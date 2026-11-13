//! Black-box CLI tests: real `shiibar-gh` subprocesses against a real daemon on
//! a temporary state directory.

use serde_json::Value;
#[cfg(feature = "dev-ingest")]
use serde_json::json;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

/// The bound on every wait here: past it a test fails, it never hangs.
const WAIT: Duration = Duration::from_secs(60);
const BUILD_WAIT: Duration = Duration::from_secs(600);

/// Wait for a process, killing it and failing the test past the limit.
fn wait_within(child: &mut Child, limit: Duration, what: &str) -> ExitStatus {
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

fn read_all(mut pipe: impl Read + Send + 'static) -> std::thread::JoinHandle<String> {
    std::thread::spawn(move || {
        let mut text = String::new();
        pipe.read_to_string(&mut text).unwrap();
        text
    })
}

/// `shiibar-ghd` belongs to another package, so Cargo gives no env var for it.
/// Both binaries land in the same directory.
fn daemon_binary() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_BIN_EXE_shiibar-gh"));
    let dir = dir.parent().expect("a parent directory").to_path_buf();
    let binary = dir.join("shiibar-ghd");
    if !binary.exists() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let mut build = Command::new(env!("CARGO"))
            .args(["build", "-p", "shiibar-ghd", "--bin", "shiibar-ghd"])
            .current_dir(root)
            .spawn()
            .expect("run cargo");
        assert!(wait_within(&mut build, BUILD_WAIT, "cargo build").success());
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

    #[cfg_attr(not(feature = "dev-ingest"), allow(dead_code))]
    fn send(&self, value: Value) -> Value {
        let mut stream = UnixStream::connect(self.dir.path().join("shiibar-ghd.sock")).unwrap();
        stream.set_read_timeout(Some(WAIT)).unwrap();
        stream.set_write_timeout(Some(WAIT)).unwrap();
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

/// Standard input is empty and not a terminal.
fn run(state_dir: &Path, args: &[&str]) -> Run {
    run_with_input(state_dir, args, "")
}

fn run_with_input(state_dir: &Path, args: &[&str], input: &str) -> Run {
    let mut child = Command::new(env!("CARGO_BIN_EXE_shiibar-gh"))
        .args(args)
        .env("SHIIBAR_GH_STATE_DIR", state_dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(input.as_bytes()).unwrap();
    drop(stdin);
    let stdout = read_all(child.stdout.take().unwrap());
    let stderr = read_all(child.stderr.take().unwrap());
    let status = wait_within(&mut child, WAIT, "shiibar-gh");
    Run {
        code: status.code().unwrap(),
        stdout: stdout.join().unwrap(),
        stderr: stderr.join().unwrap(),
    }
}

#[test]
fn every_command_has_help_with_exit_0_and_needs_no_daemon() {
    let dir = tempfile::tempdir().unwrap();
    let commands: [&[&str]; 29] = [
        &["--help"],
        &["help"],
        &["list", "--help"],
        &["status", "--help"],
        &["activity", "--help"],
        &["read", "--help"],
        &["version", "--help"],
        &["place", "--help"],
        &["dismiss", "--help"],
        &["restore", "--help"],
        &["mute", "--help"],
        &["unmute", "--help"],
        &["mutes", "--help"],
        &["refresh", "--help"],
        &["open", "--help"],
        &["config", "get", "--help"],
        &["config", "set", "--help"],
        &["reset", "--help"],
        &["account", "--help"],
        &["account", "list", "--help"],
        &["account", "add", "--help"],
        &["account", "remove", "--help"],
        &["account", "color", "--help"],
        &["token", "set", "--help"],
        &["token", "test", "--help"],
        &["token", "reset", "--help"],
        &["owner", "--help"],
        &["owner", "add", "--help"],
        &["owner", "events", "--help"],
    ];
    for args in commands {
        let result = run(dir.path(), args);
        assert_eq!(result.code, 0, "{args:?}");
        assert!(result.stdout.contains("usage"), "{args:?}");
        for gone in [
            "--todo",
            "list|todo|notify",
            "snooze",
            "Snooze",
            "--snoozed",
            "exclusions",
            "Exclusions",
            "drop_after_days",
            "keep_watching_days",
        ] {
            assert!(!result.stdout.contains(gone), "{args:?}: {gone}");
        }
    }
    let help = run(dir.path(), &["--help"]).stdout;
    for wanted in [
        "--search <text>",
        "read <row>... [--account <a>] | --all --account <a>",
        "version [--json]",
        "text_size",
        "list|notify on|off",
        "[review requested]",
        "[--tab all|review|mine]",
        "[--dismissed]",
        "place <pr> review doing|todo|waiting [--top|--bottom|--before <pr>] --account <a>",
        "mute pr|repo|user <name> --account <a>",
        "auto_dismiss_after_days",
        "dismissed_keep_days",
        "[review:todo]",
        "[muted]",
    ] {
        assert!(help.contains(wanted), "{wanted}: {help}");
    }
    // Stage 4, S4-2-5: the one `--json` that is not the daemon's line.
    let owner_list = run(dir.path(), &["owner", "list", "--help"]);
    assert_eq!(owner_list.code, 0);
    assert!(
        owner_list.stdout.contains(r#"{"ok":true,"owners":[...]}"#),
        "{}",
        owner_list.stdout
    );
}

#[test]
fn usage_errors_exit_1() {
    let dir = tempfile::tempdir().unwrap();
    let cases: [&[&str]; 54] = [
        &[],
        &["nope"],
        // 0.1 commands are gone.
        &["undone", "x"],
        &["scope", "list"],
        &["settings", "status"],
        &["list", "--needs-action"],
        // 0.2 commands are gone.
        &["done", "x"],
        &["todo", "x"],
        &["list", "--todo"],
        &["activity", "--todo"],
        // 0.3 commands are gone.
        &["snooze", "a/b#1", "--account", "me"],
        &["unsnooze", "a/b#1", "--account", "me"],
        &["list", "--snoozed"],
        &["owner", "exclusions", "org", "--account", "me"],
        // `place` takes a tab, a section for review, one position.
        &["place", "a/b#1", "--account", "me"],
        &["place", "a/b#1", "review", "--account", "me"],
        &["place", "a/b#1", "review", "done", "--account", "me"],
        &[
            "place",
            "a/b#1",
            "mine",
            "--top",
            "--bottom",
            "--account",
            "me",
        ],
        &["place", "a/b#1", "none", "--top", "--account", "me"],
        &["mute", "team", "x", "--account", "me"],
        &["mute", "user", "--account", "me"],
        &["list", "--tab", "done"],
        &[
            "owner",
            "events",
            "set",
            "org",
            "mentioned",
            "todo",
            "on",
            "--account",
            "me",
        ],
        // `read` takes rows, or `--all` with `--account`.
        &["read"],
        &["read", "--all"],
        &["read", "--all", "x", "--account", "me"],
        &["list", "--search"],
        &["version", "extra"],
        // No token on standard input.
        &["token", "set", "--account", "me"],
        &["account", "add"],
        // `--account` is required.
        &["token", "set"],
        &["status", "a/b#1"],
        &["dismiss", "a/b#1"],
        &["restore", "a/b#1"],
        &["place", "a/b#1", "mine"],
        &["mute", "user", "x"],
        &["mutes"],
        &["open", "a/b#1"],
        &["owner", "add", "org"],
        &["owner", "lookup", "org"],
        &["owner", "remove", "org"],
        &["owner", "enable", "org"],
        &["owner", "notify", "org", "on"],
        &["owner", "events", "org"],
        // Without `--account` a piped token is required.
        &["token", "test"],
        &["token"],
        &["token", "nope"],
        &["list", "--authored", "--assigned"],
        &["list", "--bogus"],
        &["list", "extra"],
        &["list", "--account"],
        &["owner", "notify", "org", "maybe", "--account", "me"],
        &["account", "color", "me", "pink"],
        &[
            "owner",
            "events",
            "set",
            "org",
            "nope",
            "list",
            "on",
            "--account",
            "me",
        ],
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

/// DESIGN.md, "CLI": `version` exits 0 without a daemon too.
#[test]
fn version_prints_both_versions_or_not_running() {
    let cli = env!("CARGO_PKG_VERSION");
    let dir = tempfile::tempdir().unwrap();
    let alone = run(dir.path(), &["version"]);
    assert_eq!(alone.code, 0);
    assert_eq!(alone.stdout, format!("cli: {cli}\ndaemon: not running\n"));
    let alone = run(dir.path(), &["version", "--json"]);
    assert_eq!(alone.code, 0);
    let json: Value = serde_json::from_str(&alone.stdout).unwrap();
    assert_eq!(json, serde_json::json!({"cli": cli, "daemon": null}));

    let daemon = Daemon::start();
    let both = daemon.cli(&["version"]);
    assert_eq!(both.code, 0);
    assert_eq!(both.stdout, format!("cli: {cli}\ndaemon: {cli}\n"));
    let json: Value = serde_json::from_str(&daemon.cli(&["version", "--json"]).stdout).unwrap();
    assert_eq!(json, serde_json::json!({"cli": cli, "daemon": cli}));
}

/// Nothing here reads the Keychain or reaches GitHub: no account exists.
#[test]
fn exit_codes_without_an_account() {
    let daemon = Daemon::start();
    let cases: [(&[&str], i32); 25] = [
        (&["list"], 0),
        (&["list", "--dismissed", "--search", "x"], 0),
        (&["list", "--tab", "review"], 0),
        (&["list", "--tab", "mine", "--json"], 0),
        (&["activity", "--search", "x y"], 0),
        (&["refresh"], 0),
        (&["account", "list"], 0),
        (&["owner", "list"], 0),
        (&["config", "get", "dismissed_keep_days"], 0),
        (&["config", "set", "dismissed_keep_days", "5"], 0),
        (&["config", "set", "auto_dismiss_after_days", "0"], 0),
        (&["config", "get", "drop_after_days"], 1),
        (&["config", "set", "text_size", "18"], 0),
        (&["config", "set", "text_size", "19"], 1),
        (&["config", "set", "text_size", "8"], 1),
        (&["config", "set", "text_size", "12.5"], 1),
        (&["read", "nope"], 2),
        (&["read", "--all", "--account", "nobody"], 2),
        (&["status", "a/b#1", "--account", "me"], 2),
        (&["open", "nope"], 2),
        (&["list", "--account", "nobody"], 2),
        (&["refresh", "--account", "nobody"], 2),
        (&["owner", "enable", "org", "--account", "nobody"], 2),
        (&["config", "set", "dismissed_keep_days", "0"], 1),
        (&["reset"], 1),
    ];
    for (args, code) in cases {
        let result = daemon.cli(args);
        assert_eq!(result.code, code, "{args:?}: {}", result.stderr);
    }
    assert_eq!(daemon.cli(&["config", "get", "text_size"]).stdout, "18\n");
    let cases: [(&[&str], i32); 6] = [
        (&["account", "remove", "nobody"], 2),
        (&["account", "color", "nobody", "red"], 2),
        (&["owner", "add", "public", "--account", "nobody"], 2),
        (&["owner", "list", "--account", "nobody"], 2),
        (&["mutes", "--account", "nobody"], 2),
        (&["config", "get", "notify_state"], 1),
    ];
    for (args, code) in cases {
        assert_eq!(daemon.cli(args).code, code, "{args:?}");
    }
}

#[test]
fn values_print_as_set() {
    let daemon = Daemon::start();
    assert_eq!(
        daemon
            .cli(&["config", "get", "auto_dismiss_after_days"])
            .stdout,
        "3\n"
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
    assert_eq!(
        daemon.cli(&["config", "get", "appearance"]).stdout,
        "system\n"
    );
    assert_eq!(daemon.cli(&["config", "set", "appearance", "dark"]).code, 0);
    assert_eq!(
        daemon.cli(&["config", "get", "appearance"]).stdout,
        "dark\n"
    );
    assert_eq!(
        daemon.cli(&["config", "set", "appearance", "sepia"]).code,
        1
    );
    assert_eq!(
        daemon.cli(&["config", "get", "appearance"]).stdout,
        "dark\n"
    );
}

/// Tokens come from standard input only: an argument is a usage error.
#[test]
fn a_token_is_never_an_argument() {
    let dir = tempfile::tempdir().unwrap();
    for args in [
        &["token", "set", "--account", "me", "ghp_x"][..],
        &["account", "add", "ghp_x"][..],
        &["token", "test", "ghp_x"][..],
    ] {
        let result = run_with_input(dir.path(), args, "ghp_y\n");
        assert_eq!(result.code, 1, "{args:?}");
        assert!(!result.stderr.contains("ghp_y"), "{args:?}");
    }
}

#[cfg(feature = "dev-ingest")]
impl Daemon {
    /// A `dev-ingest` daemon with a test Keychain at `keychain` (relative
    /// to the state directory) and no GitHub.
    fn start_with_keychain(keychain: &str, prepare: impl FnOnce(&Path)) -> Self {
        let dir = tempfile::tempdir().unwrap();
        prepare(dir.path());
        let mut command = Command::new(daemon_binary());
        command
            .arg("--foreground")
            .env("SHIIBAR_GH_STATE_DIR", dir.path())
            .env("SHIIBAR_GH_LOG", "error")
            .env("SHIIBAR_GH_DEV_NOW", "1800000000")
            .env("SHIIBAR_GH_DEV_TZ", "Asia/Tokyo")
            .env("SHIIBAR_GH_DEV_KEYCHAIN", dir.path().join(keychain))
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

    fn ok(&self, value: Value) -> Value {
        let response = self.send(value.clone());
        assert_eq!(response["ok"], true, "{value} -> {response}");
        response
    }

    /// The account `me` with `org` and Public, made without GitHub.
    fn setup(&self) {
        self.ok(json!({"cmd":"dev_account_add","id":"1001","login":"me"}));
        self.ok(json!({"cmd":"dev_owner_add","account":"me","owner":"org","kind":"org","github_id":100}));
        self.ok(json!({"cmd":"dev_owner_add","account":"me","owner":"public","kind":"public"}));
    }
}

#[cfg(feature = "dev-ingest")]
#[test]
fn account_and_owner_commands_work_from_the_command_line() {
    let daemon = Daemon::start_with_keychain("keychain.json", |_| {});
    daemon.setup();
    let accounts = daemon.cli(&["account", "list"]);
    assert!(
        accounts
            .stdout
            .starts_with("me id=1001 color=none token=no unread=false"),
        "{}",
        accounts.stdout
    );
    assert_eq!(daemon.cli(&["account", "color", "ME", "green"]).code, 0);
    let json: Value =
        serde_json::from_str(&daemon.cli(&["account", "list", "--json"]).stdout).unwrap();
    assert_eq!(json["accounts"][0]["color"], "green");
    assert_eq!(json["accounts"][0]["owners"][1]["kind"], "public");

    for args in [
        &["owner", "notify", "ORG", "off", "--account", "me"][..],
        &["owner", "skip-drafts", "org", "off", "--account", "me"][..],
        &["owner", "disable", "org", "--account", "me"][..],
    ] {
        assert_eq!(daemon.cli(args).code, 0, "{args:?}");
    }
    let owners = daemon.cli(&["owner", "list", "--account", "me"]).stdout;
    assert!(
        owners.contains("me org ")
            && owners.contains("enabled=false notify=false skip_drafts=false prs=0"),
        "{owners}"
    );
    let json: Value = serde_json::from_str(
        &daemon
            .cli(&["owner", "list", "--account", "me", "--json"])
            .stdout,
    )
    .unwrap();
    assert_eq!(json["owners"].as_array().unwrap().len(), 2);
    assert_eq!(
        daemon
            .cli(&["owner", "enable", "org", "--account", "me"])
            .code,
        0
    );

    let events = daemon
        .cli(&["owner", "events", "org", "--account", "me"])
        .stdout;
    assert!(
        events.starts_with("review_requested list=on notify=on\n"),
        "{events}"
    );
    assert!(
        events.contains("merged_closed list=on notify=off"),
        "{events}"
    );
    let set = daemon.cli(&[
        "owner",
        "events",
        "set",
        "org",
        "merged_closed",
        "notify",
        "on",
        "--account",
        "me",
    ]);
    assert_eq!(set.code, 0, "{}", set.stderr);
    assert!(set.stdout.contains("merged_closed list=on notify=on"));
    // Notify while List is off is refused.
    daemon.cli(&[
        "owner",
        "events",
        "set",
        "public",
        "reaction",
        "list",
        "off",
        "--account",
        "me",
    ]);
    assert_eq!(
        daemon
            .cli(&[
                "owner",
                "events",
                "set",
                "public",
                "reaction",
                "notify",
                "on",
                "--account",
                "me"
            ])
            .code,
        1
    );
    let copied = daemon.cli(&[
        "owner",
        "events",
        "copy",
        "org",
        "public",
        "--account",
        "me",
    ]);
    assert_eq!(copied.code, 0, "{}", copied.stderr);
    assert!(copied.stdout.contains("merged_closed list=on notify=on"));

    // The Mute lists (DESIGN.md, "CLI (AI integration)").
    for args in [
        &["mute", "user", "renovate", "--account", "me"][..],
        &["mute", "repo", "org/legacy", "--account", "me"][..],
        &["mute", "user", "Renovate", "--account", "me"][..],
    ] {
        let result = daemon.cli(args);
        assert_eq!(result.code, 0, "{args:?}: {}", result.stderr);
    }
    assert_eq!(
        daemon.cli(&["mutes", "--account", "me"]).stdout,
        "repo org/legacy\nuser renovate\n"
    );
    assert_eq!(
        daemon
            .cli(&["mute", "repo", "noslash", "--account", "me"])
            .code,
        1
    );
    assert_eq!(
        daemon
            .cli(&["mute", "pr", "org/app#9", "--account", "me"])
            .code,
        2,
        "a PR the account does not know"
    );
    assert_eq!(
        daemon
            .cli(&["unmute", "user", "RENOVATE", "--account", "me"])
            .code,
        0
    );
    assert_eq!(
        daemon
            .cli(&["unmute", "user", "nobody", "--account", "me"])
            .code,
        2
    );
    let json: Value =
        serde_json::from_str(&daemon.cli(&["mutes", "--account", "me", "--json"]).stdout).unwrap();
    assert_eq!(
        json["mutes"],
        json!({"repos":["org/legacy"],"users":[],"prs":[]})
    );

    // Public needs no GitHub, but it is there already.
    assert_eq!(
        daemon
            .cli(&["owner", "add", "public", "--account", "me"])
            .code,
        1
    );
    assert_eq!(
        daemon
            .cli(&["owner", "remove", "public", "--account", "me"])
            .code,
        0
    );
    let added = daemon.cli(&["owner", "add", "PUBLIC", "--account", "me"]);
    assert_eq!(added.code, 0, "{}", added.stderr);
    assert_eq!(added.stdout, "me\n");
    // A token test without GitHub cannot run: GitHub is unreachable.
    let test = run_with_input(daemon.dir.path(), &["token", "test"], "ghp_secret\n");
    assert_eq!(test.code, 1);
    assert!(!test.stderr.contains("ghp_secret"));
    // Without GitHub the owner is not checked, so nothing is saved.
    let set = run_with_input(
        daemon.dir.path(),
        &["token", "set", "--account", "me"],
        "ghp_first_line\r\nsecond line\n",
    );
    assert_eq!(set.code, 1);
    assert!(
        set.stderr.contains("Couldn't reach GitHub"),
        "{}",
        set.stderr
    );
    assert!(!set.stderr.contains("ghp_first_line"));
    assert!(!daemon.dir.path().join("keychain.json").exists());
    assert_eq!(daemon.cli(&["account", "remove", "me"]).code, 0);
    assert_eq!(daemon.cli(&["account", "list"]).stdout, "");
}

/// A Keychain path that is a directory cannot be read: refused commands exit
/// with 1 and say why.
#[cfg(feature = "dev-ingest")]
#[test]
fn a_keychain_that_cannot_be_read_exits_1() {
    let daemon = Daemon::start_with_keychain("keychain", |dir| {
        std::fs::create_dir(dir.join("keychain")).unwrap();
    });
    daemon.setup();
    // The first fetch reads the Keychain.
    let refresh = daemon.cli(&["refresh"]);
    assert_eq!(refresh.code, 0);
    assert!(
        refresh.stderr.contains("warning: keychain_unavailable"),
        "{}",
        refresh.stderr
    );
    let removed = daemon.cli(&["account", "remove", "me"]);
    assert_eq!(removed.code, 1);
    assert!(
        removed
            .stderr
            .contains("Couldn't read tokens from Keychain"),
        "{}",
        removed.stderr
    );
    assert_eq!(daemon.cli(&["token", "test", "--account", "me"]).code, 1);
    assert_eq!(
        daemon
            .cli(&["owner", "add", "acme", "--account", "me"])
            .code,
        1
    );
    assert_eq!(
        daemon
            .cli(&["owner", "remove", "public", "--account", "me"])
            .code,
        0
    );
    assert_eq!(daemon.cli(&["account", "list"]).code, 0);
}

/// The unreadable state reads no Keychain, but `reset` makes the first fetch
/// read it, so this runs only in the `dev-ingest` build.
#[test]
#[cfg(feature = "dev-ingest")]
fn reset_works_from_the_command_line_when_the_database_is_unreadable() {
    let daemon = Daemon::start_with_keychain("keychain.json", |dir| {
        std::fs::write(dir.join("state.db"), vec![0xAB; 4096]).unwrap();
    });
    assert_eq!(daemon.cli(&["list"]).code, 1);
    assert_eq!(daemon.cli(&["account", "list"]).code, 1);
    assert_eq!(
        daemon.cli(&["config", "get", "dismissed_keep_days"]).code,
        1
    );
    assert_eq!(daemon.cli(&["reset"]).code, 0);
    assert_eq!(daemon.cli(&["list"]).code, 0);
    assert_eq!(daemon.cli(&["reset"]).code, 1, "readable now");
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
            "changes_requested_by": null, "updated_at": 1_800_000_000,
            "created_at": 1_799_000_000, "is_private": false,
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
        let daemon = Daemon::start_with_keychain("keychain.json", |_| {});
        daemon.setup();
        daemon.ok(json!({"cmd":"dev_ingest","account":"me","ingest":{
            "missing_pr_ids":[],
            "prs":[
                pr("PR_1", 1, "me", json!({"checks":"failed"})),
                pr("PR_2", 2, "alice", json!({"assignees":["me"]})),
                pr("PR_3", 3, "alice", json!({"is_draft":true})),
            ],
            "events":[
                event("E_1", "PR_2", "comment", 1_800_000_001),
                event("E_2", "PR_2", "merged", 1_800_000_002),
            ],
            "reactions":[]
        }}));
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
        assert_eq!(
            cards["cards"].as_array().unwrap().len(),
            3,
            "a Draft of someone else shows too"
        );
        let text = daemon.cli(&["list"]).stdout;
        assert!(text.contains("org/app#1 [open]"), "{text}");
        assert!(text.contains("account=me"), "{text}");
        assert!(
            text.contains("1001:E_1"),
            "a row id to pass to read: {text}"
        );

        let rows = json_of(daemon.cli(&["activity", "--json"]));
        let ids: Vec<&str> = rows["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["1001:E_2", "1001:E_1"]);
        let found =
            json_of(daemon.cli(&["list", "--search", "APP #2", "--account", "me", "--json"]));
        let found: Vec<&str> = found["cards"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["id"].as_str().unwrap())
            .collect();
        assert_eq!(found, ["1001:PR_2"]);
        let rows = json_of(daemon.cli(&["activity", "--search", "merged", "--json"]));
        assert!(
            rows["rows"].as_array().unwrap().is_empty(),
            "the row kind is no field"
        );
        let rows = json_of(daemon.cli(&["activity", "--search", "text e_2", "--json"]));
        assert_eq!(rows["rows"][0]["id"], "1001:E_2");
        assert_eq!(rows["rows"].as_array().unwrap().len(), 1);
        let assigned = json_of(daemon.cli(&["list", "--assigned", "--owner", "org", "--json"]));
        assert_eq!(assigned["cards"].as_array().unwrap().len(), 1);
        let authored = json_of(daemon.cli(&["activity", "--authored", "--json"]));
        assert!(authored["rows"].as_array().unwrap().is_empty());
        let public =
            json_of(daemon.cli(&["activity", "--owner", "public", "--owner", "org", "--json"]));
        assert_eq!(public["rows"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn read_dismiss_and_open_flow() {
        let daemon = seeded();
        let unread = |daemon: &Daemon| -> Vec<bool> {
            json_of(daemon.cli(&["activity", "--json"]))["rows"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["unread"].as_bool().unwrap())
                .collect()
        };
        assert_eq!(unread(&daemon), [true, true]);
        // DESIGN.md, "CLI": `open` prints the URL and reads nothing.
        assert_eq!(
            daemon.cli(&["open", "1001:E_1"]).stdout,
            "https://github.example/E_1\n"
        );
        assert_eq!(unread(&daemon), [true, true]);
        // `--account` may come with rows; it has to name their account.
        assert_eq!(
            daemon
                .cli(&["read", "1001:E_1", "--account", "nobody"])
                .code,
            2
        );
        assert_eq!(daemon.cli(&["read", "1002:E_1", "--account", "me"]).code, 2);
        assert_eq!(unread(&daemon), [true, true], "nothing read yet");
        assert_eq!(daemon.cli(&["read", "1001:E_1", "--account", "ME"]).code, 0);
        assert_eq!(unread(&daemon), [true, false]);
        assert_eq!(daemon.cli(&["read", "1001:E_2", "nope"]).code, 2);
        assert_eq!(unread(&daemon), [true, false], "nothing changes");
        assert_eq!(daemon.cli(&["read", "--all", "--account", "ME"]).code, 0);
        assert_eq!(unread(&daemon), [false, false]);

        let dismissed = daemon.cli(&["dismiss", "org/app#2", "--account", "me"]);
        assert_eq!(dismissed.code, 0, "{}", dismissed.stderr);
        assert_eq!(dismissed.stdout, "org/app#2 [dismissed]\n");
        let list = json_of(daemon.cli(&["list", "--json"]));
        assert_eq!(list["cards"].as_array().unwrap().len(), 2);
        let list = json_of(daemon.cli(&["list", "--dismissed", "--tab", "mine", "--json"]));
        assert_eq!(
            list["cards"].as_array().unwrap().len(),
            1,
            "--tab is ignored"
        );
        // The days left count from the wall clock of the command; the
        // daemon of the test runs at a fixed time.
        let text = daemon.cli(&["list", "--dismissed"]).stdout;
        assert!(text.starts_with("org/app#2 [open] ["), "{text}");
        assert!(text.contains(" days left] review="), "{text}");
        assert_eq!(
            daemon
                .cli(&["dismiss", "org/app#2", "--account", "me"])
                .code,
            1
        );
        assert_eq!(
            daemon
                .cli(&["restore", "org/app#2", "--account", "me"])
                .code,
            0
        );
        assert_eq!(
            daemon
                .cli(&["restore", "org/app#2", "--account", "me"])
                .code,
            1
        );

        assert_eq!(
            daemon.cli(&["open", "org/app#2", "--account", "me"]).stdout,
            "https://github.example/PR_2\n"
        );
        assert_eq!(
            daemon.cli(&["open", "1001:E_1"]).stdout,
            "https://github.example/E_1\n"
        );
        let status = daemon.cli(&["status", "org/app#1", "--account", "me"]);
        assert_eq!(
            status.stdout,
            "org/app#1 open\nReview: none\nChecks: failed\nBase: none\n"
        );
        let status = json_of(daemon.cli(&["status", "org/app#1", "--account", "me", "--json"]));
        assert_eq!(status["card"]["checks"], "failed");
    }

    /// DESIGN.md, "CLI": logins and repositories compare without case.
    #[test]
    fn a_pr_resolves_whatever_the_case_of_owner_and_repository() {
        let daemon = seeded();
        let status = daemon.cli(&["status", "ORG/App#1", "--account", "ME"]);
        assert_eq!(status.code, 0, "{}", status.stderr);
        assert!(status.stdout.starts_with("org/app#1 open"));
        assert_eq!(
            daemon.cli(&["open", "Org/APP#2", "--account", "me"]).stdout,
            "https://github.example/PR_2\n"
        );
        assert_eq!(
            daemon
                .cli(&["dismiss", "ORG/APP#2", "--account", "me"])
                .code,
            0
        );
        assert_eq!(
            daemon
                .cli(&["restore", "org/App#2", "--account", "me"])
                .code,
            0
        );
        assert_eq!(
            daemon
                .cli(&["status", "org/other#1", "--account", "me"])
                .code,
            2
        );
    }

    #[test]
    fn list_prints_open_prs_first_then_recently_updated_and_marks_review_requests() {
        let daemon = Daemon::start_with_keychain("keychain.json", |_| {});
        daemon.setup();
        daemon.ok(json!({"cmd":"dev_ingest","account":"me","ingest":{
            "prs":[pr("PR_2", 2, "alice", json!({}))]
        }}));
        daemon.ok(json!({"cmd":"dev_ingest","account":"me","ingest":{
            "prs":[
                pr("PR_1", 1, "me", json!({"updated_at": 1_800_000_500})),
                pr("PR_2", 2, "alice", json!({"updated_at": 1_800_000_900, "state": "merged"})),
                pr("PR_3", 3, "alice", json!({"updated_at": 1_800_000_700, "requested_me": true})),
                pr("PR_4", 4, "alice", json!({"owner": "elsewhere", "requested_me": true})),
            ],
            "events":[
                event("E_1", "PR_2", "merged", 1_800_000_002),
                event("RR_3", "PR_3", "review_requested", 1_800_000_003),
            ]
        }}));
        let text = daemon.cli(&["list"]).stdout;
        let order: Vec<&str> = text
            .lines()
            .filter(|l| !l.starts_with(' '))
            .map(|l| l.split(' ').next().unwrap())
            .collect();
        assert_eq!(
            order,
            ["org/app#3", "org/app#1", "org/app#2", "elsewhere/app#4"]
        );
        assert!(
            text.contains("org/app#3 [open] [review:todo] [review requested] review="),
            "{text}"
        );
        assert!(text.contains("org/app#1 [open] [mine] review="), "{text}");
        let owners = daemon.cli(&["owner", "list"]).stdout;
        assert!(
            owners.contains("me org ") && owners.contains(" prs=3"),
            "{owners}"
        );
        assert!(!owners.contains("review="), "{owners}");
        // DESIGN.md, "CLI (AI integration)": the tabs in section order.
        let review = daemon.cli(&["list", "--tab", "review"]).stdout;
        let order: Vec<&str> = review
            .lines()
            .filter(|l| !l.starts_with(' '))
            .map(|l| l.split(' ').next().unwrap())
            .collect();
        // PR_4 is requested too, but no request row put it in Todo.
        assert_eq!(order, ["org/app#3"]);
        let mine = daemon.cli(&["list", "--tab", "mine"]).stdout;
        assert!(mine.starts_with("org/app#1 [open] [mine]"), "{mine}");
        assert_eq!(mine.lines().filter(|l| !l.starts_with(' ')).count(), 1);
    }

    #[test]
    fn place_moves_cards_between_sections_and_marks_them() {
        let daemon = seeded();
        let place = |args: &[&str]| {
            let result = daemon.cli(args);
            assert_eq!(result.code, 0, "{args:?}: {}", result.stderr);
            result.stdout
        };
        assert_eq!(
            place(&["place", "org/app#3", "review", "doing", "--account", "me"]),
            "org/app#3 [review:doing]\n"
        );
        // From Doing to Todo without a position: the top.
        assert_eq!(
            place(&["place", "org/app#3", "review", "todo", "--account", "me"]),
            "org/app#3 [review:todo]\n"
        );
        let json = json_of(daemon.cli(&["status", "org/app#3", "--account", "me", "--json"]));
        assert_eq!(
            json["card"]["placement"],
            json!({"tab":"review","section":"todo","position":0})
        );
        // A merged PR goes straight to Done; the user can move it out and
        // back.
        daemon.ok(json!({"cmd":"dev_ingest","account":"me","ingest":{
            "prs":[pr("PR_2", 2, "alice", json!({"state":"merged"}))]
        }}));
        assert_eq!(
            place(&["place", "org/app#2", "mine", "--account", "me"]),
            "org/app#2 [mine:done]\n"
        );
        assert_eq!(
            place(&["place", "org/app#2", "mine", "--account", "me"]),
            "org/app#2 [mine]\n"
        );
        assert_eq!(
            place(&["place", "org/app#2", "mine", "done", "--account", "me"]),
            "org/app#2 [mine:done]\n"
        );
        // An open PR moves to Done by hand.
        assert_eq!(
            place(&["place", "org/app#3", "review", "done", "--account", "me"]),
            "org/app#3 [review:done]\n"
        );
        assert_eq!(
            place(&["place", "org/app#3", "review", "todo", "--account", "me"]),
            "org/app#3 [review:todo]\n"
        );
        for (args, code) in [
            (
                &["place", "org/app#1", "review", "todo", "--account", "me"][..],
                1,
            ),
            (&["place", "org/app#1", "none", "--account", "me"], 1),
            (
                &[
                    "place",
                    "org/app#3",
                    "review",
                    "todo",
                    "--before",
                    "org/app#1",
                    "--account",
                    "me",
                ],
                1,
            ),
            (&["place", "org/app#9", "mine", "--account", "me"], 2),
        ] {
            assert_eq!(daemon.cli(args).code, code, "{args:?}");
        }
        assert_eq!(
            place(&["place", "org/app#3", "none", "--account", "me"]),
            "org/app#3\n"
        );
        // Muted cards say so.
        place(&["mute", "repo", "org/app", "--account", "me"]);
        let text = daemon.cli(&["list"]).stdout;
        assert!(text.contains("org/app#3 [draft] [muted] review="), "{text}");
        assert!(text.contains(" comment [muted] text E_1"), "{text}");
    }

    #[test]
    fn exit_codes_with_prs() {
        let daemon = seeded();
        let cases: [(&[&str], i32); 5] = [
            (&["dismiss", "org/app#3", "--account", "me"], 0),
            (&["status", "org/app#3", "--account", "me"], 0),
            (&["open", "org/app#3", "--account", "me"], 0),
            (&["dismiss", "org/app#9", "--account", "me"], 2),
            (&["restore", "org/app#9", "--account", "me"], 2),
        ];
        for (args, code) in cases {
            assert_eq!(daemon.cli(args).code, code, "{args:?}");
        }
        assert_eq!(
            daemon
                .cli(&["owner", "disable", "org", "--account", "me"])
                .code,
            0
        );
        let cases: [(&[&str], i32); 6] = [
            (&["read", "1001:nope"], 2),
            (&["dismiss", "org/app#1", "--account", "me"], 2),
            (&["restore", "org/app#3", "--account", "me"], 2),
            (&["place", "org/app#1", "mine", "--account", "me"], 2),
            (&["status", "org/app#1", "--account", "me"], 2),
            (&["open", "1001:E_1"], 2),
        ];
        for (args, code) in cases {
            assert_eq!(daemon.cli(args).code, code, "{args:?}");
        }
        assert_eq!(daemon.cli(&["list"]).stdout, "");
    }
}
