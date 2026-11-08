//! The exact send queue boundary, on the daemon itself: over a socket the
//! writer task and the kernel buffer hide how many lines are really queued.

use serde_json::{Value, json};
use shiibar_gh_proto::paths::StateDir;
use shiibar_gh_proto::{ClientKind, Request};
use shiibar_ghd::clock::Clock;
use shiibar_ghd::daemon::{Daemon, SEND_QUEUE};
use tokio::sync::oneshot::error::TryRecvError;

/// Each flip changes the setting, so it queues exactly one `config_changed`.
fn queue_one(daemon: &mut Daemon, on: bool) {
    let value = json!({"cmd":"config_set","key":"launch_at_login","value":on});
    let request: Request = serde_json::from_value(value).unwrap();
    let response: Value = serde_json::from_str(&daemon.handle(request)).unwrap();
    assert_eq!(response["ok"], true, "{response}");
}

#[test]
fn a_queue_of_256_stays_and_the_257th_line_cuts_the_client() {
    assert_eq!(SEND_QUEUE, 256);
    let dir = tempfile::tempdir().unwrap();
    let mut daemon = Daemon::start(
        StateDir::new(dir.path()),
        Clock::system(),
        std::sync::Arc::new(shiibar_ghd::keychain::NoKeychain),
    )
    .unwrap();
    let mut subscribed = daemon.subscribe(ClientKind::Cli);
    assert_eq!(subscribed.rx.len(), 1, "the snapshot");

    for n in 1..SEND_QUEUE {
        queue_one(&mut daemon, n.is_multiple_of(2));
    }
    assert_eq!(subscribed.rx.len(), SEND_QUEUE);
    assert!(
        matches!(subscribed.kill.try_recv(), Err(TryRecvError::Empty)),
        "256 queued lines are kept"
    );

    queue_one(&mut daemon, SEND_QUEUE.is_multiple_of(2));
    assert_eq!(subscribed.rx.len(), SEND_QUEUE, "the 257th was not queued");
    assert!(
        matches!(subscribed.kill.try_recv(), Err(TryRecvError::Closed)),
        "the 257th line disconnects the client"
    );
}
