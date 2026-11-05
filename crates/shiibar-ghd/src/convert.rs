//! GitHub answers to `Ingest` values: pure functions over the JSON GitHub
//! returns, so the rule tables in `tests/` feed them responses directly.
//!
//! Spec: docs/tasks/M2.md, "PR values", "Failed check names", "Event kinds"
//! and "Collecting a newly found PR"; DESIGN.md, "Needs action decisions".

use crate::github::parse_time;
use crate::model::{BaseStatus, OwnComment, TeamRec, ThreadRec};
use serde_json::Value;
use shiibar_gh_proto as proto;
use shiibar_gh_proto::{EventKind, IngestEvent, IngestPr, IngestReaction};
use std::collections::{BTreeMap, BTreeSet};

/// Who is asking: the viewer's login and the teams the scope can see.
#[derive(Debug, Clone, Copy)]
pub struct Ctx<'a> {
    pub viewer: &'a str,
    pub teams: &'a [TeamRec],
}

impl Ctx<'_> {
    pub fn is_me(&self, login: &str) -> bool {
        !login.is_empty() && login.eq_ignore_ascii_case(self.viewer)
    }

    fn my_team(&self, database_id: i64) -> Option<&TeamRec> {
        self.teams.iter().find(|t| t.database_id == database_id)
    }

    fn mentions_my_team(&self, html: &str) -> bool {
        mentioned_teams(html)
            .into_iter()
            .any(|id| self.my_team(id).is_some())
    }
}

fn text(value: &Value) -> &str {
    value.as_str().unwrap_or_default()
}

fn time(value: &Value) -> i64 {
    value.as_str().and_then(parse_time).unwrap_or(0)
}

/// The login of an `Actor`, empty for a deleted account.
fn login(actor: &Value) -> &str {
    text(&actor["login"])
}

fn is_bot(actor: &Value) -> bool {
    actor["__typename"] == "Bot"
}

fn nodes(connection: &Value) -> &[Value] {
    connection["nodes"].as_array().map_or(&[], Vec::as_slice)
}

/// The first name and how many more: `build +2`.
fn first_and_more(names: &[String]) -> Option<String> {
    let first = names.first()?;
    Some(if names.len() > 1 {
        format!("{first} +{}", names.len() - 1)
    } else {
        first.clone()
    })
}

// ---------------------------------------------------------------- PR values

/// `reviewDecision`, or from `latestOpinionatedReviews` when it is null.
pub fn review_value(decision: &Value, latest: &Value) -> proto::Review {
    match decision.as_str() {
        Some("APPROVED") => proto::Review::Approved,
        Some("CHANGES_REQUESTED") => proto::Review::ChangesRequested,
        Some("REVIEW_REQUIRED") => proto::Review::ReviewRequired,
        _ => {
            let states: Vec<&str> = nodes(latest).iter().map(|r| text(&r["state"])).collect();
            if states.contains(&"CHANGES_REQUESTED") {
                proto::Review::ChangesRequested
            } else if states.contains(&"APPROVED") {
                proto::Review::Approved
            } else {
                proto::Review::None
            }
        }
    }
}

/// `statusCheckRollup.state`.
pub fn checks_value(rollup: &Value) -> proto::Checks {
    match rollup["state"].as_str() {
        Some("SUCCESS") => proto::Checks::Passed,
        Some("PENDING" | "EXPECTED") => proto::Checks::InProgress,
        Some("FAILURE" | "ERROR") => proto::Checks::Failed,
        _ => proto::Checks::None,
    }
}

/// `base_status` and `mergeable` from `mergeable`, `mergeStateStatus` and
/// `behindBy`. `UNKNOWN` keeps the previous values, or gives none and false
/// for a PR seen for the first time.
pub fn base_values(
    mergeable: &str,
    merge_state: &str,
    behind_by: Option<i64>,
    previous: Option<(BaseStatus, bool)>,
) -> (proto::BaseStatus, bool) {
    if mergeable == "UNKNOWN" {
        return match previous {
            Some((base, clean)) => (base.into(), clean),
            None => (proto::BaseStatus::None, false),
        };
    }
    let base = if mergeable == "CONFLICTING" {
        proto::BaseStatus::Conflicts
    } else {
        match behind_by {
            Some(n) if n > 0 => proto::BaseStatus::Behind,
            Some(_) => proto::BaseStatus::UpToDate,
            None => proto::BaseStatus::None,
        }
    };
    (base, merge_state == "CLEAN")
}

