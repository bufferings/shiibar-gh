//! The core's side of fetching: the watch period, `since`, teams,
//! notification summaries, warnings and rate limits, per account.
//! DESIGN.md, "API usage", "Rate limits", "Fetch success and failure" and
//! "Showing warnings".

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use shiibar_ghd::engine::{Engine, missing_scopes};
use shiibar_ghd::github::{CallError, Recorder};
use shiibar_ghd::model::{LimitRec, OwnComment, OwnerKind as Kind, TeamRec};
use shiibar_ghd::plan::*;
use std::collections::BTreeMap;
use support::*;

/// The warning kinds of the default account.
fn kinds(h: &H) -> Vec<String> {
    h.account()
        .warnings
        .iter()
        .map(|w| w.kind.as_text())
        .collect()
}

fn warning(h: &H, kind: WarningKind) -> Option<Warning> {
    h.account().warnings.into_iter().find(|w| w.kind.is(kind))
}

fn plan_of(h: &H, account: &str, forced: bool) -> Plan {
    let due = h.engine.due(account, h.at(), forced);
    h.engine
        .fetch_plan(account, &h.now, due, forced, "t".into())
        .unwrap()
}

fn plan(h: &H, forced: bool) -> Plan {
    plan_of(h, ACCOUNT, forced)
}

fn apply(h: &mut H, outcome: Outcome) {
    apply_to(h, ACCOUNT, outcome);
}

fn apply_to(h: &mut H, account: &str, outcome: Outcome) {
    let now = h.now.clone();
    h.engine.apply_fetch(account, outcome, &now);
}

fn ran(outcome: Outcome) -> Outcome {
    Outcome {
        ran: true,
        ..outcome
    }
}

// ---------------------------------------------------------------- watching

#[test]
fn a_pr_is_watched_while_shown_and_for_the_keep_days_after() {
    let mut h = H::new();
    h.set("keep_watching_days", json!(3));
    h.prs(vec![other("PR_1")]);
    let watched = |h: &H| plan(h, true).prs["PR_1"].watched;
    assert!(watched(&h), "the card shows");
    h.set_time(T0 + 15 * DAY);
    h.tick();
    assert!(!h.visible("PR_1"));
    assert!(watched(&h), "gone just now");
    h.set_time(T0 + 18 * DAY);
    h.tick();
    assert!(watched(&h), "three days after");
    h.set_time(T0 + 18 * DAY + 1);
    h.tick();
    assert!(!watched(&h), "past the keep days");
}

#[test]
fn zero_keep_days_watch_only_while_shown() {
    let mut h = H::new();
    h.set("keep_watching_days", json!(0));
    h.prs(vec![other("PR_1")]);
    h.set_time(T0 + 15 * DAY);
    h.tick();
    assert!(plan(&h, true).prs["PR_1"].watched, "the moment it went");
    h.advance(1);
    h.tick();
    assert!(!plan(&h, true).prs["PR_1"].watched);
}

#[test]
fn a_snoozed_card_counts_as_shown() {
    let mut h = H::new();
    h.set("keep_watching_days", json!(0));
    h.prs(vec![pr("PR_1")]);
    h.snooze(&key("PR_1"));
    h.advance(DAY / 2);
    h.tick();
    assert!(plan(&h, true).prs["PR_1"].watched);
}

#[test]
fn leaving_the_watch_forgets_what_was_collected() {
    let mut h = H::new();
    h.set("keep_watching_days", json!(0));
    h.prs(vec![other("PR_1")]);
    apply(
        &mut h,
        Outcome {
            collected: vec!["PR_1".into()],
            ..Outcome::default()
        },
    );
    assert!(plan(&h, true).prs["PR_1"].collected);
    h.set_time(T0 + 15 * DAY);
    h.tick();
    h.advance(1);
    h.tick();
    let p = plan(&h, true);
    assert!(!p.prs["PR_1"].watched);
    assert!(!p.prs["PR_1"].collected, "a return collects again");
}

