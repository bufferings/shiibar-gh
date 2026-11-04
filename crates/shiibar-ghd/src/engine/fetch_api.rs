//! The core's side of fetching: what a run may read, applying what it brings
//! back, the watch period, token records and the scope warnings.
//! docs/tasks/M2.md, "Fetcher and core".

use super::{DAY_SECS, Engine, Result, Timers, not_found};
use crate::clock::Now;
use crate::model::*;
use crate::plan::*;
use shiibar_gh_proto as proto;
use shiibar_gh_proto::{Lenient, TokenRole, WarningKind};
use std::collections::{BTreeMap, BTreeSet};

/// `token_expiring` starts this long before the expiry.
const EXPIRY_WARNING: i64 = 7 * DAY_SECS;
/// `cost_near_cap` above this share of the cost cap, in percent.
const NEAR_CAP_PERCENT: i64 = 80;
const HOUR: i64 = 3_600;
/// Failed event fetches in a row before `events_fetch_failed`.
const EVENTS_FAILURES_WARNED: u32 = 3;
/// The poll interval when GitHub has not named one yet.
pub const DEFAULT_POLL_INTERVAL: i64 = 60;

fn warning(
    kind: WarningKind,
    token: Option<TokenRole>,
    message: &str,
    until: Option<i64>,
) -> proto::Warning {
    proto::Warning {
        kind: Lenient::Known(kind),
        token: token.map(Lenient::Known),
        message: message.to_string(),
        until,
    }
}

impl Engine {
    pub fn timers(&self) -> &Timers {
        &self.timers
    }

    fn status_due(&self, scope: &str, now: i64) -> bool {
        now >= self.timers.status.get(scope).copied().unwrap_or(0)
    }

    /// The time every fetch is stopped until, when it is.
    pub fn stopped_until(&self, now: i64) -> Option<i64> {
        self.data.fetch.stopped_until.filter(|until| *until > now)
    }

    /// The card shows, Snooze counted as showing, or disappeared less than
    /// Days to keep watching after close ago. docs/tasks/M2.md.
    pub fn is_watched(&self, pr: &PrRec, now: i64) -> bool {
        if pr.unreadable || self.enabled_scope_of(pr).is_none() {
            return false;
        }
        if self.would_show(pr, now) {
            return true;
        }
        let keep = self.data.config.keep_watching_days.saturating_mul(DAY_SECS);
        pr.gone_at
            .is_some_and(|gone| now.saturating_sub(gone) <= keep)
    }

    /// The periodic pass records when cards disappear, and forgets what was
    /// collected for PRs that left the watch.
    pub(super) fn track_watching(&mut self, now: &Now) {
        let mut changes = Vec::new();
        for pr in self.data.prs.values() {
            let shows = !pr.unreadable && self.would_show(pr, now.at);
            let gone_at = match (shows, pr.gone_at) {
                (true, _) => None,
                (false, Some(at)) => Some(at),
                (false, None) => Some(now.at),
            };
            let collected = pr.collected && self.is_watched(pr, now.at);
            if gone_at != pr.gone_at || collected != pr.collected {
                changes.push((pr.id.clone(), gone_at, collected));
            }
        }
        for (id, gone_at, collected) in changes {
            if let Some(pr) = self.pr_mut(&id) {
                pr.gone_at = gone_at;
                pr.collected = collected;
            }
        }
        // DESIGN.md, "Reaction rows": what changed outside the watch makes no
        // row; the first fetch after the return sets the baseline. Any PR out
        // of the watch, collected or not, starts again from a baseline.
        let unwatched: BTreeSet<String> = self
            .data
            .prs
            .values()
            .filter(|pr| !self.is_watched(pr, now.at))
            .map(|pr| pr.id.clone())
            .collect();
        for own in self.data.fetch.own.values_mut() {
            if own.baseline_done && unwatched.contains(&own.pr_id) {
                own.baseline_done = false;
                self.dirty.fetch = true;
            }
        }
    }

