//! The real daemon fetching from the fake GitHub with a file Keychain.
//! Ordering comes from `refresh` and `dev_clock_set`, which answer after the
//! fetch is applied; nothing sleeps. docs/tasks/M2.md, "Tests".
#![cfg(feature = "dev-ingest")]

mod common;
mod fake_github;

use common::*;
use fake_github::*;
use serde_json::{Value, json};
use std::path::Path;
use std::process::Stdio;

const CLASSIC: &str = "ghp_classic_SECRET_1";
const ORG_TOKEN: &str = "github_pat_org_SECRET_2";
const PUBLIC_TOKEN: &str = "github_pat_public_SECRET_3";

fn keychain(dir: &Path) -> std::path::PathBuf {
    dir.join("keychain.json")
}

fn start(dir: &Path, github: &FakeGitHub) -> TestDaemon {
    let mut command = command(dir);
    command
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", keychain(dir))
        .env("SHIIBAR_GH_DEV_GITHUB_URL", &github.url);
    TestDaemon::spawn(dir, command)
}

/// The world most tests start from: three tokens of `me`, owner `org`.
fn world() -> FakeGitHub {
    let github = FakeGitHub::start();
    github.with(|w| {
        for token in [CLASSIC, ORG_TOKEN, PUBLIC_TOKEN] {
            w.logins.insert(token.into(), "me".into());
        }
        w.owners.insert("org".into(), "Organization".into());
    });
    github
}

fn set_tokens(daemon: &TestDaemon) {
    daemon.ok(json!({"cmd":"scope_add","owner":"org"}));
    daemon.ok(json!({"cmd":"token_set","target":"notifications","token":CLASSIC}));
    daemon.ok(json!({"cmd":"token_set","target":"org","token":ORG_TOKEN}));
    daemon.ok(json!({"cmd":"token_set","target":"public","token":PUBLIC_TOKEN}));
}