#[test]
fn unreadable_and_disabled_prs_are_not_watched() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.missing("PR_1");
    let p = plan(&h, true);
    assert!(!p.prs["PR_1"].watched);
    assert!(p.prs["PR_1"].unreadable, "status still reads it");
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let org = h.owner_id(ORG);
    h.engine.owner_enable(&org, false, &h.now);
    let p = plan(&h, true);
    assert!(!p.prs["PR_1"].watched);
    let owner = p.owners.iter().find(|o| o.id == org).unwrap();
    assert!(
        !owner.enabled && !owner.status_due,
        "a disabled owner is not fetched"
    );
}

// ------------------------------------------------------------------- since

#[test]
fn since_is_five_minutes_before_the_last_success_never_before_the_watch() {
    let owner = |fetched_at, watch| OwnerPlan {
        id: "o1".into(),
        login: Some("x".into()),
        kind: Kind::Org,
        enabled: true,
        status_due: false,
        fetched_at,
        watch_started_at: watch,
        team_requests: true,
    };
    let cases = [
        (None, T0, T0, T0),
        (Some(T0 + 3600), T0, T0 + 3300, T0 + 3600),
        (Some(T0 + 100), T0, T0, T0 + 100),
        (Some(T0 + 300), T0, T0, T0 + 300),
    ];
    for (fetched, watch, since, zero_after) in cases {
        let o = owner(fetched, watch);
        assert_eq!(o.since(), since, "{fetched:?}");
        assert_eq!(o.reaction_zero_after(), zero_after, "{fetched:?}");
    }
}

#[test]
fn a_succeeded_owner_sets_its_fetch_time_and_the_account_moves_on() {
    let mut h = H::new();
    assert_eq!(h.account().updated_at, None);
    apply(
        &mut h,
        ran(Outcome {
            ingest: Some(Ingest {
                succeeded_owners: Some(vec!["ORG".into()]),
                ..Ingest::default()
            }),
            ..Outcome::default()
        }),
    );
    assert_eq!(h.account().updated_at, Some(h.at()), "without PRs too");
    let p = plan(&h, true);
    let fetched = |name: Option<&str>| {
        p.owners
            .iter()
            .find(|o| o.login.as_deref() == name)
            .unwrap()
            .fetched_at
    };
    assert_eq!(fetched(Some(ORG)), Some(h.at()));
    assert_eq!(fetched(None), None, "only the listed owners");
}

#[test]
fn updated_ago_moves_with_every_run_failed_or_not_but_not_without_one() {
    let mut h = H::new();
    apply(
        &mut h,
        ran(Outcome {
            failed: Some("Couldn't reach GitHub".into()),
            ..Outcome::default()
        }),
    );
    let first = h.account().updated_at;
    assert_eq!(first, Some(h.at()), "a failed run counts");
    h.advance(60);
    apply(&mut h, Outcome::default());
    assert_eq!(h.account().updated_at, first, "no call, no move");
}

#[test]
fn a_listed_ingest_does_not_move_owners_that_failed() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    let ingest = Ingest {
        prs: vec![pr("PR_1")],
        events: vec![e],
        succeeded_owners: Some(vec![]),
        ..Ingest::default()
    };
    h.engine.ingest(ACCOUNT, ingest, &h.now).unwrap();
    assert!(h.has_row("E_1"), "what was fetched still applies");
    let p = plan(&h, true);
    assert!(p.owners.iter().all(|o| o.fetched_at.is_none()));
}

#[test]
fn the_same_event_from_overlapping_windows_is_one_row() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e.clone()], vec![]);
    h.open();
    h.seen(&["E_1"]);
    h.close();
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    assert!(!h.wire_row("E_1").unwrap().unread, "not made again");
    assert_eq!(h.card(&key("PR_1")).unwrap().rows.len(), 1);
}

