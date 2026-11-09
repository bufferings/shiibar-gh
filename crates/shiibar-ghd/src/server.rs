//! The socket: startup sequence, accept loop, one request per connection, and
//! the long-lived `subscribe` connections.

use crate::clock::Clock;
use crate::daemon::{self, Daemon, Subscribed};
use crate::engine::CmdError;
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
/// How often the real-time scheduler looks for a due fetch. Due times are
/// whole seconds, and a failed run is retried after as little as five
/// seconds (DESIGN.md, "Constants"), so a fetch starts at most about a
/// second late. A check with nothing due only reads the core's timers.
const FETCH_CHECK: Duration = Duration::from_secs(1);
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

/// Runs fetches one at a time: the schedule, `refresh`, `dev_clock_set`,
/// `token_test` and the token checks all go through `running`.
pub struct Fetcher {
    daemon: Shared,
    /// `None` in a `dev-ingest` build without a test server: nothing is
    /// fetched.
    api: Option<Api>,
    running: tokio::sync::Mutex<()>,
}

impl Fetcher {
    /// One run of what is due, or of everything with `forced`, account by
    /// account. The first run reads the Keychain.
    async fn cycle(&self, forced: bool, only: Option<String>) {
        lock(&self.daemon).load_tokens();
        let Some(api) = &self.api else { return };
        let plans = lock(&self.daemon).fetch_plans(forced, only.as_deref());
        for plan in plans {
            let outcome = crate::fetch::run(api, &plan).await;
            lock(&self.daemon).apply_fetch(&plan.account, outcome);
        }
    }

    /// Fetch whatever is due now.
    pub async fn run_due(&self) {
        let _running = self.running.lock().await;
        self.cycle(false, None).await;
    }

    /// DESIGN.md, "Wire format": `refresh` answers after the fetch and its
    /// changes are applied; one that arrives during a fetch waits for it.
    /// While the Keychain could not be read it reads it again first.
    async fn refresh(&self, account: Option<String>) -> String {
        let account = match lock(&self.daemon).precheck(account.as_deref()) {
            Ok(account) => account,
            Err(line) => return line,
        };
        match self.running.try_lock() {
            Ok(_running) => {
                lock(&self.daemon).reload_tokens();
                self.cycle(true, account.clone()).await;
            }
            Err(_) => {
                logging::debug(format_args!("refresh waits for the running fetch"));
                drop(self.running.lock().await);
            }
        }
        lock(&self.daemon).refresh_answer(account.as_deref())
    }

    /// `viewer { databaseId login }` of a token, for `account_add` and
    /// `token_set`.
    async fn owner_of_token(&self, token: &str) -> Result<(String, String), String> {
        let Some(api) = &self.api else {
            return Err(daemon::error_of(CmdError::Unreachable(
                "Couldn't reach GitHub".into(),
            )));
        };
        let now = lock(&self.daemon).now().at;
        let mut rec = Recorder::new(now);
        crate::tokentest::viewer(api, &mut rec, token)
            .await
            .map_err(|e| daemon::error_of(daemon::call_error(&e)))
    }

    /// `account_add`: the token's owner becomes the account. Never logged.
    async fn account_add(&self, token: String) -> (String, Option<String>) {
        let token = token.trim().to_string();
        if token.is_empty() {
            return (
                daemon::error_of(CmdError::Invalid("the token is empty".into())),
                None,
            );
        }
        if let Err(line) = lock(&self.daemon).account_add_check() {
            return (line, None);
        }
        let _running = self.running.lock().await;
        let (id, login) = match self.owner_of_token(&token).await {
            Ok(found) => found,
            Err(line) => return (line, None),
        };
        match lock(&self.daemon).account_add_finish(&id, &login, &token) {
            Ok(line) => (line, Some(id)),
            Err(line) => (line, None),
        }
    }

