//! The My review mark and the My review rows from the fake GitHub: the
//! `Status` request reads the account's newest verdict, `Viewer` its avatar,
//! and the events fetch makes the rows. DESIGN.md, "Card" ("My review
//! mark"), "My review rows" and "API usage".
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

fn card(daemon: &TestDaemon, pr: &str) -> Value {
    daemon.ok(json!({"cmd":"list","dismissed":"include"}))["cards"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["pr"] == pr)
        .cloned()
        .unwrap_or_else(|| panic!("no card {pr}"))
}

fn requests(github: &FakeGitHub, op: &str) -> Vec<Req> {
    github
        .requests()
        .into_iter()
        .filter(|r| r.op.as_deref() == Some(op))
        .collect()
}

/// A submitted review of the account in a timeline.
fn my_review_item(id: &str, state: &str, at: i64) -> Value {
    json!({"__typename":"PullRequestReview","id":id,"url":format!("https://github.com/r/{id}"),
           "createdAt":iso(at - 30),"publishedAt":iso(at - 30),"submittedAt":iso(at),
           "state":state,"bodyText":"","bodyHTML":"",
           "author":{"__typename":"User","login":ME,"avatarUrl":"https://avatars.example/me"}})
}

/// `reviews(last: 100)` of the status query: the account's reviews, for
/// the time of its newest review (DESIGN.md, "Awaiting review").
fn my_reviews(list: &[(&str, i64)]) -> Value {
    json!({"nodes": list.iter().map(|(state, at)| json!({"state":state,"submittedAt":iso(*at),
        "createdAt":iso(*at),"author":{"login":ME}})).collect::<Vec<_>>()})
}

#[test]
fn the_status_fetch_reads_the_newest_verdict_and_viewer_the_avatar() {
    let github = world();
    github.with(|w| {
        let pr =
            |id: &str, n: u64, author: &str, patch: Value| pr_node(id, "org", n, author, patch);
        w.prs.push(pr(
            "PR_1",
            1,
            "alice",
            json!({"myReview": my_review(Some("APPROVED"))}),
        ));
        w.prs.push(pr(
            "PR_2",
            2,
            "alice",
            json!({"myReview": my_review(Some("CHANGES_REQUESTED"))}),
        ));
        w.prs.push(pr(
            "PR_3",
            3,
            "alice",
            json!({"myReview": my_review(Some("DISMISSED"))}),
        ));
        w.prs
            .push(pr("PR_4", 4, "alice", json!({"myReview": my_review(None)})));
        w.prs.push(pr(
            "PR_5",
            5,
            ME,
            json!({"myReview": my_review(Some("APPROVED"))}),
        ));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    assert_eq!(daemon.account(ME)["avatar_url"], Value::Null);
    daemon.clock(T0 + 100);

    let viewer = requests(&github, "Viewer").remove(0);
    assert!(
        viewer
            .query()
            .contains("viewer { databaseId login avatarUrl(size: 32) }"),
        "{}",
        viewer.query()
    );
    assert_eq!(
        daemon.account(ME)["avatar_url"],
        "https://avatars.example/me"
    );
    let status = requests(&github, "Status").remove(0);
    assert!(
        status.query().contains("$login: String!"),
        "{}",
        status.query()
    );
    assert!(
        status.query().contains(
            "reviews(author: $login, states: [APPROVED, CHANGES_REQUESTED, DISMISSED], last: 1) { nodes { state } }"
        ),
        "{}",
        status.query()
    );
    assert!(
        status.query().contains("reviews(last: 100)"),
        "the reviews for Awaiting review stay"
    );
    assert_eq!(status.vars()["login"], ME);
    let marks: Vec<Value> = (1..=5)
        .map(|n| card(&daemon, &format!("org/app#{n}"))["my_review"].clone())
        .collect();
    assert_eq!(
        marks,
        [
            json!("approved"),
            json!("changes_requested"),
            Value::Null,
            Value::Null,
            Value::Null
        ],
        "a dismissed verdict, none and the account's own PR show no verdict"
    );

    // A status that fails keeps the saved verdict.
    github.with(|w| w.prs[0]["myReview"] = my_review(None));
    github.intercept(|req| {
        (req.op.as_deref() == Some("Status")).then(|| Resp::json(502, json!({"message":"bad"})))
    });
    daemon.clock(T0 + 200);
    assert_eq!(card(&daemon, "org/app#1")["my_review"], "approved");
    github.clear_overrides();
    daemon.clock(T0 + 300);
    assert_eq!(card(&daemon, "org/app#1")["my_review"], Value::Null);
    daemon.stop();
}

#[test]
fn every_part_of_a_split_status_request_carries_the_login() {
    let github = world();
    github.with(|w| {
        for n in 1..=4 {
            w.prs
                .push(pr_node(&format!("PR_{n}"), "org", n, "alice", json!({})));
        }
    });
    // A gateway error for any request of more than one PR.
    github.intercept(|req| {
        let many = req.vars()["ids"]
            .as_array()
            .is_some_and(|ids| ids.len() > 1);
        (req.op.as_deref() == Some("Status") && many)
            .then(|| Resp::json(502, json!({"message":"bad gateway"})))
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let status = requests(&github, "Status");
    assert!(
        status.len() > 4,
        "split down to one PR each: {}",
        status.len()
    );
    for request in &status {
        assert_eq!(request.vars()["login"], ME, "{}", request.vars());
    }
    daemon.stop();
}

/// The account approved, was asked again (waiting, the mark's waiting
/// state), and left a review without a verdict: the wait ends and the mark
/// shows the approval again.
#[test]
fn a_comment_only_review_after_a_new_request_brings_the_verdict_back() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node(
            "PR_1",
            "org",
            1,
            "alice",
            json!({"myReview": my_review(Some("APPROVED")),
                   "reviews": my_reviews(&[("APPROVED", T0 - 500)])}),
        ));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let first = card(&daemon, "org/app#1");
    assert_eq!(first["awaiting_review"], false);
    assert_eq!(first["my_review"], "approved");

    // alice asks the account again.
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(T0 + 150));
        w.prs[0]["reviewRequests"] =
            json!({"nodes":[{"requestedReviewer":{"__typename":"User","login":ME}}]});
        w.timeline.insert(
            "PR_1".into(),
            vec![
                json!({"__typename":"ReviewRequestedEvent","id":"RQ_1","createdAt":iso(T0 + 150),
                "actor":{"__typename":"User","login":"alice"},
                "requestedReviewer":{"__typename":"User","login":ME}}),
            ],
        );
    });
    daemon.clock(T0 + 200);
    let waiting = card(&daemon, "org/app#1");
    assert_eq!(waiting["awaiting_review"], true);
    assert_eq!(waiting["my_review"], Value::Null, "waiting wins");

    // A review without a verdict: GitHub drops the request; the newest
    // verdict stays the approval.
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(T0 + 250));
        w.prs[0]["reviewRequests"] = json!({"nodes":[]});
        w.prs[0]["reviews"] = my_reviews(&[("APPROVED", T0 - 500), ("COMMENTED", T0 + 250)]);
        w.timeline
            .get_mut("PR_1")
            .unwrap()
            .push(my_review_item("PRR_2", "COMMENTED", T0 + 250));
    });
    daemon.clock(T0 + 300);
    let back = card(&daemon, "org/app#1");
    assert_eq!(back["awaiting_review"], false);
    assert_eq!(back["my_review"], "approved");
    let kinds: Vec<Value> = back["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["kind"].clone())
        .collect();
    assert_eq!(
        kinds,
        [json!("review_requested")],
        "a review without a verdict makes no row"
    );
    daemon.stop();
}

