//! Accounts and the Keychain over the socket: the one item, the two kinds of
//! read failure, the requests refused meanwhile, `token_reset`, and `reset`
//! bringing accounts back. DESIGN.md, "When the Keychain cannot be read",
//! "Saved state" and "Wire format". A file under the state directory stands
//! in for the Keychain; no GitHub is reached.
#![cfg(feature = "dev-ingest")]

mod common;

use common::*;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// A daemon whose test Keychain is `keychain` under the state directory.
fn start(dir: &Path, keychain: &Path) -> TestDaemon {
    let mut command = command(dir);
    command
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", keychain);
    TestDaemon::spawn(dir, command)
}

fn item(accounts: Value) -> String {
    json!({"version":2,"accounts":accounts}).to_string()
}

fn kinds(account: &Value) -> Vec<String> {
    account["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["kind"].as_str().unwrap().to_string())
        .collect()
}

fn keychain_path(dir: &Path) -> PathBuf {
    dir.join("keychain.json")
}

#[test]
fn an_empty_state_never_reads_the_keychain() {
    let dir = tempfile::tempdir().unwrap();
    // A path that cannot be read: any read would turn the state unavailable.
    let keychain = dir.path().join("keychain");
    std::fs::create_dir(&keychain).unwrap();
    let daemon = start(dir.path(), &keychain);
    assert_eq!(daemon.ok(json!({"cmd":"refresh"}))["warnings"], json!([]));
    daemon.clock(T0 + 600);
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["keychain"], "ok");
    // With an account the first fetch reads it.
    daemon.ok(json!({"cmd":"dev_account_add","id":ACCOUNT,"login":ME}));
    let warnings = daemon.ok(json!({"cmd":"refresh"}))["warnings"].clone();
    assert_eq!(warnings[0]["kind"], "keychain_unavailable", "{warnings}");
    daemon.stop();
}

#[test]
fn an_unavailable_keychain_warns_every_account_and_refuses_token_requests() {
    let dir = tempfile::tempdir().unwrap();
    let keychain = dir.path().join("keychain");
    std::fs::create_dir(&keychain).unwrap();
    let daemon = start(dir.path(), &keychain);
    daemon.setup_account();
    daemon.ok(json!({"cmd":"dev_account_add","id":"1002","login":"you"}));
    let mut cli = daemon.subscribe("cli");
    assert_eq!(cli.snapshot()["keychain"], "ok", "not read yet");
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(
        cli.until(|e| e["event"] == "keychain_changed"),
        json!({"event":"keychain_changed","keychain":"unavailable"})
    );
    for login in ["me", "you"] {
        let account = daemon.account(login);
        assert_eq!(
            account["warnings"][0],
            json!({"kind":"keychain_unavailable","account":null,"owner":null,
                   "message":"Couldn't read tokens from Keychain","until":null,"url":null}),
            "{login}"
        );
        assert!(
            !kinds(&account).contains(&"no_token".to_string()),
            "{login}"
        );
    }
    assert_eq!(
        daemon.subscribe("cli").snapshot()["keychain"],
        "unavailable"
    );

    for request in [
        json!({"cmd":"account_remove","account":"me"}),
        json!({"cmd":"token_set","account":"me","token":"t"}),
        json!({"cmd":"token_test","account":"me"}),
        json!({"cmd":"owner_add","account":"me","owner":"acme"}),
        json!({"cmd":"owner_lookup","account":"me","owner":"acme"}),
        json!({"cmd":"account_add","token":"t"}),
    ] {
        assert_eq!(
            daemon.code(request.clone()),
            "keychain_unavailable",
            "{request}"
        );
    }
    // A pasted token is tested without the Keychain; this build reaches no
    // GitHub, so it fails as unreachable, not as a Keychain refusal.
    assert_eq!(
        daemon.code(json!({"cmd":"token_test","token":"t"})),
        "unreachable"
    );
    // Owners that need no token keep working.
    daemon.ok(json!({"cmd":"owner_remove","account":"me","owner":"public"}));
    daemon.ok(json!({"cmd":"owner_add","account":"me","owner":"public"}));
    daemon.ok(json!({"cmd":"owner_disable","account":"me","owner":"org"}));
    daemon.ok(json!({"cmd":"owner_enable","account":"me","owner":"org"}));
    assert_eq!(daemon.accounts().len(), 2);
    daemon.stop();
}