/// The reviewers asking for changes: the first login and `+N`.
pub fn changes_requested_by(latest: &Value) -> Option<String> {
    let names: Vec<String> = nodes(latest)
        .iter()
        .filter(|r| r["state"] == "CHANGES_REQUESTED")
        .map(|r| login(&r["author"]).to_string())
        .filter(|name| !name.is_empty())
        .collect();
    first_and_more(&names)
}

/// Who a review is requested from now, as seen with this token.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Requested {
    pub me: bool,
    pub team: bool,
    /// Some `requestedReviewer` came back null: the Public token cannot see
    /// it, and the classic PAT reads it again.
    pub hidden: bool,
}

pub fn requested(review_requests: &Value, ctx: Ctx<'_>) -> Requested {
    let mut out = Requested::default();
    for request in nodes(review_requests) {
        let reviewer = &request["requestedReviewer"];
        match reviewer["__typename"].as_str() {
            None => out.hidden = true,
            Some("User") if ctx.is_me(login(reviewer)) => out.me = true,
            Some("Team")
                if reviewer["databaseId"]
                    .as_i64()
                    .is_some_and(|id| ctx.my_team(id).is_some()) =>
            {
                out.team = true
            }
            _ => {}
        }
    }
    out
}

/// What the status of a PR needs beyond its node.
#[derive(Debug, Clone, Default)]
pub struct StatusExtra {
    pub behind_by: Option<i64>,
    pub previous: Option<(BaseStatus, bool)>,
    pub failed_check: Option<String>,
    /// `reviewRequests` read again with the classic PAT.
    pub review_requests: Option<Value>,
}

/// A PR node from the status query as an `IngestPr`.
pub fn pr_values(node: &Value, extra: &StatusExtra, ctx: Ctx<'_>) -> Option<IngestPr> {
    let id = node["id"].as_str()?.to_string();
    let url = text(&node["url"]).to_string();
    let latest = &node["latestOpinionatedReviews"];
    let (base_status, mergeable) = base_values(
        text(&node["mergeable"]),
        text(&node["mergeStateStatus"]),
        extra.behind_by,
        extra.previous,
    );
    let requests = extra
        .review_requests
        .as_ref()
        .unwrap_or(&node["reviewRequests"]);
    let asked = requested(requests, ctx);
    let state = match text(&node["state"]) {
        "MERGED" => proto::PrState::Merged,
        "CLOSED" => proto::PrState::Closed,
        _ => proto::PrState::Open,
    };
    Some(IngestPr {
        id,
        owner: text(&node["repository"]["owner"]["login"]).to_string(),
        repo: text(&node["repository"]["name"]).to_string(),
        number: node["number"].as_u64().unwrap_or(0),
        title: text(&node["title"]).to_string(),
        author: login(&node["author"]).to_string(),
        author_avatar_url: node["author"]["avatarUrl"].as_str().map(str::to_string),
        base: text(&node["baseRefName"]).to_string(),
        head: text(&node["headRefName"]).to_string(),
        state,
        is_draft: node["isDraft"].as_bool().unwrap_or(false),
        review: review_value(&node["reviewDecision"], latest),
        checks: checks_value(&node["statusCheckRollup"]),
        base_status,
        mergeable,
        failed_check: extra.failed_check.clone(),
        changes_requested_by: changes_requested_by(latest),
        updated_at: time(&node["updatedAt"]),
        is_private: node["repository"]["isPrivate"].as_bool().unwrap_or(false),
        requested_me: asked.me,
        requested_team: asked.team,
        links: proto::Links {
            review: url.clone(),
            checks: format!("{url}/checks"),
            base: url.clone(),
        },
        url,
    })
}

// ------------------------------------------------------- failed check names

/// The failed checks of a head commit: GitHub Actions jobs first, then
/// Commit statuses. Runs outside `statusCheckRollup` (event `dynamic`) are
/// left out. `jobs` holds the `jobs` answer of each run, in run order.
pub fn failed_check_name(runs: &Value, jobs: &[(i64, Value)], contexts: &Value) -> Option<String> {
    let mut names = Vec::new();
    for run in runs["workflow_runs"].as_array().into_iter().flatten() {
        if run["event"] == "dynamic" {
            continue;
        }
        let Some(run_id) = run["id"].as_i64() else {
            continue;
        };
        let Some((_, answer)) = jobs.iter().find(|(id, _)| *id == run_id) else {
            continue;
        };
        for job in answer["jobs"].as_array().into_iter().flatten() {
            let failed = match job["conclusion"].as_str() {
                None => false,
                Some(c) => !matches!(c, "success" | "neutral" | "skipped"),
            };
            if failed && let Some(name) = job["name"].as_str() {
                names.push(name.to_string());
            }
        }
    }
    for context in nodes(contexts) {
        if matches!(context["state"].as_str(), Some("FAILURE" | "ERROR"))
            && let Some(name) = context["context"].as_str()
        {
            names.push(name.to_string());
        }
    }
    first_and_more(&names)
}