fn kinds(daemon: &TestDaemon, scope: &str) -> Vec<String> {
    daemon.scope(scope)["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["kind"].as_str().unwrap().to_string())
        .collect()
}

fn warning(daemon: &TestDaemon, scope: &str, kind: &str) -> Value {
    daemon.scope(scope)["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["kind"] == kind)
        .cloned()
        .unwrap_or_else(|| panic!("no {kind} on {scope}"))
}

/// The PRs of the token-to-list test, as the fake GitHub holds them.
fn seed(github: &FakeGitHub) {
    github.with(|w| {
        w.prs.push(pr_node(
            "PR_1",
            "org",
            1,
            "alice",
            json!({"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"me"}}]}}),
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
                json!({"__typename":"MentionedEvent","id":"M_1","createdAt":iso(T0 + 30),"actor":{"login":"me"}}),
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
        "viewer":"me","missing_pr_ids":[],
        "prs":[
            pr("PR_1", 1, "alice", json!({"requested_me":true})),
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
fn from_token_set_to_list_the_rows_match_a_dev_ingest() {
    let github = world();
    seed(&github);
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    let mut app = daemon.subscribe("app");
    app.snapshot();
    daemon.clock(T0 + 100);
    let fetched_cards = daemon.cards();
    let fetched_note = app.notification();

    // The same state injected by hand into a daemon without GitHub.
    let other = tempfile::tempdir().unwrap();
    let injected = TestDaemon::start(other.path());
    injected.ok(json!({"cmd":"scope_add","owner":"org"}));
    let mut app2 = injected.subscribe("app");
    app2.snapshot();
    injected.clock(T0 + 100);
    injected.ok(json!({"cmd":"dev_ingest","ingest":seed_ingest()}));
    let injected_cards = injected.cards();
    let injected_note = app2.notification();

    assert_eq!(fetched_cards.len(), 2);
    assert_eq!(
        fetched_cards, injected_cards,
        "the same rows, unread and done"
    );
    let strip = |mut n: Value| {
        n["id"] = json!(null);
        n
    };
    assert_eq!(strip(fetched_note.clone()), strip(injected_note));
    assert_eq!(fetched_note["title"], "org · 3 new events");
    let rows: Vec<&Value> = fetched_cards
        .iter()
        .flat_map(|c| c["rows"].as_array().unwrap())
        .collect();
    assert!(rows.iter().all(|r| r["unread"] == true));
    assert!(daemon.scope("org")["kind"] == "org");
    assert_eq!(daemon.scope("org")["updated_at"], T0 + 100);
    assert!(
        kinds(&daemon, "org").is_empty(),
        "{:?}",
        daemon.scope("org")
    );
    // Read-only: GET for REST, queries for GraphQL.
    for req in github.requests() {
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
    daemon.stop();
    injected.stop();
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
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    let polls = |github: &FakeGitHub| -> Vec<fake_github::Req> {
        github
            .requests()
            .into_iter()
            .filter(|r| r.path.starts_with("/notifications"))
            .collect()
    };
    let first = polls(&github);
    assert_eq!(first.len(), 1);
    assert!(first[0].path.contains("all=true") && first[0].path.contains("per_page=50"));
    assert!(!first[0].headers.contains_key("if-modified-since"));
    assert_eq!(
        first[0].token, CLASSIC,
        "only the classic PAT reads notifications"
    );
    assert!(
        github
            .requests()
            .iter()
            .any(|r| r.op.as_deref() == Some("Resolve")),
        "a notified PR is looked up by owner, name and number"
    );

    github.clear_requests();
    daemon.clock(T0 + 160);
    assert!(polls(&github).is_empty(), "within X-Poll-Interval");
    daemon.clock(T0 + 220);
    let second = polls(&github);
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
    let status = daemon.ok(json!({"cmd":"settings_status"}));
    assert_eq!(status["api_usage"]["notifications_poll_interval"], 120);
    assert_eq!(status["api_usage"]["graphql_remaining"], 4999);
    assert_eq!(status["api_usage"]["rest_remaining"], 4990);
    assert!(status["api_usage"]["cost_per_poll"].as_i64().unwrap() > 0);
    daemon.stop();
}

#[test]
fn a_secondary_limit_stops_every_fetch_for_retry_after_then_resumes() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    github.intercept(|req| {
        (req.op.as_deref() == Some("Scope")).then(|| {
            Resp::json(
                403,
                json!({"message":"You have exceeded a secondary rate limit."}),
            )
            .header("retry-after", "120")
        })
    });
    daemon.clock(T0 + 100);
    for scope in ["org", "public"] {
        let limited = warning(&daemon, scope, "rate_limited");
        assert_eq!(limited["until"], T0 + 220, "{scope}");
    }
    github.clear_overrides();
    github.clear_requests();
    let answer = daemon.ok(json!({"cmd":"refresh"}));
    assert!(
        answer["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|w| w["kind"] == "rate_limited" && w["until"] == T0 + 220)
    );
    daemon.clock(T0 + 219);
    assert!(
        github.requests().is_empty(),
        "nothing, notifications included"
    );
    daemon.clock(T0 + 220);
    assert!(!github.requests().is_empty(), "resumes by itself");
    assert!(
        kinds(&daemon, "org").is_empty(),
        "{:?}",
        daemon.scope("org")
    );
    daemon.stop();
}

#[test]
fn an_exhausted_primary_limit_waits_for_its_reset() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    github.intercept(|req| {
        req.path.starts_with("/notifications").then(|| {
            Resp::json(403, json!({"message":"API rate limit exceeded"}))
                .header("x-ratelimit-remaining", "0")
                .header("x-ratelimit-reset", (T0 + 900).to_string())
        })
    });
    daemon.clock(T0 + 100);
    assert_eq!(warning(&daemon, "org", "rate_limited")["until"], T0 + 900);
    github.clear_overrides();
    github.clear_requests();
    daemon.clock(T0 + 899);
    assert!(github.requests().is_empty());
    daemon.clock(T0 + 900);
    assert!(!github.requests().is_empty());
    daemon.stop();
}

#[test]
fn the_cost_cap_stops_fetching_and_refresh_answers_at_once() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.ok(json!({"cmd":"config_set","key":"graphql_cost_cap","value":100}));
    github.intercept(|req| {
        (req.op.as_deref() == Some("Viewer")).then(|| {
            Resp::json(
                200,
                json!({"data":{"viewer":{"login":"me"},
                "rateLimit":{"cost":100,"limit":5000,"remaining":4000,"resetAt":iso(T0 + 3600)}}}),
            )
        })
    });
    daemon.clock(T0 + 100);
    let limited = warning(&daemon, "org", "rate_limited");
    assert_eq!(
        limited["until"],
        T0 + 100 + 3600,
        "when the hour's cost falls below the cap"
    );
    github.clear_requests();
    daemon.ok(json!({"cmd":"refresh","scope":"org"}));
    assert!(github.requests().is_empty(), "no fetch while stopped");
    daemon.stop();
}

#[test]
fn tokens_never_reach_the_log_the_database_or_an_answer() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("daemon.log");
    let mut command = command(dir.path());
    command
        .env("SHIIBAR_GH_LOG", "debug")
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", keychain(dir.path()))
        .env("SHIIBAR_GH_DEV_GITHUB_URL", &github.url)
        .stderr(Stdio::from(std::fs::File::create(&log).unwrap()));
    let daemon = TestDaemon::spawn(dir.path(), command);
    set_tokens(&daemon);
    github.with(|w| w.unauthorized.insert(ORG_TOKEN.into()));
    let mut answers = vec![
        daemon.request(json!({"cmd":"token_set","target":"nobody","token":"SECRET_4"})),
        daemon.request(json!({"cmd":"token_set","target":"org","token":""})),
        daemon.raw(r#"{"cmd":"token_set","target":"org","token":12345678}"#),
        daemon.raw(r#"{"cmd":"token_set","target":"org","token":"SECRET_5","x":}"#),
        daemon.request(json!({"cmd":"token_test","target":"org","token":"SECRET_6"})),
        daemon.request(json!({"cmd":"token_test","target":"org"})),
        daemon.request(json!({"cmd":"token_test","target":"notifications"})),
        daemon.request(json!({"cmd":"token_test","target":"nobody","token":"SECRET_7"})),
        daemon.request(json!({"cmd":"refresh"})),
        daemon.request(json!({"cmd":"settings_status"})),
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
        "SECRET_1", "SECRET_2", "SECRET_3", "SECRET_4", "SECRET_5", "SECRET_6", "SECRET_7",
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
}

#[test]
fn a_failing_fetch_keeps_the_content_and_a_401_stops_only_its_scope() {
    let github = world();
    seed(&github);
    github.with(|w| w.prs.push(pr_node("PR_9", "someone", 9, "me", json!({}))));
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    assert_eq!(daemon.cards().len(), 3);

    github.intercept(|req| {
        (req.token == ORG_TOKEN && req.op.as_deref() == Some("Status"))
            .then(|| Resp::json(502, json!({})))
    });
    daemon.clock(T0 + 200);
    let failed = warning(&daemon, "org", "fetch_failed");
    assert_eq!(failed["until"], T0 + 260, "the next interval");
    assert_eq!(failed["token"], "scope");
    assert_eq!(daemon.cards().len(), 3, "the last content stays");
    assert_eq!(daemon.scope("org")["updated_at"], T0 + 100);
    assert_eq!(
        daemon.scope("public")["updated_at"],
        T0 + 200,
        "other scopes go on"
    );

    github.clear_overrides();
    github.with(|w| w.unauthorized.insert(ORG_TOKEN.into()));
    daemon.clock(T0 + 300);
    assert_eq!(kinds(&daemon, "org"), ["token_invalid"]);
    assert_eq!(daemon.scope("public")["updated_at"], T0 + 300);
    github.clear_requests();
    daemon.clock(T0 + 400);
    assert!(
        github.by_token(ORG_TOKEN).is_empty(),
        "stopped until the token changes"
    );
    assert!(!github.by_token(PUBLIC_TOKEN).is_empty());
    // refresh tries once more, and stays stopped on another 401.
    daemon.ok(json!({"cmd":"refresh","scope":"org"}));
    assert!(!github.by_token(ORG_TOKEN).is_empty());
    assert_eq!(kinds(&daemon, "org"), ["token_invalid"]);
    // A new token resumes at the next fetch.
    github.with(|w| {
        w.unauthorized.clear();
        w.logins.insert("github_pat_new".into(), "me".into());
    });
    daemon.ok(json!({"cmd":"token_set","target":"org","token":"github_pat_new"}));
    daemon.clock(T0 + 500);
    assert!(kinds(&daemon, "org").is_empty());
    assert_eq!(daemon.scope("org")["updated_at"], T0 + 500);
    daemon.stop();
}

#[test]
fn success_moves_on_and_failed_events_are_fetched_again_from_their_window() {
    let github = world();
    github.with(|w| w.prs.push(pr_node("PR_1", "org", 1, "me", json!({}))));
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    assert_eq!(
        daemon.scope("org")["updated_at"],
        T0 + 100,
        "no events still counts"
    );
    assert_eq!(
        daemon.scope("public")["updated_at"],
        T0 + 100,
        "no PRs still counts"
    );

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
        assert_eq!(daemon.scope("org")["updated_at"], at, "the scope succeeded");
        let named = kinds(&daemon, "org").contains(&"events_fetch_failed".to_string());
        assert_eq!(named, i == 2, "after three failures in a row");
    }
    assert_eq!(
        warning(&daemon, "org", "events_fetch_failed")["message"],
        "org/app#1"
    );
    assert!(daemon.row("C_1").is_none());

    github.clear_overrides();
    github.clear_requests();
    daemon.clock(T0 + 4000);
    let events: Vec<fake_github::Req> = github
        .requests()
        .into_iter()
        .filter(|r| r.op.as_deref() == Some("Events"))
        .collect();
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0].vars()["since"],
        iso(T0 + 100 - 300).max(iso(T0)),
        "the window of the first failure"
    );
    assert!(daemon.row("C_1").is_some(), "nothing was lost");
    assert!(!kinds(&daemon, "org").contains(&"events_fetch_failed".to_string()));
    daemon.stop();
}

#[test]
fn without_the_notifications_token_nothing_is_fetched() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    daemon.ok(json!({"cmd":"scope_add","owner":"org"}));
    daemon.ok(json!({"cmd":"token_set","target":"org","token":ORG_TOKEN}));
    daemon.clock(T0 + 100);
    daemon.ok(json!({"cmd":"refresh"}));
    assert!(github.requests().is_empty());
    for scope in ["org", "public"] {
        let first = &daemon.scope(scope)["warnings"][0];
        assert_eq!(
            (first["kind"].as_str(), first["token"].as_str()),
            (Some("no_token"), Some("notifications"))
        );
    }
    daemon.stop();
}

#[test]
fn a_401_of_the_notifications_token_stops_every_scope() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    github.with(|w| w.unauthorized.insert(CLASSIC.into()));
    daemon.clock(T0 + 100);
    for scope in ["org", "public"] {
        let w = &daemon.scope(scope)["warnings"][0];
        assert_eq!(
            (w["kind"].as_str(), w["token"].as_str()),
            (Some("token_invalid"), Some("notifications"))
        );
    }
    github.clear_requests();
    daemon.clock(T0 + 200);
    assert!(github.requests().is_empty(), "every scope stopped");
    github.with(|w| {
        w.unauthorized.clear();
        w.logins.insert("ghp_new".into(), "me".into());
    });
    daemon.ok(json!({"cmd":"token_set","target":"notifications","token":"ghp_new"}));
    daemon.clock(T0 + 300);
    assert!(kinds(&daemon, "org").is_empty());
    daemon.stop();
}

#[test]
fn a_token_of_another_account_stops_its_scope_until_replaced() {
    let github = world();
    github.with(|w| {
        w.logins.insert(ORG_TOKEN.into(), "someone".into());
        w.prs.push(pr_node("PR_1", "org", 1, "me", json!({})));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    assert_eq!(kinds(&daemon, "org"), ["token_owner_mismatch"]);
    assert!(daemon.cards().is_empty(), "nothing fetched for org");
    assert_eq!(daemon.scope("public")["updated_at"], T0 + 100);
    github.clear_requests();
    daemon.clock(T0 + 200);
    assert!(
        github
            .by_token(ORG_TOKEN)
            .iter()
            .all(|r| r.op.as_deref() == Some("Scope")),
        "only the owner check"
    );
    github.with(|w| w.logins.insert("github_pat_mine".into(), "me".into()));
    daemon.ok(json!({"cmd":"token_set","target":"org","token":"github_pat_mine"}));
    daemon.clock(T0 + 300);
    assert!(kinds(&daemon, "org").is_empty());
    assert_eq!(daemon.cards().len(), 1);
    daemon.stop();
}

#[test]
fn refresh_answers_once_the_fetch_is_applied() {
    let github = world();
    seed(&github);
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    let answer = daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(answer["warnings"], json!([]));
    assert_eq!(daemon.cards().len(), 2, "applied before the answer");
    assert_eq!(
        daemon.code(json!({"cmd":"refresh","scope":"nobody"})),
        "not_found"
    );
    daemon.stop();
}

#[test]
fn token_test_reports_each_item_and_keeps_the_saved_result() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    github.intercept(|req| {
        (req.path.contains("/actions/runs")).then(|| {
            Resp::json(
                403,
                json!({"message":"Resource not accessible by personal access token"}),
            )
            .header("x-accepted-github-permissions", "actions=read")
        })
    });
    let answer = daemon.ok(json!({"cmd":"token_test","target":"org"}));
    let items: Vec<(String, String)> = answer["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            (
                r["item"].as_str().unwrap().into(),
                r["outcome"].as_str().unwrap().into(),
            )
        })
        .collect();
    assert_eq!(
        items,
        [
            ("PRs, reviews, comments".to_string(), "ok".to_string()),
            ("Checks".to_string(), "failed".to_string()),
            ("Behind base".to_string(), "ok".to_string()),
            ("Team membership".to_string(), "ok".to_string()),
            ("Merge queue".to_string(), "ok".to_string()),
        ]
    );
    assert_eq!(answer["results"][1]["missing"], "actions=read");
    assert_eq!(answer["owner"], "me");
    assert_eq!(answer["owner_mismatch"], false);
    assert_eq!(daemon.scope("org")["kind"], "org");
    let status = daemon.ok(json!({"cmd":"settings_status"}));
    let org = status["tokens"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["target"] == "org")
        .unwrap()
        .clone();
    assert_eq!(org["last_test"]["results"], answer["results"]);
    assert_eq!(org["registered"], true);

    // A piped token is tested without being saved.
    github.with(|w| w.logins.insert("github_pat_other".into(), "someone".into()));
    let answer = daemon.ok(json!({"cmd":"token_test","target":"org","token":"github_pat_other"}));
    assert_eq!(answer["owner_mismatch"], true);
    let classic = daemon.ok(json!({"cmd":"token_test","target":"notifications"}));
    let items: Vec<&str> = classic["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["item"].as_str().unwrap())
        .collect();
    assert_eq!(items, ["Notifications", "Team membership", "Scopes"]);
    assert!(
        classic["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["outcome"] == "ok")
    );
    let status = daemon.ok(json!({"cmd":"settings_status"}));
    let classic = status["tokens"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["target"] == "notifications")
        .unwrap()
        .clone();
    assert_eq!(classic["scopes"], json!(["notifications", "read:org"]));
    daemon.stop();
}

#[test]
fn a_token_set_for_an_unknown_owner_is_not_found() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    assert_eq!(
        daemon.code(json!({"cmd":"token_set","target":"nobody","token":"x"})),
        "not_found"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"token_set","target":"public","token":"  "})),
        "invalid"
    );
    assert_eq!(
        daemon.code(json!({"cmd":"scope_add","owner":"Notifications"})),
        "invalid"
    );
    daemon.stop();
}

#[test]
fn reset_restores_scopes_from_the_keychain_and_remove_deletes_the_token() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        keychain(dir.path()),
        json!({"notifications":"a","public":"b","scope:acme":"c"}).to_string(),
    )
    .unwrap();
    std::fs::write(dir.path().join("state.db"), vec![0xAB; 8192]).unwrap();
    let daemon = start(dir.path(), &github);
    let snapshot = daemon.subscribe("cli").snapshot();
    assert_eq!(snapshot["db_unreadable"], true);
    let ids: Vec<&str> = snapshot["scopes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["id"].as_str().unwrap())
        .collect();
    assert_eq!(
        ids,
        ["acme", "public"],
        "the unreadable state shows what reset gives"
    );
    assert!(
        snapshot["scopes"]
            .as_array()
            .unwrap()
            .iter()
            .all(|s| s["badge"] == 0 && s["dot"] == false)
    );
    daemon.ok(json!({"cmd":"reset"}));
    let ids: Vec<String> = daemon
        .scopes()
        .iter()
        .map(|s| s["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids, ["acme", "public"]);
    let status = daemon.ok(json!({"cmd":"settings_status"}));
    assert!(
        status["tokens"]
            .as_array()
            .unwrap()
            .iter()
            .all(|t| t["registered"] == true),
        "{status}"
    );

    daemon.ok(json!({"cmd":"scope_remove","owner":"acme"}));
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(keychain(dir.path())).unwrap()).unwrap();
    assert_eq!(saved, json!({"notifications":"a","public":"b"}));
    daemon.ok(json!({"cmd":"scope_add","owner":"acme"}));
    assert_eq!(
        kinds(&daemon, "acme"),
        ["no_token"],
        "set the token again after adding"
    );
    daemon.ok(json!({"cmd":"token_set","target":"ACME","token":"d"}));
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(keychain(dir.path())).unwrap()).unwrap();
    assert_eq!(saved["scope:acme"], "d");
    daemon.stop();
}

#[test]
fn a_scope_without_a_recorded_token_is_removed_without_the_keychain() {
    // No Keychain at all: a delete would fail, so none is attempted.
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    daemon.ok(json!({"cmd":"scope_add","owner":"acme"}));
    daemon.ok(json!({"cmd":"scope_remove","owner":"acme"}));
    assert_eq!(
        daemon.code(json!({"cmd":"token_set","target":"public","token":"x"})),
        "internal"
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
        daemon.code(json!({"cmd":"token_set","target":"notifications","token":"x"})),
        "internal"
    );
    daemon.ok(json!({"cmd":"refresh"}));
    assert_eq!(
        daemon.code(json!({"cmd":"token_test","target":"notifications","token":"x"})),
        "internal"
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

#[test]
fn a_manual_unsnooze_clears_what_went_undelivered_before_the_snooze() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(dir.path());
    daemon.ok(json!({"cmd":"scope_add","owner":"org"}));
    daemon.ingest(
        vec![pr("PR_1", "alice")],
        vec![event("E_1", "PR_1", "comment", T0)],
        vec![],
    );
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#1"}));
    daemon.ok(json!({"cmd":"unsnooze","pr":"org/app#1"}));
    let mut app = daemon.subscribe("app");
    app.snapshot();
    // A later notification proves the queue is empty before it.
    daemon.ingest(vec![], vec![event("E_2", "PR_1", "comment", T0)], vec![]);
    let note = app.notification();
    assert_eq!(
        note["rows"],
        json!(["E_2"]),
        "E_1 was cleared by the Unsnooze"
    );
    daemon.stop();
}

#[test]
fn a_version_1_database_migrates_and_its_fetch_state_survives_a_restart() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("state.db");
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch(include_str!("data/schema_v1.sql"))
        .unwrap();
    conn.execute_batch(&format!(
        "INSERT INTO meta VALUES ('last_release_at', '{T0}');
         INSERT INTO scopes VALUES ('public', 0, 1, 1, {T0}, NULL, 0);
         INSERT INTO scopes VALUES ('org', 0, 1, 1, {T0}, NULL, 0);
         INSERT INTO prs VALUES ('PR_1','org','app',1,'u','t','me','main','topic','open',0,'none','none',
           'none',0,NULL,NULL,{T0},0,0,'r','c','b',1,0,0,{T0},'none','none','none',0);
         INSERT INTO pr_rows VALUES ('E_1','PR_1','comment','hi',NULL,'alice','u',{T0},NULL,1,0,0,0,'none');
         PRAGMA user_version = 1;"
    ))
    .unwrap();
    drop(conn);
    let daemon = start(dir.path(), &github);
    assert_eq!(
        daemon.row("E_1").unwrap()["unread"],
        true,
        "v1 rows survive"
    );
    daemon.ok(json!({"cmd":"token_set","target":"notifications","token":CLASSIC}));
    daemon.ok(json!({"cmd":"token_set","target":"org","token":ORG_TOKEN}));
    daemon.ok(json!({"cmd":"config_set","key":"include_team_requests","value":false}));
    daemon.ok(json!({"cmd":"config_set","key":"include_team_requests","value":true}));
    github.with(|w| w.prs.push(pr_node("PR_1", "org", 1, "me", json!({}))));
    daemon.clock(T0 + 100);
    let before = daemon.ok(json!({"cmd":"settings_status"}));
    let scope_before = daemon.scope("org");
    daemon.stop();
    let version: i64 = rusqlite::Connection::open(&db)
        .unwrap()
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 2);

    let daemon = start(dir.path(), &github);
    assert_eq!(
        daemon.ok(json!({"cmd":"settings_status"})),
        before,
        "tokens, usage and poll interval"
    );
    let scope = daemon.scope("org");
    assert_eq!(scope["kind"], "org");
    assert_eq!(scope["updated_at"], scope_before["updated_at"]);
    github.clear_requests();
    daemon.clock(T0 + 200);
    let events: Vec<fake_github::Req> = github
        .requests()
        .into_iter()
        .filter(|r| r.op.as_deref() == Some("Collect"))
        .collect();
    assert!(
        events.is_empty(),
        "what was collected is remembered across the restart"
    );
    daemon.stop();
}

#[test]
fn a_notified_pr_of_a_scope_that_failed_is_fetched_at_the_next_run() {
    let github = world();
    github.with(|w| w.prs.push(pr_node("PR_1", "org", 1, "me", json!({}))));
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    assert_eq!(daemon.cards().len(), 1);

    // A comment GitHub reports only through a notification: the PR's
    // updatedAt stays, so nothing else would fetch its events.
    github.with(|w| {
        w.timeline.insert("PR_1".into(), vec![issue_comment("C_1", "alice", T0 + 150, "")]);
        w.notifications = vec![json!({"updated_at":iso(T0 + 150),"reason":"comment",
            "subject":{"type":"PullRequest","url":"https://api.github.com/repos/org/app/pulls/1"}})];
        w.last_modified = "Fri, 15 Jan 2027 08:02:30 GMT".into();
    });
    github.intercept(|req| {
        (req.token == ORG_TOKEN && req.op.as_deref() == Some("Status"))
            .then(|| Resp::json(502, json!({})))
    });
    daemon.clock(T0 + 200);
    assert!(daemon.row("C_1").is_none());
    assert!(kinds(&daemon, "org").contains(&"fetch_failed".to_string()));

    github.clear_overrides();
    github.clear_requests();
    daemon.clock(T0 + 300);
    let polls: Vec<u16> = github
        .requests()
        .iter()
        .filter(|r| r.path.starts_with("/notifications"))
        .map(|r| u16::from(r.headers.contains_key("if-modified-since")))
        .collect();
    assert_eq!(polls, [1], "the notification is not repeated");
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
    daemon.ok(json!({"cmd":"activity","snoozed":true}))["rows"]
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
    set_tokens(&daemon);
    daemon.ok(json!({"cmd":"config_set","key":"keep_watching_days","value":0}));
    daemon.ok(json!({"cmd":"config_set","key":"drop_after_days","value":1}));
    daemon.clock(T0 + 100);
    assert_eq!(reaction_rows(&daemon), 0, "the first count is the baseline");

    // The card drops, the PR leaves the watch, reactions grow meanwhile.
    let gone = T0 + 2 * DAY;
    daemon.clock(gone);
    daemon.clock(gone + 1);
    assert!(daemon.cards().is_empty());
    github.with(|w| w.reactables.insert("C_ME".into(), reaction_node("C_ME", 5)));
    daemon.clock(gone + 400);
    // An update brings it back; the next run collects it again.
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
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    let compare = github
        .requests()
        .into_iter()
        .find(|r| r.op.as_deref() == Some("Compare"))
        .expect("a compare for the fork");
    assert_eq!(compare.vars()["h0"], "f00d");
    assert_eq!(daemon.cards()[0]["base_status"], "up_to_date");
    daemon.stop();
}

#[test]
fn a_reactions_only_run_checks_the_token_owner_too() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "me", json!({})));
        w.reactables.insert("PR_1".into(), reaction_node("PR_1", 0));
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.ok(json!({"cmd":"config_set","key":"status_interval_minutes","value":10}));
    daemon.ok(json!({"cmd":"config_set","key":"reactions_interval_minutes","value":1}));
    daemon.clock(T0 + 100);
    github.with(|w| w.logins.insert(ORG_TOKEN.into(), "someone".into()));
    github.clear_requests();
    daemon.clock(T0 + 160);
    let ops: Vec<String> = github
        .by_token(ORG_TOKEN)
        .into_iter()
        .filter_map(|r| r.op)
        .collect();
    assert_eq!(
        ops,
        ["Who"],
        "no Reactions query with another account's token"
    );
    assert_eq!(kinds(&daemon, "org"), ["token_owner_mismatch"]);
    daemon.stop();
}

