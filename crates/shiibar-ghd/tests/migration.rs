//! The move of a 0.6 database (schema version 8) to version 9, of a 0.5
//! database (version 7) through 8 to 9 and of a 0.4 database (version 6)
//! through 7 and 8 to 9, keeping everything, and of a 0.3 database (version
//! 5) and a 0.2 database (version 4) to version 9, keeping only the
//! accounts. docs/tasks/M7.md, docs/tasks/M9.md and docs/tasks/M10.md,
//! "Database and migration" and "How to test"; DESIGN.md, "Updating from
//! 0.6", "Updating from 0.5", "Updating from 0.4" and "Updating from 0.3 and
//! 0.2". The schemas come from tags v0.6.0 (`data/schema_v06.sql`), v0.5.0
//! (`data/schema_v05.sql`), v0.4.0 (`data/schema_v04.sql`), v0.3.0
//! (`data/schema_v03.sql`) and v0.2.0 (`data/schema_v02.sql`); the rows
//! below are what those daemons write.

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
    ('o2', 'user', 0, 'example-bot', 'list_only'), ('o2', 'repo', 0, 'org/legacy', 'hidden');
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
     'Bump', 'example-bot', NULL, 'main', 'example-bot/x', 'open', 0, 'none', 'passed',
     'up_to_date', 1, NULL, NULL, 1799999600, 0, 0, 0, '[]', 'r', 'c', 'b', 0, 1, 1799000200,
     'none', 'passed', 'up_to_date', 1, NULL, 0);
INSERT INTO pr_rows (id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id,
    unread, seen_pending, done, pruned, notify, todo_auto, todo_manual) VALUES
    ('1001:R_3', '1001', '1001:PR_N', 'mentioned', 'hi @me', NULL, 'carol', 'u3', 1799999200,
     'C_8', 1, 0, 0, 0, 'held', 1, 0);
"#;

/// One of everything 0.4 saves (DESIGN.md, "Updating from 0.4"): an account
/// whose teams lack the organization, owners and an event table, settings,
/// Mute lists, PRs placed in Review with ranks (the muted PR_2 between two
/// others, which 0.4 showed last), two cards in Done at the same time, a
/// dismissed card, rows with delivery records, a deleted row, a Dismiss
/// record and a Reaction baseline.
const SEED_V6: &str = r#"
INSERT INTO meta (key, value) VALUES ('seq', '5'), ('restore_accounts', 'false');
INSERT INTO config (key, value) VALUES
    ('appearance', '"dark"'), ('text_size', '15'), ('auto_dismiss_after_days', '5'),
    ('dismissed_keep_days', '9');
INSERT INTO accounts (id, login, color, seq, token, updated_at, dot, teams, graphql_limit,
    rest_limit, stopped_until, fetch) VALUES (
    '1001', 'me', 'red', 1,
    '{"registered":true,"invalid":false,"expires_at":1899999999,"scopes":["repo","notifications","read:org"],"refused":[],"sso":false,"sso_orgs":[],"sso_urls":[],"sso_owners":{},"last_test":null}',
    1799999000, 1, '[{"database_id":42,"slug":"core"}]',
    '{"limit":5000,"remaining":4000,"reset_at":1800003600}',
    '{"limit":5000,"remaining":4900,"reset_at":1800003000}', NULL,
    '{"own":{},"threads":{},"retries":{"PR_C":{"pr_id":"PR_C","since":1799990000,"failures":1,"owner":"o2"}},"pending_signals":["org/app#1"],"notif_last_modified":"Fri, 15 Jan 2027 08:00:00 GMT","notif_since":"2027-01-15T08:00:00Z","poll_interval":60,"notif_checked_at":1799999000,"status_failures":[],"failed_requests":[],"full_run_started_at":1799999000}');
INSERT INTO mutes (account, kind, position, name) VALUES
    ('1001', 'repo', 0, 'org/legacy'), ('1001', 'user', 0, 'example-bot'),
    ('1001', 'pr', 0, 'org/app#2');
INSERT INTO owners (id, account, name, kind, github_id, seq, enabled, notify, skip_drafts,
    watch_started_at, fetched_at) VALUES
    ('o2', '1001', 'org', 'org', 100, 2, 1, 0, 1, 1799000000, 1799999000),
    ('o3', '1001', 'Public', 'public', NULL, 3, 1, 1, 1, 1799000000, NULL);
INSERT INTO owner_events (owner, event, list, notify) VALUES
    ('o2', 'comment', 1, 0), ('o2', 'team_mentioned', 0, 0);