/// The workflow runs whose jobs are worth reading.
pub fn runs_to_read(runs: &Value) -> Vec<i64> {
    runs["workflow_runs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|run| run["event"] != "dynamic")
        .filter_map(|run| run["id"].as_i64())
        .collect()
}

// ------------------------------------------------------------- bodyHTML

/// The attributes of one `<a ...>` of rendered HTML.
struct Anchor<'a> {
    attrs: &'a str,
}

fn anchors(html: &str) -> Vec<Anchor<'_>> {
    let mut out = Vec::new();
    let mut rest = html;
    while let Some(start) = rest.find("<a ") {
        let after = &rest[start + 3..];
        let Some(close) = after.find('>') else { break };
        out.push(Anchor {
            attrs: &after[..close],
        });
        rest = &after[close + 1..];
    }
    out
}

fn attr<'a>(attrs: &'a str, name: &str) -> Option<&'a str> {
    let key = format!("{name}=\"");
    let start = attrs.find(&key)? + key.len();
    let end = attrs[start..].find('"')? + start;
    Some(&attrs[start..end])
}

fn has_class(attrs: &str, class: &str) -> bool {
    attr(attrs, "class").is_some_and(|c| c.split_whitespace().any(|c| c == class))
}

/// A `user-mention` link to `login`: an `a` element with `user-mention` in
/// its class and an href pointing at the user's page, the login compared
/// without case. A quote of a mention renders without the class and does
/// not count (DESIGN.md, "Needs action decisions"; checked on
/// bufferings-hello/hello-merge-queue#10, 2026-11-05). The markup is not an
/// API contract (DESIGN.md, open questions).
pub fn mentions_user(html: &str, login: &str) -> bool {
    if login.is_empty() {
        return false;
    }
    anchors(html).iter().any(|a| {
        has_class(a.attrs, "user-mention")
            && attr(a.attrs, "href").is_some_and(|href| user_page_of(href, login))
    })
}

/// `https://github.com/<login>` or `/<login>`, with nothing after the login.
fn user_page_of(href: &str, login: &str) -> bool {
    let path = match href.split_once("://") {
        Some((_, rest)) => rest.split_once('/').map_or("", |(_, path)| path),
        None => href.trim_start_matches('/'),
    };
    let path = path.trim_end_matches('/');
    !path.contains(['/', '?', '#']) && path.eq_ignore_ascii_case(login)
}

/// The `data-id` of every `team-mention` link: the team's databaseId
/// (docs/tasks/M2.md, "Team mentions").
pub fn mentioned_teams(html: &str) -> Vec<i64> {
    anchors(html)
        .iter()
        .filter(|a| has_class(a.attrs, "team-mention"))
        .filter_map(|a| attr(a.attrs, "data-id")?.parse().ok())
        .collect()
}

// ---------------------------------------------------------------- events

/// A comment, review body or review comment, flattened.
#[derive(Debug, Clone)]
struct Post<'a> {
    id: &'a str,
    url: &'a str,
    at: i64,
    author: &'a str,
    bot: bool,
    html: &'a str,
    body: &'a str,
    /// The review thread of a review comment.
    thread: Option<&'a str>,
    /// A review body: one without text makes no row.
    review: bool,
}

impl<'a> Post<'a> {
    fn from(node: &'a Value, thread: Option<&'a str>, review: bool) -> Self {
        let at = if review {
            node["submittedAt"]
                .as_str()
                .and_then(parse_time)
                .unwrap_or_else(|| time(&node["createdAt"]))
        } else {
            time(&node["createdAt"])
        };
        Post {
            id: text(&node["id"]),
            url: text(&node["url"]),
            at,
            author: login(&node["author"]),
            bot: is_bot(&node["author"]),
            html: text(&node["bodyHTML"]),
            body: text(&node["bodyText"]),
            thread,
            review,
        }
    }
}

