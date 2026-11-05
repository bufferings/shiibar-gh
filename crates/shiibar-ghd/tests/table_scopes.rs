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
fn public_is_added_and_removed_like_an_owner() {
    // A database without saved state has no scope at all.
    let now = shiibar_ghd::clock::Now::fixed(T0, "Asia/Tokyo").unwrap();
    let mut engine = shiibar_ghd::engine::Engine::fresh(&now);
    assert!(engine.scopes().is_empty());
    assert!(not_found(engine.scope_remove("public")));
    engine.scope_add("Public", &now).unwrap();
    let scopes = engine.scopes();
    assert_eq!(scopes.len(), 1);
    let public = &scopes[0];
    assert_eq!(
        (public.id.as_str(), public.name.as_str()),
        ("public", "Public")
    );
    assert_eq!(public.kind, Some(Lenient::Known(ScopeKind::Public)));
    assert_eq!(public.color, Lenient::Known(ScopeColor::Beige));
    assert!(public.enabled && public.notify);
    for spelling in ["public", "PUBLIC"] {
        assert!(invalid(engine.scope_add(spelling, &now)), "{spelling}");
    }
    for spelling in ["notifications", "Notifications"] {
        assert!(invalid(engine.scope_add(spelling, &now)), "{spelling}");
    }
    assert_eq!(engine.scope_remove("PUBLIC"), Ok(None), "no token recorded");
    assert!(engine.scopes().is_empty());
    assert!(not_found(engine.token_key("public")));
    engine.scope_add("public", &now).unwrap();
    assert_eq!(engine.token_key("public"), Ok("public".into()));
}

#[test]
fn without_public_its_prs_stay_hidden_and_come_back_with_their_state() {
    let mut h = H::new();
    let stranger = IngestPr {
        owner: "stranger".into(),
        ..other("PR_1")
    };
    let e1 = h.ev("E_1", "PR_1", EventKind::Comment);
    let e2 = h.ev("E_2", "PR_2", EventKind::Comment);
    h.push(vec![stranger, other("PR_2")], vec![e1, e2], vec![]);
    h.engine.done("E_1").unwrap();
    h.snooze("stranger/app#1");
    assert_eq!(h.scope("public").badge, 0, "snoozed");

    h.engine.scope_remove("public").unwrap();
    h.engine.scope_remove(ORG).unwrap();
    // org's PR would move to Public, which is gone too.
    assert!(h.engine.scopes().is_empty());
    assert!(h.cards(&show_snoozed()).is_empty());
    assert!(not_found(h.engine.done("E_2")));

    h.engine.scope_add("public", &h.now).unwrap();
    let cards = h.cards(&show_snoozed());
    let scopes: Vec<&str> = cards.iter().map(|c| c.scope.as_str()).collect();
    assert_eq!(scopes, ["public", "public"], "both PRs show under Public");
    assert!(h.card("stranger/app#1").unwrap().snoozed);
    assert!(h.row("E_1").done);
    assert!(h.row("E_2").unread && !h.row("E_2").done);
    assert_eq!(h.scope("public").badge, 1);
}

#[test]
fn scope_colors_cycle_in_the_order_scopes_are_added() {
    let mut h = H::new();
    assert_eq!(h.scope(ORG).color, Lenient::Known(ScopeColor::Gray));
    assert_eq!(h.scope("public").color, Lenient::Known(ScopeColor::Beige));
    let names = ["b", "c", "d", "e", "f", "g"];
    for name in names {
        h.engine.scope_add(name, &h.now).unwrap();
    }
    let colors: Vec<Lenient<ScopeColor>> = names.iter().map(|n| h.scope(n).color).collect();
    use ScopeColor::*;
    let want = [Green, Blue, Purple, Pink, Beige, Gray];
    assert_eq!(colors, want.map(Lenient::Known));

    h.engine.scope_color("B", ScopeColor::Purple).unwrap();
    assert_eq!(h.scope("b").color, Lenient::Known(ScopeColor::Purple));
    h.engine.scope_remove("b").unwrap();
    h.engine.scope_add("b", &h.now).unwrap();
    assert_eq!(
        h.scope("b").color,
        Lenient::Known(ScopeColor::Purple),
        "adding again keeps the color"
    );
    assert!(not_found(h.engine.scope_color("nobody", ScopeColor::Blue)));
}