INSERT INTO prs (key, account, id, owner, repo, number, url, title, author, author_avatar_url,
    base, head, head_oid, state, is_draft, review, checks, base_status, mergeable,
    failed_check, changes_requested_by, updated_at, created_at, my_review_at,
    last_request_at, is_private, requested_me, requested_team, assignees, link_review,
    link_checks, link_base, unreadable, added_at, prev_review, prev_checks,
    prev_base_status, prev_mergeable, settled, settled_head, watch_reset, place_tab,
    place_section, place_rank, closed_at, done_at, keep_after_close, dismissed_at, restored,
    seen_closed, quiet_from, quiet_until, merged_event_at, collected) VALUES
    ('1001:PR_1', '1001', 'PR_1', 'org', 'app', 1, 'https://github.com/org/app/pull/1',
     'One', 'alice', 'https://avatars.example/a', 'main', 'one', 'abc', 'open', 0,
     'review_required', 'failed', 'behind', 0, 'build', NULL, 1799999500, 1798000000, NULL,
     1799000500, 1, 1, 0, '["me"]', 'r', 'c', 'b', 0, 1799000100, 'review_required',
     'failed', 'behind', 0, 'failed', 'abc', 0, 'review', 'todo', 0, NULL, NULL, 0, NULL, 0,
     0, NULL, NULL, NULL, 1),
    ('1001:PR_2', '1001', 'PR_2', 'org', 'app', 2, 'https://github.com/org/app/pull/2',
     'Two', 'bob', NULL, 'main', 'two', NULL, 'open', 0, 'none', 'none', 'none', 0, NULL,
     NULL, 1799999400, 1798000000, NULL, NULL, 0, 0, 0, '[]', 'r', 'c', 'b', 0, 1799000200,
     NULL, NULL, NULL, NULL, NULL, NULL, 0, 'review', 'todo', 1, NULL, NULL, 0, NULL, 0, 0,
     NULL, NULL, NULL, 1),
    ('1001:PR_3', '1001', 'PR_3', 'org', 'app', 3, 'https://github.com/org/app/pull/3',
     'Three', 'carol', NULL, 'main', 'three', NULL, 'open', 1, 'none', 'none', 'none', 0,
     NULL, NULL, 1799999300, 1798000000, NULL, NULL, 0, 0, 0, '[]', 'r', 'c', 'b', 0,
     1799000300, NULL, NULL, NULL, NULL, NULL, NULL, 0, 'review', 'todo', 2, NULL, NULL, 0,
     NULL, 0, 0, NULL, NULL, NULL, 1),
    ('1001:PR_4', '1001', 'PR_4', 'org', 'app', 4, 'https://github.com/org/app/pull/4',
     'Four', 'dave', NULL, 'main', 'four', NULL, 'merged', 0, 'approved', 'passed',
     'up_to_date', 0, NULL, NULL, 1799999200, 1798000000, NULL, NULL, 0, 0, 0, '[]', 'r',
     'c', 'b', 0, 1799000400, NULL, NULL, NULL, NULL, NULL, NULL, 0, 'review', 'doing', 0,
     1799999000, 1799999000, 1, NULL, 0, 0, NULL, NULL, 1799998990, 1),
    ('1001:PR_5', '1001', 'PR_5', 'org', 'app', 5, 'https://github.com/org/app/pull/5',
     'Five', 'erin', NULL, 'main', 'five', NULL, 'closed', 0, 'none', 'none', 'none', 0,
     NULL, NULL, 1799999100, 1798000000, NULL, NULL, 0, 0, 0, '[]', 'r', 'c', 'b', 0,
     1799000500, NULL, NULL, NULL, NULL, NULL, NULL, 0, 'review', 'waiting', 0, 1799999000,
     1799999000, 0, NULL, 0, 0, NULL, NULL, NULL, 1),
    ('1001:PR_6', '1001', 'PR_6', 'org', 'app', 6, 'https://github.com/org/app/pull/6',
     'Six', 'me', NULL, 'main', 'six', NULL, 'open', 0, 'none', 'none', 'none', 0, NULL,
     NULL, 1799999000, 1798000000, NULL, NULL, 0, 0, 0, '[]', 'r', 'c', 'b', 0, 1799000600,
     NULL, NULL, NULL, NULL, NULL, NULL, 0, 'mine', 'main', 0, NULL, NULL, 0, 1799999900, 1,
     0, 1799000000, 1799000100, NULL, 0);
INSERT INTO pr_rows (id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id,
    unread, listed, made_at, notify) VALUES
    ('1001:R_1', '1001', '1001:PR_1', 'comment', 'hello', NULL, 'example-bot', 'u1', 1799999100,
     'C_9', 1, 1, 1799999101, 'pending'),
    ('1001:R_2', '1001', '1001:PR_1', 'team_mentioned', 'hi @org/core', NULL, 'bob', 'u2',
     1799999000, NULL, 0, 0, 1799999001, 'delivered'),
    ('1001:R_3', '1001', '1001:PR_4', 'merged', NULL, NULL, 'dave', 'u3', 1799998990, NULL,
     0, 1, 1799999000, 'none');
INSERT INTO deleted_rows (id, pr) VALUES ('1001:R_0', '1001:PR_1');
INSERT INTO dismiss_records (key, account, pr_id, owner, updated_at) VALUES
    ('1001:PR_R', '1001', 'PR_R', 'o2', 1799990000);
INSERT INTO reaction_baselines (key, pr, counts) VALUES
    ('1001:C_1', '1001:PR_1', '{"THUMBS_UP":2}');
"#;

/// One of each placement 0.5 saves (DESIGN.md, "Updating from 0.5"): Mine's
/// single list (section `main`) with ranks that leave gaps, a muted card
/// added by hand, a dismissed card; two cards in Mine's Done whose section
/// before Done is `main`, entered at the same time; Review's four sections.
/// A row and the Mute list come along to show nothing else changes.
const SEED_V7: &str = r#"
INSERT INTO meta (key, value) VALUES ('seq', '5'), ('restore_accounts', 'false');
INSERT INTO config (key, value) VALUES ('text_size', '14');
INSERT INTO accounts (id, login, color, seq, token, updated_at, dot, teams, graphql_limit,
    rest_limit, stopped_until, fetch) VALUES (
    '1001', 'me', 'none', 1, '{"registered":true}', 1799999000, 0,
    '[{"database_id":42,"slug":"core","org":"org"}]', NULL, NULL, NULL, '{}');
INSERT INTO mutes (account, kind, position, name) VALUES ('1001', 'pr', 0, 'org/app#2');
INSERT INTO owners (id, account, name, kind, github_id, seq, enabled, notify, skip_drafts,
    watch_started_at, fetched_at) VALUES
    ('o2', '1001', 'org', 'org', 100, 2, 1, 1, 1, 1799000000, 1799999000);
INSERT INTO pr_rows (id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id,
    unread, listed, made_at, notify) VALUES
    ('1001:R_1', '1001', '1001:PR_1', 'comment', 'hello', NULL, 'bob', 'u1', 1799999100,
     'C_9', 1, 1, 1799999101, 'delivered');
"#;

/// A `prs` row of the 0.5 schema: PR `n` of org/app by `author`, its state,
/// placement, Done entry (time and sequence) and Dismiss time.
#[allow(clippy::too_many_arguments)]
fn pr_v7(
    n: u32,
    author: &str,
    state: &str,
    tab: &str,
    section: &str,
    rank: i64,
    done: Option<(i64, i64)>,
    dismissed_at: Option<i64>,
) -> String {
    let null = |v: Option<i64>| v.map_or("NULL".to_string(), |v| v.to_string());
    let closed_at = if state == "open" {
        None
    } else {
        done.map(|(at, _)| at)
    };
    format!(
        "INSERT INTO prs (key, account, id, owner, repo, number, url, title, author,
            author_avatar_url, base, head, head_oid, state, is_draft, review, checks,
            base_status, mergeable, failed_check, changes_requested_by, updated_at, created_at,
            my_review_at, last_request_at, is_private, requested_me, requested_team, assignees,
            link_review, link_checks, link_base, unreadable, added_at, prev_review, prev_checks,
            prev_base_status, prev_mergeable, settled, settled_head, watch_reset, place_tab,
            place_section, place_rank, closed_at, done_at, keep_after_close, dismissed_at,
            restored, seen_closed, quiet_from, quiet_until, merged_event_at, collected,
            done_seq, unmuted) VALUES
            ('1001:PR_{n}', '1001', 'PR_{n}', 'org', 'app', {n},
             'https://github.example/PR_{n}', 'Title {n}', '{author}', NULL, 'main', 'topic',
             NULL, '{state}', 0, 'none', 'none', 'none', 0, NULL, NULL, 1799999000, 1798000000,
             NULL, NULL, 0, 0, 0, '[]', 'r', 'c', 'b', 0, 1799000000, 'none', 'none', 'none', 0,
             NULL, NULL, 0, '{tab}', '{section}', {rank}, {closed_at}, {done_at}, 0,
             {dismissed_at}, 0, 0, NULL, NULL, NULL, 1, {done_seq}, 0);",
        closed_at = null(closed_at),
        done_at = null(done.map(|(at, _)| at)),
        done_seq = done.map_or(0, |(_, seq)| seq),
        dismissed_at = null(dismissed_at),
    )
}