/// What the events of one PR fetch need besides GitHub's answer.
#[derive(Debug, Clone)]
pub struct EventInput<'a> {
    /// The PR node: `id`, `url`, `author`, `bodyHTML`, `bodyText`, `createdAt`.
    pub pr: &'a Value,
    /// `timelineItems` nodes in timeline order.
    pub timeline: &'a [Value],
    /// `reviewThreads` nodes, each with `comments.nodes`.
    pub threads: &'a [Value],
    /// Every ADDED_TO_ and REMOVED_FROM_MERGE_QUEUE_EVENT of the PR, when
    /// they were read regardless of `since`.
    pub merge_queue: Option<&'a [Value]>,
    pub since: i64,
    /// Comments of the viewer created after this start from zero.
    pub zero_after: i64,
    /// Threads recorded earlier: id to the time replies count from.
    pub recorded: &'a BTreeMap<String, i64>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct EventOutput {
    pub events: Vec<IngestEvent>,
    pub threads: Vec<ThreadRec>,
    pub own: Vec<OwnComment>,
    /// A removal from the merge queue needs every queue event of the PR.
    pub needs_merge_queue: bool,
}

/// DESIGN.md, "Needs action decisions" and "Comment and Reply sources", for
/// the events of one PR since `since`.
pub fn events(input: &EventInput<'_>, ctx: Ctx<'_>) -> EventOutput {
    let pr = input.pr;
    let pr_id = text(&pr["id"]).to_string();
    let pr_url = text(&pr["url"]).to_string();
    let mine = ctx.is_me(login(&pr["author"]));
    let mut out = EventOutput::default();

    // Posts in timeline order, review comments after the timeline.
    let mut posts: Vec<Post<'_>> = Vec::new();
    for item in input.timeline {
        match item["__typename"].as_str() {
            Some("IssueComment") => posts.push(Post::from(item, None, false)),
            Some("PullRequestReview") if item["state"] != "PENDING" => {
                posts.push(Post::from(item, None, true));
            }
            _ => {}
        }
    }
    for thread in input.threads {
        let thread_id = text(&thread["id"]);
        for comment in nodes(&thread["comments"]) {
            posts.push(Post::from(comment, Some(thread_id), false));
        }
    }
    // DESIGN.md, "Needs action decisions": a mention is a link to the viewer
    // in the post itself, or to one of the viewer's teams.
    let mentions_me = |html: &str| mentions_user(html, ctx.viewer) || ctx.mentions_my_team(html);

    // Threads: the viewer's own, and those the viewer is mentioned in.
    let mut recorded: BTreeMap<String, i64> = input.recorded.clone();
    for post in &posts {
        let Some(thread) = post.thread else { continue };
        let counts = ctx.is_me(post.author) || mentions_me(post.html);
        if counts {
            let entry = recorded.entry(thread.to_string()).or_insert(post.at);
            *entry = (*entry).min(post.at);
        }
    }
    for (thread, from_at) in &recorded {
        if input.recorded.get(thread) != Some(from_at) {
            out.threads.push(ThreadRec {
                id: thread.clone(),
                pr_id: pr_id.clone(),
                from_at: *from_at,
            });
        }
    }

    let mut seen: BTreeSet<String> = BTreeSet::new();
    for post in &posts {
        if post.id.is_empty() || !seen.insert(post.id.to_string()) {
            continue;
        }
        if ctx.is_me(post.author) {
            if !post.review || !post.body.trim().is_empty() {
                out.own.push(OwnComment {
                    id: post.id.to_string(),
                    pr_id: pr_id.clone(),
                    url: post.url.to_string(),
                    text: post.body.to_string(),
                    created_at: post.at,
                    baseline_done: post.at > input.zero_after,
                });
            }
            continue;
        }
        if post.at < input.since || (post.review && post.body.trim().is_empty()) {
            continue;
        }
        let mentioned = mentions_me(post.html);
        let reply = post
            .thread
            .and_then(|t| recorded.get(t))
            .is_some_and(|from| post.at > *from);
        let kind = if post.bot {
            (mentioned || reply || mine).then_some(EventKind::BotComment)
        } else if mentioned {
            Some(EventKind::Mentioned)
        } else if reply {
            Some(EventKind::Reply)
        } else if mine {
            Some(EventKind::Comment)
        } else {
            None
        };
        if let Some(kind) = kind {
            out.events.push(IngestEvent {
                id: post.id.to_string(),
                pr_id: pr_id.clone(),
                kind,
                occurred_at: post.at,
                url: post.url.to_string(),
                actor: Some(post.author.to_string()).filter(|a| !a.is_empty()),
                text: Some(post.body.to_string()),
                comment_id: Some(post.id.to_string()),
                team: false,
            });
        }
    }

    // A mention in the body of a PR opened in the window.
    let opened = time(&pr["createdAt"]);
    if opened >= input.since && !mine && mentions_me(text(&pr["bodyHTML"])) {
        out.events.push(IngestEvent {
            id: format!("{pr_id}:mention"),
            pr_id: pr_id.clone(),
            kind: if is_bot(&pr["author"]) {
                EventKind::BotComment
            } else {
                EventKind::Mentioned
            },
            occurred_at: opened,
            url: pr_url.clone(),
            actor: Some(login(&pr["author"]).to_string()).filter(|a| !a.is_empty()),
            text: Some(text(&pr["bodyText"]).to_string()),
            comment_id: None,
            team: false,
        });
    }

    for item in input.timeline {
        let at = time(&item["createdAt"]);
        if at < input.since {
            continue;
        }
        let id = text(&item["id"]).to_string();
        let actor = Some(login(&item["actor"]).to_string()).filter(|a| !a.is_empty());
        let event = |kind, url: String, actor: Option<String>, body: Option<String>| IngestEvent {
            id: id.clone(),
            pr_id: pr_id.clone(),
            kind,
            occurred_at: at,
            url,
            actor,
            text: body,
            comment_id: None,
            team: false,
        };
        match item["__typename"].as_str() {
            Some("ReviewRequestedEvent") => {
                if let Some(e) = review_request_event(item, &pr_id, &pr_url, ctx) {
                    out.events.push(e);
                }
            }
            Some("MergedEvent") => out.events.push(event(
                EventKind::Merged,
                text(&item["url"]).to_string(),
                actor,
                None,
            )),
            Some("ClosedEvent") => out.events.push(event(
                EventKind::Closed,
                text(&item["url"]).to_string(),
                actor,
                None,
            )),
            Some("AddedToMergeQueueEvent") => out.events.push(event(
                EventKind::AddedToMergeQueue,
                pr_url.clone(),
                actor,
                None,
            )),
            Some("RemovedFromMergeQueueEvent") => {
                let reason = item["reason"].as_str();
                if reason == Some("merged") {
                    continue;
                }
                let Some(queue) = input.merge_queue else {
                    out.needs_merge_queue = true;
                    continue;
                };
                let adder = enqueuer(queue, &id);
                let reason = reason.map(|r| match r {
                    "failed_checks" => "Checks failed".to_string(),
                    "manual" => "Removed manually".to_string(),
                    other => other.to_string(),
                });
                let body = match (reason, adder) {
                    (Some(r), Some(a)) => Some(format!("{r} · added by {a}")),
                    (Some(r), None) => Some(r),
                    (None, Some(a)) => Some(format!("added by {a}")),
                    (None, None) => None,
                };
                out.events.push(event(
                    EventKind::RemovedFromMergeQueue,
                    pr_url.clone(),
                    actor,
                    body,
                ));
            }
            _ => {}
        }
    }
    out
}

