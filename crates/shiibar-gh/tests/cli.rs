//! Black-box CLI tests: real `shiibar-gh` subprocesses against a real daemon on
//! a temporary state directory.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// `shiibar-ghd` belongs to another package, so Cargo gives no env var for it.
/// Both binaries land in the same directory.
fn daemon_binary() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_BIN_EXE_shiibar-gh"));
    let dir = dir.parent().expect("a parent directory").to_path_buf();
    let binary = dir.join("shiibar-ghd");
    if !binary.exists() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let status = Command::new(env!("CARGO"))
            .args(["build", "-p", "shiibar-ghd", "--bin", "shiibar-ghd"])
            .current_dir(root)
            .status()
            .expect("run cargo");
        assert!(status.success());
    }
    binary
}

struct Daemon {
    dir: tempfile::TempDir,
    child: Child,
}

impl Daemon {
    fn start() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let mut command = Command::new(daemon_binary());
        command
            .arg("--foreground")
            .env("SHIIBAR_GH_STATE_DIR", dir.path())
            .env("SHIIBAR_GH_LOG", "error")
            .env("SHIIBAR_GH_DEV_NOW", "1800000000")
            .env("SHIIBAR_GH_DEV_TZ", "Asia/Tokyo")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let child = command.spawn().unwrap();
        let socket = dir.path().join("shiibar-ghd.sock");
        let deadline = Instant::now() + Duration::from_secs(10);
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "the daemon never accepted");
            std::thread::yield_now();
        }
        Self { dir, child }
    }

    fn cli(&self, args: &[&str]) -> Run {
        run(self.dir.path(), args)
    }

    fn send(&self, value: Value) -> Value {
        let mut stream = UnixStream::connect(self.dir.path().join("shiibar-ghd.sock")).unwrap();
        stream.write_all(format!("{value}\n").as_bytes()).unwrap();
        let mut text = String::new();
        BufReader::new(stream).read_line(&mut text).unwrap();
        serde_json::from_str(&text).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct Run {
    code: i32,
    stdout: String,
    stderr: String,
}

fn run(state_dir: &Path, args: &[&str]) -> Run {
    let output = Command::new(env!("CARGO_BIN_EXE_shiibar-gh"))
        .args(args)
        .env("SHIIBAR_GH_STATE_DIR", state_dir)
        .output()
        .unwrap();
    Run {
        code: output.status.code().unwrap(),
        stdout: String::from_utf8(output.stdout).unwrap(),
        stderr: String::from_utf8(output.stderr).unwrap(),
    }
}

#[test]
fn every_command_has_help_with_exit_0_and_needs_no_daemon() {
    let dir = tempfile::tempdir().unwrap();
    let commands: [&[&str]; 20] = [
        &["--help"],
        &["list", "--help"],
        &["status", "--help"],
        &["activity", "--help"],
        &["done", "--help"],
        &["undone", "--help"],
        &["snooze", "--help"],
        &["unsnooze", "--help"],
        &["refresh", "--help"],
        &["open", "--help"],
        &["config", "get", "--help"],
        &["config", "set", "--help"],
        &["reset", "--help"],
        &["scope", "list", "--help"],
        &["scope", "add", "--help"],
        &["scope", "remove", "--help"],
        &["scope", "enable", "--help"],
        &["scope", "disable", "--help"],
        &["scope", "notify", "--help"],
        &["scope", "--help"],
    ];
    for args in commands {
        let result = run(dir.path(), args);
        assert_eq!(result.code, 0, "{args:?}");
        assert!(result.stdout.contains("usage"), "{args:?}");
    }
}

#[test]
fn usage_errors_exit_1() {
    let dir = tempfile::tempdir().unwrap();
    let cases: [&[&str]; 13] = [
        &[],
        &["nope"],
        &["token", "set", "notifications"],
        &["list", "--mine", "--others"],
        &["list", "--bogus"],
        &["list", "extra"],
        &["list", "--scope"],
        &["done"],
        &["done", "a", "b"],
        &["status"],
        &["config", "get"],
        &["scope", "notify", "public", "maybe"],
        &["scope"],
    ];
    for args in cases {
        assert_eq!(run(dir.path(), args).code, 1, "{args:?}");
    }
}

#[test]
fn no_daemon_exits_1() {
    let dir = tempfile::tempdir().unwrap();
    let result = run(dir.path(), &["list"]);
    assert_eq!(result.code, 1);
    assert!(
        result.stderr.contains("cannot connect"),
        "{}",
        result.stderr
    );
}

#[test]
fn exit_codes_without_injected_events() {
    let daemon = Daemon::start();
    let cases: [(&[&str], i32); 14] = [
        (&["list"], 0),
        (&["activity"], 0),
        (&["refresh"], 0),
        (&["scope", "list"], 0),
        (&["scope", "add", "org"], 0),
        (&["config", "get", "notify_state"], 0),
        (&["config", "set", "notify_state", "false"], 0),
        (&["done", "nope"], 2),
        (&["status", "a/b#1"], 2),
        (&["open", "a/b#1"], 2),
        (&["list", "--scope", "nobody"], 2),
        (&["scope", "add", "public"], 1),
        (&["config", "set", "notify_state", "maybe"], 1),
        (&["reset"], 1),
    ];
    for (args, code) in cases {
        let result = daemon.cli(args);
        assert_eq!(result.code, code, "{args:?}: {}", result.stderr);
    }
    let cases: [(&[&str], i32); 5] = [
        (&["scope", "remove", "nobody"], 2),
        (&["scope", "remove", "public"], 1),
        (&["scope", "add", "org"], 1),
        (&["config", "get", "nope"], 1),
        (&["scope", "enable", "nobody"], 2),
    ];
    for (args, code) in cases {
        assert_eq!(daemon.cli(args).code, code, "{args:?}");
    }
}

#[test]
fn values_print_as_set() {
    let daemon = Daemon::start();
    assert_eq!(
        daemon.cli(&["config", "get", "snooze_return_time"]).stdout,
        "09:00\n"
    );
    assert_eq!(
        daemon
            .cli(&["config", "set", "status_interval_minutes", "7"])
            .code,
        0
    );
    assert_eq!(
        daemon
            .cli(&["config", "get", "status_interval_minutes"])
            .stdout,
        "7\n"
    );
    let json: Value = serde_json::from_str(
        &daemon
            .cli(&["config", "get", "status_interval_minutes", "--json"])
            .stdout,
    )
    .unwrap();
    assert_eq!(json["value"], 7);
}

#[test]
fn scope_commands_work_from_the_command_line() {
    let daemon = Daemon::start();
    assert_eq!(daemon.cli(&["scope", "add", "org"]).code, 0);
    assert_eq!(daemon.cli(&["scope", "notify", "org", "off"]).code, 0);
    assert_eq!(daemon.cli(&["scope", "disable", "org"]).code, 0);
    let json: Value =
        serde_json::from_str(&daemon.cli(&["scope", "list", "--json"]).stdout).unwrap();
    let org = json["scopes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == "org")
        .unwrap();
    assert_eq!(org["notify"], false);
    assert_eq!(org["enabled"], false);
    assert_eq!(daemon.cli(&["scope", "enable", "org"]).code, 0);
    assert_eq!(daemon.cli(&["scope", "remove", "org"]).code, 0);
    assert!(!daemon.cli(&["scope", "list"]).stdout.contains("org"));
    assert!(daemon.send(json!({"cmd":"info"}))["ok"] == true);
}

#[test]
fn reset_works_from_the_command_line_when_the_database_is_unreadable() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("state.db"), vec![0xAB; 4096]).unwrap();
    let mut child = Command::new(daemon_binary())
        .arg("--foreground")
        .env("SHIIBAR_GH_STATE_DIR", dir.path())
        .env("SHIIBAR_GH_LOG", "error")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let socket = dir.path().join("shiibar-ghd.sock");
    let deadline = Instant::now() + Duration::from_secs(10);
    while UnixStream::connect(&socket).is_err() {
        assert!(Instant::now() < deadline, "the daemon never accepted");
        std::thread::yield_now();
    }
    assert_eq!(run(dir.path(), &["list"]).code, 1);
    assert_eq!(run(dir.path(), &["config", "get", "notify_state"]).code, 1);
    assert_eq!(run(dir.path(), &["reset"]).code, 0);
    assert_eq!(run(dir.path(), &["list"]).code, 0);
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(feature = "dev-ingest")]
mod with_events {
    use super::*;

