//! The real daemon over its socket, with injected events and a fixed clock.
#![cfg(feature = "dev-ingest")]

mod common;

use common::*;
use serde_json::{Value, json};

fn setup() -> (tempfile::TempDir, TestDaemon) {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    daemon.ok(json!({"cmd":"scope_add","owner":"org"}));
    (dir, daemon)
}

fn row_ids(rows: &Value) -> Vec<&str> {
    rows.as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_str().unwrap())
        .collect()
}

/// `stop` waits for every finished write, so restart tests need no sleep.
fn restart(daemon: TestDaemon, dir: &std::path::Path, at: i64) -> TestDaemon {
    daemon.stop();
    TestDaemon::start_at(dir, at)
}

#[test]
fn everything_saved_comes_back_after_a_restart() {
    let (dir, daemon) = setup();
    let t = T0 + 10;
    // A comment made Done, one left unread and seen, and PRs with state.
    daemon.ingest(
        vec![
            with(pr("PR_1", "me"), json!({"checks":"passed"})),
            pr("PR_2", "alice"),
            pr("PR_3", "alice"),
        ],
        vec![
            event("DONE", "PR_1", "comment", t),
            event("SEEN", "PR_2", "comment", t + 1),
            event("HELD", "PR_3", "comment", t + 2),
        ],
        vec![reaction("C_1", "PR_1", t, json!({"HEART":2}))],
    );
    daemon.ok(json!({"cmd":"done","row":"DONE"}));
    daemon.ok(json!({"cmd":"seen","row_ids":["SEEN"]}));
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#3"}));
    daemon.ingest(
        vec![],
        vec![event("HELD2", "PR_3", "mentioned", t + 3)],
        vec![],
    );
    let added = daemon.card("PR_2").unwrap()["added_at"].clone();
    let watch_probe = event("BEFORE", "PR_2", "comment", T0 - 1);

    let daemon = restart(daemon, dir.path(), T0 + 100);

    // Done, Snooze, unread and the dot.
    assert_eq!(daemon.row("DONE").unwrap()["done"], true);
    assert_eq!(daemon.card("PR_3").unwrap()["snoozed"], true);
    assert_eq!(daemon.row("SEEN").unwrap()["unread"], true);
    assert_eq!(daemon.scope("org")["dot"], true);
    assert_eq!(daemon.card("PR_2").unwrap()["added_at"], added);

    // seen_pending: closing now clears the row that was shown before.
    daemon.ok(json!({"cmd":"popover_closed","scope":"org"}));
    assert_eq!(daemon.row("SEEN").unwrap()["unread"], false);

    // Watch start: older than T0 stays out.
    daemon.ingest(vec![], vec![watch_probe], vec![]);
    assert!(daemon.row("BEFORE").is_none());

    // Previous values: the change from passed to failed is detected.
    daemon.ingest(
        vec![with(pr("PR_1", "me"), json!({"checks":"failed"}))],
        vec![],
        vec![],
    );
    let kinds: Vec<Value> = daemon.card("PR_1").unwrap()["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["kind"].clone())
        .collect();
    assert!(kinds.contains(&json!("checks_failed")), "{kinds:?}");

    // Reaction baseline: only the increase counts.
    daemon.ingest(
        vec![],
        vec![],
        vec![reaction("C_1", "PR_1", t, json!({"HEART":3}))],
    );
    let rows = daemon.card("PR_1").unwrap()["rows"].clone();
    let newest = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["kind"] == "reaction" && r["occurred_at"] == T0 + 100)
        .unwrap();
    assert_eq!(newest["counts"]["HEART"], 1);

    // last_release_at: no release before the Return time; the held rows then
    // arrive through the summary record.
    let mut app = daemon.subscribe("app");
    app.snapshot();
    let first = app.notification();
    // SEEN, two Reaction rows and Checks failed. The Done row and the held
    // rows stay out.
    assert_eq!(
        first["title"], "org · 4 new events",
        "undelivered rows are one summary"
    );
    daemon.clock(NEXT_0900);
    let summary = app.notification();
    assert_eq!(summary["title"], "org · Back from Snooze");
    assert_eq!(summary["rows"].as_array().unwrap().len(), 2);
    daemon.stop();
}

