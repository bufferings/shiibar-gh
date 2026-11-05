//! Startup, files and the socket, none of which needs injected events.
//!
//! The default build reads the real Keychain when it restores scopes for
//! `reset` and for the unreadable state, so those tests run only in the
//! `dev-ingest` build, which has no Keychain unless a test gives it a file
//! (docs/tasks/M2.md, "How to test").

mod common;

use common::*;
use serde_json::json;
use std::process::{Command, Stdio};

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
fn an_unfinished_socket_from_a_crash_is_replaced() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("shiibar-ghd.new"), b"").unwrap();
    let daemon = start(dir.path());
    daemon.ok(json!({"cmd":"info"}));
    assert!(!dir.path().join("shiibar-ghd.new").exists());
    daemon.stop();
}

/// `sun_path` holds 104 bytes on macOS, so 103 plus the terminator is the
/// longest socket path that binds.
#[test]
fn a_socket_path_at_the_length_limit_starts() {
    const LONGEST_SOCKET_PATH: usize = 103;
    let dir = tempfile::tempdir().unwrap();
    let used = dir.path().join("shiibar-ghd.sock");
    let padding = LONGEST_SOCKET_PATH - used.as_os_str().len() - 1;
    let state = dir.path().join("x".repeat(padding));
    let socket = state.join("shiibar-ghd.sock");
    assert_eq!(socket.as_os_str().len(), LONGEST_SOCKET_PATH);
    let daemon = start(&state);
    daemon.ok(json!({"cmd":"info"}));
    daemon.stop();

    let too_long = dir.path().join("x".repeat(padding + 1));
    assert_eq!(exit_code(command(&too_long)), 1, "one byte past the limit");
    assert!(!too_long.join("shiibar-ghd.sock").exists());
}

#[test]
#[should_panic(expected = "did not exit within")]
fn a_process_that_never_ends_fails_the_test_instead_of_hanging_it() {
    let mut child = Command::new("tail")
        .args(["-f", "/dev/null"])
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    wait_within(&mut child, std::time::Duration::from_millis(100), "tail");
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
    assert_eq!(
        daemon.code(json!({"cmd":"refresh","scope":"public"})),
        "not_found",
        "Public is not there until it is added"
    );
    daemon.ok(json!({"cmd":"scope_add","owner":"public"}));
    daemon.ok(json!({"cmd":"refresh","scope":"public"}));
    assert_eq!(
        daemon.code(json!({"cmd":"refresh","scope":"nobody"})),
        "not_found"
    );
    daemon.stop();
}

#[test]
fn the_first_snapshot_has_no_scope_and_public_is_added_beige() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path());
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], false);
    assert_eq!(
        snapshot["scopes"],
        json!([]),
        "Public does not exist at first"
    );

    daemon.ok(json!({"cmd":"scope_add","owner":"Public"}));
    let snapshot = daemon.subscribe("cli").snapshot();
    // No token yet: both the notifications token and Public's are missing.
    assert_eq!(
        snapshot["scopes"],
        json!([{"id":"public","name":"Public","kind":"public","enabled":true,"notify":true,
               "color":"beige","badge":0,"dot":false,"warnings":[
                   {"kind":"no_token","token":"notifications","message":"Add a token in Settings","until":null},
                   {"kind":"no_token","token":"scope","message":"Add a token in Settings","until":null}
               ],"updated_at":null}])
    );
    daemon.stop();
}

