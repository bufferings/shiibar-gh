//! The core's side of fetching: what a run of one account may read, applying
//! what it brings back, the watch period, token records and the account
//! warnings. DESIGN.md, "API usage", "Rate limits", "Fetch success and
//! failure" and "Showing warnings".

use super::{DAY_SECS, Engine, Failures, Timers};
use crate::clock::Now;
use crate::model::*;
use crate::plan::*;
use shiibar_gh_proto as proto;
use shiibar_gh_proto::{Lenient, WarningKind};
use std::collections::BTreeSet;

/// `token_expiring` starts this long before the expiry.
const EXPIRY_WARNING: i64 = 7 * DAY_SECS;
/// Near the limit below this share of it remaining, in percent.
const NEAR_LIMIT_PERCENT: i64 = 20;
/// Failed event fetches in a row before `events_fetch_failed`.
const EVENTS_FAILURES_WARNED: u32 = 3;
/// The poll interval when GitHub has not named one yet.
pub const DEFAULT_POLL_INTERVAL: i64 = 60;
/// DESIGN.md, "Constants": the waits after the first, second, third and any
/// later failure in a row, never longer than the interval.
pub const RETRY_WAITS: [i64; 4] = [5, 10, 20, 40];
/// DESIGN.md, "Constants": `fetch_failed` shows once the first failure is
/// this old without a success.
pub const FAILED_WARNING_AFTER: i64 = 300;

/// The wait before the next run after `count` failures in a row.
pub fn retry_wait(count: u32, interval: i64) -> i64 {
    let index = (count.max(1) as usize - 1).min(RETRY_WAITS.len() - 1);
    RETRY_WAITS[index].min(interval)
}
/// The classic PAT scopes shiibar-gh needs. DESIGN.md, "Tokens".
pub const REQUIRED_SCOPES: [&str; 3] = ["repo", "notifications", "read:org"];

/// The required scopes a granted list lacks. GitHub saves a token's scopes
/// normalized, without the ones a granted scope includes, so `write:org`
/// and `admin:org` stand for `read:org` (docs.github.com, "Scopes for OAuth
/// apps": "normalized list"). Unverified that those two include
/// `read:org`; see the open questions of DESIGN.md.
pub fn missing_scopes(granted: &[String]) -> Vec<&'static str> {
    REQUIRED_SCOPES
        .iter()
        .copied()
        .filter(|need| {
            !granted.iter().any(|g| {
                g == need || (*need == "read:org" && (g == "write:org" || g == "admin:org"))
            })
        })
        .collect()
}

fn warning(
    kind: WarningKind,
    account: Option<&str>,
    owner: Option<&str>,
    message: String,
    until: Option<i64>,
    url: Option<String>,
) -> proto::Warning {
    proto::Warning {
        kind: Lenient::Known(kind),
        account: account.map(str::to_string),
        owner: owner.map(str::to_string),
        message,
        until,
        url,
    }
}

/// `N days`, rounded up, at least one: `Expires in 1 day` under a day.
fn days_left(until: i64, now: i64) -> String {
    let days = ((until - now) + DAY_SECS - 1).div_euclid(DAY_SECS).max(1);
    if days == 1 {
        "1 day".into()
    } else {
        format!("{days} days")
    }
}

impl Engine {
    pub fn timers(&self, account: &str) -> Timers {
        self.timers.get(account).cloned().unwrap_or_default()
    }

    /// The card shows, Snooze counted as showing, or disappeared less than
    /// Days to keep watching after close ago.
    pub fn is_watched(&self, pr: &PrRec, now: i64) -> bool {
        if pr.unreadable {
            return false;
        }
        let Some(owner) = self.enabled_owner_of(pr) else {
            return false;
        };
        if self.on_screen(pr, owner, now) {
            return true;
        }
        let keep = self.data.config.keep_watching_days.saturating_mul(DAY_SECS);
        pr.gone_at
            .is_some_and(|gone| now.saturating_sub(gone) <= keep)
    }