#[test]
fn unreadable_tokens_and_token_reset() {
    let dir = tempfile::tempdir().unwrap();
    let keychain = keychain_path(dir.path());
    std::fs::write(&keychain, "not json").unwrap();
    let daemon = start(dir.path(), &keychain);
    daemon.setup_account();
    daemon.ingest(
        vec![pr("PR_1", "me")],
        vec![event("E_1", "PR_1", "comment", T0 + 1)],
        vec![],
    );
    let warnings = daemon.ok(json!({"cmd":"refresh"}))["warnings"].clone();
    assert_eq!(warnings[0]["kind"], "tokens_unreadable", "{warnings}");
    assert_eq!(warnings[0]["message"], "Saved tokens are unreadable");
    assert_eq!(warnings[0]["account"], Value::Null);
    let mut cli = daemon.subscribe("cli");
    assert_eq!(cli.snapshot()["keychain"], "unreadable");
    assert_eq!(
        daemon.code(json!({"cmd":"account_remove","account":"me"})),
        "keychain_unavailable"
    );

    daemon.ok(json!({"cmd":"token_reset"}));
    assert!(!keychain.exists(), "the item is deleted");
    assert_eq!(
        cli.until(|e| e["event"] == "keychain_changed"),
        json!({"event":"keychain_changed","keychain":"ok"})
    );
    let account = daemon.account("me");
    assert_eq!(kinds(&account), ["no_token"]);
    assert_eq!(account["token"]["registered"], false);
    assert_eq!(
        account["owners"].as_array().unwrap().len(),
        2,
        "owners stay"
    );
    assert!(daemon.card("PR_1").is_some(), "PRs stay");
    assert!(daemon.row("E_1").is_some(), "rows stay");
    daemon.stop();
}

#[test]
fn a_token_goes_into_the_one_item_and_comes_back_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let keychain = keychain_path(dir.path());
    let daemon = start(dir.path(), &keychain);
    daemon.ok(json!({"cmd":"dev_account_add","id":ACCOUNT,"login":ME,"token":"ghp_me"}));
    daemon.ok(json!({"cmd":"dev_account_add","id":"1002","login":"you","token":"ghp_you"}));
    let saved: Value = serde_json::from_str(&std::fs::read_to_string(&keychain).unwrap()).unwrap();
    assert_eq!(
        saved,
        json!({"version":2,"accounts":[
            {"id":"1001","login":"me","token":"ghp_me"},
            {"id":"1002","login":"you","token":"ghp_you"}]})
    );
    assert_eq!(mode(&keychain), 0o600);
    daemon.stop();

    let daemon = start(dir.path(), &keychain);
    assert_eq!(daemon.ok(json!({"cmd":"refresh"}))["warnings"], json!([]));
    assert_eq!(daemon.account("me")["token"]["registered"], true);

    // Removing an account takes its token out of the item.
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.ok(json!({"cmd":"account_remove","account":"YOU"}));
    assert_eq!(
        cli.until(|e| e["event"] == "account_removed"),
        json!({"event":"account_removed","id":"1002"})
    );
    let saved: Value = serde_json::from_str(&std::fs::read_to_string(&keychain).unwrap()).unwrap();
    assert_eq!(
        saved,
        json!({"version":2,"accounts":[{"id":"1001","login":"me","token":"ghp_me"}]})
    );
    daemon.stop();

    // Without the item, every account has no token and the Keychain is ok.
    std::fs::remove_file(&keychain).unwrap();
    let daemon = start(dir.path(), &keychain);
    let warnings = daemon.ok(json!({"cmd":"refresh"}))["warnings"].clone();
    let kinds: Vec<&str> = warnings
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["no_token"]);
    assert_eq!(daemon.subscribe("cli").snapshot()["keychain"], "ok");
    daemon.stop();
}

#[test]
fn refresh_reads_the_keychain_again() {
    let dir = tempfile::tempdir().unwrap();
    let keychain = keychain_path(dir.path());
    std::fs::create_dir(&keychain).unwrap();
    let daemon = start(dir.path(), &keychain);
    daemon.setup_account();
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.ok(json!({"cmd":"refresh"}));
    cli.until(|e| e["event"] == "keychain_changed" && e["keychain"] == "unavailable");
    // Nothing reads it again by itself.
    daemon.clock(T0 + 3600);
    assert_eq!(
        daemon.subscribe("cli").snapshot()["keychain"],
        "unavailable"
    );

    std::fs::remove_dir(&keychain).unwrap();
    std::fs::write(
        &keychain,
        item(json!([{"id":ACCOUNT,"login":ME,"token":"ghp_me"}])),
    )
    .unwrap();
    assert_eq!(daemon.ok(json!({"cmd":"refresh"}))["warnings"], json!([]));
    cli.until(|e| e["event"] == "keychain_changed" && e["keychain"] == "ok");
    assert_eq!(daemon.account("me")["token"]["registered"], true);
    daemon.stop();
}