    /// Which fetches are due now. `refresh` makes all of them due except the
    /// notifications, which keep to `X-Poll-Interval`.
    pub fn due(&self, now: i64, forced: bool) -> Due {
        let any_scope = self
            .data
            .scopes
            .values()
            .filter(|s| !s.removed && s.enabled)
            .any(|s| self.status_due(&s.id, now));
        Due {
            status: forced || any_scope,
            reactions: forced || now >= self.timers.reactions,
            notifications: now >= self.timers.notifications,
        }
    }

    fn token_use(
        &self,
        key: &str,
        now: i64,
        read: &mut dyn FnMut(&str) -> Option<String>,
    ) -> TokenUse {
        let Some(record) = self.data.fetch.tokens.get(key).filter(|t| t.registered) else {
            return TokenUse::default();
        };
        let expired = record.expires_at.is_some_and(|at| at <= now);
        TokenUse {
            registered: true,
            token: read(&scope_account(key)),
            invalid: record.invalid || expired,
            owner: record.owner.clone(),
        }
    }

    /// A copy of what a run needs. `read` gets a token from the Keychain and
    /// is called only for recorded registrations.
    pub fn fetch_plan(
        &self,
        now: &Now,
        due: Due,
        forced: bool,
        only_scope: Option<String>,
        read: &mut dyn FnMut(&str) -> Option<String>,
    ) -> Plan {
        let notifications = self.token_use(NOTIFICATIONS, now.at, read);
        let mut scopes = Vec::new();
        for scope in self.data.scopes.values() {
            if scope.removed || !scope.enabled {
                continue;
            }
            if only_scope.as_ref().is_some_and(|only| *only != scope.id) {
                continue;
            }
            let public = scope.id == PUBLIC;
            let key = scope.id.to_lowercase();
            scopes.push(ScopePlan {
                status_due: forced || self.status_due(&scope.id, now.at),
                id: scope.id.clone(),
                owner: (!public).then(|| scope.name.clone().unwrap_or_else(|| scope.id.clone())),
                kind: scope.kind,
                token: self.token_use(&key, now.at, read),
                token_key: key.clone(),
                fetched_at: scope.fetched_at,
                watch_started_at: scope.watch_started_at,
                teams: self.data.fetch.teams.get(&key).cloned().unwrap_or_default(),
            });
        }
        let prs = self
            .data
            .prs
            .values()
            .map(|pr| {
                let info = PrInfo {
                    id: pr.id.clone(),
                    owner: pr.owner.clone(),
                    repo: pr.repo.clone(),
                    number: pr.number,
                    scope: self.enabled_scope_of(pr).map(|s| s.id.clone()),
                    updated_at: pr.updated_at,
                    state: pr.state,
                    mine: pr.mine,
                    checks: pr.checks,
                    base_status: pr.base_status,
                    mergeable: pr.mergeable,
                    watched: self.is_watched(pr, now.at),
                    collected: pr.collected,
                    unreadable: pr.unreadable,
                };
                (pr.id.clone(), info)
            })
            .collect();
        let fetch = &self.data.fetch;
        Plan {
            now: now.at,
            due,
            only_scope,
            forced,
            notifications,
            notif_last_modified: fetch.notif_last_modified.clone(),
            notif_since: fetch.notif_since.clone(),
            scopes,
            registered_owners: self
                .data
                .scopes
                .values()
                .filter(|s| !s.removed && s.id != PUBLIC)
                .map(|s| s.id.to_lowercase())
                .collect(),
            prs,
            pr_ids: fetch.pr_ids.clone(),
            threads: fetch.threads.clone(),
            own: fetch.own.clone(),
            retries: fetch
                .retries
                .values()
                .map(|r| (r.pr_id.clone(), r.since))
                .collect(),
            pending_signals: fetch.pending_signals.clone(),
            enabled_scopes: self
                .data
                .scopes
                .values()
                .filter(|s| !s.removed && s.enabled)
                .map(|s| s.id.clone())
                .collect(),
            mismatched: self
                .data
                .scopes
                .values()
                .filter(|s| self.owner_mismatch(&s.id))
                .map(|s| s.id.clone())
                .collect(),
            status_interval_minutes: self.data.config.status_interval_minutes,
            drop_after_days: self.data.config.drop_after_days,
            include_team_requests: self.data.config.include_team_requests,
            cost_cap: self.data.config.graphql_cost_cap,
            costs: fetch.costs.clone(),
        }
    }

