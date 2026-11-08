//! The default build has no test commands.
#![cfg(not(feature = "dev-ingest"))]

mod common;

use common::*;
use serde_json::json;

#[test]
fn the_default_build_rejects_the_test_commands_as_unknown() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::spawn(dir.path(), command(dir.path()));
    let ingest = json!({"cmd":"dev_ingest","account":"me","ingest":{
        "missing_pr_ids":[],"prs":[],"events":[],"reactions":[]
    }});
    assert_eq!(daemon.code(ingest), "invalid");
    assert_eq!(
        daemon.code(json!({"cmd":"dev_account_add","id":"1001","login":"me"})),
        "invalid"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"dev_owner_add","account":"me","owner":"org","kind":"org"})),
        "invalid"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"dev_clock_set","now":1,"tz":"Asia/Tokyo"})),
        "invalid"
    );
    assert_eq!(daemon.code(json!({"cmd":"nope"})), "invalid");
}

#[test]
fn the_default_build_ignores_the_test_clock() {
    let dir = tempfile::tempdir().unwrap();
    let mut command = command(dir.path());
    command.env("SHIIBAR_GH_DEV_NOW", "1000");
    let daemon = TestDaemon::spawn(dir.path(), command);
    let started = daemon.ok(json!({"cmd":"info"}))["started_at"]
        .as_i64()
        .unwrap();
    assert!(started > 1000);
}

#[test]
fn an_empty_state_has_no_account_and_a_keychain_never_read() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::spawn(dir.path(), command(dir.path()));
    let mut sub = daemon.subscribe("cli");
    let snapshot = sub.snapshot();
    assert_eq!(snapshot["accounts"], json!([]));
    assert_eq!(snapshot["keychain"], "ok");
    assert_eq!(snapshot["db_unreadable"], false);
    // A refresh with no account fetches nothing and reads no Keychain.
    assert_eq!(daemon.ok(json!({"cmd":"refresh"}))["warnings"], json!([]));
    assert_eq!(
        daemon.code(json!({"cmd":"list","account":"me"})),
        "not_found"
    );
}