#[test]
fn new_scopes_take_the_six_colors_in_turn_and_keep_them() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path());
    daemon.ok(json!({"cmd":"scope_add","owner":"public"}));
    for n in 0..7 {
        daemon.ok(json!({"cmd":"scope_add","owner":format!("o{n}")}));
    }
    let colors = |daemon: &TestDaemon| -> Vec<(String, String)> {
        daemon
            .scopes()
            .iter()
            .map(|s| {
                (
                    s["id"].as_str().unwrap().to_string(),
                    s["color"].as_str().unwrap().to_string(),
                )
            })
            .collect()
    };
    let expected: Vec<(String, String)> = [
        ("o0", "gray"),
        ("o1", "green"),
        ("o2", "blue"),
        ("o3", "purple"),
        ("o4", "pink"),
        ("o5", "beige"),
        ("o6", "gray"),
        ("public", "beige"),
    ]
    .iter()
    .map(|(id, color)| (id.to_string(), color.to_string()))
    .collect();
    assert_eq!(colors(&daemon), expected, "Public does not take a turn");

    // Removing and adding again restores the color; a new scope continues
    // the cycle.
    daemon.ok(json!({"cmd":"scope_color","scope":"O1","color":"pink"}));
    daemon.ok(json!({"cmd":"scope_remove","owner":"o1"}));
    daemon.ok(json!({"cmd":"scope_remove","owner":"public"}));
    assert!(colors(&daemon).iter().all(|(id, _)| id != "public"));
    daemon.ok(json!({"cmd":"scope_add","owner":"o1"}));
    daemon.ok(json!({"cmd":"scope_add","owner":"public"}));
    daemon.stop();
    let daemon = start(dir.path());
    daemon.ok(json!({"cmd":"scope_add","owner":"o7"}));
    let after = colors(&daemon);
    assert!(after.contains(&("o1".into(), "pink".into())), "{after:?}");
    assert!(
        after.contains(&("public".into(), "beige".into())),
        "{after:?}"
    );
    assert!(after.contains(&("o7".into(), "green".into())), "{after:?}");
    assert_eq!(
        daemon.code(json!({"cmd":"scope_color","scope":"o7","color":"Red"})),
        "invalid"
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
    assert!(daemon.scopes().is_empty());
    daemon.stop();
    let conn = rusqlite::Connection::open(&db).unwrap();
    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, shiibar_ghd::store::SCHEMA_VERSION);
}

#[test]
#[cfg(feature = "dev-ingest")]
fn a_damaged_file_starts_the_waiting_state_without_touching_it() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("state.db");
    let damaged = vec![0xAB; 8192];
    std::fs::write(&db, &damaged).unwrap();
    std::fs::write(dir.path().join("state.db-wal"), b"old wal").unwrap();
    std::fs::write(dir.path().join("state.db-shm"), b"old shm").unwrap();

    let daemon = start(dir.path());
    daemon.ok(json!({"cmd":"info"}));
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], true);
    assert_eq!(snapshot["scopes"], json!([]), "no token restores no scope");

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

mod side_files {
    use super::*;
    use std::path::Path;

    const PAGE: usize = 4096;

    fn remove_side_files(dir: &Path) {
        for name in ["state.db-wal", "state.db-shm"] {
            let path = dir.join(name);
            if path.exists() {
                std::fs::remove_file(path).unwrap();
            }
        }
    }

    /// Everything after the first page, so the header still says WAL mode.
    #[cfg_attr(not(feature = "dev-ingest"), allow(dead_code))]
    fn damage_pages(dir: &Path) -> Vec<u8> {
        let path = dir.join("state.db");
        let mut bytes = std::fs::read(&path).unwrap();
        assert!(bytes.len() > PAGE, "{}", bytes.len());
        assert_eq!(&bytes[18..20], [2, 2], "a WAL mode header");
        bytes[PAGE..].fill(0xCD);
        std::fs::write(&path, &bytes).unwrap();
        bytes
    }

    fn saved_database(dir: &Path) {
        let daemon = start(dir);
        daemon.ok(json!({"cmd":"config_set","key":"drop_after_days","value":5}));
        daemon.stop();
    }

    fn drop_after_days(daemon: &TestDaemon) -> serde_json::Value {
        daemon.ok(json!({"cmd":"config_get","key":"drop_after_days"}))["value"].clone()
    }

    #[test]
    fn a_healthy_database_starts_with_its_side_files_gone() {
        let dir = tempfile::tempdir().unwrap();
        saved_database(dir.path());
        remove_side_files(dir.path());
        let daemon = start(dir.path());
        assert_eq!(daemon.subscribe("cli").snapshot()["db_unreadable"], false);
        assert_eq!(drop_after_days(&daemon), 5);
        daemon.stop();
    }