#[test]
fn last_release_at_survives_a_restart() {
    let (dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "me")], vec![], vec![]);
    daemon.clock(NEXT_0900 + 60);
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    // Restarting after today's release must not release again.
    let daemon = restart(daemon, dir.path(), NEXT_0900 + 120);
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed"], true);
    daemon.clock(NEXT_0900 + DAY);
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed"], false);
    daemon.stop();
}

#[test]
fn a_notification_written_to_the_app_is_not_sent_again_after_a_restart() {
    let (dir, daemon) = setup();
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    let notification = app.notification();
    assert_eq!(notification["type"], "single");
    assert_eq!(notification["rows"], json!(["E_1"]));

    let daemon = restart(daemon, dir.path(), T0 + 50);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    // Any later event proves the summary did not come first.
    daemon.ingest(
        vec![],
        vec![event("E_2", "PR_1", "comment", T0 + 51)],
        vec![],
    );
    assert_eq!(app.notification()["rows"], json!(["E_2"]));
    daemon.stop();
}

#[test]
fn a_write_to_a_cli_subscriber_is_not_delivery() {
    let (_dir, daemon) = setup();
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    let mut app = daemon.subscribe("app");
    app.snapshot();
    let summary = app.notification();
    assert_eq!(summary["type"], "summary");
    assert_eq!(summary["title"], "org · 1 new event");
    assert_eq!(summary["body"], "In 1 PR");
    assert_eq!(summary["subtitle"], Value::Null);
    daemon.stop();
}

#[test]
fn a_cli_subscriber_sees_notifications_too() {
    let (_dir, daemon) = setup();
    let mut app = daemon.subscribe("app");
    app.snapshot();
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    assert_eq!(cli.notification()["rows"], json!(["E_1"]));
    assert_eq!(app.notification()["rows"], json!(["E_1"]));
    daemon.stop();
}

#[test]
fn absence_becomes_one_summary_per_scope_including_snooze_rows() {
    let (_dir, daemon) = setup();
    daemon.ok(json!({"cmd":"scope_add","owner":"second"}));
    let second = with(pr("PR_3", "alice"), json!({"owner":"second"}));
    daemon.ingest(
        vec![pr("PR_1", "alice"), pr("PR_2", "alice"), second],
        vec![],
        vec![],
    );
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    daemon.ingest(
        vec![],
        vec![
            event("A", "PR_1", "comment", T0 + 1),
            event("B", "PR_1", "reply", T0 + 1),
            event("C", "PR_2", "comment", T0 + 1),
            event("D", "PR_3", "comment", T0 + 1),
        ],
        vec![],
    );
    // The release happens with no app connected.
    daemon.clock(NEXT_0900);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    let first = app.notification();
    assert_eq!(first["scope"], "org");
    assert_eq!(first["title"], "org · 3 new events");
    assert_eq!(first["body"], "In 2 PRs");
    assert_eq!(first["rows"].as_array().unwrap().len(), 3);
    let second = app.notification();
    assert_eq!(second["title"], "second · 1 new event");
    daemon.stop();
}

#[test]
fn a_summary_written_once_does_not_repeat_on_the_next_reconnect() {
    let (dir, daemon) = setup();
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    let mut app = daemon.subscribe("app");
    app.snapshot();
    assert_eq!(app.notification()["rows"], json!(["E_1"]));
    let daemon = restart(daemon, dir.path(), T0 + 50);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.ingest(
        vec![],
        vec![event("E_2", "PR_1", "comment", T0 + 51)],
        vec![],
    );
    assert_eq!(app.notification()["rows"], json!(["E_2"]));
    daemon.stop();
}

