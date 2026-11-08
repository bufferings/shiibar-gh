//! One fetch run of one account: its login and teams, notifications, then
//! each owner's search, status and events, then reactions. Calls run one
//! after another, never in parallel. The run works on a copy of the core
//! state ([`Plan`]) and hands everything back as an [`Outcome`]; it never
//! changes rows, cards or unread state itself. Every call uses the
//! account's one classic token (DESIGN.md, "Tokens" and "API usage").

use crate::convert::{self, Ctx, EventInput, StatusExtra};
use crate::github::{Api, CallError, Gql, Recorder, format_time};
use crate::logging;
use crate::model::{OwnComment, OwnerKind, TeamRec, ThreadRec};
use crate::plan::*;
use serde_json::{Value, json};
use shiibar_gh_proto as proto;
use shiibar_gh_proto::{Ingest, IngestEvent, IngestPr};
use std::collections::{BTreeMap, BTreeSet};

/// Ten pages per connection.
const MAX_PAGES: usize = 10;
const NODES_PER_QUERY: usize = 100;
/// PRs per events query: each brings up to 100 threads of 100 comments.
const EVENT_BATCH: usize = 5;

const RATE: &str = "rateLimit { cost limit remaining resetAt }";
const ACTOR: &str = "{ __typename login }";
/// The PR author with the avatar the card shows. `size` is the pixel width of
/// the square image (`Actor.avatarUrl(size:)` in the public schema): the card
/// draws it at 16 points, 32 pixels on a Retina display.
const AUTHOR: &str = "{ __typename login avatarUrl(size: 32) }";
const REVIEWER: &str =
    "requestedReviewer { __typename ... on User { login } ... on Team { databaseId slug } }";
const COMMENT: &str = "id url createdAt bodyText bodyHTML author { __typename login }";
const SEARCH_NODES: &str = "pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { id repository { owner { login } } } }";
const ITEM_TYPES: &str = "[ISSUE_COMMENT, PULL_REQUEST_REVIEW, REVIEW_REQUESTED_EVENT, \
    MERGED_EVENT, CLOSED_EVENT, ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT]";
/// The message of `fetch_failed`.
pub const UNREACHABLE: &str = "Couldn't reach GitHub";

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