#[test]
fn owner_scope_fields() {
    let h = H::new();
    let scope = h.scope(ORG);
    assert_eq!(scope.name, "org");
    assert_eq!(scope.kind, None);
    let kinds: Vec<String> = scope.warnings.iter().map(|w| w.kind.as_text()).collect();
    assert_eq!(kinds, ["no_token", "no_token"], "no token registered yet");
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

#[test]
fn owners_compare_without_regard_to_case() {
    let mut h = H::new();
    assert!(invalid(h.engine.scope_add("ORG", &h.now)), "a duplicate");
    for public in ["public", "Public", "PUBLIC"] {
        assert!(invalid(h.engine.scope_add(public, &h.now)), "{public}");
    }

    h.engine.scope_notify("ORG", false).unwrap();
    assert!(!h.scope(ORG).notify);
    h.engine.scope_disable("Org").unwrap();
    assert!(!h.scope(ORG).enabled);
    h.engine.scope_enable("oRG", &h.now).unwrap();
    assert!(h.scope(ORG).enabled);
    h.engine.scope_disable("PUBLIC").unwrap();
    assert!(!h.scope("public").enabled);
    h.engine.scope_enable("Public", &h.now).unwrap();
    assert_eq!(
        h.engine.scopes().len(),
        2,
        "no scope was added by a spelling"
    );
}

#[test]
fn a_pr_owner_finds_its_scope_in_any_case() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    let private = IngestPr {
        owner: "ORG".into(),
        is_private: true,
        ..other("PR_1")
    };
    h.push(vec![private], vec![e], vec![]);
    let card = h.engine.status("org/app#1", &h.now).unwrap();
    assert_eq!(card.scope, ORG);
    assert_eq!(card.pr, "ORG/app#1", "the PR keeps GitHub's spelling");
    assert_eq!(h.badge(), 1);
    assert_eq!(
        h.engine.open_pr("Org/app#1").unwrap(),
        "https://github.example/PR_1"
    );
    h.snooze("ORG/app#1");
    h.unsnooze("oRg/app#1");
    // DESIGN.md, "CLI": the repository name ignores case too.
    assert_eq!(h.engine.status("org/APP#1", &h.now).unwrap().id, "PR_1");
    assert!(not_found(h.engine.status("org/other#1", &h.now)));
}

#[test]
fn scope_filters_and_popovers_find_a_scope_in_any_case() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let filter = Filter {
        scope: Some("ORG".into()),
        ..Filter::default()
    };
    assert_eq!(h.cards(&filter).len(), 1);
    assert_eq!(h.engine.activity(&filter, &h.now).unwrap().len(), 0);
    h.engine.popover_opened("ORG").unwrap();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.events(vec![e]);
    assert!(!h.dot(), "the open state reached the same scope");
    h.seen(&["E_1"]);
    h.engine.popover_closed("Org").unwrap();
    assert!(!h.row("E_1").unread);
}

#[test]
fn adding_an_owner_back_in_another_case_restores_the_same_scope() {
    let mut h = H::new();
    h.engine.scope_notify(ORG, false).unwrap();
    h.engine.scope_remove("ORG").unwrap();
    assert!(!h.engine.scopes().iter().any(|s| s.id == ORG));
    h.engine.scope_add("Org", &h.now).unwrap();
    assert_eq!(h.engine.scopes().len(), 2);
    let scope = h.scope(ORG);
    assert_eq!(scope.name, ORG, "the first spelling stays");
    assert!(!scope.notify, "state restored");
}

