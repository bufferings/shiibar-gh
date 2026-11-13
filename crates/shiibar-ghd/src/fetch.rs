//! One fetch run of one account: its login and teams, notifications, then
//! each owner's search, status and events (the account run, DESIGN.md "Fetch
//! success and failure"), then reactions, which keep their own time and never
//! make the run fail. Calls run one after another, never in parallel. The run
//! works on a copy of the core state ([`Plan`]) and hands everything back as
//! an [`Outcome`]; it never changes rows, cards or unread state itself. Every
//! call uses the account's one classic token (DESIGN.md, "Tokens" and "API
//! usage").
//!
//! A request is one HTTP call to GitHub. A request that GitHub answers with
//! 502 or 504 is split in two halves and made again at once, down to one
//! item. What a successful request brings is used whatever the other
//! requests do; a failed one is recorded, and the next run makes only the
//! failed requests until the interval since the last full run has passed.

use crate::convert::{self, Ctx, EventInput, StatusExtra};
use crate::github::{Api, CallError, Gql, Recorder, format_time};
use crate::logging;
use crate::model::{FailedRequest, OwnComment, OwnerKind, TeamRec, ThreadRec};
use crate::plan::*;
use serde_json::{Value, json};
use shiibar_gh_proto as proto;
use shiibar_gh_proto::{Ingest, IngestEvent, IngestPr, SearchHit};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::time::Instant;

/// Ten pages per connection.
const MAX_PAGES: usize = 10;
/// DESIGN.md, "Constants": ids per `Status`, `Compare`, `Contexts` and
/// `Reactions` request.
const NODES_PER_QUERY: usize = 50;
/// DESIGN.md, "Constants": PRs per `Events` request; each brings up to 100
/// threads of 100 comments.
const EVENT_BATCH: usize = 5;

/// The names of the requests a run records as failed. GraphQL requests go by
/// their query name, REST ones by `GET <path>` (DESIGN.md, "Logs").
const SEARCH: &str = "Search";
const STATUS: &str = "Status";
const COMPARE: &str = "Compare";
const CONTEXTS: &str = "Contexts";
const NOTIFICATIONS: &str = "GET /notifications";
const TEAMS: &str = "GET /user/teams";

const RATE: &str = "rateLimit { cost limit remaining resetAt }";
const ACTOR: &str = "{ __typename login }";
/// The PR author with the avatar the card shows. `size` is the pixel width of
/// the square image (`Actor.avatarUrl(size:)` in the public schema): the card
/// draws it at 16 points, 32 pixels on a Retina display.
const AUTHOR: &str = "{ __typename login avatarUrl(size: 32) }";
const REVIEWER: &str =
    "requestedReviewer { __typename ... on User { login } ... on Team { databaseId slug } }";
const COMMENT: &str = "id url createdAt bodyText bodyHTML author { __typename login }";
/// DESIGN.md, "API usage": each hit carries its `updatedAt` and state.
const SEARCH_NODES: &str = "pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { id updatedAt state repository { owner { login } } } }";
const ITEM_TYPES: &str = "[ISSUE_COMMENT, PULL_REQUEST_REVIEW, REVIEW_REQUESTED_EVENT, \
    MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, ADDED_TO_MERGE_QUEUE_EVENT, \
    REMOVED_FROM_MERGE_QUEUE_EVENT]";
/// DESIGN.md, "API usage": the checks of the commit a merge queue made, with
/// `isRequired` for the PR (`$number`). Checked against the public schema and
/// bevyengine/bevy#26450 (2026-11-13).
const BEFORE_COMMIT: &str = "beforeCommit { statusCheckRollup { contexts(first: 100) { nodes { __typename \
    ... on CheckRun { name conclusion detailsUrl isRequired(pullRequestNumber: $number) } \
    ... on StatusContext { context state targetUrl isRequired(pullRequestNumber: $number) } } } } }";
/// The message of `fetch_failed`.
pub const UNREACHABLE: &str = "Couldn't reach GitHub";

/// The timeline items of the `Events` query. `beforeCommit` needs the PR
/// number as a variable, which a query over several PRs cannot give, so it is
/// read by the `MergeQueue` query of one PR, which every removal that makes a
/// row needs anyway.
fn timeline_nodes() -> String {
    format!(
        "__typename \
         ... on IssueComment {{ {COMMENT} }} \
         ... on PullRequestReview {{ id url createdAt submittedAt state bodyText bodyHTML author {ACTOR} }} \
         ... on ReviewRequestedEvent {{ id createdAt actor {{ login }} {REVIEWER} }} \
         ... on MergedEvent {{ id createdAt url actor {{ login }} }} \
         ... on ClosedEvent {{ id createdAt url actor {{ login }} }} \
         ... on ReopenedEvent {{ id createdAt actor {{ login }} }} \
         ... on AddedToMergeQueueEvent {{ id createdAt actor {{ login }} }} \
         ... on RemovedFromMergeQueueEvent {{ id createdAt actor {{ login }} enqueuer {{ login }} reason }}"
    )
}

