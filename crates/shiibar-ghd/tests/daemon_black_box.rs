//! The real daemon over its socket, with injected events and a fixed clock.
#![cfg(feature = "dev-ingest")]

mod common;

use common::*;
use serde_json::{Value, json};

fn setup() -> (tempfile::TempDir, TestDaemon) {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    daemon.setup_account();
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
    // A comment read, one left unread, and PRs with state.
    daemon.ingest(
        vec![
            with(pr("PR_1", "me"), json!({"checks":"passed"})),
            with(
                pr("PR_2", "alice"),
                json!({"author_avatar_url":"https://avatars.example/alice"}),
            ),
            pr("PR_3", "alice"),
        ],
        vec![
            event("READ", "PR_1", "comment", t),
            event("SEEN", "PR_2", "comment", t + 1),
            event("HELD", "PR_3", "comment", t + 2),
        ],
        vec![reaction("C_1", "PR_1", t, json!({"HEART":2}))],
    );
    daemon.ok(json!({"cmd":"read","row_ids":["1001:READ"]}));
    daemon.ok(
        json!({"cmd":"place","account":"me","pr":"org/app#3","tab":"review","section":"waiting"}),
    );
    daemon.ok(json!({"cmd":"mute","account":"me","kind":"user","name":"bob"}));
    daemon.ingest(vec![pr("PR_4", "alice")], vec![], vec![]);
    daemon.ok(json!({"cmd":"dismiss","account":"me","pr":"org/app#4"}));
    daemon.ok(json!({"cmd":"account_color","account":"me","color":"purple"}));
    daemon.ingest(
        vec![],
        vec![event("HELD2", "PR_3", "mentioned", t + 3)],
        vec![],
    );
    let added = daemon.card("PR_2").unwrap()["added_at"].clone();
    let watch_probe = event("BEFORE", "PR_2", "comment", T0 - 1);

    let daemon = restart(daemon, dir.path(), T0 + 100);

    // Read, place, Dismiss, Mute, unread, the dot and the created time.
    assert_eq!(daemon.row("READ").unwrap()["unread"], false);
    assert_eq!(daemon.card("PR_1").unwrap()["created_at"], T0 - 86_400);
    assert_eq!(
        daemon.card("PR_3").unwrap()["placement"],
        json!({"tab":"review","section":"waiting","position":0})
    );
    assert_eq!(daemon.card("PR_1").unwrap()["placement"]["tab"], "mine");
    assert_eq!(daemon.card("PR_4").unwrap()["dismissed_at"], T0);
    assert_eq!(
        daemon.ok(json!({"cmd":"mutes_get","account":"me"}))["mutes"],
        json!({"repos":[],"users":["bob"],"prs":[]})
    );
    assert_eq!(daemon.row("SEEN").unwrap()["unread"], true);
    assert_eq!(daemon.account("me")["unread"], true);
    assert_eq!(daemon.card("PR_2").unwrap()["added_at"], added);

    // The account color and the author's avatar.
    assert_eq!(daemon.account("me")["color"], "purple");
    assert_eq!(
        daemon.card("PR_2").unwrap()["author_avatar_url"],
        "https://avatars.example/alice"
    );
    assert_eq!(
        daemon.card("PR_1").unwrap()["author_avatar_url"],
        Value::Null
    );

    // Closing reads nothing.
    daemon.ok(json!({"cmd":"popover_closed","account":"me"}));
    assert_eq!(daemon.row("SEEN").unwrap()["unread"], true);

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

    // The undelivered rows arrive as one summary: SEEN, HELD, HELD2, two
    // Reaction rows and Checks failed. The read row stays out.
    let mut app = daemon.subscribe("app");
    app.snapshot();
    let first = app.notification();
    assert_eq!(
        first["title"], "me · 6 new events",
        "undelivered rows are one summary"
    );
    assert_eq!(first["subtitle"], "org · in 3 PRs");
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
    assert_eq!(notification["rows"], json!(["1001:E_1"]));

    let daemon = restart(daemon, dir.path(), T0 + 50);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    // Any later event proves the summary did not come first.
    daemon.ingest(
        vec![],
        vec![event("E_2", "PR_1", "comment", T0 + 51)],
        vec![],
    );
    assert_eq!(app.notification()["rows"], json!(["1001:E_2"]));
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
    // One undelivered notification of a scope goes out as it is.
    let summary = app.notification();
    assert_eq!(summary["type"], "single");
    assert_eq!(summary["title"], "me · Comment on my PR");
    assert_eq!(summary["body"], "text E_1");
    assert_eq!(summary["subtitle"], "org/app #1 · Title PR_1");
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
    assert_eq!(cli.notification()["rows"], json!(["1001:E_1"]));
    assert_eq!(app.notification()["rows"], json!(["1001:E_1"]));
    daemon.stop();
}

