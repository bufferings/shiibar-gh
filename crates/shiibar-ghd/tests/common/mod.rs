//! Black-box harness: the real daemon binary on a temporary state directory,
//! driven over its socket. Readiness means a successful connection, because
//! the socket file appears before the daemon listens.
#![allow(dead_code)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

pub const T0: i64 = 1_800_000_000;
pub const DAY: i64 = 86_400;
pub const TZ: &str = "Asia/Tokyo";
/// 09:00 in Tokyo the day after `T0`.
pub const NEXT_0900: i64 = T0 + 16 * 3600;
/// The bound on every wait in the harness: past it a test fails, it never
/// hangs.
pub const WAIT: Duration = Duration::from_secs(30);
/// The account the harness sets up, and its login.
pub const ACCOUNT: &str = "1001";
pub const ME: &str = "me";

/// The full id of a node of `me`: `1001:<id>`.
pub fn rid(id: &str) -> String {
    format!("{ACCOUNT}:{id}")
}

/// Wait for a process, killing it and failing the test past the limit.
pub fn wait_within(child: &mut Child, limit: Duration, what: &str) -> ExitStatus {
    let deadline = Instant::now() + limit;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("{what} did not exit within {limit:?}");
        }
        std::thread::yield_now();
    }
}

/// The exit code of a process that has to end by itself.
pub fn exit_code(mut command: Command) -> i32 {
    let mut child = command
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    wait_within(&mut child, WAIT, "the command").code().unwrap()
}

fn timed(stream: &UnixStream) {
    stream.set_read_timeout(Some(WAIT)).unwrap();
    stream.set_write_timeout(Some(WAIT)).unwrap();
}

pub fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_shiibar-ghd")
}