// ---------------------------------------------- team review requests

#[test]
fn the_team_list_decides_the_search() {
    let mut h = H::new();
    let team = |h: &H| {
        plan(h, true)
            .owners
            .iter()
            .find(|o| o.login.as_deref() == Some(ORG))
            .unwrap()
            .team_requests
    };
    assert!(team(&h));
    h.table(EventKind::TeamReviewRequested, EventColumn::List, false);
    assert!(!team(&h), "user-review-requested:@me while off");
}

#[test]
fn a_team_request_before_the_watch_counts_only_while_the_team_is_asked() {
    // DESIGN.md, "Events before the watch started": an ongoing request.
    for (requested_team, kept) in [(true, true), (false, false)] {
        let mut h = H::new();
        let pr = IngestPr {
            requested_team,
            ..other("PR_1")
        };
        let e = h.ev_at("RR_1", "PR_1", IngestKind::TeamReviewRequested, T0 - DAY);
        h.push(vec![pr], vec![e], vec![]);
        assert_eq!(h.has_row("RR_1"), kept, "{requested_team}");
        assert!(h.delivered().is_empty(), "before the watch: not notified");
    }
}

#[test]
fn teams_are_kept_per_account() {
    let mut h = H::new();
    h.add_other();
    let teams = vec![TeamRec {
        database_id: 42,
        slug: "core".into(),
    }];
    apply(
        &mut h,
        Outcome {
            teams: Some(teams.clone()),
            ..Outcome::default()
        },
    );
    assert_eq!(plan(&h, true).teams, teams);
    assert!(plan_of(&h, OTHER, true).teams.is_empty());
    apply(&mut h, Outcome::default());
    assert_eq!(
        plan(&h, true).teams,
        teams,
        "a run without teams keeps them"
    );
}

// ---------------------------------------------------- notification summaries

#[test]
fn would_be_individual_notifications_of_an_owner_become_one_summary() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let b = h.ev("E_2", "PR_2", IngestKind::Comment);
    let c = h.ev("E_3", "PR_2", IngestKind::Comment);
    h.push(vec![pr("PR_1"), pr("PR_2")], vec![a, b, c], vec![]);
    let out = h.delivered();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].kind, Lenient::Known(NotificationType::Summary));
    assert_eq!(out[0].title, "me · 3 new events");
    assert_eq!(out[0].subtitle.as_deref(), Some("org · in 2 PRs"));
    assert_eq!(out[0].body, None);
}

#[test]
fn summaries_never_cross_owners() {
    let mut h = H::new();
    let public = IngestPr {
        owner: "someone".into(),
        ..pr("PR_2")
    };
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let b = h.ev("E_2", "PR_2", IngestKind::Comment);
    h.push(vec![pr("PR_1"), public], vec![a, b], vec![]);
    let out = h.delivered();
    let owners: Vec<String> = out.iter().map(|n| n.owner.clone()).collect();
    assert_eq!(owners, [h.owner_id(ORG), h.owner_id("public")]);
    assert!(out.iter().all(|n| n.title == "me · Comment on my PR"));
}

#[test]
fn rows_that_do_not_notify_do_not_count_toward_a_summary() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let c = h.ev("E_3", "PR_1", IngestKind::Merged);
    let d = h.ev("E_4", "PR_1", IngestKind::MergeQueueAdded);
    h.push(vec![pr("PR_1")], vec![a, c, d], vec![]);
    let out = h.delivered();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].title, "me · Comment on my PR");
}

#[test]
fn the_account_follows_the_login_github_gives() {
    let mut h = H::new();
    apply(
        &mut h,
        ran(Outcome {
            login: Some("Me-Renamed".into()),
            ..Outcome::default()
        }),
    );
    assert_eq!(h.account().login, "Me-Renamed");
    assert_eq!(h.account().id, ACCOUNT, "the id stays");
    assert_eq!(h.engine.account_id("me-renamed").unwrap(), ACCOUNT);
}

