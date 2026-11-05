//! The socket: startup sequence, accept loop, one request per connection, and
//! the long-lived `subscribe` connections.

use crate::clock::Clock;
use crate::daemon::{self, Daemon, Subscribed};
use crate::github::{Api, Recorder};
use crate::keychain::Keychain;
use crate::logging;
use anyhow::Context;
use shiibar_gh_proto::paths::StateDir;
use shiibar_gh_proto::{Request, codec};
use std::fs::{File, OpenOptions, TryLockError};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::SocketAddr;
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
/// How often the real-time scheduler looks for a due fetch. The intervals
/// themselves are minutes; this only bounds how late a fetch starts.
const FETCH_CHECK: Duration = Duration::from_secs(5);
/// No longer than the socket's own name: a Unix socket path has a small length
/// limit, and a state directory that fits the socket must fit the draft too.
const SOCKET_DRAFT: &str = "shiibar-ghd.new";

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

/// The draft name is shorter than the socket's, so a path past the limit would
/// bind, rename and leave a daemon no client can ever reach.
fn check_socket_path(path: &Path) -> anyhow::Result<()> {
    SocketAddr::from_pathname(path)
        .map(|_| ())
        .with_context(|| format!("the socket path is too long: {}", path.display()))
}

/// A socket takes its mode from the umask at bind time and accepts connections
/// from then on. Binding under another name and renaming it into place means
/// nobody can connect before the mode is 0600.
fn bind_socket(path: &Path) -> anyhow::Result<UnixListener> {
    let draft = path.with_file_name(SOCKET_DRAFT);
    match std::fs::remove_file(&draft) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e).context("cannot remove an unfinished socket"),
    }
    let listener = UnixListener::bind(&draft).context("cannot bind the socket")?;
    std::fs::set_permissions(&draft, std::fs::Permissions::from_mode(0o600))
        .context("cannot set the socket mode")?;
    std::fs::rename(&draft, path).context("cannot move the socket into place")?;
    Ok(listener)
}

/// Runs fetches one at a time: the schedule, `refresh`, `dev_clock_set` and
/// `token_test` all go through `running`.
pub struct Fetcher {
    daemon: Shared,
    /// `None` in a `dev-ingest` build without a test server: nothing is
    /// fetched.
    api: Option<Api>,
    running: tokio::sync::Mutex<()>,
}

impl Fetcher {
    /// One run of what is due, or of everything with `forced`.
    async fn cycle(&self, forced: bool, only_scope: Option<String>) {
        let Some(api) = &self.api else { return };
        let Some(plan) = lock(&self.daemon).fetch_plan(forced, only_scope) else {
            return;
        };
        let outcome = crate::fetch::run(api, &plan).await;
        lock(&self.daemon).apply_fetch(outcome);
    }

    /// Fetch whatever is due now.
    pub async fn run_due(&self) {
        let _running = self.running.lock().await;
        self.cycle(false, None).await;
    }

    /// DESIGN.md, "Wire format": `refresh` answers after the fetch and its
    /// changes are applied. One that arrives during a fetch waits for it.
    /// While fetching is stopped it answers at once with `rate_limited`.
    async fn refresh(&self, scope: Option<String>) -> String {
        let scope = match lock(&self.daemon).precheck(scope.as_deref()) {
            Ok(scope) => scope,
            Err(line) => return line,
        };
        if !lock(&self.daemon).stopped() {
            match self.running.try_lock() {
                Ok(_running) => self.cycle(true, scope.clone()).await,
                Err(_) => {
                    logging::debug(format_args!("refresh waits for the running fetch"));
                    drop(self.running.lock().await);
                }
            }
        }
        lock(&self.daemon).refresh_answer(scope.as_deref())
    }

    /// `scope_lookup`: `GET /users/{owner}` with the notifications token when
    /// one is registered, else without a token (docs/DESIGN.md, "CLI").
    /// Nothing is registered and nothing the answer says is stored.
    async fn scope_lookup(&self, owner: String) -> String {
        let token = match lock(&self.daemon).lookup_token(&owner) {
            Ok(token) => token,
            Err(line) => return line,
        };
        let Some(api) = &self.api else {
            return daemon::lookup_failed("this build does not reach GitHub");
        };
        let _running = self.running.lock().await;
        let now = lock(&self.daemon).now().at;
        let mut rec = Recorder::new(now, i64::MAX, Vec::new());
        let path = format!("/users/{owner}");
        let key = if token.is_empty() {
            ""
        } else {
            crate::model::NOTIFICATIONS
        };
        let answer = api.rest(&mut rec, key, &token, &path, None).await;
        daemon::lookup_answer(answer)
    }