pub fn command(dir: &Path) -> Command {
    let mut command = Command::new(binary());
    command
        .arg("--foreground")
        .env("SHIIBAR_GH_STATE_DIR", dir)
        .env("SHIIBAR_GH_LOG", "error")
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

pub struct TestDaemon {
    pub dir: PathBuf,
    child: Child,
}

impl TestDaemon {
    /// Fixed at `T0` in Tokyo unless `env` overrides it.
    pub fn start(dir: &Path) -> Self {
        Self::start_at(dir, T0)
    }

    pub fn start_at(dir: &Path, now: i64) -> Self {
        let mut command = command(dir);
        command
            .env("SHIIBAR_GH_DEV_NOW", now.to_string())
            .env("SHIIBAR_GH_DEV_TZ", TZ);
        Self::spawn(dir, command)
    }

    pub fn spawn(dir: &Path, mut command: Command) -> Self {
        let child = command.spawn().expect("spawn shiibar-ghd");
        let mut daemon = Self {
            dir: dir.to_path_buf(),
            child,
        };
        daemon.wait_ready();
        daemon
    }

    fn wait_ready(&mut self) {
        let deadline = Instant::now() + WAIT;
        while !self.answers() {
            if let Some(status) = self.child.try_wait().unwrap() {
                panic!("the daemon exited during startup: {status}");
            }
            assert!(Instant::now() < deadline, "the daemon never accepted");
            std::thread::yield_now();
        }
    }

    /// A full round trip: a stale socket file can briefly accept a connection
    /// while a process forked by a parallel test still holds its listener.
    fn answers(&self) -> bool {
        let Ok(mut stream) = UnixStream::connect(self.socket()) else {
            return false;
        };
        timed(&stream);
        if stream.write_all(b"{\"cmd\":\"info\"}\n").is_err() {
            return false;
        }
        let mut text = String::new();
        matches!(BufReader::new(stream).read_line(&mut text), Ok(n) if n > 0)
    }

    pub fn socket(&self) -> PathBuf {
        self.dir.join("shiibar-ghd.sock")
    }

    pub fn raw(&self, line: &str) -> Value {
        let mut stream = UnixStream::connect(self.socket()).unwrap();
        timed(&stream);
        stream.write_all(line.as_bytes()).unwrap();
        stream.write_all(b"\n").unwrap();
        let mut text = String::new();
        BufReader::new(stream).read_line(&mut text).unwrap();
        serde_json::from_str(&text).unwrap_or_else(|e| panic!("bad response {text:?}: {e}"))
    }

    pub fn request(&self, value: Value) -> Value {
        self.raw(&value.to_string())
    }

    /// A request that must succeed.
    pub fn ok(&self, value: Value) -> Value {
        let response = self.request(value.clone());
        assert_eq!(response["ok"], true, "{value} -> {response}");
        response
    }

    pub fn code(&self, value: Value) -> String {
        let response = self.request(value.clone());
        assert_eq!(response["ok"], false, "{value} -> {response}");
        response["code"].as_str().unwrap().to_string()
    }

    /// The account `me` (id `1001`) with its `org` owner and Public, made
    /// without GitHub (`dev-ingest`).
    pub fn setup_account(&self) {
        self.ok(json!({"cmd":"dev_account_add","id":ACCOUNT,"login":ME}));
        self.ok(
            json!({"cmd":"dev_owner_add","account":ME,"owner":"org","kind":"org","github_id":100}),
        );
        self.ok(json!({"cmd":"dev_owner_add","account":ME,"owner":"public","kind":"public"}));
    }

    pub fn ingest(&self, prs: Vec<Value>, events: Vec<Value>, reactions: Vec<Value>) {
        self.ingest_to(ME, prs, events, reactions);
    }

    pub fn ingest_to(
        &self,
        account: &str,
        prs: Vec<Value>,
        events: Vec<Value>,
        reactions: Vec<Value>,
    ) {
        self.ok(json!({"cmd":"dev_ingest","account":account,"ingest":{
            "missing_pr_ids":[],"prs":prs,"events":events,"reactions":reactions
        }}));
    }

    pub fn clock(&self, now: i64) {
        self.clock_in(now, TZ);
    }

    pub fn clock_in(&self, now: i64, tz: &str) {
        self.ok(json!({"cmd":"dev_clock_set","now":now,"tz":tz}));
    }

    pub fn accounts(&self) -> Vec<Value> {
        self.ok(json!({"cmd":"account_list"}))["accounts"]
            .as_array()
            .unwrap()
            .clone()
    }

    pub fn account(&self, login: &str) -> Value {
        self.accounts()
            .into_iter()
            .find(|a| a["login"] == login)
            .unwrap_or_else(|| panic!("no account {login}"))
    }

    pub fn owner(&self, login: &str, name: &str) -> Value {
        self.account(login)["owners"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["name"].as_str().unwrap().eq_ignore_ascii_case(name))
            .cloned()
            .unwrap_or_else(|| panic!("no owner {name}"))
    }

    /// Every card: the owner sections, then the Snoozed section.
    pub fn cards(&self) -> Vec<Value> {
        let mut cards = self.ok(json!({"cmd":"list"}))["cards"]
            .as_array()
            .unwrap()
            .clone();
        cards.extend(
            self.ok(json!({"cmd":"list","snoozed":true}))["cards"]
                .as_array()
                .unwrap()
                .clone(),
        );
        cards
    }

    /// A card by the short PR id of `me`.
    pub fn card(&self, id: &str) -> Option<Value> {
        let id = rid(id);
        self.cards().into_iter().find(|c| c["id"] == id)
    }

    /// A row by the short event id of `me`, on any card.
    pub fn row(&self, id: &str) -> Option<Value> {
        let id = rid(id);
        self.cards()
            .iter()
            .flat_map(|c| c["rows"].as_array().unwrap().clone())
            .find(|r| r["id"] == id)
    }

    pub fn subscribe(&self, client: &str) -> Subscriber {
        let mut stream = UnixStream::connect(self.socket()).unwrap();
        timed(&stream);
        let line = format!("{}\n", json!({"cmd":"subscribe","client":client}));
        stream.write_all(line.as_bytes()).unwrap();
        Subscriber {
            reader: BufReader::new(stream),
        }
    }

    /// Ask the daemon to stop and wait for the process to end.
    pub fn stop(mut self) {
        self.ok(json!({"cmd":"shutdown"}));
        wait_within(&mut self.child, WAIT, "the daemon");
    }

    pub fn kill(mut self) {
        self.child.kill().unwrap();
        wait_within(&mut self.child, WAIT, "the killed daemon");
    }
}

impl Drop for TestDaemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub struct Subscriber {
    reader: BufReader<UnixStream>,
}

impl Subscriber {
    /// The next event, or `None` once the daemon closed the connection. A
    /// missing event fails the test instead of hanging it.
    pub fn next(&mut self) -> Option<Value> {
        let mut text = String::new();
        match self.reader.read_line(&mut text) {
            Ok(0) => None,
            // A connection cut in the middle of a write ends without a newline.
            Ok(_) if !text.ends_with('\n') => None,
            Ok(_) => Some(serde_json::from_str(&text).unwrap()),
            Err(e) if e.kind() == ErrorKind::ConnectionReset => None,
            Err(e) => panic!("no event in time: {e}"),
        }
    }

    pub fn snapshot(&mut self) -> Value {
        let event = self.next().expect("a snapshot");
        assert_eq!(event["event"], "snapshot", "{event}");
        event
    }

    /// Skip events until one matches.
    pub fn until(&mut self, what: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
        loop {
            assert!(Instant::now() < deadline, "no matching event in time");
            let event = self.next().expect("the wanted event before the close");
            if what(&event) {
                return event;
            }
        }
    }

    /// Skip events until one matches, failing the test if none comes
    /// within `limit`.
    pub fn until_within(&mut self, limit: Duration, what: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + limit;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "no matching event within {limit:?}");
            self.reader.get_ref().set_read_timeout(Some(left)).unwrap();
            let mut text = String::new();
            let read = self.reader.read_line(&mut text);
            self.reader.get_ref().set_read_timeout(Some(WAIT)).unwrap();
            match read {
                Ok(n) if n > 0 && text.ends_with('\n') => {
                    let event: Value = serde_json::from_str(&text).unwrap();
                    if what(&event) {
                        return event;
                    }
                }
                Ok(_) => panic!("the connection closed before the wanted event"),
                Err(e) => panic!("no matching event within {limit:?}: {e}"),
            }
        }
    }

    pub fn notification(&mut self) -> Value {
        let event = self.until(|e| e["event"] == "notify");
        event["notification"].clone()
    }

    /// Everything until the daemon closes the connection.
    pub fn until_closed(&mut self) -> Vec<Value> {
        let deadline = Instant::now() + WAIT;
        let mut events = Vec::new();
        while let Some(event) = self.next() {
            assert!(Instant::now() < deadline, "the connection stayed open");
            events.push(event);
        }
        events
    }

    pub fn close(self) {}
}

