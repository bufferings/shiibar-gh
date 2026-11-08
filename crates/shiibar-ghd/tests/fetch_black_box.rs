//! The real daemon fetching from the fake GitHub with a file Keychain, one
//! classic token per account. Ordering comes from `refresh` and
//! `dev_clock_set`, which answer after the fetch is applied; nothing sleeps.
//! docs/tasks/M4.md, "How to test".
#![cfg(feature = "dev-ingest")]

mod common;
mod fake_github;

use common::*;
use fake_github::*;
use serde_json::{Value, json};
use std::path::Path;
use std::process::Stdio;

const TOKEN: &str = "ghp_me_SECRET_1";
/// How soon an event that a request causes must arrive: far less than the
/// 30-second periodic pass.
const SOON: std::time::Duration = std::time::Duration::from_secs(2);
const YOU_TOKEN: &str = "ghp_you_SECRET_2";
const YOU: &str = "you";

fn keychain(dir: &Path) -> std::path::PathBuf {
    dir.join("keychain.json")
}

fn command_with(dir: &Path, github: &FakeGitHub, now: i64) -> std::process::Command {
    let mut command = command(dir);
    command
        .env("SHIIBAR_GH_DEV_NOW", now.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", keychain(dir))
        .env("SHIIBAR_GH_DEV_GITHUB_URL", &github.url);
    command
}

fn start(dir: &Path, github: &FakeGitHub) -> TestDaemon {
    TestDaemon::spawn(dir, command_with(dir, github, T0))
}

fn start_at(dir: &Path, github: &FakeGitHub, now: i64) -> TestDaemon {
    TestDaemon::spawn(dir, command_with(dir, github, now))
}

/// A daemon whose stderr goes to `daemon.log` at this level.
fn start_logged(dir: &Path, github: &FakeGitHub, level: &str) -> (TestDaemon, std::path::PathBuf) {
    let log = dir.join("daemon.log");
    let mut command = command_with(dir, github, T0);
    command
        .env("SHIIBAR_GH_LOG", level)
        .stderr(Stdio::from(std::fs::File::create(&log).unwrap()));
    (TestDaemon::spawn(dir, command), log)
}

/// The world most tests start from: tokens of `me` and `you`, owner `org`
/// (numeric id 100).
fn world() -> FakeGitHub {
    let github = FakeGitHub::start();
    github.with(|w| {
        w.logins.insert(TOKEN.into(), ME.into());
        w.logins.insert(YOU_TOKEN.into(), YOU.into());
        w.owners.insert("org".into(), "Organization".into());
        w.owner_ids.insert("org".into(), 100);
    });
    github
}

/// `me` with its token, the `org` owner and Public, without GitHub.
fn setup(daemon: &TestDaemon) {
    add_account(daemon, ACCOUNT, ME, TOKEN);
    add_owner(daemon, ME, "org");
    daemon.ok(json!({"cmd":"dev_owner_add","account":ME,"owner":"public","kind":"public"}));
}

fn add_account(daemon: &TestDaemon, id: &str, login: &str, token: &str) {
    daemon.ok(json!({"cmd":"dev_account_add","id":id,"login":login,"token":token}));
}

fn add_owner(daemon: &TestDaemon, login: &str, owner: &str) {
    daemon.ok(
        json!({"cmd":"dev_owner_add","account":login,"owner":owner,"kind":"org","github_id":100}),
    );
}

fn kinds(daemon: &TestDaemon, login: &str) -> Vec<String> {
    daemon.account(login)["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["kind"].as_str().unwrap().to_string())
        .collect()
}

fn warning(daemon: &TestDaemon, login: &str, kind: &str) -> Value {
    daemon.account(login)["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["kind"] == kind)
        .cloned()
        .unwrap_or_else(|| panic!("no {kind} on {login}"))
}

fn polls(github: &FakeGitHub) -> usize {
    github
        .requests()
        .iter()
        .filter(|r| r.path.starts_with("/notifications"))
        .count()
}

fn ops(github: &FakeGitHub, op: &str) -> Vec<Req> {
    github
        .requests()
        .into_iter()
        .filter(|r| r.op.as_deref() == Some(op))
        .collect()
}

fn cards_of(daemon: &TestDaemon, login: &str) -> Vec<Value> {
    daemon.ok(json!({"cmd":"list","account":login}))["cards"]
        .as_array()
        .unwrap()
        .clone()
}

/// The PRs of the fetch-to-list test, as the fake GitHub holds them.
fn seed(github: &FakeGitHub) {
    github.with(|w| {
        w.prs.push(pr_node(
            "PR_1",
            "org",
            1,
            "alice",
            json!({"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"me"}}]},
                   "assignees":{"nodes":[{"login":"me"}]},
                   "author":{"__typename":"User","login":"alice",
                             "avatarUrl":"https://avatars.example/alice?s=32"}}),
        ));
        w.prs.push(pr_node(
            "PR_2",
            "org",
            2,
            "me",
            json!({"statusCheckRollup":{"state":"SUCCESS"},"mergeStateStatus":"CLEAN"}),
        ));
        w.timeline.insert(
            "PR_1".into(),
            vec![
                json!({"__typename":"ReviewRequestedEvent","id":"RR_1","createdAt":iso(T0 + 10),
                       "actor":{"login":"alice"},"requestedReviewer":{"__typename":"User","login":"me"}}),
                issue_comment("C_1", "bob", T0 + 20, ""),
                issue_comment("C_2", "carol", T0 + 30, &mention_link("me")),
            ],
        );
        w.timeline
            .insert("PR_2".into(), vec![issue_comment("C_3", "alice", T0 + 40, "")]);
    });
}

/// What the same GitHub state is as a hand-written `Ingest`.
fn seed_ingest() -> Value {
    let pr = |id: &str, number: u64, author: &str, patch: Value| {
        let mut value = json!({
            "id":id,"owner":"org","repo":"app","number":number,
            "url":format!("https://github.com/org/app/pull/{number}"),"title":format!("Title {id}"),
            "author":author,"base":"main","head":"topic","state":"open","is_draft":false,
            "review":"none","checks":"none","base_status":"up_to_date","mergeable":false,
            "failed_check":null,"changes_requested_by":null,"updated_at":T0,"is_private":false,
            "requested_me":false,
            "links":{"review":format!("https://github.com/org/app/pull/{number}"),
                     "checks":format!("https://github.com/org/app/pull/{number}/checks"),
                     "base":format!("https://github.com/org/app/pull/{number}")}
        });
        for (key, field) in patch.as_object().unwrap() {
            value[key] = field.clone();
        }
        value
    };
    json!({
        "missing_pr_ids":[],
        "prs":[
            pr("PR_1", 1, "alice", json!({"requested_me":true,"assignees":["me"],
                "author_avatar_url":"https://avatars.example/alice?s=32"})),
            pr("PR_2", 2, "me", json!({"checks":"passed","mergeable":true}))
        ],
        "events":[
            {"id":"RR_1","pr_id":"PR_1","kind":"review_requested","occurred_at":T0 + 10,
             "url":"https://github.com/org/app/pull/1","actor":"alice","text":"for you","comment_id":null},
            {"id":"C_2","pr_id":"PR_1","kind":"mentioned","occurred_at":T0 + 30,
             "url":"https://github.com/c/C_2","actor":"carol","text":"text C_2","comment_id":"C_2"},
            {"id":"C_3","pr_id":"PR_2","kind":"comment","occurred_at":T0 + 40,
             "url":"https://github.com/c/C_3","actor":"alice","text":"text C_3","comment_id":"C_3"}
        ],
        "reactions":[]
    })
}

#[test]
fn from_a_token_to_list_the_rows_match_a_dev_ingest() {
    let github = world();
    seed(&github);
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.clock(T0 + 100);
    let fetched_cards = daemon.cards();
    let fetched_note = app.notification();

    // The same state injected by hand into a daemon without GitHub.
    let other = tempfile::tempdir().unwrap();
    let injected = TestDaemon::start(other.path());
    injected.setup_account();
    let mut app2 = injected.subscribe("app");
    app2.snapshot();
    injected.clock(T0 + 100);
    injected.ok(json!({"cmd":"dev_ingest","account":ME,"ingest":seed_ingest()}));
    let injected_cards = injected.cards();
    let injected_note = app2.notification();

    assert_eq!(fetched_cards.len(), 2);
    let card = |id: &str| {
        fetched_cards
            .iter()
            .find(|c| c["id"] == rid(id))
            .unwrap()
            .clone()
    };
    assert_eq!(
        card("PR_1")["author_avatar_url"],
        "https://avatars.example/alice?s=32"
    );
    assert_eq!(card("PR_1")["assigned_to_me"], true, "assignees are read");
    assert_eq!(card("PR_2")["author_avatar_url"], Value::Null);
    let status = ops(&github, "Status").remove(0);
    assert!(
        status
            .query()
            .contains("author { __typename login avatarUrl(size: 32) }")
    );
    assert!(status.query().contains("assignees(first: 100)"));
    assert_eq!(
        fetched_cards, injected_cards,
        "the same rows, unread and done"
    );
    let strip = |mut n: Value| {
        n["id"] = json!(null);
        n
    };
    assert_eq!(strip(fetched_note.clone()), strip(injected_note));
    assert_eq!(fetched_note["title"], "me · 3 new events");
    assert_eq!(fetched_note["subtitle"], "org · in 2 PRs");
    let account = daemon.account(ME);
    assert_eq!(account["updated_at"], T0 + 100);
    assert!(kinds(&daemon, ME).is_empty(), "{account}");
    // One classic token for everything, read-only calls only.
    for req in github.requests() {
        assert_eq!(req.token, TOKEN, "{} {:?}", req.path, req.op);
        if req.path == "/graphql" {
            assert_eq!(req.method, "POST");
            assert!(
                req.query().trim_start().starts_with("query "),
                "{}",
                req.query()
            );
            assert!(!req.query().contains("mutation"));
        } else {
            assert_eq!(req.method, "GET", "{}", req.path);
            assert_eq!(
                req.headers.get("x-github-api-version").map(String::as_str),
                Some("2026-03-10")
            );
        }
    }
    let search = ops(&github, "Search").remove(0);
    assert_eq!(
        search.vars()["q3"],
        "is:pr is:open review-requested:@me org:org",
        "the team kind's List is on"
    );
    assert!(
        github
            .requests()
            .iter()
            .any(|r| r.path.starts_with("/user/teams")),
        "teams come from GET /user/teams"
    );
    daemon.stop();
    injected.stop();
}

#[test]
fn the_team_list_off_searches_requests_to_me_only() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.ok(json!({"cmd":"owner_events_set","account":ME,"owner":"org",
        "event":"team_review_requested","column":"list","on":false}));
    daemon.clock(T0 + 100);
    let queries: Vec<String> = ops(&github, "Search")
        .iter()
        .map(|r| r.vars()["q3"].as_str().unwrap().to_string())
        .collect();
    assert!(
        queries.contains(&"is:pr is:open user-review-requested:@me org:org".to_string()),
        "{queries:?}"
    );
    assert!(
        queries.contains(&"is:pr is:open review-requested:@me is:public".to_string()),
        "Public keeps its own table: {queries:?}"
    );
    daemon.stop();
}

#[test]
fn two_accounts_on_the_same_owner_fetch_with_their_own_tokens_apart() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "me", json!({})));
        w.prs.push(pr_node("PR_2", "org", 2, "you", json!({})));
        w.prs.push(pr_node("PR_3", "org", 3, "alice", json!({})));
        w.visible
            .insert(TOKEN.into(), ["PR_1".into(), "PR_3".into()].into());
        w.visible
            .insert(YOU_TOKEN.into(), ["PR_2".into(), "PR_3".into()].into());
        let both = format!("{}{}", mention_link("me"), mention_link("you"));
        w.timeline.insert(
            "PR_3".into(),
            vec![issue_comment("C_9", "bob", T0 + 10, &both)],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    add_account(&daemon, "1002", YOU, YOU_TOKEN);
    add_owner(&daemon, YOU, "org");
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.clock(T0 + 100);
    let ids = |login: &str| {
        let mut ids: Vec<String> = cards_of(&daemon, login)
            .iter()
            .map(|c| c["id"].as_str().unwrap().to_string())
            .collect();
        ids.sort();
        ids
    };
    assert_eq!(ids(ME), ["1001:PR_1", "1001:PR_3"]);
    assert_eq!(ids(YOU), ["1002:PR_2", "1002:PR_3"]);
    assert!(daemon.row("C_9").is_some());
    let mut titles = vec![
        app.notification()["title"].as_str().unwrap().to_string(),
        app.notification()["title"].as_str().unwrap().to_string(),
    ];
    titles.sort();
    assert_eq!(titles, ["me · Mentioned", "you · Mentioned"]);
    // Every call of an account carries that account's token.
    let searches = ops(&github, "Search");
    assert!(searches.iter().any(|r| r.token == TOKEN));
    assert!(searches.iter().any(|r| r.token == YOU_TOKEN));
    // Done on one account leaves the other.
    daemon.ok(json!({"cmd":"done","row":"1001:C_9","on":true}));
    let yours = cards_of(&daemon, YOU);
    let row = yours
        .iter()
        .flat_map(|c| c["rows"].as_array().unwrap().clone())
        .find(|r| r["id"] == "1002:C_9")
        .unwrap();
    assert_eq!(row["done"], false);
    daemon.stop();
}

