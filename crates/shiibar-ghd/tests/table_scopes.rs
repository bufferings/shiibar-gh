//! Rule table: scope membership and disabled scopes. DESIGN.md, section
//! "Scopes", and the brief's scope rules.

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use support::*;

#[test]
fn membership_table() {
    // (name, owner, private, card scope). `org` is registered, `gone` removed.
    let cases = [
        ("registered owner, public repo", "org", false, Some("org")),
        ("registered owner, private repo", "org", true, Some("org")),
        (
            "unregistered owner, public repo",
            "stranger",
            false,
            Some("public"),
        ),
        ("unregistered owner, private repo", "stranger", true, None),
        ("removed owner, public repo", "gone", false, Some("public")),
        ("removed owner, private repo", "gone", true, None),
    ];
    for (name, owner, is_private, want) in cases {
        let mut h = H::new();
        h.engine.scope_add("gone", &h.now).unwrap();
        h.engine.scope_remove("gone").unwrap();
        h.prs(vec![IngestPr {
            owner: owner.into(),
            is_private,
            ..pr("PR_1")
        }]);
        let cards = h.cards(&Filter::default());
        assert_eq!(cards.first().map(|c| c.scope.as_str()), want, "{name}");
    }
}

#[test]
fn public_exists_from_the_start_and_cannot_go() {
    let h = H::new();
    let public = h.scope("public");
    assert_eq!(public.name, "Public");
    assert_eq!(public.kind, Some(Lenient::Known(ScopeKind::Public)));
    assert!(public.enabled && public.notify);
    let mut h = h;
    assert!(invalid(h.engine.scope_add("public", &h.now)));
    assert!(invalid(h.engine.scope_remove("public")));
}

#[test]
fn owner_scope_fields() {
    let h = H::new();
    let scope = h.scope(ORG);
    assert_eq!(scope.name, "org");
    assert_eq!(scope.kind, None);
    assert!(scope.warnings.is_empty());
    assert_eq!(scope.updated_at, None);
}

#[test]
fn updated_at_is_the_last_ingest_touching_the_scope() {
    let mut h = H::new();
    let at = h.at();
    h.prs(vec![pr("PR_1")]);
    assert_eq!(h.scope(ORG).updated_at, Some(at));
    assert_eq!(h.scope("public").updated_at, None);
}

#[test]
fn scope_command_errors() {
    let mut h = H::new();
    assert!(invalid(h.engine.scope_add(ORG, &h.now)), "duplicate");
    assert!(not_found(h.engine.scope_remove("nobody")));
    assert!(not_found(h.engine.scope_enable("nobody", &h.now)));
    assert!(not_found(h.engine.scope_disable("nobody")));
    assert!(not_found(h.engine.scope_notify("nobody", true)));
    assert!(not_found(h.engine.popover_opened("nobody")));
    assert!(not_found(h.engine.popover_closed("nobody")));
    let filter = Filter {
        scope: Some("nobody".into()),
        ..Filter::default()
    };
    assert!(not_found(h.engine.list(&filter, &h.now)));
    assert!(not_found(h.engine.activity(&filter, &h.now)));
    h.engine.scope_remove(ORG).unwrap();
    assert!(not_found(h.engine.scope_remove(ORG)), "already removed");
    assert!(not_found(h.engine.scope_disable(ORG)), "removed is unknown");
}

#[test]
fn a_disabled_scope_ignores_ingests_and_leaves_lists() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.engine.scope_disable(ORG).unwrap();
    assert!(h.cards(&Filter::default()).is_empty());
    assert!(
        h.engine
            .activity(&Filter::default(), &h.now)
            .unwrap()
            .is_empty()
    );
    let filter = Filter {
        scope: Some(ORG.into()),
        ..Filter::default()
    };
    assert!(
        h.cards(&filter).is_empty(),
        "an explicit disabled scope is empty"
    );

    let e = h.ev("E_2", "PR_1", EventKind::Comment);
    let r = h.reaction("C_1", "PR_1", &[("HEART", 1)]);
    let at = h.scope(ORG).updated_at;
    h.push(
        vec![IngestPr {
            title: "New".into(),
            ..pr("PR_1")
        }],
        vec![e],
        vec![r],
    );
    assert!(!h.has_row("E_2"));
    assert_eq!(h.scope(ORG).updated_at, at);

    h.engine.scope_enable(ORG, &h.now).unwrap();
    assert_eq!(h.card(&key("PR_1")).unwrap().title, "Title PR_1", "ignored");
    assert!(h.has_row("E_1"), "state survives");
}