    /// Apply what a run brought back, then hand its `Ingest` to the core.
    pub fn apply_fetch(&mut self, outcome: Outcome, now: &Now) {
        self.clock_at = now.at;
        self.dirty.fetch = true;
        let status_interval = self.data.config.status_interval_minutes.max(1) * 60;
        let reactions_interval = self.data.config.reactions_interval_minutes.max(1) * 60;
        for scope in &outcome.status_ran {
            self.timers
                .status
                .insert(scope.clone(), now.at + status_interval);
        }
        if outcome.due.reactions {
            self.timers.reactions = now.at + reactions_interval;
        }
        if outcome.due.notifications {
            let interval = outcome
                .poll_interval
                .or(self.data.fetch.poll_interval)
                .unwrap_or(DEFAULT_POLL_INTERVAL);
            self.timers.notifications = now.at + interval.max(1);
        }

        if let Some(ingest) = outcome.ingest
            && let Err(e) = self.ingest(ingest, now)
        {
            crate::logging::error(format_args!("a fetch result was not applied: {e:?}"));
        }

        let fetch = &mut self.data.fetch;
        for (key, obs) in outcome.tokens {
            let Some(token) = fetch.tokens.get_mut(&key).filter(|t| t.registered) else {
                continue;
            };
            if obs.owner.is_some() {
                token.owner = obs.owner;
            }
            if let Some(invalid) = obs.invalid {
                token.invalid = invalid;
                token.sso = obs.sso;
                token.sso_urls = obs.sso_urls;
            }
            // Only a header updates these; a response without it keeps them.
            if obs.expires_at.is_some() {
                token.expires_at = obs.expires_at;
            }
            if obs.scopes.is_some() && key == NOTIFICATIONS {
                token.scopes = obs.scopes;
            }
        }
        for (key, id) in outcome.pr_ids {
            fetch.pr_ids.insert(key, id);
        }
        for thread in outcome.threads {
            let from_at = fetch
                .threads
                .get(&thread.id)
                .map_or(thread.from_at, |t| t.from_at.min(thread.from_at));
            fetch
                .threads
                .insert(thread.id.clone(), ThreadRec { from_at, ..thread });
        }
        for own in outcome.own {
            fetch.own.entry(own.id.clone()).or_insert(own);
        }
        for id in outcome.own_gone {
            fetch.own.remove(&id);
        }
        for id in outcome.baselines_set {
            if let Some(own) = fetch.own.get_mut(&id) {
                own.baseline_done = true;
            }
        }
        for id in outcome.retries_ok {
            fetch.retries.remove(&id);
        }
        for (id, since) in outcome.retries_failed {
            let entry = fetch.retries.entry(id.clone()).or_insert(RetryRec {
                pr_id: id,
                since,
                failures: 0,
            });
            entry.since = entry.since.min(since);
            entry.failures += 1;
        }
        if let Some(pending) = outcome.pending_signals {
            fetch.pending_signals = pending;
        }
        if outcome.notif_last_modified.is_some() {
            fetch.notif_last_modified = outcome.notif_last_modified;
        }
        if outcome.notif_since.is_some() {
            fetch.notif_since = outcome.notif_since;
        }
        if outcome.poll_interval.is_some() {
            fetch.poll_interval = outcome.poll_interval;
        }
        fetch.costs.extend(outcome.costs);
        fetch.costs.retain(|(at, _)| *at > now.at - HOUR);
        if let Some((remaining, limit)) = outcome.rest {
            fetch.usage.rest_remaining = Some(remaining);
            fetch.usage.rest_limit = Some(limit);
        }
        if let Some((remaining, limit)) = outcome.graphql {
            fetch.usage.graphql_remaining = Some(remaining);
            fetch.usage.graphql_limit = Some(limit);
        }
        if outcome.cost_per_poll.is_some() {
            fetch.usage.cost_per_poll = outcome.cost_per_poll;
        }
        if let Some((until, reason)) = outcome.stop {
            fetch.stopped_until = Some(until);
            fetch.stop_reason = Some(reason);
        }

        for (id, obs) in outcome.scopes {
            let key = id.to_lowercase();
            if let Some(teams) = obs.teams {
                self.data.fetch.teams.insert(key, teams);
            }
            if let Some(warnings) = obs.warnings {
                self.fetch_warnings.insert(id.clone(), warnings);
            }
            if (obs.kind.is_some() || obs.name.is_some())
                && let Some(scope) = self.scope_mut(&id)
            {
                if obs.kind.is_some() {
                    scope.kind = obs.kind;
                }
                if obs.name.is_some() {
                    scope.name = obs.name;
                }
            }
        }
        for id in outcome.collected {
            if self.data.prs.contains_key(&id)
                && let Some(pr) = self.pr_mut(&id)
            {
                pr.collected = true;
            }
        }
    }