/// The person who added the PR to the queue for one removal: each removal,
/// in time order, takes the oldest addition not taken yet. `enqueuer` is not
/// used (docs/tasks/M2.md, "Row text and targets").
pub fn enqueuer(queue: &[Value], removal_id: &str) -> Option<String> {
    let mut items: Vec<(i64, usize, &Value)> = queue
        .iter()
        .enumerate()
        .map(|(i, item)| (time(&item["createdAt"]), i, item))
        .collect();
    items.sort_by_key(|(at, i, _)| (*at, *i));
    let mut waiting: std::collections::VecDeque<&Value> = Default::default();
    for (_, _, item) in items {
        match item["__typename"].as_str() {
            Some("AddedToMergeQueueEvent") => waiting.push_back(item),
            Some("RemovedFromMergeQueueEvent") => {
                let added = waiting.pop_front();
                if item["id"] == removal_id {
                    return added
                        .map(|a| login(&a["actor"]).to_string())
                        .filter(|a| !a.is_empty());
                }
            }
            _ => {}
        }
    }
    None
}

/// A REVIEW_REQUESTED_EVENT for the viewer or one of the viewer's teams.
fn review_request_event(
    item: &Value,
    pr_id: &str,
    pr_url: &str,
    ctx: Ctx<'_>,
) -> Option<IngestEvent> {
    let reviewer = &item["requestedReviewer"];
    let (body, team) = match reviewer["__typename"].as_str() {
        Some("User") if ctx.is_me(login(reviewer)) => ("for you".to_string(), false),
        Some("Team") => {
            let team = ctx.my_team(reviewer["databaseId"].as_i64()?)?;
            let slug = reviewer["slug"].as_str().unwrap_or(&team.slug);
            (format!("for {slug} team"), true)
        }
        _ => return None,
    };
    Some(IngestEvent {
        id: text(&item["id"]).to_string(),
        pr_id: pr_id.to_string(),
        kind: EventKind::ReviewRequested,
        occurred_at: time(&item["createdAt"]),
        url: pr_url.to_string(),
        actor: Some(login(&item["actor"]).to_string()).filter(|a| !a.is_empty()),
        text: Some(body),
        comment_id: None,
        team,
    })
}

