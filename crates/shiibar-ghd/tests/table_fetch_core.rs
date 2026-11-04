//! The core's side of fetching: the watch period, `since`, Include requests
//! to my teams, notification summaries, warnings and rate limits.
//! docs/tasks/M2.md, "Fetcher and core", "Rate limits", "Warnings and the
//! wire format".

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use shiibar_ghd::github::{CallError, Recorder};
use shiibar_ghd::model::{NOTIFICATIONS, TeamRec};
use shiibar_ghd::plan::*;
use std::collections::BTreeMap;
use support::*;

fn kinds(h: &H, scope: &str) -> Vec<(String, String)> {
    h.scope(scope)
        .warnings
        .iter()
        .map(|w| {
            let token = w.token.as_ref().map_or("null".into(), |t| t.as_text());
            (w.kind.as_text(), token)
        })
        .collect()
}

fn register(h: &mut H, key: &str) {
    h.engine.token_saved(key);
}

fn plan(h: &H, forced: bool) -> Plan {
    let due = h.engine.due(h.at(), forced);
    let mut read = |_: &str| Some("t".to_string());
    h.engine.fetch_plan(&h.now, due, forced, None, &mut read)
}

fn obs(owner: &str) -> TokenObs {
    TokenObs {
        owner: Some(owner.into()),
        invalid: Some(false),
        ..TokenObs::default()
    }
}

fn apply(h: &mut H, outcome: Outcome) {
    let now = h.now.clone();
    h.engine.apply_fetch(outcome, &now);
}

// ---------------------------------------------------------------- watching

#[test]
fn a_pr_is_watched_while_shown_and_for_the_keep_days_after() {
    let mut h = H::new();
    h.set("keep_watching_days", json!(3));
    h.prs(vec![other("PR_1")]);
    let watched = |h: &H| plan(h, true).prs["PR_1"].watched;
    assert!(watched(&h), "the card shows");
    // Drop after 14 days without updates: the card disappears.
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
    h.engine.scope_disable(ORG).unwrap();
    let p = plan(&h, true);
    assert!(!p.prs["PR_1"].watched);
    assert!(
        p.scopes.iter().all(|s| s.id != ORG),
        "a disabled scope is not fetched"
    );
}

// ------------------------------------------------------------------- since

#[test]
fn since_is_five_minutes_before_the_last_success_never_before_the_watch() {
    let scope = |fetched_at, watch| ScopePlan {
        status_due: false,
        id: "x".into(),
        owner: Some("x".into()),
        kind: None,
        token_key: "x".into(),
        token: TokenUse::default(),
        fetched_at,
        watch_started_at: watch,
        teams: vec![],
    };
    let cases = [
        (None, T0, T0, T0),
        (Some(T0 + 3600), T0, T0 + 3300, T0 + 3600),
        (Some(T0 + 100), T0, T0, T0 + 100),
        (Some(T0 + 300), T0, T0, T0 + 300),
    ];
    for (fetched, watch, since, zero_after) in cases {
        let s = scope(fetched, watch);
        assert_eq!(s.since(), since, "{fetched:?}");
        assert_eq!(s.reaction_zero_after(), zero_after, "{fetched:?}");
    }
}

#[test]
fn a_succeeded_scope_moves_on_without_prs_and_sets_the_fetch_time() {
    let mut h = H::new();
    assert_eq!(h.scope(ORG).updated_at, None);
    let ingest = Ingest {
        viewer: ME.into(),
        missing_pr_ids: vec![],
        prs: vec![],
        events: vec![],
        reactions: vec![],
        succeeded_scopes: Some(vec!["ORG".into()]),
    };
    apply(
        &mut h,
        Outcome {
            ingest: Some(ingest),
            ..Outcome::default()
        },
    );
    assert_eq!(h.scope(ORG).updated_at, Some(h.at()));
    assert_eq!(
        plan(&h, true)
            .scopes
            .iter()
            .find(|s| s.id == ORG)
            .unwrap()
            .fetched_at,
        Some(h.at())
    );
    assert_eq!(h.scope("public").updated_at, None, "only the listed scopes");
}