    #[test]
    fn a_healthy_database_starts_with_its_side_files_present() {
        let dir = tempfile::tempdir().unwrap();
        saved_database(dir.path());
        let daemon = start(dir.path());
        assert_eq!(drop_after_days(&daemon), 5);
        daemon.stop();
    }

    #[test]
    fn a_healthy_database_starts_with_only_an_empty_wal() {
        let dir = tempfile::tempdir().unwrap();
        saved_database(dir.path());
        remove_side_files(dir.path());
        std::fs::write(dir.path().join("state.db-wal"), b"").unwrap();
        let daemon = start(dir.path());
        assert_eq!(drop_after_days(&daemon), 5);
        daemon.stop();
    }

    #[test]
    fn a_healthy_database_ignores_a_wal_that_is_not_a_wal() {
        let dir = tempfile::tempdir().unwrap();
        saved_database(dir.path());
        remove_side_files(dir.path());
        std::fs::write(dir.path().join("state.db-wal"), b"old wal").unwrap();
        let daemon = start(dir.path());
        assert_eq!(drop_after_days(&daemon), 5);
        daemon.stop();
    }

    #[test]
    fn saved_state_survives_a_kill_with_side_files_in_place() {
        let dir = tempfile::tempdir().unwrap();
        let daemon = start(dir.path());
        daemon.ok(json!({"cmd":"config_set","key":"drop_after_days","value":5}));
        daemon.kill();
        let daemon = start(dir.path());
        assert_eq!(drop_after_days(&daemon), 5);
        daemon.stop();
    }

    #[test]
    #[cfg(feature = "dev-ingest")]
    fn a_damaged_database_waits_with_its_side_files_gone() {
        let dir = tempfile::tempdir().unwrap();
        saved_database(dir.path());
        remove_side_files(dir.path());
        let damaged = damage_pages(dir.path());
        let daemon = start(dir.path());
        assert_eq!(daemon.subscribe("cli").snapshot()["db_unreadable"], true);
        assert_eq!(daemon.code(json!({"cmd":"list"})), "internal");
        assert_eq!(std::fs::read(dir.path().join("state.db")).unwrap(), damaged);
        daemon.ok(json!({"cmd":"reset"}));
        assert_eq!(daemon.subscribe("cli").snapshot()["db_unreadable"], false);
        assert_eq!(drop_after_days(&daemon), 14, "an empty state");
        daemon.stop();
    }

    #[test]
    #[cfg(feature = "dev-ingest")]
    fn a_damaged_database_waits_with_its_side_files_present() {
        let dir = tempfile::tempdir().unwrap();
        saved_database(dir.path());
        let damaged = damage_pages(dir.path());
        let daemon = start(dir.path());
        assert_eq!(daemon.subscribe("cli").snapshot()["db_unreadable"], true);
        assert_eq!(std::fs::read(dir.path().join("state.db")).unwrap(), damaged);
        daemon.stop();
    }

    /// What a crash leaves: a WAL with committed content and no `-shm`.
    fn crash_image(source: &Path, target: &Path) {
        saved_database(source);
        let db = source.join("state.db");
        let conn = rusqlite::Connection::open(&db).unwrap();
        conn.query_row("PRAGMA wal_autocheckpoint=0", [], |_| Ok(()))
            .unwrap();
        conn.execute(
            "UPDATE config SET value = '6' WHERE key = 'drop_after_days'",
            [],
        )
        .unwrap();
        std::fs::copy(&db, target.join("state.db")).unwrap();
        std::fs::copy(source.join("state.db-wal"), target.join("state.db-wal")).unwrap();
        assert!(
            std::fs::metadata(target.join("state.db-wal"))
                .unwrap()
                .len()
                > 0
        );
    }

    #[test]
    fn a_crash_image_is_recovered_from_its_wal() {
        let source = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        crash_image(source.path(), target.path());
        let daemon = start(target.path());
        assert_eq!(drop_after_days(&daemon), 6, "the WAL content counts");
        daemon.stop();
    }