    fn pr(id: &str, number: u64, author: &str, patch: Value) -> Value {
        let mut value = json!({
            "id": id, "owner": "org", "repo": "app", "number": number,
            "url": format!("https://github.example/{id}"),
            "title": format!("Title {id}"), "author": author, "base": "main", "head": "topic",
            "state": "open", "is_draft": false, "review": "none", "checks": "none",
            "base_status": "none", "mergeable": false, "failed_check": null,
            "changes_requested_by": null, "updated_at": 1_800_000_000, "is_private": false,
            "requested_me": false,
            "links": {"review":"https://r.example","checks":"https://c.example","base":"https://b.example"}
        });
        for (key, field) in patch.as_object().unwrap() {
            value[key] = field.clone();
        }
        value
    }

    fn event(id: &str, pr_id: &str, kind: &str, at: i64) -> Value {
        json!({"id":id,"pr_id":pr_id,"kind":kind,"occurred_at":at,
               "url":format!("https://github.example/{id}"),"actor":"alice",
               "text":format!("text {id}"),"comment_id":null})
    }

    fn seeded() -> Daemon {
        let daemon = Daemon::start();
        assert_eq!(daemon.cli(&["scope", "add", "org"]).code, 0);
        let response = daemon.send(json!({"cmd":"dev_ingest","ingest":{
            "viewer":"me","missing_pr_ids":[],
            "prs":[
                pr("PR_1", 1, "me", json!({"checks":"failed"})),
                pr("PR_2", 2, "alice", json!({})),
                pr("PR_3", 3, "alice", json!({"is_draft":true})),
            ],
            "events":[
                event("E_1", "PR_2", "comment", 1_800_000_001),
                event("E_2", "PR_2", "merged", 1_800_000_002),
            ],
            "reactions":[]
        }}));
        assert_eq!(response["ok"], true, "{response}");
        daemon
    }