#[test]
fn a_listed_ingest_does_not_move_scopes_that_failed() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    let ingest = Ingest {
        viewer: ME.into(),
        missing_pr_ids: vec![],
        prs: vec![pr("PR_1")],
        events: vec![e],
        reactions: vec![],
        succeeded_scopes: Some(vec![]),
    };
    h.engine.ingest(ingest, &h.now).unwrap();
    assert!(h.has_row("E_1"), "what was fetched still applies");
    assert_eq!(h.scope(ORG).updated_at, None);
}

#[test]
fn the_same_event_from_overlapping_windows_is_one_row() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e.clone()], vec![]);
    h.open();
    h.seen(&["E_1"]);
    h.close();
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    assert!(!h.wire_row("E_1").unwrap().unread, "not made again");
    assert_eq!(h.card(&key("PR_1")).unwrap().rows.len(), 1);
}

// ---------------------------------------------- Include requests to my teams

fn team_request(h: &H, id: &str, at: i64) -> IngestEvent {
    IngestEvent {
        team: true,
        text: Some("for core team".into()),
        ..h.ev_at(id, "PR_1", EventKind::ReviewRequested, at)
    }
}

#[test]
fn a_team_request_follows_include_requests_to_my_teams() {
    let mut h = H::new();
    let requested = IngestPr {
        requested_team: true,
        ..other("PR_1")
    };
    let e = team_request(&h, "RR_1", h.at());
    h.push(vec![requested.clone()], vec![e], vec![]);
    let row = h.wire_row("RR_1").unwrap();
    assert_eq!(class(&row), RowClass::NeedsAction);
    assert!(row.unread);
    assert_eq!(h.badge(), 1);
    assert_eq!(h.delivered().len(), 1);

    h.set("include_team_requests", json!(false));
    assert!(h.wire_row("RR_1").is_none(), "hidden while off");
    assert_eq!(h.badge(), 0);
}

#[test]
fn a_team_request_recorded_while_off_returns_read_and_silent() {
    let mut h = H::new();
    h.set("include_team_requests", json!(false));
    let requested = IngestPr {
        requested_team: true,
        ..other("PR_1")
    };
    let e = team_request(&h, "RR_1", h.at());
    h.push(vec![requested.clone()], vec![e], vec![]);
    assert!(h.engine.row_record("RR_1").is_some(), "recorded anyway");
    assert!(h.delivered().is_empty());
    assert!(!h.dot());
    h.advance(10);
    h.set("include_team_requests", json!(true));
    let row = h.wire_row("RR_1").unwrap();
    assert!(!row.unread, "shown as read");
    assert_eq!(class(&row), RowClass::NeedsAction, "the request goes on");
    assert!(h.delivered().is_empty(), "never notified after the fact");

    // Found later, made while the setting was off: read and silent too.
    let late = team_request(&h, "RR_0", h.at() - 5);
    h.push(vec![requested.clone()], vec![late], vec![]);
    assert!(!h.row("RR_0").unread);
    assert!(h.delivered().is_empty());
    // Made after it was turned on: an ordinary request.
    let fresh = team_request(&h, "RR_2", h.at());
    h.push(vec![requested], vec![fresh], vec![]);
    assert!(h.row("RR_2").unread);
    assert_eq!(h.delivered().len(), 1);
}

#[test]
fn a_direct_request_is_unaffected_by_the_team_setting() {
    let mut h = H::new();
    h.set("include_team_requests", json!(false));
    let requested = IngestPr {
        requested_me: true,
        ..other("PR_1")
    };
    let e = h.ev("RR_1", "PR_1", EventKind::ReviewRequested);
    h.push(vec![requested], vec![e], vec![]);
    assert_eq!(class(&h.wire_row("RR_1").unwrap()), RowClass::NeedsAction);
    assert_eq!(h.delivered().len(), 1);
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
        let e = team_request(&h, "RR_1", T0 - DAY);
        h.push(vec![pr], vec![e], vec![]);
        assert_eq!(h.has_row("RR_1"), kept, "{requested_team}");
        assert!(h.delivered().is_empty(), "before the watch: not notified");
    }
}

// ---------------------------------------------------- notification summaries