    /// A checkpoint torn by a crash: main file pages are ruined, and the WAL
    /// still has their good copies, so the database is healthy.
    #[test]
    fn a_torn_checkpoint_is_not_damage() {
        let source = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        crash_image(source.path(), target.path());
        let wal = std::fs::read(target.path().join("state.db-wal")).unwrap();
        let page_size = u32::from_be_bytes(wal[8..12].try_into().unwrap()) as usize;
        let path = target.path().join("state.db");
        let mut main = std::fs::read(&path).unwrap();
        let mut ruined = 0;
        for frame in wal[32..].chunks_exact(24 + page_size) {
            let page = u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize;
            if page > 1 {
                main[(page - 1) * page_size..page * page_size].fill(0xCD);
                ruined += 1;
            }
        }
        assert!(ruined > 0);
        std::fs::write(&path, &main).unwrap();
        let daemon = start(target.path());
        assert_eq!(daemon.subscribe("cli").snapshot()["db_unreadable"], false);
        assert_eq!(drop_after_days(&daemon), 6);
        daemon.stop();
    }

    #[test]
    #[cfg(feature = "dev-ingest")]
    fn a_damaged_database_with_a_full_wal_waits() {
        let source = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        crash_image(source.path(), target.path());
        let path = target.path().join("state.db");
        let damaged = vec![0xCD; std::fs::metadata(&path).unwrap().len() as usize];
        std::fs::write(&path, &damaged).unwrap();
        let daemon = start(target.path());
        assert_eq!(daemon.subscribe("cli").snapshot()["db_unreadable"], true);
        assert_eq!(std::fs::read(&path).unwrap(), damaged);
        daemon.stop();
    }

    #[test]
    #[cfg(feature = "dev-ingest")]
    fn a_state_directory_with_uri_characters_works() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("a b?c#d%e");
        saved_database(&state);
        remove_side_files(&state);
        let daemon = start(&state);
        assert_eq!(drop_after_days(&daemon), 5);
        daemon.stop();
        let damaged = damage_pages(&state);
        remove_side_files(&state);
        let daemon = start(&state);
        assert_eq!(daemon.subscribe("cli").snapshot()["db_unreadable"], true);
        assert_eq!(std::fs::read(state.join("state.db")).unwrap(), damaged);
        daemon.stop();
    }

    #[test]
    fn a_running_daemon_keeps_working_when_side_files_disappear() {
        let dir = tempfile::tempdir().unwrap();
        let daemon = start(dir.path());
        remove_side_files(dir.path());
        let mut cli = daemon.subscribe("cli");
        assert_eq!(cli.snapshot()["db_unreadable"], false);
        daemon.ok(json!({"cmd":"list"}));
        daemon.ok(json!({"cmd":"config_set","key":"drop_after_days","value":5}));
        daemon.stop();
        let daemon = start(dir.path());
        assert_eq!(
            drop_after_days(&daemon),
            5,
            "the change reached the main file"
        );
        daemon.stop();
    }

    #[test]
    #[cfg(feature = "dev-ingest")]
    fn a_running_daemon_notices_damage_when_side_files_disappear() {
        let dir = tempfile::tempdir().unwrap();
        let daemon = start(dir.path());
        daemon.ok(json!({"cmd":"config_set","key":"drop_after_days","value":5}));
        remove_side_files(dir.path());
        let damaged = damage_pages(dir.path());
        assert_eq!(daemon.code(json!({"cmd":"list"})), "internal");
        assert_eq!(std::fs::read(dir.path().join("state.db")).unwrap(), damaged);
        daemon.stop();
    }

    #[test]
    #[cfg(feature = "dev-ingest")]
    fn a_running_daemon_notices_damage_with_side_files_present() {
        let dir = tempfile::tempdir().unwrap();
        let daemon = start(dir.path());
        daemon.ok(json!({"cmd":"config_set","key":"drop_after_days","value":5}));
        let damaged = damage_pages(dir.path());
        assert_eq!(daemon.code(json!({"cmd":"list"})), "internal");
        assert_eq!(std::fs::read(dir.path().join("state.db")).unwrap(), damaged);
        daemon.stop();
    }
}
