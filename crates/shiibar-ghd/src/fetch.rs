//! One fetch run: notifications, then each scope's search, status and
//! events, then reactions. Calls run one after another, never in parallel
//! (docs/tasks/M2.md, "What is fetched"). The run works on a copy of the core
//! state ([`Plan`]) and hands everything back as an [`Outcome`]; it never
//! changes rows, cards or unread state itself.

use crate::convert::{self, Ctx, EventInput, StatusExtra};
use crate::github::{Api, CallError, Gql, Recorder, format_time};
use crate::logging;
use crate::model::{NOTIFICATIONS, OwnComment, PUBLIC, ScopeKind, TeamRec};
use crate::plan::*;
use serde_json::{Value, json};
use shiibar_gh_proto as proto;
use shiibar_gh_proto::{Ingest, IngestEvent, IngestPr, Lenient, TokenRole, WarningKind};
use std::collections::{BTreeMap, BTreeSet};

/// docs/tasks/M2.md, "Collecting a newly found PR": ten pages per connection.
const MAX_PAGES: usize = 10;
const NODES_PER_QUERY: usize = 100;
/// PRs per events query: each brings up to 100 threads of 100 comments.
const EVENT_BATCH: usize = 5;

const RATE: &str = "rateLimit { cost limit remaining resetAt }";
const ACTOR: &str = "{ __typename login }";
const REVIEWER: &str =
    "requestedReviewer { __typename ... on User { login } ... on Team { databaseId slug } }";
const COMMENT: &str = "id url createdAt bodyText bodyHTML author { __typename login }";
const SEARCH_NODES: &str = "pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { id repository { owner { login } } } }";
const ITEM_TYPES: &str = "[ISSUE_COMMENT, PULL_REQUEST_REVIEW, REVIEW_REQUESTED_EVENT, \
    MERGED_EVENT, CLOSED_EVENT, ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT]";

fn timeline_nodes() -> String {
    format!(
        "__typename \
         ... on IssueComment {{ {COMMENT} }} \
         ... on PullRequestReview {{ id url createdAt submittedAt state bodyText bodyHTML author {ACTOR} }} \
         ... on ReviewRequestedEvent {{ id createdAt actor {{ login }} {REVIEWER} }} \
         ... on MergedEvent {{ id createdAt url actor {{ login }} }} \
         ... on ClosedEvent {{ id createdAt url actor {{ login }} }} \
         ... on AddedToMergeQueueEvent {{ id createdAt actor {{ login }} }} \
         ... on RemovedFromMergeQueueEvent {{ id createdAt actor {{ login }} reason }}"
    )
}

fn pr_status_fields() -> String {
    format!(
        "id number url title state isDraft updatedAt isCrossRepository \
         author {ACTOR} repository {{ name isPrivate owner {{ login }} }} \
         baseRefName headRefName headRefOid reviewDecision \
         latestOpinionatedReviews(first: 100) {{ nodes {{ state author {{ login }} }} }} \
         statusCheckRollup {{ state }} mergeable mergeStateStatus \
         reviewRequests(first: 100) {{ nodes {{ {REVIEWER} }} }}"
    )
}

fn request_events() -> String {
    format!(
        "requestEvents: timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 100) \
         {{ nodes {{ ... on ReviewRequestedEvent {{ id createdAt actor {{ login }} {REVIEWER} }} }} }}"
    )
}

/// The `YYYY-MM-DD` (UTC) of `days` before `now`.
fn date_before(now: i64, days: i64) -> String {
    let at = now - days * 86_400;
    jiff::Timestamp::from_second(at)
        .map(|t| t.strftime("%Y-%m-%d").to_string())
        .unwrap_or_else(|_| "1970-01-01".into())
}

fn warning(
    kind: WarningKind,
    token: TokenRole,
    message: String,
    until: Option<i64>,
) -> proto::Warning {
    proto::Warning {
        kind: Lenient::Known(kind),
        token: Some(Lenient::Known(token)),
        message,
        until,
    }
}

/// The value at a path of nested objects.
fn at<'a>(value: &'a Value, path: &[&str]) -> &'a Value {
    path.iter().fold(value, |v, key| &v[*key])
}

fn nodes_of(connection: &Value) -> Vec<Value> {
    connection["nodes"].as_array().cloned().unwrap_or_default()
}

fn has_next(connection: &Value) -> Option<String> {
    (connection["pageInfo"]["hasNextPage"] == true)
        .then(|| {
            connection["pageInfo"]["endCursor"]
                .as_str()
                .map(str::to_string)
        })
        .flatten()
}

/// A scope's run outcome before it is folded into the [`Outcome`].
#[derive(Default)]
struct ScopeRun {
    warnings: Vec<proto::Warning>,
    missing: BTreeSet<&'static str>,
    failed: Option<String>,
}

impl ScopeRun {
    fn permission(&mut self, name: &'static str) {
        self.missing.insert(name);
    }
}

pub struct Run<'a> {
    api: &'a Api,
    plan: &'a Plan,
    rec: Recorder,
    out: Outcome,
    viewer: String,
    prs: Vec<IngestPr>,
    events: Vec<IngestEvent>,
    reactions: Vec<proto::IngestReaction>,
    missing: Vec<String>,
    succeeded: Vec<String>,
    /// Signals this run dealt with or dropped.
    consumed: BTreeSet<String>,
    /// Owner scopes whose token belongs to someone else this run.
    mismatched: BTreeSet<String>,
    /// PR ids the run fetched a status for.
    fetched: BTreeSet<String>,
    /// The classic PAT may not read team membership (`read:org`).
    public_teams_forbidden: bool,
    /// Scopes whose token owner was checked in this run.
    verified: BTreeSet<String>,
    /// Scopes whose token may not read merge queue events.
    queue_refused: BTreeSet<String>,
}

/// Run the fetches the plan names and hand back what they found.
pub async fn run(api: &Api, plan: &Plan) -> Outcome {
    let mut run = Run {
        api,
        plan,
        rec: Recorder::new(plan.now, plan.cost_cap, plan.costs.clone()),
        out: Outcome {
            due: plan.due,
            status_ran: plan
                .scopes
                .iter()
                .filter(|s| s.status_due)
                .map(|s| s.id.clone())
                .collect(),
            ..Outcome::default()
        },
        viewer: String::new(),
        prs: Vec::new(),
        events: Vec::new(),
        reactions: Vec::new(),
        missing: Vec::new(),
        succeeded: Vec::new(),
        consumed: BTreeSet::new(),
        mismatched: BTreeSet::new(),
        fetched: BTreeSet::new(),
        public_teams_forbidden: false,
        verified: BTreeSet::new(),
        queue_refused: BTreeSet::new(),
    };
    run.execute().await;
    run.finish()
}