    fn json_of(run: Run) -> Value {
        assert_eq!(run.code, 0, "{}", run.stderr);
        serde_json::from_str(&run.stdout).unwrap()
    }

    #[test]
    fn list_and_activity_print_the_same_as_the_tabs() {
        let daemon = seeded();
        let cards = json_of(daemon.cli(&["list", "--json"]));
        assert_eq!(cards["cards"].as_array().unwrap().len(), 2);
        let text = daemon.cli(&["list"]).stdout;
        assert!(text.contains("org/app#1 [open]"), "{text}");
        assert!(text.contains("E_1"), "a row id to pass to done: {text}");

        let rows = json_of(daemon.cli(&["activity", "--json"]));
        let ids: Vec<&str> = rows["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["E_2", "E_1"]);
        let others = json_of(daemon.cli(&["list", "--others", "--needs-action", "--json"]));
        assert_eq!(others["cards"][0]["id"], "PR_2");
        let mine = json_of(daemon.cli(&["activity", "--mine", "--json"]));
        assert!(mine["rows"].as_array().unwrap().is_empty());
    }

    #[test]
    fn done_snooze_and_open_flow() {
        let daemon = seeded();
        assert_eq!(daemon.cli(&["done", "E_1"]).code, 0);
        let rows = json_of(daemon.cli(&["activity", "--json"]));
        assert_eq!(rows["rows"][1]["done"], true);
        assert_eq!(daemon.cli(&["undone", "E_1"]).code, 0);
        assert_eq!(
            daemon.cli(&["done", "E_2"]).code,
            0,
            "an event row is ok with no change"
        );

        assert_eq!(daemon.cli(&["snooze", "org/app#2"]).code, 0);
        let list = json_of(daemon.cli(&["list", "--json"]));
        assert_eq!(list["cards"].as_array().unwrap().len(), 1);
        let list = json_of(daemon.cli(&["list", "--snoozed", "--json"]));
        assert_eq!(list["cards"].as_array().unwrap().len(), 2);
        assert_eq!(daemon.cli(&["unsnooze", "org/app#2"]).code, 0);

        assert_eq!(
            daemon.cli(&["open", "org/app#2"]).stdout,
            "https://github.example/PR_2\n"
        );
        assert_eq!(
            daemon.cli(&["open", "E_1"]).stdout,
            "https://github.example/E_1\n"
        );
        let status = daemon.cli(&["status", "org/app#1"]);
        assert_eq!(
            status.stdout,
            "org/app#1 open\nReview: none\nChecks: failed\nBase: none\n"
        );
        let status = json_of(daemon.cli(&["status", "org/app#1", "--json"]));
        assert_eq!(status["card"]["checks"], "failed");
    }

    #[test]
    fn exit_codes_with_prs() {
        let daemon = seeded();
        let cases: [(&[&str], i32); 5] = [
            (&["snooze", "org/app#3"], 2),
            (&["status", "org/app#3"], 0),
            (&["open", "org/app#3"], 0),
            (&["snooze", "org/app#9"], 2),
            (&["unsnooze", "org/app#9"], 2),
        ];
        for (args, code) in cases {
            assert_eq!(daemon.cli(args).code, code, "{args:?}");
        }
        assert_eq!(daemon.cli(&["scope", "disable", "org"]).code, 0);
        let cases: [(&[&str], i32); 5] = [
            (&["done", "E_1"], 2),
            (&["snooze", "org/app#1"], 2),
            (&["unsnooze", "org/app#1"], 2),
            (&["status", "org/app#1"], 2),
            (&["open", "E_1"], 2),
        ];
        for (args, code) in cases {
            assert_eq!(daemon.cli(args).code, code, "{args:?}");
        }
        assert_eq!(daemon.cli(&["list"]).stdout, "");
    }
}
