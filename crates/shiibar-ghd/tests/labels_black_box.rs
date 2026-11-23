//! GitHub labels on the cards (DESIGN.md, "Card", "GitHub labels", "Wire
//! format", "What the filters mean") and the Ready for review and Converted
//! to draft rows a fetch makes, against the real daemon: through
//! `dev_ingest`, and from the fake GitHub.
#![cfg(feature = "dev-ingest")]

mod common;
mod fake_github;

use common::*;
use fake_github::*;
use serde_json::{Value, json};
use std::path::Path;

const TOKEN: &str = "ghp_me_SECRET_1";

fn labels(names: &[(&str, &str)]) -> Value {
    json!(
        names
            .iter()
            .map(|(name, color)| json!({"name":name,"color":color}))
            .collect::<Vec<_>>()
    )
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

/// The `<pr>` of the cards a search keeps.
fn found(daemon: &TestDaemon, search: &str, dismissed: &str) -> Vec<String> {
    daemon.ok(json!({"cmd":"list","search":search,"dismissed":dismissed}))["cards"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["pr"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn ingested_labels_go_on_the_card_and_stay_when_left_out() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    daemon.setup_account();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    let first = card(&daemon, "org/app#1");
    assert_eq!(first["labels"], json!([]), "a PR without labels");
    assert_eq!(first["labels_more"], 0);

    let given = labels(&[("bug", "d73a4a"), ("good first issue", "7057FF")]);
    daemon.ingest(
        vec![with(
            pr("PR_1", "alice"),
            json!({"labels": given.clone(), "labels_more": 3}),
        )],
        vec![],
        vec![],
    );
    let labelled = card(&daemon, "org/app#1");
    assert_eq!(labelled["labels"], given, "in the order given");
    assert_eq!(labelled["labels_more"], 3);

    // An ingest without `labels` keeps them.
    daemon.ingest(
        vec![with(pr("PR_1", "alice"), json!({"title":"Renamed"}))],
        vec![],
        vec![],
    );
    let kept = card(&daemon, "org/app#1");
    assert_eq!(kept["title"], "Renamed");
    assert_eq!(kept["labels"], given);
    assert_eq!(kept["labels_more"], 3);

    // `labels` without `labels_more` has none more.
    daemon.ingest(
        vec![with(pr("PR_1", "alice"), json!({"labels": []}))],
        vec![],
        vec![],
    );
    let cleared = card(&daemon, "org/app#1");
    assert_eq!(cleared["labels"], json!([]));
    assert_eq!(cleared["labels_more"], 0);
    daemon.stop();
}

/// DESIGN.md, "Card", "GitHub labels": the labels keep the order they were
/// fetched in; the daemon does not sort them again.
#[test]
fn labels_keep_the_order_they_came_in() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    daemon.setup_account();
    let given = labels(&[
        ("zeta", "ededed"),
        ("Alpha", "D73A4A"),
        ("beta", "0075ca"),
        ("ALPHA-2", "7057ff"),
        ("_tooling", "000000"),
    ]);
    daemon.ingest(
        vec![with(pr("PR_1", "alice"), json!({"labels": given.clone()}))],
        vec![],
        vec![],
    );
    assert_eq!(card(&daemon, "org/app#1")["labels"], given);
    daemon.stop();
    let daemon = TestDaemon::start(dir.path());
    assert_eq!(
        card(&daemon, "org/app#1")["labels"],
        given,
        "the saved order too"
    );
    daemon.stop();
}

#[test]
fn a_change_of_labels_makes_no_row_but_an_account_change() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    daemon.setup_account();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    let before = daemon.account(ME);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.ingest(
        vec![with(
            pr("PR_1", "alice"),
            json!({"labels": labels(&[("bug", "d73a4a")])}),
        )],
        vec![],
        vec![],
    );
    let event = app.next().unwrap();
    assert_eq!(event["event"], "account_changed", "{event}");
    let after = card(&daemon, "org/app#1");
    assert_eq!(after["rows"], json!([]), "no row");
    assert_eq!(daemon.account(ME)["unread"], before["unread"]);
    daemon.stop();
}

#[test]
fn show_labels_decides_whether_a_search_matches_a_label() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    daemon.setup_account();
    let bug = json!({"labels": labels(&[("bug", "d73a4a"), ("Needs Triage", "FBCA04")])});
    daemon.ingest(
        vec![
            with(pr("PR_1", "alice"), bug.clone()),
            with(pr("PR_2", "alice"), bug),
            with(
                pr("PR_3", "alice"),
                json!({"labels": labels(&[("docs", "0075ca")])}),
            ),
        ],
        vec![event("E_1", "PR_3", "comment_other", T0 + 5)],
        vec![],
    );
    daemon.ok(json!({"cmd":"dismiss","account":"me","pr":"org/app#2"}));
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"show_labels"}))["value"],
        true
    );
    assert_eq!(found(&daemon, "bug", "exclude"), ["org/app#1"]);
    assert_eq!(
        found(&daemon, "triage BUG", "exclude"),
        ["org/app#1"],
        "words in two labels, without regard to case"
    );
    assert!(
        found(&daemon, "bug", "only").is_empty(),
        "the Dismissed list shows no labels and matches none"
    );
    assert_eq!(
        found(&daemon, "bug", "include"),
        ["org/app#1"],
        "a dismissed card with a tab's cards matches no label either"
    );
    let activity: Vec<String> = daemon.ok(json!({"cmd":"activity","search":"docs"}))["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(activity, [rid("E_1")], "a row of a PR whose label matches");

    daemon.ok(json!({"cmd":"config_set","key":"show_labels","value":false}));
    assert!(found(&daemon, "bug", "exclude").is_empty());
    assert!(
        daemon.ok(json!({"cmd":"activity","search":"docs"}))["rows"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let hidden = card(&daemon, "org/app#1");
    assert_eq!(
        hidden["labels"].as_array().unwrap().len(),
        2,
        "the wire carries the labels whatever show_labels says"
    );
    daemon.stop();
}

#[test]
fn show_labels_is_a_setting_with_its_change_sent_once() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    let mut app = daemon.subscribe("app");
    app.snapshot();
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"show_labels"}))["value"],
        true
    );
    assert_eq!(
        daemon.code(json!({"cmd":"config_set","key":"show_labels","value":3})),
        "invalid"
    );
    daemon.ok(json!({"cmd":"config_set","key":"show_labels","value":false}));
    let event = app.next().unwrap();
    assert_eq!(
        event,
        json!({"event":"config_changed","key":"show_labels","value":false})
    );
    // The same value again sends nothing; the next change does.
    daemon.ok(json!({"cmd":"config_set","key":"show_labels","value":"false"}));
    daemon.ok(json!({"cmd":"config_set","key":"show_labels","value":"true"}));
    let event = app.next().unwrap();
    assert_eq!(
        event,
        json!({"event":"config_changed","key":"show_labels","value":true})
    );
    daemon.stop();

    // Saved across a restart.
    let daemon = TestDaemon::start(dir.path());
    daemon.ok(json!({"cmd":"config_set","key":"show_labels","value":false}));
    daemon.stop();
    let daemon = TestDaemon::start(dir.path());
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"show_labels"}))["value"],
        false
    );
    daemon.stop();
}