#[test]
fn back_from_snooze_goes_to_a_connected_app() {
    let (_dir, daemon) = setup();
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    daemon.ingest(
        vec![],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    daemon.clock(NEXT_0900);
    let notification = app.notification();
    assert_eq!(notification["title"], "org · Back from Snooze");
    assert_eq!(notification["body"], "1 PR had new events");
    assert_eq!(notification["rows"], json!(["E_1"]));
    daemon.stop();
}

#[test]
fn the_release_runs_at_startup_for_a_sleeping_or_stopped_daemon() {
    let (dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "me")], vec![], vec![]);
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    let daemon = restart(daemon, dir.path(), NEXT_0900 + 3 * DAY);
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed"], false);
    daemon.stop();
}

#[test]
fn dev_clock_set_runs_the_periodic_pass_before_answering() {
    let (_dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.clock(T0 + 15 * DAY);
    assert!(daemon.card("PR_1").is_none(), "dropped after 14 days");
    let event = cli.until(|e| e["event"] == "scope_changed" && e["scope"]["id"] == "org");
    assert_eq!(event["scope"]["badge"], 0);
    assert_eq!(
        daemon.code(json!({"cmd":"dev_clock_set","now":1,"tz":"Mars/Olympus"})),
        "invalid"
    );
    daemon.stop();
}

#[test]
fn an_ingest_with_a_bad_kind_or_pr_id_applies_nothing() {
    let (_dir, daemon) = setup();
    let ingest = |events: Value| {
        json!({"cmd":"dev_ingest","ingest":{
            "viewer":"me","missing_pr_ids":[],"prs":[pr("PR_1","me")],"events":events,"reactions":[]
        }})
    };
    assert_eq!(
        daemon.code(ingest(json!([event("E", "PR_1", "nope", T0 + 1)]))),
        "invalid"
    );
    assert_eq!(
        daemon.code(ingest(json!([event("E", "PR_9", "comment", T0 + 1)]))),
        "invalid"
    );
    assert!(daemon.cards().is_empty());
    daemon.ok(ingest(json!([event("E", "PR_1", "comment", T0 + 1)])));
    assert_eq!(daemon.cards().len(), 1);
    daemon.stop();
}

#[test]
fn the_sample_from_the_brief_is_accepted() {
    let (_dir, daemon) = setup();
    daemon.ok(json!({"cmd":"scope_add","owner":"example-org"}));
    let text = r#"{"cmd":"dev_ingest","ingest":{
      "viewer":"me",
      "missing_pr_ids":[],
      "prs":[{"id":"PR_1","owner":"example-org","repo":"app","number":1,"url":"https://github.example/1","title":"Fix","author":"me","base":"main","head":"fix","state":"open","is_draft":false,"review":"none","checks":"failed","base_status":"up_to_date","mergeable":false,"failed_check":"build","changes_requested_by":null,"updated_at":1800000000,"is_private":false,"requested_me":false,"links":{"review":"https://github.example/1/r","checks":"https://github.example/1/c","base":"https://github.example/1/b"}}],
      "events":[{"id":"E_1","pr_id":"PR_1","kind":"comment","occurred_at":1800000000,"url":"https://github.example/1#c","actor":"alice","text":"Looks good","comment_id":"C_1"}],
      "reactions":[{"comment_id":"C_2","pr_id":"PR_1","url":"https://github.example/1#d","text":"Done","comment_created_at":1800000000,"counts":{"THUMBS_UP":2},"watching":true}]
    }}"#.replace('\n', " ");
    assert_eq!(daemon.raw(&text)["ok"], true);
    let card = daemon.card("PR_1").unwrap();
    assert_eq!(card["pr"], "example-org/app#1");
    assert_eq!(card["state_label"], "open");
    assert_eq!(card["mine"], true);
    assert_eq!(card["rows"].as_array().unwrap().len(), 2);
    daemon.stop();
}