// ---------------------------------------------------------------- warnings

#[test]
fn no_token_until_one_is_saved_and_no_fetch_without_it() {
    let mut h = H::new();
    h.engine.account_create("2002", "two").unwrap();
    let w = h.account_of("2002").warnings;
    assert_eq!(w.len(), 1);
    assert!(w[0].kind.is(WarningKind::NoToken));
    assert_eq!(w[0].message, "No token");
    assert_eq!(w[0].account.as_deref(), Some("2002"));
    assert!(!h.engine.may_fetch("2002", h.at(), true));
    h.engine.token_saved("2002");
    assert!(h.account_of("2002").warnings.is_empty());
    assert!(h.engine.may_fetch("2002", h.at(), false));
    h.engine.token_cleared("2002");
    assert!(
        h.account_of("2002").warnings[0]
            .kind
            .is(WarningKind::NoToken)
    );
}

#[test]
fn token_states_become_warnings() {
    let invalid = |expires_at| Outcome {
        token: TokenObs {
            invalid: Some(true),
            expires_at,
            ..TokenObs::default()
        },
        ..Outcome::default()
    };
    let expiring = |expires_at| Outcome {
        token: TokenObs {
            invalid: Some(false),
            expires_at: Some(expires_at),
            ..TokenObs::default()
        },
        ..Outcome::default()
    };
    // (outcome, kind, message)
    let cases: Vec<(Outcome, Option<WarningKind>, &str)> = vec![
        (
            invalid(None),
            Some(WarningKind::TokenInvalid),
            "Token is invalid",
        ),
        (
            expiring(T0 + 10 + 5 * DAY),
            Some(WarningKind::TokenExpiring),
            "Token expires in 5 days",
        ),
        (
            expiring(T0 + 10 + 3600),
            Some(WarningKind::TokenExpiring),
            "Token expires in 1 day",
        ),
        (
            expiring(T0 + 10 + 7 * DAY),
            Some(WarningKind::TokenExpiring),
            "Token expires in 7 days",
        ),
        (expiring(T0 + 10 + 8 * DAY), None, ""),
        (
            expiring(T0 + 10),
            Some(WarningKind::TokenInvalid),
            "Token is invalid",
        ),
    ];
    for (outcome, kind, message) in cases {
        let mut h = H::new();
        apply(&mut h, outcome);
        let w = h.account().warnings;
        match kind {
            None => assert!(w.is_empty(), "{w:?}"),
            Some(kind) => {
                assert_eq!(w.len(), 1, "{w:?}");
                assert!(w[0].kind.is(kind));
                assert_eq!(w[0].message, message);
            }
        }
    }
}

#[test]
fn a_401_stops_only_that_account_until_a_token_is_saved() {
    let mut h = H::new();
    h.add_other();
    apply(
        &mut h,
        Outcome {
            token: TokenObs {
                invalid: Some(true),
                ..TokenObs::default()
            },
            ..Outcome::default()
        },
    );
    assert!(!h.engine.may_fetch(ACCOUNT, h.at(), false));
    assert!(
        h.engine.may_fetch(ACCOUNT, h.at(), true),
        "refresh tries once"
    );
    assert!(h.engine.may_fetch(OTHER, h.at(), false));
    h.engine.token_saved(ACCOUNT);
    assert!(h.engine.may_fetch(ACCOUNT, h.at(), false));
    assert!(kinds(&h).is_empty());
}