    /// `token_test`: never logged, and the token never leaves this call.
    async fn token_test(&self, target: String, token: Option<String>) -> String {
        let mut target = match lock(&self.daemon).test_target(&target, token) {
            Ok(target) => target,
            Err(line) => return line,
        };
        let Some(api) = &self.api else {
            return daemon::test_failed("this build does not reach GitHub");
        };
        let _running = self.running.lock().await;
        let mut rec = Recorder::new(target.now, target.cost_cap, target.costs.clone());
        if let Some(classic) = target.classic.clone() {
            let found = api
                .rest(
                    &mut rec,
                    crate::model::NOTIFICATIONS,
                    &classic,
                    "/user",
                    None,
                )
                .await;
            target.viewer = found
                .ok()
                .and_then(|user| user.body["login"].as_str().map(str::to_string));
            if target.viewer.is_none() {
                target.classic = None;
            }
        }
        let report = crate::tokentest::Tester {
            api,
            rec: &mut rec,
            key: &target.key,
            token: &target.token,
            classic: target.team_token.as_deref(),
        }
        .run(&target.key, target.owner.as_deref())
        .await;
        lock(&self.daemon).test_done(&target, report, rec)
    }
}

/// The real-time schedule. A fixed clock never moves, so a `dev-ingest`
/// build with a fixed time fetches on `dev_clock_set` and `refresh` only.
async fn schedule(fetcher: Arc<Fetcher>) {
    let mut checks = tokio::time::interval(FETCH_CHECK);
    loop {
        checks.tick().await;
        if !lock(&fetcher.daemon).clock_fixed() {
            fetcher.run_due().await;
        }
    }
}

/// Run until a `shutdown` request.
pub async fn run(
    dir: StateDir,
    clock: Clock,
    keychain: Arc<dyn Keychain>,
    api: Option<Api>,
) -> anyhow::Result<()> {
    let socket = dir.socket();
    check_socket_path(&socket)?;
    ensure_dir(&dir)?;
    let _lock = acquire_lock(&dir.lock())?;
    clear_stale_socket(&socket)?;
    let daemon: Shared = Arc::new(Mutex::new(Daemon::start(dir, clock, keychain)?));
    let listener = bind_socket(&socket)?;
    logging::info(format_args!("listening on {}", socket.display()));

    let fetcher = Arc::new(Fetcher {
        daemon: daemon.clone(),
        api,
        running: tokio::sync::Mutex::new(()),
    });
    let scheduler = tokio::spawn(schedule(fetcher.clone()));
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
                            fetcher.clone(),
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
    scheduler.abort();
    lock(&daemon).disconnect_all();
    // A write that finished before the shutdown still records its delivery.
    let drain = async { while connections.join_next().await.is_some() {} };
    let _ = tokio::time::timeout(SHUTDOWN_GRACE, drain).await;
    let _ = std::fs::remove_file(&socket);
    logging::info(format_args!("shut down"));
    Ok(())
}

/// A line that may carry a token: its decode error never echoes it.
fn carries_token(text: &str) -> bool {
    text.contains("token_set") || text.contains("token_test")
}

async fn handle_connection(
    stream: UnixStream,
    daemon: Shared,
    fetcher: Arc<Fetcher>,
    shutdown: Arc<Notify>,
) {
    let (read, mut write) = stream.into_split();
    let mut reader = tokio::io::BufReader::new(read);
    let mut text = String::new();
    let request = match reader.read_line(&mut text).await {
        Ok(0) => return,
        Ok(_) => codec::decode_line::<Request>(&text).map_err(|e| {
            if carries_token(&text) {
                "malformed token request".to_string()
            } else {
                e.to_string()
            }
        }),
        Err(e) => Err(e.to_string()),
    };
    drop(text);
    let response = match request {
        Err(e) => daemon::invalid_line(e),
        Ok(Request::Refresh { scope }) => fetcher.refresh(scope).await,
        Ok(Request::TokenTest { target, token }) => fetcher.token_test(target, token).await,
        Ok(Request::ScopeLookup { owner }) => fetcher.scope_lookup(owner).await,
        #[cfg(feature = "dev-ingest")]
        Ok(request @ Request::DevClockSet { .. }) => {
            // The fetches due at the new time run before the answer.
            let response = lock(&daemon).handle(request);
            fetcher.run_due().await;
            response
        }
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