#[test]
fn scope_changed_goes_out_on_value_and_row_changes_only() {
    let (_dir, daemon) = setup();
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    let event = cli.until(|e| e["event"] == "scope_changed");
    assert_eq!(event["scope"]["id"], "org");
    assert_eq!(event["scope"]["badge"], 1);
    assert_eq!(event["scope"]["dot"], true);

    // Reads and `seen` change nothing a client shows.
    daemon.ok(json!({"cmd":"list"}));
    daemon.ok(json!({"cmd":"seen","row_ids":["E_1"]}));
    // `done` changes a row. It must be the very next event.
    daemon.ok(json!({"cmd":"done","row":"E_1"}));
    let event = cli.next().unwrap();
    assert_eq!(event["event"], "scope_changed");
    assert_eq!(event["scope"]["badge"], 0);
    daemon.stop();
}

#[test]
fn removing_a_scope_disconnects_subscribers_and_the_next_snapshot_lacks_it() {
    let (_dir, daemon) = setup();
    let mut app = daemon.subscribe("app");
    let mut cli = daemon.subscribe("cli");
    assert_eq!(app.snapshot()["scopes"].as_array().unwrap().len(), 2);
    cli.snapshot();
    daemon.ok(json!({"cmd":"scope_remove","owner":"org"}));
    app.until_closed();
    cli.until_closed();
    let snapshot = daemon.subscribe("cli").snapshot();
    let scopes = snapshot["scopes"].as_array().unwrap();
    assert_eq!(scopes.len(), 1);
    assert_eq!(scopes[0]["id"], "public");
    daemon.stop();
}

#[test]
fn a_disconnecting_app_ends_the_open_state_and_seen_pending_survives() {
    let (_dir, daemon) = setup();
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.ok(json!({"cmd":"popover_opened","scope":"org"}));
    assert_eq!(daemon.scope("org")["dot"], false);
    daemon.ok(json!({"cmd":"seen","row_ids":["E_1"]}));
    app.close();

    // The daemon notices the close on its own task, so retry with new rows
    // until a row raises the dot. Each attempt is a round trip, not a sleep.
    let mut attempt = 0;
    while daemon.scope("org")["dot"] != true {
        attempt += 1;
        assert!(attempt < 10_000, "the open state never ended");
        let id = format!("L_{attempt}");
        daemon.ingest(vec![], vec![event(&id, "PR_1", "merged", T0 + 2)], vec![]);
    }
    assert_eq!(daemon.row("E_1").unwrap()["unread"], true);
    daemon.ok(json!({"cmd":"popover_closed","scope":"org"}));
    assert_eq!(daemon.row("E_1").unwrap()["unread"], false);
    daemon.stop();
}