#[test]
fn fetch_failed_holds_until_the_next_run_and_counts_down_the_retry() {
    let mut h = H::new();
    apply(
        &mut h,
        ran(Outcome {
            failed: Some("Couldn't reach GitHub".into()),
            ..Outcome::default()
        }),
    );
    let w = warning(&h, WarningKind::FetchFailed).unwrap();
    assert_eq!(w.until, Some(h.at() + 60));
    assert_eq!(w.message, "Couldn't reach GitHub · retrying in 1 min");
    assert_eq!(w.account.as_deref(), Some(ACCOUNT));
    apply(&mut h, Outcome::default());
    assert!(
        warning(&h, WarningKind::FetchFailed).is_some(),
        "no run, no change"
    );
    apply(&mut h, ran(Outcome::default()));
    assert!(kinds(&h).is_empty(), "a run without failures clears it");
}

#[test]
fn a_pr_whose_events_fail_three_times_in_a_row_is_named() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let fail = |h: &mut H, since| {
        apply(
            h,
            Outcome {
                retries_failed: vec![("PR_1".into(), since)],
                ..Outcome::default()
            },
        )
    };
    fail(&mut h, T0 + 100);
    fail(&mut h, T0 + 50);
    assert!(kinds(&h).is_empty());
    assert_eq!(
        plan(&h, true).retries["PR_1"],
        T0 + 50,
        "the earliest window"
    );
    fail(&mut h, T0 + 200);
    let w = h.account().warnings;
    assert_eq!(w.len(), 1);
    assert!(w[0].kind.is(WarningKind::EventsFetchFailed));
    assert_eq!(
        w[0].message,
        "Couldn't fetch events for org/app #1 · retrying"
    );
    assert_eq!(w[0].owner, Some(h.owner_id(ORG)));
    apply(
        &mut h,
        Outcome {
            retries_ok: vec!["PR_1".into()],
            ..Outcome::default()
        },
    );
    assert!(kinds(&h).is_empty());
    assert!(plan(&h, true).retries.is_empty());
}

#[test]
fn missing_scopes_follow_the_normalized_header() {
    let s = |list: &[&str]| list.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    assert!(missing_scopes(&s(&["repo", "notifications", "read:org"])).is_empty());
    assert!(missing_scopes(&s(&["repo", "notifications", "admin:org"])).is_empty());
    assert!(missing_scopes(&s(&["repo", "notifications", "write:org", "gist"])).is_empty());
    assert_eq!(
        missing_scopes(&s(&["public_repo", "notifications"])),
        ["repo", "read:org"]
    );
    assert_eq!(missing_scopes(&[]), ["repo", "notifications", "read:org"]);
}

#[test]
fn a_missing_scope_warns_and_a_later_answer_clears_it() {
    let mut h = H::new();
    apply(
        &mut h,
        Outcome {
            token: TokenObs {
                invalid: Some(false),
                scopes: Some(vec!["repo".into(), "notifications".into()]),
                ..TokenObs::default()
            },
            ..Outcome::default()
        },
    );
    let w = warning(&h, WarningKind::ScopeMissing).unwrap();
    assert_eq!(w.message, "Token is missing read:org");
    // Without the header, an endpoint's refusal names the scope.
    let mut h = H::new();
    apply(
        &mut h,
        Outcome {
            refused: ["read:org".to_string()].into(),
            ..Outcome::default()
        },
    );
    assert_eq!(
        warning(&h, WarningKind::ScopeMissing).unwrap().message,
        "Token is missing read:org"
    );
    apply(
        &mut h,
        Outcome {
            checked: ["read:org".to_string()].into(),
            ..Outcome::default()
        },
    );
    assert!(warning(&h, WarningKind::ScopeMissing).is_none());
    assert!(
        h.engine.may_fetch(ACCOUNT, h.at(), false),
        "fetching goes on"
    );
}