/// The cards of [`SEED_V7`].
fn cards_v7() -> String {
    [
        pr_v7(1, "me", "open", "mine", "main", 0, None, None),
        pr_v7(2, "alice", "open", "mine", "main", 2, None, None),
        pr_v7(
            3,
            "me",
            "open",
            "mine",
            "main",
            5,
            None,
            Some(1_799_999_900),
        ),
        pr_v7(4, "me", "open", "mine", "main", 7, None, None),
        pr_v7(
            5,
            "me",
            "merged",
            "mine",
            "main",
            1,
            Some((1_799_999_000, 3)),
            None,
        ),
        pr_v7(
            6,
            "me",
            "closed",
            "mine",
            "main",
            4,
            Some((1_799_999_000, 4)),
            None,
        ),
        pr_v7(7, "bob", "open", "review", "doing", 0, None, None),
        pr_v7(8, "bob", "open", "review", "todo", 0, None, None),
        pr_v7(9, "bob", "open", "review", "waiting", 0, None, None),
        pr_v7(
            10,
            "bob",
            "merged",
            "review",
            "waiting",
            1,
            Some((1_799_998_000, 1)),
            None,
        ),
    ]
    .concat()
}

/// A database of the given old version with its seed, plus `extra` SQL, at
/// `dir/state.db`.
fn old_database(dir: &Path, version: i64, extra: &str) -> PathBuf {
    let db = dir.join("state.db");
    let conn = Connection::open(&db).unwrap();
    let (schema, seed) = match version {
        8 => (include_str!("data/schema_v06.sql"), SEED_V8),
        7 => (include_str!("data/schema_v05.sql"), SEED_V7),
        6 => (include_str!("data/schema_v04.sql"), SEED_V6),
        5 => (include_str!("data/schema_v03.sql"), SEED_V5),
        4 => (include_str!("data/schema_v02.sql"), SEED_V4),
        other => panic!("no seed for version {other}"),
    };
    conn.execute_batch(schema).unwrap();
    conn.execute_batch(seed).unwrap();
    if version == 7 {
        conn.execute_batch(&cards_v7()).unwrap();
    }
    if version == 8 {
        conn.execute_batch(&cards_v8()).unwrap();
    }
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
    assert_eq!(SCHEMA_VERSION, 9);
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
fn a_0_3_database_moves_to_version_9_keeping_only_the_accounts() {
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
fn a_0_2_database_moves_to_version_9_keeping_only_the_accounts() {
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
fn a_moved_database_saves_and_opens_again_as_version_9() {
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
    // A view named like a version 9 table survives the drop of the old
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
    conn.execute_batch("CREATE TABLE t (x); PRAGMA user_version = 10;")
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

// ------------------------------------------------------------- from 0.4

#[test]
fn a_0_4_database_moves_to_version_9_keeping_everything() {
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 6, "");
    let counts: Vec<i64> = [
        "accounts",
        "owners",
        "owner_events",
        "prs",
        "pr_rows",
        "deleted_rows",
        "dismiss_records",
        "reaction_baselines",
        "mutes",
        "config",
        "meta",
    ]
    .iter()
    .map(|t| count(&db, t))
    .collect();
    let (store, data) = open(&db);
    drop(store);
    assert_eq!(version(&db), 9);
    let after: Vec<i64> = [
        "accounts",
        "owners",
        "owner_events",
        "prs",
        "pr_rows",
        "deleted_rows",
        "dismiss_records",
        "reaction_baselines",
        "mutes",
        "config",
        "meta",
    ]
    .iter()
    .map(|t| count(&db, t))
    .collect();
    assert_eq!(after, counts, "every row stays");

    let account = &data.accounts["1001"];
    assert_eq!(
        (account.login.as_str(), account.color),
        ("me", AccountColor::Red)
    );
    assert!(account.token.registered);
    assert_eq!(account.token.expires_at, Some(1_899_999_999));
    assert_eq!(account.updated_at, Some(1_799_999_000));
    assert!(account.dot);
    assert_eq!(
        account.teams,
        [TeamRec {
            database_id: 42,
            slug: "core".into(),
            org: None,
        }],
        "the teams of 0.4 read without their organization"
    );
    assert_eq!(account.graphql.map(|l| l.remaining), Some(4000));
    assert_eq!(account.rest.map(|l| l.remaining), Some(4900));
    assert_eq!(
        account.fetch.notif_since.as_deref(),
        Some("2027-01-15T08:00:00Z")
    );
    assert_eq!(account.fetch.retries["PR_C"].owner.as_deref(), Some("o2"));
    assert!(!account.fetch.retries["PR_C"].team_only);
    assert_eq!(
        account.mutes,
        MuteRec {
            repos: vec!["org/legacy".into()],
            users: vec!["example-bot".into()],
            prs: vec!["org/app#2".into()],
        }
    );
    assert_eq!(data.config.text_size, 15);
    assert_eq!(data.config.auto_dismiss_after_days, 5);
    assert_eq!(data.config.dismissed_keep_days, 9);
    assert_eq!(data.config.appearance, Appearance::Dark);
    assert_eq!(data.seq, 5);
    let org = &data.owners["o2"];
    assert!(!org.notify);
    assert!(!org.events.cell(EventKind::TeamMentioned).list);
    assert_eq!(data.owners.len(), 2);

    assert_eq!(data.prs.len(), 6);
    for pr in data.prs.values() {
        assert!(!pr.unmuted, "{}: no Unmute", pr.key);
        assert_eq!(pr.done_seq, 0, "{}", pr.key);
    }
    let pr1 = &data.prs["1001:PR_1"];
    assert_eq!(pr1.place.map(|p| p.rank), Some(0));
    assert_eq!(pr1.last_request_at, Some(1_799_000_500));
    assert_eq!(pr1.settled, Some(Checks::Failed));
    let pr6 = &data.prs["1001:PR_6"];
    assert_eq!(pr6.dismissed_at, Some(1_799_999_900));
    assert!(pr6.restored);
    // Through version 7 to 8: Mine's single list is Mine's Todo.
    assert_eq!(
        pr6.place,
        Some(PlaceRec {
            tab: PlacedTab::Mine,
            section: Section::Todo,
            rank: 0,
        })
    );
    assert_eq!(data.prs["1001:PR_4"].merged_event_at, Some(1_799_998_990));
    assert!(data.prs["1001:PR_4"].keep_after_close);

    assert_eq!(data.rows.len(), 3);
    let r1 = &data.rows["1001:R_1"];
    assert!(r1.unread);
    assert_eq!(r1.notify, NotifyState::Pending);
    assert!(!data.rows["1001:R_2"].listed);
    assert_eq!(data.deleted_rows["1001:R_0"], "1001:PR_1");
    assert_eq!(data.records["1001:PR_R"].updated_at, 1_799_990_000);
    assert_eq!(data.baselines["1001:C_1"].counts["THUMBS_UP"], 2);
}

#[test]
fn a_0_4_database_shows_its_ranks_and_done_order_after_the_move() {
    // docs/tasks/M7.md, "Database and migration": the muted card shows at
    // its rank (0.4 showed it last); Done keeps the order 0.4 gave it.
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 6, "");
    let (_, data) = open(&db);
    let engine = shiibar_ghd::engine::Engine::restore(data);
    let now = shiibar_ghd::clock::Now::fixed(1_800_000_000, "Asia/Tokyo").unwrap();
    let cards = engine
        .list(
            &shiibar_ghd::engine::ListArgs {
                tab: shiibar_gh_proto::Tab::Review,
                ..Default::default()
            },
            &now,
        )
        .unwrap();
    let order: Vec<(String, String, u32, bool)> = cards
        .iter()
        .map(|c| {
            let p = c.placement.as_ref().unwrap();
            (
                c.pr.clone(),
                p.section.as_text(),
                p.position,
                !c.muted.is_empty(),
            )
        })
        .collect();
    // The screen's section order: Done before Todo.
    let want = [
        ("org/app#4", "done", 0, false),
        ("org/app#5", "done", 1, false),
        ("org/app#1", "todo", 0, false),
        ("org/app#2", "todo", 1, true),
        ("org/app#3", "todo", 2, false),
    ];
    let want: Vec<(String, String, u32, bool)> = want
        .iter()
        .map(|(a, b, c, d)| (a.to_string(), b.to_string(), *c, *d))
        .collect();
    assert_eq!(order, want);
}

#[test]
fn a_moved_0_4_database_saves_and_opens_again() {
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 6, "");
    let (mut store, data) = open(&db);
    let mut engine = shiibar_ghd::engine::Engine::restore(data);
    let now = shiibar_ghd::clock::Now::fixed(1_800_000_000, "Asia/Tokyo").unwrap();
    engine.set_clock(&now);
    engine
        .unmute("me", shiibar_gh_proto::MuteKind::Pr, "org/app#2")
        .unwrap();
    engine
        .mute("me", shiibar_gh_proto::MuteKind::Repo, "org/app")
        .unwrap();
    engine
        .unmute("me", shiibar_gh_proto::MuteKind::Pr, "org/app#3")
        .unwrap();
    engine
        .place(
            "me",
            "org/app#1",
            &shiibar_ghd::engine::PlaceArgs {
                tab: shiibar_gh_proto::PlaceTab::Review,
                section: Some(shiibar_gh_proto::Section::Done),
                before: None,
                at: None,
            },
        )
        .unwrap();
    store.save(engine.data(), engine.dirty()).unwrap();
    drop(store);
    let (_, again) = open(&db);
    assert_eq!(&again, engine.data(), "nothing lost");
    assert!(again.prs["1001:PR_3"].unmuted);
    assert!(again.prs["1001:PR_1"].done_seq > 0);
}

#[test]
fn a_failed_move_from_0_4_rolls_back_and_leaves_version_6_unreadable() {
    // The second column cannot be added after the first one was, or the
    // step from 7 to 8 fails after both were: the move fails inside its
    // transaction either way.
    for extra in [
        "ALTER TABLE prs ADD COLUMN unmuted INTEGER;",
        "CREATE TRIGGER no_update BEFORE UPDATE ON prs BEGIN SELECT RAISE(ABORT, 'no'); END;",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let db = old_database(dir.path(), 6, extra);
        for start in 1..=2 {
            assert!(
                matches!(Store::open(&db).unwrap(), OpenOutcome::Unreadable),
                "start {start}"
            );
            assert_eq!(version(&db), 6, "start {start}: old version");
            let conn = Connection::open(&db).unwrap();
            let columns: Vec<String> = conn
                .prepare("SELECT name FROM pragma_table_info('prs')")
                .unwrap()
                .query_map([], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect();
            assert!(
                !columns.contains(&"done_seq".to_string()),
                "start {start}: the first column was rolled back"
            );
            assert_eq!(count(&db, "prs"), 6);
            let section: String = conn
                .query_row(
                    "SELECT place_section FROM prs WHERE key = '1001:PR_6'",
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(section, "main", "start {start}");
        }
    }
}

/// The daemon on a 0.4 state directory, with a test Keychain file and no
/// GitHub: the cards, their places and the Mute lists are there.
#[cfg(feature = "dev-ingest")]
#[test]
fn the_daemon_starts_on_a_0_4_state_directory() {
    use common::*;
    use serde_json::json;
    let dir = tempfile::tempdir().unwrap();
    old_database(dir.path(), 6, "");
    let item = dir.path().join("keychain.json");
    std::fs::write(
        &item,
        r#"{"version":2,"accounts":[{"id":"1001","login":"me","token":"ghp_test_only"}]}"#,
    )
    .unwrap();
    let mut command = command(dir.path());
    command
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", &item);
    let daemon = TestDaemon::spawn(dir.path(), command);
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], false);
    let me = daemon.account("me");
    assert_eq!(me["owners"].as_array().unwrap().len(), 2);
    let cards = daemon.ok(json!({"cmd":"list","account":"me","tab":"review"}))["cards"].clone();
    let prs: Vec<&str> = cards
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["pr"].as_str().unwrap())
        .collect();
    // Done (#4, #5) before Todo (#1, #2, #3).
    assert_eq!(
        prs,
        [
            "org/app#4",
            "org/app#5",
            "org/app#1",
            "org/app#2",
            "org/app#3"
        ]
    );
    assert_eq!(cards[3]["muted"], json!(["pr"]));
    assert_eq!(cards[3]["pr_mute"], "mute");
    assert_eq!(cards[2]["pr_mute"], "none");
    let mutes = daemon.ok(json!({"cmd":"mutes_get","account":"me"}))["mutes"].clone();
    assert_eq!(mutes["prs"], json!(["org/app#2"]));
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"text_size"}))["value"],
        15
    );
    daemon.stop();
}