#[test]
fn a_restart_ends_the_open_state() {
    let (dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    daemon.ok(json!({"cmd":"popover_opened","scope":"org"}));
    let daemon = restart(daemon, dir.path(), T0 + 5);
    daemon.ingest(vec![], vec![event("E_1", "PR_1", "merged", T0 + 6)], vec![]);
    assert_eq!(daemon.scope("org")["dot"], true);
    daemon.stop();
}

#[test]
fn a_slow_client_is_disconnected_and_recovers_by_reconnecting() {
    let (_dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    let mut slow = daemon.subscribe("cli");
    slow.snapshot();
    // The slow client reads nothing while long notifications outgrow both the
    // socket buffer and the 256 line queue. The app keeps up, which also shows
    // one slow client does not hold the others back.
    let text = "x".repeat(4096);
    let events = 400;
    for n in 0..events {
        let long = with(
            event(&format!("E_{n}"), "PR_1", "comment", T0 + 1),
            json!({"text": text}),
        );
        daemon.ingest(vec![], vec![long], vec![]);
        assert_eq!(app.notification()["body"], text.as_str());
    }
    // A connection that stayed open would time out here and fail the test.
    let received = slow.until_closed();
    assert!(received.len() < 2 * events, "{}", received.len());
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["scopes"].as_array().unwrap().len(), 2);
    daemon.stop();
}

#[test]
fn damage_under_a_running_daemon_moves_it_to_the_waiting_state() {
    let (dir, daemon) = setup();
    // A Merged row is never notified, so no delivery is being saved while the
    // file gets damaged.
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "merged", T0 + 1)],
        vec![],
    );
    let mut app = daemon.subscribe("app");
    let mut cli = daemon.subscribe("cli");
    app.snapshot();
    cli.snapshot();

    let db = dir.path().join("state.db");
    let damaged = vec![0xCD; std::fs::metadata(&db).unwrap().len() as usize];
    std::fs::write(&db, &damaged).unwrap();

    assert_eq!(daemon.code(json!({"cmd":"list"})), "internal");
    app.until_closed();
    cli.until_closed();
    assert_eq!(std::fs::read(&db).unwrap(), damaged, "left as it was");

    let mut waiting = daemon.subscribe("app");
    let snapshot = waiting.snapshot();
    assert_eq!(snapshot["db_unreadable"], true);
    assert_eq!(snapshot["scopes"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["scopes"][0]["id"], "public");
    assert_eq!(snapshot["scopes"][0]["badge"], 0);
    assert_eq!(snapshot["scopes"][0]["dot"], false);
    daemon.ok(json!({"cmd":"info"}));

    daemon.ok(json!({"cmd":"reset"}));
    waiting.until_closed();
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], false);
    let retired = dir.path().join(format!("state.db.corrupt-{T0}"));
    assert_eq!(std::fs::read(&retired).unwrap(), damaged);
    assert_eq!(mode(&retired), 0o600);

    // Normal operation, from an empty state.
    assert!(daemon.scopes().iter().all(|s| s["id"] == "public"));
    assert!(daemon.cards().is_empty());
    let public = with(pr("PR_2", "alice"), json!({"owner":"stranger"}));
    daemon.ingest(
        vec![public],
        vec![event("E_2", "PR_2", "comment", T0 + 1)],
        vec![],
    );
    assert_eq!(daemon.scope("public")["badge"], 1);
    daemon.stop();
}

#[test]
fn damage_is_noticed_by_reset_and_by_a_snapshot() {
    let (dir, daemon) = setup();
    let db = dir.path().join("state.db");
    std::fs::write(&db, vec![0xEE; 4096]).unwrap();
    daemon.ok(json!({"cmd":"reset"}));
    assert!(dir.path().join(format!("state.db.corrupt-{T0}")).exists());

    std::fs::write(&db, vec![0xEF; 4096]).unwrap();
    let mut cli = daemon.subscribe("cli");
    assert_eq!(
        cli.snapshot()["db_unreadable"],
        true,
        "a snapshot checks the file"
    );
    daemon.ok(json!({"cmd":"reset"}));
    assert!(
        dir.path()
            .join(format!("state.db.corrupt-{}", T0 + 1))
            .exists(),
        "the first retired file is not overwritten"
    );
    daemon.stop();
}

#[test]
fn activity_order_and_filters_over_the_socket() {
    let (_dir, daemon) = setup();
    daemon.ingest(
        vec![
            with(pr("PR_1", "me"), json!({"checks":"failed"})),
            pr("PR_2", "alice"),
            with(pr("PR_3", "alice"), json!({"owner":"stranger"})),
        ],
        vec![
            event("B", "PR_2", "comment", T0 + 5),
            event("A", "PR_2", "merged", T0 + 5),
            event("C", "PR_1", "merged", T0 + 9),
            event("D", "PR_3", "merged", T0 + 1),
        ],
        vec![],
    );
    let activity = |args: Value| {
        let mut request = json!({"cmd":"activity"});
        for (key, value) in args.as_object().unwrap() {
            request[key] = value.clone();
        }
        let response = daemon.ok(request);
        row_ids(&response["rows"])
            .into_iter()
            .map(String::from)
            .collect::<Vec<_>>()
    };
    assert_eq!(activity(json!({})), ["C", "A", "B", "D"]);
    assert_eq!(activity(json!({"scope":"public"})), ["D"]);
    assert_eq!(activity(json!({"mine":true})), ["C"]);
    assert_eq!(activity(json!({"others":true})), ["A", "B", "D"]);
    assert_eq!(activity(json!({"needs_action":true})), ["C", "A", "B"]);
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#2"}));
    assert_eq!(activity(json!({})), ["C", "D"]);
    assert_eq!(activity(json!({"snoozed":true})), ["C", "A", "B", "D"]);
    assert_eq!(activity(json!({"needs_action":true,"snoozed":true})), ["C"]);
    daemon.stop();
}