#[test]
fn a_forbidden_part_of_the_events_is_a_permission_warning() {
    let github = world();
    github.with(|w| w.prs.push(pr_node("PR_1", "org", 1, "me", json!({}))));
    github.intercept(|req| {
        (req.op.as_deref() == Some("Events")).then(|| {
            Resp::json(200, json!({
                "data":{"rateLimit":{"cost":1,"limit":5000,"remaining":4999,"resetAt":iso(T0 + 3600)},
                  "nodes":[{"id":"PR_1","url":"https://github.com/org/app/pull/1","createdAt":iso(T0 - 86_400),
                    "bodyHTML":"","bodyText":"","author":{"__typename":"User","login":"me"},
                    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[null]},
                    "reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}]},
                "errors":[{"type":"FORBIDDEN","path":["nodes",0,"timelineItems","nodes",0],
                  "message":"Resource not accessible by personal access token"}]
            }))
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    let missing = warning(&daemon, "org", "permission_missing");
    assert_eq!(missing["token"], "scope");
    assert_eq!(missing["message"], "Missing permission: Merge queue");
    assert_eq!(daemon.scope("org")["updated_at"], T0 + 100, "not a failure");
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
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    daemon.clock(T0 + 200);
    assert!(
        !kinds(&daemon, "org").contains(&"events_fetch_failed".to_string()),
        "two runs, two failures"
    );
    daemon.clock(T0 + 300);
    assert!(kinds(&daemon, "org").contains(&"events_fetch_failed".to_string()));
    daemon.stop();
}

#[test]
fn a_rate_limit_met_by_a_token_test_stops_fetching() {
    let github = world();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    github.intercept(|req| {
        (req.op.as_deref() == Some("Probe")).then(|| {
            Resp::json(
                403,
                json!({"message":"You have exceeded a secondary rate limit."}),
            )
            .header("retry-after", "300")
        })
    });
    assert_eq!(
        daemon.code(json!({"cmd":"token_test","target":"org"})),
        "internal"
    );
    assert_eq!(warning(&daemon, "org", "rate_limited")["until"], T0 + 300);
    github.clear_overrides();
    github.clear_requests();
    daemon.clock(T0 + 100);
    assert!(github.requests().is_empty());
    daemon.stop();
}

#[test]
fn public_team_membership_is_read_with_the_classic_token_page_by_page() {
    let github = world();
    let url = github.url.clone();
    github.intercept(move |req| {
        if req.path.starts_with("/user/teams")
            && req.token == CLASSIC
            && !req.path.contains("page=2")
        {
            let next = format!("<{url}/user/teams?per_page=100&page=2>; rel=\"next\"");
            return Some(
                Resp::json(
                    200,
                    json!([{"id":1,"slug":"a","organization":{"login":"x"}}]),
                )
                .header("Link", next),
            );
        }
        None
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    let pages = github
        .requests()
        .iter()
        .filter(|r| r.path.starts_with("/user/teams"))
        .count();
    assert_eq!(pages, 2, "the Link header's next page is read");
    assert!(kinds(&daemon, "public").is_empty());

    let test = daemon.ok(json!({"cmd":"token_test","target":"public"}));
    let items: Vec<&str> = test["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["item"].as_str().unwrap())
        .collect();
    assert_eq!(
        items,
        [
            "PRs, reviews, comments",
            "Checks",
            "Behind base",
            "Team membership",
            "Merge queue"
        ]
    );
    assert_eq!(test["results"][3]["outcome"], "ok");

    github.clear_overrides();
    github.intercept(|req| {
        req.path
            .starts_with("/user/teams")
            .then(|| Resp::json(403, json!({"message":"Resource not accessible"})))
    });
    daemon.clock(T0 + 200);
    let missing = warning(&daemon, "public", "permission_missing");
    assert_eq!(missing["token"], "notifications");
    assert_eq!(missing["message"], "Missing permission: read:org");
    let test = daemon.ok(json!({"cmd":"token_test","target":"public"}));
    assert_eq!(test["results"][3]["outcome"], "failed");
    assert_eq!(test["results"][3]["missing"], "read:org");
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
    let log = dir.path().join("daemon.log");
    let mut command = command(dir.path());
    command
        .env("SHIIBAR_GH_LOG", "warn")
        .env("SHIIBAR_GH_DEV_NOW", T0.to_string())
        .env("SHIIBAR_GH_DEV_TZ", TZ)
        .env("SHIIBAR_GH_DEV_KEYCHAIN", keychain(dir.path()))
        .env("SHIIBAR_GH_DEV_GITHUB_URL", &github.url)
        .stderr(Stdio::from(std::fs::File::create(&log).unwrap()));
    let daemon = TestDaemon::spawn(dir.path(), command);
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    let pages = github
        .requests()
        .iter()
        .filter(|r| r.op.as_deref() == Some("Page"))
        .count();
    assert_eq!(pages, 9, "ten pages with the first");
    daemon.stop();
    let text = std::fs::read_to_string(&log).unwrap();
    assert!(
        text.contains("shiibar-ghd warn: comments of PR_1 has more than 10 pages"),
        "{text}"
    );
}

#[test]
fn a_refused_merge_queue_read_keeps_the_other_events_and_warns() {
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
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    assert!(daemon.row("C_1").is_some(), "the comment is kept");
    assert!(daemon.row("X_1").is_none(), "the removal needed the queue");
    let missing = warning(&daemon, "org", "permission_missing");
    assert_eq!(missing["message"], "Missing permission: Merge queue");
    assert!(!kinds(&daemon, "org").contains(&"fetch_failed".to_string()));
    daemon.stop();
}

#[test]
fn organization_teams_are_read_past_the_first_hundred() {
    let github = world();
    github.with(|w| {
        w.teams = vec![json!({"databaseId":42,"slug":"core"})];
        w.more_teams = vec![json!({"databaseId":43,"slug":"infra"})];
        let team = json!({"__typename":"Team","databaseId":43,"slug":"infra"});
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
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    // The kind is known after the first run; the team query needs it.
    daemon.clock(T0 + 5);
    daemon.clock(T0 + 100);
    let page = github
        .requests()
        .into_iter()
        .find(|r| r.op.as_deref() == Some("TeamsPage"))
        .expect("the second page of teams");
    assert_eq!(page.vars()["after"], "c1");
    let row = daemon
        .row("RR_1")
        .expect("a request to a team on the second page");
    assert_eq!(row["text"], "for infra team");
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
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    let polls: Vec<fake_github::Req> = github
        .requests()
        .into_iter()
        .filter(|r| r.path.starts_with("/notifications"))
        .collect();
    assert_eq!(polls.len(), 2);
    assert!(polls[1].path.contains("page=2"));
    assert!(
        !polls[1].headers.contains_key("if-modified-since"),
        "only the first page"
    );
    let resolve = github
        .requests()
        .into_iter()
        .find(|r| r.op.as_deref() == Some("Resolve"))
        .unwrap();
    let numbers: Vec<i64> = (0..2)
        .filter_map(|i| resolve.vars()[format!("n{i}")].as_i64())
        .collect();
    assert_eq!(numbers, [1, 2], "both pages' PRs are looked up");
    daemon.stop();
}

#[test]
fn a_refresh_during_a_fetch_waits_for_it_and_both_answer_after_one_fetch() {
    use std::sync::{Arc, Condvar, Mutex};
    let github = world();
    seed(&github);
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
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    let socket = daemon.socket();
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
    let first = send(socket.clone());
    {
        let (lock, cv) = &*gate;
        let mut state = lock.lock().unwrap();
        while !state.0 {
            state = cv.wait(state).unwrap();
        }
    }
    let second = send(socket);
    // The second request is read while the first fetch is held at the gate;
    // round trips on other connections give the daemon time to take it.
    for _ in 0..50 {
        daemon.ok(json!({"cmd":"info"}));
    }
    {
        let (lock, cv) = &*gate;
        lock.lock().unwrap().1 = true;
        cv.notify_all();
    }
    let (a, b) = (first.join().unwrap(), second.join().unwrap());
    assert_eq!(a["ok"], true);
    assert_eq!(b["ok"], true);
    let viewers = github
        .requests()
        .iter()
        .filter(|r| r.op.as_deref() == Some("Viewer"))
        .count();
    assert_eq!(viewers, 1, "one fetch for both");
    assert_eq!(daemon.cards().len(), 2, "applied before either answer");
    daemon.stop();
}

#[test]
fn a_public_team_request_hidden_from_the_public_token_is_read_with_the_classic_token() {
    let github = world();
    let team = json!({"__typename":"Team","databaseId":42,"slug":"core"});
    github.with(|w| {
        w.prs.push(pr_node(
            "PR_1",
            "someone",
            1,
            "alice",
            json!({"reviewRequests":{"nodes":[{"requestedReviewer":null}]}}),
        ));
        w.timeline.insert(
            "PR_1".into(),
            vec![
                json!({"__typename":"ReviewRequestedEvent","id":"RR_1","createdAt":iso(T0 + 10),
                        "actor":{"login":"alice"},"requestedReviewer":null}),
            ],
        );
    });
    let reviewer = team.clone();
    github.intercept(move |req| {
        if req.path.starts_with("/user/teams") {
            return Some(Resp::json(
                200,
                json!([{"id":42,"slug":"core","organization":{"login":"o"}}]),
            ));
        }
        (req.op.as_deref() == Some("Requests")).then(|| {
            assert_eq!(req.token, CLASSIC, "only the classic PAT reads them again");
            Resp::json(
                200,
                json!({"data":{
                "rateLimit":{"cost":1,"limit":5000,"remaining":4999,"resetAt":iso(T0 + 3600)},
                "nodes":[{"id":"PR_1","reviewRequests":{"nodes":[{"requestedReviewer":reviewer}]},
                  "requestEvents":{"nodes":[{"id":"RR_1","createdAt":iso(T0 + 10),
                    "actor":{"login":"alice"},"requestedReviewer":reviewer}]}}]}}),
            )
        })
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    let row = daemon.row("RR_1").expect("the team request");
    assert_eq!(row["text"], "for core team");
    assert_eq!(row["class"], "needs_action", "the team is still asked");
    assert_eq!(daemon.cards()[0]["scope"], "public");
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
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    let x1 = daemon.row("X_1").unwrap();
    assert_eq!(x1["text"], "Checks failed · added by alice");
    assert_eq!(x1["actor"], "github-merge-queue");
    assert_eq!(x1["url"], "https://github.com/org/app/pull/1");
    assert_eq!(
        daemon.row("X_2").unwrap()["text"],
        "Removed manually · added by bob"
    );
    assert!(daemon.row("X_3").is_none(), "a merged removal makes no row");
    assert!(daemon.row("A_3").is_some());
    daemon.stop();
}

#[test]
fn removing_a_scope_moves_its_public_prs_to_public_with_done_and_snooze() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "me", json!({})));
        w.prs.push(pr_node("PR_2", "org", 2, "alice", json!({})));
        w.timeline.insert(
            "PR_1".into(),
            vec![issue_comment("C_1", "alice", T0 + 10, "")],
        );
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.clock(T0 + 100);
    daemon.ok(json!({"cmd":"done","row":"C_1"}));
    daemon.ok(json!({"cmd":"snooze","pr":"org/app#2"}));

    daemon.ok(json!({"cmd":"scope_remove","owner":"org"}));
    github.clear_requests();
    daemon.clock(T0 + 200);
    let search = github
        .requests()
        .into_iter()
        .find(|r| r.op.as_deref() == Some("Scope") && r.token == PUBLIC_TOKEN)
        .unwrap();
    assert!(search.vars()["q0"].as_str().unwrap().contains("is:public"));
    let cards = daemon.cards();
    assert_eq!(cards.len(), 2);
    assert!(cards.iter().all(|c| c["scope"] == "public"), "{cards:?}");
    assert_eq!(daemon.row("C_1").unwrap()["done"], true, "Done comes along");
    let snoozed = cards.iter().find(|c| c["pr"] == "org/app#2").unwrap();
    assert_eq!(snoozed["snoozed"], true, "so does Snooze");

    daemon.ok(json!({"cmd":"scope_add","owner":"org"}));
    let cards = daemon.cards();
    assert!(
        cards.iter().all(|c| c["scope"] == "org"),
        "back under the owner"
    );
    assert_eq!(daemon.row("C_1").unwrap()["done"], true);
    assert_eq!(
        cards.iter().find(|c| c["pr"] == "org/app#2").unwrap()["snoozed"],
        true
    );
    daemon.stop();
}

#[test]
fn notifications_of_a_disabled_scope_are_ignored() {
    let github = world();
    github.with(|w| {
        w.prs.push(pr_node("PR_1", "org", 1, "alice", json!({})));
        w.notifications = vec![notified("org", 1, T0 + 10)];
    });
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path(), &github);
    set_tokens(&daemon);
    daemon.ok(json!({"cmd":"scope_disable","scope":"org"}));
    daemon.clock(T0 + 100);
    assert!(
        github
            .requests()
            .iter()
            .any(|r| r.path.starts_with("/notifications"))
    );
    assert!(
        github.by_token(ORG_TOKEN).is_empty(),
        "nothing for the disabled scope"
    );
    assert!(
        !github
            .requests()
            .iter()
            .any(|r| r.op.as_deref() == Some("Resolve")),
        "not even with another token"
    );
    // Turning it back on does not replay the dropped notification.
    daemon.ok(json!({"cmd":"scope_enable","scope":"org"}));
    github.with(|w| w.prs.clear());
    github.clear_requests();
    daemon.clock(T0 + 200);
    assert!(
        !github
            .requests()
            .iter()
            .any(|r| r.op.as_deref() == Some("Resolve"))
    );
    daemon.stop();
}