// ------------------------------------------------------------- from 0.5

const TABLES: [&str; 11] = [
    "accounts",
    "owners",
    "owner_events",
    "prs",
    "pr_rows",
    "deleted_rows",
    "dismiss_records",
    "reaction_baselines",
    "mutes",
    "config",
    "meta",
];

#[test]
fn a_0_5_database_moves_to_version_9_keeping_everything() {
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 7, "");
    let counts: Vec<i64> = TABLES.iter().map(|t| count(&db, t)).collect();
    let (store, data) = open(&db);
    drop(store);
    assert_eq!(version(&db), 9);
    let after: Vec<i64> = TABLES.iter().map(|t| count(&db, t)).collect();
    assert_eq!(after, counts, "every row stays");

    // Mine's single list is Mine's Todo with the same ranks; the cards in
    // Done keep their entry and take Todo as their section before Done;
    // Review stays.
    let place = |n: u32| {
        let pr = &data.prs[&format!("1001:PR_{n}")];
        let p = pr.place.unwrap();
        (p.tab, p.section, p.rank, pr.done_at, pr.done_seq)
    };
    let want = [
        (1, PlacedTab::Mine, Section::Todo, 0, None, 0),
        (2, PlacedTab::Mine, Section::Todo, 2, None, 0),
        (3, PlacedTab::Mine, Section::Todo, 5, None, 0),
        (4, PlacedTab::Mine, Section::Todo, 7, None, 0),
        (5, PlacedTab::Mine, Section::Todo, 1, Some(1_799_999_000), 3),
        (6, PlacedTab::Mine, Section::Todo, 4, Some(1_799_999_000), 4),
        (7, PlacedTab::Review, Section::Doing, 0, None, 0),
        (8, PlacedTab::Review, Section::Todo, 0, None, 0),
        (9, PlacedTab::Review, Section::Waiting, 0, None, 0),
        (
            10,
            PlacedTab::Review,
            Section::Waiting,
            1,
            Some(1_799_998_000),
            1,
        ),
    ];
    for (n, tab, section, rank, done_at, done_seq) in want {
        assert_eq!(place(n), (tab, section, rank, done_at, done_seq), "PR_{n}");
    }
    assert_eq!(data.prs["1001:PR_3"].dismissed_at, Some(1_799_999_900));
    assert_eq!(
        data.accounts["1001"].mutes.prs,
        vec!["org/app#2".to_string()]
    );
    assert_eq!(data.config.text_size, 14);
    assert!(data.rows["1001:R_1"].unread);
    assert_eq!(
        data.accounts["1001"].teams[0].org.as_deref(),
        Some("org"),
        "the teams of 0.5 keep their organization"
    );
}