#[test]
fn error_codes_table() {
    let (_dir, daemon) = setup();
    daemon.ingest(
        vec![
            with(pr("PR_1", "alice"), json!({"is_draft":true})),
            pr("PR_2", "alice"),
        ],
        vec![event("E_1", "PR_2", "merged", T0 + 1)],
        vec![],
    );
    let cases = [
        (json!({"cmd":"done","row":"nope"}), "not_found"),
        (json!({"cmd":"undone","row":"nope"}), "not_found"),
        (json!({"cmd":"snooze","pr":"a/b#1"}), "not_found"),
        (json!({"cmd":"unsnooze","pr":"a/b#1"}), "not_found"),
        (json!({"cmd":"status","pr":"a/b#1"}), "not_found"),
        (json!({"cmd":"open","pr":"a/b#1"}), "not_found"),
        (json!({"cmd":"open","row":"nope"}), "not_found"),
        (json!({"cmd":"snooze","pr":"org/app#1"}), "not_found"),
        (json!({"cmd":"list","scope":"nobody"}), "not_found"),
        (json!({"cmd":"scope_remove","owner":"nobody"}), "not_found"),
        (
            json!({"cmd":"popover_opened","scope":"nobody"}),
            "not_found",
        ),
        (json!({"cmd":"config_get","key":"nope"}), "invalid"),
        (
            json!({"cmd":"config_set","key":"notify_state","value":"nope"}),
            "invalid",
        ),
        (json!({"cmd":"scope_add","owner":"public"}), "invalid"),
        (json!({"cmd":"scope_add","owner":"org"}), "invalid"),
        (json!({"cmd":"scope_remove","owner":"public"}), "invalid"),
    ];
    for (request, code) in cases {
        assert_eq!(daemon.code(request.clone()), code, "{request}");
    }
    daemon.ok(json!({"cmd":"done","row":"E_1"}));
    daemon.ok(json!({"cmd":"seen","row_ids":["nope","E_1"]}));
    daemon.ok(json!({"cmd":"status","pr":"org/app#1"}));
    daemon.ok(json!({"cmd":"open","pr":"org/app#1"}));
    daemon.stop();
}

#[test]
fn a_long_snapshot_arrives_as_one_line() {
    let (_dir, daemon) = setup();
    for n in 0..300 {
        daemon.ok(json!({"cmd":"scope_add","owner":format!("owner-{n}-{}", "x".repeat(100))}));
    }
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["scopes"].as_array().unwrap().len(), 302);
    daemon.stop();
}