#[test]
fn sso_names_the_owner_whose_id_github_gives() {
    let sso = |orgs: Vec<i64>, urls: Vec<String>| Outcome {
        token: TokenObs {
            invalid: Some(false),
            sso: true,
            sso_orgs: orgs,
            sso_urls: urls,
            ..TokenObs::default()
        },
        ..Outcome::default()
    };
    // `org` has github_id 100 in the support module.
    let mut h = H::new();
    apply(&mut h, sso(vec![100], vec![]));
    let w: Vec<Warning> = h.account().warnings;
    assert_eq!(w.len(), 1, "{w:?}");
    assert!(w[0].kind.is(WarningKind::SsoRequired));
    assert_eq!(w[0].message, "SSO authorization required for org");
    assert_eq!(w[0].owner, Some(h.owner_id(ORG)));
    assert!(
        h.engine.may_fetch(ACCOUNT, h.at(), false),
        "the others go on"
    );

    let mut h = H::new();
    apply(
        &mut h,
        sso(vec![999], vec!["https://github.com/orgs/x/sso".into()]),
    );
    let w = h.account().warnings;
    assert_eq!(w.len(), 1);
    assert_eq!(w[0].message, "SSO authorization required");
    assert_eq!(w[0].owner, None);
    assert_eq!(w[0].url.as_deref(), Some("https://github.com/orgs/x/sso"));

    // The next answer without the header clears it.
    apply(
        &mut h,
        Outcome {
            token: TokenObs {
                invalid: Some(false),
                ..TokenObs::default()
            },
            ..Outcome::default()
        },
    );
    assert!(kinds(&h).is_empty());
}

#[test]
fn the_keychain_warnings_go_on_every_account_without_one() {
    let mut h = H::new();
    h.add_other();
    for (state, kind, message) in [
        (
            KeychainState::Unavailable,
            WarningKind::KeychainUnavailable,
            "Couldn't read tokens from Keychain",
        ),
        (
            KeychainState::Unreadable,
            WarningKind::TokensUnreadable,
            "Saved tokens are unreadable",
        ),
    ] {
        h.engine.set_keychain_state(state);
        for account in [ACCOUNT, OTHER] {
            let w = h.account_of(account).warnings;
            assert!(w[0].kind.is(kind), "{w:?}");
            assert_eq!(w[0].account, None);
            assert_eq!(w[0].message, message);
        }
    }
}

// --------------------------------------------------------------- rate limits

#[test]
fn usage_under_a_fifth_of_the_limit_warns_per_api() {
    let limit = |remaining| {
        Some(LimitRec {
            limit: 5000,
            remaining,
            reset_at: Some(T0 + 3600),
        })
    };
    // (graphql remaining, rest remaining, warnings)
    let cases: [(i64, i64, &[&str]); 4] = [
        (1000, 1000, &[]),
        (999, 1000, &["graphql_near_limit"]),
        (1000, 999, &["rest_near_limit"]),
        (1, 1, &["graphql_near_limit", "rest_near_limit"]),
    ];
    for (graphql, rest, expect) in cases {
        let mut h = H::new();
        apply(
            &mut h,
            Outcome {
                graphql: limit(graphql),
                rest: limit(rest),
                ..Outcome::default()
            },
        );
        assert_eq!(kinds(&h), expect, "{graphql} {rest}");
        let rate = h.account().rate_limit.unwrap();
        assert_eq!(rate.graphql.unwrap().used, 5000 - graphql);
        assert_eq!(rate.rest.unwrap().limit, 5000);
        assert!(
            h.engine.may_fetch(ACCOUNT, h.at(), false),
            "the interval stays"
        );
    }
    let h = H::new();
    assert_eq!(h.account().rate_limit, None, "nothing known yet");
}