/// Whether a timeline or a request list has reviewers this token cannot see.
pub fn has_hidden_reviewers(items: &[Value]) -> bool {
    items.iter().any(|item| {
        item["__typename"] == "ReviewRequestedEvent" && item["requestedReviewer"].is_null()
    })
}

// ------------------------------------------------ collecting a found PR

/// Everything read without `since` for a newly found or returning PR: the
/// PR node with `comments`, `reviews`, `reviewThreads` (pages merged),
/// `reviewRequests` and `requestEvents` (the newest REVIEW_REQUESTED_EVENTs).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Collection {
    pub own: Vec<OwnComment>,
    pub threads: Vec<ThreadRec>,
    /// Review requests still open, as `review_requested` events of any age.
    pub ongoing: Vec<IngestEvent>,
}

pub fn collect(pr: &Value, zero_after: i64, ctx: Ctx<'_>) -> Collection {
    let pr_id = text(&pr["id"]).to_string();
    let pr_url = text(&pr["url"]).to_string();
    let mut out = Collection::default();
    let own = |post: &Post<'_>, out: &mut Collection| {
        out.own.push(OwnComment {
            id: post.id.to_string(),
            pr_id: pr_id.clone(),
            url: post.url.to_string(),
            text: post.body.to_string(),
            created_at: post.at,
            baseline_done: post.at > zero_after,
        });
    };
    if ctx.is_me(login(&pr["author"])) {
        own(&Post::from(pr, None, false), &mut out);
    }
    for comment in nodes(&pr["comments"]) {
        let post = Post::from(comment, None, false);
        if ctx.is_me(post.author) {
            own(&post, &mut out);
        }
    }
    for review in nodes(&pr["reviews"]) {
        let post = Post::from(review, None, true);
        if ctx.is_me(post.author) && !post.body.trim().is_empty() && review["state"] != "PENDING" {
            own(&post, &mut out);
        }
    }
    for thread in nodes(&pr["reviewThreads"]) {
        let thread_id = text(&thread["id"]);
        let mut from: Option<i64> = None;
        for comment in nodes(&thread["comments"]) {
            let post = Post::from(comment, Some(thread_id), false);
            let counts = if ctx.is_me(post.author) {
                own(&post, &mut out);
                true
            } else {
                mentions_user(post.html, ctx.viewer) || ctx.mentions_my_team(post.html)
            };
            if counts {
                from = Some(from.map_or(post.at, |f| f.min(post.at)));
            }
        }
        if let Some(from_at) = from {
            out.threads.push(ThreadRec {
                id: thread_id.to_string(),
                pr_id: pr_id.clone(),
                from_at,
            });
        }
    }

    // Open requests, each with the newest event that asked that reviewer.
    let events = nodes(&pr["requestEvents"]);
    for request in nodes(&pr["reviewRequests"]) {
        let reviewer = &request["requestedReviewer"];
        let same = |event: &&Value| {
            let other = &event["requestedReviewer"];
            match reviewer["__typename"].as_str() {
                Some("User") => {
                    other["__typename"] == "User"
                        && login(other).eq_ignore_ascii_case(login(reviewer))
                }
                Some("Team") => {
                    other["__typename"] == "Team" && other["databaseId"] == reviewer["databaseId"]
                }
                _ => false,
            }
        };
        let newest = events
            .iter()
            .filter(same)
            .max_by_key(|event| time(&event["createdAt"]));
        if let Some(event) = newest
            && let Some(e) = review_request_event(event, &pr_id, &pr_url, ctx)
        {
            out.ongoing.push(e);
        }
    }
    out
}