#[test]
fn state_change_rows_from_the_same_second_are_told_apart_by_moving_the_clock() {
    let (_dir, daemon) = setup();
    let passed = with(pr("PR_1", "me"), json!({"checks":"passed"}));
    let failed = with(
        pr("PR_1", "me"),
        json!({"checks":"failed","failed_check":"build"}),
    );
    daemon.ingest(vec![passed.clone()], vec![], vec![]);
    daemon.ingest(vec![failed.clone()], vec![], vec![]);
    daemon.ingest(vec![passed.clone()], vec![], vec![]);
    daemon.ingest(vec![failed.clone()], vec![], vec![]);
    assert_eq!(
        daemon.card("PR_1").unwrap()["rows"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    daemon.clock(T0 + 1);
    daemon.ingest(vec![passed], vec![], vec![]);
    daemon.ingest(vec![failed], vec![], vec![]);
    assert_eq!(
        daemon.card("PR_1").unwrap()["rows"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    daemon.stop();
}

const NEW_YORK: &str = "America/New_York";

#[test]
fn a_return_time_inside_a_dst_gap_lands_after_the_gap() {
    let (_dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "me")], vec![], vec![]);
    let after_gap = epoch("2027-03-14 03:30 -0400");
    daemon.clock_in(epoch("2027-03-14 00:00 -0500"), NEW_YORK);
    daemon.ok(json!({"cmd":"config_set","key":"snooze_return_time","value":"02:30"}));
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed_until"], after_gap);
    daemon.clock_in(after_gap - 1, NEW_YORK);
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed"], true);
    daemon.clock_in(after_gap, NEW_YORK);
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed"], false);
    daemon.stop();
}

#[test]
fn a_return_time_inside_a_dst_fold_fires_once() {
    let (_dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "me")], vec![], vec![]);
    let first = epoch("2027-11-07 01:30 -0400");
    let second = epoch("2027-11-07 01:30 -0500");
    daemon.clock_in(first - 3600, NEW_YORK);
    daemon.ok(json!({"cmd":"config_set","key":"snooze_return_time","value":"01:30"}));
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed_until"], first);
    daemon.clock_in(first, NEW_YORK);
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed"], false);
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    daemon.clock_in(second, NEW_YORK);
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed"], true);
    daemon.stop();
}

#[test]
fn a_time_zone_change_moves_snoozed_until_for_a_snoozed_pr() {
    let (_dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "me")], vec![], vec![]);
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed_until"], NEXT_0900);
    daemon.clock_in(T0 + 60, "Europe/London");
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed_until"], T0 + 3600);
    daemon.stop();
}

#[test]
fn a_startup_release_without_an_app_is_a_new_events_summary() {
    let (dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    daemon.ingest(
        vec![],
        vec![
            event("A", "PR_1", "comment", T0 + 1),
            event("B", "PR_1", "reply", T0 + 2),
        ],
        vec![],
    );
    let daemon = restart(daemon, dir.path(), NEXT_0900 + 60);
    assert_eq!(daemon.card("PR_1").unwrap()["snoozed"], false);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    let summary = app.notification();
    assert_eq!(summary["title"], "org · 2 new events");
    assert_eq!(summary["body"], "In 1 PR");
    // A later row proves no `Back from Snooze` follows the summary.
    daemon.ingest(
        vec![],
        vec![event("C", "PR_1", "comment", NEXT_0900 + 61)],
        vec![],
    );
    let next = app.notification();
    assert_eq!(next["rows"], json!(["C"]));
    daemon.stop();
}

#[test]
fn a_slow_app_loses_no_row_and_gets_none_twice() {
    let (_dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    let mut slow = daemon.subscribe("app");
    // Registered before the first row, and read nothing more from here on.
    slow.snapshot();
    let text = "x".repeat(4096);
    let total = 400;
    for n in 0..total {
        let long = with(
            event(&format!("E_{n}"), "PR_1", "comment", T0 + 1),
            json!({"text": text}),
        );
        daemon.ingest(vec![], vec![long], vec![]);
    }

    let mut received: Vec<String> = Vec::new();
    let mut collect = |notification: &Value| {
        for row in notification["rows"].as_array().unwrap() {
            received.push(row.as_str().unwrap().to_string());
        }
    };
    for event in slow.until_closed() {
        if event["event"] == "notify" {
            assert_eq!(event["notification"]["type"], "single");
            collect(&event["notification"]);
        }
    }
    let mut app = daemon.subscribe("app");
    assert_eq!(app.snapshot()["event"], "snapshot");
    let summary = app.notification();
    assert_eq!(summary["type"], "summary");
    collect(&summary);

    let mut unique = received.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), received.len(), "a row arrived twice");
    assert_eq!(received.len(), total, "a row was lost");
    daemon.stop();
}