#[test]
fn a_stop_holds_every_fetch_of_the_account_until_its_time_then_resumes() {
    let mut h = H::new();
    h.add_other();
    let until = h.at() + 120;
    apply(
        &mut h,
        Outcome {
            due: Due {
                status: true,
                reactions: true,
                notifications: true,
            },
            stop: Some(until),
            ..Outcome::default()
        },
    );
    assert_eq!(h.engine.stopped_until(ACCOUNT, h.at()), Some(until));
    assert!(!h.engine.may_fetch(ACCOUNT, h.at(), true), "refresh too");
    assert!(
        h.engine.may_fetch(OTHER, h.at(), false),
        "the other account"
    );
    let w = warning(&h, WarningKind::RateLimited).unwrap();
    assert_eq!(w.until, Some(until));
    // 08:02:10 UTC is 17:02 in Tokyo, the zone of the support clock.
    assert_eq!(
        w.message,
        "Polling paused until 17:02 · GitHub's limit reached"
    );
    assert!(h.account_of(OTHER).warnings.is_empty());
    h.set_time(until);
    h.tick();
    assert_eq!(h.engine.stopped_until(ACCOUNT, h.at()), None);
    assert!(kinds(&h).is_empty());
    assert!(
        h.engine.due(ACCOUNT, h.at(), false).status,
        "fetching resumes by itself"
    );
}

#[test]
fn due_times_follow_the_intervals() {
    let mut h = H::new();
    h.set("status_interval_minutes", json!(2));
    h.set("reactions_interval_minutes", json!(5));
    let due = h.engine.due(ACCOUNT, h.at(), false);
    assert!(
        due.status && due.reactions && due.notifications,
        "a start fetches"
    );
    let owners = vec![h.owner_id(ORG), h.owner_id("public")];
    apply(
        &mut h,
        Outcome {
            due,
            poll_interval: Some(90),
            status_ran: owners,
            ..Outcome::default()
        },
    );
    let start = h.at();
    for (offset, status, reactions, notifications) in [
        (0, false, false, false),
        (89, false, false, false),
        (90, false, false, true),
        (120, true, false, true),
        (300, true, true, true),
    ] {
        let due = h.engine.due(ACCOUNT, start + offset, false);
        assert_eq!(
            (due.status, due.reactions, due.notifications),
            (status, reactions, notifications),
            "+{offset}"
        );
    }
    let forced = h.engine.due(ACCOUNT, start, true);
    assert!(forced.status && forced.reactions, "refresh fetches now");
    assert!(!forced.notifications, "but keeps to X-Poll-Interval");
}

#[test]
fn secondary_limits_wait_for_retry_after_or_a_minute() {
    let mut rec = Recorder::new(T0);
    assert!(matches!(
        rec.stop(T0 + 30),
        CallError::RateLimited { until, .. } if until == T0 + 30
    ));
    assert!(
        matches!(rec.stop(T0 + 999), CallError::RateLimited { until, .. } if until == T0 + 30),
        "the first stop of a run wins"
    );
}

#[test]
fn status_timers_are_per_owner() {
    let mut h = H::new();
    let start = h.at();
    let org = h.owner_id(ORG);
    apply(
        &mut h,
        Outcome {
            status_ran: vec![org.clone()],
            ..Outcome::default()
        },
    );
    let p = plan(&h, false);
    let due = |id: &str| p.owners.iter().find(|o| o.id == id).unwrap().status_due;
    assert!(!due(&org), "fetched just now");
    assert!(due(&h.owner_id("public")), "untouched");
    h.set_time(start + 60);
    let p = plan(&h, false);
    assert!(p.owners.iter().all(|o| o.status_due));
}

// ---------------------------------------------------- reaction baselines

#[test]
fn a_returning_pr_sets_its_baselines_without_rows() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let mut first = h.reaction("C_1", "PR_1", &[("THUMBS_UP", 5)]);
    first.comment_created_at = T0 - DAY;
    first.watching = false;
    h.push(vec![], vec![], vec![first.clone()]);
    assert!(h.card(&key("PR_1")).unwrap().rows.is_empty());
    let mut next = first;
    next.watching = true;
    next.counts = BTreeMap::from([("THUMBS_UP".into(), 6)]);
    h.push(vec![], vec![], vec![next]);
    let rows = h.card(&key("PR_1")).unwrap().rows;
    assert_eq!(rows.len(), 1);
    assert_eq!(
        rows[0].counts,
        Some(BTreeMap::from([("THUMBS_UP".into(), 1)]))
    );
}