impl Run<'_> {
    async fn gql(
        &mut self,
        key: &str,
        token: &str,
        query: &str,
        vars: Value,
    ) -> Result<Gql, CallError> {
        let query = query.replacen('{', &format!("{{ {RATE} "), 1);
        self.api
            .graphql(&mut self.rec, key, token, &query, vars)
            .await
    }

    async fn execute(&mut self) {
        let plan = self.plan;
        let Some(classic) = plan.notifications.usable(plan.forced).map(str::to_string) else {
            return;
        };
        // The owner of the notifications token is the reference for every
        // scope token (DESIGN.md, "Tokens").
        let known = plan.notifications.owner.clone();
        let viewer = if plan.due.status || known.is_none() {
            match self
                .gql(
                    NOTIFICATIONS,
                    &classic,
                    "query Viewer { viewer { login } }",
                    json!({}),
                )
                .await
            {
                Ok(answer) => answer.data["viewer"]["login"].as_str().map(str::to_string),
                Err(CallError::Unauthorized | CallError::RateLimited { .. }) => return,
                Err(e) => {
                    self.fail_everything(&format!("Couldn't reach GitHub: {e}"));
                    return;
                }
            }
        } else {
            known
        };
        let Some(viewer) = viewer else {
            self.fail_everything("GitHub did not name the token owner");
            return;
        };
        self.out
            .tokens
            .entry(NOTIFICATIONS.into())
            .or_default()
            .owner = Some(viewer.clone());
        self.viewer = viewer;

        let mut signals: BTreeSet<String> = plan.pending_signals.clone();
        if plan.due.notifications {
            match self.poll_notifications(&classic).await {
                Ok(found) => {
                    self.out.notifications_check = Some(None);
                    signals.extend(found);
                }
                Err(CallError::Unauthorized | CallError::RateLimited { .. }) => {
                    self.out.pending_signals = Some(signals);
                    return;
                }
                // Owner rule: a failed check warns every scope and fetching
                // goes on; a 401 keeps the rule that stops everything.
                Err(e) => {
                    logging::info(format_args!("notifications not fetched: {e}"));
                    self.out.notifications_check =
                        Some(Some(format!("Couldn't check notifications: {e}")));
                }
            }
        }

        let mut public_teams = None;
        if plan.scopes.iter().any(|s| s.public() && s.status_due) {
            public_teams = self.public_teams(&classic).await;
        }

        for scope in &plan.scopes {
            if self.rec.stop.is_some() {
                break;
            }
            let teams = if scope.public() {
                public_teams.clone()
            } else {
                None
            };
            self.scope(scope, &signals, teams).await;
        }
        if plan.due.reactions && self.rec.stop.is_none() {
            self.reactions().await;
        }
        // Signals of scopes this run did not reach wait for the next run;
        // those of disabled or unknown scopes are dropped.
        let left: BTreeSet<String> = signals
            .difference(&self.consumed)
            .filter(|key| plan.enabled_scopes.contains(&self.scope_of_signal(key)))
            .cloned()
            .collect();
        self.out.pending_signals = Some(left);
    }

    /// Every scope gets `fetch_failed` until the next status interval.
    fn fail_everything(&mut self, message: &str) {
        for scope in &self.plan.scopes {
            self.out
                .scopes
                .entry(scope.id.clone())
                .or_default()
                .warnings = Some(vec![warning(
                WarningKind::FetchFailed,
                TokenRole::Notifications,
                message.to_string(),
                Some(self.next_retry()),
            )]);
        }
    }

    /// The next status fetch, which is when a failure is retried.
    fn next_retry(&self) -> i64 {
        self.plan.now + 60 * self.plan.status_interval_minutes.max(1)
    }

    /// DESIGN.md, "Notifications API usage": `all=true`, 50 a page, `since`
    /// the newest seen, `If-Modified-Since` the last `Last-Modified`. The
    /// read state on GitHub is never touched.
    async fn poll_notifications(&mut self, token: &str) -> Result<BTreeSet<String>, CallError> {
        let plan = self.plan;
        let mut path = String::from("/notifications?all=true&per_page=50");
        if let Some(since) = &plan.notif_since {
            path.push_str(&format!("&since={}", encode(since)));
        }
        let mut found = BTreeSet::new();
        let mut modified = plan.notif_last_modified.clone();
        let mut first = true;
        let mut pages = 0;
        loop {
            let answer = self
                .api
                .rest(
                    &mut self.rec,
                    NOTIFICATIONS,
                    token,
                    &path,
                    if first { modified.as_deref() } else { None },
                )
                .await?;
            if let Some(interval) = answer
                .header("x-poll-interval")
                .and_then(|v| v.trim().parse().ok())
            {
                self.out.poll_interval = Some(interval);
            }
            if first && let Some(last) = answer.header("last-modified") {
                modified = Some(last.to_string());
            }
            first = false;
            if answer.status == 304 {
                break;
            }
            let (prs, newest) = convert::notified_prs(&answer.body);
            for (owner, repo, number) in prs {
                found.insert(pr_key(&owner, &repo, number));
            }
            if let Some(newest) = newest
                && self.out.notif_since.as_deref().is_none_or(|old| {
                    crate::github::parse_time(old) < crate::github::parse_time(&newest)
                })
            {
                self.out.notif_since = Some(newest);
            }
            pages += 1;
            match answer.header("link").and_then(convert::next_link) {
                Some(next) if pages < MAX_PAGES => path = next,
                Some(_) => {
                    logging::warn(format_args!("more than {MAX_PAGES} pages of notifications"));
                    break;
                }
                None => break,
            }
        }
        self.out.notif_last_modified = modified;
        Ok(found)
    }

    /// The viewer's teams across organizations, read with the classic PAT
    /// (`read:org`) for Public.
    async fn public_teams(&mut self, token: &str) -> Option<Vec<TeamRec>> {
        let mut path = "/user/teams?per_page=100".to_string();
        let mut teams = Vec::new();
        for page in 1.. {
            match self
                .api
                .rest(&mut self.rec, NOTIFICATIONS, token, &path, None)
                .await
            {
                Ok(answer) => {
                    teams.extend(
                        answer
                            .body
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|team| {
                                Some(TeamRec {
                                    database_id: team["id"].as_i64()?,
                                    slug: team["slug"].as_str()?.to_string(),
                                })
                            }),
                    );
                    match answer.header("link").and_then(convert::next_link) {
                        Some(next) if page < MAX_PAGES => path = next,
                        Some(_) => {
                            logging::warn(format_args!("more than {MAX_PAGES} pages of teams"));
                            break;
                        }
                        None => break,
                    }
                }
                Err(CallError::Forbidden { .. }) => {
                    self.public_teams_forbidden = true;
                    return None;
                }
                Err(e) => {
                    logging::info(format_args!(
                        "teams of the notifications token not read: {e}"
                    ));
                    return None;
                }
            }
        }
        Some(teams)
    }

    /// DESIGN.md, "Tokens": the owner is checked on every run. A run without
    /// the status fetch asks the token who it belongs to.
    async fn owner_matches(&mut self, sp: &ScopePlan, token: &str) -> Result<bool, CallError> {
        if !self.verified.contains(&sp.id) {
            let answer = self
                .gql(
                    &sp.token_key,
                    token,
                    "query Who { viewer { login } }",
                    json!({}),
                )
                .await?;
            let login = answer.data["viewer"]["login"].as_str().map(str::to_string);
            self.out
                .tokens
                .entry(sp.token_key.clone())
                .or_default()
                .owner = login.clone();
            self.verified.insert(sp.id.clone());
            if login.is_some_and(|l| !l.eq_ignore_ascii_case(&self.viewer)) {
                self.mismatched.insert(sp.id.clone());
            }
        }
        Ok(!self.mismatched.contains(&sp.id))
    }

    fn scope_of_signal(&self, key: &str) -> String {
        let owner = key.split('/').next().unwrap_or_default();
        if self.plan.registered_owners.contains(owner) {
            self.plan
                .enabled_scopes
                .iter()
                .find(|id| id.eq_ignore_ascii_case(owner))
                .cloned()
                .unwrap_or_else(|| owner.to_string())
        } else {
            PUBLIC.to_string()
        }
    }

    async fn scope(
        &mut self,
        sp: &ScopePlan,
        signals: &BTreeSet<String>,
        public_teams: Option<Vec<TeamRec>>,
    ) {
        let plan = self.plan;
        let mine: Vec<String> = signals
            .iter()
            .filter(|key| self.scope_of_signal(key) == sp.id)
            .cloned()
            .collect();
        let retries: Vec<String> = plan
            .retries
            .keys()
            .filter(|id| {
                plan.prs
                    .get(*id)
                    .is_some_and(|pr| pr.scope.as_deref() == Some(&sp.id))
            })
            .cloned()
            .collect();
        let Some(token) = sp.token.usable(plan.forced).map(str::to_string) else {
            // DESIGN.md, "Fetch success and failure": a scope that cannot be
            // fetched ignores its notifications.
            self.consumed.extend(mine);
            return;
        };
        if !sp.status_due && mine.is_empty() && retries.is_empty() {
            return;
        }
        let mut run = ScopeRun::default();
        if sp.status_due {
            self.rec.counted = Some(0);
        }
        let result = self
            .scope_inner(sp, &token, &mine, &retries, public_teams, &mut run)
            .await;
        if let Some(cost) = self.rec.counted.take() {
            *self.out.cost_per_poll.get_or_insert(0) += cost;
        }
        match result {
            // Notified PRs of a failed scope wait for the next run, like PRs
            // whose events are fetched again.
            Ok(()) => self.consumed.extend(mine),
            Err(CallError::RateLimited { .. }) => return,
            Err(CallError::Unauthorized) => {
                // A stopped scope ignores its notifications.
                self.consumed.extend(mine);
                self.out.scopes.entry(sp.id.clone()).or_default().warnings = Some(Vec::new());
                return;
            }
            Err(e) => run.failed = Some(format!("Couldn't reach GitHub: {e}")),
        }
        if self.queue_refused.contains(&sp.id) {
            run.permission("Merge queue");
        }
        let mut warnings = run.warnings;
        // Public's team membership is read with the classic PAT.
        if sp.public() && self.public_teams_forbidden {
            warnings.push(warning(
                WarningKind::PermissionMissing,
                TokenRole::Notifications,
                "Missing permission: read:org".into(),
                None,
            ));
        }
        if !run.missing.is_empty() {
            let names: Vec<&str> = run.missing.iter().copied().collect();
            warnings.push(warning(
                WarningKind::PermissionMissing,
                TokenRole::Scope,
                format!("Missing permission: {}", names.join(", ")),
                None,
            ));
        }
        if let Some(message) = run.failed {
            warnings.push(warning(
                WarningKind::FetchFailed,
                TokenRole::Scope,
                message,
                Some(self.next_retry()),
            ));
        } else if sp.status_due && !self.mismatched.contains(&sp.id) {
            self.succeeded.push(sp.id.clone());
        }
        if sp.status_due || !warnings.is_empty() {
            self.out.scopes.entry(sp.id.clone()).or_default().warnings = Some(warnings);
        }
    }

    async fn scope_inner(
        &mut self,
        sp: &ScopePlan,
        token: &str,
        signals: &[String],
        retries: &[String],
        public_teams: Option<Vec<TeamRec>>,
        run: &mut ScopeRun,
    ) -> Result<(), CallError> {
        let plan = self.plan;
        let key = sp.token_key.clone();
        let mut kind = sp.kind;
        let mut teams = sp.teams.clone();
        if let Some(found) = public_teams {
            teams = found.clone();
            self.out.scopes.entry(sp.id.clone()).or_default().teams = Some(found);
        }

        // The owner's kind decides the search qualifier: resolve it first.
        if let Some(owner) = sp.owner.clone().filter(|_| kind.is_none()) {
            let answer = self
                .gql(
                    &key,
                    token,
                    "query Owner($owner: String!) { owner: repositoryOwner(login: $owner) { __typename login } }",
                    json!({"owner": owner}),
                )
                .await?;
            kind = owner_kind(&answer.data["owner"]);
            let obs = self.out.scopes.entry(sp.id.clone()).or_default();
            obs.kind = kind;
            obs.name = answer.data["owner"]["login"].as_str().map(str::to_string);
            if kind.is_none() {
                return Err(CallError::Other(format!("owner {owner} not found")));
            }
        }

        let mut targets: BTreeSet<String> = BTreeSet::new();
        let mut found: BTreeSet<String> = BTreeSet::new();
        if sp.status_due {
            let qualifier = match (&sp.owner, kind) {
                (None, _) => "is:public".to_string(),
                (Some(owner), Some(ScopeKind::User)) => format!("user:{owner}"),
                (Some(owner), _) => format!("org:{owner}"),
            };
            let since = date_before(plan.now, plan.drop_after_days);
            let queries = convert::search_queries(&qualifier, &since, plan.include_team_requests);
            let with_teams = sp.owner.is_some() && kind == Some(ScopeKind::Org);
            let mut text =
                String::from("query Scope($q0: String!, $q1: String!, $q2: String!, $q3: String!");
            if sp.owner.is_some() {
                text.push_str(", $owner: String!");
            }
            if with_teams {
                text.push_str(", $viewer: String!");
            }
            text.push_str(") { viewer { login } ");
            if sp.owner.is_some() {
                text.push_str("owner: repositoryOwner(login: $owner) { __typename login } ");
            }
            if with_teams {
                text.push_str(
                    "org: organization(login: $owner) { teams(first: 100, userLogins: [$viewer]) { pageInfo { hasNextPage endCursor } nodes { databaseId slug } } } ",
                );
            }
            for i in 0..4 {
                text.push_str(&format!(
                    "s{i}: search(type: ISSUE, query: $q{i}, first: 100) {{ {SEARCH_NODES} }} "
                ));
            }
            text.push('}');
            let mut vars =
                json!({"q0": queries[0], "q1": queries[1], "q2": queries[2], "q3": queries[3]});
            if let Some(owner) = &sp.owner {
                vars["owner"] = json!(owner);
            }
            if with_teams {
                vars["viewer"] = json!(self.viewer);
            }
            let answer = self.gql(&key, token, &text, vars).await?;
            let login = answer.data["viewer"]["login"].as_str().map(str::to_string);
            self.out.tokens.entry(key.clone()).or_default().owner = login.clone();
            self.verified.insert(sp.id.clone());
            if login.is_some_and(|l| !l.eq_ignore_ascii_case(&self.viewer)) {
                // DESIGN.md, "Tokens": a token of another account stops the scope.
                self.mismatched.insert(sp.id.clone());
                return Ok(());
            }
            if sp.owner.is_some() {
                let obs = self.out.scopes.entry(sp.id.clone()).or_default();
                if let Some(name) = answer.data["owner"]["login"].as_str() {
                    obs.name = Some(name.to_string());
                }
                let k = owner_kind(&answer.data["owner"]);
                if k.is_some() {
                    obs.kind = k;
                }
            }
            if with_teams {
                if answer
                    .errors
                    .iter()
                    .any(|e| e.is_permission() && e.path.first().is_some_and(|p| p == "org"))
                {
                    run.permission("Members");
                } else {
                    let first = answer.data["org"]["teams"].clone();
                    let text = "query TeamsPage($owner: String!, $viewer: String!, $after: String!) { org: organization(login: $owner) { teams(first: 100, after: $after, userLogins: [$viewer]) { pageInfo { hasNextPage endCursor } nodes { databaseId slug } } } }";
                    let vars = json!({"owner": sp.owner, "viewer": self.viewer});
                    let all = self
                        .pages_at(&key, token, text, vars, &["org", "teams"], &first)
                        .await?;
                    let list: Vec<TeamRec> = all
                        .iter()
                        .filter_map(|t| {
                            Some(TeamRec {
                                database_id: t["databaseId"].as_i64()?,
                                slug: t["slug"].as_str()?.to_string(),
                            })
                        })
                        .collect();
                    teams = list.clone();
                    self.out.scopes.entry(sp.id.clone()).or_default().teams = Some(list);
                }
            }
            if let Some(e) = answer
                .errors
                .iter()
                .find(|e| e.path.first().is_some_and(|p| p.starts_with('s')) && !e.is_permission())
            {
                return Err(CallError::Other(format!("search failed: {}", e.message)));
            }
            let exclude = if sp.public() {
                plan.registered_owners.clone()
            } else {
                BTreeSet::new()
            };
            for (i, query) in queries.iter().enumerate() {
                let connection = answer.data[format!("s{i}")].clone();
                found.extend(convert::search_ids(&connection, &exclude));
                let mut cursor = has_next(&connection);
                let mut pages = 1;
                while let Some(after) = cursor {
                    if pages >= MAX_PAGES {
                        logging::warn(format_args!(
                            "search of {} has more than {MAX_PAGES} pages",
                            sp.id
                        ));
                        break;
                    }
                    let page = self
                        .gql(
                            &key,
                            token,
                            &format!("query SearchPage($q: String!, $after: String!) {{ s: search(type: ISSUE, query: $q, first: 100, after: $after) {{ {SEARCH_NODES} }} }}"),
                            json!({"q": query, "after": after}),
                        )
                        .await?;
                    found.extend(convert::search_ids(&page.data["s"], &exclude));
                    cursor = has_next(&page.data["s"]);
                    pages += 1;
                }
            }
            targets.extend(found.iter().cloned());
            for pr in plan.prs.values() {
                if pr.scope.as_deref() == Some(&sp.id) && (pr.watched || pr.unreadable) {
                    targets.insert(pr.id.clone());
                }
            }
        } else if !self.owner_matches(sp, token).await? {
            return Ok(());
        }

        // Notified PRs: their ids, resolved once and remembered.
        let mut signaled: BTreeSet<String> = BTreeSet::new();
        let mut unresolved: Vec<String> = Vec::new();
        for key_text in signals {
            match plan.pr_ids.get(key_text) {
                Some(id) => {
                    signaled.insert(id.clone());
                }
                None => unresolved.push(key_text.clone()),
            }
        }
        for chunk in unresolved.chunks(NODES_PER_QUERY) {
            let mut text = String::from("query Resolve(");
            let mut body = String::new();
            let mut vars = json!({});
            for (i, key_text) in chunk.iter().enumerate() {
                let Some((owner, rest)) = key_text.split_once('/') else {
                    continue;
                };
                let Some((repo, number)) = rest.split_once('#') else {
                    continue;
                };
                let Ok(number) = number.parse::<i64>() else {
                    continue;
                };
                text.push_str(&format!("$o{i}: String!, $r{i}: String!, $n{i}: Int!, "));
                body.push_str(&format!(
                    "p{i}: repository(owner: $o{i}, name: $r{i}) {{ pullRequest(number: $n{i}) {{ id }} }} "
                ));
                vars[format!("o{i}")] = json!(owner);
                vars[format!("r{i}")] = json!(repo);
                vars[format!("n{i}")] = json!(number);
            }
            if body.is_empty() {
                continue;
            }
            let text = format!("{}) {{ {body} }}", text.trim_end_matches(", "));
            let answer = self.gql(&key, token, &text, vars).await?;
            for (i, key_text) in chunk.iter().enumerate() {
                if let Some(id) = answer.data[format!("p{i}")]["pullRequest"]["id"].as_str() {
                    self.out.pr_ids.push((key_text.clone(), id.to_string()));
                    signaled.insert(id.to_string());
                }
            }
        }
        targets.extend(signaled.iter().cloned());
        targets.extend(retries.iter().cloned());

        // Status of every target, 100 at a time.
        let ids: Vec<String> = targets.into_iter().collect();
        let mut nodes: BTreeMap<String, Value> = BTreeMap::new();
        for chunk in ids.chunks(NODES_PER_QUERY) {
            let text = format!(
                "query Status($ids: [ID!]!) {{ nodes(ids: $ids) {{ ... on PullRequest {{ {} }} }} }}",
                pr_status_fields()
            );
            let answer = self.gql(&key, token, &text, json!({"ids": chunk})).await?;
            for e in &answer.errors {
                if e.is_permission() {
                    match e.path.get(2).map(String::as_str) {
                        Some("statusCheckRollup") => run.permission("Commit statuses"),
                        Some("baseRef") => run.permission("Contents"),
                        _ => run.permission("Pull requests"),
                    }
                } else if !e.is_not_found() {
                    return Err(CallError::Other(format!("status failed: {}", e.message)));
                }
            }
            let list = answer.data["nodes"].as_array().cloned().unwrap_or_default();
            for (id, node) in chunk.iter().zip(list) {
                if node.is_null() {
                    self.missing.push(id.clone());
                } else {
                    nodes.insert(id.clone(), node);
                }
            }
        }
        // Behind base: one aliased `compare` per open PR, against the head
        // commit, which works for forks too (checked by the orchestrator with
        // gh on rust-lang/rust#157885: behindBy matched REST).
        let comparable: Vec<(String, String)> = nodes
            .iter()
            .filter(|(_, n)| n["state"] == "OPEN")
            .map(|(id, n)| {
                (
                    id.clone(),
                    n["headRefOid"].as_str().unwrap_or_default().to_string(),
                )
            })
            .collect();
        let mut behind: BTreeMap<String, i64> = BTreeMap::new();
        for chunk in comparable.chunks(NODES_PER_QUERY) {
            let mut text = String::from("query Compare(");
            let mut body = String::new();
            let mut vars = json!({});
            for (i, (id, head)) in chunk.iter().enumerate() {
                text.push_str(&format!("$i{i}: ID!, $h{i}: String!, "));
                body.push_str(&format!(
                    "c{i}: node(id: $i{i}) {{ ... on PullRequest {{ baseRef {{ compare(headRef: $h{i}) {{ behindBy }} }} }} }} "
                ));
                vars[format!("i{i}")] = json!(id);
                vars[format!("h{i}")] = json!(head);
            }
            let text = format!("{}) {{ {body} }}", text.trim_end_matches(", "));
            let answer = self.gql(&key, token, &text, vars).await?;
            if answer.errors.iter().any(|e| e.is_permission()) {
                run.permission("Contents");
            }
            for (i, (id, _)) in chunk.iter().enumerate() {
                if let Some(n) =
                    answer.data[format!("c{i}")]["baseRef"]["compare"]["behindBy"].as_i64()
                {
                    behind.insert(id.clone(), n);
                }
            }
        }
        // Public: reviewers the fine-grained PAT cannot see, read again with
        // the classic PAT (docs/tasks/M2.md, "Team review requests").
        let viewer = self.viewer.clone();
        let ctx = Ctx {
            viewer: &viewer,
            teams: &teams,
        };
        let mut reread: BTreeMap<String, Value> = BTreeMap::new();
        if sp.public() {
            let hidden: Vec<String> = nodes
                .iter()
                .filter(|(_, n)| convert::requested(&n["reviewRequests"], ctx).hidden)
                .map(|(id, _)| id.clone())
                .collect();
            if !hidden.is_empty() {
                reread = self.reread_requests(&hidden).await?;
            }
        }

        // Failed check names, for the viewer's open PRs that just failed.
        let mut failed_names: BTreeMap<String, Option<String>> = BTreeMap::new();
        let newly_failed: Vec<(String, Value)> = nodes
            .iter()
            .filter(|(id, n)| {
                ctx.is_me(n["author"]["login"].as_str().unwrap_or_default())
                    && n["state"] == "OPEN"
                    && matches!(
                        n["statusCheckRollup"]["state"].as_str(),
                        Some("FAILURE" | "ERROR")
                    )
                    && plan
                        .prs
                        .get(*id)
                        .is_some_and(|pr| pr.checks != crate::model::Checks::Failed)
            })
            .map(|(id, n)| (id.clone(), n.clone()))
            .collect();
        if !newly_failed.is_empty() {
            let contexts = self.contexts(&key, token, &newly_failed).await?;
            for (id, node) in &newly_failed {
                let name = self
                    .failed_check(&key, token, node, contexts.get(id), run)
                    .await?;
                failed_names.insert(id.clone(), name);
            }
        }

        for (id, node) in &nodes {
            let previous = plan.prs.get(id).map(|pr| (pr.base_status, pr.mergeable));
            let extra = StatusExtra {
                behind_by: behind.get(id).copied(),
                previous,
                failed_check: failed_names.get(id).cloned().flatten(),
                review_requests: reread.get(id).map(|r| r["reviewRequests"].clone()),
            };
            if let Some(pr) = convert::pr_values(node, &extra, ctx) {
                self.fetched.insert(pr.id.clone());
                self.prs.push(pr);
            }
        }

        // Events: notified PRs, PRs updated since the last status, PRs to
        // fetch again, and newly found ones.
        let mut wanted: BTreeSet<String> = signaled.clone();
        wanted.extend(retries.iter().cloned());
        for (id, node) in &nodes {
            let updated = crate::github::parse_time(node["updatedAt"].as_str().unwrap_or_default())
                .unwrap_or(0);
            match plan.prs.get(id) {
                None => {
                    wanted.insert(id.clone());
                }
                Some(pr) if pr.updated_at != updated || (!pr.collected && pr.watched) => {
                    wanted.insert(id.clone());
                }
                _ => {}
            }
        }
        wanted.retain(|id| nodes.contains_key(id));
        self.events_of(sp, &key, token, &wanted, &reread, ctx, run)
            .await?;
        Ok(())
    }

    async fn reread_requests(
        &mut self,
        ids: &[String],
    ) -> Result<BTreeMap<String, Value>, CallError> {
        let Some(classic) = self
            .plan
            .notifications
            .usable(self.plan.forced)
            .map(str::to_string)
        else {
            return Ok(BTreeMap::new());
        };
        let mut out = BTreeMap::new();
        for chunk in ids.chunks(NODES_PER_QUERY) {
            let text = format!(
                "query Requests($ids: [ID!]!) {{ nodes(ids: $ids) {{ ... on PullRequest {{ id reviewRequests(first: 100) {{ nodes {{ {REVIEWER} }} }} {} }} }} }}",
                request_events()
            );
            let answer = self
                .gql(NOTIFICATIONS, &classic, &text, json!({"ids": chunk}))
                .await?;
            for node in answer.data["nodes"].as_array().into_iter().flatten() {
                if let Some(id) = node["id"].as_str() {
                    out.insert(id.to_string(), node.clone());
                }
            }
        }
        Ok(out)
    }

    /// `StatusContext` entries of the rollups. CheckRun entries are
    /// FORBIDDEN for a fine-grained PAT; those errors are expected here.
    async fn contexts(
        &mut self,
        key: &str,
        token: &str,
        prs: &[(String, Value)],
    ) -> Result<BTreeMap<String, Value>, CallError> {
        let ids: Vec<&String> = prs.iter().map(|(id, _)| id).collect();
        let text = "query Contexts($ids: [ID!]!) { nodes(ids: $ids) { ... on PullRequest { id statusCheckRollup { contexts(first: 100) { nodes { __typename ... on StatusContext { context state } } } } } } }";
        let answer = self.gql(key, token, text, json!({"ids": ids})).await?;
        let mut out = BTreeMap::new();
        for node in answer.data["nodes"].as_array().into_iter().flatten() {
            if let Some(id) = node["id"].as_str() {
                out.insert(
                    id.to_string(),
                    node["statusCheckRollup"]["contexts"].clone(),
                );
            }
        }
        Ok(out)
    }

    /// docs/tasks/M2.md, "Failed check names".
    async fn failed_check(
        &mut self,
        key: &str,
        token: &str,
        node: &Value,
        contexts: Option<&Value>,
        run: &mut ScopeRun,
    ) -> Result<Option<String>, CallError> {
        let owner = node["repository"]["owner"]["login"]
            .as_str()
            .unwrap_or_default();
        let repo = node["repository"]["name"].as_str().unwrap_or_default();
        let sha = node["headRefOid"].as_str().unwrap_or_default();
        let base = format!("/repos/{}/{}/actions/runs", encode(owner), encode(repo));
        let runs = match self
            .api
            .rest(
                &mut self.rec,
                key,
                token,
                &format!("{base}?head_sha={}&per_page=100", encode(sha)),
                None,
            )
            .await
        {
            Ok(answer) => answer.body,
            Err(CallError::Forbidden { .. }) => {
                run.permission("Actions");
                Value::Null
            }
            Err(e @ (CallError::RateLimited { .. } | CallError::Unauthorized)) => return Err(e),
            Err(e) => {
                logging::info(format_args!("workflow runs not read: {e}"));
                Value::Null
            }
        };
        let mut jobs = Vec::new();
        for run_id in convert::runs_to_read(&runs) {
            match self
                .api
                .rest(
                    &mut self.rec,
                    key,
                    token,
                    &format!("{base}/{run_id}/jobs?per_page=100"),
                    None,
                )
                .await
            {
                Ok(answer) => jobs.push((run_id, answer.body)),
                Err(CallError::Forbidden { .. }) => run.permission("Actions"),
                Err(e @ (CallError::RateLimited { .. } | CallError::Unauthorized)) => {
                    return Err(e);
                }
                Err(e) => logging::info(format_args!("jobs not read: {e}")),
            }
        }
        Ok(convert::failed_check_name(
            &runs,
            &jobs,
            contexts.unwrap_or(&Value::Null),
        ))
    }

    #[allow(clippy::too_many_arguments)]
    async fn events_of(
        &mut self,
        sp: &ScopePlan,
        key: &str,
        token: &str,
        wanted: &BTreeSet<String>,
        reread: &BTreeMap<String, Value>,
        ctx: Ctx<'_>,
        run: &mut ScopeRun,
    ) -> Result<(), CallError> {
        let plan = self.plan;
        let scope_since = sp.since();
        let zero_after = sp.reaction_zero_after();
        let mut recorded: BTreeMap<String, i64> = plan
            .threads
            .values()
            .map(|t| (t.id.clone(), t.from_at))
            .collect();

        // Collect what a newly found or returning PR already holds.
        for id in wanted {
            // A new PR, or a watched one that came back: docs/tasks/M2.md.
            let collect = plan
                .prs
                .get(id)
                .is_none_or(|pr| pr.watched && !pr.collected);
            if !collect {
                continue;
            }
            match self.collect(key, token, id).await {
                Ok(Some(mut node)) => {
                    if let Some(again) = reread.get(id) {
                        node["reviewRequests"] = again["reviewRequests"].clone();
                        node["requestEvents"] = again["requestEvents"].clone();
                    } else if sp.public()
                        && convert::has_hidden_reviewers(&nodes_of(&node["requestEvents"]))
                    {
                        let again = self.reread_requests(std::slice::from_ref(id)).await?;
                        if let Some(again) = again.get(id) {
                            node["reviewRequests"] = again["reviewRequests"].clone();
                            node["requestEvents"] = again["requestEvents"].clone();
                        }
                    }
                    let found = convert::collect(&node, zero_after, ctx);
                    for thread in &found.threads {
                        let entry = recorded.entry(thread.id.clone()).or_insert(thread.from_at);
                        *entry = (*entry).min(thread.from_at);
                    }
                    self.out.threads.extend(found.threads);
                    self.out.own.extend(found.own);
                    self.events.extend(found.ongoing);
                    self.out.collected.push(id.clone());
                }
                Ok(None) => {}
                Err(e @ (CallError::RateLimited { .. } | CallError::Unauthorized)) => {
                    return Err(e);
                }
                Err(e) => {
                    logging::info(format_args!("comments of {id} not collected: {e}"));
                    self.out
                        .retries_failed
                        .push((id.clone(), self.since_of(id, scope_since)));
                }
            }
        }

        // Then the events since the window start, batched by `since`.
        let mut by_since: BTreeMap<i64, Vec<String>> = BTreeMap::new();
        for id in wanted {
            by_since
                .entry(self.since_of(id, scope_since))
                .or_default()
                .push(id.clone());
        }
        for (since, ids) in by_since {
            for chunk in ids.chunks(EVENT_BATCH) {
                let text = format!(
                    "query Events($ids: [ID!]!, $since: DateTime!) {{ nodes(ids: $ids) {{ ... on PullRequest {{ \
                     id url createdAt bodyHTML bodyText author {ACTOR} \
                     timelineItems(since: $since, first: 100, itemTypes: {ITEM_TYPES}) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {} }} }} \
                     reviewThreads(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ id comments(last: 100) {{ nodes {{ {COMMENT} }} }} }} }} \
                     }} }} }}",
                    timeline_nodes()
                );
                let answer = match self
                    .gql(
                        key,
                        token,
                        &text,
                        json!({"ids": chunk, "since": format_time(since)}),
                    )
                    .await
                {
                    Ok(answer) => answer,
                    Err(e @ (CallError::RateLimited { .. } | CallError::Unauthorized)) => {
                        return Err(e);
                    }
                    Err(e) => {
                        logging::info(format_args!("events not fetched: {e}"));
                        for id in chunk {
                            self.out.retries_failed.push((id.clone(), since));
                        }
                        continue;
                    }
                };
                // M2.md, "Tokens and the Keychain": what the token may not
                // read is a warning, and the rest is still used.
                for e in answer.errors.iter().filter(|e| e.is_permission()) {
                    run.permission(if e.path.iter().any(|p| p == "timelineItems") {
                        "Merge queue"
                    } else {
                        "Pull requests"
                    });
                }
                let list = answer.data["nodes"].as_array().cloned().unwrap_or_default();
                for (index, (id, node)) in chunk.iter().zip(list).enumerate() {
                    let broken = answer.errors.iter().any(|e| {
                        !e.is_permission()
                            && !e.is_not_found()
                            && e.path.get(1).is_some_and(|p| *p == index.to_string())
                    });
                    if node.is_null() || broken {
                        if broken {
                            self.out.retries_failed.push((id.clone(), since));
                        }
                        continue;
                    }
                    match self
                        .events_of_pr(
                            sp,
                            key,
                            token,
                            node,
                            since,
                            zero_after,
                            &recorded,
                            reread.get(id),
                            ctx,
                        )
                        .await
                    {
                        Ok(output) => {
                            for thread in &output.threads {
                                recorded.insert(thread.id.clone(), thread.from_at);
                            }
                            self.out.threads.extend(output.threads);
                            self.out.own.extend(output.own);
                            self.events.extend(output.events);
                            self.out.retries_ok.push(id.clone());
                        }
                        Err(e @ (CallError::RateLimited { .. } | CallError::Unauthorized)) => {
                            return Err(e);
                        }
                        Err(CallError::Forbidden { .. }) => run.permission("Merge queue"),
                        Err(e) => {
                            logging::info(format_args!("events of {id} not fetched: {e}"));
                            self.out.retries_failed.push((id.clone(), since));
                        }
                    }
                }
            }
        }
        Ok(())
    }

    fn since_of(&self, id: &str, scope_since: i64) -> i64 {
        self.plan
            .retries
            .get(id)
            .map_or(scope_since, |since| (*since).min(scope_since))
    }

    #[allow(clippy::too_many_arguments)]
    async fn events_of_pr(
        &mut self,
        sp: &ScopePlan,
        key: &str,
        token: &str,
        node: Value,
        since: i64,
        zero_after: i64,
        recorded: &BTreeMap<String, i64>,
        reread: Option<&Value>,
        ctx: Ctx<'_>,
    ) -> Result<convert::EventOutput, CallError> {
        let id = node["id"].as_str().unwrap_or_default().to_string();
        let mut timeline = nodes_of(&node["timelineItems"]);
        let mut cursor = has_next(&node["timelineItems"]);
        let mut pages = 1;
        while let Some(after) = cursor {
            if pages >= MAX_PAGES {
                logging::warn(format_args!(
                    "timeline of {id} has more than {MAX_PAGES} pages"
                ));
                break;
            }
            let text = format!(
                "query TimelinePage($id: ID!, $since: DateTime!, $after: String!) {{ node(id: $id) {{ ... on PullRequest {{ \
                 timelineItems(since: $since, first: 100, after: $after, itemTypes: {ITEM_TYPES}) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {} }} }} }} }} }}",
                timeline_nodes()
            );
            let page = self
                .gql(
                    key,
                    token,
                    &text,
                    json!({"id": id, "since": format_time(since), "after": after}),
                )
                .await?;
            let connection = &page.data["node"]["timelineItems"];
            timeline.extend(nodes_of(connection));
            cursor = has_next(connection);
            pages += 1;
        }
        let mut threads = nodes_of(&node["reviewThreads"]);
        let mut cursor = has_next(&node["reviewThreads"]);
        let mut pages = 1;
        while let Some(after) = cursor {
            if pages >= MAX_PAGES {
                logging::warn(format_args!(
                    "review threads of {id} have more than {MAX_PAGES} pages"
                ));
                break;
            }
            let text = format!(
                "query ThreadsPage($id: ID!, $after: String!) {{ node(id: $id) {{ ... on PullRequest {{ \
                 reviewThreads(first: 100, after: $after) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ id comments(last: 100) {{ nodes {{ {COMMENT} }} }} }} }} }} }} }}"
            );
            let page = self
                .gql(key, token, &text, json!({"id": id, "after": after}))
                .await?;
            let connection = &page.data["node"]["reviewThreads"];
            threads.extend(nodes_of(connection));
            cursor = has_next(connection);
            pages += 1;
        }

        // Public: review requests the fine-grained PAT returned without a
        // reviewer come from the classic PAT.
        if sp.public() && convert::has_hidden_reviewers(&timeline) {
            let again = match reread {
                Some(again) => Some(again.clone()),
                None => self
                    .reread_requests(std::slice::from_ref(&id))
                    .await?
                    .remove(&id),
            };
            if let Some(again) = again {
                timeline.retain(|item| item["__typename"] != "ReviewRequestedEvent");
                timeline.extend(nodes_of(&again["requestEvents"]).into_iter().map(|mut e| {
                    e["__typename"] = json!("ReviewRequestedEvent");
                    e
                }));
            }
        }

        let mut input = EventInput {
            pr: &node,
            timeline: &timeline,
            threads: &threads,
            merge_queue: None,
            since,
            zero_after,
            recorded,
        };
        let output = convert::events(&input, ctx);
        if !output.needs_merge_queue {
            return Ok(output);
        }
        let text = "query MergeQueue($id: ID!) { node(id: $id) { ... on PullRequest { timelineItems(first: 100, itemTypes: [ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT]) { nodes { __typename ... on AddedToMergeQueueEvent { id createdAt actor { login } } ... on RemovedFromMergeQueueEvent { id createdAt actor { login } reason } } } } } }";
        // A refused queue read is a permission warning: the other events
        // stay, and only the removals that needed the queue are left out.
        let answer = match self.gql(key, token, text, json!({"id": id})).await {
            Ok(answer) if !answer.errors.iter().any(|e| e.is_permission()) => answer,
            Ok(_) | Err(CallError::Forbidden { .. }) => {
                self.queue_refused.insert(sp.id.clone());
                return Ok(output);
            }
            Err(e) => return Err(e),
        };
        let queue = nodes_of(&answer.data["node"]["timelineItems"]);
        input.merge_queue = Some(&queue);
        Ok(convert::events(&input, ctx))
    }

    /// docs/tasks/M2.md, "Collecting a newly found PR": every connection
    /// without `since`, pages followed up to ten per connection.
    async fn collect(
        &mut self,
        key: &str,
        token: &str,
        id: &str,
    ) -> Result<Option<Value>, CallError> {
        let text = format!(
            "query Collect($id: ID!) {{ node(id: $id) {{ ... on PullRequest {{ \
             id url createdAt bodyHTML bodyText author {ACTOR} \
             comments(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {COMMENT} }} }} \
             reviews(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ id url createdAt submittedAt state bodyText bodyHTML author {ACTOR} }} }} \
             reviewThreads(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ id comments(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {COMMENT} }} }} }} }} \
             reviewRequests(first: 100) {{ nodes {{ {REVIEWER} }} }} {} }} }} }}",
            request_events()
        );
        let answer = self.gql(key, token, &text, json!({"id": id})).await?;
        let mut node = answer.data["node"].clone();
        if node.is_null() {
            return Ok(None);
        }
        for (field, fields) in [
            ("comments", COMMENT.to_string()),
            (
                "reviews",
                format!("id url createdAt submittedAt state bodyText bodyHTML author {ACTOR}"),
            ),
            (
                "reviewThreads",
                format!(
                    "id comments(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {COMMENT} }} }}"
                ),
            ),
        ] {
            let more = self
                .pages(key, token, id, "PullRequest", field, &fields, &node[field])
                .await?;
            node[field]["nodes"] = json!(more);
        }
        let threads = nodes_of(&node["reviewThreads"]);
        let mut full = Vec::new();
        for mut thread in threads {
            let thread_id = thread["id"].as_str().unwrap_or_default().to_string();
            let comments = self
                .pages(
                    key,
                    token,
                    &thread_id,
                    "PullRequestReviewThread",
                    "comments",
                    COMMENT,
                    &thread["comments"],
                )
                .await?;
            thread["comments"]["nodes"] = json!(comments);
            full.push(thread);
        }
        node["reviewThreads"]["nodes"] = json!(full);
        Ok(Some(node))
    }

    /// Every node of a connection, following `endCursor` from `first`.
    #[allow(clippy::too_many_arguments)]
    async fn pages(
        &mut self,
        key: &str,
        token: &str,
        owner_id: &str,
        owner_type: &str,
        field: &str,
        fields: &str,
        first: &Value,
    ) -> Result<Vec<Value>, CallError> {
        let mut all = nodes_of(first);
        let mut cursor = has_next(first);
        let mut pages = 1;
        while let Some(after) = cursor {
            if pages >= MAX_PAGES {
                logging::warn(format_args!(
                    "{field} of {owner_id} has more than {MAX_PAGES} pages; the rest is not read"
                ));
                break;
            }
            let text = format!(
                "query Page($id: ID!, $after: String!) {{ node(id: $id) {{ ... on {owner_type} {{ \
                 {field}(first: 100, after: $after) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {fields} }} }} }} }} }}"
            );
            let page = self
                .gql(key, token, &text, json!({"id": owner_id, "after": after}))
                .await?;
            let connection = at(&page.data, &["node", field]).clone();
            all.extend(nodes_of(&connection));
            cursor = has_next(&connection);
            pages += 1;
        }
        Ok(all)
    }

    /// Every node of a connection at `path` of a query that takes `$after`,
    /// following `endCursor` from `first`, ten pages at most.
    async fn pages_at(
        &mut self,
        key: &str,
        token: &str,
        query: &str,
        vars: Value,
        path: &[&str],
        first: &Value,
    ) -> Result<Vec<Value>, CallError> {
        let mut all = nodes_of(first);
        let mut cursor = has_next(first);
        let mut pages = 1;
        while let Some(after) = cursor {
            if pages >= MAX_PAGES {
                logging::warn(format_args!(
                    "{} has more than {MAX_PAGES} pages; the rest is not read",
                    path.join(".")
                ));
                break;
            }
            let mut vars = vars.clone();
            vars["after"] = json!(after);
            let page = self.gql(key, token, query, vars).await?;
            let connection = at(&page.data, path).clone();
            all.extend(nodes_of(&connection));
            cursor = has_next(&connection);
            pages += 1;
        }
        Ok(all)
    }

    /// DESIGN.md, "Reaction rows": the viewer's comments on watched PRs.
    async fn reactions(&mut self) {
        let plan = self.plan;
        for sp in &plan.scopes {
            if self.mismatched.contains(&sp.id) || self.rec.stop.is_some() {
                continue;
            }
            let Some(token) = sp.token.usable(plan.forced).map(str::to_string) else {
                continue;
            };
            match self.owner_matches(sp, &token).await {
                Ok(true) => {}
                Ok(false) => continue,
                Err(e) => {
                    logging::info(format_args!("reactions of {} not fetched: {e}", sp.id));
                    continue;
                }
            }
            let own: Vec<&OwnComment> = plan
                .own
                .values()
                .filter(|own| {
                    plan.prs
                        .get(&own.pr_id)
                        .is_some_and(|pr| pr.watched && pr.scope.as_deref() == Some(&sp.id))
                })
                .collect();
            for chunk in own.chunks(NODES_PER_QUERY) {
                let ids: Vec<&str> = chunk.iter().map(|own| own.id.as_str()).collect();
                let text = "query Reactions($ids: [ID!]!) { nodes(ids: $ids) { __typename ... on Reactable { id reactionGroups { content viewerHasReacted reactors(first: 1) { totalCount } } } } }";
                let answer = match self
                    .gql(&sp.token_key, &token, text, json!({"ids": ids}))
                    .await
                {
                    Ok(answer) => answer,
                    Err(e) => {
                        logging::info(format_args!("reactions of {} not fetched: {e}", sp.id));
                        break;
                    }
                };
                let list = answer.data["nodes"].as_array().cloned().unwrap_or_default();
                for (own, node) in chunk.iter().zip(list) {
                    if node.is_null() {
                        if answer.errors.iter().any(|e| e.is_not_found()) {
                            self.out.own_gone.push(own.id.clone());
                        }
                        continue;
                    }
                    self.reactions
                        .push(convert::reaction(&node, own, own.baseline_done));
                    if !own.baseline_done {
                        self.out.baselines_set.push(own.id.clone());
                    }
                }
            }
        }
    }

    fn finish(mut self) -> Outcome {
        // Events and reactions only for PRs the core will know.
        let known: BTreeSet<String> = self
            .plan
            .prs
            .keys()
            .cloned()
            .chain(self.fetched.iter().cloned())
            .collect();
        self.events.retain(|e| known.contains(&e.pr_id));
        self.reactions.retain(|r| known.contains(&r.pr_id));
        let mut seen = BTreeSet::new();
        self.events.retain(|e| seen.insert(e.id.clone()));
        if !self.viewer.is_empty() {
            self.out.ingest = Some(Ingest {
                viewer: self.viewer.clone(),
                missing_pr_ids: self.missing,
                prs: self.prs,
                events: self.events,
                reactions: self.reactions,
                succeeded_scopes: Some(self.succeeded),
            });
        }
        for (key, obs) in std::mem::take(&mut self.rec.tokens) {
            let entry = self.out.tokens.entry(key).or_default();
            entry.expires_at = obs.expires_at.or(entry.expires_at);
            entry.scopes = obs.scopes.or(entry.scopes.take());
            entry.sso = obs.sso;
            entry.sso_urls = obs.sso_urls;
            entry.invalid = obs.invalid;
        }
        // One failure per PR per run, from its earliest window; a PR that
        // failed anywhere in the run is not a success.
        let mut failed: BTreeMap<String, i64> = BTreeMap::new();
        for (id, since) in std::mem::take(&mut self.out.retries_failed) {
            let entry = failed.entry(id).or_insert(since);
            *entry = (*entry).min(since);
        }
        self.out.retries_ok.retain(|id| !failed.contains_key(id));
        self.out.retries_ok.sort();
        self.out.retries_ok.dedup();
        self.out.retries_failed = failed.into_iter().collect();
        self.out.costs = std::mem::take(&mut self.rec.added);
        self.out.rest = self.rec.rest;
        self.out.graphql = self.rec.graphql;
        self.out.stop = self.rec.stop.take();
        self.out
    }
}

/// `org` or `user` from `repositoryOwner { __typename }`.
pub fn owner_kind(owner: &Value) -> Option<ScopeKind> {
    match owner["__typename"].as_str() {
        Some("Organization") => Some(ScopeKind::Org),
        Some("User") => Some(ScopeKind::User),
        _ => None,
    }
}

/// Percent-encode a path or query component.
pub fn encode(text: &str) -> String {
    let mut out = String::new();
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}