#[test]
fn absence_becomes_one_summary_per_scope() {
    let (_dir, daemon) = setup();
    daemon.ok(json!({"cmd":"dev_owner_add","account":"me","owner":"second","kind":"org"}));
    let second = with(pr("PR_3", "alice"), json!({"owner":"second"}));
    daemon.ingest(
        vec![pr("PR_1", "alice"), pr("PR_2", "alice"), second],
        vec![],
        vec![],
    );
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
    // Made with no app connected.
    let mut app = daemon.subscribe("app");
    app.snapshot();
    let first = app.notification();
    assert_eq!(first["account"], ACCOUNT);
    assert_eq!(first["owner"], daemon.owner("me", "org")["id"]);
    assert_eq!(first["title"], "me · 3 new events");
    assert_eq!(first["subtitle"], "org · in 2 PRs");
    assert_eq!(first["body"], Value::Null);
    assert_eq!(first["rows"].as_array().unwrap().len(), 3);
    let second = app.notification();
    assert_eq!(
        second["title"], "me · Comment on my PR",
        "one is individual"
    );
    assert_eq!(second["owner"], daemon.owner("me", "second")["id"]);
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
    assert_eq!(app.notification()["rows"], json!(["1001:E_1"]));
    let daemon = restart(daemon, dir.path(), T0 + 50);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.ingest(
        vec![],
        vec![event("E_2", "PR_1", "comment", T0 + 51)],
        vec![],
    );
    assert_eq!(app.notification()["rows"], json!(["1001:E_2"]));
    daemon.stop();
}

#[test]
fn the_automatic_dismiss_runs_at_startup_for_a_sleeping_or_stopped_daemon() {
    // DESIGN.md, "Dismiss": n days after the merge was detected.
    let (dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "me")], vec![], vec![]);
    daemon.ingest(
        vec![with(pr("PR_1", "me"), json!({"state":"merged"}))],
        vec![],
        vec![],
    );
    let daemon = restart(daemon, dir.path(), T0 + 3 * DAY);
    let card = daemon.card("PR_1").unwrap();
    assert_eq!(card["dismissed_at"], T0 + 3 * DAY);
    assert_eq!(card["dismiss_expires_at"], T0 + 10 * DAY);
    daemon.stop();
}

