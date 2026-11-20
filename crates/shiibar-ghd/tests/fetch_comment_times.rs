//! DESIGN.md, "Comment times": a review comment counts from the time its
//! review was submitted (`publishedAt`), not from the time it was drafted in
//! a pending review (`createdAt`). The real daemon fetches from the fake
//! GitHub; ordering comes from `dev_clock_set`, which answers after the run.
#![cfg(feature = "dev-ingest")]

mod common;
mod fake_github;

use common::*;
use fake_github::*;
use serde_json::{Value, json};
use std::path::Path;

const TOKEN: &str = "ghp_me_SECRET_1";

fn world() -> FakeGitHub {
    let github = FakeGitHub::start();
    github.with(|w| {
        w.logins.insert(TOKEN.into(), ME.into());
        w.owners.insert("org".into(), "Organization".into());
        w.owner_ids.insert("org".into(), 100);
    });
    github
}

fn start(dir: &Path, github: &FakeGitHub) -> TestDaemon {
    let mut command = command(dir);
    command
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", dir.join("keychain.json"))
        .env("SHIIBAR_GH_DEV_GITHUB_URL", &github.url);
    TestDaemon::spawn(dir, command)
}

fn setup(daemon: &TestDaemon) {
    daemon.ok(json!({"cmd":"dev_account_add","id":ACCOUNT,"login":ME,"token":TOKEN}));
    daemon
        .ok(json!({"cmd":"dev_owner_add","account":ME,"owner":"org","kind":"org","github_id":100}));
}

fn reaction_node(id: &str, thumbs: u32) -> Value {
    json!({"__typename":"PullRequestReviewComment","id":id,"reactionGroups":[
        {"content":"THUMBS_UP","viewerHasReacted":false,"reactors":{"totalCount":thumbs}}]})
}

/// Every row as `(id, kind, occurred_at)`, sorted.
fn rows(daemon: &TestDaemon) -> Vec<(String, String, i64)> {
    let mut rows: Vec<(String, String, i64)> = daemon.ok(json!({"cmd":"activity"}))["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["id"].as_str().unwrap().to_string(),
                r["kind"].as_str().unwrap().to_string(),
                r["occurred_at"].as_i64().unwrap(),
            )
        })
        .collect();
    rows.sort();
    rows
}

/// The URLs of the Reaction rows, sorted.
fn reaction_rows(daemon: &TestDaemon) -> Vec<String> {
    let mut urls: Vec<String> = daemon.ok(json!({"cmd":"activity"}))["rows"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["kind"] == "reaction")
        .map(|r| r["url"].as_str().unwrap_or_default().to_string())
        .collect();
    urls.sort();
    urls
}

/// The comment ids every `Reactions` request so far asked for.
fn reaction_ids(github: &FakeGitHub) -> Vec<String> {
    github
        .requests()
        .into_iter()
        .filter(|r| r.op.as_deref() == Some("Reactions"))
        .flat_map(|r| {
            r.vars()["ids"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect::<Vec<_>>()
        })
        .collect()
}

/// One review of `me` with three comments submitted after the owner's fetch
/// at F, each in its own thread and drafted at `drafted`; each has one
/// reaction from someone else before the first Reaction fetch. Returns the
/// URLs of the Reaction rows.
fn one_review(drafted: [i64; 3]) -> Vec<String> {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);

    // The owner's fetch at F: the review is still pending, and GitHub
    // returns none of its comments.
    let f = T0 + 100;
    daemon.clock(f);
    assert_eq!(
        daemon.account(ME)["updated_at"].as_i64(),
        Some(f),
        "F is the last success"
    );

    // The review is submitted at F + 200 with its three comments; each gets
    // one reaction right away.
    let submitted = f + 200;
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(submitted));
        w.threads.insert(
            "PR_1".into(),
            drafted
                .iter()
                .enumerate()
                .map(|(i, at)| {
                    let n = i + 1;
                    json!({"id":format!("T_{n}"),"comments":[
                        review_comment(&format!("C_{n}"), ME, *at, Some(submitted), "")]})
                })
                .collect(),
        );
        for n in 1..=3 {
            w.reactables
                .insert(format!("C_{n}"), reaction_node(&format!("C_{n}"), 1));
        }
    });
    // The run that collects the comments, then the run whose Reaction fetch
    // reads them first.
    daemon.clock(submitted + 100);
    daemon.clock(submitted + 400);
    assert!(
        !reaction_ids(&github).is_empty(),
        "the reactions were fetched"
    );
    let urls = reaction_rows(&daemon);
    daemon.stop();
    urls
}

#[test]
fn every_comment_of_a_review_submitted_after_the_fetch_starts_from_zero() {
    let f = T0 + 100;
    // Two comments drafted before F, one after; all submitted after F.
    assert_eq!(
        one_review([f - 50, f - 40, f + 100]),
        [
            "https://github.com/c/C_1",
            "https://github.com/c/C_2",
            "https://github.com/c/C_3"
        ],
        "one Reaction row per comment of the review"
    );
}