#[test]
fn the_events_fetch_makes_my_review_rows_once() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
        w.prs.push(pr_node("PR_2", "org", 2, ME, json!({})));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let f = T0 + 100;
    daemon.clock(f);
    let mut app = daemon.subscribe("app");
    app.snapshot();

    // The account approves alice's PR, asks for changes on another review
    // of it and approves a review dismissed before the fetch; it reviews its
    // own PR too.
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(f + 50));
        w.prs[1]["updatedAt"] = json!(iso(f + 50));
        w.timeline.insert(
            "PR_1".into(),
            vec![
                my_review_item("PRR_1", "APPROVED", f + 20),
                my_review_item("PRR_2", "DISMISSED", f + 30),
            ],
        );
        w.timeline.insert(
            "PR_2".into(),
            vec![my_review_item("PRR_3", "CHANGES_REQUESTED", f + 40)],
        );
    });
    daemon.clock(f + 100);
    let rows = |pr: &str| card(&daemon, pr)["rows"].as_array().unwrap().clone();
    let one = rows("org/app#1");
    assert_eq!(one.len(), 1, "{one:?}");
    let row = &one[0];
    assert_eq!(row["id"], rid("PRR_1"));
    assert_eq!(row["kind"], "my_review_approved");
    assert_eq!(row["unread"], false);
    assert_eq!(row["actor"], ME);
    assert_eq!(row["actor_avatar_url"], "https://avatars.example/me");
    assert_eq!(row["text"], Value::Null);
    assert_eq!(row["url"], "https://github.com/r/PRR_1");
    assert_eq!(row["occurred_at"], f + 20);
    let two = rows("org/app#2");
    assert_eq!(two[0]["kind"], "my_review_changes_requested");
    assert_eq!(daemon.account(ME)["unread"], false, "no dot");
    assert_eq!(card(&daemon, "org/app#1")["placement"], Value::Null);

    // The next fetch reads the same reviews again inside its five-minute
    // overlap: no second row. The approval is dismissed meanwhile and the
    // account asked again; the row stays.
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(f + 150));
        w.prs[0]["reviewRequests"] =
            json!({"nodes":[{"requestedReviewer":{"__typename":"User","login":ME}}]});
        let timeline = w.timeline.get_mut("PR_1").unwrap();
        timeline[0]["state"] = json!("DISMISSED");
        timeline.push(issue_comment("IC_1", "alice", f + 150, ""));
    });
    daemon.clock(f + 200);
    let again = github
        .requests()
        .into_iter()
        .filter(|r| r.op.as_deref() == Some("Events"))
        .count();
    assert!(again >= 2, "the events were fetched again");
    let ids: Vec<Value> = rows("org/app#1").iter().map(|r| r["id"].clone()).collect();
    assert_eq!(ids, [json!(rid("IC_1")), json!(rid("PRR_1"))]);
    let mut more = rows("org/app#2");
    more.retain(|r| r["id"] == rid("PRR_3"));
    assert_eq!(more.len(), 1);
    // The only notification is the comment's: the My review rows notify
    // nothing.
    let note = app.until(|e| e["event"] == "notify");
    assert_eq!(note["notification"]["rows"], json!([rid("IC_1")]));
    daemon.stop();
}