pub fn pr(id: &str, author: &str) -> Value {
    let number: u64 = id.rsplit('_').next().unwrap().parse().unwrap();
    json!({
        "id": id, "owner": "org", "repo": "app", "number": number,
        "url": format!("https://github.example/{id}"),
        "title": format!("Title {id}"), "author": author, "base": "main", "head": "topic",
        "state": "open", "is_draft": false, "review": "none", "checks": "none",
        "base_status": "none", "mergeable": false, "failed_check": null,
        "changes_requested_by": null, "updated_at": T0, "created_at": T0 - 86_400, "is_private": false,
        "requested_me": false,
        "links": {
            "review": format!("https://github.example/{id}/r"),
            "checks": format!("https://github.example/{id}/c"),
            "base": format!("https://github.example/{id}/b"),
        }
    })
}

pub fn with(mut value: Value, patch: Value) -> Value {
    for (key, field) in patch.as_object().unwrap() {
        value[key] = field.clone();
    }
    value
}

pub fn event(id: &str, pr_id: &str, kind: &str, at: i64) -> Value {
    json!({
        "id": id, "pr_id": pr_id, "kind": kind, "occurred_at": at,
        "url": format!("https://github.example/{id}"), "actor": "alice",
        "text": format!("text {id}"), "comment_id": null
    })
}

pub fn reaction(comment: &str, pr_id: &str, created_at: i64, counts: Value) -> Value {
    json!({
        "comment_id": comment, "pr_id": pr_id, "url": format!("https://github.example/{comment}"),
        "text": "my comment", "comment_created_at": created_at, "counts": counts, "watching": true
    })
}

/// Epoch seconds of `2027-03-14 03:30 -0400`.
pub fn epoch(text: &str) -> i64 {
    jiff::Timestamp::strptime("%Y-%m-%d %H:%M %z", text)
        .unwrap()
        .as_second()
}

pub fn mode(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}