/// `scope_changed` for `org` is the very next event after the action.
#[test]
fn scope_changed_table() {
    type Step = fn(&TestDaemon);
    let cases: [(&str, Step, Step); 7] = [
        (
            "release at the Return time",
            |d| {
                d.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
            },
            |d| d.clock(NEXT_0900),
        ),
        (
            "manual unsnooze",
            |d| {
                d.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
            },
            |d| {
                d.ok(json!({"cmd":"unsnooze","pr":"org/app#1"}));
            },
        ),
        (
            "popover_opened clears the dot",
            |_| {},
            |d| {
                d.ok(json!({"cmd":"popover_opened","scope":"org"}));
            },
        ),
        (
            "popover_closed reads a row",
            |d| {
                d.ok(json!({"cmd":"seen","row_ids":["E_1"]}));
            },
            |d| {
                d.ok(json!({"cmd":"popover_closed","scope":"org"}));
            },
        ),
        (
            "bot_comments hides a row",
            |_| {},
            |d| {
                d.ok(json!({"cmd":"config_set","key":"bot_comments","value":"hide"}));
            },
        ),
        (
            "drop_after_days drops a card",
            |d| d.clock(T0 + 2 * DAY),
            |d| {
                d.ok(json!({"cmd":"config_set","key":"drop_after_days","value":1}));
            },
        ),
        (
            "snooze_return_time moves snoozed_until",
            |d| {
                d.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
            },
            |d| {
                d.ok(json!({"cmd":"config_set","key":"snooze_return_time","value":"10:00"}));
            },
        ),
    ];
    for (name, arrange, act) in cases {
        let (_dir, daemon) = setup();
        daemon.ingest(
            vec![pr("PR_1", "alice"), pr("PR_2", "alice")],
            vec![event("E_1", "PR_2", "bot_comment", T0 + 1)],
            vec![],
        );
        arrange(&daemon);
        let mut cli = daemon.subscribe("cli");
        cli.snapshot();
        act(&daemon);
        let event = cli.next().expect(name);
        assert_eq!(event["event"], "scope_changed", "{name}");
        assert_eq!(event["scope"]["id"], "org", "{name}");
        daemon.stop();
    }
}

/// Nothing a client shows changed, so the sentinel is the next event.
#[test]
fn no_scope_changed_table() {
    type Step = fn(&TestDaemon);
    let cases: [(&str, Step); 4] = [
        ("a read", |d| {
            d.ok(json!({"cmd":"activity"}));
        }),
        ("a setting nothing shows", |d| {
            d.ok(json!({"cmd":"config_set","key":"notify_state","value":false}));
        }),
        ("opening without a dot", |d| {
            d.ok(json!({"cmd":"popover_opened","scope":"org"}));
        }),
        ("closing with nothing seen", |d| {
            d.ok(json!({"cmd":"popover_closed","scope":"org"}));
        }),
    ];
    for (name, act) in cases {
        let (_dir, daemon) = setup();
        daemon.ingest(vec![pr("PR_1", "me")], vec![], vec![]);
        let mut cli = daemon.subscribe("cli");
        cli.snapshot();
        act(&daemon);
        daemon.ok(json!({"cmd":"scope_notify","scope":"public","on":false}));
        let event = cli.next().expect(name);
        assert_eq!(event["scope"]["id"], "public", "{name}");
        daemon.stop();
    }
}

#[test]
fn a_readable_again_pr_raises_the_dot_through_the_daemon() {
    let (_dir, daemon) = setup();
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "merged", T0 + 1)],
        vec![],
    );
    daemon.ok(json!({"cmd":"popover_opened","scope":"org"}));
    daemon.ok(json!({"cmd":"popover_closed","scope":"org"}));
    assert_eq!(daemon.scope("org")["dot"], false);
    daemon.ok(json!({"cmd":"dev_ingest","ingest":{
        "viewer":"me","missing_pr_ids":["PR_1"],"prs":[],"events":[],"reactions":[]
    }}));
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    assert_eq!(daemon.scope("org")["dot"], true);
    daemon.stop();
}
