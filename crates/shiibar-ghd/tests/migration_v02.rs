//! The move of a 0.2 database (schema version 4) to version 5.
//! docs/tasks/M5.md, "Database and migration" and "How to test"; DESIGN.md,
//! "Saved state". The schema comes from tag v0.2.0 (`data/schema_v02.sql`);
//! the rows below are what a 0.2 daemon writes.

mod common;

use rusqlite::Connection;
use shiibar_ghd::model::*;
use shiibar_ghd::store::{OpenOutcome, SCHEMA_VERSION, Store};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// One of everything 0.2 saves, in its own column layout: Todo and Done
/// columns set, a PR only a notification brought in (`someone/lib#7`), the
/// previous values, a Reaction baseline, the delivery records, a pruned row
/// and the notifications `since`.
const SEED: &str = r#"
INSERT INTO meta (key, value) VALUES
    ('last_release_at', '1799990000'), ('seq', '3'), ('restore_accounts', 'false');
INSERT INTO config (key, value) VALUES ('drop_after_days', '5'), ('appearance', '"dark"');
INSERT INTO accounts (id, login, color, seq, token, updated_at, dot, teams, graphql_limit,
    rest_limit, stopped_until, fetch) VALUES (
    '1001', 'me', 'red', 1,
    '{"registered":true,"invalid":false,"expires_at":null,"scopes":["repo","notifications","read:org"],"refused":[],"sso":false,"sso_orgs":[],"sso_urls":[],"last_test":null}',
    1799999000, 1, '[{"database_id":42,"slug":"core"}]',
    '{"limit":5000,"remaining":4000,"reset_at":null}', NULL, NULL,
    '{"pr_ids":{"someone/lib#7":"PR_N"},"own":{"C_1":{"id":"C_1","pr_id":"PR_1","url":"u","text":"t","created_at":1799990000,"baseline_done":true}},"threads":{},"retries":{"PR_1":{"pr_id":"PR_1","since":1799998000,"failures":1}},"pending_signals":[],"notif_last_modified":"Fri, 15 Jan 2027 08:00:00 GMT","notif_since":"2027-01-15T08:00:00Z","poll_interval":60,"notif_checked_at":1799999000}');
INSERT INTO owners (id, account, name, kind, github_id, seq, enabled, notify, skip_drafts,
    watch_started_at, fetched_at) VALUES
    ('o2', '1001', 'org', 'org', 100, 2, 1, 0, 1, 1799000000, 1799999000),
    ('o3', '1001', 'Public', 'public', NULL, 3, 1, 1, 1, 1799000000, NULL);
INSERT INTO owner_events (owner, event, list, todo, notify) VALUES
    ('o2', 'comment', 1, 1, 0), ('o2', 'mentioned', 0, 0, 0), ('o3', 'comment', 1, 0, 1);
INSERT INTO exclusions (owner, kind, position, name, state) VALUES
    ('o2', 'user', 0, 'renovate', 'list_only'), ('o2', 'repo', 0, 'org/legacy', 'hidden');
INSERT INTO prs (key, account, id, owner, repo, number, url, title, author, author_avatar_url,
    base, head, state, is_draft, review, checks, base_status, mergeable, failed_check,
    changes_requested_by, updated_at, is_private, requested_me, requested_team, assignees,
    link_review, link_checks, link_base, unreadable, snoozed, added_at, prev_review,
    prev_checks, prev_base_status, prev_mergeable, gone_at, collected) VALUES
    ('1001:PR_1', '1001', 'PR_1', 'org', 'app', 1, 'https://github.com/org/app/pull/1',
     'Fix it', 'me', 'https://avatars.example/me', 'main', 'fix', 'open', 0,
     'review_required', 'failed', 'behind', 0, 'build', NULL, 1799999500, 1, 1, 0, '["me"]',
     'r', 'c', 'b', 0, 0, 1799000100, 'review_required', 'failed', 'behind', 0, NULL, 1),
    ('1001:PR_N', '1001', 'PR_N', 'someone', 'lib', 7, 'https://github.com/someone/lib/pull/7',
     'Bump', 'renovate', NULL, 'main', 'renovate/x', 'open', 0, 'none', 'passed',
     'up_to_date', 1, NULL, NULL, 1799999600, 0, 0, 0, '[]', 'r', 'c', 'b', 0, 1, 1799000200,
     'none', 'passed', 'up_to_date', 1, NULL, 0);