#[test]
fn notifications_follow_the_poll_interval_and_if_modified_since() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "someone", 5, "alice", json!({})));
        w.notifications = vec![json!({
            "updated_at":iso(T0 + 50),"reason":"mention",
            "subject":{"type":"PullRequest","url":"https://api.github.com/repos/someone/app/pulls/5"}
        })];
        w.poll_interval = 120;
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let polled = |github: &FakeGitHub| -> Vec<Req> {
        github
            .requests()
            .into_iter()
            .filter(|r| r.path.starts_with("/notifications"))
            .collect()
    };
    let first = polled(&github);
    assert_eq!(first.len(), 1);
    assert!(first[0].path.contains("all=true") && first[0].path.contains("per_page=50"));
    assert!(!first[0].headers.contains_key("if-modified-since"));
    assert_eq!(first[0].token, TOKEN);
    assert!(
        !ops(&github, "Resolve").is_empty(),
        "a notified PR is looked up by owner, name and number"
    );

    github.clear_requests();
    daemon.clock(T0 + 160);
    assert!(polled(&github).is_empty(), "within X-Poll-Interval");
    daemon.clock(T0 + 220);
    let second = polled(&github);
    assert_eq!(second.len(), 1);
    assert_eq!(
        second[0]
            .headers
            .get("if-modified-since")
            .map(String::as_str),
        Some("Fri, 15 Jan 2027 08:00:00 GMT")
    );
    assert!(
        second[0]
            .path
            .contains(&format!("since={}", iso(T0 + 50).replace(':', "%3A")))
    );
    let rate = &daemon.account(ME)["rate_limit"];
    assert_eq!(rate["graphql"]["used"], 1);
    assert_eq!(rate["graphql"]["limit"], 5000);
    assert_eq!(rate["rest"]["used"], 10);
    daemon.stop();
}

#[test]
fn a_secondary_limit_stops_only_that_account_for_retry_after_then_resumes() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    add_account(&daemon, "1002", YOU, YOU_TOKEN);
    add_owner(&daemon, YOU, "org");
    github.intercept(|req| {
        (req.token == TOKEN && req.op.as_deref() == Some("Search")).then(|| {
            Resp::json(
                403,
                json!({"message":"You have exceeded a secondary rate limit."}),
            )
            .header("retry-after", "120")
        })
    });
    daemon.clock(T0 + 100);
    let limited = warning(&daemon, ME, "rate_limited");
    assert_eq!(limited["until"], T0 + 220);
    assert_eq!(limited["account"], ACCOUNT);
    assert_eq!(
        limited["message"],
        "Polling paused until 17:03 · GitHub's limit reached"
    );
    assert!(kinds(&daemon, YOU).is_empty(), "the other account goes on");
    github.clear_overrides();
    github.clear_requests();
    let answer = daemon.ok(json!({"cmd":"refresh","account":ME}));
    assert!(
        answer["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|w| w["kind"] == "rate_limited" && w["until"] == T0 + 220)
    );
    assert!(
        github.by_token(TOKEN).is_empty(),
        "refresh does not fetch while stopped"
    );
    daemon.clock(T0 + 219);
    assert!(github.by_token(TOKEN).is_empty(), "notifications included");
    daemon.clock(T0 + 220);
    assert!(!github.by_token(TOKEN).is_empty(), "resumes by itself");
    assert!(kinds(&daemon, ME).is_empty());
    daemon.stop();
}

#[test]
fn an_exhausted_primary_limit_waits_for_its_reset() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    github.intercept(|req| {
        req.path.starts_with("/notifications").then(|| {
            Resp::json(403, json!({"message":"API rate limit exceeded"}))
                .header("x-ratelimit-remaining", "0")
                .header("x-ratelimit-reset", (T0 + 900).to_string())
        })
    });
    daemon.clock(T0 + 100);
    assert_eq!(warning(&daemon, ME, "rate_limited")["until"], T0 + 900);
    github.clear_overrides();
    github.clear_requests();
    daemon.clock(T0 + 899);
    assert!(github.requests().is_empty());
    daemon.clock(T0 + 900);
    assert!(!github.requests().is_empty());
    daemon.stop();
}

#[test]
fn usage_under_a_fifth_of_the_limit_warns_and_keeps_the_interval() {
    let github = world();
    github.with(|w| w.limits = Some((999, 999)));
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    assert_eq!(
        kinds(&daemon, ME),
        ["graphql_near_limit", "rest_near_limit"]
    );
    let w = warning(&daemon, ME, "graphql_near_limit");
    assert_eq!(
        w["message"],
        "GraphQL API usage is over 80% of GitHub's limit"
    );
    assert_eq!(
        warning(&daemon, ME, "rest_near_limit")["message"],
        "REST API usage is over 80% of GitHub's limit"
    );
    assert_eq!(
        daemon.account(ME)["rate_limit"]["graphql"]["used"],
        5000 - 999
    );
    github.clear_requests();
    daemon.clock(T0 + 160);
    assert!(!ops(&github, "Search").is_empty(), "the interval stays");
    github.with(|w| w.limits = Some((1000, 1000)));
    daemon.clock(T0 + 220);
    assert!(kinds(&daemon, ME).is_empty(), "20% left is not under it");
    daemon.stop();
}

#[test]
fn tokens_never_reach_the_log_the_database_or_an_answer() {
    let github = world();
    github.with(|w| {
        w.logins
            .insert("ghp_other_SECRET_3".into(), "octocat".into());
    });
    let dir = tempfile::tempdir().unwrap();
    let (daemon, log) = start_logged(dir.path(), &github, "debug");
    setup(&daemon);
    let mut answers = vec![
        daemon.request(json!({"cmd":"account_add","token":TOKEN})),
        daemon.request(json!({"cmd":"account_add","token":"SECRET_4"})),
        daemon.request(json!({"cmd":"token_set","account":"nobody","token":"SECRET_5"})),
        daemon.request(json!({"cmd":"token_set","account":ME,"token":""})),
        daemon.request(json!({"cmd":"token_set","account":ME,"token":"ghp_other_SECRET_3"})),
        daemon.raw(r#"{"cmd":"token_set","account":"me","token":12345678}"#),
        daemon.raw(r#"{"cmd":"token_set","account":"me","token":"SECRET_6","x":}"#),
        daemon.request(json!({"cmd":"token_test","account":ME,"token":"SECRET_7"})),
        daemon.request(json!({"cmd":"token_test","account":ME})),
        daemon.request(json!({"cmd":"token_test","token":"SECRET_8"})),
        daemon.request(json!({"cmd":"refresh"})),
        daemon.request(json!({"cmd":"account_list"})),
    ];
    answers.push(daemon.subscribe("cli").snapshot());
    daemon.stop();
    let mut files: Vec<std::path::PathBuf> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p != &keychain(dir.path()))
        .collect();
    files.sort();
    for secret in [
        "SECRET_1", "SECRET_3", "SECRET_4", "SECRET_5", "SECRET_6", "SECRET_7", "SECRET_8",
        "12345678",
    ] {
        for answer in &answers {
            assert!(!answer.to_string().contains(secret), "{secret} in {answer}");
        }
        for file in &files {
            let bytes = std::fs::read(file).unwrap_or_default();
            let text = String::from_utf8_lossy(&bytes);
            assert!(!text.contains(secret), "{secret} in {}", file.display());
        }
    }
    let log_text = std::fs::read_to_string(&log).unwrap();
    assert!(
        log_text.contains("dev-ingest: test Keychain at"),
        "{log_text}"
    );
    assert!(
        log_text.contains(&format!("dev-ingest: test GitHub at {}", github.url)),
        "{log_text}"
    );
    assert!(files.iter().any(|f| f.ends_with("state.db")));
    // The tokens did reach the fake GitHub, and only in the header.
    assert!(
        github
            .requests()
            .iter()
            .all(|r| !r.path.contains("SECRET") && !r.body.to_string().contains("SECRET"))
    );
    // The Keychain item holds the token, with the account id and login.
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(keychain(dir.path())).unwrap()).unwrap();
    assert_eq!(
        saved,
        json!({"version":2,"accounts":[{"id":"1001","login":"me","token":TOKEN}]})
    );
}