#[test]
fn would_be_individual_notifications_of_a_scope_become_one_summary() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    let b = h.ev("E_2", "PR_2", EventKind::Comment);
    let c = h.ev("E_3", "PR_2", EventKind::Comment);
    h.push(vec![pr("PR_1"), pr("PR_2")], vec![a, b, c], vec![]);
    let out = h.delivered();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].kind, Lenient::Known(NotificationType::Summary));
    assert_eq!(out[0].title, "org · 3 new events");
    assert_eq!(out[0].body.as_deref(), Some("In 2 PRs"));
    assert_eq!(out[0].subtitle, None);
}

#[test]
fn summaries_never_cross_scopes() {
    let mut h = H::new();
    let public = IngestPr {
        owner: "someone".into(),
        ..pr("PR_2")
    };
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    let b = h.ev("E_2", "PR_2", EventKind::Comment);
    h.push(vec![pr("PR_1"), public], vec![a, b], vec![]);
    let out = h.delivered();
    let titles: Vec<&str> = out.iter().map(|n| n.title.as_str()).collect();
    assert_eq!(titles, ["org · Comment", "Public · Comment"]);
}

#[test]
fn rows_that_do_not_notify_do_not_count_toward_a_summary() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    let b = h.ev("E_2", "PR_1", EventKind::BotComment);
    let c = h.ev("E_3", "PR_1", EventKind::Merged);
    h.push(vec![pr("PR_1")], vec![a, b, c], vec![]);
    let out = h.delivered();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].title, "org · Comment");
}

#[test]
fn a_scope_shows_the_login_github_spells() {
    let mut h = H::new();
    apply(
        &mut h,
        Outcome {
            scopes: BTreeMap::from([(
                ORG.to_string(),
                ScopeObs {
                    kind: Some(shiibar_ghd::model::ScopeKind::Org),
                    name: Some("Org".into()),
                    ..ScopeObs::default()
                },
            )]),
            ..Outcome::default()
        },
    );
    let scope = h.scope(ORG);
    assert_eq!(scope.name, "Org");
    assert_eq!(scope.kind, Some(Lenient::Known(ScopeKind::Org)));
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    assert_eq!(h.delivered()[0].title, "Org · Comment");
}

// ------------------------------------------------------------------ warnings

#[test]
fn no_token_until_both_tokens_are_registered() {
    let mut h = H::new();
    assert_eq!(
        kinds(&h, ORG),
        [
            ("no_token".to_string(), "notifications".to_string()),
            ("no_token".to_string(), "scope".to_string())
        ]
    );
    register(&mut h, NOTIFICATIONS);
    assert_eq!(
        kinds(&h, ORG),
        [("no_token".to_string(), "scope".to_string())]
    );
    register(&mut h, ORG);
    assert!(kinds(&h, ORG).is_empty());
    assert_eq!(
        kinds(&h, "public"),
        [("no_token".to_string(), "scope".to_string())]
    );
}

#[test]
fn token_states_become_warnings() {
    let mut h = H::new();
    register(&mut h, NOTIFICATIONS);
    register(&mut h, ORG);
    register(&mut h, "public");
    let token = |expires: Option<i64>, invalid: bool, sso: bool| TokenObs {
        owner: Some(ME.into()),
        expires_at: expires,
        invalid: Some(invalid),
        sso,
        sso_urls: if sso {
            vec!["https://sso".into()]
        } else {
            vec![]
        },
        ..TokenObs::default()
    };
    let cases: [(TokenObs, Vec<(&str, &str)>); 6] = [
        (token(None, false, false), vec![]),
        (token(Some(T0 + 30 * DAY), false, false), vec![]),
        (
            token(Some(h.at() + 7 * DAY), false, false),
            vec![("token_expiring", "scope")],
        ),
        (
            token(Some(h.at()), false, false),
            vec![("token_invalid", "scope")],
        ),
        (token(None, true, false), vec![("token_invalid", "scope")]),
        (token(None, false, true), vec![("sso_required", "scope")]),
    ];
    for (obs, expect) in cases {
        // A header never clears what an earlier one said: start each case
        // from a newly saved token.
        h.engine.token_saved(ORG);
        apply(
            &mut h,
            Outcome {
                tokens: BTreeMap::from([(ORG.to_string(), obs.clone())]),
                ..Outcome::default()
            },
        );
        let expect: Vec<(String, String)> = expect
            .into_iter()
            .map(|(k, t)| (k.to_string(), t.to_string()))
            .collect();
        assert_eq!(kinds(&h, ORG), expect, "{obs:?}");
        if obs.invalid == Some(true) || obs.expires_at == Some(h.at()) {
            assert!(
                plan(&h, false)
                    .scopes
                    .iter()
                    .find(|s| s.id == ORG)
                    .unwrap()
                    .token
                    .invalid
            );
            assert!(
                !plan(&h, true)
                    .scopes
                    .iter()
                    .find(|s| s.id == ORG)
                    .unwrap()
                    .token
                    .usable(false)
                    .is_some()
            );
            assert!(
                plan(&h, true)
                    .scopes
                    .iter()
                    .find(|s| s.id == ORG)
                    .unwrap()
                    .token
                    .usable(true)
                    .is_some(),
                "refresh tries once"
            );
        }
    }
    assert_eq!(kinds(&h, "public"), Vec::<(String, String)>::new());
}