/// `assignees` is a `UserConnection` of `PullRequest` (public schema).
fn pr_status_fields() -> String {
    format!(
        "id number url title state isDraft createdAt updatedAt isCrossRepository \
         author {AUTHOR} repository {{ name isPrivate owner {{ login }} }} \
         baseRefName headRefName headRefOid reviewDecision \
         latestOpinionatedReviews(first: 100) {{ nodes {{ state author {{ login }} }} }} \
         statusCheckRollup {{ state }} mergeable mergeStateStatus \
         reviewRequests(first: 100) {{ nodes {{ {REVIEWER} }} }} \
         reviews(last: 100) {{ nodes {{ state submittedAt createdAt author {{ login }} }} }} \
         assignees(first: 100) {{ nodes {{ login }} }}"
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

/// `GraphQL Status (ids: 50)`: the query name and the size of a request, for
/// the log line of a failed request (DESIGN.md, "Logs"). A request that
/// passes `ids` counts them; any other counts its variables.
pub fn describe_query(query: &str, vars: &Value) -> String {
    let name = query
        .trim_start()
        .strip_prefix("query")
        .map(str::trim_start)
        .and_then(|rest| rest.split(|c: char| !c.is_ascii_alphanumeric()).next())
        .filter(|name| !name.is_empty())
        .unwrap_or("query");
    let size = match vars.get("ids").and_then(Value::as_array) {
        Some(ids) => format!("ids: {}", ids.len()),
        None => format!(
            "variables: {}",
            vars.as_object().map_or(0, serde_json::Map::len)
        ),
    };
    format!("GraphQL {name} ({size})")
}

/// Keep going after this error: the rest of the run still makes sense.
fn stops_the_run(error: &CallError) -> bool {
    matches!(
        error,
        CallError::RateLimited { .. } | CallError::Unauthorized
    )
}

fn stops_the_run_result<T>(answer: &Result<T, CallError>) -> bool {
    answer.as_ref().err().is_some_and(stops_the_run)
}

/// The answers of one batched request after its 502 and 504 splits.
#[derive(Default)]
struct Split {
    /// The parts GitHub answered, with their items.
    ok: Vec<(Vec<String>, Gql)>,
    /// Items whose one-item request still got a 502 or 504, and that error.
    alone: Vec<String>,
    gateway_error: Option<CallError>,
    /// Parts that failed another way.
    failed: Vec<(Vec<String>, CallError)>,
    /// A part was refused with the single-organization form of
    /// `X-GitHub-SSO`.
    sso: bool,
}

/// What a run does for one owner beyond its six searches.
#[derive(Default)]
struct OwnerWork {
    /// Search texts to make again.
    searches: Vec<String>,
    /// PRs whose status is wanted.
    status: BTreeSet<String>,
    /// PRs whose events are wanted whatever their status says.
    events: BTreeSet<String>,
    /// Notified PRs (keys) of the owner.
    signals: Vec<String>,
    /// PRs the core does not know whose events failed before: closed ones
    /// found by a search, fetched again until their events are read.
    candidates: BTreeSet<String>,
}

pub struct Run<'a> {
    api: &'a Api,
    plan: &'a Plan,
    rec: Recorder,
    out: Outcome,
    teams: Vec<TeamRec>,
    prs: Vec<IngestPr>,
    events: Vec<IngestEvent>,
    reactions: Vec<proto::IngestReaction>,
    missing: Vec<String>,
    succeeded: Vec<String>,
    /// Signals this run dealt with or dropped.
    consumed: BTreeSet<String>,
    /// PR ids the run fetched a status for.
    fetched: BTreeSet<String>,
    /// This run makes only the requests the last one could not.
    retry_only: bool,
    /// The requests of this run that failed.
    failed: Vec<FailedRequest>,
    /// The owner being fetched had a request that decides its success fail.
    owner_failed: bool,
    hits: BTreeMap<String, SearchHit>,
    /// PRs whose events this run needed, and those it fetched without error.
    needs_events: BTreeSet<String>,
    events_ok: BTreeSet<String>,
    status_failed: BTreeSet<String>,
    status_ok: BTreeSet<String>,
    owner_run_started: BTreeMap<String, i64>,
    /// The first error that failed the account fetch, for its log line.
    first_error: Option<String>,
}

/// Run the fetches the plan names and hand back what they found.
pub async fn run(api: &Api, plan: &Plan) -> Outcome {
    let interval = plan.status_interval_minutes.max(1) * 60;
    // DESIGN.md, "Fetch success and failure": only the failed requests,
    // until the interval since the last full run has passed.
    let retry_only = plan.due.status
        && !plan.failed_requests.is_empty()
        && plan
            .full_run_started_at
            .is_some_and(|at| plan.now < at + interval);
    let mut run = Run {
        api,
        plan,
        rec: Recorder::new(plan.now),
        out: Outcome {
            due: plan.due,
            ..Outcome::default()
        },
        teams: plan.teams.clone(),
        prs: Vec::new(),
        events: Vec::new(),
        reactions: Vec::new(),
        missing: Vec::new(),
        succeeded: Vec::new(),
        consumed: BTreeSet::new(),
        fetched: BTreeSet::new(),
        retry_only,
        failed: Vec::new(),
        owner_failed: false,
        hits: BTreeMap::new(),
        needs_events: BTreeSet::new(),
        events_ok: BTreeSet::new(),
        status_failed: BTreeSet::new(),
        status_ok: BTreeSet::new(),
        owner_run_started: BTreeMap::new(),
        first_error: None,
    };
    run.execute().await;
    run.finish()
}

impl Run<'_> {
    async fn gql(&mut self, query: &str, vars: Value) -> Result<Gql, CallError> {
        let what = describe_query(query, &vars);
        let query = query.replacen('{', &format!("{{ {RATE} "), 1);
        let started = Instant::now();
        let answer = self
            .api
            .graphql(&mut self.rec, &self.plan.token, &query, vars)
            .await;
        self.log_failed_request(&what, started, answer.as_ref().err());
        answer
    }

    async fn rest(
        &mut self,
        path: &str,
        if_modified_since: Option<&str>,
    ) -> Result<crate::github::Rest, CallError> {
        let started = Instant::now();
        let answer = self
            .api
            .rest(&mut self.rec, &self.plan.token, path, if_modified_since)
            .await;
        self.log_failed_request(&format!("GET {path}"), started, answer.as_ref().err());
        answer
    }

    /// DESIGN.md, "Logs": one line per failed request, with what it was, its
    /// size and how long GitHub took. A REST 404 is an expected answer for
    /// some requests and shows only at `debug`.
    fn log_failed_request(&self, what: &str, started: Instant, error: Option<&CallError>) {
        let Some(error) = error else { return };
        let text = error.to_string();
        // A status GitHub answered that the error does not name already.
        let detail = if text.contains("GitHub answered") {
            String::new()
        } else {
            self.rec.client_error_detail()
        };
        let line = format_args!(
            "request of {} failed after {} ms: {what}: {text}{detail}",
            self.plan.login,
            started.elapsed().as_millis(),
        );
        if matches!(error, CallError::NotFound) {
            logging::debug(line);
        } else {
            logging::info(line);
        }
    }

    /// The last answer was a 502 or a 504.
    fn gateway(&self) -> bool {
        matches!(self.rec.last_status, 502 | 504)
    }

    /// A request made of `items`, `size` at a time. DESIGN.md, "Fetch
    /// success and failure": a part GitHub answers with 502 or 504 is split
    /// in two halves and made again at once, down to one item. `Err` only
    /// for an error that stops the run.
    async fn split(
        &mut self,
        items: &[String],
        size: usize,
        build: impl Fn(&[String]) -> (String, Value),
    ) -> Result<Split, CallError> {
        let mut out = Split::default();
        let mut queue: VecDeque<Vec<String>> =
            items.chunks(size.max(1)).map(<[String]>::to_vec).collect();
        while let Some(part) = queue.pop_front() {
            let (text, vars) = build(&part);
            match self.gql(&text, vars).await {
                Ok(answer) => out.ok.push((part, answer)),
                Err(e) if stops_the_run(&e) => return Err(e),
                Err(_) if self.gateway() && part.len() > 1 => {
                    let (first, second) = part.split_at(part.len().div_ceil(2));
                    queue.push_front(second.to_vec());
                    queue.push_front(first.to_vec());
                }
                Err(e) if self.gateway() => {
                    out.alone.extend(part);
                    out.gateway_error = Some(e);
                }
                Err(e) => {
                    if matches!(e, CallError::Forbidden { .. }) && self.last_call_single_org_sso() {
                        out.sso = true;
                    }
                    out.failed.push((part, e));
                }
            }
        }
        Ok(out)
    }

    /// The account fetch failed. DESIGN.md, "Logs": the run logs one
    /// `fetch of <login> failed` line at its end, with the first error.
    fn fail(&mut self, error: &CallError) {
        if self.first_error.is_none() {
            self.first_error = Some(error.to_string());
        }
        self.out.failed = Some(UNREACHABLE.into());
    }

    /// A request that decides the success of an owner or of the account
    /// failed: it is made again by the next run.
    fn request_failed(
        &mut self,
        name: &str,
        owner: Option<&str>,
        items: Vec<String>,
        error: &CallError,
    ) {
        self.fail(error);
        if owner.is_some() {
            self.owner_failed = true;
        }
        let request = FailedRequest {
            name: name.to_string(),
            owner: owner.map(str::to_string),
            items,
            since: None,
        };
        if !self.failed.contains(&request) {
            self.failed.push(request);
        }
    }

    /// The last request failed in this run before: made again only when it
    /// was recorded so.
    fn retried(&self, name: &str) -> bool {
        self.plan
            .failed_requests
            .iter()
            .any(|r| r.name == name && r.owner.is_none())
    }

    /// The last call was a 403 with the single-organization form of
    /// `X-GitHub-SSO`. A call that spans owners (notifications, teams)
    /// cannot name an owner with it, so it fails the run (DESIGN.md,
    /// "Tokens").
    fn last_call_single_org_sso(&self) -> bool {
        self.rec.refused_for_sso()
    }

    async fn execute(&mut self) {
        let plan = self.plan;
        if !plan.due.status {
            // A reaction-only run: no owner, no notifications.
            if plan.due.reactions {
                self.reactions().await;
            }
            self.out.pending_signals = Some(plan.pending_signals.clone());
            return;
        }
        // DESIGN.md, "Tokens": the login follows GitHub's.
        match self
            .gql("query Viewer { viewer { databaseId login } }", json!({}))
            .await
        {
            Ok(answer) => {
                self.out.login = answer.data["viewer"]["login"].as_str().map(str::to_string);
            }
            Err(e) if stops_the_run(&e) => return,
            Err(e) => {
                self.fail(&e);
                return;
            }
        }
        if !self.retry_only || self.retried(TEAMS) {
            match self.read_teams().await {
                Ok(()) => {}
                Err(e) if stops_the_run(&e) => return,
                Err(e) => self.request_failed(TEAMS, None, Vec::new(), &e),
            }
        }

        let mut signals: BTreeSet<String> = plan.pending_signals.clone();
        if plan.due.notifications && (!self.retry_only || self.retried(NOTIFICATIONS)) {
            match self.poll_notifications().await {
                Ok(found) => {
                    self.out.notifications_checked = true;
                    self.out.checked.insert("notifications".into());
                    signals.extend(found);
                }
                Err(e) if stops_the_run(&e) => {
                    self.out.pending_signals = Some(signals);
                    return;
                }
                // DESIGN.md, "Fetch success and failure": only a check GitHub
                // answered starts the X-Poll-Interval wait; after a failure
                // the retry checks again.
                Err(e @ CallError::Forbidden { .. }) if self.last_call_single_org_sso() => {
                    self.request_failed(NOTIFICATIONS, None, Vec::new(), &e);
                }
                Err(CallError::Forbidden { .. }) => {
                    self.out.refused.insert("notifications".into());
                }
                Err(e) => self.request_failed(NOTIFICATIONS, None, Vec::new(), &e),
            }
        }

        for owner in &plan.owners {
            if !owner.enabled || self.rec.stop.is_some() {
                continue;
            }
            if !self.owner(owner, &signals).await {
                self.out.pending_signals = Some(self.left_signals(&signals));
                return;
            }
        }
        if plan.due.reactions && self.rec.stop.is_none() {
            self.reactions().await;
        }
        self.out.pending_signals = Some(self.left_signals(&signals));
    }

    /// Signals of owners this run did not reach wait for the next run;
    /// those of disabled or unknown owners are dropped.
    fn left_signals(&self, signals: &BTreeSet<String>) -> BTreeSet<String> {
        signals
            .difference(&self.consumed)
            .filter(|key| {
                self.owner_of_signal(key)
                    .is_some_and(|id| self.plan.owners.iter().any(|o| o.id == id && o.enabled))
            })
            .cloned()
            .collect()
    }

    /// DESIGN.md, "API usage": every team of the account with `GET
    /// /user/teams` (`read:org`). A refusal keeps the teams read before.
    async fn read_teams(&mut self) -> Result<(), CallError> {
        let mut path = "/user/teams?per_page=100".to_string();
        let mut teams = Vec::new();
        for page in 1.. {
            match self.rest(&path, None).await {
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
                Err(e @ CallError::Forbidden { .. }) if self.last_call_single_org_sso() => {
                    return Err(e);
                }
                Err(CallError::Forbidden { .. }) => {
                    self.out.refused.insert("read:org".into());
                    return Ok(());
                }
                Err(e) => return Err(e),
            }
        }
        self.out.checked.insert("read:org".into());
        self.teams = teams.clone();
        self.out.teams = Some(teams);
        Ok(())
    }

    /// DESIGN.md, "Notifications API usage": `all=true`, 50 a page, `since`
    /// the newest seen, `If-Modified-Since` the last `Last-Modified`. The
    /// read state on GitHub is never touched.
    async fn poll_notifications(&mut self) -> Result<BTreeSet<String>, CallError> {
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
                .rest(&path, if first { modified.as_deref() } else { None })
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
            // DESIGN.md, "Identifying PRs": a notification only signals a PR
            // already saved; an unknown one, or one with only a Dismiss
            // record, is ignored, never looked up.
            for (owner, repo, number) in prs {
                let key = pr_key(&owner, &repo, number);
                if plan.pr_ids.contains_key(&key) {
                    found.insert(key);
                }
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

    /// The owner a notified PR belongs to: the registered owner of its
    /// repository owner, else Public.
    fn owner_of_signal(&self, key: &str) -> Option<String> {
        let login = key.split('/').next().unwrap_or_default();
        let named = self.plan.owners.iter().find(|o| {
            o.login
                .as_deref()
                .is_some_and(|l| l.eq_ignore_ascii_case(login))
        });
        match named {
            Some(owner) => Some(owner.id.clone()),
            None => self
                .plan
                .owners
                .iter()
                .find(|o| o.public())
                .map(|o| o.id.clone()),
        }
    }

    /// A saved PR of this owner.
    fn pr_of<'p>(&'p self, op: &OwnerPlan, id: &str) -> Option<&'p PrInfo> {
        self.plan
            .prs
            .get(id)
            .filter(|pr| pr.owner_id.as_deref() == Some(&op.id))
    }

    /// What the owner fetches besides a full run's searches.
    fn owner_work(&self, op: &OwnerPlan, signals: &BTreeSet<String>) -> OwnerWork {
        let plan = self.plan;
        let mut work = OwnerWork {
            signals: signals
                .iter()
                .filter(|key| self.owner_of_signal(key).as_deref() == Some(&op.id))
                .cloned()
                .collect(),
            ..OwnerWork::default()
        };
        if self.retry_only {
            for request in plan
                .failed_requests
                .iter()
                .filter(|r| r.owner.as_deref() == Some(&op.id))
            {
                match request.name.as_str() {
                    SEARCH => work.searches.extend(request.items.iter().cloned()),
                    // A PR is taken only with its status, base and checks
                    // together, so a failed `Compare` or `Contexts` makes the
                    // `Status` of its PRs again too.
                    STATUS | COMPARE | CONTEXTS => {
                        work.status.extend(request.items.iter().cloned());
                    }
                    _ => {}
                }
            }
        }
        // Notified PRs: only saved ones reach here (`poll_notifications`).
        // Events fetched again: the PRs of `retries`.
        let wanted = work
            .signals
            .iter()
            .filter_map(|key| plan.pr_ids.get(key))
            .chain(plan.retries.keys());
        for id in wanted {
            let Some(pr) = self.pr_of(op, id) else {
                continue;
            };
            work.events.insert(id.clone());
            if !pr.dismissed {
                work.status.insert(id.clone());
            }
        }
        // DESIGN.md, "Fetch success and failure": a closed PR found by a
        // search whose events failed is fetched again, its events from the
        // window of that failure, though the owner's window moved on.
        for (id, owner) in &plan.retry_owners {
            if owner == &op.id && !plan.prs.contains_key(id) {
                work.status.insert(id.clone());
                work.candidates.insert(id.clone());
            }
        }
        // DESIGN.md, "Fetch success and failure": a PR whose status failed
        // even alone is fetched again every run.
        for id in &plan.status_retries {
            if self.pr_of(op, id).is_some_and(|pr| !pr.dismissed) {
                work.status.insert(id.clone());
            }
        }
        work
    }

    /// One owner. Returns false when the run has to stop (a 401 or a rate
    /// limit).
    async fn owner(&mut self, op: &OwnerPlan, signals: &BTreeSet<String>) -> bool {
        let work = self.owner_work(op, signals);
        let retrying = self.retry_only
            && self
                .plan
                .failed_requests
                .iter()
                .any(|r| r.owner.as_deref() == Some(&op.id));
        if !op.status_due
            && !retrying
            && work.searches.is_empty()
            && work.status.is_empty()
            && work.events.is_empty()
        {
            return true;
        }
        self.owner_failed = false;
        self.out.owners_fetched.insert(op.id.clone());
        let signals = work.signals.clone();
        match self.owner_inner(op, work).await {
            Ok(true) => {}
            // DESIGN.md, "Tokens": a request of the owner needs SSO; a
            // warning, not a failure, and the rest of the owner waits.
            Ok(false) => return true,
            Err(e) if stops_the_run(&e) => return false,
            Err(e) => {
                self.fail(&e);
                return true;
            }
        }
        if self.owner_failed {
            // Notified PRs of a failed owner wait for the next run.
            return true;
        }
        self.consumed.extend(signals);
        let name = op
            .login
            .clone()
            .unwrap_or_else(|| crate::model::PUBLIC.to_string());
        if op.status_due && !self.retry_only {
            // DESIGN.md, "Fetch success and failure": the success dates from
            // the start of the run, not from when it is applied.
            self.owner_run_started.insert(name.clone(), self.plan.now);
            self.succeeded.push(name);
        } else if retrying {
            // The success of a retry dates from the full run it completes.
            if let Some(at) = self.plan.full_run_started_at {
                self.owner_run_started.insert(name.clone(), at);
            }
            self.succeeded.push(name);
        }
        true
    }

    /// The six searches of a full run.
    fn all_searches(&self, op: &OwnerPlan) -> Vec<String> {
        let qualifier = match (&op.login, op.kind) {
            (None, _) => "is:public".to_string(),
            (Some(login), OwnerKind::User) => format!("user:{login}"),
            (Some(login), _) => format!("org:{login}"),
        };
        let since = date_before(self.plan.now, self.plan.discovery_days);
        let window = format_time(op.since());
        convert::search_queries(&qualifier, &since, &window, op.team_requests).to_vec()
    }

    /// Search, status and events of one owner. `Ok(false)` when a request of
    /// the owner needs SSO authorization.
    async fn owner_inner(
        &mut self,
        op: &OwnerPlan,
        mut work: OwnerWork,
    ) -> Result<bool, CallError> {
        let plan = self.plan;
        let full = op.status_due && !self.retry_only;
        let searches = if full {
            self.all_searches(op)
        } else {
            std::mem::take(&mut work.searches)
        };
        // PRs that show only through a return trigger: closed ones the core
        // does not know, and those with a Dismiss record (DESIGN.md, "API
        // usage").
        let mut candidates: BTreeSet<String> = std::mem::take(&mut work.candidates);
        self.needs_events.extend(candidates.iter().cloned());
        if !searches.is_empty() {
            let Some(hits) = self.search(op, &searches).await? else {
                return Ok(false);
            };
            for hit in hits {
                match self.pr_of(op, &hit.id) {
                    // A dismissed card: its events only, once it moved.
                    Some(pr) if pr.dismissed => {
                        if hit.updated_at > pr.updated_at {
                            work.events.insert(hit.id.clone());
                            self.needs_events.insert(hit.id.clone());
                        }
                    }
                    Some(_) => {
                        work.status.insert(hit.id.clone());
                    }
                    // Another owner's PR: not this owner's to fetch.
                    None if plan.prs.contains_key(&hit.id) => {}
                    None => match plan.records.get(&hit.id) {
                        Some(record) => {
                            if hit.updated_at > record.updated_at {
                                candidates.insert(hit.id.clone());
                                work.status.insert(hit.id.clone());
                                self.needs_events.insert(hit.id.clone());
                            }
                        }
                        None if hit.open => {
                            work.status.insert(hit.id.clone());
                        }
                        None => {
                            candidates.insert(hit.id.clone());
                            work.status.insert(hit.id.clone());
                            self.needs_events.insert(hit.id.clone());
                        }
                    },
                }
                self.hits.entry(hit.id.clone()).or_insert(hit);
            }
        }
        if full {
            // Every card of the owner that is watched, or no longer readable.
            for pr in plan.prs.values() {
                if pr.owner_id.as_deref() == Some(&op.id)
                    && !pr.dismissed
                    && (pr.watched || pr.unreadable)
                {
                    work.status.insert(pr.id.clone());
                }
            }
        }

        let ids: Vec<String> = work.status.iter().cloned().collect();
        let Some((nodes, broken)) = self.status(op, &ids).await? else {
            return Ok(false);
        };
        // A PR the core does not know is a candidate unless it is open
        // without a Dismiss record (a retried one may have been reopened).
        candidates.retain(|id| {
            plan.records.contains_key(id) || nodes.get(id).is_none_or(|n| n["state"] != "OPEN")
        });
        for (id, node) in &nodes {
            if !plan.prs.contains_key(id)
                && (plan.records.contains_key(id) || node["state"] != "OPEN")
            {
                candidates.insert(id.clone());
                self.needs_events.insert(id.clone());
            }
        }

        let login = plan.login.clone();
        let teams = self.teams.clone();
        let ctx = Ctx {
            viewer: &login,
            teams: &teams,
        };

        // Events: notified PRs, PRs to fetch again, dismissed cards that
        // moved, PRs updated since the last status, newly found ones and
        // candidates.
        let mut wanted: BTreeSet<String> = work.events.clone();
        for (id, node) in &nodes {
            if broken.contains(id) {
                continue;
            }
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
        // A PR the core does not know needs its status to be taken.
        wanted.retain(|id| {
            plan.prs.contains_key(id) || (nodes.contains_key(id) && !broken.contains(id))
        });
        // A PR whose events failed is fetched again; the owner still
        // succeeded (DESIGN.md, "Fetch success and failure").
        // A candidate whose events fail is fetched again by this owner.
        for id in wanted.intersection(&candidates) {
            if !plan.prs.contains_key(id) {
                self.out.retry_owners.insert(id.clone(), op.id.clone());
            }
        }
        self.events_of(op, &wanted, &candidates, ctx).await?;
        Ok(true)
    }

    /// The owner's searches, split on 502 and 504, each followed page by
    /// page. `None` when the owner needs SSO authorization.
    async fn search(
        &mut self,
        op: &OwnerPlan,
        queries: &[String],
    ) -> Result<Option<Vec<SearchHit>>, CallError> {
        let plan = self.plan;
        let exclude = if op.public() {
            plan.registered_owners.clone()
        } else {
            BTreeSet::new()
        };
        let indexed: Vec<String> = (0..queries.len()).map(|i| i.to_string()).collect();
        let build = |part: &[String]| {
            let positions: Vec<usize> = part.iter().filter_map(|i| i.parse().ok()).collect();
            let params: Vec<String> = positions
                .iter()
                .map(|i| format!("$q{i}: String!"))
                .collect();
            let mut text = format!("query Search({}) {{ ", params.join(", "));
            let mut vars = json!({});
            for i in &positions {
                text.push_str(&format!(
                    "s{i}: search(type: ISSUE, query: $q{i}, first: 100) {{ {SEARCH_NODES} }} "
                ));
                vars[format!("q{i}")] = json!(queries[*i]);
            }
            text.push('}');
            (text, vars)
        };
        let answer = self.split(&indexed, queries.len(), build).await?;
        // DESIGN.md, "Tokens": the single-organization form names this
        // owner, unless it is Public, whose search spans organizations: there
        // the refused part fails like any other (`answer.failed`), and the
        // hits of the parts GitHub answered are kept.
        if answer.sso && !op.public() {
            self.owner_needs_sso(op, "search");
            return Ok(None);
        }
        let text_of = |part: &[String]| -> Vec<String> {
            part.iter()
                .filter_map(|i| i.parse::<usize>().ok())
                .filter_map(|i| queries.get(i).cloned())
                .collect()
        };
        for (part, error) in &answer.failed {
            self.request_failed(SEARCH, Some(&op.id), text_of(part), error);
        }
        if let Some(error) = &answer.gateway_error {
            // DESIGN.md, "Fetch success and failure": a search that failed
            // alone is the failure of that request.
            self.request_failed(SEARCH, Some(&op.id), text_of(&answer.alone), error);
        }
        let mut found: Vec<SearchHit> = Vec::new();
        for (part, answer) in answer.ok {
            if let Some(e) = answer.errors.iter().find(|e| !e.is_permission()) {
                let error = CallError::Other(format!("search failed: {}", e.message));
                self.request_failed(SEARCH, Some(&op.id), text_of(&part), &error);
                continue;
            }
            for i in part.iter().filter_map(|i| i.parse::<usize>().ok()) {
                let query = &queries[i];
                let connection = answer.data[format!("s{i}")].clone();
                found.extend(convert::search_hits(&connection, &exclude));
                let mut cursor = has_next(&connection);
                let mut pages = 1;
                while let Some(after) = cursor {
                    if pages >= MAX_PAGES {
                        logging::warn(format_args!(
                            "a search of {} has more than {MAX_PAGES} pages",
                            op.id
                        ));
                        break;
                    }
                    let page = self
                        .gql(
                            &format!("query SearchPage($q: String!, $after: String!) {{ s: search(type: ISSUE, query: $q, first: 100, after: $after) {{ {SEARCH_NODES} }} }}"),
                            json!({"q": query, "after": after}),
                        )
                        .await;
                    if self.search_needs_sso(op, &page) {
                        if op.public() {
                            break;
                        }
                        return Ok(None);
                    }
                    match page {
                        Ok(page) => {
                            found.extend(convert::search_hits(&page.data["s"], &exclude));
                            cursor = has_next(&page.data["s"]);
                            pages += 1;
                        }
                        Err(e) if stops_the_run(&e) => return Err(e),
                        Err(e) => {
                            self.request_failed(SEARCH, Some(&op.id), vec![query.clone()], &e);
                            break;
                        }
                    }
                }
            }
        }
        Ok(Some(found))
    }

    /// The owner's request was refused with the single-organization form of
    /// `X-GitHub-SSO`: the owner's `sso_required` (DESIGN.md, "Tokens").
    fn owner_needs_sso(&mut self, op: &OwnerPlan, what: &str) {
        let url = self
            .rec
            .last_sso
            .as_deref()
            .and_then(crate::github::sso_url);
        self.rec.token.sso_owners.insert(op.id.clone(), url);
        logging::info(format_args!(
            "the {what} of {} needs SSO authorization",
            op.id
        ));
    }

    /// DESIGN.md, "Tokens": a search page of the owner answered with the
    /// single-organization form of `X-GitHub-SSO` (a refusal or not) is that
    /// owner's `sso_required`; for Public it fails the search.
    fn search_needs_sso<T>(&mut self, op: &OwnerPlan, answer: &Result<T, CallError>) -> bool {
        if stops_the_run_result(answer) || !self.last_call_single_org_sso() {
            return false;
        }
        if op.public() {
            self.request_failed(
                SEARCH,
                Some(&op.id),
                Vec::new(),
                &CallError::Other(
                    "the search of Public needs SSO authorization for an organization".into(),
                ),
            );
            return true;
        }
        self.owner_needs_sso(op, "search");
        true
    }

    /// Status, base and failed check names of the owner's PRs, each request
    /// `NODES_PER_QUERY` ids. The status values of a PR are taken only when
    /// all three answered; a PR whose request failed even alone gets
    /// `status_fetch_failed` (`broken`), and any other failure is the owner's
    /// and is made again by the next run. `None` when the owner needs SSO
    /// authorization.
    #[allow(clippy::type_complexity)]
    async fn status(
        &mut self,
        op: &OwnerPlan,
        ids: &[String],
    ) -> Result<Option<(BTreeMap<String, Value>, BTreeSet<String>)>, CallError> {
        let plan = self.plan;
        let mut nodes: BTreeMap<String, Value> = BTreeMap::new();
        let mut broken: BTreeSet<String> = BTreeSet::new();
        if ids.is_empty() {
            return Ok(Some((nodes, broken)));
        }
        let text = format!(
            "query Status($ids: [ID!]!) {{ nodes(ids: $ids) {{ ... on PullRequest {{ {} }} }} }}",
            pr_status_fields()
        );
        let answer = self
            .split(ids, NODES_PER_QUERY, |part| {
                (text.clone(), json!({"ids": part}))
            })
            .await?;
        if !self.owner_request_answered(op, STATUS, &answer) {
            return Ok(None);
        }
        broken.extend(answer.alone.iter().cloned());
        for (part, answer) in answer.ok {
            let mut fatal = None;
            for e in &answer.errors {
                if e.is_permission() {
                    logging::info(format_args!("status not readable: {}", e.message));
                } else if !e.is_not_found() {
                    fatal = Some(e.message.clone());
                }
            }
            if let Some(message) = fatal {
                let error = CallError::Other(format!("status failed: {message}"));
                self.request_failed(STATUS, Some(&op.id), part, &error);
                continue;
            }
            let list = answer.data["nodes"].as_array().cloned().unwrap_or_default();
            for (index, (id, node)) in part.iter().zip(list).enumerate() {
                if !node.is_null() {
                    nodes.insert(id.clone(), node);
                    continue;
                }
                // Only a node GitHub reports as not found makes the PR
                // unreadable. Any other null (a refusal) keeps the card and
                // is fetched again like a status that failed alone. The
                // shape of a refused node is unverified (DESIGN.md, open
                // questions).
                let not_found = answer.errors.iter().any(|e| {
                    e.is_not_found() && e.path.get(1).is_some_and(|p| *p == index.to_string())
                });
                if not_found {
                    self.missing.push(id.clone());
                } else {
                    broken.insert(id.clone());
                }
            }
        }

        // Behind base: one aliased `compare` per open PR, against the head
        // commit, which works for forks too.
        let heads: BTreeMap<String, String> = nodes
            .iter()
            .filter(|(_, n)| n["state"] == "OPEN")
            .map(|(id, n)| {
                (
                    id.clone(),
                    n["headRefOid"].as_str().unwrap_or_default().to_string(),
                )
            })
            .collect();
        let comparable: Vec<String> = heads.keys().cloned().collect();
        let mut behind: BTreeMap<String, i64> = BTreeMap::new();
        let build = |part: &[String]| {
            let mut params = Vec::new();
            let mut body = String::new();
            let mut vars = json!({});
            for (i, id) in part.iter().enumerate() {
                params.push(format!("$i{i}: ID!, $h{i}: String!"));
                body.push_str(&format!(
                    "c{i}: node(id: $i{i}) {{ ... on PullRequest {{ baseRef {{ compare(headRef: $h{i}) {{ behindBy }} }} }} }} "
                ));
                vars[format!("i{i}")] = json!(id);
                vars[format!("h{i}")] = json!(heads.get(id).cloned().unwrap_or_default());
            }
            (
                format!("query Compare({}) {{ {body} }}", params.join(", ")),
                vars,
            )
        };
        let answer = self.split(&comparable, NODES_PER_QUERY, build).await?;
        if !self.owner_request_answered(op, COMPARE, &answer) {
            return Ok(None);
        }
        broken.extend(answer.alone.iter().cloned());
        for (part, answer) in answer.ok {
            for (i, id) in part.iter().enumerate() {
                if let Some(n) =
                    answer.data[format!("c{i}")]["baseRef"]["compare"]["behindBy"].as_i64()
                {
                    behind.insert(id.clone(), n);
                }
            }
        }

        let login = plan.login.clone();
        let teams = self.teams.clone();
        let ctx = Ctx {
            viewer: &login,
            teams: &teams,
        };
        // Failed check names, for the account's open PRs whose checks just
        // failed, or failed again on a new head commit.
        let newly_failed: Vec<String> = nodes
            .iter()
            .filter(|(id, n)| {
                let head = n["headRefOid"].as_str();
                ctx.is_me(n["author"]["login"].as_str().unwrap_or_default())
                    && n["state"] == "OPEN"
                    && matches!(
                        n["statusCheckRollup"]["state"].as_str(),
                        Some("FAILURE" | "ERROR")
                    )
                    && plan.prs.get(*id).is_some_and(|pr| {
                        pr.checks != crate::model::Checks::Failed
                            || pr.settled_head.as_deref() != head
                    })
            })
            .map(|(id, _)| id.clone())
            .collect();
        let mut failed_names: BTreeMap<String, Option<String>> = BTreeMap::new();
        if !newly_failed.is_empty() {
            let text = "query Contexts($ids: [ID!]!) { nodes(ids: $ids) { ... on PullRequest { id statusCheckRollup { contexts(first: 100) { nodes { __typename ... on StatusContext { context state } } } } } } }";
            let answer = self
                .split(&newly_failed, NODES_PER_QUERY, |part| {
                    (text.to_string(), json!({"ids": part}))
                })
                .await?;
            if !self.owner_request_answered(op, CONTEXTS, &answer) {
                return Ok(None);
            }
            broken.extend(answer.alone.iter().cloned());
            let mut contexts: BTreeMap<String, Value> = BTreeMap::new();
            for (part, answer) in answer.ok {
                let list = answer.data["nodes"].as_array().cloned().unwrap_or_default();
                for (index, id) in part.iter().enumerate() {
                    let node = list.get(index).cloned().unwrap_or(Value::Null);
                    contexts.insert(id.clone(), node["statusCheckRollup"]["contexts"].clone());
                }
            }
            for (id, context) in contexts {
                let Some(node) = nodes.get(&id).cloned() else {
                    continue;
                };
                let name = self.failed_check(&node, &context).await?;
                failed_names.insert(id, name);
            }
        }
        // A part that failed otherwise leaves its PRs out of this run.
        let failed_items: BTreeSet<String> = self
            .failed
            .iter()
            .filter(|r| r.owner.as_deref() == Some(&op.id))
            .filter(|r| matches!(r.name.as_str(), STATUS | COMPARE | CONTEXTS))
            .flat_map(|r| r.items.iter().cloned())
            .collect();
        for id in &newly_failed {
            if !failed_names.contains_key(id) {
                broken.insert(id.clone());
            }
        }
        broken.extend(failed_items.iter().cloned());

        for (id, node) in &nodes {
            if broken.contains(id) {
                continue;
            }
            let previous = plan.prs.get(id).map(|pr| (pr.base_status, pr.mergeable));
            let extra = StatusExtra {
                behind_by: behind.get(id).copied(),
                previous,
                failed_check: failed_names.get(id).cloned().flatten(),
            };
            if let Some(pr) = convert::pr_values(node, &extra, ctx) {
                self.fetched.insert(pr.id.clone());
                self.status_ok.insert(pr.id.clone());
                self.prs.push(pr);
            }
        }
        // DESIGN.md, "Fetch success and failure": a saved PR whose request
        // failed even alone; one the core does not know waits for a search
        // to find it again.
        for id in &broken {
            if !failed_items.contains(id) && plan.prs.contains_key(id) {
                self.status_failed.insert(id.clone());
            }
        }
        Ok(Some((nodes, broken)))
    }

    /// Record what a `Status`, `Compare` or `Contexts` request of the owner
    /// could not do. False when it was refused for SSO, which stops the
    /// owner without failing it (DESIGN.md, "Tokens"); for Public such a
    /// refusal is a failure like any other.
    fn owner_request_answered(&mut self, op: &OwnerPlan, name: &str, answer: &Split) -> bool {
        if answer.sso && !op.public() {
            self.owner_needs_sso(op, "status");
            return false;
        }
        for (part, error) in &answer.failed {
            self.request_failed(name, Some(&op.id), part.clone(), error);
        }
        true
    }

    /// DESIGN.md, "State change rows": failed GitHub Actions jobs, then
    /// failed Commit statuses.
    async fn failed_check(
        &mut self,
        node: &Value,
        contexts: &Value,
    ) -> Result<Option<String>, CallError> {
        let owner = node["repository"]["owner"]["login"]
            .as_str()
            .unwrap_or_default();
        let repo = node["repository"]["name"].as_str().unwrap_or_default();
        let sha = node["headRefOid"].as_str().unwrap_or_default();
        let base = format!("/repos/{}/{}/actions/runs", encode(owner), encode(repo));
        let runs = match self
            .rest(
                &format!("{base}?head_sha={}&per_page=100", encode(sha)),
                None,
            )
            .await
        {
            Ok(answer) => answer.body,
            Err(e) if stops_the_run(&e) => return Err(e),
            Err(_) => Value::Null,
        };
        let mut jobs = Vec::new();
        for run_id in convert::runs_to_read(&runs) {
            match self
                .rest(&format!("{base}/{run_id}/jobs?per_page=100"), None)
                .await
            {
                Ok(answer) => jobs.push((run_id, answer.body)),
                Err(e) if stops_the_run(&e) => return Err(e),
                Err(_) => {}
            }
        }
        Ok(convert::failed_check_name(&runs, &jobs, contexts))
    }

    async fn events_of(
        &mut self,
        op: &OwnerPlan,
        wanted: &BTreeSet<String>,
        candidates: &BTreeSet<String>,
        ctx: Ctx<'_>,
    ) -> Result<(), CallError> {
        let plan = self.plan;
        let owner_since = op.since();
        let zero_after = op.reaction_zero_after();
        let mut recorded: BTreeMap<String, ThreadRec> = plan.threads.clone();
        self.needs_events.extend(wanted.iter().cloned());

        // Collect what a newly found or returning PR already holds. A
        // candidate shows only through an event of the window (DESIGN.md,
        // "Events before the watch started").
        for id in wanted {
            let collect = !candidates.contains(id)
                && plan
                    .prs
                    .get(id)
                    .is_none_or(|pr| pr.watched && !pr.collected);
            if !collect {
                continue;
            }
            match self.collect(id).await {
                Ok(Some(node)) => {
                    let found = convert::collect(&node, zero_after, ctx);
                    for thread in &found.threads {
                        merge_thread(&mut recorded, thread);
                    }
                    self.out.threads.extend(found.threads);
                    self.out.own.extend(found.own);
                    self.events.extend(found.ongoing);
                    self.out.collected.push(id.clone());
                }
                Ok(None) => {}
                Err(e) if stops_the_run(&e) => return Err(e),
                Err(e) => {
                    logging::info(format_args!("comments of {id} not collected: {e}"));
                    self.out
                        .retries_failed
                        .push((id.clone(), self.since_of(id, owner_since)));
                }
            }
        }

        // Then the events since the window start, batched by `since`.
        let mut by_since: BTreeMap<i64, Vec<String>> = BTreeMap::new();
        for id in wanted {
            by_since
                .entry(self.since_of(id, owner_since))
                .or_default()
                .push(id.clone());
        }
        let text = format!(
            "query Events($ids: [ID!]!, $since: DateTime!) {{ nodes(ids: $ids) {{ ... on PullRequest {{ \
             id number url createdAt bodyHTML bodyText author {ACTOR} \
             timelineItems(since: $since, first: 100, itemTypes: {ITEM_TYPES}) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {} }} }} \
             reviewThreads(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ id comments(last: 100) {{ nodes {{ {COMMENT} }} }} }} }} \
             }} }} }}",
            timeline_nodes()
        );
        for (since, ids) in by_since {
            let answer = self
                .split(&ids, EVENT_BATCH, |part| {
                    (
                        text.clone(),
                        json!({"ids": part, "since": format_time(since)}),
                    )
                })
                .await?;
            for id in answer
                .alone
                .iter()
                .chain(answer.failed.iter().flat_map(|(part, _)| part))
            {
                self.out.retries_failed.push((id.clone(), since));
            }
            for (part, answer) in answer.ok {
                let list = answer.data["nodes"].as_array().cloned().unwrap_or_default();
                for (index, (id, node)) in part.iter().zip(list).enumerate() {
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
                        .events_of_pr(node, since, zero_after, &recorded, ctx)
                        .await
                    {
                        Ok(output) => {
                            for thread in &output.threads {
                                merge_thread(&mut recorded, thread);
                            }
                            // A candidate the core may not take keeps
                            // nothing for later; a taken one is collected by
                            // the next run.
                            if !candidates.contains(id) {
                                self.out.threads.extend(output.threads);
                                self.out.own.extend(output.own);
                            }
                            self.events.extend(output.events);
                            self.out.retries_ok.push(id.clone());
                            self.events_ok.insert(id.clone());
                        }
                        Err(e) if stops_the_run(&e) => return Err(e),
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

    fn since_of(&self, id: &str, owner_since: i64) -> i64 {
        self.plan
            .retries
            .get(id)
            .map_or(owner_since, |since| (*since).min(owner_since))
    }

    async fn events_of_pr(
        &mut self,
        node: Value,
        since: i64,
        zero_after: i64,
        recorded: &BTreeMap<String, ThreadRec>,
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
            let page = self.gql(&text, json!({"id": id, "after": after})).await?;
            let connection = &page.data["node"]["reviewThreads"];
            threads.extend(nodes_of(connection));
            cursor = has_next(connection);
            pages += 1;
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
        let text = format!(
            "query MergeQueue($id: ID!, $number: Int!) {{ node(id: $id) {{ ... on PullRequest {{ \
             timelineItems(first: 100, itemTypes: [ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT]) {{ nodes {{ __typename \
             ... on AddedToMergeQueueEvent {{ id createdAt actor {{ login }} }} \
             ... on RemovedFromMergeQueueEvent {{ id createdAt actor {{ login }} enqueuer {{ login }} reason {BEFORE_COMMIT} }} \
             }} }} }} }} }}"
        );
        let number = node["number"].as_i64().unwrap_or_default();
        // DESIGN.md, "Row text and targets": a refused queue read still
        // makes the removal rows, from the timeline item alone: the reason
        // without who added the PR, and the Checks page for `failed_checks`.
        let queue = match self.gql(&text, json!({"id": id, "number": number})).await {
            Ok(answer) if !answer.errors.iter().any(|e| e.is_permission()) => {
                nodes_of(&answer.data["node"]["timelineItems"])
            }
            Ok(_) | Err(CallError::Forbidden { .. }) => Vec::new(),
            Err(e) => return Err(e),
        };
        input.merge_queue = Some(&queue);
        Ok(convert::events(&input, ctx))
    }

    /// Every connection without `since`, pages followed up to ten per
    /// connection.
    async fn collect(&mut self, id: &str) -> Result<Option<Value>, CallError> {
        let text = format!(
            "query Collect($id: ID!) {{ node(id: $id) {{ ... on PullRequest {{ \
             id url createdAt bodyHTML bodyText author {ACTOR} \
             comments(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {COMMENT} }} }} \
             reviews(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ id url createdAt submittedAt state bodyText bodyHTML author {ACTOR} }} }} \
             reviewThreads(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ id comments(first: 100) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ {COMMENT} }} }} }} }} \
             reviewRequests(first: 100) {{ nodes {{ {REVIEWER} }} }} {} }} }} }}",
            request_events()
        );
        let answer = self.gql(&text, json!({"id": id})).await?;
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
                .pages(id, "PullRequest", field, &fields, &node[field])
                .await?;
            node[field]["nodes"] = json!(more);
        }
        let threads = nodes_of(&node["reviewThreads"]);
        let mut full = Vec::new();
        for mut thread in threads {
            let thread_id = thread["id"].as_str().unwrap_or_default().to_string();
            let comments = self
                .pages(
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
    async fn pages(
        &mut self,
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
                .gql(&text, json!({"id": owner_id, "after": after}))
                .await?;
            let connection = at(&page.data, &["node", field]).clone();
            all.extend(nodes_of(&connection));
            cursor = has_next(&connection);
            pages += 1;
        }
        Ok(all)
    }

    /// DESIGN.md, "Reaction rows": the account's comments on watched PRs; a
    /// dismissed card is not watched. A failed request is left for the next
    /// reaction fetch and never fails the run.
    async fn reactions(&mut self) {
        let plan = self.plan;
        let own: BTreeMap<String, &OwnComment> = plan
            .own
            .values()
            .filter(|own| {
                plan.prs
                    .get(&own.pr_id)
                    .is_some_and(|pr| pr.watched && pr.owner_id.is_some())
            })
            .map(|own| (own.id.clone(), own))
            .collect();
        let ids: Vec<String> = own.keys().cloned().collect();
        let text = "query Reactions($ids: [ID!]!) { nodes(ids: $ids) { __typename ... on Reactable { id reactionGroups { content viewerHasReacted reactors(first: 1) { totalCount } } } } }";
        // DESIGN.md, "Fetch success and failure": the reaction fetch is not
        // part of the account run's success or failure.
        let Ok(answer) = self
            .split(&ids, NODES_PER_QUERY, |part| {
                (text.to_string(), json!({"ids": part}))
            })
            .await
        else {
            return;
        };
        for (part, answer) in answer.ok {
            let list = answer.data["nodes"].as_array().cloned().unwrap_or_default();
            for (id, node) in part.iter().zip(list) {
                let Some(own) = own.get(id) else { continue };
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

    fn finish(mut self) -> Outcome {
        let plan = self.plan;
        if let Some(error) = &self.first_error {
            logging::info(format_args!("fetch of {} failed: {error}", plan.login));
        }
        // Events and reactions only for PRs the core will know.
        let known: BTreeSet<String> = plan
            .prs
            .keys()
            .cloned()
            .chain(self.fetched.iter().cloned())
            .collect();
        // A retried PR the core does not know that GitHub no longer finds
        // is not fetched again.
        for id in &self.missing {
            if plan.retry_owners.contains_key(id) && !plan.prs.contains_key(id) {
                self.out.retries_ok.push(id.clone());
            }
        }
        self.events.retain(|e| known.contains(&e.pr_id));
        self.reactions.retain(|r| known.contains(&r.pr_id));
        // An approving review with a body is an Approved row and a Comment
        // row of the same review id; the core keys them apart.
        let mut seen = BTreeSet::new();
        self.events
            .retain(|e| seen.insert((e.id.clone(), e.kind == proto::IngestKind::Approved)));
        self.out.ran = self.rec.answered || self.out.failed.is_some();
        // DESIGN.md, "API usage": the core moves a dismissed card's or a
        // record's `updatedAt` on only when its events were read.
        let search: Vec<SearchHit> = std::mem::take(&mut self.hits)
            .into_values()
            .map(|mut hit| {
                hit.events_fetched =
                    !self.needs_events.contains(&hit.id) || self.events_ok.contains(&hit.id);
                hit
            })
            .collect();
        if self.out.ran {
            self.out.ingest = Some(Ingest {
                missing_pr_ids: self.missing,
                prs: self.prs,
                events: self.events,
                reactions: self.reactions,
                succeeded_owners: Some(self.succeeded),
                owner_run_started: self.owner_run_started,
                search,
            });
        }
        self.out.token = std::mem::take(&mut self.rec.token);
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
        if plan.due.status {
            // A status warning ends when the PR's status came back, and for a
            // PR whose status is no longer fetched (dismissed or gone).
            let mut ok: BTreeSet<String> = std::mem::take(&mut self.status_ok);
            for id in &plan.status_retries {
                if plan.prs.get(id).is_none_or(|pr| pr.dismissed) {
                    ok.insert(id.clone());
                }
            }
            ok.retain(|id| !self.status_failed.contains(id));
            self.out.status_ok = ok.into_iter().collect();
            self.out.status_failed = std::mem::take(&mut self.status_failed)
                .into_iter()
                .collect();
            let stopped = self.rec.stop.is_some() || self.rec.token.invalid == Some(true);
            let viewer_failed = self.out.login.is_none() && self.out.failed.is_some();
            if self.retry_only {
                // A retry that could not start keeps the list.
                if !stopped && !viewer_failed {
                    self.out.failed_requests = Some(std::mem::take(&mut self.failed));
                }
            } else {
                self.out.full_run_started_at = Some(plan.now);
                // A full run cut short leaves the next run a full one.
                self.out.failed_requests = Some(if stopped || viewer_failed {
                    Vec::new()
                } else {
                    std::mem::take(&mut self.failed)
                });
            }
        }
        self.out.retry_only = self.retry_only;
        self.out.rest = self.rec.rest;
        self.out.graphql = self.rec.graphql;
        self.out.stop = self.rec.stop.take();
        self.out
    }
}

fn merge_thread(recorded: &mut BTreeMap<String, ThreadRec>, thread: &ThreadRec) {
    let min = |a: Option<i64>, b: Option<i64>| match (a, b) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    };
    let entry = recorded
        .entry(thread.id.clone())
        .or_insert_with(|| thread.clone());
    entry.mine_at = min(entry.mine_at, thread.mine_at);
    entry.mention_at = min(entry.mention_at, thread.mention_at);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_query_is_described_by_its_name_and_size() {
        assert_eq!(
            describe_query(
                "query Status($ids: [ID!]!) { nodes(ids: $ids) { id } }",
                &json!({"ids": ["a", "b", "c"]})
            ),
            "GraphQL Status (ids: 3)"
        );
        assert_eq!(
            describe_query(
                "query Search($q0: String!, $q1: String!) { s0: search(query: $q0) { issueCount } }",
                &json!({"q0": "x", "q1": "y"})
            ),
            "GraphQL Search (variables: 2)"
        );
        assert_eq!(
            describe_query("query Viewer { viewer { login } }", &json!({})),
            "GraphQL Viewer (variables: 0)"
        );
        assert_eq!(
            describe_query("{ viewer { login } }", &json!({})),
            "GraphQL query (variables: 0)"
        );
    }
}