#[test]
fn a_0_5_database_lists_mine_in_the_same_order_after_the_move() {
    // docs/tasks/M9.md, "Risky points": the relative order of Mine's single
    // list is the order of Todo, seen in the wire `placement.position`.
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 7, "");
    let (_, data) = open(&db);
    let engine = shiibar_ghd::engine::Engine::restore(data);
    let now = shiibar_ghd::clock::Now::fixed(1_800_000_000, "Asia/Tokyo").unwrap();
    let order = |tab| -> Vec<(String, String, u32, bool, bool)> {
        engine
            .list(
                &shiibar_ghd::engine::ListArgs {
                    tab,
                    dismissed: shiibar_gh_proto::DismissedFilter::Include,
                    ..Default::default()
                },
                &now,
            )
            .unwrap()
            .iter()
            .map(|c| {
                let p = c.placement.as_ref().unwrap();
                (
                    c.pr.clone(),
                    p.section.as_text(),
                    p.position,
                    !c.muted.is_empty(),
                    c.dismissed_at.is_some(),
                )
            })
            .collect()
    };
    let want = |rows: &[(&str, &str, u32, bool, bool)]| -> Vec<(String, String, u32, bool, bool)> {
        rows.iter()
            .map(|(a, b, c, d, e)| (a.to_string(), b.to_string(), *c, *d, *e))
            .collect()
    };
    assert_eq!(
        order(shiibar_gh_proto::Tab::Mine),
        want(&[
            ("org/app#6", "done", 0, false, false),
            ("org/app#5", "done", 1, false, false),
            ("org/app#1", "todo", 0, false, false),
            ("org/app#2", "todo", 1, true, false),
            ("org/app#4", "todo", 2, false, false),
            // Dismissed: where it would come back, between #2 and #4.
            ("org/app#3", "todo", 2, false, true),
        ])
    );
    assert_eq!(
        order(shiibar_gh_proto::Tab::Review),
        want(&[
            ("org/app#10", "done", 0, false, false),
            ("org/app#9", "waiting", 0, false, false),
            ("org/app#7", "doing", 0, false, false),
            ("org/app#8", "todo", 0, false, false),
        ])
    );
}

#[test]
fn a_moved_0_5_database_saves_and_opens_again() {
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 7, "");
    let (mut store, data) = open(&db);
    let mut engine = shiibar_ghd::engine::Engine::restore(data);
    let now = shiibar_ghd::clock::Now::fixed(1_800_000_000, "Asia/Tokyo").unwrap();
    engine.set_clock(&now);
    engine
        .place(
            "me",
            "org/app#4",
            &shiibar_ghd::engine::PlaceArgs {
                tab: shiibar_gh_proto::PlaceTab::Mine,
                section: Some(shiibar_gh_proto::Section::Doing),
                before: None,
                at: None,
            },
        )
        .unwrap();
    store.save(engine.data(), engine.dirty()).unwrap();
    drop(store);
    let (_, again) = open(&db);
    assert_eq!(&again, engine.data(), "nothing lost");
    assert_eq!(
        again.prs["1001:PR_4"].place.map(|p| p.section),
        Some(Section::Doing)
    );
}