#[test]
fn account_add_makes_the_account_of_the_token_owner_and_tests_it() {
    let github = world();
    github.with(|w| {
        w.token_headers.insert(
            TOKEN.into(),
            vec![(
                "github-authentication-token-expiration".into(),
                "2027-02-01 00:00:00 UTC".into(),
            )],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    let added = daemon.ok(json!({"cmd":"account_add","token":format!("  {TOKEN}\n")}));
    let account = &added["account"];
    assert_eq!(
        account["id"], "1001",
        "the numeric user id of viewer (databaseId)"
    );
    assert_eq!(account["login"], "me");
    assert_eq!(account["color"], "none", "the first account");
    assert_eq!(account["token"]["registered"], true);
    assert_eq!(account["owners"], json!([]));
    // The saved token is tested right after the answer.
    let changed = cli.until(|e| {
        e["event"] == "account_changed" && !e["account"]["token"]["last_test"].is_null()
    });
    let results = changed["account"]["token"]["last_test"]["results"].clone();
    let items: Vec<(String, String, String)> = results
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["label"].as_str().unwrap().into(),
                r["outcome"].as_str().unwrap().into(),
                r["text"].as_str().unwrap().into(),
            )
        })
        .collect();
    assert_eq!(
        items,
        [
            ("Account".into(), "ok".into(), "me".into()),
            ("Scopes".into(), "ok".into(), "OK".into()),
            ("Notifications".into(), "ok".into(), "OK".into()),
            ("Team membership".into(), "ok".into(), "OK".into()),
        ]
    );
    assert!(changed["account"]["token"]["expires_at"].is_i64());
    // The same token again; a second account is colored.
    assert_eq!(
        daemon.request(json!({"cmd":"account_add","token":TOKEN}))["error"],
        "me is already added"
    );
    let second = daemon.ok(json!({"cmd":"account_add","token":YOU_TOKEN}));
    assert_eq!(second["account"]["color"], "red");
    // A token GitHub rejects, and GitHub out of reach.
    github.with(|w| w.unauthorized.insert("ghp_bad".into()));
    let bad = daemon.request(json!({"cmd":"account_add","token":"ghp_bad"}));
    assert_eq!(bad["code"], "invalid");
    github
        .intercept(|req| (req.op.as_deref() == Some("Viewer")).then(|| Resp::json(502, json!({}))));
    let away = daemon.request(json!({"cmd":"account_add","token":"ghp_new"}));
    assert_eq!(away["code"], "unreachable");
    assert_eq!(away["error"], "Couldn't reach GitHub");
    assert_eq!(daemon.accounts().len(), 2, "nothing was made");
    assert_eq!(
        daemon.code(json!({"cmd":"account_add","token":"   "})),
        "invalid"
    );
    daemon.stop();
}

#[test]
fn token_set_saves_only_a_token_of_the_same_account() {
    let github = world();
    github.with(|w| {
        w.logins.insert("ghp_me_new".into(), ME.into());
        w.logins.insert("ghp_octo".into(), "octocat".into());
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let wrong = daemon.request(json!({"cmd":"token_set","account":ME,"token":"ghp_octo"}));
    assert_eq!(wrong["code"], "invalid");
    assert_eq!(wrong["error"], "Belongs to octocat");
    github
        .intercept(|req| (req.op.as_deref() == Some("Viewer")).then(|| Resp::json(503, json!({}))));
    let away = daemon.request(json!({"cmd":"token_set","account":ME,"token":"ghp_me_new"}));
    assert_eq!(away["code"], "unreachable");
    let saved = || -> Value {
        serde_json::from_str(&std::fs::read_to_string(keychain(dir.path())).unwrap()).unwrap()
    };
    assert_eq!(saved()["accounts"][0]["token"], TOKEN, "nothing was saved");
    github.clear_overrides();
    daemon.ok(json!({"cmd":"token_set","account":"ME","token":"ghp_me_new"}));
    assert_eq!(saved()["accounts"][0]["token"], "ghp_me_new");
    assert_eq!(
        daemon.code(json!({"cmd":"token_set","account":"nobody","token":"x"})),
        "not_found"
    );
    daemon.stop();
}

fn test_items(answer: &Value) -> Vec<(String, String, String)> {
    answer["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["label"].as_str().unwrap().into(),
                r["outcome"].as_str().unwrap().into(),
                r["text"].as_str().unwrap().into(),
            )
        })
        .collect()
}

fn item(label: &str, outcome: &str, text: &str) -> (String, String, String) {
    (label.into(), outcome.into(), text.into())
}