#[test]
fn a_response_without_the_expiry_header_keeps_the_expiry() {
    let mut h = H::new();
    let at = h.at() + 3 * DAY;
    for expires_at in [Some(at), None] {
        apply(
            &mut h,
            Outcome {
                token: TokenObs {
                    expires_at,
                    invalid: Some(false),
                    ..TokenObs::default()
                },
                ..Outcome::default()
            },
        );
        assert_eq!(
            warning(&h, WarningKind::TokenExpiring).and_then(|w| w.until),
            Some(at)
        );
    }
    assert_eq!(h.account().token.expires_at, Some(at));
}

fn own_comment() -> OwnComment {
    OwnComment {
        id: "C_1".into(),
        pr_id: "PR_1".into(),
        url: "u".into(),
        text: "t".into(),
        created_at: T0,
        baseline_done: true,
    }
}

#[test]
fn a_pr_leaving_the_watch_sets_its_reaction_baseline_again() {
    for collected in [true, false] {
        let mut h = H::new();
        h.set("keep_watching_days", json!(0));
        h.prs(vec![other("PR_1")]);
        apply(
            &mut h,
            Outcome {
                collected: if collected {
                    vec!["PR_1".into()]
                } else {
                    vec![]
                },
                own: vec![own_comment()],
                ..Outcome::default()
            },
        );
        assert!(plan(&h, true).own["C_1"].baseline_done);
        h.set_time(T0 + 15 * DAY);
        h.tick();
        h.advance(1);
        h.tick();
        assert!(!plan(&h, true).own["C_1"].baseline_done, "{collected}");
    }
}

#[test]
fn fetch_records_are_kept_per_account() {
    let mut h = H::new();
    h.add_other();
    apply(
        &mut h,
        Outcome {
            own: vec![own_comment()],
            pr_ids: vec![("org/app#1".into(), "PR_1".into())],
            ..Outcome::default()
        },
    );
    assert!(plan(&h, true).own.contains_key("C_1"));
    assert!(plan_of(&h, OTHER, true).own.is_empty());
    assert!(plan_of(&h, OTHER, true).pr_ids.is_empty());
}

// ------------------------------------------------- notifications check

#[test]
fn refresh_skips_only_the_notifications_check_within_the_poll_interval() {
    let mut h = H::new();
    let start = h.at();
    let owners = vec![h.owner_id(ORG), h.owner_id("public")];
    apply(
        &mut h,
        Outcome {
            due: Due {
                status: true,
                reactions: true,
                notifications: true,
            },
            poll_interval: Some(60),
            notifications_checked: true,
            status_ran: owners,
            ..Outcome::default()
        },
    );
    for (offset, notifications) in [(0, false), (30, false), (59, false), (60, true), (90, true)] {
        let due = h.engine.due(ACCOUNT, start + offset, true);
        assert!(
            due.status && due.reactions,
            "+{offset}: the PRs are still fetched"
        );
        assert_eq!(due.notifications, notifications, "+{offset}");
    }
}

#[test]
fn the_last_notifications_check_survives_a_restart() {
    let mut h = H::new();
    let start = h.at();
    apply(
        &mut h,
        Outcome {
            due: Due {
                notifications: true,
                ..Due::default()
            },
            poll_interval: Some(60),
            notifications_checked: true,
            ..Outcome::default()
        },
    );
    let restored = Engine::restore(h.engine.data().clone());
    assert_eq!(
        restored.data().accounts[ACCOUNT].fetch.notif_checked_at,
        Some(start)
    );
    assert!(
        !restored.due(ACCOUNT, start + 59, true).notifications,
        "within the interval"
    );
    assert!(
        restored.due(ACCOUNT, start + 60, true).notifications,
        "after it"
    );
    assert!(
        restored.due(ACCOUNT, start, false).status,
        "the PR fetches are due at once"
    );
}