    /// A held card still shows: it leaves when the popover closes.
    fn shows_now(&self, pr: &PrRec, now: i64) -> bool {
        self.owner_of(pr)
            .is_some_and(|owner| self.on_screen(pr, owner, now))
    }

    /// The periodic pass records when cards disappear, and forgets what was
    /// collected for PRs that left the watch.
    pub(super) fn track_watching(&mut self, now: &Now) {
        let mut changes = Vec::new();
        for pr in self.data.prs.values() {
            let gone_at = match (self.shows_now(pr, now.at), pr.gone_at) {
                (true, _) => None,
                (false, Some(at)) => Some(at),
                (false, None) => Some(now.at),
            };
            let collected = pr.collected && self.is_watched(pr, now.at);
            if gone_at != pr.gone_at || collected != pr.collected {
                changes.push((pr.key.clone(), gone_at, collected));
            }
        }
        for (key, gone_at, collected) in changes {
            if let Some(pr) = self.pr_mut(&key) {
                pr.gone_at = gone_at;
                pr.collected = collected;
            }
        }
        // DESIGN.md, "Reaction rows": what changed outside the watch makes no
        // row; the first fetch after the return sets the baseline.
        let unwatched: BTreeSet<(String, String)> = self
            .data
            .prs
            .values()
            .filter(|pr| !self.is_watched(pr, now.at))
            .map(|pr| (pr.account.clone(), pr.id.clone()))
            .collect();
        let mut changed = Vec::new();
        for account in self.data.accounts.values_mut() {
            for own in account.fetch.own.values_mut() {
                if own.baseline_done && unwatched.contains(&(account.id.clone(), own.pr_id.clone()))
                {
                    own.baseline_done = false;
                    changed.push(account.id.clone());
                }
            }
        }
        self.dirty.accounts.extend(changed);
    }

    /// Stopped by a rate limit until this time.
    pub fn stopped_until(&self, account: &str, now: i64) -> Option<i64> {
        self.data
            .accounts
            .get(account)
            .and_then(|a| a.stopped_until)
            .filter(|until| *until > now)
    }

    fn token_unusable(&self, account: &AccountRec, now: i64) -> bool {
        account.token.invalid || account.token.expires_at.is_some_and(|at| at <= now)
    }

    /// Whether a run of the account may start: a registered token, no rate
    /// limit stop, and a token that is neither rejected nor expired, unless
    /// `refresh` tries it once more.
    pub fn may_fetch(&self, account: &str, now: i64, forced: bool) -> bool {
        let Some(record) = self.data.accounts.get(account) else {
            return false;
        };
        record.token.registered
            && self.stopped_until(account, now).is_none()
            && (forced || !self.token_unusable(record, now))
    }

    /// Which fetches of the account are due now. DESIGN.md, "Fetch success
    /// and failure": the account run (`status`) checks the notifications too
    /// unless `X-Poll-Interval` has not passed; the reactions keep their own
    /// time. `refresh` makes the run and the reactions due at once.
    pub fn due(&self, account: &str, now: i64, forced: bool) -> Due {
        let timers = self.timers(account);
        let run = forced || now >= timers.run;
        Due {
            status: run,
            reactions: forced || now >= timers.reactions,
            notifications: run && now >= timers.notifications,
        }
    }

    /// The failed runs of the account since its last success.
    pub fn failures(&self, account: &str) -> Option<Failures> {
        self.failures.get(account).copied()
    }

    /// A stop begins (rate limit, 401, no token, unreadable Keychain): the
    /// failures are forgotten, and counting starts again after it.
    fn forget_failures(&mut self, account: &str) {
        self.failures.remove(account);
    }