    /// What `token_test` learned about a scope's owner.
    pub fn scope_observed(&mut self, scope: &str, kind: Option<ScopeKind>, name: Option<String>) {
        if let Some(record) = self.scope_mut(scope) {
            if kind.is_some() {
                record.kind = kind;
            }
            if name.is_some() {
                record.name = name;
            }
        }
    }

    /// `notifications`, `public` or a registered owner, as the key of its
    /// token record. An unregistered owner is `not_found`.
    pub fn token_key(&self, target: &str) -> Result<String> {
        if target.eq_ignore_ascii_case(NOTIFICATIONS) {
            return Ok(NOTIFICATIONS.into());
        }
        if target.eq_ignore_ascii_case(PUBLIC) {
            return Ok(PUBLIC.into());
        }
        self.registered_scope(target)
            .map(|scope| scope.id.to_lowercase())
            .ok_or_else(|| not_found(format!("scope {target}")))
    }

    /// The scope id a token key belongs to, if any.
    pub fn scope_of_token(&self, key: &str) -> Option<String> {
        if key == NOTIFICATIONS {
            return None;
        }
        self.scope_key(key).map(str::to_string)
    }

    /// A token was saved to the Keychain: record the registration and
    /// forget everything learned about the token it replaced.
    pub fn token_saved(&mut self, key: &str) {
        self.data.fetch.tokens.insert(
            key.to_string(),
            TokenRec {
                target: key.to_string(),
                registered: true,
                ..TokenRec::default()
            },
        );
        self.dirty.fetch = true;
    }

    pub fn token_record(&self, key: &str) -> Option<&TokenRec> {
        self.data.fetch.tokens.get(key).filter(|t| t.registered)
    }

    /// The scope's token belongs to another account than the notifications
    /// token. DESIGN.md, "Tokens".
    pub fn owner_mismatch(&self, scope: &str) -> bool {
        let owner = self
            .token_record(&scope.to_lowercase())
            .and_then(|t| t.owner.clone());
        match (self.viewer(), owner) {
            (Some(viewer), Some(owner)) => !viewer.eq_ignore_ascii_case(&owner),
            _ => false,
        }
    }

    /// The owner of the notifications token, the reference for every other.
    pub fn viewer(&self) -> Option<String> {
        self.token_record(NOTIFICATIONS)
            .and_then(|t| t.owner.clone())
    }