INSERT INTO pr_rows (id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id,
    unread, seen_pending, done, pruned, notify, todo_auto, todo_manual) VALUES
    ('1001:R_1', '1001', '1001:PR_1', 'comment', 'hello', NULL, 'alice', 'u1', 1799999100,
     'C_9', 1, 1, 0, 0, 'delivered', 1, NULL),
    ('1001:R_2', '1001', '1001:PR_1', 'merged', NULL, NULL, 'bob', 'u2', 1799999000, NULL,
     0, 0, 1, 1, 'none', 0, 1),
    ('1001:R_3', '1001', '1001:PR_N', 'mentioned', 'hi @me', NULL, 'carol', 'u3', 1799999200,
     'C_8', 1, 0, 0, 0, 'held', 1, 0),
    ('1001:R_4', '1001', '1001:PR_1', 'reaction', 'my text', '{"THUMBS_UP":1}', NULL, 'u4',
     1799999300, 'C_1', 0, 0, 0, 0, 'pending', 0, NULL);
INSERT INTO reaction_baselines (key, pr, counts) VALUES
    ('1001:C_1', '1001:PR_1', '{"THUMBS_UP":2}');
"#;

/// A 0.2 database with the seed, plus `extra` SQL, at `dir/state.db`.
fn v02_database(dir: &Path, extra: &str) -> PathBuf {
    let db = dir.join("state.db");
    let conn = Connection::open(&db).unwrap();
    conn.execute_batch(include_str!("data/schema_v02.sql"))
        .unwrap();
    conn.execute_batch(SEED).unwrap();
    conn.execute_batch(extra).unwrap();
    drop(conn);
    db
}

