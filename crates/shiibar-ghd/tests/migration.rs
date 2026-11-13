//! The move of a 0.3 database (schema version 5) and of a 0.2 database
//! (version 4) to version 6: only the accounts are kept. docs/tasks/M6.md,
//! "Database and migration" and "How to test"; DESIGN.md, "Updating from
//! 0.3 and 0.2". The schemas come from tags v0.3.0 (`data/schema_v03.sql`)
//! and v0.2.0 (`data/schema_v02.sql`); the rows below are what those
//! daemons write.

mod common;

use rusqlite::Connection;
use shiibar_ghd::model::*;
use shiibar_ghd::store::{OpenOutcome, SCHEMA_VERSION, Store};
use std::path::{Path, PathBuf};

/// One of everything 0.3 saves: two accounts (the second added first, so
/// their order differs from their ids), owners, an event table, Exclusions,
/// settings, PRs (one snoozed), rows with delivery records, a Reaction
/// baseline and the notifications `since`.
const SEED_V5: &str = r#"
INSERT INTO meta (key, value) VALUES
    ('last_release_at', '1799990000'), ('seq', '5'), ('restore_accounts', 'false');
INSERT INTO config (key, value) VALUES
    ('drop_after_days', '5'), ('appearance', '"dark"'), ('text_size', '15'),
    ('snooze_return_time', '"08:30"');
INSERT INTO accounts (id, login, color, seq, token, updated_at, dot, teams, graphql_limit,
    rest_limit, stopped_until, fetch) VALUES (
    '1001', 'me', 'red', 4,
    '{"registered":true,"invalid":true,"expires_at":1799999999,"scopes":["repo"],"refused":[],"sso":false,"sso_orgs":[],"sso_urls":[],"sso_owners":{},"last_test":null}',
    1799999000, 1, '[{"database_id":42,"slug":"core"}]',
    '{"limit":5000,"remaining":4000,"reset_at":null}', NULL, 1800000500,
    '{"own":{},"threads":{},"retries":{},"pending_signals":["org/app#1"],"notif_last_modified":"Fri, 15 Jan 2027 08:00:00 GMT","notif_since":"2027-01-15T08:00:00Z","poll_interval":60,"notif_checked_at":1799999000}'),
    ('2002', 'work', 'blue', 1, '{"registered":true}', NULL, 0, '[]', NULL, NULL, NULL, '{}');
INSERT INTO owners (id, account, name, kind, github_id, seq, enabled, notify, skip_drafts,
    watch_started_at, fetched_at) VALUES
    ('o2', '1001', 'org', 'org', 100, 2, 1, 0, 1, 1799000000, 1799999000),
    ('o3', '1001', 'Public', 'public', NULL, 3, 1, 1, 1, 1799000000, NULL),
    ('o5', '2002', 'corp', 'org', 300, 5, 1, 1, 1, 1799000000, NULL);
INSERT INTO owner_events (owner, event, list, notify) VALUES
    ('o2', 'comment', 1, 0), ('o2', 'mentioned', 0, 0);
INSERT INTO exclusions (owner, kind, position, name, state) VALUES
    ('o2', 'user', 0, 'renovate', 'list_only'), ('o2', 'repo', 0, 'org/legacy', 'hidden');
INSERT INTO prs (key, account, id, owner, repo, number, url, title, author, author_avatar_url,
    base, head, state, is_draft, review, checks, base_status, mergeable, failed_check,
    changes_requested_by, updated_at, is_private, requested_me, requested_team, assignees,
    link_review, link_checks, link_base, unreadable, snoozed, added_at, prev_review,
    prev_checks, prev_base_status, prev_mergeable, gone_at, collected, created_at,
    my_review_at) VALUES
    ('1001:PR_1', '1001', 'PR_1', 'org', 'app', 1, 'https://github.com/org/app/pull/1',
     'Fix it', 'me', NULL, 'main', 'fix', 'open', 0, 'review_required', 'failed', 'behind',
     0, 'build', NULL, 1799999500, 1, 1, 0, '["me"]', 'r', 'c', 'b', 0, 1, 1799000100,
     'review_required', 'failed', 'behind', 0, NULL, 1, 1798000000, NULL);
INSERT INTO pr_rows (id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id,
    unread, pruned, notify) VALUES
    ('1001:R_1', '1001', '1001:PR_1', 'comment', 'hello', NULL, 'alice', 'u1', 1799999100,
     'C_9', 1, 0, 'held'),
    ('1001:R_2', '1001', '1001:PR_1', 'merged', NULL, NULL, 'bob', 'u2', 1799999000, NULL,
     0, 1, 'pending');
INSERT INTO reaction_baselines (key, pr, counts) VALUES
    ('1001:C_1', '1001:PR_1', '{"THUMBS_UP":2}');
"#;

/// The same for 0.2, in its own column layout.
const SEED_V4: &str = r#"
INSERT INTO meta (key, value) VALUES
    ('last_release_at', '1799990000'), ('seq', '3'), ('restore_accounts', 'false');