#[test]
fn a_failed_move_from_0_5_rolls_back_and_leaves_version_7_unreadable() {
    // The update fails inside the transaction, or the moved state cannot be
    // read (a section no build knows in Review): either way nothing changes.
    for extra in [
        "CREATE TRIGGER no_update BEFORE UPDATE ON prs BEGIN SELECT RAISE(ABORT, 'no'); END;",
        "UPDATE prs SET place_section = 'main' WHERE key = '1001:PR_7';",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let db = old_database(dir.path(), 7, extra);
        for start in 1..=2 {
            assert!(
                matches!(Store::open(&db).unwrap(), OpenOutcome::Unreadable),
                "{extra}: start {start}"
            );
            assert_eq!(version(&db), 7, "{extra}: start {start}: old version");
            let mains: i64 = Connection::open(&db)
                .unwrap()
                .query_row(
                    "SELECT count(*) FROM prs WHERE place_tab = 'mine' AND place_section = 'main'",
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(mains, 6, "{extra}: start {start}: rolled back");
        }
    }
}

/// The daemon on a 0.5 state directory, with a test Keychain file and no
/// GitHub: Mine's single list is Mine's Todo in the same order, and a
/// reopen takes a card in Mine's Done back to its rank in Todo.
#[cfg(feature = "dev-ingest")]
#[test]
fn the_daemon_starts_on_a_0_5_state_directory() {
    use common::*;
    use serde_json::{Value, json};
    let dir = tempfile::tempdir().unwrap();
    old_database(dir.path(), 7, "");
    let item = dir.path().join("keychain.json");
    std::fs::write(
        &item,
        r#"{"version":2,"accounts":[{"id":"1001","login":"me","token":"ghp_test_only"}]}"#,
    )
    .unwrap();
    let mut command = command(dir.path());
    command
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", &item);
    let daemon = TestDaemon::spawn(dir.path(), command);
    assert_eq!(daemon.subscribe("cli").snapshot()["db_unreadable"], false);
    let mine = || -> Vec<(String, Value)> {
        daemon.ok(json!({"cmd":"list","account":"me","tab":"mine"}))["cards"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| {
                (
                    c["pr"].as_str().unwrap().to_string(),
                    c["placement"].clone(),
                )
            })
            .collect()
    };
    let at = |pr: &str, section: &str, position: u32| {
        (
            pr.to_string(),
            json!({"tab":"mine","section":section,"position":position}),
        )
    };
    assert_eq!(
        mine(),
        [
            at("org/app#6", "done", 0),
            at("org/app#5", "done", 1),
            at("org/app#1", "todo", 0),
            at("org/app#2", "todo", 1),
            at("org/app#4", "todo", 2),
        ]
    );
    // A reopen of the cards in Done: back to their ranks in Todo.
    daemon.ingest(
        vec![
            with(pr("PR_5", "me"), json!({"updated_at": T0 + 10})),
            with(pr("PR_6", "me"), json!({"updated_at": T0 + 10})),
        ],
        vec![],
        vec![],
    );
    assert_eq!(
        mine(),
        [
            at("org/app#1", "todo", 0),
            at("org/app#5", "todo", 1),
            at("org/app#2", "todo", 2),
            at("org/app#6", "todo", 3),
            at("org/app#4", "todo", 4),
        ]
    );
    // The dismissed card comes back to its rank in Todo too.
    daemon.ok(json!({"cmd":"restore","account":"me","pr":"org/app#3"}));
    assert_eq!(mine()[4], at("org/app#3", "todo", 4));
    daemon.stop();
}

// ------------------------------------------------------------- from 0.6

/// One of everything 0.6 saves (DESIGN.md, "Updating from 0.6"): Mine's and
/// Review's four sections, a dismissed card, a muted card, Mute lists, an
/// event table, settings, rows of every kind (unread and read, the actor
/// kinds without a text), a deleted row, a Dismiss record and a Reaction
/// baseline.
const SEED_V8: &str = r#"
INSERT INTO meta (key, value) VALUES ('seq', '5'), ('restore_accounts', 'false');
INSERT INTO config (key, value) VALUES ('text_size', '15'), ('appearance', '"dark"');
INSERT INTO accounts (id, login, color, seq, token, updated_at, dot, teams, graphql_limit,
    rest_limit, stopped_until, fetch) VALUES (
    '1001', 'me', 'green', 1, '{"registered":true}', 1799999000, 1,
    '[{"database_id":42,"slug":"core","org":"org"}]', NULL, NULL, NULL, '{}');
INSERT INTO mutes (account, kind, position, name) VALUES
    ('1001', 'pr', 0, 'org/app#2'), ('1001', 'user', 0, 'example-bot'),
    ('1001', 'repo', 0, 'org/legacy');
INSERT INTO owners (id, account, name, kind, github_id, seq, enabled, notify, skip_drafts,
    watch_started_at, fetched_at) VALUES
    ('o2', '1001', 'org', 'org', 100, 2, 1, 1, 1, 1799000000, 1799999000);
INSERT INTO owner_events (owner, event, list, notify) VALUES
    ('o2', 'comment', 1, 0), ('o2', 'checks_passed', 0, 0);
INSERT INTO pr_rows (id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id,
    unread, listed, made_at, notify) VALUES
    ('1001:R_1', '1001', '1001:PR_1', 'review_requested', 'for you', NULL, 'bob', 'u1',
     1799999101, NULL, 1, 1, 1799999102, 'delivered'),
    ('1001:R_2', '1001', '1001:PR_1', 'team_review_requested', 'for core team', NULL, 'bob',
     'u2', 1799999102, NULL, 0, 1, 1799999103, 'none'),
    ('1001:R_3', '1001', '1001:PR_1', 'mentioned', 'hi @me', NULL, 'carol', 'u3', 1799999103,
     'C_3', 1, 1, 1799999104, 'pending'),
    ('1001:R_4', '1001', '1001:PR_1', 'team_mentioned', 'hi @org/core', NULL, 'carol', 'u4',
     1799999104, 'C_4', 0, 0, 1799999105, 'delivered'),
    ('1001:R_5', '1001', '1001:PR_1', 'comment', 'hello', NULL, 'alice', 'u5', 1799999105,
     'C_5', 1, 1, 1799999106, 'pending'),
    ('1001:R_6', '1001', '1001:PR_1', 'comment_other', 'hey', NULL, 'alice', 'u6', 1799999106,
     'C_6', 0, 1, 1799999107, 'none'),
    ('1001:R_7', '1001', '1001:PR_1', 'reply', 'yes', NULL, 'dave', 'u7', 1799999107, 'C_7', 1,
     1, 1799999108, 'delivered'),
    ('1001:R_8', '1001', '1001:PR_1', 'reply_mentioned', 'and you', NULL, 'dave', 'u8',
     1799999108, 'C_8', 0, 1, 1799999109, 'none'),
    ('1001:R_9', '1001', '1001:PR_1', 'reaction', 'my comment', '{"THUMBS_UP":2}', NULL, 'u9',
     1799999109, 'C_1', 1, 1, 1799999110, 'none'),
    ('1001:R_10', '1001', '1001:PR_1', 'approved', NULL, NULL, 'erin', 'u10', 1799999110, NULL,
     1, 1, 1799999111, 'delivered'),
    ('1001:R_11', '1001', '1001:PR_1', 'changes_requested', NULL, NULL, NULL, 'u11',
     1799999111, NULL, 0, 1, 1799999112, 'none'),
    ('1001:R_12', '1001', '1001:PR_1', 'checks_failed', 'build', NULL, NULL, 'u12',
     1799999112, NULL, 1, 1, 1799999113, 'delivered'),
    ('1001:R_13', '1001', '1001:PR_1', 'checks_passed', NULL, NULL, NULL, 'u13', 1799999113,
     NULL, 0, 0, 1799999114, 'none'),
    ('1001:R_14', '1001', '1001:PR_1', 'conflicts', NULL, NULL, NULL, 'u14', 1799999114, NULL,
     1, 1, 1799999115, 'none'),
    ('1001:R_15', '1001', '1001:PR_1', 'mergeable', NULL, NULL, NULL, 'u15', 1799999115, NULL,
     0, 1, 1799999116, 'none'),
    ('1001:R_16', '1001', '1001:PR_1', 'merge_queue_added', NULL, NULL, 'me', 'u16',
     1799999116, NULL, 1, 1, 1799999117, 'delivered'),
    ('1001:R_17', '1001', '1001:PR_1', 'merge_queue_removed', 'Checks failed · added by me',
     NULL, 'github-merge-queue', 'u17', 1799999117, NULL, 1, 1, 1799999118, 'pending'),
    ('1001:R_18', '1001', '1001:PR_5', 'merged', NULL, NULL, 'me', 'u18', 1799999118, NULL, 1,
     1, 1799999119, 'delivered'),
    ('1001:R_19', '1001', '1001:PR_6', 'closed', NULL, NULL, 'bob', 'u19', 1799999119, NULL,
     0, 1, 1799999120, 'none'),
    ('1001:R_20', '1001', '1001:PR_1', 'reopened', NULL, NULL, 'me', 'u20', 1799999120, NULL,
     0, 1, 1799999121, 'none');
INSERT INTO deleted_rows (id, pr) VALUES ('1001:R_0', '1001:PR_1');
INSERT INTO dismiss_records (key, account, pr_id, owner, updated_at) VALUES
    ('1001:PR_R', '1001', 'PR_R', 'o2', 1799990000);
INSERT INTO reaction_baselines (key, pr, counts) VALUES
    ('1001:C_1', '1001:PR_1', '{"THUMBS_UP":2}');
"#;

/// The cards of [`SEED_V8`]: the 0.6 `prs` layout is the 0.5 one.
fn cards_v8() -> String {
    [
        pr_v7(1, "me", "open", "mine", "doing", 0, None, None),
        pr_v7(2, "alice", "open", "mine", "todo", 0, None, None),
        pr_v7(
            3,
            "me",
            "open",
            "mine",
            "todo",
            1,
            None,
            Some(1_799_999_900),
        ),
        pr_v7(4, "me", "open", "mine", "waiting", 0, None, None),
        pr_v7(
            5,
            "me",
            "merged",
            "mine",
            "todo",
            2,
            Some((1_799_999_000, 3)),
            None,
        ),
        pr_v7(
            6,
            "bob",
            "closed",
            "review",
            "waiting",
            1,
            Some((1_799_998_000, 1)),
            None,
        ),
        pr_v7(7, "bob", "open", "review", "doing", 0, None, None),
        pr_v7(8, "bob", "open", "review", "todo", 0, None, None),
        pr_v7(9, "bob", "open", "review", "waiting", 0, None, None),
    ]
    .concat()
}

/// The names of a table's columns.
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

#[test]
fn a_0_6_database_moves_to_version_9_keeping_everything() {
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 8, "");
    let counts: Vec<i64> = TABLES.iter().map(|t| count(&db, t)).collect();
    let before = {
        let conn = Connection::open(&db).unwrap();
        let mut statement = conn
            .prepare("SELECT id, kind, text, actor, unread, notify FROM pr_rows ORDER BY id")
            .unwrap();
        statement
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, bool>(4)?,
                    r.get::<_, String>(5)?,
                ))
            })
            .unwrap()
            .map(Result::unwrap)
            .collect::<Vec<_>>()
    };
    let (store, data) = open(&db);
    drop(store);
    assert_eq!(version(&db), 9);
    let after: Vec<i64> = TABLES.iter().map(|t| count(&db, t)).collect();
    assert_eq!(after, counts, "every row stays");
    assert!(columns(&db, "prs").contains(&"timeline_updated_at".to_string()));
    assert!(columns(&db, "pr_rows").contains(&"actor_avatar_url".to_string()));

    // Every row keeps its kind, text, actor, unread mark and delivery, and
    // has no avatar: the rows of the account's own events made by 0.6 stay
    // unread.
    let mut rows: Vec<_> = data.rows.values().collect();
    rows.sort_by(|a, b| a.id.cmp(&b.id));
    let now: Vec<_> = rows
        .iter()
        .map(|r| {
            (
                r.id.clone(),
                r.kind.as_str().to_string(),
                r.text.clone(),
                r.actor.clone(),
                r.unread,
                r.notify.as_str().to_string(),
            )
        })
        .collect();
    assert_eq!(now, before);
    assert_eq!(rows.len(), 20, "one of every kind");
    assert!(rows.iter().all(|r| r.actor_avatar_url.is_none()));
    assert!(data.rows["1001:R_16"].unread, "own merge queue addition");
    assert!(data.rows["1001:R_18"].unread, "own merge");
    assert_eq!(data.rows["1001:R_10"].text, None, "Approved has no text");
    assert!(data.deleted_rows.contains_key("1001:R_0"));

    // Placements, Done entries, Dismiss and Mute stay; no PR has a
    // timeline time yet.
    let place = |n: u32| {
        let pr = &data.prs[&format!("1001:PR_{n}")];
        let p = pr.place.unwrap();
        (p.tab, p.section, p.rank, pr.done_at, pr.done_seq)
    };
    let want = [
        (1, PlacedTab::Mine, Section::Doing, 0, None, 0),
        (2, PlacedTab::Mine, Section::Todo, 0, None, 0),
        (3, PlacedTab::Mine, Section::Todo, 1, None, 0),
        (4, PlacedTab::Mine, Section::Waiting, 0, None, 0),
        (5, PlacedTab::Mine, Section::Todo, 2, Some(1_799_999_000), 3),
        (
            6,
            PlacedTab::Review,
            Section::Waiting,
            1,
            Some(1_799_998_000),
            1,
        ),
        (7, PlacedTab::Review, Section::Doing, 0, None, 0),
        (8, PlacedTab::Review, Section::Todo, 0, None, 0),
        (9, PlacedTab::Review, Section::Waiting, 0, None, 0),
    ];
    for (n, tab, section, rank, done_at, done_seq) in want {
        assert_eq!(place(n), (tab, section, rank, done_at, done_seq), "PR_{n}");
    }
    assert!(data.prs.values().all(|p| p.timeline_updated_at.is_none()));
    assert_eq!(data.prs["1001:PR_3"].dismissed_at, Some(1_799_999_900));
    let mutes = &data.accounts["1001"].mutes;
    assert_eq!(mutes.prs, vec!["org/app#2".to_string()]);
    assert_eq!(mutes.users, vec!["example-bot".to_string()]);
    assert_eq!(mutes.repos, vec!["org/legacy".to_string()]);
    assert_eq!(data.config.text_size, 15);
    assert_eq!(data.records.len(), 1);
    assert_eq!(data.baselines.len(), 1);
}