fn columns(db: &Path, table: &str) -> Vec<String> {
    let conn = Connection::open(db).unwrap();
    let mut statement = conn
        .prepare(&format!("SELECT name FROM pragma_table_info('{table}')"))
        .unwrap();
    statement
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

fn version(db: &Path) -> i64 {
    Connection::open(db)
        .unwrap()
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap()
}

fn count(db: &Path, table: &str) -> i64 {
    Connection::open(db)
        .unwrap()
        .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}

fn open(db: &Path) -> (Store, Data) {
    match Store::open(db).unwrap() {
        OpenOutcome::Ready(store, Some(data)) => (store, *data),
        other => panic!("not migrated: {other:?}"),
    }
}

#[test]
fn a_0_2_database_moves_to_version_5_and_keeps_its_data() {
    let dir = tempfile::tempdir().unwrap();
    let db = v02_database(dir.path(), "");
    let (store, data) = open(&db);
    drop(store);

    assert_eq!(version(&db), SCHEMA_VERSION);
    assert_eq!(SCHEMA_VERSION, 5);
    assert_eq!(
        columns(&db, "owner_events"),
        ["owner", "event", "list", "notify"]
    );
    let rows = columns(&db, "pr_rows");
    for gone in ["seen_pending", "done", "todo_auto", "todo_manual"] {
        assert!(!rows.contains(&gone.to_string()), "{gone}: {rows:?}");
    }
    let prs = columns(&db, "prs");
    assert!(prs.ends_with(&["created_at".to_string(), "my_review_at".to_string()]));

    // Meta and settings.
    assert_eq!(data.last_release_at, 1_799_990_000);
    assert_eq!(data.seq, 3);
    assert_eq!(data.config.drop_after_days, 5);
    assert_eq!(data.config.appearance, Appearance::Dark);
    assert_eq!(data.config.text_size, 12, "the default");

    // The account with its fetch records and the notifications `since`.
    let account = &data.accounts["1001"];
    assert_eq!(account.login, "me");
    assert_eq!(account.color, AccountColor::Red);
    assert_eq!(account.updated_at, Some(1_799_999_000));
    assert!(account.dot);
    assert!(account.token.registered);
    assert!(account.token.sso_owners.is_empty());
    assert_eq!(account.teams[0].slug, "core");
    assert_eq!(account.graphql.unwrap().remaining, 4000);
    let fetch = &account.fetch;
    assert_eq!(fetch.notif_since.as_deref(), Some("2027-01-15T08:00:00Z"));
    assert_eq!(
        fetch.notif_last_modified.as_deref(),
        Some("Fri, 15 Jan 2027 08:00:00 GMT")
    );
    assert_eq!(fetch.poll_interval, Some(60));
    assert_eq!(fetch.notif_checked_at, Some(1_799_999_000));
    assert!(fetch.own["C_1"].baseline_done);
    assert_eq!(fetch.retries["PR_1"].since, 1_799_998_000);

    // Owners, their two-column tables and Exclusions.
    let org = &data.owners["o2"];
    assert!(!org.notify && org.enabled && org.skip_drafts);
    assert_eq!(org.github_id, Some(100));
    assert_eq!(org.fetched_at, Some(1_799_999_000));
    assert_eq!(org.watch_started_at, 1_799_000_000);
    assert_eq!(
        org.events.cell(EventKind::Comment),
        Cell {
            list: true,
            notify: false
        }
    );
    assert_eq!(
        org.events.cell(EventKind::Mentioned),
        Cell {
            list: false,
            notify: false
        }
    );
    assert_eq!(org.users[0].state, ExclusionState::ListOnly);
    assert_eq!(org.repos[0].name, "org/legacy");
    assert!(data.owners["o3"].is_public());

    // PRs with their previous values; the one a notification brought in
    // stays. `created_at` waits for the next fetch.
    let pr = &data.prs["1001:PR_1"];
    assert_eq!(pr.created_at, None);
    assert_eq!(pr.my_review_at, None);
    assert_eq!(pr.added_at, Some(1_799_000_100));
    assert_eq!(pr.updated_at, 1_799_999_500);
    assert!(pr.requested_me && pr.collected);
    assert_eq!(
        pr.prev,
        Some(PrevValues {
            review: Review::ReviewRequired,
            checks: Checks::Failed,
            base_status: BaseStatus::Behind,
            mergeable: false,
        })
    );
    let notified = &data.prs["1001:PR_N"];
    assert!(notified.snoozed);
    assert_eq!(notified.created_at, None);

    // Rows: unread, pruned and the delivery records.
    let row = |id: &str| &data.rows[&format!("1001:{id}")];
    assert!(row("R_1").unread && !row("R_1").pruned);
    assert_eq!(row("R_1").notify, NotifyState::Delivered);
    assert!(!row("R_2").unread && row("R_2").pruned);
    assert_eq!(row("R_3").notify, NotifyState::Held);
    assert_eq!(row("R_4").notify, NotifyState::Pending);
    assert_eq!(
        row("R_4").counts,
        Some(BTreeMap::from([("THUMBS_UP".to_string(), 1)]))
    );
    assert_eq!(data.rows.len(), 4);

    // Reaction baselines.
    assert_eq!(
        data.baselines["1001:C_1"].counts,
        BTreeMap::from([("THUMBS_UP".to_string(), 2)])
    );
}

#[test]
fn a_moved_database_saves_and_opens_again_as_version_5() {
    let dir = tempfile::tempdir().unwrap();
    let db = v02_database(dir.path(), "");
    let (mut store, mut data) = open(&db);
    let pr = data.prs.get_mut("1001:PR_1").unwrap();
    pr.created_at = Some(1_798_000_000);
    pr.my_review_at = Some(1_799_999_999);
    data.config.text_size = 15;
    let dirty = Dirty {
        prs: ["1001:PR_1".to_string()].into(),
        owners: ["o2".to_string()].into(),
        rows: ["1001:R_1".to_string()].into(),
        config: true,
        ..Dirty::default()
    };
    store.save(&data, &dirty).unwrap();
    drop(store);
    let (_, again) = open(&db);
    assert_eq!(again, data, "nothing lost between saving and reading");
    assert_eq!(version(&db), SCHEMA_VERSION);
}

#[test]
fn a_failed_move_rolls_back_and_leaves_the_0_2_database_unreadable() {
    // An index on a column the move drops makes `ALTER TABLE DROP COLUMN`
    // fail (sqlite.org/lang_altertable.html, "The column is indexed") after
    // the earlier drops already ran inside the transaction.
    let dir = tempfile::tempdir().unwrap();
    let db = v02_database(
        dir.path(),
        "CREATE INDEX pr_rows_todo ON pr_rows (todo_auto);",
    );
    assert!(matches!(Store::open(&db).unwrap(), OpenOutcome::Unreadable));
    assert_eq!(version(&db), 4, "still version 4");
    assert!(
        columns(&db, "owner_events").contains(&"todo".to_string()),
        "the first drop was rolled back"
    );
    let rows = columns(&db, "pr_rows");
    for kept in ["seen_pending", "done", "todo_auto", "todo_manual"] {
        assert!(rows.contains(&kept.to_string()), "{kept}");
    }
    assert!(!columns(&db, "prs").contains(&"created_at".to_string()));
    assert_eq!(count(&db, "pr_rows"), 4);
    assert_eq!(count(&db, "prs"), 2);
    // Opening again does the same and changes nothing.
    assert!(matches!(Store::open(&db).unwrap(), OpenOutcome::Unreadable));
    assert_eq!(version(&db), 4);
}

/// The daemon on a moved database, with a test Keychain file and no
/// GitHub: the account, owners, rows and Snooze are there.
#[cfg(feature = "dev-ingest")]
#[test]
fn the_daemon_starts_on_a_0_2_state_directory() {
    use common::*;
    use serde_json::json;
    let dir = tempfile::tempdir().unwrap();
    v02_database(dir.path(), "");
    let mut command = command(dir.path());
    command
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", dir.path().join("keychain.json"));
    let daemon = TestDaemon::spawn(dir.path(), command);
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], false);
    let account = &snapshot["accounts"][0];
    assert_eq!(account["login"], "me");
    assert_eq!(account["color"], "red");
    assert_eq!(account["owners"].as_array().unwrap().len(), 2);
    assert_eq!(account["updated_at"], 1_799_999_000);
    let card = daemon.card("PR_1").expect("the card of org/app#1");
    assert_eq!(card["created_at"], serde_json::Value::Null);
    assert_eq!(card["updated_at"], 1_799_999_500);
    assert_eq!(card["awaiting_review"], true, "still requested");
    let snoozed = daemon.ok(json!({"cmd":"list","snoozed":true}))["cards"].clone();
    assert_eq!(snoozed[0]["pr"], "someone/lib#7", "kept, and snoozed");
    let row = daemon.row("R_1").unwrap();
    assert_eq!(row["unread"], true);
    assert!(row.get("done").is_none() && row.get("todo").is_none());
    let events =
        daemon.ok(json!({"cmd":"owner_events_get","account":"me","owner":"org"}))["events"].clone();
    assert_eq!(events["comment"], json!({"list":true,"notify":false}));
    daemon.stop();
}