#[test]
fn token_test_reports_each_item_of_the_table() {
    let github = world();
    github.with(|w| {
        w.logins.insert("ghp_octo".into(), "octocat".into());
        w.logins.insert("ghp_narrow".into(), ME.into());
        w.token_headers.insert(
            "ghp_narrow".into(),
            vec![("X-OAuth-Scopes".into(), "repo, notifications".into())],
        );
        w.teams_forbidden.insert("ghp_narrow".into());
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    // The saved token, with a row per owner.
    let answer = daemon.ok(json!({"cmd":"token_test","account":ME}));
    assert_eq!(
        test_items(&answer),
        [
            item("Account", "ok", "me"),
            item("Scopes", "ok", "OK"),
            item("Notifications", "ok", "OK"),
            item("Team membership", "ok", "OK"),
            item("org", "ok", "OK"),
            item("Public", "ok", "OK"),
        ]
    );
    assert_eq!(answer["results"][4]["item"], "owner");
    assert_eq!(answer["results"][4]["owner"], daemon.owner(ME, "org")["id"]);
    assert_eq!(
        daemon.account(ME)["token"]["last_test"]["results"],
        answer["results"],
        "the saved token's last test"
    );
    // A pasted token of someone else, and one with too few scopes.
    let other = daemon.ok(json!({"cmd":"token_test","account":ME,"token":"ghp_octo"}));
    assert_eq!(
        test_items(&other)[0],
        item("Account", "failed", "Belongs to octocat")
    );
    let narrow = daemon.ok(json!({"cmd":"token_test","token":"ghp_narrow"}));
    assert_eq!(
        test_items(&narrow),
        [
            item("Account", "failed", "me is already added"),
            item("Scopes", "failed", "Missing (read:org)"),
            item("Notifications", "ok", "OK"),
            item("Team membership", "failed", "Failed (read:org)"),
        ],
        "Add account has no owner rows"
    );
    assert_eq!(
        daemon.account(ME)["token"]["last_test"]["results"],
        answer["results"],
        "a pasted token is not recorded"
    );
    // GitHub out of reach.
    github
        .intercept(|req| (req.op.as_deref() == Some("Viewer")).then(|| Resp::json(502, json!({}))));
    let away = daemon.ok(json!({"cmd":"token_test","token":"ghp_x"}));
    assert_eq!(
        test_items(&away),
        [
            item("Account", "failed", "Couldn't reach GitHub"),
            item(
                "Scopes",
                "cant_check",
                "Can't check (Couldn't reach GitHub)"
            ),
            item(
                "Notifications",
                "cant_check",
                "Can't check (Couldn't reach GitHub)"
            ),
            item(
                "Team membership",
                "cant_check",
                "Can't check (Couldn't reach GitHub)"
            ),
        ]
    );
    assert_eq!(
        daemon.code(json!({"cmd":"token_test"})),
        "invalid",
        "without an account a token is needed"
    );
    daemon.stop();
}

#[test]
fn token_test_names_an_owner_that_needs_sso() {
    let github = world();
    github.intercept(|req| {
        (req.op.as_deref() == Some("OwnerTest")
            && req.vars()["q"].as_str().unwrap().contains("org:org"))
        .then(|| {
            Resp::json(
                200,
                json!({"data":{"search":{"issueCount":0},
                "rateLimit":{"cost":1,"limit":5000,"remaining":4999,"resetAt":iso(T0 + 3600)}}}),
            )
            .header("X-GitHub-SSO", "partial-results; organizations=100")
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let answer = daemon.ok(json!({"cmd":"token_test","account":ME}));
    let items = test_items(&answer);
    assert_eq!(
        items[4],
        item("org", "sso_required", "SSO authorization required")
    );
    assert_eq!(items[5], item("Public", "ok", "OK"));
    daemon.stop();
}

#[test]
fn a_failing_fetch_keeps_the_content_and_a_401_stops_only_its_account() {
    let github = world();
    seed(&github);
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    add_account(&daemon, "1002", YOU, YOU_TOKEN);
    add_owner(&daemon, YOU, "org");
    daemon.clock(T0 + 100);
    assert_eq!(cards_of(&daemon, ME).len(), 2);

    github.intercept(|req| {
        (req.token == TOKEN && req.op.as_deref() == Some("Status"))
            .then(|| Resp::json(502, json!({})))
    });
    daemon.clock(T0 + 200);
    let failed = warning(&daemon, ME, "fetch_failed");
    assert_eq!(failed["until"], T0 + 260, "the next interval");
    assert_eq!(
        failed["message"],
        "Couldn't reach GitHub · retrying in 1 min"
    );
    assert_eq!(cards_of(&daemon, ME).len(), 2, "the last content stays");
    assert_eq!(
        daemon.account(ME)["updated_at"],
        T0 + 200,
        "failed runs count"
    );
    assert!(kinds(&daemon, YOU).is_empty(), "the other account goes on");

    github.clear_overrides();
    github.with(|w| w.unauthorized.insert(TOKEN.into()));
    daemon.clock(T0 + 300);
    assert_eq!(kinds(&daemon, ME), ["token_invalid"]);
    assert_eq!(
        warning(&daemon, ME, "token_invalid")["message"],
        "Token is invalid"
    );
    github.clear_requests();
    daemon.clock(T0 + 400);
    assert!(
        github.by_token(TOKEN).is_empty(),
        "stopped until the token changes"
    );
    assert!(!github.by_token(YOU_TOKEN).is_empty());
    assert_eq!(
        daemon.account(ME)["updated_at"],
        T0 + 300,
        "a stop does not move it"
    );
    // refresh tries once more, and stays stopped on another 401.
    daemon.ok(json!({"cmd":"refresh","account":ME}));
    assert!(!github.by_token(TOKEN).is_empty());
    assert_eq!(kinds(&daemon, ME), ["token_invalid"]);
    // A new token of the same account resumes at the next fetch.
    github.with(|w| {
        w.unauthorized.clear();
        w.logins.insert("ghp_me_new".into(), ME.into());
    });
    daemon.ok(json!({"cmd":"token_set","account":ME,"token":"ghp_me_new"}));
    daemon.clock(T0 + 500);
    assert!(kinds(&daemon, ME).is_empty());
    assert_eq!(daemon.account(ME)["updated_at"], T0 + 500);
    daemon.stop();
}

#[test]
fn success_moves_on_and_failed_events_are_fetched_again_from_their_window() {
    let github = world();
    github.with(|w| w.prs.push(pr_node("PR_1", "org", 1, "me", json!({}))));
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    github
        .intercept(|req| (req.op.as_deref() == Some("Events")).then(|| Resp::json(500, json!({}))));
    github.with(|w| {
        w.prs[0]["updatedAt"] = json!(iso(T0 + 150));
        w.timeline.insert(
            "PR_1".into(),
            vec![issue_comment("C_1", "alice", T0 + 150, "")],
        );
    });
    for (i, at) in [T0 + 1000, T0 + 2000, T0 + 3000].into_iter().enumerate() {
        daemon.clock(at);
        let k = kinds(&daemon, ME);
        assert!(
            !k.contains(&"fetch_failed".to_string()),
            "events are no fetch failure"
        );
        assert_eq!(
            k.contains(&"events_fetch_failed".to_string()),
            i == 2,
            "{k:?}"
        );
    }
    let named = warning(&daemon, ME, "events_fetch_failed");
    assert_eq!(
        named["message"],
        "Couldn't fetch events for org/app #1 · retrying"
    );
    assert_eq!(named["owner"], daemon.owner(ME, "org")["id"]);
    assert!(daemon.row("C_1").is_none());

    github.clear_overrides();
    github.clear_requests();
    daemon.clock(T0 + 4000);
    let events = ops(&github, "Events");
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0].vars()["since"],
        iso(T0 + 100 - 300).max(iso(T0)),
        "the window of the first failure"
    );
    assert!(daemon.row("C_1").is_some(), "nothing was lost");
    assert!(!kinds(&daemon, ME).contains(&"events_fetch_failed".to_string()));
    daemon.stop();
}

#[test]
fn an_account_without_a_token_is_not_fetched() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    daemon.ok(json!({"cmd":"dev_account_add","id":"1001","login":"me"}));
    add_owner(&daemon, ME, "org");
    daemon.clock(T0 + 100);
    daemon.ok(json!({"cmd":"refresh"}));
    assert!(github.requests().is_empty());
    let w = warning(&daemon, ME, "no_token");
    assert_eq!(w["message"], "No token");
    assert_eq!(daemon.account(ME)["updated_at"], Value::Null);
    daemon.stop();
}

#[test]
fn the_login_follows_github_and_the_keychain_keeps_the_id() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    github.with(|w| {
        w.logins.insert(TOKEN.into(), "me-renamed".into());
        w.ids.insert(TOKEN.into(), 1001);
    });
    daemon.clock(T0 + 100);
    assert_eq!(daemon.accounts()[0]["login"], "me-renamed");
    assert_eq!(daemon.accounts()[0]["id"], "1001");
    daemon.ok(json!({"cmd":"list","account":"ME-RENAMED"}));
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(keychain(dir.path())).unwrap()).unwrap();
    assert_eq!(
        saved["accounts"][0]["login"], "me-renamed",
        "the item follows too"
    );
    assert_eq!(saved["accounts"][0]["id"], "1001");
    daemon.stop();
}

#[test]
fn refresh_answers_once_the_fetch_is_applied() {
    let github = world();
    seed(&github);
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let answer = daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(answer["warnings"], json!([]));
    assert_eq!(daemon.cards().len(), 2, "applied before the answer");
    assert_eq!(
        daemon.code(json!({"cmd":"refresh","account":"nobody"})),
        "not_found"
    );
    daemon.stop();
}

#[test]
fn without_the_test_variables_there_is_no_keychain_and_no_fetching() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("daemon.log");
    let mut command = command(dir.path());
    command
        .env("SHIIBAR_GH_LOG", "info")
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .stderr(Stdio::from(std::fs::File::create(&log).unwrap()));
    let daemon = TestDaemon::spawn(dir.path(), command);
    assert_eq!(
        daemon.code(json!({"cmd":"account_add","token":"x"})),
        "unreachable"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"dev_account_add","id":"1001","login":"me","token":"x"})),
        "keychain_unavailable",
        "nothing can be saved"
    );
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(
        daemon.code(json!({"cmd":"token_test","token":"x"})),
        "unreachable"
    );
    daemon.stop();
    let text = std::fs::read_to_string(&log).unwrap();
    assert!(text.contains("dev-ingest: no Keychain"), "{text}");
    assert!(
        text.contains("dev-ingest: no GitHub; nothing is fetched"),
        "{text}"
    );
}

#[test]
fn only_a_loopback_github_and_a_keychain_in_the_state_directory_are_accepted() {
    let dir = tempfile::tempdir().unwrap();
    let mut remote = command(dir.path());
    remote.env("SHIIBAR_GH_DEV_GITHUB_URL", "https://api.github.com");
    assert_eq!(exit_code(remote), 1);
    let mut named = command(dir.path());
    named.env("SHIIBAR_GH_DEV_GITHUB_URL", "http://example.com:8080");
    assert_eq!(exit_code(named), 1);
    let other = tempfile::tempdir().unwrap();
    let mut outside = command(dir.path());
    outside.env("SHIIBAR_GH_DEV_KEYCHAIN", other.path().join("k.json"));
    assert_eq!(exit_code(outside), 1);
    let mut sneaky = command(dir.path());
    sneaky.env("SHIIBAR_GH_DEV_KEYCHAIN", dir.path().join("../k.json"));
    assert_eq!(exit_code(sneaky), 1);
}

// ------------------------------------------------------------- Keychain

#[test]
fn an_empty_state_never_reads_the_keychain() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    // A Keychain that cannot be read: a directory.
    std::fs::create_dir(keychain(dir.path())).unwrap();
    let daemon = start(dir.path(), &github);
    daemon.ok(json!({"cmd":"refresh"}));
    daemon.clock(T0 + 100);
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["keychain"], "ok", "no account, no read");
    assert_eq!(snapshot["accounts"], json!([]));
    daemon.stop();
}

#[test]
fn an_unavailable_keychain_stops_fetching_and_refuses_token_requests() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.stop();
    // The item becomes unreadable for the OS: a directory in its place.
    std::fs::remove_file(keychain(dir.path())).unwrap();
    std::fs::create_dir(keychain(dir.path())).unwrap();
    github.clear_requests();
    let daemon = start(dir.path(), &github);
    let mut cli = daemon.subscribe("cli");
    assert_eq!(cli.snapshot()["keychain"], "ok", "until the first read");
    daemon.clock(T0 + 100);
    let changed = cli.until(|e| e["event"] == "keychain_changed");
    assert_eq!(changed["keychain"], "unavailable");
    assert!(github.requests().is_empty(), "nothing is fetched");
    let w = warning(&daemon, ME, "keychain_unavailable");
    assert_eq!(w["account"], Value::Null);
    assert_eq!(w["message"], "Couldn't read tokens from Keychain");
    for refused in [
        json!({"cmd":"account_add","token":TOKEN}),
        json!({"cmd":"account_remove","account":ME}),
        json!({"cmd":"token_set","account":ME,"token":TOKEN}),
        json!({"cmd":"token_test","account":ME}),
        json!({"cmd":"owner_add","account":ME,"owner":"acme"}),
    ] {
        assert_eq!(
            daemon.code(refused.clone()),
            "keychain_unavailable",
            "{refused}"
        );
    }
    // What does not need a token goes on.
    daemon.ok(json!({"cmd":"owner_remove","account":ME,"owner":"public"}));
    daemon.ok(json!({"cmd":"owner_add","account":ME,"owner":"public"}));
    daemon.ok(json!({"cmd":"owner_disable","account":ME,"owner":"org"}));
    daemon.ok(json!({"cmd":"token_test","token":TOKEN}));
    // Retry: refresh reads the item again.
    std::fs::remove_dir(keychain(dir.path())).unwrap();
    std::fs::write(
        keychain(dir.path()),
        json!({"version":2,"accounts":[{"id":"1001","login":"me","token":TOKEN}]}).to_string(),
    )
    .unwrap();
    daemon.ok(json!({"cmd":"refresh"}));
    let changed = cli.until(|e| e["event"] == "keychain_changed");
    assert_eq!(changed["keychain"], "ok");
    assert!(kinds(&daemon, ME).is_empty(), "{:?}", daemon.account(ME));
    daemon.stop();
}

#[test]
fn unreadable_tokens_are_reset_and_every_account_is_left_without_one() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.stop();
    std::fs::write(keychain(dir.path()), "{not json").unwrap();
    let daemon = start(dir.path(), &github);
    daemon.clock(T0 + 100);
    assert_eq!(daemon.subscribe("cli").snapshot()["keychain"], "unreadable");
    assert_eq!(kinds(&daemon, ME)[0], "tokens_unreadable");
    assert_eq!(
        warning(&daemon, ME, "tokens_unreadable")["message"],
        "Saved tokens are unreadable"
    );
    daemon.ok(json!({"cmd":"token_reset"}));
    assert!(!keychain(dir.path()).exists(), "the item is deleted");
    assert_eq!(daemon.subscribe("cli").snapshot()["keychain"], "ok");
    assert_eq!(kinds(&daemon, ME), ["no_token"]);
    assert_eq!(daemon.account(ME)["token"]["registered"], false);
    assert_eq!(
        daemon.owner(ME, "org")["name"],
        "org",
        "accounts and owners stay"
    );
    // A token again: read, write, and fetching resumes.
    daemon.ok(json!({"cmd":"token_set","account":ME,"token":TOKEN}));
    github.clear_requests();
    daemon.clock(T0 + 200);
    assert!(!github.by_token(TOKEN).is_empty());
    daemon.stop();
}