    /// Record what a test of the saved token found.
    pub fn token_tested(&mut self, key: &str, test: TestRec, obs: TokenObs) {
        if let Some(token) = self.data.fetch.tokens.get_mut(key).filter(|t| t.registered) {
            token.last_test = Some(test);
            if obs.owner.is_some() {
                token.owner = obs.owner;
            }
            if obs.expires_at.is_some() {
                token.expires_at = obs.expires_at;
            }
            if obs.scopes.is_some() && key == NOTIFICATIONS {
                token.scopes = obs.scopes;
            }
            self.dirty.fetch = true;
        }
    }

    /// The owner of a token, read while testing another.
    pub fn token_tested_owner(&mut self, key: &str, owner: String) {
        if let Some(token) = self.data.fetch.tokens.get_mut(key).filter(|t| t.registered) {
            token.owner = Some(owner);
            self.dirty.fetch = true;
        }
    }

    /// The `settings_status` response. DESIGN.md, "Wire format".
    pub fn settings_status(&self) -> (proto::ApiUsage, Vec<proto::TokenStatus>) {
        let fetch = &self.data.fetch;
        let usage = proto::ApiUsage {
            rest_remaining: fetch.usage.rest_remaining,
            rest_limit: fetch.usage.rest_limit,
            graphql_remaining: fetch.usage.graphql_remaining,
            graphql_limit: fetch.usage.graphql_limit,
            cost_per_poll: fetch.usage.cost_per_poll,
            notifications_poll_interval: fetch.poll_interval,
        };
        let mut targets = vec![
            (NOTIFICATIONS.to_string(), NOTIFICATIONS.to_string()),
            (PUBLIC.to_string(), PUBLIC.to_string()),
        ];
        for scope in self.data.scopes.values() {
            if !scope.removed && scope.id != PUBLIC {
                targets.push((self.display_name(&scope.id), scope.id.to_lowercase()));
            }
        }
        let tokens = targets
            .into_iter()
            .map(|(target, key)| {
                let record = self.token_record(&key);
                proto::TokenStatus {
                    target,
                    registered: record.is_some(),
                    owner: record.and_then(|t| t.owner.clone()),
                    expires_at: record.and_then(|t| t.expires_at),
                    // Only the classic PAT has scopes.
                    scopes: record
                        .filter(|_| key == NOTIFICATIONS)
                        .and_then(|t| t.scopes.clone()),
                    last_test: record.and_then(|t| t.last_test.as_ref()).map(|test| {
                        proto::LastTest {
                            at: test.at,
                            results: test.results.iter().map(wire_test_item).collect(),
                        }
                    }),
                    sso_urls: record.map(|t| t.sso_urls.clone()).unwrap_or_default(),
                }
            })
            .collect();
        (usage, tokens)
    }

    /// The warnings of the scopes a `refresh` covered, without repeats.
    pub fn refresh_warnings(&self, scope: Option<&str>) -> Vec<proto::Warning> {
        let mut out: Vec<proto::Warning> = Vec::new();
        for record in self.data.scopes.values() {
            if record.removed || scope.is_some_and(|s| s != record.id) {
                continue;
            }
            for warning in self.warnings(record) {
                if !out.contains(&warning) {
                    out.push(warning);
                }
            }
        }
        out
    }