#[test]
fn dev_clock_set_runs_the_periodic_pass_before_answering() {
    let (_dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    daemon.ingest(
        vec![with(pr("PR_1", "alice"), json!({"state":"closed"}))],
        vec![],
        vec![],
    );
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.clock(T0 + 3 * DAY);
    let listed = daemon.ok(json!({"cmd":"list"}))["cards"].clone();
    assert!(
        listed.as_array().unwrap().is_empty(),
        "dismissed after 3 days"
    );
    let event = cli.until(|e| e["event"] == "account_changed");
    assert_eq!(event["account"]["id"], ACCOUNT);
    assert_eq!(event["account"]["owners"][0]["pr_count"], 0);
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
        json!({"cmd":"dev_ingest","account":"me","ingest":{
            "missing_pr_ids":[],"prs":[pr("PR_1","me")],"events":events,"reactions":[]
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
    assert_eq!(
        daemon.code(ingest(json!([event("E", "PR_1", "bot_comment", T0 + 1)]))),
        "invalid",
        "0.1's kinds are gone"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"dev_ingest","account":"nobody","ingest":{}})),
        "not_found"
    );
    assert!(daemon.cards().is_empty());
    daemon.ok(ingest(json!([event("E", "PR_1", "comment", T0 + 1)])));
    assert_eq!(daemon.cards().len(), 1);
    daemon.stop();
}

#[test]
fn a_dev_ingest_with_accounts_assignees_and_the_new_kinds_is_accepted() {
    let (_dir, daemon) = setup();
    daemon.ok(json!({"cmd":"dev_owner_add","account":"me","owner":"example-org","kind":"org","github_id":7}));
    let text = r#"{"cmd":"dev_ingest","account":"me","ingest":{
      "missing_pr_ids":[],
      "prs":[{"id":"PR_1","owner":"example-org","repo":"app","number":1,"url":"https://github.example/1","title":"Fix","author":"me","base":"main","head":"fix","state":"open","is_draft":false,"review":"none","checks":"failed","base_status":"up_to_date","mergeable":false,"failed_check":"build","changes_requested_by":null,"updated_at":1800000000,"created_at":1799990000,"is_private":false,"requested_me":false,"requested_team":true,"assignees":["me"],"links":{"review":"https://github.example/1/r","checks":"https://github.example/1/c","base":"https://github.example/1/b"}}],
      "events":[{"id":"E_1","pr_id":"PR_1","kind":"approved","occurred_at":1800000000,"url":"https://github.example/1#r","actor":"alice","text":null,"comment_id":null},
                {"id":"E_2","pr_id":"PR_1","kind":"team_review_requested","occurred_at":1800000000,"url":"https://github.example/1","actor":"bob","text":"for core team","comment_id":null},
                {"id":"E_3","pr_id":"PR_1","kind":"team_mentioned","occurred_at":1800000000,"url":"https://github.example/1#c","actor":"carol","text":"hi","comment_id":"C_3"},
                {"id":"E_4","pr_id":"PR_1","kind":"reply_mentioned","occurred_at":1800000000,"url":"https://github.example/1#d","actor":"dave","text":"ok","comment_id":"C_4"}],
      "reactions":[{"comment_id":"C_2","pr_id":"PR_1","url":"https://github.example/1#d","text":"Done","comment_created_at":1800000000,"counts":{"THUMBS_UP":2},"watching":true}],
      "succeeded_owners":["example-org"]
    }}"#.replace('\n', " ");
    assert_eq!(daemon.raw(&text)["ok"], true);
    let card = daemon.card("PR_1").unwrap();
    assert_eq!(card["pr"], "example-org/app#1");
    assert_eq!(card["account"], ACCOUNT);
    assert_eq!(card["owner"], daemon.owner("me", "example-org")["id"]);
    assert_eq!(card["authored_by_me"], true);
    assert_eq!(card["assigned_to_me"], true);
    assert_eq!(card["review_requested"], true);
    let mut kinds: Vec<String> = card["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["kind"].as_str().unwrap().to_string())
        .collect();
    kinds.sort();
    assert_eq!(
        kinds,
        [
            "approved",
            "reaction",
            "reply_mentioned",
            "team_mentioned",
            "team_review_requested"
        ]
    );
    assert!(daemon.row("E_1:approved").is_some());
    daemon.stop();
}

#[test]
fn account_changed_goes_out_on_value_and_row_changes_only() {
    let (_dir, daemon) = setup();
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.ingest(
        vec![with(pr("PR_1", "alice"), json!({"requested_me": true}))],
        vec![event("E_1", "PR_1", "review_requested", T0 + 1)],
        vec![],
    );
    let event = cli.until(|e| e["event"] == "account_changed");
    assert_eq!(event["account"]["id"], ACCOUNT);
    assert!(event["account"].get("review_count").is_none());
    assert_eq!(event["account"]["unread"], true);

    // Requests that read change nothing a client shows; opening the
    // popover clears the dot.
    daemon.ok(json!({"cmd":"list"}));
    daemon.ok(json!({"cmd":"activity"}));
    daemon.ok(json!({"cmd":"open","row":"1001:E_1"}));
    // `read` changes a row. It must be the very next event.
    daemon.ok(json!({"cmd":"read","row_ids":["1001:E_1"]}));
    let event = cli.next().unwrap();
    assert_eq!(event["event"], "account_changed");
    assert_eq!(daemon.row("E_1").unwrap()["unread"], false);
    assert_eq!(
        daemon.card("PR_1").unwrap()["awaiting_review"],
        true,
        "reading the request row keeps the PR awaiting review"
    );
    daemon.stop();
}