#[test]
fn commands_on_prs_of_a_disabled_scope_are_not_found() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.snooze(&key("PR_1"));
    h.engine.scope_disable(ORG).unwrap();
    assert!(not_found(h.engine.done("E_1")));
    assert!(not_found(h.engine.undone("E_1")));
    assert!(not_found(h.engine.snooze(&key("PR_1"), &h.now)));
    assert!(not_found(h.engine.unsnooze(&key("PR_1"), &h.now)));
    assert!(not_found(h.engine.status(&key("PR_1"), &h.now)));
    assert!(not_found(h.engine.open_pr(&key("PR_1"))));
    assert!(not_found(h.engine.open_row("E_1")));
}

#[test]
fn commands_on_unreadable_prs_are_not_found() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.missing("PR_1");
    assert!(not_found(h.engine.done("E_1")));
    assert!(not_found(h.engine.snooze(&key("PR_1"), &h.now)));
    assert!(not_found(h.engine.unsnooze(&key("PR_1"), &h.now)));
    assert!(not_found(h.engine.status(&key("PR_1"), &h.now)));
    assert!(not_found(h.engine.open_pr(&key("PR_1"))));
    assert!(not_found(h.engine.open_row("E_1")));
}

#[test]
fn status_and_open_work_for_a_known_pr_without_a_card() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        is_draft: true,
        ..other("PR_1")
    }]);
    assert!(!h.visible("PR_1"));
    assert_eq!(h.engine.status(&key("PR_1"), &h.now).unwrap().id, "PR_1");
    assert_eq!(
        h.engine.open_pr(&key("PR_1")).unwrap(),
        "https://github.example/PR_1"
    );
}

#[test]
fn seen_applies_what_exists() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.seen(&["nobody", "E_1"]);
    assert!(h.row("E_1").seen_pending);
}

#[test]
fn removing_an_owner_moves_public_prs_with_done_and_snooze() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1"), other("PR_2")], vec![e], vec![]);
    h.engine.done("E_1").unwrap();
    h.snooze(&key("PR_2"));
    h.engine.scope_remove(ORG).unwrap();
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.scope, "public");
    assert!(card.rows[0].done);
    let card = h.card(&key("PR_2")).unwrap();
    assert_eq!(card.scope, "public");
    assert!(card.snoozed);
    assert!(!h.engine.scopes().iter().any(|s| s.id == ORG));
}

#[test]
fn adding_an_owner_back_restores_its_state() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    let private = IngestPr {
        is_private: true,
        ..pr("PR_1")
    };
    h.push(vec![private], vec![e], vec![]);
    h.engine.done("E_1").unwrap();
    h.engine.scope_notify(ORG, false).unwrap();
    h.engine.scope_remove(ORG).unwrap();
    assert!(h.cards(&Filter::default()).is_empty());
    assert!(
        not_found(h.engine.status(&key("PR_1"), &h.now)),
        "belongs to no scope"
    );
    h.engine.scope_add(ORG, &h.now).unwrap();
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.scope, ORG);
    assert!(card.rows[0].done);
    assert!(!h.scope(ORG).notify);
}

#[test]
fn an_ingest_with_an_unknown_pr_id_applies_nothing() {
    let mut h = H::new();
    let bad_event = h.ev("E_1", "PR_404", EventKind::Comment);
    let result = h.try_push(vec![pr("PR_1")], vec![bad_event], vec![]);
    assert!(invalid(result));
    assert!(h.card(&key("PR_1")).is_none());

    let bad_reaction = h.reaction("C_1", "PR_404", &[("HEART", 1)]);
    let result = h.try_push(vec![pr("PR_1")], vec![], vec![bad_reaction]);
    assert!(invalid(result));
    assert!(h.card(&key("PR_1")).is_none());
}