#[test]
fn a_moved_0_6_database_saves_and_opens_again() {
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(dir.path(), 8, "");
    let (mut store, mut data) = open(&db);
    data.prs.get_mut("1001:PR_1").unwrap().timeline_updated_at = Some(1_799_999_500);
    data.rows.get_mut("1001:R_3").unwrap().actor_avatar_url =
        Some("https://avatars.example/carol".into());
    let engine = shiibar_ghd::engine::Engine::restore(data.clone());
    let mut dirty = engine.dirty().clone();
    dirty.prs.insert("1001:PR_1".into());
    dirty.rows.insert("1001:R_3".into());
    store.save(engine.data(), &dirty).unwrap();
    drop(store);
    let (_, again) = open(&db);
    assert_eq!(&again, engine.data(), "nothing lost");
    assert_eq!(
        again.prs["1001:PR_1"].timeline_updated_at,
        Some(1_799_999_500)
    );
    assert_eq!(
        again.rows["1001:R_3"].actor_avatar_url.as_deref(),
        Some("https://avatars.example/carol")
    );
}

#[test]
fn a_failed_move_from_0_6_rolls_back_and_leaves_version_8_unreadable() {
    // The second column cannot be added after the first one was, or the
    // moved state cannot be read (a section no build knows in Review):
    // either way the move fails inside its transaction and nothing changes.
    for extra in [
        "ALTER TABLE pr_rows ADD COLUMN actor_avatar_url TEXT;",
        "UPDATE prs SET place_section = 'main' WHERE key = '1001:PR_7';",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let db = old_database(dir.path(), 8, extra);
        let rows = count(&db, "pr_rows");
        for start in 1..=2 {
            assert!(
                matches!(Store::open(&db).unwrap(), OpenOutcome::Unreadable),
                "{extra}: start {start}"
            );
            assert_eq!(version(&db), 8, "{extra}: start {start}: old version");
            assert!(
                !columns(&db, "prs").contains(&"timeline_updated_at".to_string()),
                "{extra}: start {start}: rolled back"
            );
            assert_eq!(count(&db, "pr_rows"), rows);
        }
    }
}