    /// DESIGN.md, "Wire format" and "First run, failures and empty states":
    /// the warnings of one scope, from the saved fetch state and the last run.
    pub(super) fn warnings(&self, scope: &ScopeRec) -> Vec<proto::Warning> {
        use TokenRole::{Notifications, Scope};
        let now = self.clock_at;
        let mut out = Vec::new();
        let token_warnings = |key: &str, role: TokenRole, out: &mut Vec<proto::Warning>| {
            let role = Some(role);
            let Some(token) = self.token_record(key) else {
                out.push(warning(
                    WarningKind::NoToken,
                    role,
                    "Add a token in Settings",
                    None,
                ));
                return;
            };
            let expired = token.expires_at.is_some_and(|at| at <= now);
            if token.invalid || expired {
                let message = if expired {
                    "The token has expired"
                } else {
                    "The token was rejected"
                };
                out.push(warning(WarningKind::TokenInvalid, role, message, None));
            } else if let Some(at) = token.expires_at.filter(|at| at - now <= EXPIRY_WARNING) {
                out.push(warning(
                    WarningKind::TokenExpiring,
                    role,
                    "The token expires soon",
                    Some(at),
                ));
            }
            if token.sso {
                out.push(warning(
                    WarningKind::SsoRequired,
                    role,
                    "SSO authorization required",
                    None,
                ));
            }
        };
        token_warnings(NOTIFICATIONS, Notifications, &mut out);
        token_warnings(&scope.id.to_lowercase(), Scope, &mut out);
        if self.owner_mismatch(&scope.id) {
            let viewer = self.viewer().unwrap_or_default();
            let owner = self
                .token_record(&scope.id.to_lowercase())
                .and_then(|t| t.owner.clone())
                .unwrap_or_default();
            out.push(warning(
                WarningKind::TokenOwnerMismatch,
                Some(Scope),
                &format!("The token belongs to {owner}, not {viewer}"),
                None,
            ));
        }
        if let Some(until) = self.stopped_until(now) {
            let reason = self
                .data
                .fetch
                .stop_reason
                .clone()
                .unwrap_or_else(|| "Rate limited".into());
            out.push(warning(
                WarningKind::RateLimited,
                None,
                &reason,
                Some(until),
            ));
        }
        let cost: i64 = self
            .data
            .fetch
            .costs
            .iter()
            .filter(|(at, _)| *at > now - HOUR)
            .map(|(_, cost)| cost)
            .sum();
        let cap = self.data.config.graphql_cost_cap;
        if cost * 100 > cap * NEAR_CAP_PERCENT {
            out.push(warning(
                WarningKind::CostNearCap,
                None,
                &format!("GraphQL cost {cost} of {cap} in the last hour"),
                None,
            ));
        }
        if let Some(fetch) = self.fetch_warnings.get(&scope.id) {
            out.extend(fetch.iter().cloned());
        }
        let failing: BTreeSet<String> = self
            .data
            .fetch
            .retries
            .values()
            .filter(|r| r.failures >= EVENTS_FAILURES_WARNED)
            .filter_map(|r| self.data.prs.get(&r.pr_id))
            .filter(|pr| self.scope_of(pr).is_some_and(|s| s.id == scope.id))
            .map(PrRec::key)
            .collect();
        for key in failing {
            out.push(warning(
                WarningKind::EventsFetchFailed,
                Some(Scope),
                &key,
                None,
            ));
        }
        out
    }

    /// Lowercase owner keys of every registered token, for the unreadable
    /// state and tests.
    pub fn registered_tokens(&self) -> BTreeMap<String, bool> {
        self.data
            .fetch
            .tokens
            .iter()
            .map(|(k, t)| (k.clone(), t.registered))
            .collect()
    }
}

fn wire_test_item(item: &TestItem) -> proto::TestResult {
    let outcome = match item.outcome.as_str() {
        "ok" => Lenient::Known(proto::TestOutcome::Ok),
        "failed" => Lenient::Known(proto::TestOutcome::Failed),
        "unverifiable" => Lenient::Known(proto::TestOutcome::Unverifiable),
        other => Lenient::Unknown(other.to_string()),
    };
    proto::TestResult {
        item: item.item.clone(),
        outcome,
        missing: item.missing.clone(),
        reason: item.reason.clone(),
    }
}

/// The stored form of a test result.
pub fn stored_test_item(result: &proto::TestResult) -> TestItem {
    TestItem {
        item: result.item.clone(),
        outcome: result.outcome.as_text(),
        missing: result.missing.clone(),
        reason: result.reason.clone(),
    }
}