INSERT INTO config (key, value) VALUES ('drop_after_days', '5');
INSERT INTO accounts (id, login, color, seq, token, updated_at, dot, teams, graphql_limit,
    rest_limit, stopped_until, fetch) VALUES (
    '1001', 'me', 'green', 1, '{"registered":true}', 1799999000, 1, '[]', NULL, NULL, NULL,
    '{"pr_ids":{"someone/lib#7":"PR_N"}}');
INSERT INTO owners (id, account, name, kind, github_id, seq, enabled, notify, skip_drafts,
    watch_started_at, fetched_at) VALUES
    ('o2', '1001', 'org', 'org', 100, 2, 1, 0, 1, 1799000000, 1799999000);
INSERT INTO owner_events (owner, event, list, todo, notify) VALUES ('o2', 'comment', 1, 1, 0);
INSERT INTO prs (key, account, id, owner, repo, number, url, title, author, author_avatar_url,
    base, head, state, is_draft, review, checks, base_status, mergeable, failed_check,
    changes_requested_by, updated_at, is_private, requested_me, requested_team, assignees,
    link_review, link_checks, link_base, unreadable, snoozed, added_at, prev_review,
    prev_checks, prev_base_status, prev_mergeable, gone_at, collected) VALUES
    ('1001:PR_N', '1001', 'PR_N', 'someone', 'lib', 7, 'https://github.com/someone/lib/pull/7',
     'Bump', 'renovate', NULL, 'main', 'renovate/x', 'open', 0, 'none', 'passed',
     'up_to_date', 1, NULL, NULL, 1799999600, 0, 0, 0, '[]', 'r', 'c', 'b', 0, 1, 1799000200,
     'none', 'passed', 'up_to_date', 1, NULL, 0);
INSERT INTO pr_rows (id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id,
    unread, seen_pending, done, pruned, notify, todo_auto, todo_manual) VALUES
    ('1001:R_3', '1001', '1001:PR_N', 'mentioned', 'hi @me', NULL, 'carol', 'u3', 1799999200,
     'C_8', 1, 0, 0, 0, 'held', 1, 0);
"#;

/// A database of the given old version with its seed, plus `extra` SQL, at
/// `dir/state.db`.
fn old_database(dir: &Path, version: i64, extra: &str) -> PathBuf {
    let db = dir.join("state.db");
    let conn = Connection::open(&db).unwrap();
    let (schema, seed) = match version {
        5 => (include_str!("data/schema_v03.sql"), SEED_V5),
        4 => (include_str!("data/schema_v02.sql"), SEED_V4),
        other => panic!("no seed for version {other}"),
    };
    conn.execute_batch(schema).unwrap();
    conn.execute_batch(seed).unwrap();
    conn.execute_batch(extra).unwrap();
    drop(conn);
    db
}

fn tables(db: &Path) -> Vec<String> {
    let conn = Connection::open(db).unwrap();
    let mut statement = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
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

/// What every move leaves: the accounts and nothing else.
fn only_the_accounts_are_left(db: &Path, data: &Data) {
    assert_eq!(version(db), SCHEMA_VERSION);
    assert_eq!(SCHEMA_VERSION, 6);
    let mut names = tables(db);
    names.sort();
    assert_eq!(
        names,
        [
            "accounts",
            "config",
            "deleted_rows",
            "dismiss_records",
            "meta",
            "mutes",
            "owner_events",
            "owners",
            "pr_rows",
            "prs",
            "reaction_baselines"
        ],
        "the 0.3 tables (exclusions) are gone"
    );
    for table in [
        "owners",
        "owner_events",
        "prs",
        "pr_rows",
        "reaction_baselines",
        "config",
        "mutes",
        "deleted_rows",
        "dismiss_records",
    ] {
        assert_eq!(count(db, table), 0, "{table}");
    }
    assert!(data.owners.is_empty());
    assert!(data.prs.is_empty());
    assert!(data.rows.is_empty());
    assert!(data.baselines.is_empty());
    assert_eq!(data.config, Config::default(), "settings start over");
    for account in data.accounts.values() {
        assert_eq!(account.token, TokenRec::default(), "token record dropped");
        assert_eq!(
            account.fetch,
            FetchRec::default(),
            "since and signals dropped"
        );
        assert_eq!(account.updated_at, None);
        assert!(!account.dot);
        assert!(account.teams.is_empty());
        assert_eq!(account.graphql, None);
        assert_eq!(account.stopped_until, None);
        assert_eq!(account.mutes, MuteRec::default());
    }
}

#[test]
fn a_0_3_database_moves_to_version_6_keeping_only_the_accounts() {
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 5, "");
    let (store, data) = open(&db);
    drop(store);
    only_the_accounts_are_left(&db, &data);
    let ids: Vec<(&str, &str, AccountColor, u64)> = data
        .accounts
        .values()
        .map(|a| (a.id.as_str(), a.login.as_str(), a.color, a.seq))
        .collect();
    assert_eq!(
        ids,
        [
            ("1001", "me", AccountColor::Red, 4),
            ("2002", "work", AccountColor::Blue, 1)
        ],
        "id, login, color and order"
    );
    // The next owner id must not reuse an account's number.
    assert!(data.seq >= 4, "{}", data.seq);
}

