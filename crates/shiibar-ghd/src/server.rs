//! The socket: startup sequence, accept loop, one request per connection, and
//! the long-lived `subscribe` connections.

use crate::clock::Clock;
use crate::daemon::{self, Daemon, Subscribed};
use crate::logging;
use anyhow::Context;
use shiibar_gh_proto::paths::StateDir;
use shiibar_gh_proto::{Request, codec};
use std::fs::{File, OpenOptions, TryLockError};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Notify;
use tokio::task::JoinSet;

const PROBE_TIMEOUT: Duration = Duration::from_millis(500);
/// DESIGN.md brief, "Files and constants".
const PERIODIC_PASS: Duration = Duration::from_secs(30);
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);

type Shared = Arc<Mutex<Daemon>>;

fn lock(daemon: &Shared) -> std::sync::MutexGuard<'_, Daemon> {
    daemon.lock().expect("daemon mutex poisoned")
}

fn ensure_dir(dir: &StateDir) -> anyhow::Result<()> {
    std::fs::create_dir_all(dir.root()).context("cannot create the state directory")?;
    std::fs::set_permissions(dir.root(), std::fs::Permissions::from_mode(0o700))
        .context("cannot set the state directory mode")
}

/// The exclusive lock lives as long as the returned file. The OS releases it
/// when the process dies, so a crash cannot leave it stuck.
fn acquire_lock(path: &Path) -> anyhow::Result<File> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(path)
        .context("cannot open the lock file")?;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))
        .context("cannot set the lock file mode")?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(TryLockError::WouldBlock) => anyhow::bail!("shiibar-ghd is already running"),
        Err(TryLockError::Error(e)) => Err(e).context("cannot take the lock"),
    }
}

/// Whether something answers `info` on this socket.
fn daemon_answers(path: &Path) -> bool {
    let Ok(mut stream) = std::os::unix::net::UnixStream::connect(path) else {
        return false;
    };
    let timed = stream.set_read_timeout(Some(PROBE_TIMEOUT)).is_ok()
        && stream.set_write_timeout(Some(PROBE_TIMEOUT)).is_ok();
    if !timed || stream.write_all(b"{\"cmd\":\"info\"}\n").is_err() {
        return false;
    }
    let mut response = String::new();
    matches!(BufReader::new(stream).read_line(&mut response), Ok(n) if n > 0)
}

fn clear_stale_socket(path: &Path) -> anyhow::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    anyhow::ensure!(!daemon_answers(path), "shiibar-ghd is already running");
    std::fs::remove_file(path).context("cannot remove the stale socket")
}

/// Run until a `shutdown` request.
pub async fn run(dir: StateDir, clock: Clock) -> anyhow::Result<()> {
    ensure_dir(&dir)?;
    let _lock = acquire_lock(&dir.lock())?;
    let socket = dir.socket();
    clear_stale_socket(&socket)?;
    let daemon: Shared = Arc::new(Mutex::new(Daemon::start(dir, clock)?));
    let listener = UnixListener::bind(&socket).context("cannot bind the socket")?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))
        .context("cannot set the socket mode")?;
    logging::info(format_args!("listening on {}", socket.display()));

    let shutdown = Arc::new(Notify::new());
    let mut connections = JoinSet::new();
    let start = tokio::time::Instant::now() + PERIODIC_PASS;
    let mut ticks = tokio::time::interval_at(start, PERIODIC_PASS);
    loop {
        tokio::select! {
            _ = shutdown.notified() => break,
            _ = ticks.tick() => lock(&daemon).tick(),
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _)) => {
                        connections.spawn(handle_connection(
                            stream,
                            daemon.clone(),
                            shutdown.clone(),
                        ));
                    }
                    Err(e) => logging::error(format_args!("accept failed: {e}")),
                }
            }
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    drop(listener);
    lock(&daemon).disconnect_all();
    // A write that finished before the shutdown still records its delivery.
    let drain = async { while connections.join_next().await.is_some() {} };
    let _ = tokio::time::timeout(SHUTDOWN_GRACE, drain).await;
    let _ = std::fs::remove_file(&socket);
    logging::info(format_args!("shut down"));
    Ok(())
}

async fn handle_connection(stream: UnixStream, daemon: Shared, shutdown: Arc<Notify>) {
    let (read, mut write) = stream.into_split();
    let mut reader = tokio::io::BufReader::new(read);
    let mut text = String::new();
    let request = match reader.read_line(&mut text).await {
        Ok(0) => return,
        Ok(_) => codec::decode_line::<Request>(&text).map_err(|e| e.to_string()),
        Err(e) => Err(e.to_string()),
    };
    let response = match request {
        Err(e) => daemon::invalid_line(e),
        Ok(Request::Subscribe { client }) => {
            let subscribed = lock(&daemon).subscribe(client);
            run_subscriber(reader, write, daemon, subscribed).await;
            return;
        }
        Ok(Request::Shutdown) => {
            let ack = shiibar_gh_proto::AckResponse::new();
            let text = codec::encode_line(&ack).unwrap_or_default();
            let _ = write.write_all(text.as_bytes()).await;
            shutdown.notify_one();
            return;
        }
        Ok(request) => lock(&daemon).handle(request),
    };
    let _ = write.write_all(response.as_bytes()).await;
}

async fn run_subscriber(
    mut reader: tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>,
    mut write: tokio::net::unix::OwnedWriteHalf,
    daemon: Shared,
    subscribed: Subscribed,
) {
    let Subscribed {
        id,
        mut rx,
        mut kill,
    } = subscribed;
    let mut discard = [0u8; 256];
    loop {
        tokio::select! {
            biased;
            _ = &mut kill => break,
            read = reader.read(&mut discard) => {
                // The connection is push-only, so input only signals a close.
                if !matches!(read, Ok(n) if n > 0) {
                    break;
                }
            }
            queued = rx.recv() => {
                let Some(outgoing) = queued else { break };
                let written = tokio::select! {
                    biased;
                    written = write.write_all(outgoing.line.as_bytes()) => written.is_ok(),
                    _ = &mut kill => {
                        lock(&daemon).connection_closed(id);
                        return;
                    }
                };
                if !written {
                    break;
                }
                if let Some(notification) = outgoing.ack {
                    lock(&daemon).delivered(&notification);
                }
            }
        }
    }
    lock(&daemon).connection_closed(id);
}