#[test]
fn removing_an_owner_or_an_account_is_an_event_not_a_disconnect() {
    let (_dir, daemon) = setup();
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    let mut cli = daemon.subscribe("cli");
    assert_eq!(
        cli.snapshot()["accounts"][0]["owners"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let response = daemon.ok(json!({"cmd":"owner_remove","account":"me","owner":"ORG"}));
    assert_eq!(response["account"]["owners"].as_array().unwrap().len(), 1);
    let event = cli.next().unwrap();
    assert_eq!(event["event"], "account_changed");
    assert_eq!(event["account"]["owners"][0]["kind"], "public");
    assert!(daemon.card("PR_1").is_none(), "its PRs are gone");
    // Adding it again starts empty.
    daemon.ok(json!({"cmd":"dev_owner_add","account":"me","owner":"org","kind":"org"}));
    cli.next().unwrap();
    assert!(daemon.card("PR_1").is_none());

    daemon.ok(json!({"cmd":"account_remove","account":"me"}));
    assert_eq!(
        cli.next().unwrap(),
        json!({"event":"account_removed","id":ACCOUNT})
    );
    assert!(daemon.accounts().is_empty());
    assert_eq!(daemon.subscribe("cli").snapshot()["accounts"], json!([]));
    daemon.stop();
}

#[test]
fn a_disconnecting_app_ends_the_open_state_and_reads_nothing() {
    let (_dir, daemon) = setup();
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.ok(json!({"cmd":"popover_opened","account":"me"}));
    assert_eq!(daemon.account("me")["unread"], false);
    app.close();

    // The daemon notices the close on its own task, so retry with new rows
    // until a row raises the dot. Each attempt is a round trip, not a sleep.
    let mut attempt = 0;
    while daemon.account("me")["unread"] != true {
        attempt += 1;
        assert!(attempt < 10_000, "the open state never ended");
        let id = format!("L_{attempt}");
        daemon.ingest(vec![], vec![event(&id, "PR_1", "merged", T0 + 2)], vec![]);
    }
    assert_eq!(daemon.row("E_1").unwrap()["unread"], true);
    daemon.ok(json!({"cmd":"popover_closed","account":"me"}));
    assert_eq!(daemon.row("E_1").unwrap()["unread"], true);
    daemon.stop();
}

#[test]
fn a_restart_ends_the_open_state() {
    let (dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    daemon.ok(json!({"cmd":"popover_opened","account":"me"}));
    let daemon = restart(daemon, dir.path(), T0 + 5);
    daemon.ingest(vec![], vec![event("E_1", "PR_1", "merged", T0 + 6)], vec![]);
    assert_eq!(daemon.account("me")["unread"], true);
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
    // Each row is newer than the last: the newest 20 stay and the older
    // ones go, but every row is notified when made.
    for n in 0..events {
        let long = with(
            event(&format!("E_{n}"), "PR_1", "comment", T0 + 1 + n),
            json!({"text": text}),
        );
        daemon.ingest(vec![], vec![long], vec![]);
        assert_eq!(app.notification()["body"], text.as_str());
    }
    // A connection that stayed open would time out here and fail the test.
    let received = slow.until_closed();
    assert!(received.len() < 2 * events as usize, "{}", received.len());
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["accounts"].as_array().unwrap().len(), 1);
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
    assert_eq!(
        snapshot["accounts"],
        json!([]),
        "no account while unreadable"
    );
    daemon.ok(json!({"cmd":"info"}));

    daemon.ok(json!({"cmd":"reset"}));
    waiting.until_closed();
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], false);
    let retired = dir.path().join(format!("state.db.corrupt-{T0}"));
    assert_eq!(std::fs::read(&retired).unwrap(), damaged);
    assert_eq!(mode(&retired), 0o600);

    // Normal operation, from an empty state.
    assert!(daemon.accounts().is_empty());
    daemon.ok(json!({"cmd":"refresh"}));
    assert!(
        daemon.accounts().is_empty(),
        "no Keychain item restores no account"
    );
    daemon.ok(json!({"cmd":"dev_account_add","id":ACCOUNT,"login":ME}));
    daemon.ok(json!({"cmd":"dev_owner_add","account":"me","owner":"public","kind":"public"}));
    assert!(daemon.cards().is_empty());
    let public = with(
        pr("PR_2", "alice"),
        json!({"owner":"stranger","requested_me":true}),
    );
    daemon.ingest(
        vec![public],
        vec![event("E_2", "PR_2", "comment", T0 + 1)],
        vec![],
    );
    assert_eq!(daemon.owner("me", "public")["pr_count"], 1);
    assert_eq!(daemon.card("PR_2").unwrap()["awaiting_review"], true);
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
            .map(|id| id.trim_start_matches("1001:").to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(activity(json!({})), ["C", "A", "B", "D"]);
    assert_eq!(activity(json!({"owners":["public"]})), ["D"]);
    assert_eq!(
        activity(json!({"owners":["public","org"]})),
        ["C", "A", "B", "D"]
    );
    assert_eq!(activity(json!({"filter":"authored"})), ["C"]);
    assert_eq!(activity(json!({"account":"me","search":"text b"})), ["B"]);
    assert_eq!(
        activity(json!({"search":"ORG/APP#2"})),
        ["A", "B"],
        "every row of the PR"
    );
    assert_eq!(
        activity(json!({"search":"alice text"})),
        ["C", "A", "B", "D"]
    );
    assert!(activity(json!({"search":"text nobody"})).is_empty());
    daemon.ok(json!({"cmd":"dismiss","account":"me","pr":"org/app#2"}));
    assert_eq!(activity(json!({})), ["C", "D"], "no dismissed PR");
    assert_eq!(
        daemon.code(json!({"cmd":"activity","owners":["nobody"]})),
        "not_found"
    );
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
        (json!({"cmd":"read","row_ids":["nope"]}), "not_found"),
        (json!({"cmd":"read_all","account":"nobody"}), "not_found"),
        (
            json!({"cmd":"dismiss","account":"me","pr":"a/b#1"}),
            "not_found",
        ),
        (
            json!({"cmd":"restore","account":"me","pr":"a/b#1"}),
            "not_found",
        ),
        (
            json!({"cmd":"place","account":"me","pr":"a/b#1","tab":"mine"}),
            "not_found",
        ),
        (
            json!({"cmd":"restore","account":"me","pr":"org/app#2"}),
            "invalid",
        ),
        (
            json!({"cmd":"place","account":"me","pr":"org/app#2","tab":"review"}),
            "invalid",
        ),
        (
            json!({"cmd":"place","account":"me","pr":"org/app#2","tab":"review","section":"todo","before":"org/app#9"}),
            "invalid",
        ),
        (
            json!({"cmd":"mute","account":"me","kind":"repo","name":"noslash"}),
            "invalid",
        ),
        (
            json!({"cmd":"mute","account":"me","kind":"pr","name":"org/app#99"}),
            "not_found",
        ),
        (
            json!({"cmd":"unmute","account":"me","kind":"user","name":"nobody"}),
            "not_found",
        ),
        (json!({"cmd":"mutes_get","account":"nobody"}), "not_found"),
        (
            json!({"cmd":"status","account":"me","pr":"a/b#1"}),
            "not_found",
        ),
        (
            json!({"cmd":"status","account":"nobody","pr":"org/app#2"}),
            "not_found",
        ),
        (
            json!({"cmd":"open","account":"me","pr":"a/b#1"}),
            "not_found",
        ),
        (json!({"cmd":"open","pr":"org/app#2"}), "invalid"),
        (json!({"cmd":"open","row":"nope"}), "not_found"),
        (
            json!({"cmd":"open","account":"nobody","row":"1001:E_1"}),
            "not_found",
        ),
        (json!({"cmd":"list","account":"nobody"}), "not_found"),
        (json!({"cmd":"list","owner":"nobody"}), "not_found"),
        (
            json!({"cmd":"owner_remove","account":"me","owner":"nobody"}),
            "not_found",
        ),
        (
            json!({"cmd":"owner_enable","account":"nobody","owner":"org"}),
            "not_found",
        ),
        (
            json!({"cmd":"popover_opened","account":"nobody"}),
            "not_found",
        ),
        (json!({"cmd":"config_get","key":"nope"}), "invalid"),
        (
            json!({"cmd":"config_set","key":"dismissed_keep_days","value":"nope"}),
            "invalid",
        ),
        (
            json!({"cmd":"config_set","key":"dismissed_keep_days","value":0}),
            "invalid",
        ),
        (
            json!({"cmd":"config_set","key":"auto_dismiss_after_days","value":-1}),
            "invalid",
        ),
        (
            json!({"cmd":"config_set","key":"drop_after_days","value":3}),
            "invalid",
        ),
        (
            json!({"cmd":"owner_add","account":"me","owner":"public"}),
            "invalid",
        ),
        (
            json!({"cmd":"owner_add","account":"me","owner":"PUBLIC"}),
            "invalid",
        ),
        (
            json!({"cmd":"dev_owner_add","account":"me","owner":"ORG","kind":"org"}),
            "invalid",
        ),
        (
            json!({"cmd":"owner_lookup","account":"me","owner":"-bad-"}),
            "invalid",
        ),
        (
            json!({"cmd":"account_color","account":"me","color":"pink"}),
            "invalid",
        ),
        (
            json!({"cmd":"dev_account_add","id":ACCOUNT,"login":"again"}),
            "invalid",
        ),
        (
            json!({"cmd":"owner_events_set","account":"me","owner":"org","event":"merged","column":"list","on":true}),
            "invalid",
        ),
        (
            json!({"cmd":"owner_exclusions_get","account":"me","owner":"org"}),
            "invalid",
        ),
        (
            json!({"cmd":"snooze","account":"me","pr":"org/app#2"}),
            "invalid",
        ),
        (json!({"cmd":"token_test"}), "invalid"),
    ];
    for (request, code) in cases {
        assert_eq!(daemon.code(request.clone()), code, "{request}");
    }
    daemon.ok(json!({"cmd":"read","row_ids":["1001:E_1"]}));
    daemon.ok(json!({"cmd":"read","row_ids":[]}));
    daemon.ok(json!({"cmd":"read_all","account":"ME"}));
    daemon.ok(json!({"cmd":"open","row":"1001:E_1"}));
    daemon.ok(json!({"cmd":"open","account":"ME","row":"1001:E_1"}));
    daemon.ok(json!({"cmd":"status","account":"me","pr":"org/app#1"}));
    daemon.ok(json!({"cmd":"open","account":"me","pr":"org/app#1"}));
    daemon.stop();
}