/// `assignees` is a `UserConnection` of `PullRequest` (public schema).
fn pr_status_fields() -> String {
    format!(
        "id number url title state isDraft updatedAt isCrossRepository \
         author {AUTHOR} repository {{ name isPrivate owner {{ login }} }} \
         baseRefName headRefName headRefOid reviewDecision \
         latestOpinionatedReviews(first: 100) {{ nodes {{ state author {{ login }} }} }} \
         statusCheckRollup {{ state }} mergeable mergeStateStatus \
         reviewRequests(first: 100) {{ nodes {{ {REVIEWER} }} }} \
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

/// Keep going after this error: the rest of the run still makes sense.
fn stops_the_run(error: &CallError) -> bool {
    matches!(
        error,
        CallError::RateLimited { .. } | CallError::Unauthorized
    )
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
}

/// Run the fetches the plan names and hand back what they found.
pub async fn run(api: &Api, plan: &Plan) -> Outcome {
    let mut run = Run {
        api,
        plan,
        rec: Recorder::new(plan.now),
        out: Outcome {
            due: plan.due,
            status_ran: plan
                .owners
                .iter()
                .filter(|o| o.status_due)
                .map(|o| o.id.clone())
                .collect(),
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
    };
    run.execute().await;
    run.finish()
}

impl Run<'_> {
    async fn gql(&mut self, query: &str, vars: Value) -> Result<Gql, CallError> {
        let query = query.replacen('{', &format!("{{ {RATE} "), 1);
        self.api
            .graphql(&mut self.rec, &self.plan.token, &query, vars)
            .await
    }

    async fn rest(
        &mut self,
        path: &str,
        if_modified_since: Option<&str>,
    ) -> Result<crate::github::Rest, CallError> {
        self.api
            .rest(&mut self.rec, &self.plan.token, path, if_modified_since)
            .await
    }

    fn fail(&mut self, error: &CallError) {
        logging::info(format_args!("fetch of {} failed: {error}", self.plan.login));
        self.out.failed = Some(UNREACHABLE.into());
    }

    async fn execute(&mut self) {
        let plan = self.plan;
        if plan.due.status {
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
            match self.read_teams().await {
                Ok(()) => {}
                Err(e) if stops_the_run(&e) => return,
                Err(e) => self.fail(&e),
            }
        }

        let mut signals: BTreeSet<String> = plan.pending_signals.clone();
        if plan.due.notifications {
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
                Err(CallError::Forbidden { .. }) => {
                    self.out.notifications_checked = true;
                    self.out.refused.insert("notifications".into());
                }
                Err(e) => {
                    self.out.notifications_checked = true;
                    self.fail(&e);
                }
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

    /// One owner. Returns false when the run has to stop (a 401 or a rate
    /// limit).
    async fn owner(&mut self, op: &OwnerPlan, signals: &BTreeSet<String>) -> bool {
        let plan = self.plan;
        let mine: Vec<String> = signals
            .iter()
            .filter(|key| self.owner_of_signal(key).as_deref() == Some(&op.id))
            .cloned()
            .collect();
        let retries: Vec<String> = plan
            .retries
            .keys()
            .filter(|id| {
                plan.prs
                    .get(*id)
                    .is_some_and(|pr| pr.owner_id.as_deref() == Some(&op.id))
            })
            .cloned()
            .collect();
        if !op.status_due && mine.is_empty() && retries.is_empty() {
            return true;
        }
        match self.owner_inner(op, &mine, &retries).await {
            Ok(()) => self.consumed.extend(mine),
            Err(e) if stops_the_run(&e) => return false,
            // Notified PRs of a failed owner wait for the next run.
            Err(e) => {
                self.fail(&e);
                return true;
            }
        }
        if op.status_due {
            self.succeeded.push(
                op.login
                    .clone()
                    .unwrap_or_else(|| crate::model::PUBLIC.to_string()),
            );
        }
        true
    }

    async fn owner_inner(
        &mut self,
        op: &OwnerPlan,
        signals: &[String],
        retries: &[String],
    ) -> Result<(), CallError> {
        let plan = self.plan;
        let mut targets: BTreeSet<String> = BTreeSet::new();
        if op.status_due {
            let qualifier = match (&op.login, op.kind) {
                (None, _) => "is:public".to_string(),
                (Some(login), OwnerKind::User) => format!("user:{login}"),
                (Some(login), _) => format!("org:{login}"),
            };
            let since = date_before(plan.now, plan.drop_after_days);
            let queries = convert::search_queries(&qualifier, &since, op.team_requests);
            let mut text = String::from(
                "query Search($q0: String!, $q1: String!, $q2: String!, $q3: String!) { ",
            );
            for i in 0..4 {
                text.push_str(&format!(
                    "s{i}: search(type: ISSUE, query: $q{i}, first: 100) {{ {SEARCH_NODES} }} "
                ));
            }
            text.push('}');
            let vars =
                json!({"q0": queries[0], "q1": queries[1], "q2": queries[2], "q3": queries[3]});
            let answer = self.gql(&text, vars).await?;
            if let Some(e) = answer.errors.iter().find(|e| !e.is_permission()) {
                return Err(CallError::Other(format!("search failed: {}", e.message)));
            }
            let exclude = if op.public() {
                plan.registered_owners.clone()
            } else {
                BTreeSet::new()
            };
            let mut found: BTreeSet<String> = BTreeSet::new();
            for (i, query) in queries.iter().enumerate() {
                let connection = answer.data[format!("s{i}")].clone();
                found.extend(convert::search_ids(&connection, &exclude));
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
                        .await?;
                    found.extend(convert::search_ids(&page.data["s"], &exclude));
                    cursor = has_next(&page.data["s"]);
                    pages += 1;
                }
            }
            targets.extend(found);
            for pr in plan.prs.values() {
                if pr.owner_id.as_deref() == Some(&op.id) && (pr.watched || pr.unreadable) {
                    targets.insert(pr.id.clone());
                }
            }
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
            let answer = self.gql(&text, vars).await?;
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
            let answer = self.gql(&text, json!({"ids": chunk})).await?;
            for e in &answer.errors {
                if e.is_permission() {
                    logging::info(format_args!("status not readable: {}", e.message));
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
        // commit, which works for forks too.
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
            let answer = self.gql(&text, vars).await?;
            for (i, (id, _)) in chunk.iter().enumerate() {
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

        // Failed check names, for the account's open PRs that just failed.
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
            let contexts = self.contexts(&newly_failed).await?;
            for (id, node) in &newly_failed {
                let name = self.failed_check(node, contexts.get(id)).await?;
                failed_names.insert(id.clone(), name);
            }
        }

        for (id, node) in &nodes {
            let previous = plan.prs.get(id).map(|pr| (pr.base_status, pr.mergeable));
            let extra = StatusExtra {
                behind_by: behind.get(id).copied(),
                previous,
                failed_check: failed_names.get(id).cloned().flatten(),
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
        // A PR whose events failed is fetched again; the owner still
        // succeeded (DESIGN.md, "Fetch success and failure").
        self.events_of(op, &wanted, ctx).await
    }

    /// `StatusContext` entries of the rollups.
    async fn contexts(
        &mut self,
        prs: &[(String, Value)],
    ) -> Result<BTreeMap<String, Value>, CallError> {
        let ids: Vec<&String> = prs.iter().map(|(id, _)| id).collect();
        let text = "query Contexts($ids: [ID!]!) { nodes(ids: $ids) { ... on PullRequest { id statusCheckRollup { contexts(first: 100) { nodes { __typename ... on StatusContext { context state } } } } } } }";
        let answer = self.gql(text, json!({"ids": ids})).await?;
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

    /// DESIGN.md, "State change rows": failed GitHub Actions jobs, then
    /// failed Commit statuses.
    async fn failed_check(
        &mut self,
        node: &Value,
        contexts: Option<&Value>,
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
            Err(e) => {
                logging::info(format_args!("workflow runs not read: {e}"));
                Value::Null
            }
        };
        let mut jobs = Vec::new();
        for run_id in convert::runs_to_read(&runs) {
            match self
                .rest(&format!("{base}/{run_id}/jobs?per_page=100"), None)
                .await
            {
                Ok(answer) => jobs.push((run_id, answer.body)),
                Err(e) if stops_the_run(&e) => return Err(e),
                Err(e) => logging::info(format_args!("jobs not read: {e}")),
            }
        }
        Ok(convert::failed_check_name(
            &runs,
            &jobs,
            contexts.unwrap_or(&Value::Null),
        ))
    }

    async fn events_of(
        &mut self,
        op: &OwnerPlan,
        wanted: &BTreeSet<String>,
        ctx: Ctx<'_>,
    ) -> Result<(), CallError> {
        let plan = self.plan;
        let owner_since = op.since();
        let zero_after = op.reaction_zero_after();
        let mut recorded: BTreeMap<String, ThreadRec> = plan.threads.clone();

        // Collect what a newly found or returning PR already holds.
        for id in wanted {
            let collect = plan
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
                    .gql(&text, json!({"ids": chunk, "since": format_time(since)}))
                    .await
                {
                    Ok(answer) => answer,
                    Err(e) if stops_the_run(&e) => return Err(e),
                    Err(e) => {
                        logging::info(format_args!("events not fetched: {e}"));
                        for id in chunk {
                            self.out.retries_failed.push((id.clone(), since));
                        }
                        continue;
                    }
                };
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
                        .events_of_pr(node, since, zero_after, &recorded, ctx)
                        .await
                    {
                        Ok(output) => {
                            for thread in &output.threads {
                                merge_thread(&mut recorded, thread);
                            }
                            self.out.threads.extend(output.threads);
                            self.out.own.extend(output.own);
                            self.events.extend(output.events);
                            self.out.retries_ok.push(id.clone());
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
        let text = "query MergeQueue($id: ID!) { node(id: $id) { ... on PullRequest { timelineItems(first: 100, itemTypes: [ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT]) { nodes { __typename ... on AddedToMergeQueueEvent { id createdAt actor { login } } ... on RemovedFromMergeQueueEvent { id createdAt actor { login } reason } } } } } }";
        // A refused queue read leaves out only the removals that needed it.
        let answer = match self.gql(text, json!({"id": id})).await {
            Ok(answer) if !answer.errors.iter().any(|e| e.is_permission()) => answer,
            Ok(_) | Err(CallError::Forbidden { .. }) => return Ok(output),
            Err(e) => return Err(e),
        };
        let queue = nodes_of(&answer.data["node"]["timelineItems"]);
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

    /// DESIGN.md, "Reaction rows": the account's comments on watched PRs.
    async fn reactions(&mut self) {
        let plan = self.plan;
        let own: Vec<&OwnComment> = plan
            .own
            .values()
            .filter(|own| {
                plan.prs
                    .get(&own.pr_id)
                    .is_some_and(|pr| pr.watched && pr.owner_id.is_some())
            })
            .collect();
        for chunk in own.chunks(NODES_PER_QUERY) {
            let ids: Vec<&str> = chunk.iter().map(|own| own.id.as_str()).collect();
            let text = "query Reactions($ids: [ID!]!) { nodes(ids: $ids) { __typename ... on Reactable { id reactionGroups { content viewerHasReacted reactors(first: 1) { totalCount } } } } }";
            let answer = match self.gql(text, json!({"ids": ids})).await {
                Ok(answer) => answer,
                Err(e) => {
                    logging::info(format_args!("reactions not fetched: {e}"));
                    if !stops_the_run(&e) {
                        self.out.failed = Some(UNREACHABLE.into());
                    }
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
        // An approving review with a body is an Approved row and a Comment
        // row of the same review id; the core keys them apart.
        let mut seen = BTreeSet::new();
        self.events
            .retain(|e| seen.insert((e.id.clone(), e.kind == proto::IngestKind::Approved)));
        self.out.ran = self.rec.answered || self.out.failed.is_some();
        if self.out.ran {
            self.out.ingest = Some(Ingest {
                missing_pr_ids: self.missing,
                prs: self.prs,
                events: self.events,
                reactions: self.reactions,
                succeeded_owners: Some(self.succeeded),
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