/// The daemon on a 0.6 state directory, with a test Keychain file and no
/// GitHub: the sections list in the new order with the same cards, and the
/// rows keep their unread marks, without avatars and without a `by` text.
#[cfg(feature = "dev-ingest")]
#[test]
fn the_daemon_starts_on_a_0_6_state_directory() {
    use common::*;
    use serde_json::{Value, json};
    let dir = tempfile::tempdir().unwrap();
    old_database(dir.path(), 8, "");
    let item = dir.path().join("keychain.json");
    std::fs::write(
        &item,
        r#"{"version":2,"accounts":[{"id":"1001","login":"me","token":"ghp_test_only"}]}"#,
    )
    .unwrap();
    let mut command = command(dir.path());
    command
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", &item);
    let daemon = TestDaemon::spawn(dir.path(), command);
    assert_eq!(daemon.subscribe("cli").snapshot()["db_unreadable"], false);
    let list = |tab: &str| -> Vec<(String, Value)> {
        daemon.ok(json!({"cmd":"list","account":"me","tab":tab}))["cards"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| {
                (
                    c["pr"].as_str().unwrap().to_string(),
                    c["placement"]["section"].clone(),
                )
            })
            .collect()
    };
    let at = |pr: &str, section: &str| (pr.to_string(), json!(section));
    assert_eq!(
        list("mine"),
        [
            at("org/app#5", "done"),
            at("org/app#4", "waiting"),
            at("org/app#1", "doing"),
            at("org/app#2", "todo"),
        ]
    );
    assert_eq!(
        list("review"),
        [
            at("org/app#6", "done"),
            at("org/app#9", "waiting"),
            at("org/app#7", "doing"),
            at("org/app#8", "todo"),
        ]
    );
    let cards = daemon.ok(json!({"cmd":"list","account":"me","tab":"all"}))["cards"].clone();
    let card = cards
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["pr"] == "org/app#5")
        .unwrap()
        .clone();
    let merged = &card["rows"][0];
    assert_eq!(merged["kind"], "merged");
    assert_eq!(merged["text"], Value::Null);
    assert_eq!(merged["actor"], "me");
    assert_eq!(merged["actor_avatar_url"], Value::Null);
    assert_eq!(merged["unread"], true, "a 0.6 row keeps its unread mark");
    daemon.stop();
}

#[test]
fn a_card_without_the_time_it_was_added_sorts_as_the_oldest() {
    // DESIGN.md, "All", "Order": a card with no row and no added time (a
    // record without one) comes after every other, as in the app.
    let dir = tempfile::tempdir().unwrap();
    let db = old_database(
        dir.path(),
        8,
        "UPDATE prs SET added_at = NULL WHERE key = '1001:PR_8';",
    );
    let (_, data) = open(&db);
    assert_eq!(data.prs["1001:PR_8"].added_at, None);
    let engine = shiibar_ghd::engine::Engine::restore(data);
    let now = shiibar_ghd::clock::Now::fixed(1_800_000_000, "Asia/Tokyo").unwrap();
    let all: Vec<String> = engine
        .list(&shiibar_ghd::engine::ListArgs::default(), &now)
        .unwrap()
        .into_iter()
        .map(|c| c.pr)
        .collect();
    assert_eq!(all.last().map(String::as_str), Some("org/app#8"), "{all:?}");
}