/// `viewer` without an avatar leaves the account without one; the
/// development command takes one as `viewer` would give it.
#[test]
fn an_account_without_an_avatar_has_none() {
    let github = world();
    github.with(|w| {
        w.no_avatar.insert(TOKEN.into());
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    assert_eq!(daemon.account(ME)["avatar_url"], Value::Null);
    let added = daemon.ok(json!({"cmd":"dev_account_add","id":"1002","login":"you",
        "avatar_url":"https://avatars.example/you"}));
    assert_eq!(
        added["account"]["avatar_url"],
        "https://avatars.example/you"
    );
    assert_eq!(
        daemon.account("you")["avatar_url"],
        "https://avatars.example/you"
    );
    daemon.stop();
}

/// A run whose `Viewer` request fails keeps the account's saved avatar.
#[test]
fn a_failed_viewer_request_keeps_the_avatar() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    assert_eq!(
        daemon.account(ME)["avatar_url"],
        "https://avatars.example/me"
    );
    github.intercept(|req| {
        (req.op.as_deref() == Some("Viewer")).then(|| Resp::json(502, json!({"message":"bad"})))
    });
    let before = requests(&github, "Viewer").len();
    daemon.clock(T0 + 200);
    assert!(
        requests(&github, "Viewer").len() > before,
        "the run asked again"
    );
    assert_eq!(
        daemon.account(ME)["avatar_url"],
        "https://avatars.example/me"
    );
    daemon.stop();
}

/// A later `viewer` answer with a null or an empty `avatarUrl` keeps the
/// saved avatar.
#[test]
fn a_viewer_without_an_avatar_later_keeps_the_saved_one() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let saved = json!("https://avatars.example/me");
    assert_eq!(daemon.account(ME)["avatar_url"], saved);
    github.with(|w| {
        w.no_avatar.insert(TOKEN.into());
    });
    daemon.clock(T0 + 200);
    assert_eq!(daemon.account(ME)["avatar_url"], saved, "null");
    github.with(|w| {
        w.no_avatar.clear();
        w.empty_avatar.insert(TOKEN.into());
    });
    daemon.clock(T0 + 300);
    assert_eq!(daemon.account(ME)["avatar_url"], saved, "empty");
    assert_eq!(requests(&github, "Viewer").len(), 3);
    daemon.stop();
}

/// A newly found PR is read twice, by `Collect` (without `since`) and by
/// `Events`: the account's review in both makes one My review row.
#[test]
fn a_review_read_by_collect_and_events_makes_one_row() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node(
            "PR_1",
            "org",
            1,
            "alice",
            json!({"updatedAt": iso(T0 + 50)}),
        ));
        w.timeline.insert(
            "PR_1".into(),
            vec![my_review_item("PRR_1", "APPROVED", T0 + 50)],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let collect = requests(&github, "Collect");
    assert_eq!(collect.len(), 1, "a newly found PR is collected");
    assert!(!requests(&github, "Events").is_empty());
    let rows = card(&daemon, "org/app#1")["rows"].clone();
    let ids: Vec<Value> = rows
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].clone())
        .collect();
    assert_eq!(ids, [json!(rid("PRR_1"))]);
    daemon.stop();
}
