//! Startup, files and the socket, none of which needs injected events.

mod common;

use common::*;
use serde_json::json;
use std::io::Write;
use std::process::{Command, Stdio};

fn exit_code(mut command: Command) -> i32 {
    command
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .code()
        .unwrap()
}

fn start(dir: &std::path::Path) -> TestDaemon {
    TestDaemon::spawn(dir, command(dir))
}

#[test]
fn starting_without_foreground_is_a_usage_error() {
    let dir = tempfile::tempdir().unwrap();
    let mut bare = Command::new(binary());
    bare.env("SHIIBAR_GH_STATE_DIR", dir.path());
    assert_eq!(exit_code(bare), 1);
    let mut other = Command::new(binary());
    other
        .args(["--foreground", "--extra"])
        .env("SHIIBAR_GH_STATE_DIR", dir.path());
    assert_eq!(exit_code(other), 1);
}

#[test]
fn files_have_explicit_modes_under_any_umask() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let mut loose = Command::new("sh");
    loose
        .args(["-c", "umask 000; exec \"$0\" --foreground", binary()])
        .env("SHIIBAR_GH_STATE_DIR", &state)
        .env("SHIIBAR_GH_LOG", "error")
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let daemon = TestDaemon::spawn(&state, loose);
    assert_eq!(mode(&state), 0o700);
    for file in [
        "shiibar-ghd.sock",
        "shiibar-ghd.lock",
        "state.db",
        "state.db-wal",
        "state.db-shm",
    ] {
        assert_eq!(mode(&state.join(file)), 0o600, "{file}");
    }
    daemon.stop();
}

#[test]
fn a_loose_state_directory_is_tightened() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    let daemon = start(dir.path());
    assert_eq!(mode(dir.path()), 0o700);
    daemon.stop();
}

#[test]
fn a_second_daemon_exits_with_1_and_leaves_the_first_alone() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path());
    assert_eq!(exit_code(command(dir.path())), 1);
    daemon.ok(json!({"cmd":"info"}));
    daemon.stop();
}

#[test]
fn a_lock_held_by_a_silent_process_also_blocks_a_second_daemon() {
    let dir = tempfile::tempdir().unwrap();
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.path().join("shiibar-ghd.lock"))
        .unwrap();
    lock.lock().unwrap();
    assert_eq!(exit_code(command(dir.path())), 1);
}

#[test]
fn a_stale_socket_file_is_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let stale =
        std::os::unix::net::UnixListener::bind(dir.path().join("shiibar-ghd.sock")).unwrap();
    drop(stale);
    let daemon = start(dir.path());
    daemon.ok(json!({"cmd":"info"}));
    daemon.stop();
}

#[test]
fn shutdown_answers_then_removes_the_socket() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path());
    let socket = daemon.socket();
    daemon.stop();
    assert!(!socket.exists());
}

#[test]
fn a_kill_leaves_a_daemon_that_can_start_again() {
    let dir = tempfile::tempdir().unwrap();
    start(dir.path()).kill();
    let daemon = start(dir.path());
    daemon.ok(json!({"cmd":"info"}));
    daemon.stop();
}

#[test]
fn malformed_requests_are_invalid() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path());
    assert_eq!(daemon.raw("not json")["code"], "invalid");
    assert_eq!(daemon.raw("{}")["code"], "invalid");
    assert_eq!(daemon.code(json!({"cmd":"nope"})), "invalid");
    assert_eq!(daemon.code(json!({"cmd":"done"})), "invalid");
    assert_eq!(
        daemon.code(json!({"cmd":"subscribe"})),
        "invalid",
        "client is required"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"subscribe","client":"x"})),
        "invalid"
    );
    assert_eq!(daemon.code(json!({"cmd":"open"})), "invalid");
    assert_eq!(
        daemon.code(json!({"cmd":"open","pr":"a/b#1","row":"x"})),
        "invalid"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"list","mine":true,"others":true})),
        "invalid"
    );
    daemon.stop();
}

#[test]
fn refresh_succeeds_without_fetching() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path());
    daemon.ok(json!({"cmd":"refresh"}));
    daemon.ok(json!({"cmd":"refresh","scope":"public"}));
    assert_eq!(
        daemon.code(json!({"cmd":"refresh","scope":"nobody"})),
        "not_found"
    );
    daemon.stop();
}

#[test]
fn the_first_snapshot_has_public_only() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path());
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], false);
    assert_eq!(snapshot["scopes"].as_array().unwrap().len(), 1);
    assert_eq!(
        snapshot["scopes"][0],
        json!({"id":"public","name":"Public","kind":"public","enabled":true,"notify":true,
               "badge":0,"dot":false,"warnings":[],"updated_at":null})
    );
    daemon.stop();
}

#[test]
fn a_database_from_a_newer_program_is_an_exit_not_the_waiting_state() {
    let dir = tempfile::tempdir().unwrap();
    start(dir.path()).stop();
    let conn = rusqlite::Connection::open(dir.path().join("state.db")).unwrap();
    conn.pragma_update(None, "user_version", 999).unwrap();
    drop(conn);
    assert_eq!(exit_code(command(dir.path())), 1);
}

#[test]
fn a_database_locked_by_another_process_is_an_exit_not_the_waiting_state() {
    let dir = tempfile::tempdir().unwrap();
    start(dir.path()).stop();
    let conn = rusqlite::Connection::open(dir.path().join("state.db")).unwrap();
    conn.execute_batch("BEGIN EXCLUSIVE").unwrap();
    assert_eq!(exit_code(command(dir.path())), 1);
    conn.execute_batch("ROLLBACK").unwrap();
    assert!(!dir.path().join("shiibar-ghd.sock").exists());
}