#[test]
fn a_long_snapshot_arrives_as_one_line() {
    let (_dir, daemon) = setup();
    for n in 0..300 {
        daemon.ok(json!({"cmd":"dev_owner_add","account":"me","kind":"org",
            "owner":format!("owner-{n}-{}", "x".repeat(25))}));
    }
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(
        snapshot["accounts"][0]["owners"].as_array().unwrap().len(),
        302
    );
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
    // Checks failed and Checks passed, each once in this second.
    assert_eq!(
        daemon.card("PR_1").unwrap()["rows"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    daemon.clock(T0 + 1);
    daemon.ingest(vec![passed], vec![], vec![]);
    daemon.ingest(vec![failed], vec![], vec![]);
    assert_eq!(
        daemon.card("PR_1").unwrap()["rows"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
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
    for n in 0i64..total {
        let long = with(
            event(&format!("E_{n}"), "PR_1", "comment", T0 + 1 + n),
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
    // Rows deleted with the newest 20 before the app read them are not
    // notified any more (DESIGN.md, "Notification decisions"); the rest
    // arrive exactly once.
    assert!(received.len() <= total as usize, "{}", received.len());
    for n in total - 20..total {
        assert!(received.contains(&format!("1001:E_{n}")), "E_{n} was lost");
    }
    daemon.stop();
}

/// `account_changed` for `me` is the very next event after the action.
#[test]
fn account_changed_table() {
    type Step = fn(&TestDaemon);
    let cases: [(&str, Step, Step); 13] = [
        (
            "dismiss",
            |_| {},
            |d| {
                d.ok(json!({"cmd":"dismiss","account":"me","pr":"org/app#1"}));
            },
        ),
        (
            "restore",
            |d| {
                d.ok(json!({"cmd":"dismiss","account":"me","pr":"org/app#1"}));
            },
            |d| {
                d.ok(json!({"cmd":"restore","account":"me","pr":"org/app#1"}));
            },
        ),
        (
            "place",
            |_| {},
            |d| {
                d.ok(json!({"cmd":"place","account":"me","pr":"org/app#1","tab":"review","section":"doing"}));
            },
        ),
        (
            "mute",
            |_| {},
            |d| {
                d.ok(json!({"cmd":"mute","account":"me","kind":"repo","name":"org/app"}));
            },
        ),
        (
            "unmute",
            |d| {
                d.ok(json!({"cmd":"mute","account":"me","kind":"repo","name":"org/app"}));
            },
            |d| {
                d.ok(json!({"cmd":"unmute","account":"me","kind":"repo","name":"org/app"}));
            },
        ),
        (
            "popover_opened clears the dot",
            |_| {},
            |d| {
                d.ok(json!({"cmd":"popover_opened","account":"me"}));
            },
        ),
        (
            "read reads a row",
            |_| {},
            |d| {
                d.ok(json!({"cmd":"read","row_ids":["1001:E_1"]}));
            },
        ),
        (
            "the table's List hides a row",
            |_| {},
            |d| {
                d.ok(
                    json!({"cmd":"owner_events_set","account":"me","owner":"org",
                    "event":"comment","column":"list","on":false}),
                );
            },
        ),
        (
            "an owner switch",
            |_| {},
            |d| {
                d.ok(json!({"cmd":"owner_skip_drafts","account":"me","owner":"org","on":false}));
            },
        ),
        (
            "read_all reads the rows",
            |_| {},
            |d| {
                d.ok(json!({"cmd":"read_all","account":"me"}));
            },
        ),
        (
            "dismissed_keep_days moves dismiss_expires_at",
            |d| {
                d.ok(json!({"cmd":"dismiss","account":"me","pr":"org/app#1"}));
            },
            |d| {
                d.ok(json!({"cmd":"config_set","key":"dismissed_keep_days","value":3}));
            },
        ),
        (
            "auto_dismiss_after_days dismisses a closed card",
            |d| {
                d.ingest(
                    vec![with(pr("PR_1", "alice"), json!({"state":"closed"}))],
                    vec![],
                    vec![],
                );
                d.clock(T0 + DAY);
            },
            |d| {
                d.ok(json!({"cmd":"config_set","key":"auto_dismiss_after_days","value":1}));
            },
        ),
        (
            "the end of the Dismissed list",
            |d| {
                d.ok(json!({"cmd":"dismiss","account":"me","pr":"org/app#1"}));
            },
            |d| d.clock(T0 + 7 * DAY),
        ),
    ];
    for (name, arrange, act) in cases {
        let (_dir, daemon) = setup();
        daemon.ingest(
            vec![pr("PR_1", "alice"), pr("PR_2", "alice")],
            vec![event("E_1", "PR_2", "comment", T0 + 1)],
            vec![],
        );
        arrange(&daemon);
        let mut cli = daemon.subscribe("cli");
        cli.snapshot();
        act(&daemon);
        let event = cli.next().expect(name);
        assert_eq!(event["event"], "account_changed", "{name}");
        assert_eq!(event["account"]["id"], ACCOUNT, "{name}");
        daemon.stop();
    }
}

/// Nothing a client shows changed, so the sentinel is the next event.
#[test]
fn no_account_changed_table() {
    type Step = fn(&TestDaemon);
    let cases: [(&str, Step); 4] = [
        ("a read", |d| {
            d.ok(json!({"cmd":"activity"}));
        }),
        ("a setting nothing shows", |d| {
            d.ok(json!({"cmd":"config_set","key":"reactions_interval_minutes","value":5}));
        }),
        ("opening without a dot", |d| {
            d.ok(json!({"cmd":"popover_opened","account":"me"}));
        }),
        ("closing with nothing to dismiss", |d| {
            d.ok(json!({"cmd":"popover_closed","account":"me"}));
        }),
    ];
    for (name, act) in cases {
        let (_dir, daemon) = setup();
        daemon.ingest(vec![pr("PR_1", "me")], vec![], vec![]);
        let mut cli = daemon.subscribe("cli");
        cli.snapshot();
        act(&daemon);
        daemon.ok(json!({"cmd":"owner_notify","account":"me","owner":"public","on":false}));
        let mut event = cli.next().expect(name);
        // A setting is announced as config_changed, never as account_changed.
        if event["event"] == "config_changed" {
            assert_eq!(event["key"], "reactions_interval_minutes", "{name}");
            event = cli.next().expect(name);
        }
        assert_eq!(event["event"], "account_changed", "{name}");
        assert_eq!(event["account"]["owners"][1]["notify"], false, "{name}");
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
    daemon.ok(json!({"cmd":"popover_opened","account":"me"}));
    daemon.ok(json!({"cmd":"popover_closed","account":"me"}));
    assert_eq!(daemon.account("me")["unread"], false);
    daemon.ok(json!({"cmd":"dev_ingest","account":"me","ingest":{
        "missing_pr_ids":["PR_1"],"prs":[],"events":[],"reactions":[]
    }}));
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    assert_eq!(daemon.account("me")["unread"], true);
    daemon.stop();
}

/// DESIGN.md, "CLI": `<pr>` compares owner and repository without case.
#[test]
fn a_pr_key_ignores_the_case_of_owner_and_repository() {
    let (_dir, daemon) = setup();
    daemon.ingest(vec![pr("PR_1", "alice")], vec![], vec![]);
    for key in ["org/app#1", "ORG/APP#1", "Org/App#1", "org/APP#1"] {
        let card = daemon.ok(json!({"cmd":"status","account":"me","pr":key}))["card"].clone();
        assert_eq!(card["pr"], "org/app#1", "{key}");
        daemon.ok(json!({"cmd":"open","account":"me","pr":key}));
    }
    daemon.ok(json!({"cmd":"dismiss","account":"me","pr":"ORG/App#1"}));
    daemon.ok(json!({"cmd":"restore","account":"me","pr":"org/aPP#1"}));
    daemon.ok(json!({"cmd":"mute","account":"me","kind":"pr","name":"ORG/APP#1"}));
    assert_eq!(
        daemon.ok(json!({"cmd":"mutes_get","account":"me"}))["mutes"]["prs"],
        json!(["org/app#1"]),
        "kept as GitHub spells it"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"status","account":"me","pr":"org/app#2"})),
        "not_found"
    );
    daemon.stop();
}

#[test]
fn a_changed_setting_goes_to_every_subscriber_once_saved() {
    let (_dir, daemon) = setup();
    let mut app = daemon.subscribe("app");
    app.snapshot();
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.ok(json!({"cmd":"config_set","key":"launch_at_login","value":false}));
    for subscriber in [&mut app, &mut cli] {
        assert_eq!(
            subscriber.next().unwrap(),
            json!({"event":"config_changed","key":"launch_at_login","value":false})
        );
    }
    // The same value again changes nothing and sends nothing; the next
    // event is the next change.
    daemon.ok(json!({"cmd":"config_set","key":"launch_at_login","value":false}));
    daemon.code(json!({"cmd":"config_set","key":"launch_at_login","value":"maybe"}));
    daemon.ok(json!({"cmd":"config_set","key":"dismissed_keep_days","value":20}));
    assert_eq!(
        cli.next().unwrap(),
        json!({"event":"config_changed","key":"dismissed_keep_days","value":20})
    );
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"launch_at_login"}))["value"],
        false
    );
    daemon.stop();
}