#[test]
fn removing_an_account_deletes_its_token_and_tells_subscribers() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    add_account(&daemon, "1002", YOU, YOU_TOKEN);
    let mut cli = daemon.subscribe("cli");
    cli.snapshot();
    daemon.ok(json!({"cmd":"account_remove","account":"ME"}));
    let removed = cli.until(|e| e["event"] == "account_removed");
    assert_eq!(removed["id"], "1001");
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(keychain(dir.path())).unwrap()).unwrap();
    assert_eq!(
        saved,
        json!({"version":2,"accounts":[{"id":"1002","login":"you","token":YOU_TOKEN}]})
    );
    assert_eq!(daemon.accounts().len(), 1);
    assert_eq!(
        daemon.code(json!({"cmd":"account_remove","account":"me"})),
        "not_found"
    );
    daemon.stop();
}

#[test]
fn reset_brings_the_accounts_back_from_the_keychain_without_owners() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        keychain(dir.path()),
        json!({"version":2,"accounts":[
            {"id":"1001","login":"me","token":TOKEN},
            {"id":"1002","login":"you","token":YOU_TOKEN}]})
        .to_string(),
    )
    .unwrap();
    std::fs::write(dir.path().join("state.db"), vec![0xAB; 8192]).unwrap();
    let daemon = start(dir.path(), &github);
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], true);
    assert_eq!(snapshot["accounts"], json!([]), "nothing while unreadable");
    daemon.ok(json!({"cmd":"reset"}));
    daemon.clock(T0 + 100);
    let accounts = daemon.accounts();
    let logins: Vec<&str> = accounts
        .iter()
        .map(|a| a["login"].as_str().unwrap())
        .collect();
    assert_eq!(logins, ["me", "you"]);
    assert!(accounts.iter().all(|a| a["token"]["registered"] == true));
    assert!(accounts.iter().all(|a| a["owners"] == json!([])));
    assert_eq!(accounts[0]["id"], "1001");
    daemon.stop();
}

// ------------------------------------------------------------- warnings

#[test]
fn scopes_the_token_lacks_are_a_warning_and_fetching_goes_on() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "me", json!({})));
        w.token_headers.insert(
            TOKEN.into(),
            vec![("X-OAuth-Scopes".into(), "repo, notifications".into())],
        );
        w.teams_forbidden.insert(TOKEN.into());
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let w = warning(&daemon, ME, "scope_missing");
    assert_eq!(w["message"], "Token is missing read:org");
    assert_eq!(daemon.cards().len(), 1, "what can be read is read");
    assert!(!kinds(&daemon, ME).contains(&"fetch_failed".to_string()));
    github.with(|w| {
        w.token_headers.clear();
        w.teams_forbidden.clear();
    });
    daemon.clock(T0 + 200);
    assert!(kinds(&daemon, ME).is_empty(), "{:?}", daemon.account(ME));
    daemon.stop();
}

