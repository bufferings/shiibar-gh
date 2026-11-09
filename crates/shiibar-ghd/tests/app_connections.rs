//! The open state with several `app` connections, on the daemon itself: the
//! order of the disconnects has to be exact, and over a socket a close only
//! reaches the daemon at some later point.
#![cfg(feature = "dev-ingest")]

use serde_json::{Value, json};
use shiibar_gh_proto::paths::StateDir;
use shiibar_gh_proto::{ClientKind, Request};
use shiibar_ghd::clock::{Clock, Now};
use shiibar_ghd::daemon::Daemon;

const T0: i64 = 1_800_000_000;

fn request(daemon: &mut Daemon, value: Value) -> Value {
    let request: Request = serde_json::from_value(value).unwrap();
    let response: Value = serde_json::from_str(&daemon.handle(request)).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response
}

fn row(daemon: &mut Daemon, id: &str) {
    let pr = json!({
        "id":"PR_1","owner":"stranger","repo":"app","number":1,"url":"https://github.example/1",
        "title":"T","author":"me","base":"main","head":"topic","state":"open","is_draft":false,
        "review":"none","checks":"none","base_status":"none","mergeable":false,
        "failed_check":null,"changes_requested_by":null,"updated_at":T0,"created_at":T0 - 100,"is_private":false,
        "requested_me":false,"assignees":[],"links":{"review":"r","checks":"c","base":"b"}
    });
    let event = json!({"id":id,"pr_id":"PR_1","kind":"merged","occurred_at":T0 + 1,"url":"u",
                       "actor":null,"text":null,"comment_id":null});
    request(
        daemon,
        json!({"cmd":"dev_ingest","account":"me","ingest":{
            "missing_pr_ids":[],"prs":[pr],"events":[event],"reactions":[]
        }}),
    );
}

/// The account `me` with Public, which the PR of `row` belongs to.
fn setup(daemon: &mut Daemon) {
    request(
        daemon,
        json!({"cmd":"dev_account_add","id":"1001","login":"me"}),
    );
    request(
        daemon,
        json!({"cmd":"dev_owner_add","account":"me","owner":"public","kind":"public"}),
    );
}

fn dot(daemon: &mut Daemon) -> Value {
    request(daemon, json!({"cmd":"account_list"}))["accounts"][0]["unread"].clone()
}

#[test]
fn the_open_state_lasts_until_the_last_app_connection_drops() {
    let dir = tempfile::tempdir().unwrap();
    let mut clock = Clock::system();
    clock.fix(Now::fixed(T0, "Asia/Tokyo").unwrap());
    let mut daemon = Daemon::start(
        StateDir::new(dir.path()),
        clock,
        std::sync::Arc::new(shiibar_ghd::keychain::NoKeychain),
    )
    .unwrap();
    setup(&mut daemon);
    let first = daemon.subscribe(ClientKind::App);
    let second = daemon.subscribe(ClientKind::App);
    request(&mut daemon, json!({"cmd":"popover_opened","account":"me"}));

    daemon.connection_closed(first.id);
    row(&mut daemon, "E_1");
    assert_eq!(dot(&mut daemon), false, "one app connection remains");

    daemon.connection_closed(second.id);
    row(&mut daemon, "E_2");
    assert_eq!(dot(&mut daemon), true, "the last one dropped");
}

#[test]
fn a_cli_connection_does_not_end_the_open_state() {
    let dir = tempfile::tempdir().unwrap();
    let mut clock = Clock::system();
    clock.fix(Now::fixed(T0, "Asia/Tokyo").unwrap());
    let mut daemon = Daemon::start(
        StateDir::new(dir.path()),
        clock,
        std::sync::Arc::new(shiibar_ghd::keychain::NoKeychain),
    )
    .unwrap();
    setup(&mut daemon);
    let cli = daemon.subscribe(ClientKind::Cli);
    let _app = daemon.subscribe(ClientKind::App);
    request(&mut daemon, json!({"cmd":"popover_opened","account":"me"}));
    daemon.connection_closed(cli.id);
    row(&mut daemon, "E_1");
    assert_eq!(dot(&mut daemon), false);
}