    /// `token_set`: saved only when the token belongs to the account.
    async fn token_set(&self, account: String, token: String) -> (String, Option<String>) {
        let token = token.trim().to_string();
        if token.is_empty() {
            return (
                daemon::error_of(CmdError::Invalid("the token is empty".into())),
                None,
            );
        }
        let id = match lock(&self.daemon).token_set_check(&account) {
            Ok(id) => id,
            Err(line) => return (line, None),
        };
        let _running = self.running.lock().await;
        let (owner, login) = match self.owner_of_token(&token).await {
            Ok(found) => found,
            Err(line) => return (line, None),
        };
        match lock(&self.daemon).token_set_finish(&id, &owner, &login, &token) {
            Ok(line) => (line, Some(id)),
            Err(line) => (line, None),
        }
    }

    /// `token_test`: never logged, and the token never leaves this call.
    async fn token_test(&self, account: Option<String>, token: Option<String>) -> String {
        let target = match lock(&self.daemon).test_target(account.as_deref(), token) {
            Ok(target) => target,
            Err(line) => return line,
        };
        let Some(api) = &self.api else {
            return daemon::error_of(CmdError::Unreachable("Couldn't reach GitHub".into()));
        };
        let _running = self.running.lock().await;
        let mut rec = Recorder::new(target.now);
        let report =
            crate::tokentest::run(api, &mut rec, &target.token, &target.expect, &target.owners)
                .await;
        lock(&self.daemon).test_done(&target, report, rec)
    }

    /// After `account_add` or `token_set`: the same checks as `token test`
    /// on the saved token, recorded as its last test (DESIGN.md, "Add
    /// account… and Edit… sheets").
    async fn test_saved(&self, account: String) {
        let login = lock(&self.daemon)
            .account_login(&account)
            .unwrap_or_default();
        let _ = self.token_test(Some(login), None).await;
    }

    /// `owner_lookup` and `owner_add`: `GET /users/{owner}` with the
    /// account's token, else without a token.
    async fn lookup(&self, account: String, owner: String, adding: bool) -> String {
        let (id, token) = match lock(&self.daemon).lookup_target(&account, &owner, adding) {
            Ok(found) => found,
            Err(line) => return line,
        };
        let Some(api) = &self.api else {
            return daemon::error_of(CmdError::Unreachable("Couldn't reach GitHub".into()));
        };
        let _running = self.running.lock().await;
        let now = lock(&self.daemon).now().at;
        let mut rec = Recorder::new(now);
        let path = format!("/users/{owner}");
        let answer = api.rest(&mut rec, &token, &path, None).await;
        match daemon::lookup_answer(answer) {
            Ok(found) if adding => lock(&self.daemon).owner_add_finish(&id, found),
            Ok(found) => daemon::lookup_line(&found),
            Err(e) => daemon::error_of(e),
        }
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
    text.contains("token")
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
    let mut saved = None;
    let response = match request {
        Err(e) => daemon::invalid_line(e),
        Ok(Request::Refresh { account }) => fetcher.refresh(account).await,
        Ok(Request::TokenTest { account, token }) => fetcher.token_test(account, token).await,
        Ok(Request::AccountAdd { token }) => {
            let (line, id) = fetcher.account_add(token).await;
            saved = id;
            line
        }
        Ok(Request::TokenSet { account, token }) => {
            let (line, id) = fetcher.token_set(account, token).await;
            saved = id;
            line
        }
        Ok(Request::OwnerLookup { account, owner }) => fetcher.lookup(account, owner, false).await,
        Ok(Request::OwnerAdd { account, owner })
            if !owner.eq_ignore_ascii_case(crate::model::PUBLIC) =>
        {
            fetcher.lookup(account, owner, true).await
        }
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
    drop(write);
    // The saved token is tested after the answer; the app shows Checking…
    // until `account_changed` brings the new `last_test`.
    if let Some(account) = saved {
        fetcher.test_saved(account).await;
    }
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