/// The `dev_ingest` shape of 0.4: the new kinds, `head_oid`, search hits and
/// the owner success times, with Dismiss and its clocks over the socket.
#[test]
fn dismiss_and_its_clocks_over_the_socket() {
    let (_dir, daemon) = setup();
    daemon.ok(json!({"cmd":"dev_ingest","account":"me","ingest":{
        "prs":[
            with(pr("PR_1", "alice"), json!({"head_oid":"abc"})),
            pr("PR_2", "me"),
        ],
        "events":[
            event("CO", "PR_1", "comment_other", T0 + 1),
            event("RO", "PR_1", "reopened", T0 + 2),
        ],
        "search":[{"id":"PR_1","updated_at":T0,"open":true,"events_fetched":true}],
        "succeeded_owners":["org"],
        "owner_run_started":{"org":T0 - 30}
    }}));
    let card = daemon.card("PR_1").unwrap();
    let kinds: Vec<&str> = card["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["reopened", "comment_other"]);
    assert_eq!(card["placement"], Value::Null);
    assert_eq!(card["muted"], json!([]));
    assert_eq!(card["older_rows"], false);
    assert_eq!(card["rows"][0]["muted"], false);
    assert_eq!(
        daemon.card("PR_2").unwrap()["placement"],
        json!({"tab":"mine","section":"main","position":0})
    );
    let tab = |tab: &str| {
        daemon.ok(json!({"cmd":"list","tab":tab}))["cards"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["pr"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(tab("mine"), ["org/app#2"]);
    assert!(tab("review").is_empty());

    let card = daemon.ok(json!({"cmd":"dismiss","account":"me","pr":"org/app#1"}))["card"].clone();
    assert_eq!(card["dismissed_at"], T0);
    assert_eq!(card["dismiss_expires_at"], T0 + 7 * DAY);
    assert_eq!(tab("all"), ["org/app#2"]);
    let only = daemon.ok(json!({"cmd":"list","dismissed":"only"}))["cards"].clone();
    assert_eq!(only.as_array().unwrap().len(), 1);
    // The end of the Dismissed list, by the clock: a record is left.
    daemon.clock(T0 + 7 * DAY);
    assert!(daemon.card("PR_1").is_none());
    // A later comment does not bring it back; a mention does.
    let later = with(pr("PR_1", "alice"), json!({"updated_at": T0 + 7 * DAY + 5}));
    daemon.ingest(
        vec![later.clone()],
        vec![event("C2", "PR_1", "comment_other", T0 + 7 * DAY + 1)],
        vec![],
    );
    assert!(daemon.card("PR_1").is_none());
    daemon.ingest(
        vec![later],
        vec![event("M", "PR_1", "mentioned", T0 + 7 * DAY + 2)],
        vec![],
    );
    let back = daemon.card("PR_1").expect("back through the mention");
    assert_eq!(back["rows"].as_array().unwrap().len(), 1);
    assert_eq!(back["dismissed_at"], Value::Null);
    daemon.stop();
}