#[test]
fn the_notifications_token_warns_every_scope() {
    let mut h = H::new();
    register(&mut h, NOTIFICATIONS);
    register(&mut h, ORG);
    register(&mut h, "public");
    apply(
        &mut h,
        Outcome {
            tokens: BTreeMap::from([(
                NOTIFICATIONS.to_string(),
                TokenObs {
                    invalid: Some(true),
                    ..TokenObs::default()
                },
            )]),
            ..Outcome::default()
        },
    );
    for scope in [ORG, "public"] {
        assert_eq!(
            kinds(&h, scope),
            [("token_invalid".to_string(), "notifications".to_string())]
        );
    }
    h.engine.token_saved(NOTIFICATIONS);
    assert!(kinds(&h, ORG).is_empty(), "a new token starts clean");
}

#[test]
fn an_owner_mismatch_stops_the_scope_until_the_token_changes() {
    let mut h = H::new();
    register(&mut h, NOTIFICATIONS);
    register(&mut h, ORG);
    apply(
        &mut h,
        Outcome {
            tokens: BTreeMap::from([
                (NOTIFICATIONS.to_string(), obs("me")),
                (ORG.to_string(), obs("someone")),
            ]),
            ..Outcome::default()
        },
    );
    assert_eq!(
        kinds(&h, ORG),
        [("token_owner_mismatch".to_string(), "scope".to_string())]
    );
    assert!(plan(&h, true).mismatched.contains(ORG));
    apply(
        &mut h,
        Outcome {
            tokens: BTreeMap::from([(ORG.to_string(), obs("ME"))]),
            ..Outcome::default()
        },
    );
    assert!(kinds(&h, ORG).is_empty(), "logins compare without case");
}

#[test]
fn fetch_warnings_hold_until_the_scope_is_fetched_again() {
    let mut h = H::new();
    register(&mut h, NOTIFICATIONS);
    register(&mut h, ORG);
    let failed = Warning {
        kind: Lenient::Known(WarningKind::FetchFailed),
        token: Some(Lenient::Known(TokenRole::Scope)),
        message: "Couldn't reach GitHub".into(),
        until: Some(h.at() + 60),
    };
    let outcome = |warnings| Outcome {
        scopes: BTreeMap::from([(
            ORG.to_string(),
            ScopeObs {
                warnings: Some(warnings),
                ..ScopeObs::default()
            },
        )]),
        ..Outcome::default()
    };
    apply(&mut h, outcome(vec![failed.clone()]));
    assert_eq!(h.scope(ORG).warnings, [failed]);
    apply(&mut h, Outcome::default());
    assert_eq!(
        h.scope(ORG).warnings.len(),
        1,
        "a run that skipped the scope keeps it"
    );
    apply(&mut h, outcome(vec![]));
    assert!(h.scope(ORG).warnings.is_empty());
}

#[test]
fn a_pr_whose_events_fail_three_times_in_a_row_is_named() {
    let mut h = H::new();
    register(&mut h, NOTIFICATIONS);
    register(&mut h, ORG);
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
    assert!(kinds(&h, ORG).is_empty());
    assert_eq!(
        plan(&h, true).retries["PR_1"],
        T0 + 50,
        "the earliest window"
    );
    fail(&mut h, T0 + 200);
    let warnings = h.scope(ORG).warnings;
    assert_eq!(warnings.len(), 1);
    assert_eq!(
        warnings[0].kind,
        Lenient::Known(WarningKind::EventsFetchFailed)
    );
    assert_eq!(warnings[0].message, "org/app#1");
    apply(
        &mut h,
        Outcome {
            retries_ok: vec!["PR_1".into()],
            ..Outcome::default()
        },
    );
    assert!(h.scope(ORG).warnings.is_empty());
    assert!(plan(&h, true).retries.is_empty());
}