#[test]
fn every_comment_drafted_and_submitted_after_the_fetch_starts_from_zero() {
    let f = T0 + 100;
    assert_eq!(
        one_review([f + 50, f + 60, f + 100]),
        [
            "https://github.com/c/C_1",
            "https://github.com/c/C_2",
            "https://github.com/c/C_3"
        ]
    );
}

/// Someone else's review comments drafted before the start of the event
/// window and submitted inside it make their rows, at the time of the
/// submission: a Comment on the account's PR, a Reply in a thread the
/// account commented in, and a Mentioned.
#[test]
fn review_comments_drafted_before_the_window_and_submitted_in_it_make_rows() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "me", json!({})));
        w.threads.insert(
            "PR_1".into(),
            vec![json!({"id":"T_MINE","comments":[
                review_comment("C_ME", ME, T0 + 150, Some(T0 + 200), "")]})],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let f = T0 + 1000;
    daemon.clock(f);
    assert_eq!(daemon.account(ME)["updated_at"].as_i64(), Some(f));

    // The next window starts five minutes before F. alice drafts her three
    // comments before it and submits the review inside it.
    let drafted = T0 + 500;
    let submitted = f + 1000;
    assert!(drafted < f - 300, "drafted before the next window");
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(submitted));
        let threads = w.threads.get_mut("PR_1").unwrap();
        threads[0]["comments"]
            .as_array_mut()
            .unwrap()
            .push(review_comment(
                "C_REPLY",
                "alice",
                drafted,
                Some(submitted),
                "",
            ));
        threads.push(json!({"id":"T_NEW","comments":[
            review_comment("C_NEW", "alice", drafted, Some(submitted), "")]}));
        threads.push(json!({"id":"T_AT","comments":[
            review_comment("C_AT", "alice", drafted + 10, Some(submitted), &mention_link(ME))]}));
    });
    daemon.clock(f + 2000);
    assert_eq!(
        rows(&daemon),
        [
            (rid("C_AT"), "mentioned".to_string(), submitted),
            (rid("C_NEW"), "comment".to_string(), submitted),
            (rid("C_REPLY"), "reply".to_string(), submitted),
        ]
    );
    daemon.stop();
}

/// A comment of the account's own pending review (`publishedAt` null) is
/// not collected: no Reaction baseline and no thread record. Once the review
/// is submitted, the comment is collected, starts from zero as it was
/// published after the previous fetch, and counts as the account's comment
/// in its thread from then on.
#[test]
fn a_pending_review_comment_is_collected_only_once_submitted() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
        w.threads.insert(
            "PR_1".into(),
            vec![json!({"id":"T_1","comments":[
                review_comment("C_A1", "alice", T0 + 10, Some(T0 + 10), "")]})],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let f = T0 + 100;
    daemon.clock(f);

    // The account drafts a reply in a pending review; alice replies after
    // it was drafted.
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(f + 200));
        let thread = &mut w.threads.get_mut("PR_1").unwrap()[0];
        let comments = thread["comments"].as_array_mut().unwrap();
        comments.push(review_comment("C_ME", ME, f + 100, None, ""));
        comments.push(review_comment("C_A2", "alice", f + 200, Some(f + 200), ""));
    });
    daemon.clock(f + 300);
    daemon.clock(f + 700);
    assert!(
        !reaction_ids(&github).contains(&"C_ME".to_string()),
        "no baseline for a pending comment: its reactions are not read"
    );
    assert_eq!(
        rows(&daemon),
        [],
        "the pending comment makes no thread the account commented in"
    );

    // The review is submitted; the comment gets a reaction right away.
    let submitted = f + 800;
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(submitted));
        let thread = &mut w.threads.get_mut("PR_1").unwrap()[0];
        thread["comments"][1] = review_comment("C_ME", ME, f + 100, Some(submitted), "");
        w.reactables.insert("C_ME".into(), reaction_node("C_ME", 1));
    });
    daemon.clock(submitted + 100);
    daemon.clock(submitted + 400);
    assert_eq!(
        reaction_rows(&daemon),
        ["https://github.com/c/C_ME"],
        "published after the previous fetch: starts from zero"
    );

    // alice's reply after the submission is a Reply.
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(submitted + 500));
        let thread = &mut w.threads.get_mut("PR_1").unwrap()[0];
        thread["comments"]
            .as_array_mut()
            .unwrap()
            .push(review_comment(
                "C_A3",
                "alice",
                submitted + 500,
                Some(submitted + 500),
                "",
            ));
    });
    daemon.clock(submitted + 600);
    let replies: Vec<String> = rows(&daemon)
        .into_iter()
        .filter(|(_, kind, _)| kind == "reply")
        .map(|(id, _, _)| id)
        .collect();
    assert_eq!(
        replies,
        [rid("C_A3")],
        "alice's reply before the submission stays no reply"
    );
    daemon.stop();
}

