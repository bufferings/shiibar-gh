//! The default build has no test commands.
#![cfg(not(feature = "dev-ingest"))]

mod common;

use common::*;
use serde_json::json;

#[test]
fn the_default_build_rejects_the_test_commands_as_unknown() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::spawn(dir.path(), command(dir.path()));
    let ingest = json!({"cmd":"dev_ingest","ingest":{
        "viewer":"me","missing_pr_ids":[],"prs":[],"events":[],"reactions":[]
    }});
    assert_eq!(daemon.code(ingest), "invalid");
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