// --------------------------------------------------------------- rate limits

#[test]
fn the_cost_cap_warns_above_eighty_percent_and_stops_at_the_cap() {
    let mut h = H::new();
    register(&mut h, NOTIFICATIONS);
    register(&mut h, ORG);
    h.set("graphql_cost_cap", json!(100));
    let cost = |h: &mut H, cost| {
        let at = h.at();
        apply(
            h,
            Outcome {
                costs: vec![(at, cost)],
                ..Outcome::default()
            },
        )
    };
    cost(&mut h, 80);
    assert!(kinds(&h, ORG).is_empty(), "80% is not above 80%");
    cost(&mut h, 1);
    assert_eq!(
        kinds(&h, ORG),
        [("cost_near_cap".to_string(), "null".to_string())],
        "a cost warning is about no token"
    );
    // The costs leave the hour as it passes.
    h.advance(3601);
    h.tick();
    assert!(kinds(&h, ORG).is_empty());

    // The fetcher's recorder refuses calls once the cap is reached.
    let mut rec = Recorder::new(T0 + 4000, 100, vec![(T0 + 1000, 60), (T0 + 2000, 40)]);
    let stop = rec.stop(T0 + 4600, "GraphQL cost cap reached");
    assert!(matches!(stop, CallError::RateLimited { until, .. } if until == T0 + 4600));
}

#[test]
fn a_stop_holds_every_fetch_until_its_time_then_resumes() {
    let mut h = H::new();
    register(&mut h, NOTIFICATIONS);
    register(&mut h, ORG);
    let until = h.at() + 120;
    apply(
        &mut h,
        Outcome {
            due: Due {
                status: true,
                reactions: true,
                notifications: true,
            },
            stop: Some((until, "Secondary rate limit".into())),
            ..Outcome::default()
        },
    );
    assert_eq!(h.engine.stopped_until(h.at()), Some(until));
    let warnings = h.scope(ORG).warnings;
    assert_eq!(warnings[0].kind, Lenient::Known(WarningKind::RateLimited));
    assert_eq!(warnings[0].until, Some(until));
    let limited = h
        .engine
        .refresh_warnings(None)
        .into_iter()
        .filter(|w| w.kind == Lenient::Known(WarningKind::RateLimited))
        .count();
    assert_eq!(limited, 1, "one warning for all scopes");
    h.set_time(until);
    h.tick();
    assert_eq!(h.engine.stopped_until(h.at()), None);
    assert!(h.scope(ORG).warnings.is_empty());
    assert!(
        h.engine.due(h.at(), false).status,
        "fetching resumes by itself"
    );
}