#[test]
fn an_older_database_is_migrated() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("state.db");
    // Version 0: a valid SQLite file that has none of the tables.
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch("CREATE TABLE unrelated (x); PRAGMA user_version = 0;")
        .unwrap();
    drop(conn);
    let daemon = start(dir.path());
    assert_eq!(daemon.scopes().len(), 1);
    daemon.stop();
    let conn = rusqlite::Connection::open(&db).unwrap();
    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, shiibar_ghd::store::SCHEMA_VERSION);
}

#[test]
fn a_damaged_file_starts_the_waiting_state_without_touching_it() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("state.db");
    let damaged = vec![0xAB; 8192];
    let mut file = std::fs::File::create(&db).unwrap();
    file.write_all(&damaged).unwrap();
    drop(file);
    std::fs::write(dir.path().join("state.db-wal"), b"old wal").unwrap();
    std::fs::write(dir.path().join("state.db-shm"), b"old shm").unwrap();

    let daemon = start(dir.path());
    daemon.ok(json!({"cmd":"info"}));
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], true);
    assert_eq!(snapshot["scopes"][0]["id"], "public");
    assert_eq!(snapshot["scopes"][0]["badge"], 0);
    assert_eq!(snapshot["scopes"][0]["dot"], false);
    assert_eq!(snapshot["scopes"].as_array().unwrap().len(), 1);

    for request in [
        json!({"cmd":"list"}),
        json!({"cmd":"activity"}),
        json!({"cmd":"status","pr":"a/b#1"}),
        json!({"cmd":"seen","row_ids":[]}),
        json!({"cmd":"popover_opened","scope":"public"}),
        json!({"cmd":"popover_closed","scope":"public"}),
        json!({"cmd":"done","row":"x"}),
        json!({"cmd":"undone","row":"x"}),
        json!({"cmd":"snooze","pr":"a/b#1"}),
        json!({"cmd":"unsnooze","pr":"a/b#1"}),
        json!({"cmd":"refresh"}),
        json!({"cmd":"open","row":"x"}),
        json!({"cmd":"config_get","key":"notify_state"}),
        json!({"cmd":"config_set","key":"notify_state","value":false}),
        json!({"cmd":"scope_list"}),
        json!({"cmd":"scope_add","owner":"a"}),
        json!({"cmd":"scope_remove","owner":"a"}),
        json!({"cmd":"scope_enable","scope":"public"}),
        json!({"cmd":"scope_disable","scope":"public"}),
        json!({"cmd":"scope_notify","scope":"public","on":false}),
    ] {
        assert_eq!(daemon.code(request.clone()), "internal", "{request}");
    }
    assert_eq!(
        std::fs::read(&db).unwrap(),
        damaged,
        "the database did not change"
    );
    assert_eq!(
        std::fs::read(dir.path().join("state.db-wal")).unwrap(),
        b"old wal"
    );

    daemon.ok(json!({"cmd":"reset"}));
    let names: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    let retired = names
        .iter()
        .find(|n| {
            n.starts_with("state.db.corrupt-") && !n.ends_with("-wal") && !n.ends_with("-shm")
        })
        .unwrap_or_else(|| panic!("{names:?}"));
    let retired_path = dir.path().join(retired);
    assert_eq!(
        std::fs::read(&retired_path).unwrap(),
        damaged,
        "kept as it was"
    );
    assert_eq!(mode(&retired_path), 0o600);
    for suffix in ["-wal", "-shm"] {
        let side = dir.path().join(format!("{retired}{suffix}"));
        assert_eq!(mode(&side), 0o600, "{suffix}");
    }
    assert_eq!(
        std::fs::read(dir.path().join(format!("{retired}-wal"))).unwrap(),
        b"old wal",
        "the old WAL does not stay next to the new database"
    );
    assert_ne!(std::fs::read(&db).unwrap(), damaged);

    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], false);
    daemon.ok(json!({"cmd":"config_set","key":"notify_state","value":false}));
    daemon.stop();
}

#[test]
fn reset_on_a_readable_database_is_invalid_and_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path());
    daemon.ok(json!({"cmd":"config_set","key":"notify_state","value":false}));
    let response = daemon.request(json!({"cmd":"reset"}));
    assert_eq!(response["code"], "invalid");
    assert_eq!(
        response["error"],
        "saved state is readable; nothing to reset"
    );
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"notify_state"}))["value"],
        false
    );
    daemon.stop();
}

#[test]
fn settings_survive_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path());
    for (key, value) in [
        ("launch_at_login", json!(false)),
        ("status_interval_minutes", json!(9)),
        ("snooze_return_time", json!("07:45")),
        ("bot_comments", json!("notify")),
        ("drop_after_days", json!(2)),
    ] {
        daemon.ok(json!({"cmd":"config_set","key":key,"value":value}));
    }
    daemon.stop();
    let daemon = start(dir.path());
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"launch_at_login"}))["value"],
        false
    );
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"status_interval_minutes"}))["value"],
        9
    );
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"snooze_return_time"}))["value"],
        "07:45"
    );
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"bot_comments"}))["value"],
        "notify"
    );
    assert_eq!(
        daemon.ok(json!({"cmd":"config_get","key":"drop_after_days"}))["value"],
        2
    );
    daemon.stop();
}
