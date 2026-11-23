//! The Assigned row against the real daemon: the `Events` request asks for
//! ASSIGNED_EVENT, and the fake GitHub's answers become rows, read or
//! unread, notified or not. DESIGN.md, "API usage", "Row kind decisions",
//! "Rows of the account's own events" and "Row text and targets";
//! docs/tasks/M13.md, "How to test".
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

fn rows_of(daemon: &TestDaemon, pr: &str) -> Vec<Value> {
    daemon.ok(json!({"cmd":"list","dismissed":"include"}))["cards"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["pr"] == pr)
        .map(|c| c["rows"].as_array().unwrap().clone())
        .unwrap_or_default()
}

#[test]
fn the_events_fetch_makes_assigned_rows_for_assignments_of_the_account() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
        w.prs.push(pr_node("PR_2", "org", 2, "alice", json!({})));
        w.prs.push(pr_node("PR_3", "org", 3, "me", json!({})));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let f = T0 + 100;
    daemon.clock(f);
    github.with(|w| {
        for pr in w.prs.iter_mut() {
            pr["updatedAt"] = json!(iso(f + 60));
            pr["assignees"] = json!({"nodes":[{"login":"me"}]});
        }
        // Someone else assigns the account, and assigns bob.
        w.timeline.insert(
            "PR_1".into(),
            vec![
                assigned_event("AS_1", f + 10, user_node("alice"), user_node("Me")),
                assigned_event("AS_BOB", f + 20, user_node("alice"), user_node("bob")),
                assigned_event("AS_GONE", f + 25, user_node("alice"), Value::Null),
            ],
        );
        // The account assigns itself.
        w.timeline.insert(
            "PR_2".into(),
            vec![assigned_event(
                "AS_2",
                f + 30,
                user_node("me"),
                user_node("me"),
            )],
        );
        // An assignment to the account's own PR.
        w.timeline.insert(
            "PR_3".into(),
            vec![assigned_event(
                "AS_3",
                f + 40,
                user_node("alice"),
                user_node("me"),
            )],
        );
    });
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.clock(f + 100);

    let events = github
        .requests()
        .into_iter()
        .find(|r| r.op.as_deref() == Some("Events"))
        .unwrap();
    assert!(
        events.query().contains("ASSIGNED_EVENT"),
        "{}",
        events.query()
    );
    assert!(
        events.query().contains(
            "... on AssignedEvent { id createdAt actor { __typename login avatarUrl(size: 32) } \
             assignee { __typename ... on User { login } } }"
        ),
        "{}",
        events.query()
    );

    let assigned = |pr: &str| -> Vec<Value> {
        rows_of(&daemon, pr)
            .into_iter()
            .filter(|r| r["kind"] == "assigned")
            .collect()
    };
    let one = assigned("org/app#1");
    assert_eq!(one.len(), 1, "only the assignment of the account: {one:?}");
    let row = &one[0];
    assert_eq!(row["id"], rid("AS_1"));
    assert_eq!(row["actor"], "alice");
    assert_eq!(row["actor_avatar_url"], "https://avatars.example/alice");
    assert_eq!(row["text"], Value::Null);
    assert_eq!(row["url"], "https://github.com/org/app/pull/1");
    assert_eq!(row["unread"], true);

    let own = assigned("org/app#2");
    assert_eq!(own.len(), 1);
    assert_eq!(own[0]["actor"], "me");
    assert_eq!(own[0]["unread"], false, "assigned by the account itself");

    assert!(
        assigned("org/app#3").is_empty(),
        "no row on the account's own PR"
    );

    // Only the assignment by someone else notifies.
    let note = app.notification();
    assert_eq!(note["rows"], json!([rid("AS_1")]));
    assert_eq!(note["title"], "me · Assigned", "{note}");
    daemon.stop();
}

#[test]
fn an_assignment_brings_a_dismissed_card_back() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    daemon.ok(json!({"cmd":"dismiss","account":ME,"pr":"org/app#1"}));
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(T0 + 160));
        w.timeline.insert(
            "PR_1".into(),
            vec![assigned_event(
                "AS_1",
                T0 + 150,
                user_node("bob"),
                user_node("me"),
            )],
        );
    });
    daemon.clock(T0 + 200);
    let card = daemon.card("PR_1").expect("the card");
    assert_eq!(card["dismissed_at"], Value::Null, "back from Dismiss");
    let row = daemon.row("AS_1").expect("the Assigned row");
    assert_eq!(row["kind"], "assigned");
    assert_eq!(row["unread"], true);
    daemon.stop();
}

/// DESIGN.md, "Wire format": `dev_ingest` takes the kind `assigned`, and the
/// row carries it on the wire.
#[test]
fn dev_ingest_takes_the_assigned_kind() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    daemon.setup_account();
    let by_me = with(
        event("AS_2", "PR_1", "assigned", T0 + 2),
        json!({"actor": "me", "text": null}),
    );
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![
            with(
                event("AS_1", "PR_1", "assigned", T0 + 1),
                json!({"text": null}),
            ),
            by_me,
        ],
        vec![],
    );
    let row = daemon.row("AS_1").expect("the row");
    assert_eq!(row["kind"], "assigned");
    assert_eq!(row["unread"], true);
    let own = daemon.row("AS_2").expect("the row");
    assert_eq!(own["unread"], false);
    daemon.stop();
}