#[test]
fn due_times_follow_the_intervals() {
    let mut h = H::new();
    h.set("status_interval_minutes", json!(2));
    h.set("reactions_interval_minutes", json!(5));
    let due = h.engine.due(h.at(), false);
    assert!(
        due.status && due.reactions && due.notifications,
        "a start fetches"
    );
    apply(
        &mut h,
        Outcome {
            due,
            poll_interval: Some(90),
            status_ran: vec![ORG.into(), "public".into()],
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
        let due = h.engine.due(start + offset, false);
        assert_eq!(
            (due.status, due.reactions, due.notifications),
            (status, reactions, notifications),
            "+{offset}"
        );
    }
    let forced = h.engine.due(start, true);
    assert!(forced.status && forced.reactions, "refresh fetches now");
    assert!(!forced.notifications, "but keeps to X-Poll-Interval");
}

#[test]
fn secondary_limits_wait_for_retry_after_or_a_minute() {
    let mut rec = Recorder::new(T0, 1500, vec![]);
    assert!(matches!(
        rec.stop(T0 + 30, "Secondary rate limit"),
        CallError::RateLimited { until, .. } if until == T0 + 30
    ));
    assert!(
        matches!(rec.stop(T0 + 999, "later"), CallError::RateLimited { until, .. } if until == T0 + 30),
        "the first stop of a run wins"
    );
}

// --------------------------------------------------------------- teams

#[test]
fn team_memberships_are_kept_per_scope() {
    let mut h = H::new();
    let teams = vec![TeamRec {
        database_id: 42,
        slug: "core".into(),
    }];
    apply(
        &mut h,
        Outcome {
            scopes: BTreeMap::from([(
                ORG.to_string(),
                ScopeObs {
                    teams: Some(teams.clone()),
                    ..ScopeObs::default()
                },
            )]),
            ..Outcome::default()
        },
    );
    let p = plan(&h, true);
    assert_eq!(p.scopes.iter().find(|s| s.id == ORG).unwrap().teams, teams);
    assert!(
        p.scopes
            .iter()
            .find(|s| s.id == "public")
            .unwrap()
            .teams
            .is_empty()
    );
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
    register(&mut h, NOTIFICATIONS);
    register(&mut h, ORG);
    let at = h.at() + 3 * DAY;
    for expires_at in [Some(at), None] {
        apply(
            &mut h,
            Outcome {
                tokens: BTreeMap::from([(
                    ORG.to_string(),
                    TokenObs {
                        expires_at,
                        scopes: Some(vec!["repo".into()]),
                        invalid: Some(false),
                        ..TokenObs::default()
                    },
                )]),
                ..Outcome::default()
            },
        );
        assert_eq!(warning_until(&h, "token_expiring"), Some(at));
    }
    let (_, tokens) = h.engine.settings_status();
    let org = tokens.iter().find(|t| t.target == ORG).unwrap();
    assert_eq!(org.expires_at, Some(at));
    assert_eq!(org.scopes, None, "only the classic PAT has scopes");
}

fn warning_until(h: &H, kind: &str) -> Option<i64> {
    h.scope(ORG)
        .warnings
        .iter()
        .find(|w| w.kind.as_text() == kind)
        .and_then(|w| w.until)
}

#[test]
fn status_timers_are_per_scope() {
    let mut h = H::new();
    let start = h.at();
    apply(
        &mut h,
        Outcome {
            status_ran: vec![ORG.into()],
            ..Outcome::default()
        },
    );
    let p = plan(&h, false);
    let due = |id: &str| p.scopes.iter().find(|s| s.id == id).unwrap().status_due;
    assert!(!due(ORG), "refreshed just now");
    assert!(due("public"), "untouched by a refresh of another scope");
    h.set_time(start + 60);
    let p = plan(&h, false);
    assert!(p.scopes.iter().all(|s| s.status_due));
}

#[test]
fn a_pr_leaving_the_watch_sets_its_reaction_baseline_again() {
    let mut h = H::new();
    h.set("keep_watching_days", json!(0));
    h.prs(vec![other("PR_1")]);
    apply(
        &mut h,
        Outcome {
            collected: vec!["PR_1".into()],
            own: vec![shiibar_ghd::model::OwnComment {
                id: "C_1".into(),
                pr_id: "PR_1".into(),
                url: "u".into(),
                text: "t".into(),
                created_at: T0,
                baseline_done: true,
            }],
            ..Outcome::default()
        },
    );
    assert!(plan(&h, true).own["C_1"].baseline_done);
    h.set_time(T0 + 15 * DAY);
    h.tick();
    h.advance(1);
    h.tick();
    assert!(!plan(&h, true).own["C_1"].baseline_done);
}

#[test]
fn a_pr_never_collected_also_sets_its_baseline_again_after_leaving() {
    let mut h = H::new();
    h.set("keep_watching_days", json!(0));
    h.prs(vec![other("PR_1")]);
    apply(
        &mut h,
        Outcome {
            own: vec![shiibar_ghd::model::OwnComment {
                id: "C_1".into(),
                pr_id: "PR_1".into(),
                url: "u".into(),
                text: "t".into(),
                created_at: T0,
                baseline_done: true,
            }],
            ..Outcome::default()
        },
    );
    assert!(!plan(&h, true).prs["PR_1"].collected);
    h.set_time(T0 + 15 * DAY);
    h.tick();
    h.advance(1);
    h.tick();
    assert!(!plan(&h, true).own["C_1"].baseline_done);
}