#[test]
fn a_readable_again_pr_raises_the_dot_for_unread_rows() {
    // (name, unread row, snoozed, popover open, dot afterwards)
    let cases = [
        ("unread row", true, false, false, true),
        ("nothing unread", false, false, false, false),
        ("popover open", true, false, true, false),
        ("still snoozed", true, true, false, false),
    ];
    for (name, unread, snoozed, open, want) in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", EventKind::Comment);
        h.push(vec![pr("PR_1")], vec![e], vec![]);
        if !unread {
            h.seen(&["E_1"]);
            h.close();
        }
        if snoozed {
            h.snooze(&key("PR_1"));
        }
        h.open();
        h.close();
        assert!(!h.dot(), "{name}: cleared by opening");
        h.missing("PR_1");
        if open {
            h.open();
        }
        h.prs(vec![pr("PR_1")]);
        assert_eq!(h.dot(), want, "{name}");
    }
}

#[test]
fn an_ordinary_fetch_of_a_readable_pr_does_not_raise_the_dot() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.open();
    h.close();
    h.prs(vec![pr("PR_1")]);
    assert!(!h.dot());
}

#[test]
fn a_pr_both_missing_and_fetched_in_one_ingest_stays_readable() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.open();
    h.close();
    let ingest = Ingest {
        viewer: ME.into(),
        missing_pr_ids: vec!["PR_1".into()],
        prs: vec![pr("PR_1")],
        events: vec![],
        reactions: vec![],
        succeeded_scopes: None,
    };
    h.engine.ingest(ingest, &h.now).unwrap();
    assert!(h.visible("PR_1"));
    assert!(!h.dot(), "it never went away");
}

mod moved_to_public {
    use super::*;
    use shiibar_ghd::model::NotifyState;

    #[test]
    fn the_reaction_baseline_moves_with_the_pr() {
        let mut h = H::new();
        h.prs(vec![pr("PR_1")]);
        let mut r = h.reaction("C_1", "PR_1", &[("HEART", 2)]);
        h.push(vec![], vec![], vec![r.clone()]);
        h.engine.scope_remove(ORG).unwrap();
        r.counts.insert("HEART".into(), 3);
        h.push(vec![], vec![], vec![r]);
        let rows = h.engine.activity(&Filter::default(), &h.now).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(
            rows[0].counts.as_ref().unwrap()["HEART"],
            1,
            "only the increase"
        );
    }

    #[test]
    fn undelivered_rows_are_summarized_under_public() {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", EventKind::Comment);
        h.push(vec![other("PR_1")], vec![e], vec![]);
        h.offline();
        h.engine.scope_remove(ORG).unwrap();
        let out = h.reconnect();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].scope, "public");
        assert_eq!(out[0].title, "Public · Comment");
    }

    #[test]
    fn a_snooze_record_returns_under_public() {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.snooze(&key("PR_1"));
        let e = h.ev("E_1", "PR_1", EventKind::Comment);
        h.events(vec![e]);
        h.engine.scope_remove(ORG).unwrap();
        assert_eq!(h.row("E_1").notify, NotifyState::Held);
        h.advance(DAY);
        h.tick();
        let out = h.delivered();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].title, "Public · Back from Snooze");
        assert_eq!(out[0].rows, ["E_1"]);
    }

    #[test]
    fn delivery_checks_public_settings_not_the_old_scope() {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", EventKind::Comment);
        h.push(vec![other("PR_1")], vec![e], vec![]);
        h.offline();
        h.engine.scope_remove(ORG).unwrap();
        h.engine.scope_notify("public", false).unwrap();
        assert!(h.reconnect().is_empty());
        assert_eq!(h.row("E_1").notify, NotifyState::None);
    }

    #[test]
    fn a_disabled_public_also_clears_the_record() {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", EventKind::Comment);
        h.push(vec![other("PR_1")], vec![e], vec![]);
        h.offline();
        h.engine.scope_remove(ORG).unwrap();
        h.engine.scope_disable("public").unwrap();
        assert!(h.reconnect().is_empty());
        assert_eq!(h.row("E_1").notify, NotifyState::None);
    }
}