// ------------------------------------------------------------- fetching

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

fn connection(names: &[(&str, &str)], total: usize) -> Value {
    json!({"totalCount": total, "nodes": labels(names)})
}

#[test]
fn the_status_fetch_reads_and_saves_the_labels() {
    let github = world();
    let many: Vec<(String, String)> = (0..20)
        .map(|i| (format!("area-{i:02}"), "ededed".to_string()))
        .collect();
    let many: Vec<(&str, &str)> = many.iter().map(|(n, c)| (n.as_str(), c.as_str())).collect();
    github.with(|w| {
        w.prs.push(pr_node(
            "PR_1",
            "org",
            1,
            "alice",
            json!({"labels": connection(&[("bug", "d73a4a"), ("good first issue", "7057FF")], 2)}),
        ));
        w.prs.push(pr_node(
            "PR_2",
            "org",
            2,
            "alice",
            json!({"labels": connection(&many, 23)}),
        ));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let status = github
        .requests()
        .into_iter()
        .find(|r| r.op.as_deref() == Some("Status"))
        .unwrap();
    assert!(
        status.query().contains(
            "labels(first: 20, orderBy: {field: NAME, direction: ASC}) { totalCount nodes { name color } }"
        ),
        "{}",
        status.query()
    );
    let one = card(&daemon, "org/app#1");
    assert_eq!(
        one["labels"],
        labels(&[("bug", "d73a4a"), ("good first issue", "7057FF")])
    );
    assert_eq!(one["labels_more"], 0);
    let two = card(&daemon, "org/app#2");
    assert_eq!(two["labels"].as_array().unwrap().len(), 20);
    assert_eq!(two["labels"][0]["name"], "area-00");
    assert_eq!(two["labels_more"], 3);

    // A new label: the card follows the next status, with no row.
    github.with(|w| {
        w.prs[0]["labels"] = connection(&[("bug", "d73a4a"), ("urgent", "B60205")], 2);
    });
    daemon.clock(T0 + 200);
    let one = card(&daemon, "org/app#1");
    assert_eq!(one["labels"][1]["name"], "urgent");
    assert_eq!(one["rows"], json!([]));

    // A status that fails keeps the labels.
    github.intercept(|req| {
        (req.op.as_deref() == Some("Status")).then(|| Resp::json(502, json!({"message":"bad"})))
    });
    github.with(|w| w.prs[0]["labels"] = connection(&[], 0));
    daemon.clock(T0 + 300);
    assert!(
        github
            .requests()
            .iter()
            .filter(|r| r.op.as_deref() == Some("Status"))
            .count()
            > 2
    );
    let one = card(&daemon, "org/app#1");
    assert_eq!(one["labels"][1]["name"], "urgent", "the labels stay");
    daemon.stop();
}

/// DESIGN.md, "Ready for review and Converted to draft rows": the timeline
/// events the `Events` request reads become rows of the PR.
#[test]
fn the_events_fetch_reads_ready_for_review_and_converted_to_draft() {
    let github = world();
    github.with(|w| {
        w.prs
            .push(pr_node("PR_1", "org", 1, "alice", json!({"isDraft": true})));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let f = T0 + 100;
    daemon.clock(f);
    // alice ends the draft; the status may still say draft.
    let url = "https://github.com/org/app/pull/1#event-21";
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(f + 50));
        w.timeline.insert(
            "PR_1".into(),
            vec![
                json!({"__typename":"ReadyForReviewEvent","id":"RFR_1","createdAt":iso(f + 50),
                       "url":url,"actor":{"__typename":"User","login":"alice",
                       "avatarUrl":"https://avatars.example/alice"}}),
                json!({"__typename":"ConvertToDraftEvent","id":"CTD_1","createdAt":iso(f + 40),
                       "url":"https://github.com/org/app/pull/1#event-20","actor":null}),
            ],
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
    assert!(events.query().contains("READY_FOR_REVIEW_EVENT"));
    assert!(events.query().contains("CONVERT_TO_DRAFT_EVENT"));
    assert!(
        events
            .query()
            .contains("... on ReadyForReviewEvent { id createdAt url actor")
    );
    assert!(events.query().contains("ASSIGNED_EVENT"));
    assert!(events.query().contains(
        "... on AssignedEvent { id createdAt actor { __typename login avatarUrl(size: 32) } \
         assignee { __typename ... on User { login } } }"
    ));
    let rows = card(&daemon, "org/app#1")["rows"].clone();
    let ready = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["kind"] == "ready_for_review")
        .unwrap()
        .clone();
    assert_eq!(ready["id"], rid("RFR_1"));
    assert_eq!(ready["url"], url);
    assert_eq!(ready["actor"], "alice");
    assert_eq!(ready["actor_avatar_url"], "https://avatars.example/alice");
    assert_eq!(ready["text"], Value::Null);
    assert_eq!(ready["unread"], true);
    let back = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["kind"] == "converted_to_draft")
        .unwrap()
        .clone();
    assert_eq!(back["actor"], Value::Null);
    // Skip draft pull requests is on and the saved status says draft: the
    // Ready for review row notifies all the same.
    let note = app.until(|e| e["event"] == "notify");
    assert_eq!(note["notification"]["rows"], json!([rid("RFR_1")]));
    daemon.stop();
}