    /// A copy of what a run of the account needs.
    pub fn fetch_plan(&self, account: &str, now: &Now, due: Due, token: String) -> Option<Plan> {
        let record = self.data.accounts.get(account)?;
        let owners = self
            .owners_of(account)
            .into_iter()
            .map(|o| OwnerPlan {
                id: o.id.clone(),
                login: (!o.is_public()).then(|| o.name.clone()),
                kind: o.kind,
                enabled: o.enabled,
                status_due: o.enabled && due.status,
                fetched_at: o.fetched_at,
                watch_started_at: o.watch_started_at,
                team_requests: o.events.cell(EventKind::TeamReviewRequested).list,
            })
            .collect();
        let prs = self
            .data
            .prs
            .values()
            .filter(|pr| pr.account == account)
            .map(|pr| {
                (
                    pr.id.clone(),
                    PrInfo {
                        id: pr.id.clone(),
                        owner: pr.owner.clone(),
                        repo: pr.repo.clone(),
                        number: pr.number,
                        owner_id: self.enabled_owner_of(pr).map(|o| o.id.clone()),
                        updated_at: pr.updated_at,
                        state: pr.state,
                        mine: self.authored_by_me(pr),
                        checks: pr.checks,
                        base_status: pr.base_status,
                        mergeable: pr.mergeable,
                        watched: self.is_watched(pr, now.at),
                        collected: pr.collected,
                        unreadable: pr.unreadable,
                    },
                )
            })
            .collect();
        let fetch = &record.fetch;
        Some(Plan {
            now: now.at,
            due,
            account: account.to_string(),
            login: record.login.clone(),
            token,
            notif_last_modified: fetch.notif_last_modified.clone(),
            notif_since: fetch.notif_since.clone(),
            owners,
            registered_owners: self
                .data
                .owners
                .values()
                .filter(|o| o.account == account && !o.is_public())
                .map(|o| o.name.to_lowercase())
                .collect(),
            // DESIGN.md, "Identifying PRs": the repo#number of every saved
            // PR of the account, those 0.2 took from notifications included.
            pr_ids: self
                .data
                .prs
                .values()
                .filter(|pr| pr.account == account)
                .map(|pr| (pr_key(&pr.owner, &pr.repo, pr.number), pr.id.clone()))
                .collect(),
            prs,
            threads: fetch.threads.clone(),
            own: fetch.own.clone(),
            retries: fetch
                .retries
                .values()
                .map(|r| (r.pr_id.clone(), r.since))
                .collect(),
            pending_signals: fetch.pending_signals.clone(),
            teams: record.teams.clone(),
            status_interval_minutes: self.data.config.status_interval_minutes,
            drop_after_days: self.data.config.drop_after_days,
        })
    }