#[test]
fn a_move_that_cannot_be_read_back_rolls_back_on_every_start() {
    // DESIGN.md, "When the database cannot be read": never an exit. A row
    // kind no build knows makes the read of the moved state fail inside
    // the move's transaction, so the database stays at version 4.
    let dir = tempfile::tempdir().unwrap();
    let db = v02_database(
        dir.path(),
        "UPDATE pr_rows SET kind = 'from_the_future' WHERE id = '1001:R_1';",
    );
    for start in 1..=2 {
        assert!(
            matches!(Store::open(&db).unwrap(), OpenOutcome::Unreadable),
            "start {start}"
        );
        assert_eq!(version(&db), 4, "start {start}: still version 4");
        assert!(
            columns(&db, "owner_events").contains(&"todo".to_string()),
            "start {start}: rolled back"
        );
        assert!(!columns(&db, "prs").contains(&"created_at".to_string()));
        assert_eq!(count(&db, "pr_rows"), 4, "start {start}: nothing removed");
    }
}

#[test]
fn a_0_2_pr_is_in_the_notified_pr_map_after_the_move() {
    // DESIGN.md, "Identifying PRs": the PR a 0.2 notification brought in
    // is a saved PR, so a notification of it is a signal.
    let dir = tempfile::tempdir().unwrap();
    let db = v02_database(dir.path(), "");
    let (_, data) = open(&db);
    let engine = shiibar_ghd::engine::Engine::restore(data);
    let now = shiibar_ghd::clock::Now::fixed(1_800_000_000, "Asia/Tokyo").unwrap();
    let due = engine.due("1001", now.at, true);
    let plan = engine.fetch_plan("1001", &now, due, "t".into()).unwrap();
    assert_eq!(
        plan.pr_ids.get("someone/lib#7").map(String::as_str),
        Some("PR_N")
    );
    assert_eq!(
        plan.pr_ids.get("org/app#1").map(String::as_str),
        Some("PR_1")
    );
}

/// The Keychain item (format version 2) is not touched by the move: the
/// test Keychain file under the state directory keeps its bytes while the
/// daemon moves the database and reads the item.
#[cfg(feature = "dev-ingest")]
#[test]
fn the_move_leaves_the_keychain_item_as_it_is() {
    use common::*;
    use serde_json::json;
    let dir = tempfile::tempdir().unwrap();
    v02_database(dir.path(), "");
    let item = dir.path().join("keychain.json");
    let before = r#"{"version":2,"accounts":[{"id":"1001","login":"me","token":"ghp_test_only"}]}"#;
    std::fs::write(&item, before).unwrap();
    let mut command = command(dir.path());
    command
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", &item);
    let daemon = TestDaemon::spawn(dir.path(), command);
    // `refresh` reads the item (no GitHub in this build, so nothing is
    // fetched).
    daemon.ok(json!({"cmd":"refresh"}));
    let account = daemon.account("me");
    assert_eq!(account["token"]["registered"], true, "the token was read");
    daemon.stop();
    assert_eq!(std::fs::read_to_string(&item).unwrap(), before);
}