#[test]
fn sso_names_the_registered_owner_by_its_numeric_id() {
    let github = world();
    github.with(|w| {
        w.token_headers.insert(
            TOKEN.into(),
            vec![(
                "X-GitHub-SSO".into(),
                "partial-results; organizations=100".into(),
            )],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let w = warning(&daemon, ME, "sso_required");
    assert_eq!(w["message"], "SSO authorization required for org");
    assert_eq!(w["owner"], daemon.owner(ME, "org")["id"]);
    assert_eq!(kinds(&daemon, ME), ["sso_required"], "no stop");
    github.with(|w| {
        w.token_headers.insert(
            TOKEN.into(),
            vec![(
                "X-GitHub-SSO".into(),
                "required; url=https://github.com/orgs/acme/sso?authorization_request=1".into(),
            )],
        );
    });
    daemon.clock(T0 + 200);
    let w = warning(&daemon, ME, "sso_required");
    assert_eq!(w["message"], "SSO authorization required");
    assert_eq!(w["owner"], Value::Null);
    assert_eq!(
        w["url"],
        "https://github.com/orgs/acme/sso?authorization_request=1"
    );
    github.with(|w| w.token_headers.clear());
    daemon.clock(T0 + 300);
    assert!(
        kinds(&daemon, ME).is_empty(),
        "authorized: the header is gone"
    );
    daemon.stop();
}

#[test]
fn teams_come_from_user_teams_page_by_page() {
    let github = world();
    let url = github.url.clone();
    let team = json!({"__typename":"Team","databaseId":43,"slug":"infra"});
    github.with(|w| {
        w.prs.push(pr_node(
            "PR_1",
            "org",
            1,
            "alice",
            json!({"reviewRequests":{"nodes":[{"requestedReviewer":team}]}}),
        ));
        w.timeline.insert(
            "PR_1".into(),
            vec![
                json!({"__typename":"ReviewRequestedEvent","id":"RR_1","createdAt":iso(T0 + 10),
                        "actor":{"login":"alice"},"requestedReviewer":team}),
            ],
        );
    });
    github.intercept(move |req| {
        if !req.path.starts_with("/user/teams") {
            return None;
        }
        Some(if req.path.contains("page=2") {
            Resp::json(200, json!([{"id":43,"slug":"infra"}]))
        } else {
            Resp::json(200, json!([{"id":42,"slug":"core"}])).header(
                "Link",
                format!("<{url}/user/teams?per_page=100&page=2>; rel=\"next\""),
            )
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let pages = github
        .requests()
        .iter()
        .filter(|r| r.path.starts_with("/user/teams"))
        .count();
    assert_eq!(pages, 2, "the Link header's next page is read");
    let row = daemon
        .row("RR_1")
        .expect("a request to a team on the second page");
    assert_eq!(row["kind"], "team_review_requested");
    assert_eq!(row["text"], "for infra team");
    assert_eq!(row["todo"], true, "the team is still asked");
    daemon.stop();
}

#[test]
fn a_notified_pr_of_an_owner_that_failed_is_fetched_at_the_next_run() {
    let github = world();
    github.with(|w| w.prs.push(pr_node("PR_1", "org", 1, "me", json!({}))));
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    assert_eq!(daemon.cards().len(), 1);
    github.with(|w| {
        w.timeline
            .insert("PR_1".into(), vec![issue_comment("C_1", "alice", T0 + 150, "")]);
        w.notifications = vec![json!({"updated_at":iso(T0 + 150),"reason":"comment",
            "subject":{"type":"PullRequest","url":"https://api.github.com/repos/org/app/pulls/1"}})];
        w.last_modified = "Fri, 15 Jan 2027 08:02:30 GMT".into();
    });
    github
        .intercept(|req| (req.op.as_deref() == Some("Status")).then(|| Resp::json(502, json!({}))));
    daemon.clock(T0 + 200);
    assert!(daemon.row("C_1").is_none());
    assert!(kinds(&daemon, ME).contains(&"fetch_failed".to_string()));
    github.clear_overrides();
    github.clear_requests();
    daemon.clock(T0 + 300);
    let polled: Vec<bool> = github
        .requests()
        .iter()
        .filter(|r| r.path.starts_with("/notifications"))
        .map(|r| r.headers.contains_key("if-modified-since"))
        .collect();
    assert_eq!(polled, [true], "the notification is not repeated");
    assert!(
        daemon.row("C_1").is_some(),
        "the notified PR was kept for this run"
    );
    daemon.stop();
}

fn reaction_node(id: &str, thumbs: u32) -> Value {
    json!({"__typename":"PullRequestReviewComment","id":id,"reactionGroups":[
        {"content":"THUMBS_UP","viewerHasReacted":false,"reactors":{"totalCount":thumbs}}]})
}

fn reaction_rows(daemon: &TestDaemon) -> usize {
    daemon.ok(json!({"cmd":"activity"}))["rows"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["kind"] == "reaction")
        .count()
}

#[test]
fn a_pr_that_returns_to_the_watch_sets_its_reaction_baseline_without_rows() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
        w.threads.insert(
            "PR_1".into(),
            vec![
                json!({"id":"T_1","comments":[{"id":"C_ME","url":"https://github.com/c/C_ME",
                "createdAt":iso(T0 - 1000),"bodyText":"mine","bodyHTML":"",
                "author":{"__typename":"User","login":"me"}}]}),
            ],
        );
        w.reactables.insert("C_ME".into(), reaction_node("C_ME", 1));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.ok(json!({"cmd":"config_set","key":"keep_watching_days","value":0}));
    daemon.ok(json!({"cmd":"config_set","key":"drop_after_days","value":1}));
    daemon.clock(T0 + 100);
    assert_eq!(reaction_rows(&daemon), 0, "the first count is the baseline");
    let gone = T0 + 2 * DAY;
    daemon.clock(gone);
    daemon.clock(gone + 1);
    assert!(daemon.cards().is_empty());
    github.with(|w| w.reactables.insert("C_ME".into(), reaction_node("C_ME", 5)));
    daemon.clock(gone + 400);
    github.with(|w| w.prs[0]["updatedAt"] = json!(iso(gone + 500)));
    daemon.clock(gone + 600);
    assert_eq!(daemon.cards().len(), 1);
    daemon.clock(gone + 1000);
    assert_eq!(
        reaction_rows(&daemon),
        0,
        "what grew outside the watch makes no row"
    );
    github.with(|w| w.reactables.insert("C_ME".into(), reaction_node("C_ME", 6)));
    daemon.clock(gone + 1400);
    assert_eq!(
        reaction_rows(&daemon),
        1,
        "counting goes on from the new baseline"
    );
    daemon.stop();
}

#[test]
fn behind_base_compares_against_the_head_commit_for_forks_too() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node(
            "PR_1",
            "org",
            1,
            "me",
            json!({"isCrossRepository":true,"headRefOid":"f00d","headRefName":"patch-1"}),
        ));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let compare = ops(&github, "Compare").remove(0);
    assert_eq!(compare.vars()["h0"], "f00d");
    assert_eq!(daemon.cards()[0]["base_status"], "up_to_date");
    daemon.stop();
}

#[test]
fn a_pr_failing_twice_in_one_run_counts_one_failure() {
    let github = world();
    github.with(|w| w.prs.push(pr_node("PR_1", "org", 1, "me", json!({}))));
    github.intercept(|req| {
        matches!(req.op.as_deref(), Some("Events" | "Collect")).then(|| Resp::json(500, json!({})))
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    daemon.clock(T0 + 200);
    assert!(
        !kinds(&daemon, ME).contains(&"events_fetch_failed".to_string()),
        "two runs, two failures"
    );
    daemon.clock(T0 + 300);
    assert!(kinds(&daemon, ME).contains(&"events_fetch_failed".to_string()));
    daemon.stop();
}

#[test]
fn a_rate_limit_met_by_a_token_test_stops_fetching() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    github.intercept(|req| {
        req.path.starts_with("/notifications").then(|| {
            Resp::json(
                403,
                json!({"message":"You have exceeded a secondary rate limit."}),
            )
            .header("retry-after", "300")
        })
    });
    daemon.ok(json!({"cmd":"token_test","account":ME}));
    assert_eq!(warning(&daemon, ME, "rate_limited")["until"], T0 + 300);
    github.clear_overrides();
    github.clear_requests();
    daemon.clock(T0 + 100);
    assert!(github.requests().is_empty());
    daemon.stop();
}

#[test]
fn a_connection_is_read_up_to_ten_pages_then_warns() {
    let github = world();
    github.with(|w| w.prs.push(pr_node("PR_1", "org", 1, "me", json!({}))));
    let more = json!({"pageInfo":{"hasNextPage":true,"endCursor":"next"},"nodes":[]});
    let empty = json!({"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]});
    let (m, e) = (more.clone(), empty.clone());
    github.intercept(move |req| match req.op.as_deref() {
        Some("Collect") => Some(Resp::json(200, json!({"data":{
            "rateLimit":{"cost":1,"limit":5000,"remaining":4999,"resetAt":iso(T0 + 3600)},
            "node":{"id":"PR_1","url":"https://github.com/org/app/pull/1","createdAt":iso(T0 - 86_400),
              "bodyHTML":"","bodyText":"","author":{"__typename":"User","login":"me"},
              "comments":m.clone(),"reviews":e.clone(),"reviewThreads":e.clone(),
              "reviewRequests":{"nodes":[]},"requestEvents":{"nodes":[]}}}}))),
        Some("Page") => Some(Resp::json(200, json!({"data":{
            "rateLimit":{"cost":1,"limit":5000,"remaining":4999,"resetAt":iso(T0 + 3600)},
            "node":{"comments":m.clone()}}}))),
        _ => None,
    });
    let dir = tempfile::tempdir().unwrap();
    let (daemon, log) = start_logged(dir.path(), &github, "warn");
    setup(&daemon);
    daemon.clock(T0 + 100);
    assert_eq!(ops(&github, "Page").len(), 9, "ten pages with the first");
    daemon.stop();
    let text = std::fs::read_to_string(&log).unwrap();
    assert!(
        text.contains("shiibar-ghd warn: comments of PR_1 has more than 10 pages"),
        "{text}"
    );
}

#[test]
fn a_refused_merge_queue_read_keeps_the_other_events() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "me", json!({})));
        w.timeline.insert(
            "PR_1".into(),
            vec![
                issue_comment("C_1", "alice", T0 + 10, ""),
                json!({"__typename":"RemovedFromMergeQueueEvent","id":"X_1","createdAt":iso(T0 + 20),
                       "actor":{"login":"github-merge-queue"},"reason":"failed_checks"}),
            ],
        );
    });
    github.intercept(|req| {
        (req.op.as_deref() == Some("MergeQueue")).then(|| {
            Resp::json(200, json!({
                "data":{"rateLimit":{"cost":1,"limit":5000,"remaining":4999,"resetAt":iso(T0 + 3600)},
                        "node":{"timelineItems":null}},
                "errors":[{"type":"FORBIDDEN","path":["node","timelineItems"],
                           "message":"Resource not accessible by personal access token"}]
            }))
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    assert!(daemon.row("C_1").is_some(), "the comment is kept");
    assert!(daemon.row("X_1").is_none(), "the removal needed the queue");
    assert!(!kinds(&daemon, ME).contains(&"fetch_failed".to_string()));
    daemon.stop();
}

fn notified(owner: &str, number: u64, at: i64) -> Value {
    json!({"updated_at":iso(at),"reason":"mention","subject":{"type":"PullRequest",
        "url":format!("https://api.github.com/repos/{owner}/app/pulls/{number}")}})
}

#[test]
fn notifications_are_read_page_by_page_through_the_link_header() {
    let github = world();
    github.with(|w| {
        w.prs
            .push(pr_node("PR_1", "someone", 1, "alice", json!({})));
        w.prs
            .push(pr_node("PR_2", "someone", 2, "alice", json!({})));
    });
    let url = github.url.clone();
    github.intercept(move |req| {
        if !req.path.starts_with("/notifications") {
            return None;
        }
        Some(if req.path.contains("page=2") {
            Resp::json(200, json!([notified("someone", 2, T0 + 20)]))
        } else {
            Resp::json(200, json!([notified("someone", 1, T0 + 10)]))
                .header(
                    "Link",
                    format!("<{url}/notifications?all=true&per_page=50&page=2>; rel=\"next\""),
                )
                .header("Last-Modified", "Fri, 15 Jan 2027 08:00:00 GMT")
                .header("X-Poll-Interval", "60")
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let polled: Vec<Req> = github
        .requests()
        .into_iter()
        .filter(|r| r.path.starts_with("/notifications"))
        .collect();
    assert_eq!(polled.len(), 2);
    assert!(polled[1].path.contains("page=2"));
    assert!(
        !polled[1].headers.contains_key("if-modified-since"),
        "only the first page"
    );
    let resolve = ops(&github, "Resolve").remove(0);
    let numbers: Vec<i64> = (0..2)
        .filter_map(|i| resolve.vars()[format!("n{i}")].as_i64())
        .collect();
    assert_eq!(numbers, [1, 2], "both pages' PRs are looked up");
    daemon.stop();
}

/// The order is pinned at both ends: the fake GitHub holds the first fetch's
/// `Viewer` answer until the test releases it, and the test releases it
/// only after the daemon logged that the second `refresh` is waiting.
#[test]
fn a_refresh_during_a_fetch_waits_for_it_and_both_answer_after_one_fetch() {
    use std::sync::{Arc, Condvar, Mutex};
    let github = world();
    seed(&github);
    // (the fetch reached the gate, the test released it)
    let gate = Arc::new((Mutex::new((false, false)), Condvar::new()));
    let held = gate.clone();
    github.intercept(move |req| {
        if req.op.as_deref() == Some("Viewer") {
            let (lock, cv) = &*held;
            let mut state = lock.lock().unwrap();
            state.0 = true;
            cv.notify_all();
            while !state.1 {
                state = cv.wait(state).unwrap();
            }
        }
        None
    });
    let dir = tempfile::tempdir().unwrap();
    let (daemon, log) = start_logged(dir.path(), &github, "debug");
    setup(&daemon);
    let send = |socket: std::path::PathBuf| {
        std::thread::spawn(move || {
            use std::io::{BufRead, BufReader, Write};
            let mut stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
            stream.set_read_timeout(Some(WAIT)).unwrap();
            stream.write_all(b"{\"cmd\":\"refresh\"}\n").unwrap();
            let mut line = String::new();
            BufReader::new(stream).read_line(&mut line).unwrap();
            serde_json::from_str::<Value>(&line).unwrap()
        })
    };
    let first = send(daemon.socket());
    {
        let (lock, cv) = &*gate;
        let mut state = lock.lock().unwrap();
        while !state.0 {
            state = cv.wait_timeout(state, WAIT).unwrap().0;
        }
    }
    let second = send(daemon.socket());
    let waiting = "refresh waits for the running fetch";
    let deadline = std::time::Instant::now() + WAIT;
    while !std::fs::read_to_string(&log)
        .unwrap_or_default()
        .contains(waiting)
    {
        assert!(
            std::time::Instant::now() < deadline,
            "the second refresh never waited"
        );
        std::thread::yield_now();
    }
    {
        let (lock, cv) = &*gate;
        lock.lock().unwrap().1 = true;
        cv.notify_all();
    }
    let (a, b) = (first.join().unwrap(), second.join().unwrap());
    assert_eq!(a["ok"], true);
    assert_eq!(b["ok"], true);
    assert_eq!(ops(&github, "Viewer").len(), 1, "one fetch for both");
    assert_eq!(daemon.cards().len(), 2, "applied before either answer");
    daemon.stop();
}

#[test]
fn merge_queue_removals_name_the_reason_and_the_person_who_added_the_pr() {
    let github = world();
    let added = |id: &str, at: i64, who: &str| json!({"__typename":"AddedToMergeQueueEvent","id":id,"createdAt":iso(at),"actor":{"login":who}});
    let removed = |id: &str, at: i64, who: &str, reason: &str| {
        json!({"__typename":"RemovedFromMergeQueueEvent","id":id,"createdAt":iso(at),
               "actor":{"login":who},"reason":reason})
    };
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "me", json!({})));
        w.timeline.insert(
            "PR_1".into(),
            vec![
                added("A_1", T0 + 10, "alice"),
                removed("X_1", T0 + 20, "github-merge-queue", "failed_checks"),
                added("A_2", T0 + 30, "bob"),
                removed("X_2", T0 + 40, "bob", "manual"),
                added("A_3", T0 + 50, "carol"),
                removed("X_3", T0 + 60, "github-merge-queue", "merged"),
            ],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let x1 = daemon.row("X_1").unwrap();
    assert_eq!(x1["kind"], "merge_queue_removed");
    assert_eq!(x1["text"], "Checks failed · added by alice");
    assert_eq!(x1["actor"], "github-merge-queue");
    assert_eq!(x1["url"], "https://github.com/org/app/pull/1");
    assert_eq!(
        daemon.row("X_2").unwrap()["text"],
        "Removed manually · added by bob"
    );
    assert!(daemon.row("X_3").is_none(), "a merged removal makes no row");
    assert_eq!(daemon.row("A_3").unwrap()["kind"], "merge_queue_added");
    daemon.stop();
}

#[test]
fn approved_reviews_on_my_pr_make_a_row_each_and_a_comment_with_a_body() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "me", json!({})));
        w.timeline.insert(
            "PR_1".into(),
            vec![
                review("R_1", "alice", "APPROVED", T0 + 10, ""),
                review("R_2", "bob", "APPROVED", T0 + 20, "LGTM"),
                review("R_3", "renovate", "APPROVED", T0 + 30, ""),
            ],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    for (id, actor) in [("R_1", "alice"), ("R_2", "bob"), ("R_3", "renovate")] {
        let row = daemon
            .row(&format!("{id}:approved"))
            .unwrap_or_else(|| panic!("{id}"));
        assert_eq!(row["kind"], "approved");
        assert_eq!(row["actor"], actor);
        assert_eq!(row["text"], Value::Null);
        assert_eq!(row["url"], format!("https://github.com/r/{id}"));
    }
    assert_eq!(daemon.row("R_2").unwrap()["kind"], "comment", "the body");
    assert!(daemon.row("R_1").is_none());
    // A bot is a user for the Exclusions, by its GraphQL login (no
    // `[bot]`); a hidden one leaves no row.
    daemon.ok(
        json!({"cmd":"owner_exclusions_set","account":ME,"owner":"org",
        "kind":"user","name":"renovate","state":"hidden"}),
    );
    assert!(daemon.row("R_3:approved").is_none());
    daemon.stop();
}

#[test]
fn notifications_of_a_disabled_owner_are_ignored() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
        w.notifications = vec![notified("org", 1, T0 + 10)];
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.ok(json!({"cmd":"owner_disable","account":ME,"owner":"org"}));
    daemon.clock(T0 + 100);
    assert!(
        github
            .requests()
            .iter()
            .any(|r| r.path.starts_with("/notifications"))
    );
    assert!(
        ops(&github, "Resolve").is_empty(),
        "nothing for the disabled owner"
    );
    assert!(
        ops(&github, "Search")
            .iter()
            .all(|r| !r.vars()["q0"].as_str().unwrap().contains("org:org")),
        "no search of the disabled owner"
    );
    daemon.ok(json!({"cmd":"owner_enable","account":ME,"owner":"org"}));
    github.with(|w| w.prs.clear());
    github.clear_requests();
    daemon.clock(T0 + 200);
    assert!(
        ops(&github, "Resolve").is_empty(),
        "the dropped one is not replayed"
    );
    daemon.stop();
}

#[test]
fn refresh_skips_the_notifications_check_within_the_poll_interval_only() {
    let github = world();
    github.with(|w| w.poll_interval = 60);
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(polls(&github), 1, "no check before: refresh checks");
    daemon.clock(T0 + 30);
    github.clear_requests();
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(polls(&github), 0, "30 s after the check");
    assert!(
        !ops(&github, "Search").is_empty(),
        "the PR search still runs"
    );
    daemon.clock(T0 + 60);
    assert_eq!(polls(&github), 1, "the schedule checks at the interval");
    github.clear_requests();
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(polls(&github), 0, "just checked");
    assert!(!ops(&github, "Search").is_empty());
    daemon.stop();
}

#[test]
fn a_failing_notifications_check_warns_until_a_later_one_succeeds() {
    let github = world();
    github.with(|w| w.prs.push(pr_node("PR_1", "org", 1, "me", json!({}))));
    github.intercept(|req| {
        req.path
            .starts_with("/notifications")
            .then(|| Resp::json(502, json!({})))
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let failed = warning(&daemon, ME, "fetch_failed");
    assert_eq!(failed["until"], T0 + 160);
    assert_eq!(
        daemon.account(ME)["updated_at"],
        T0 + 100,
        "fetching went on"
    );
    assert_eq!(daemon.cards().len(), 1);
    github.clear_overrides();
    daemon.clock(T0 + 160);
    assert!(kinds(&daemon, ME).is_empty(), "{:?}", daemon.account(ME));
    daemon.stop();
}

#[test]
fn the_poll_interval_holds_across_a_restart() {
    let github = world();
    github.with(|w| w.poll_interval = 60);
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(polls(&github), 1);
    daemon.stop();

    github.clear_requests();
    let daemon = start_at(dir.path(), &github, T0 + 30);
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(polls(&github), 0, "restarted within the interval");
    assert!(
        !ops(&github, "Search").is_empty(),
        "the PR search still runs"
    );
    daemon.stop();

    github.clear_requests();
    let daemon = start_at(dir.path(), &github, T0 + 60);
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(polls(&github), 1, "restarted after the interval");
    daemon.stop();
}

/// The shapes seen on bufferings-hello/hello-merge-queue#10 (2026-11-05):
/// a conversation comment and an inline comment that mention the viewer
/// with a `user-mention` link, and a Quote reply whose quoted mention lost
/// the class. No MENTIONED_EVENT is read.
#[test]
fn mentions_come_from_the_links_in_the_posts() {
    let github = world();
    let author = json!({"__typename":"User","login":"bufferings-test"});
    let mention = "<p><a class=\"user-mention notranslate\" data-hovercard-type=\"user\" href=\"https://github.com/me\">@me</a> test</p>";
    let quote = "<blockquote><p><a href=\"https://github.com/me\">@me</a> inline test</p></blockquote><p>ok</p>";
    github.with(|w| {
        w.prs.push(pr_node("PR_10", "org", 10, "me", json!({})));
        w.timeline.insert(
            "PR_10".into(),
            vec![issue_comment("IC_1", "bufferings-test", T0 + 15, mention)],
        );
        let inline = |id: &str, at: i64, html: &str| {
            json!({"id":id,"url":format!("https://github.com/r/{id}"),"createdAt":iso(at),
                   "bodyText":format!("text {id}"),"bodyHTML":html,"author":author})
        };
        w.threads.insert(
            "PR_10".into(),
            vec![json!({"id":"T_1","comments":[
                inline("RC_1", T0 + 20, mention),
                inline("RC_2", T0 + 30, quote)
            ]})],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    daemon.clock(T0 + 100);
    let mut rows: Vec<(String, String)> = daemon.ok(json!({"cmd":"activity"}))["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["id"].as_str().unwrap().into(),
                r["kind"].as_str().unwrap().into(),
            )
        })
        .collect();
    rows.sort();
    assert_eq!(
        rows,
        [
            (rid("IC_1"), "mentioned".to_string()),
            (rid("RC_1"), "mentioned".to_string()),
            (rid("RC_2"), "reply_mentioned".to_string()),
        ],
        "the quote reply is a reply in the thread the mention started"
    );
    let events = ops(&github, "Events").remove(0);
    assert!(!events.query().contains("MENTIONED_EVENT"));
    daemon.stop();
}

#[test]
fn without_public_nothing_is_searched_or_shown_for_unregistered_owners() {
    let github = world();
    github.with(|w| w.prs.push(pr_node("PR_9", "stranger", 9, "me", json!({}))));
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    add_account(&daemon, ACCOUNT, ME, TOKEN);
    add_owner(&daemon, ME, "org");
    daemon.clock(T0 + 100);
    let requests = github.requests();
    assert!(!requests.is_empty());
    assert!(
        requests
            .iter()
            .all(|r| !r.body.to_string().contains("is:public")),
        "no Public search"
    );
    assert!(daemon.cards().is_empty());
    daemon.stop();
}

#[test]
fn owner_lookup_and_owner_add_read_the_kind_and_the_numeric_id() {
    let github = world();
    github.with(|w| {
        w.owners.insert("someone".into(), "User".into());
        w.owner_ids.insert("someone".into(), 7);
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    add_account(&daemon, ACCOUNT, ME, TOKEN);
    let found = daemon.ok(json!({"cmd":"owner_lookup","account":ME,"owner":"ORG"}));
    assert_eq!(found["owner"], "org");
    assert_eq!(found["kind"], "org");
    assert_eq!(found["id"], 100);
    let lookup = github
        .requests()
        .into_iter()
        .find(|r| r.path == "/users/ORG")
        .expect("asked GitHub");
    assert_eq!(lookup.method, "GET");
    assert_eq!(lookup.token, TOKEN, "with the account's token");
    assert!(
        daemon.account(ME)["owners"].as_array().unwrap().is_empty(),
        "lookup adds nothing"
    );
    assert_eq!(
        daemon.ok(json!({"cmd":"owner_lookup","account":ME,"owner":"someone"}))["kind"],
        "user"
    );
    let missing = daemon.request(json!({"cmd":"owner_lookup","account":ME,"owner":"nobody"}));
    assert_eq!(missing["code"], "not_found");
    assert_eq!(missing["error"], "Owner not found");
    for bad in ["", "a/b", "-x", "x y", "../user", "public"] {
        assert_eq!(
            daemon.code(json!({"cmd":"owner_lookup","account":ME,"owner":bad})),
            "invalid",
            "{bad:?}"
        );
    }
    assert_eq!(
        daemon.code(json!({"cmd":"owner_lookup","account":"nobody","owner":"org"})),
        "not_found"
    );

    // owner_add stores what the lookup found.
    let added = daemon.ok(json!({"cmd":"owner_add","account":ME,"owner":"Someone"}));
    let owner = &added["account"]["owners"][0];
    assert_eq!(owner["name"], "someone", "GitHub's spelling");
    assert_eq!(owner["kind"], "user");
    assert_eq!(owner["github_id"], 7);
    assert_eq!(owner["enabled"], true);
    assert_eq!(owner["notify"], true);
    assert_eq!(owner["skip_drafts"], true);
    assert_eq!(
        daemon.request(json!({"cmd":"owner_add","account":ME,"owner":"someone"}))["code"],
        "invalid"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"owner_add","account":ME,"owner":"nobody"})),
        "not_found"
    );
    let public = daemon.ok(json!({"cmd":"owner_add","account":ME,"owner":"PUBLIC"}));
    let names: Vec<&str> = public["account"]["owners"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["kind"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["user", "public"], "Public last");
    assert_eq!(public["account"]["owners"][1]["github_id"], Value::Null);

    // GitHub out of reach, and other failures.
    github.intercept(|req| {
        req.path
            .starts_with("/users/")
            .then(|| Resp::json(502, json!({})))
    });
    assert_eq!(
        daemon.code(json!({"cmd":"owner_add","account":ME,"owner":"org"})),
        "unreachable"
    );
    github.clear_overrides();
    github.intercept(|req| {
        req.path
            .starts_with("/users/")
            .then(|| Resp::json(418, json!({})))
    });
    let other = daemon.request(json!({"cmd":"owner_lookup","account":ME,"owner":"org"}));
    assert_eq!(other["code"], "internal");
    assert!(
        other["error"]
            .as_str()
            .unwrap()
            .starts_with("cannot look the owner up"),
        "{other}"
    );
    daemon.stop();
}

#[test]
fn owner_lookup_and_add_of_an_account_without_a_token_are_refused() {
    // DESIGN.md, "Add owner…": GitHub is asked with the account's token
    // only; an account without one is `invalid` and nothing is asked.
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    daemon.ok(json!({"cmd":"dev_account_add","id":"1001","login":"me"}));
    for cmd in ["owner_lookup", "owner_add"] {
        let answer = daemon.request(json!({"cmd":cmd,"account":ME,"owner":"org"}));
        assert_eq!(answer["code"], "invalid", "{cmd}: {answer}");
        assert_eq!(answer["error"], "Account has no token");
    }
    assert!(
        !github
            .requests()
            .iter()
            .any(|r| r.path.starts_with("/users/")),
        "nothing asked without a token"
    );
    daemon.ok(json!({"cmd":"owner_add","account":ME,"owner":"public"}));
    daemon.stop();
}

#[test]
fn a_failed_first_account_add_sends_keychain_changed_and_recovers_after_refresh() {
    // Stage 5, 2-1 and 2-2: with no account yet, a Keychain error on the
    // first `account_add` is announced before the answer, and `refresh`
    // reads the item again although there is no account.
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let path = keychain(dir.path());
    std::fs::create_dir(&path).unwrap();
    let daemon = start(dir.path(), &github);
    let mut cli = daemon.subscribe("cli");
    assert_eq!(cli.snapshot()["keychain"], "ok");
    assert_eq!(
        daemon.code(json!({"cmd":"account_add","token":TOKEN})),
        "keychain_unavailable"
    );
    // Well before the 30-second periodic pass, which would also send it.
    assert_eq!(
        cli.until_within(SOON, |e| e["event"] == "keychain_changed"),
        json!({"event":"keychain_changed","keychain":"unavailable"})
    );
    assert!(daemon.accounts().is_empty());
    std::fs::remove_dir(&path).unwrap();
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(
        cli.until(|e| e["event"] == "keychain_changed"),
        json!({"event":"keychain_changed","keychain":"ok"})
    );
    let added = daemon.ok(json!({"cmd":"account_add","token":TOKEN}));
    assert_eq!(added["account"]["login"], ME);
    daemon.stop();
}

#[test]
fn token_test_tells_a_rate_limit_and_an_http_error_apart_from_no_connection() {
    // Stage 5, 3-11 and S4-2-4.
    let github = world();
    github.intercept(|req| {
        (req.path == "/user").then(|| Resp::json(404, json!({"message":"Not Found"})))
    });
    github.intercept(|req| {
        req.path.starts_with("/notifications").then(|| {
            Resp::json(403, json!({"message":"API rate limit exceeded"}))
                .header("x-ratelimit-remaining", "0")
                .header("x-ratelimit-reset", (T0 + 3600).to_string())
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    let answer = daemon.ok(json!({"cmd":"token_test","token":TOKEN}));
    assert_eq!(
        test_items(&answer),
        [
            item("Account", "ok", ME),
            item("Scopes", "failed", "Failed (HTTP 404)"),
            item("Notifications", "cant_check", "Can't check (rate limited)"),
            item(
                "Team membership",
                "cant_check",
                "Can't check (rate limited)"
            ),
        ]
    );
    daemon.stop();
}

#[test]
fn a_pasted_token_test_records_no_usage_on_the_account() {
    // Stage 5, 3-12: DESIGN.md, "Token registration and test".
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    assert_eq!(daemon.account(ME)["rate_limit"], Value::Null);
    daemon.ok(json!({"cmd":"token_test","account":ME,"token":TOKEN}));
    let account = daemon.account(ME);
    assert_eq!(account["rate_limit"], Value::Null, "a pasted token");
    assert_eq!(account["token"]["last_test"], Value::Null);
    daemon.ok(json!({"cmd":"token_test","account":ME}));
    assert_ne!(
        daemon.account(ME)["rate_limit"],
        Value::Null,
        "the saved token"
    );
    daemon.stop();
}

#[test]
fn a_failed_token_set_sends_keychain_changed_at_once() {
    // Stage 5, 2-2, the `token_set` path: the item becomes unreadable after
    // the account was saved; the failure is announced before the answer.
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let path = keychain(dir.path());
    std::fs::remove_file(&path).unwrap();
    std::fs::create_dir(&path).unwrap();
    let mut cli = daemon.subscribe("cli");
    assert_eq!(cli.snapshot()["keychain"], "ok");
    assert_eq!(
        daemon.code(json!({"cmd":"token_set","account":ME,"token":TOKEN})),
        "keychain_unavailable"
    );
    assert_eq!(
        cli.until_within(SOON, |e| e["event"] == "keychain_changed"),
        json!({"event":"keychain_changed","keychain":"unavailable"})
    );
    daemon.stop();
}

#[test]
fn token_test_of_a_rate_limited_account_query() {
    // DESIGN.md, "Token registration and test": `✗ Rate limited`, and every
    // other item `Can't check`.
    let github = world();
    github.intercept(|req| {
        (req.op.as_deref() == Some("Viewer")).then(|| {
            Resp::json(403, json!({"message":"API rate limit exceeded"}))
                .header("x-ratelimit-remaining", "0")
                .header("x-ratelimit-reset", (T0 + 3600).to_string())
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    let answer = daemon.ok(json!({"cmd":"token_test","token":TOKEN}));
    assert_eq!(
        test_items(&answer),
        [
            item("Account", "failed", "Rate limited"),
            item("Scopes", "cant_check", "Can't check"),
            item("Notifications", "cant_check", "Can't check"),
            item("Team membership", "cant_check", "Can't check"),
        ]
    );
    daemon.stop();
}

#[test]
fn the_owner_check_compares_the_numeric_id_not_the_login() {
    // DESIGN.md, "Tokens": the account is GitHub's numeric user id. A token
    // of the same id under a new login is the same account; a token with
    // the same login but another id belongs to someone else.
    let github = world();
    github.with(|w| {
        w.logins.insert("ghp_renamed".into(), "me-renamed".into());
        w.ids.insert("ghp_renamed".into(), 1001);
        w.logins.insert("ghp_impostor".into(), ME.into());
        w.ids.insert("ghp_impostor".into(), 4242);
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    setup(&daemon);
    let wrong = daemon.request(json!({"cmd":"token_set","account":ME,"token":"ghp_impostor"}));
    assert_eq!(wrong["code"], "invalid");
    assert_eq!(wrong["error"], "Belongs to me");
    daemon.ok(json!({"cmd":"token_set","account":ME,"token":"ghp_renamed"}));
    // The test of the saved token follows the new login.
    let same = daemon.request(json!({"cmd":"account_add","token":"ghp_renamed"}));
    assert_eq!(same["code"], "invalid");
    assert_eq!(same["error"], "me-renamed is already added");
    let other = daemon.ok(json!({"cmd":"account_add","token":"ghp_impostor"}));
    assert_eq!(other["account"]["id"], "4242");
    // Only numeric ids are asked for; the next-id header is never sent.
    for req in github.requests() {
        assert!(
            !req.headers.contains_key("x-github-next-global-id"),
            "{req:?}"
        );
        if req.op.as_deref() == Some("Viewer") {
            assert!(req.query().contains("databaseId"), "{}", req.query());
        }
    }
    daemon.stop();
}

#[test]
fn a_viewer_without_a_database_id_is_an_internal_error() {
    let github = world();
    github.intercept(|req| {
        (req.op.as_deref() == Some("Viewer")).then(|| {
            Resp::json(
                200,
                json!({"data":{"viewer":{"databaseId":null,"login":"me"}}}),
            )
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    let answer = daemon.request(json!({"cmd":"account_add","token":TOKEN}));
    assert_eq!(answer["code"], "internal", "{answer}");
    assert!(
        answer["error"].as_str().unwrap().contains("numeric id"),
        "{answer}"
    );
    assert!(daemon.accounts().is_empty());
    // GitHub answered: the test says so instead of "Couldn't reach GitHub".
    let test = daemon.ok(json!({"cmd":"token_test","token":TOKEN}));
    assert_eq!(
        test_items(&test),
        [
            item("Account", "failed", "Failed (no numeric id)"),
            item("Scopes", "cant_check", "Can't check"),
            item("Notifications", "cant_check", "Can't check"),
            item("Team membership", "cant_check", "Can't check"),
        ]
    );
    daemon.stop();
}

#[test]
fn token_set_with_a_new_login_writes_it_to_the_keychain_item() {
    // DESIGN.md, "Tokens": the Keychain item follows the login, at once on
    // `token_set` and still after `reset` brings the account back from it.
    let github = world();
    github.with(|w| {
        w.logins.insert("ghp_me_new".into(), "me-new".into());
        w.ids.insert("ghp_me_new".into(), 1001);
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    daemon.ok(json!({"cmd":"account_add","token":TOKEN}));
    let saved_login = || {
        let item: Value =
            serde_json::from_str(&std::fs::read_to_string(keychain(dir.path())).unwrap()).unwrap();
        (
            item["accounts"][0]["id"].as_str().unwrap().to_string(),
            item["accounts"][0]["login"].as_str().unwrap().to_string(),
        )
    };
    assert_eq!(saved_login(), ("1001".to_string(), "me".to_string()));
    daemon.ok(json!({"cmd":"token_set","account":ME,"token":"ghp_me_new"}));
    assert_eq!(saved_login(), ("1001".to_string(), "me-new".to_string()));
    assert_eq!(daemon.accounts()[0]["login"], "me-new");
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(saved_login().1, "me-new");
    daemon.stop();
    std::fs::write(dir.path().join("state.db"), vec![0xAB; 8192]).unwrap();
    for side in ["state.db-wal", "state.db-shm"] {
        let _ = std::fs::remove_file(dir.path().join(side));
    }
    let daemon = start(dir.path(), &github);
    daemon.ok(json!({"cmd":"reset"}));
    daemon.ok(json!({"cmd":"refresh"}));
    let accounts = daemon.accounts();
    assert_eq!(accounts[0]["id"], "1001");
    assert_eq!(accounts[0]["login"], "me-new");
    assert_eq!(saved_login(), ("1001".to_string(), "me-new".to_string()));
    daemon.stop();
}