    /// Apply what a run of the account brought back, then hand its `Ingest`
    /// to the core.
    pub fn apply_fetch(&mut self, account: &str, outcome: Outcome, now: &Now) {
        self.clock = now.clone();
        if !self.data.accounts.contains_key(account) {
            return;
        }
        let status_interval = self.data.config.status_interval_minutes.max(1) * 60;
        let reactions_interval = self.data.config.reactions_interval_minutes.max(1) * 60;
        let poll = outcome
            .poll_interval
            .or(self.data.accounts[account].fetch.poll_interval)
            .unwrap_or(DEFAULT_POLL_INTERVAL);
        let timers = self.timers.entry(account.to_string()).or_default();
        if outcome.due.reactions {
            timers.reactions = now.at + reactions_interval;
        }
        // Only a check GitHub answered (200 or 304) starts the wait.
        if outcome.due.notifications && outcome.notifications_checked {
            timers.notifications = now.at + poll.max(1);
        }
        // DESIGN.md, "Fetch success and failure": one account run, timed
        // from its end. A stop (rate limit or 401) is not a failure: the
        // count starts again after it.
        let mut succeeded = false;
        // A stop that began in any run, a reaction-only one included,
        // forgets the failures.
        let stopped = outcome.stop.is_some() || outcome.token.invalid == Some(true);
        if stopped {
            self.failures.remove(account);
        }
        if outcome.due.status {
            if stopped {
                timers.run = now.at + status_interval;
            } else if outcome.failed.is_some() {
                let failures = self
                    .failures
                    .entry(account.to_string())
                    .or_insert(Failures {
                        count: 0,
                        first_at: now.at,
                    });
                failures.count += 1;
                timers.run = now.at + retry_wait(failures.count, status_interval);
            } else {
                timers.run = now.at + status_interval;
                self.failures.remove(account);
                succeeded = true;
            }
        }

        if let Some(ingest) = outcome.ingest
            && let Err(e) = self.ingest(account, ingest, now)
        {
            crate::logging::error(format_args!("a fetch result was not applied: {e:?}"));
        }

        self.dirty.accounts.insert(account.to_string());
        let Some(record) = self.data.accounts.get_mut(account) else {
            return;
        };
        if succeeded {
            record.updated_at = Some(now.at);
        }
        if let Some(login) = outcome.login.filter(|l| !l.is_empty()) {
            record.login = login;
        }
        if let Some(teams) = outcome.teams {
            record.teams = teams;
        }
        let obs = outcome.token;
        if let Some(invalid) = obs.invalid {
            record.token.invalid = invalid;
            // Only an account run searches every owner, so only it can
            // tell that the SSO warnings went away.
            if outcome.due.status {
                record.token.sso = obs.sso;
                record.token.sso_orgs = obs.sso_orgs;
                record.token.sso_urls = obs.sso_urls;
                record.token.sso_owners = obs.sso_owners;
            }
        }
        if obs.expires_at.is_some() {
            record.token.expires_at = obs.expires_at;
        }
        if obs.scopes.is_some() {
            record.token.scopes = obs.scopes;
        }
        for scope in &outcome.checked {
            record.token.refused.remove(scope);
        }
        record.token.refused.extend(outcome.refused);
        if let Some(limit) = outcome.graphql {
            record.graphql = Some(limit);
        }
        if let Some(limit) = outcome.rest {
            record.rest = Some(limit);
        }
        if let Some(until) = outcome.stop {
            record.stopped_until = Some(until);
        }
        let fetch = &mut record.fetch;
        if outcome.due.notifications && outcome.notifications_checked {
            fetch.notif_checked_at = Some(now.at);
        }
        for thread in outcome.threads {
            let merged = match fetch.threads.get(&thread.id) {
                Some(old) => ThreadRec {
                    mine_at: min_opt(old.mine_at, thread.mine_at),
                    mention_at: min_opt(old.mention_at, thread.mention_at),
                    ..thread
                },
                None => thread,
            };
            fetch.threads.insert(merged.id.clone(), merged);
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
        let collected: Vec<String> = outcome
            .collected
            .iter()
            .map(|id| join_key(account, id))
            .collect();
        for key in collected {
            if let Some(pr) = self.pr_mut(&key) {
                pr.collected = true;
            }
        }
    }

    /// A token was saved for the account: record the registration and
    /// forget what was learned about the token it replaced.
    pub fn token_saved(&mut self, account: &str) {
        self.forget_failures(account);
        if let Some(record) = self.account_mut(account) {
            record.token = TokenRec {
                registered: true,
                ..TokenRec::default()
            };
        }
    }

    /// The Keychain holds no token for the account.
    pub fn token_cleared(&mut self, account: &str) {
        self.forget_failures(account);
        if let Some(record) = self.account_mut(account)
            && record.token.registered
        {
            record.token = TokenRec::default();
        }
    }

    /// The account's login as GitHub spells it now.
    pub fn login_seen(&mut self, account: &str, login: &str) {
        if !login.is_empty()
            && let Some(record) = self.account_mut(account)
        {
            record.login = login.to_string();
        }
    }

    /// Record the result of a test of the saved token.
    pub fn token_tested(
        &mut self,
        account: &str,
        test: TestRec,
        obs: TokenObs,
        login: Option<String>,
    ) {
        if let Some(record) = self.account_mut(account) {
            record.token.last_test = Some(test);
            if obs.expires_at.is_some() {
                record.token.expires_at = obs.expires_at;
            }
            if obs.scopes.is_some() {
                record.token.scopes = obs.scopes;
            }
            if obs.invalid == Some(false) {
                record.token.invalid = false;
            }
            if let Some(login) = login.filter(|l| !l.is_empty()) {
                record.login = login;
            }
        }
    }

    /// Usage a test or lookup ran into: the limits and a stop.
    pub fn usage_seen(
        &mut self,
        account: &str,
        graphql: Option<LimitRec>,
        rest: Option<LimitRec>,
        stop: Option<i64>,
    ) {
        if let Some(record) = self.account_mut(account) {
            if graphql.is_some() {
                record.graphql = graphql;
            }
            if rest.is_some() {
                record.rest = rest;
            }
            if stop.is_some() {
                record.stopped_until = stop;
            }
        }
        // A rate limit a test or lookup ran into stops every fetch too.
        if stop.is_some() {
            self.forget_failures(account);
        }
    }

    /// The warnings of the accounts a `refresh` covered, without repeats.
    pub fn refresh_warnings(&self, account: Option<&str>) -> Vec<proto::Warning> {
        let mut out: Vec<proto::Warning> = Vec::new();
        let mut list: Vec<&AccountRec> = self.data.accounts.values().collect();
        list.sort_by_key(|a| a.seq);
        for record in list {
            if account.is_some_and(|a| a != record.id) {
                continue;
            }
            for warning in self.warnings(record) {
                if !out.contains(&warning) {
                    out.push(warning);
                }
            }
        }
        if out.is_empty() {
            out.extend(self.keychain_warning());
        }
        out
    }

    fn keychain_warning(&self) -> Option<proto::Warning> {
        match self.keychain {
            proto::KeychainState::Ok => None,
            proto::KeychainState::Unavailable => Some(warning(
                WarningKind::KeychainUnavailable,
                None,
                None,
                "Couldn't read tokens from Keychain".into(),
                None,
                None,
            )),
            proto::KeychainState::Unreadable => Some(warning(
                WarningKind::TokensUnreadable,
                None,
                None,
                "Saved tokens are unreadable".into(),
                None,
                None,
            )),
        }
    }

    /// DESIGN.md, "Wire format" and "Showing warnings": the warnings of one
    /// account, in the order of that table.
    pub(super) fn warnings(&self, account: &AccountRec) -> Vec<proto::Warning> {
        let now = self.clock.at;
        let id = Some(account.id.as_str());
        let mut out = Vec::new();
        out.extend(self.keychain_warning());
        let token = &account.token;
        let keychain_ok = self.keychain == proto::KeychainState::Ok;
        if !token.registered {
            if keychain_ok {
                out.push(warning(
                    WarningKind::NoToken,
                    id,
                    None,
                    "No token".into(),
                    None,
                    None,
                ));
            }
        } else if self.token_unusable(account, now) {
            out.push(warning(
                WarningKind::TokenInvalid,
                id,
                None,
                "Token is invalid".into(),
                None,
                None,
            ));
        } else if let Some(at) = token.expires_at.filter(|at| at - now <= EXPIRY_WARNING) {
            out.push(warning(
                WarningKind::TokenExpiring,
                id,
                None,
                format!("Token expires in {}", days_left(at, now)),
                Some(at),
                None,
            ));
        }
        // DESIGN.md, "Showing warnings": only once the first failure is five
        // minutes old, and never while fetching is stopped.
        let usable = token.registered
            && !self.token_unusable(account, now)
            && keychain_ok
            && self.stopped_until(&account.id, now).is_none();
        if usable
            && let Some(failures) = self.failures.get(&account.id)
            && now - failures.first_at >= FAILED_WARNING_AFTER
        {
            let until = self.timers(&account.id).run;
            let minutes = ((until - now) + 59).div_euclid(60).max(1);
            out.push(warning(
                WarningKind::FetchFailed,
                id,
                None,
                format!("Couldn't reach GitHub · retrying in {minutes} min"),
                Some(until),
                None,
            ));
        }
        if let Some(until) = self.stopped_until(&account.id, now) {
            let at = jiff::Timestamp::from_second(until)
                .map(|t| {
                    t.to_zoned(self.clock.tz.clone())
                        .strftime("%H:%M")
                        .to_string()
                })
                .unwrap_or_default();
            out.push(warning(
                WarningKind::RateLimited,
                id,
                None,
                format!("Polling paused until {at} · GitHub's limit reached"),
                Some(until),
                None,
            ));
        }
        let near = |limit: &Option<LimitRec>| {
            limit.is_some_and(|l| l.limit > 0 && l.remaining * 100 < l.limit * NEAR_LIMIT_PERCENT)
        };
        if near(&account.graphql) {
            out.push(warning(
                WarningKind::GraphqlNearLimit,
                id,
                None,
                "GraphQL API usage is over 80% of GitHub's limit".into(),
                None,
                None,
            ));
        }
        if near(&account.rest) {
            out.push(warning(
                WarningKind::RestNearLimit,
                id,
                None,
                "REST API usage is over 80% of GitHub's limit".into(),
                None,
                None,
            ));
        }
        if token.registered {
            let mut missing: Vec<&str> = token
                .scopes
                .as_deref()
                .map(missing_scopes)
                .unwrap_or_default();
            for scope in REQUIRED_SCOPES {
                if token.refused.contains(scope) && !missing.contains(&scope) {
                    missing.push(scope);
                }
            }
            missing.sort_by_key(|s| REQUIRED_SCOPES.iter().position(|r| r == s));
            if !missing.is_empty() {
                out.push(warning(
                    WarningKind::ScopeMissing,
                    id,
                    None,
                    format!("Token is missing {}", missing.join(", ")),
                    None,
                    None,
                ));
            }
        }
        // DESIGN.md, "Tokens": only registered owners. An organization id of
        // `X-GitHub-SSO` names one by its `github_id`; the single-organization
        // form names the owner whose search it refused. Anything else is
        // ignored.
        if token.registered {
            for owner in self.owners_of(&account.id) {
                let by_id =
                    token.sso && owner.github_id.is_some_and(|g| token.sso_orgs.contains(&g));
                let by_search = token.sso_owners.get(&owner.id);
                if !by_id && by_search.is_none() {
                    continue;
                }
                // An owner named by its organization id gets no URL: the
                // header's URLs may be another organization's, and the app
                // opens the token settings without one.
                let url = by_search.cloned().flatten();
                out.push(warning(
                    WarningKind::SsoRequired,
                    id,
                    Some(&owner.id),
                    format!("SSO authorization required for {}", owner.name),
                    None,
                    url,
                ));
            }
        }
        let mut failing: Vec<(String, String)> = account
            .fetch
            .retries
            .values()
            .filter(|r| r.failures >= EVENTS_FAILURES_WARNED)
            .filter_map(|r| self.data.prs.get(&join_key(&account.id, &r.pr_id)))
            .filter_map(|pr| {
                let owner = self.owner_of(pr)?;
                Some((
                    owner.id.clone(),
                    format!("{}/{} #{}", pr.owner, pr.repo, pr.number),
                ))
            })
            .collect();
        failing.sort();
        failing.dedup();
        for (owner, pr) in failing {
            out.push(warning(
                WarningKind::EventsFetchFailed,
                id,
                Some(&owner),
                format!("Couldn't fetch events for {pr} · retrying"),
                None,
                None,
            ));
        }
        out
    }
}

fn min_opt(a: Option<i64>, b: Option<i64>) -> Option<i64> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}