#[test]
fn reset_brings_the_accounts_back_from_the_item_without_owners() {
    let dir = tempfile::tempdir().unwrap();
    let keychain = keychain_path(dir.path());
    std::fs::write(
        &keychain,
        item(json!([
            {"id":"1005","login":"work","token":"ghp_w"},
            {"id":ACCOUNT,"login":ME,"token":"ghp_me"}
        ])),
    )
    .unwrap();
    std::fs::write(dir.path().join("state.db"), vec![0xAB; 4096]).unwrap();
    let daemon = start(dir.path(), &keychain);
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], true);
    assert_eq!(
        snapshot["accounts"],
        json!([]),
        "no Keychain read while unreadable"
    );

    daemon.ok(json!({"cmd":"reset"}));
    assert!(daemon.accounts().is_empty(), "restored on the first fetch");
    daemon.clock(T0 + 1);
    let accounts = daemon.accounts();
    let restored: Vec<(&str, &str, bool, usize)> = accounts
        .iter()
        .map(|a| {
            (
                a["id"].as_str().unwrap(),
                a["login"].as_str().unwrap(),
                a["token"]["registered"].as_bool().unwrap(),
                a["owners"].as_array().unwrap().len(),
            )
        })
        .collect();
    assert_eq!(
        restored,
        [("1005", "work", true, 0), ("1001", "me", true, 0)]
    );
    assert_eq!(accounts[0]["color"], "none");
    assert_eq!(accounts[1]["color"], "red");
    // Restored once: a restart keeps them and adds none.
    daemon.stop();
    let daemon = start(dir.path(), &keychain);
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(daemon.accounts().len(), 2);
    daemon.stop();
}

/// `account_changed` follows every change of an owner, its table and its
/// Exclusions.
#[test]
fn owner_settings_send_account_changed() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &keychain_path(dir.path()));
    daemon.setup_account();
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    let steps = [
        json!({"cmd":"owner_notify","account":"me","owner":"org","on":false}),
        json!({"cmd":"owner_skip_drafts","account":"me","owner":"org","on":false}),
        json!({"cmd":"owner_disable","account":"me","owner":"org"}),
        json!({"cmd":"owner_remove","account":"me","owner":"public"}),
        json!({"cmd":"owner_add","account":"me","owner":"public"}),
        json!({"cmd":"account_color","account":"me","color":"blue"}),
    ];
    for step in steps {
        daemon.ok(step.clone());
        let event = cli.next().unwrap();
        assert_eq!(event["event"], "account_changed", "{step}");
        assert_eq!(event["account"]["id"], ACCOUNT, "{step}");
    }
    let account = daemon.account("me");
    assert_eq!(account["color"], "blue");
    assert_eq!(account["owners"][0]["notify"], false);
    assert_eq!(account["owners"][0]["skip_drafts"], false);
    assert_eq!(account["owners"][0]["enabled"], false);

    // The table and the Exclusions answer with their new values.
    let events = daemon.ok(
        json!({"cmd":"owner_events_set","account":"me","owner":"org",
        "event":"merged_closed","column":"notify","on":true}),
    )["events"]
        .clone();
    assert_eq!(events["merged_closed"], json!({"list":true,"notify":true}));
    assert_eq!(
        events["review_requested"],
        json!({"list":true,"notify":true})
    );
    assert_eq!(events.as_object().unwrap().len(), 16);
    let copied = daemon.ok(json!({"cmd":"owner_events_copy","account":"me",
        "from_owner":"org","to_owner":"public"}))["events"]
        .clone();
    assert_eq!(copied, events);
    let exclusions = daemon.ok(
        json!({"cmd":"owner_exclusions_set","account":"me","owner":"org",
        "kind":"user","name":"renovate","state":"list_only"}),
    )["exclusions"]
        .clone();
    assert_eq!(
        exclusions,
        json!({"repos":[],"users":[{"name":"renovate","state":"list_only"}]})
    );
    let exclusions = daemon.ok(
        json!({"cmd":"owner_exclusions_set","account":"me","owner":"org",
        "kind":"user","name":"Renovate","state":"hidden"}),
    )["exclusions"]
        .clone();
    assert_eq!(
        exclusions["users"],
        json!([{"name":"renovate","state":"hidden"}]),
        "the same user without case"
    );
    daemon.stop();
}

#[test]
fn a_failed_read_is_tried_again_by_refresh_only() {
    // Stage 5, 1-1: after a failed read, the next fetch cycle does not read
    // the item again; `refresh` does, once.
    let dir = tempfile::tempdir().unwrap();
    let keychain = keychain_path(dir.path());
    std::fs::create_dir(&keychain).unwrap();
    let daemon = start(dir.path(), &keychain);
    daemon.setup_account();
    daemon.clock(T0 + 60);
    assert_eq!(
        daemon.subscribe("cli").snapshot()["keychain"],
        "unavailable"
    );
    std::fs::remove_dir(&keychain).unwrap();
    std::fs::write(
        &keychain,
        item(json!([{"id":ACCOUNT,"login":ME,"token":"t1"}])),
    )
    .unwrap();
    daemon.clock(T0 + 600);
    daemon.clock(T0 + 1200);
    assert_eq!(
        daemon.subscribe("cli").snapshot()["keychain"],
        "unavailable",
        "a cycle does not read again"
    );
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(
        cli.until(|e| e["event"] == "keychain_changed"),
        json!({"event":"keychain_changed","keychain":"ok"})
    );
    assert!(daemon.account(ME)["token"]["registered"] == true);
    daemon.stop();
}