// ---------------------------------------------------------------- reactions

/// DESIGN.md, "Reaction rows": counts per `ReactionContent`, the viewer's
/// own reaction left out. `watching` false sets the baseline without rows.
pub fn reaction(node: &Value, own: &OwnComment, watching: bool) -> IngestReaction {
    let mut counts = BTreeMap::new();
    for group in node["reactionGroups"].as_array().into_iter().flatten() {
        let Some(content) = group["content"].as_str() else {
            continue;
        };
        let total = group["reactors"]["totalCount"].as_u64().unwrap_or(0);
        let mine = u64::from(group["viewerHasReacted"].as_bool().unwrap_or(false));
        let count = total.saturating_sub(mine);
        if count > 0 {
            counts.insert(content.to_string(), count as u32);
        }
    }
    IngestReaction {
        comment_id: own.id.clone(),
        pr_id: own.pr_id.clone(),
        url: own.url.clone(),
        text: own.text.clone(),
        comment_created_at: own.created_at,
        counts,
        watching,
    }
}

// ---------------------------------------------------------- notifications

/// A notified PR as `(owner, repo, number)`.
pub type Notified = (String, String, u64);

/// The PRs of a `/notifications` page and the newest `updated_at` on it.
/// Threads that are not PRs are left out; `reason` is never read.
pub fn notified_prs(body: &Value) -> (Vec<Notified>, Option<String>) {
    let mut prs = Vec::new();
    let mut newest: Option<(i64, String)> = None;
    for thread in body.as_array().into_iter().flatten() {
        if let Some(updated) = thread["updated_at"].as_str() {
            let at = parse_time(updated).unwrap_or(0);
            if newest.as_ref().is_none_or(|(t, _)| at > *t) {
                newest = Some((at, updated.to_string()));
            }
        }
        if thread["subject"]["type"] != "PullRequest" {
            continue;
        }
        if let Some(pr) = pull_from_url(text(&thread["subject"]["url"])) {
            prs.push(pr);
        }
    }
    (prs, newest.map(|(_, text)| text))
}

/// `…/repos/{owner}/{repo}/pulls/{number}`.
pub fn pull_from_url(url: &str) -> Option<Notified> {
    let path = url.split("/repos/").nth(1)?;
    let mut parts = path.split('/');
    let owner = parts.next()?;
    let repo = parts.next()?;
    (parts.next()? == "pulls").then_some(())?;
    let number = parts.next()?.parse().ok()?;
    Some((owner.to_string(), repo.to_string(), number))
}

/// The `next` URL of a `Link` header.
pub fn next_link(header: &str) -> Option<String> {
    header.split(',').find_map(|part| {
        let (url, rel) = part.split_once(';')?;
        rel.contains("rel=\"next\"").then(|| {
            url.trim()
                .trim_start_matches('<')
                .trim_end_matches('>')
                .to_string()
        })
    })
}

// ------------------------------------------------------------------ search

/// The four searches of a scope. DESIGN.md, "API usage"; docs/tasks/M2.md,
/// "Finding PRs". `qualifier` is `org:x`, `user:x` or `is:public`; `since`
/// is the `YYYY-MM-DD` of D.
pub fn search_queries(qualifier: &str, since: &str, include_teams: bool) -> [String; 4] {
    let requested = if include_teams {
        "review-requested:@me"
    } else {
        "user-review-requested:@me"
    };
    [
        format!("is:pr is:open involves:@me updated:>={since} {qualifier}"),
        format!("is:pr is:open reviewed-by:@me updated:>={since} {qualifier}"),
        format!("is:pr is:open author:@me {qualifier}"),
        format!("is:pr is:open {requested} {qualifier}"),
    ]
}

/// PR ids from a search answer. Public leaves out registered owners.
pub fn search_ids(connection: &Value, exclude_owners: &BTreeSet<String>) -> Vec<String> {
    nodes(connection)
        .iter()
        .filter(|node| {
            let owner = text(&node["repository"]["owner"]["login"]).to_lowercase();
            !exclude_owners.contains(&owner)
        })
        .filter_map(|node| node["id"].as_str().map(str::to_string))
        .collect()
}