#[test]
fn a_pr_with_no_scope_is_not_recorded() {
    let mut h = H::new();
    let hidden = IngestPr {
        owner: "stranger".into(),
        is_private: true,
        ..pr("PR_1")
    };
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![hidden], vec![e], vec![]);
    assert!(!h.has_row("E_1"));
    let later = h.ev("E_2", "PR_1", EventKind::Comment);
    assert!(
        invalid(h.try_push(vec![], vec![later], vec![])),
        "still unknown"
    );
}

#[test]
fn config_table() {
    let cases = [
        ("launch_at_login", json!(true), json!(false), json!(1)),
        ("status_interval_minutes", json!(1), json!(2), json!(0)),
        ("reactions_interval_minutes", json!(3), json!(1), json!(0)),
        ("graphql_cost_cap", json!(1500), json!(100), json!(99)),
        ("notify_activity", json!(true), json!(false), json!("maybe")),
        ("notify_state", json!(true), json!(false), json!("maybe")),
        (
            "notify_reactions",
            json!(true),
            json!(false),
            json!("maybe"),
        ),
        (
            "snooze_return_time",
            json!("09:00"),
            json!("23:59"),
            json!("24:00"),
        ),
        (
            "bot_comments",
            json!("list_only"),
            json!("hide"),
            json!("loud"),
        ),
        (
            "include_team_requests",
            json!(true),
            json!(false),
            json!("maybe"),
        ),
        ("keep_watching_days", json!(3), json!(0), json!(-1)),
        ("drop_after_days", json!(14), json!(1), json!(0)),
    ];
    for (key, default, good, bad) in cases {
        let mut h = H::new();
        assert_eq!(h.engine.config_get(key).unwrap(), default, "{key} default");
        assert!(
            invalid(h.engine.config_set(key, &bad, &h.now.clone())),
            "{key} bad"
        );
        assert_eq!(
            h.engine.config_get(key).unwrap(),
            default,
            "{key} not stored"
        );
        assert_eq!(
            h.engine.config_set(key, &good, &h.now.clone()).unwrap(),
            good,
            "{key}"
        );
        assert_eq!(h.engine.config_get(key).unwrap(), good, "{key}");
    }
}

#[test]
fn the_command_line_sends_settings_as_text() {
    let cases = [
        ("notify_state", json!("false"), json!(false)),
        ("status_interval_minutes", json!("7"), json!(7)),
        ("snooze_return_time", json!("07:30"), json!("07:30")),
    ];
    for (key, text, want) in cases {
        let mut h = H::new();
        assert_eq!(
            h.engine.config_set(key, &text, &h.now.clone()).unwrap(),
            want
        );
    }
}

#[test]
fn return_time_format_table() {
    for bad in [
        "9:00", "09:0", "09-00", "0900", "09:60", "24:00", "", "ab:cd", "09:00:00", "+9:00",
    ] {
        let mut h = H::new();
        assert!(
            invalid(
                h.engine
                    .config_set("snooze_return_time", &json!(bad), &h.now.clone())
            ),
            "{bad}"
        );
    }
}

#[test]
fn unknown_config_keys_are_invalid() {
    let mut h = H::new();
    assert!(invalid(h.engine.config_get("nope")));
    assert!(invalid(h.engine.config_set(
        "nope",
        &json!(1),
        &h.now.clone()
    )));
}

#[test]
fn a_disabled_scope_reports_no_badge_or_dot_and_the_dot_returns_on_enable() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    assert_eq!((h.badge(), h.dot()), (1, true));
    h.engine.scope_disable(ORG).unwrap();
    assert_eq!((h.badge(), h.dot()), (0, false));
    h.engine.scope_enable(ORG, &h.now).unwrap();
    assert_eq!((h.badge(), h.dot()), (1, true));
}