#[test]
fn a_0_2_database_moves_to_version_6_keeping_only_the_accounts() {
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 4, "");
    let (store, data) = open(&db);
    drop(store);
    only_the_accounts_are_left(&db, &data);
    let account = &data.accounts["1001"];
    assert_eq!(
        (account.login.as_str(), account.color, account.seq),
        ("me", AccountColor::Green, 1)
    );
}

#[test]
fn a_moved_database_saves_and_opens_again_as_version_6() {
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 5, "");
    let (mut store, data) = open(&db);
    let mut engine = shiibar_ghd::engine::Engine::restore(data);
    let now = shiibar_ghd::clock::Now::fixed(1_800_000_000, "Asia/Tokyo").unwrap();
    engine
        .owner_add("1001", "org", OwnerKind::Org, Some(100), &now)
        .unwrap();
    store.save(engine.data(), engine.dirty()).unwrap();
    drop(store);
    let (_, again) = open(&db);
    assert_eq!(
        &again,
        engine.data(),
        "nothing lost between saving and reading"
    );
    let owner = again.owners.values().next().unwrap();
    assert!(
        again.accounts.values().all(|a| a.seq < owner.seq),
        "a new owner comes after every account"
    );
}

#[test]
fn a_failed_move_rolls_back_and_leaves_the_old_database_unreadable() {
    // A view named like a version 6 table survives the drop of the old
    // tables, so creating that table fails after the drops already ran
    // inside the transaction.
    for old in [5, 4] {
        let dir = tempfile::tempdir().unwrap();
        let db = old_database(dir.path(), old, "CREATE VIEW mutes AS SELECT 1;");
        let before = count(&db, "prs");
        for start in 1..=2 {
            assert!(
                matches!(Store::open(&db).unwrap(), OpenOutcome::Unreadable),
                "{old}, start {start}"
            );
            assert_eq!(version(&db), old, "{old}, start {start}: old version");
            assert_eq!(
                count(&db, "prs"),
                before,
                "{old}: the drops were rolled back"
            );
            assert_eq!(count(&db, "owners"), if old == 5 { 3 } else { 1 });
            assert!(!tables(&db).contains(&"deleted_rows".to_string()));
        }
    }
}

#[test]
fn an_account_the_move_cannot_read_rolls_it_back() {
    // DESIGN.md, "When the database cannot be read": never an exit.
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(
        dir.path(),
        5,
        "UPDATE accounts SET color = 'pink' WHERE id = '2002';",
    );
    assert!(matches!(Store::open(&db).unwrap(), OpenOutcome::Unreadable));
    assert_eq!(version(&db), 5);
    assert!(tables(&db).contains(&"exclusions".to_string()));
}

#[test]
fn a_0_1_database_stays_unreadable_and_a_newer_one_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("state.db");
    let conn = Connection::open(&db).unwrap();
    conn.execute_batch(include_str!("data/schema_v01.sql"))
        .unwrap();
    drop(conn);
    assert!(matches!(Store::open(&db).unwrap(), OpenOutcome::Unreadable));
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("state.db");
    let conn = Connection::open(&db).unwrap();
    conn.execute_batch("CREATE TABLE t (x); PRAGMA user_version = 7;")
        .unwrap();
    drop(conn);
    assert!(Store::open(&db).is_err());
}

/// The daemon on a moved database, with a test Keychain file and no
/// GitHub: the accounts are there, with their colors and order, and the
/// token comes back from the Keychain item without asking again.
#[cfg(feature = "dev-ingest")]
#[test]
fn the_daemon_starts_on_a_0_3_state_directory() {
    use common::*;
    use serde_json::json;
    let dir = tempfile::tempdir().unwrap();
    old_database(dir.path(), 5, "");
    let item = dir.path().join("keychain.json");
    let before = r#"{"version":2,"accounts":[{"id":"1001","login":"me","token":"ghp_test_only"},{"id":"2002","login":"work","token":"ghp_other"}]}"#;
    std::fs::write(&item, before).unwrap();
    let mut command = command(dir.path());
    command
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", &item);
    let daemon = TestDaemon::spawn(dir.path(), command);
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], false);
    let logins: Vec<&str> = snapshot["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["login"].as_str().unwrap())
        .collect();
    assert_eq!(logins, ["work", "me"], "the order of 0.3");
    let me = daemon.account("me");
    assert_eq!(me["color"], "red");
    assert!(me["owners"].as_array().unwrap().is_empty());
    assert!(daemon.cards().is_empty());
    // `refresh` reads the item (no GitHub in this build, so nothing is
    // fetched): the tokens come back.
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(daemon.account("me")["token"]["registered"], true);
    assert_eq!(daemon.account("work")["token"]["registered"], true);
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"text_size"}))["value"],
        12,
        "settings start over"
    );
    daemon.stop();
    assert_eq!(
        std::fs::read_to_string(&item).unwrap(),
        before,
        "the Keychain item is left as it is"
    );
}