/// alice submits, in one review, a comment that mentions the account and a
/// follow-up in the same thread: both have the review's time, and the
/// follow-up is after the mention by its place in the thread.
#[test]
fn a_follow_up_in_the_review_that_mentions_the_account_is_a_reply_after_the_mention() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let f = T0 + 100;
    daemon.clock(f);
    let submitted = f + 200;
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(submitted));
        w.threads.insert(
            "PR_1".into(),
            vec![json!({"id":"T_1","comments":[
                review_comment("C_AT", "alice", f + 10, Some(submitted), &mention_link(ME)),
                review_comment("C_MORE", "alice", f + 20, Some(submitted), "")]})],
        );
    });
    daemon.clock(submitted + 100);
    assert_eq!(
        rows(&daemon),
        [
            (rid("C_AT"), "mentioned".to_string(), submitted),
            (rid("C_MORE"), "reply_mentioned".to_string(), submitted),
        ]
    );
    daemon.stop();
}

/// DESIGN.md, "Reaction rows": a comment published after the owner's watch
/// started is counted from zero, though it was drafted before.
#[test]
fn a_comment_drafted_before_the_watch_and_published_after_it_starts_from_zero() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node(
            "PR_1",
            "org",
            1,
            "alice",
            json!({"updatedAt": iso(T0 + 50)}),
        ));
        w.threads.insert(
            "PR_1".into(),
            vec![json!({"id":"T_1","comments":[
                review_comment("C_ME", ME, T0 - 100, Some(T0 + 50), "")]})],
        );
        w.reactables.insert("C_ME".into(), reaction_node("C_ME", 2));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    // The watch starts at T0.
    setup(&daemon);
    daemon.clock(T0 + 100);
    daemon.clock(T0 + 400);
    assert_eq!(reaction_rows(&daemon), ["https://github.com/c/C_ME"]);
    daemon.stop();
}

/// The comment fields every request that reads comments asks for.
const COMMENT_FIELDS: &str = "id url createdAt publishedAt bodyText bodyHTML author";

/// DESIGN.md, "API usage": every request that reads comments asks for
/// `publishedAt` (`Events`, the next pages of the review threads, the
/// collection of a newly found PR and its next pages), and every request
/// that reads the timeline asks for the two draft events (`Events` and its
/// next pages). The next pages are only asked for when an answer says there
/// are more, so the answers here say so.
#[test]
fn every_request_that_reads_comments_or_the_timeline_asks_for_published_at_and_the_draft_events() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
    });
    let more =
        |nodes: Value| json!({"pageInfo":{"hasNextPage":true,"endCursor":"next"},"nodes":nodes});
    github.intercept(move |req| match req.op.as_deref() {
        Some("Events") => Some(Resp::json(
            200,
            json!({"data":{"nodes":[{
                "id":"PR_1","number":1,"url":"https://github.com/org/app/pull/1",
                "createdAt":iso(T0 - 86_400),"bodyHTML":"","bodyText":"",
                "author":{"__typename":"User","login":"alice"},
                "timelineItems":more(json!([])),"reviewThreads":more(json!([]))
            }]}}),
        )),
        Some("Collect") => Some(Resp::json(
            200,
            json!({"data":{"node":{
                "id":"PR_1","url":"https://github.com/org/app/pull/1",
                "createdAt":iso(T0 - 86_400),"bodyHTML":"","bodyText":"",
                "author":{"__typename":"User","login":"alice"},
                "comments":more(json!([])),
                "reviews":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},
                "reviewThreads":more(json!([{"id":"T_1","comments":more(json!([]))}])),
                "reviewRequests":{"nodes":[]},"requestEvents":{"nodes":[]}
            }}}),
        )),
        _ => None,
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let queries = |op: &str| -> Vec<String> {
        github
            .requests()
            .into_iter()
            .filter(|r| r.op.as_deref() == Some(op))
            .map(|r| r.query().to_string())
            .collect()
    };
    let one = |op: &str| -> String {
        let all = queries(op);
        assert!(!all.is_empty(), "no {op} request");
        all[0].clone()
    };
    let item_types = "READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT";
    let fragments = [
        "... on ReadyForReviewEvent { id createdAt url actor",
        "... on ConvertToDraftEvent { id createdAt url actor",
    ];
    for op in ["Events", "TimelinePage"] {
        let query = one(op);
        assert!(query.contains(item_types), "{op}: {query}");
        for fragment in fragments {
            assert!(query.contains(fragment), "{op}: {query}");
        }
    }
    for op in ["Events", "ThreadsPage"] {
        let query = one(op);
        assert!(query.contains(COMMENT_FIELDS), "{op}: {query}");
    }
    let collect = one("Collect");
    assert_eq!(
        collect.matches(COMMENT_FIELDS).count(),
        2,
        "the conversation comments and the thread comments: {collect}"
    );
    // The next pages of the conversation comments, of the review threads
    // and of a thread's comments.
    let pages = queries("Page");
    assert_eq!(pages.len(), 3, "{pages:?}");
    for page in &pages {
        assert!(page.contains(COMMENT_FIELDS), "{page}");
    }
    daemon.stop();
}
