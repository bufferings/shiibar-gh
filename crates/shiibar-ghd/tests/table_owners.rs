//! Rule table: owners under an account, Public, disabled owners, commands
//! on PRs and settings. DESIGN.md, sections "Owners", "Settings" and "Wire
//! format".

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use shiibar_ghd::engine::{ActivityArgs, ListArgs};
use shiibar_ghd::model::OwnerKind;
use support::*;

fn add(h: &mut H, name: &str) -> String {
    let now = h.now.clone();
    h.engine
        .owner_add(ACCOUNT, name, OwnerKind::Org, None, &now)
        .unwrap()
}

#[test]
fn membership_table() {
    // (name, repo owner, private, owner of the card). `org` and Public are
    // registered; `gone` was added and removed.
    let cases = [
        ("registered owner, public repo", "org", false, Some("org")),
        ("registered owner, private repo", "org", true, Some("org")),
        (
            "unregistered owner, public repo",
            "stranger",
            false,
            Some("Public"),
        ),
        ("unregistered owner, private repo", "stranger", true, None),
        ("removed owner, public repo", "gone", false, Some("Public")),
        ("removed owner, private repo", "gone", true, None),
    ];
    for (name, owner, is_private, want) in cases {
        let mut h = H::new();
        let gone = add(&mut h, "gone");
        h.engine.owner_remove(&gone);
        h.prs(vec![IngestPr {
            owner: owner.into(),
            is_private,
            ..pr("PR_1")
        }]);
        let cards = h.cards();
        let got = cards.first().map(|c| {
            h.account()
                .owners
                .into_iter()
                .find(|o| o.id == c.owner)
                .unwrap()
                .name
        });
        assert_eq!(got.as_deref(), want, "{name}");
    }
}

#[test]
fn public_is_added_and_removed_like_an_owner() {
    // DESIGN.md, "Overview and scope": Public does not exist at first.
    let now = shiibar_ghd::clock::Now::fixed(T0, "Asia/Tokyo").unwrap();
    let mut engine = shiibar_ghd::engine::Engine::fresh(&now);
    assert!(engine.accounts().is_empty());
    engine.account_create(ACCOUNT, ME).unwrap();
    assert!(engine.accounts()[0].owners.is_empty());
    assert!(not_found(engine.owner_id(ACCOUNT, "public")));
    let id = engine
        .owner_add(ACCOUNT, "public", OwnerKind::Public, Some(5), &now)
        .unwrap();
    let owners = &engine.accounts()[0].owners;
    assert_eq!(owners.len(), 1);
    let public = &owners[0];
    assert_eq!(
        (public.id.as_str(), public.name.as_str()),
        (id.as_str(), "Public")
    );
    assert_eq!(
        public.kind,
        Lenient::Known(shiibar_gh_proto::OwnerKind::Public)
    );
    assert_eq!(public.github_id, None, "Public has no GitHub id");
    assert!(public.enabled && public.notify && public.skip_drafts);
    assert!(invalid(engine.owner_add(
        ACCOUNT,
        "public",
        OwnerKind::Public,
        None,
        &now
    )));
    for spelling in ["public", "PUBLIC"] {
        assert!(
            invalid(engine.owner_add(ACCOUNT, spelling, OwnerKind::Org, None, &now)),
            "an owner named {spelling} cannot be registered"
        );
    }
    assert_eq!(engine.owner_id(ACCOUNT, "PUBLIC"), Ok(id.clone()));
    engine.owner_remove(&id);
    assert!(engine.accounts()[0].owners.is_empty());
}

#[test]
fn removing_public_deletes_its_prs_and_adding_it_back_starts_empty() {
    let mut h = H::new();
    let stranger = IngestPr {
        owner: "stranger".into(),
        ..other("PR_1")
    };
    let e1 = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![stranger.clone()], vec![e1], vec![]);
    h.done("E_1");
    h.snooze("stranger/app#1");
    let public = h.owner_id("public");
    h.engine.owner_remove(&public);
    // DESIGN.md, "Owners": PRs, rows, Done and Snooze go, and do not come
    // back with a new Public.
    assert!(h.all_cards().is_empty());
    assert!(!h.has_row("E_1"));
    assert!(not_found(h.engine.done(&full("E_1"), true)));
    let now = h.now.clone();
    h.engine
        .owner_add(ACCOUNT, "public", OwnerKind::Public, None, &now)
        .unwrap();
    assert!(h.all_cards().is_empty());
    h.prs(vec![stranger]);
    let card = h.card("stranger/app#1").unwrap();
    assert!(!card.snoozed);
    assert!(card.rows.is_empty());
}

#[test]
fn owner_fields() {
    let h = H::new();
    let org = h.owner(ORG);
    assert_eq!(org.name, ORG);
    assert_eq!(org.kind, Lenient::Known(shiibar_gh_proto::OwnerKind::Org));
    assert_eq!(org.github_id, Some(100));
    assert!(org.enabled && org.notify && org.skip_drafts);
    assert_eq!((org.todo_count, org.pr_count), (0, 0));
    let ids: Vec<String> = h.account().owners.iter().map(|o| o.id.clone()).collect();
    assert!(ids.iter().all(|id| id.starts_with('o')), "{ids:?}");
}

#[test]
fn owner_counts_leave_out_snoozed_prs() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let b = h.ev("E_2", "PR_2", IngestKind::Comment);
    h.push(
        vec![other("PR_1"), other("PR_2"), pr("PR_3")],
        vec![a, b],
        vec![],
    );
    assert_eq!((h.owner(ORG).todo_count, h.owner(ORG).pr_count), (2, 3));
    h.snooze(&key("PR_1"));
    assert_eq!((h.owner(ORG).todo_count, h.owner(ORG).pr_count), (1, 2));
    assert_eq!(h.badge(), 1);
}

#[test]
fn lookup_errors() {
    let h = H::new();
    assert!(not_found(h.engine.owner_id(ACCOUNT, "nobody")));
    assert!(not_found(h.engine.account_id("nobody")));
    assert!(not_found(h.engine.status("nobody", &key("PR_1"), &h.now)));
    let mut h = H::new();
    let now = h.now.clone();
    assert!(invalid(h.engine.owner_add(
        ACCOUNT,
        "ORG",
        OwnerKind::Org,
        None,
        &now
    )));
    assert!(invalid(h.engine.owner_add(
        ACCOUNT,
        "bad name",
        OwnerKind::Org,
        None,
        &now
    )));
    assert!(not_found(h.engine.owner_add(
        "9999",
        "x",
        OwnerKind::Org,
        None,
        &now
    )));
}

#[test]
fn a_disabled_owner_ignores_ingests_and_leaves_lists() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    let org = h.owner_id(ORG);
    h.engine.owner_enable(&org, false, &h.now.clone());
    assert!(h.cards().is_empty());
    assert!(h.activity(ActivityArgs::default()).is_empty());
    let named = ListArgs {
        owner: Some(ORG.into()),
        ..ListArgs::default()
    };
    assert!(
        h.list(named).is_empty(),
        "an explicit disabled owner is empty"
    );

    let e = h.ev("E_2", "PR_1", IngestKind::Comment);
    let r = h.reaction("C_1", "PR_1", &[("HEART", 1)]);
    h.push(
        vec![IngestPr {
            title: "New".into(),
            ..pr("PR_1")
        }],
        vec![e],
        vec![r],
    );
    assert!(!h.has_row("E_2"));

    h.engine.owner_enable(&org, true, &h.now.clone());
    assert_eq!(h.card(&key("PR_1")).unwrap().title, "Title PR_1", "ignored");
    assert!(h.has_row("E_1"), "state survives");
}

#[test]
fn commands_on_prs_of_a_disabled_owner_are_not_found() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.snooze(&key("PR_1"));
    let org = h.owner_id(ORG);
    h.engine.owner_enable(&org, false, &h.now.clone());
    let now = h.now.clone();
    assert!(not_found(h.engine.done(&full("E_1"), true)));
    assert!(not_found(h.engine.done(&full("E_1"), false)));
    assert!(not_found(h.engine.todo(&full("E_1"), true, &now)));
    assert!(not_found(h.engine.snooze(ME, &key("PR_1"), &now)));
    assert!(not_found(h.engine.unsnooze(ME, &key("PR_1"), &now)));
    assert!(not_found(h.engine.status(ME, &key("PR_1"), &now)));
    assert!(not_found(h.engine.open_pr(ME, &key("PR_1"))));
    assert!(not_found(h.engine.open_row(None, &full("E_1"))));
}

#[test]
fn commands_on_unreadable_prs_are_not_found() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.missing("PR_1");
    let now = h.now.clone();
    assert!(not_found(h.engine.done(&full("E_1"), true)));
    assert!(not_found(h.engine.snooze(ME, &key("PR_1"), &now)));
    assert!(not_found(h.engine.unsnooze(ME, &key("PR_1"), &now)));
    assert!(not_found(h.engine.status(ME, &key("PR_1"), &now)));
    assert!(not_found(h.engine.open_pr(ME, &key("PR_1"))));
    assert!(not_found(h.engine.open_row(None, &full("E_1"))));
}

#[test]
fn a_row_of_another_account_is_not_found_under_this_one() {
    let mut h = H::new();
    h.add_other();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    assert!(h.engine.open_row(Some(ME), &full("E_1")).is_ok());
    assert!(not_found(h.engine.open_row(Some(YOU), &full("E_1"))));
    assert!(not_found(h.engine.status(YOU, &key("PR_1"), &h.now)));
}

#[test]
fn status_and_open_work_for_a_known_pr_without_a_card() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        is_draft: true,
        ..other("PR_1")
    }]);
    assert!(!h.visible("PR_1"));
    assert_eq!(
        h.engine.status(ME, &key("PR_1"), &h.now).unwrap().id,
        full("PR_1")
    );
    assert_eq!(
        h.engine.open_pr(ME, &key("PR_1")).unwrap(),
        "https://github.example/PR_1"
    );
}

#[test]
fn seen_applies_what_exists() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.seen(&["nobody", "E_1"]);
    assert!(h.row("E_1").seen_pending);
}

#[test]
fn removing_an_owner_deletes_its_prs_even_public_ones() {
    // DESIGN.md, "Owners": removal deletes the owner's PRs; a public PR of
    // the removed owner comes back under Public only as a new PR.
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1"), other("PR_2")], vec![e], vec![]);
    h.done("E_1");
    h.snooze(&key("PR_2"));
    let org = h.owner_id(ORG);
    h.engine.owner_remove(&org);
    assert!(h.all_cards().is_empty());
    assert!(!h.has_row("E_1"));
    assert!(!h.account().owners.iter().any(|o| o.id == org));
    h.prs(vec![other("PR_2")]);
    let card = h.card(&key("PR_2")).unwrap();
    assert_eq!(card.owner, h.owner_id("public"));
    assert!(!card.snoozed);
}

#[test]
fn adding_an_owner_back_does_not_restore_its_state() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    let private = IngestPr {
        is_private: true,
        ..pr("PR_1")
    };
    h.push(vec![private.clone()], vec![e.clone()], vec![]);
    h.done("E_1");
    let org = h.owner_id(ORG);
    h.engine.owner_notify(&org, false);
    h.engine.owner_remove(&org);
    assert!(h.cards().is_empty());
    assert!(not_found(h.engine.status(ME, &key("PR_1"), &h.now)));
    let again = add(&mut h, ORG);
    assert_ne!(again, org);
    assert!(h.owner(ORG).notify, "settings start from the defaults");
    let mut fresh = e;
    fresh.occurred_at = h.at();
    h.push(vec![private], vec![fresh], vec![]);
    assert!(!h.row("E_1").done, "Done marks are gone");
}

#[test]
fn removing_an_account_removes_its_owners_and_prs() {
    let mut h = H::new();
    h.add_other();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e.clone()], vec![]);
    h.push_to(OTHER, vec![pr("PR_1")], vec![e], vec![]).unwrap();
    h.engine.account_remove(OTHER);
    assert!(h.engine.account_value(OTHER).is_none());
    assert!(h.engine.row_record("1002:E_1").is_none());
    assert!(h.engine.pr_record("1002:PR_1").is_none());
    assert!(h.has_row("E_1"), "the other account keeps its rows");
    assert_eq!(h.engine.accounts().len(), 1);
}

#[test]
fn an_ingest_with_an_unknown_pr_id_applies_nothing() {
    let mut h = H::new();
    let bad_event = h.ev("E_1", "PR_404", IngestKind::Comment);
    let result = h.try_push(vec![pr("PR_1")], vec![bad_event], vec![]);
    assert!(invalid(result));
    assert!(h.card(&key("PR_1")).is_none());

    let bad_reaction = h.reaction("C_1", "PR_404", &[("HEART", 1)]);
    let result = h.try_push(vec![pr("PR_1")], vec![], vec![bad_reaction]);
    assert!(invalid(result));
    assert!(h.card(&key("PR_1")).is_none());
}

#[test]
fn an_ingest_for_an_unknown_account_is_not_found() {
    let mut h = H::new();
    let result = h.push_to("9999", vec![pr("PR_1")], vec![], vec![]);
    assert!(not_found(result));
}

#[test]
fn a_pr_with_no_owner_is_not_recorded() {
    let mut h = H::new();
    let hidden = IngestPr {
        owner: "stranger".into(),
        is_private: true,
        ..pr("PR_1")
    };
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![hidden], vec![e], vec![]);
    assert!(!h.has_row("E_1"));
    let later = h.ev("E_2", "PR_1", IngestKind::Comment);
    assert!(
        invalid(h.try_push(vec![], vec![later], vec![])),
        "still unknown"
    );
}

#[test]
fn config_table() {
    // DESIGN.md, "Wire format": the M4 keys. The 0.1 keys are gone.
    let cases = [
        ("launch_at_login", json!(true), json!(false), json!(1)),
        ("status_interval_minutes", json!(1), json!(2), json!(0)),
        ("reactions_interval_minutes", json!(3), json!(1), json!(0)),
        (
            "snooze_return_time",
            json!("09:00"),
            json!("23:59"),
            json!("24:00"),
        ),
        ("keep_watching_days", json!(3), json!(0), json!(-1)),
        ("drop_after_days", json!(14), json!(1), json!(0)),
        ("appearance", json!("system"), json!("dark"), json!("blue")),
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
    for gone in [
        "graphql_cost_cap",
        "notify_activity",
        "notify_state",
        "notify_reactions",
        "bot_comments",
        "include_team_requests",
    ] {
        let h = H::new();
        assert!(invalid(h.engine.config_get(gone)), "{gone}");
    }
}

#[test]
fn the_command_line_sends_settings_as_text() {
    let cases = [
        ("launch_at_login", json!("false"), json!(false)),
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
fn a_disabled_owner_reports_no_count_and_the_dot_returns_on_enable() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    assert_eq!((h.badge(), h.dot()), (1, true));
    let org = h.owner_id(ORG);
    h.engine.owner_enable(&org, false, &h.now.clone());
    assert_eq!(h.badge(), 0);
    h.engine.owner_enable(&org, true, &h.now.clone());
    assert_eq!((h.badge(), h.dot()), (1, true));
}

#[test]
fn names_compare_without_regard_to_case() {
    let h = H::new();
    let org = h.owner_id(ORG);
    for spelling in ["ORG", "Org", "oRG"] {
        assert_eq!(h.engine.owner_id(ACCOUNT, spelling), Ok(org.clone()));
    }
    for spelling in ["public", "Public", "PUBLIC"] {
        assert_eq!(
            h.engine.owner_id(ACCOUNT, spelling),
            Ok(h.owner_id("public"))
        );
    }
    for spelling in ["me", "ME", "Me"] {
        assert_eq!(h.engine.account_id(spelling), Ok(ACCOUNT.into()));
    }
}

#[test]
fn a_pr_owner_finds_its_owner_in_any_case() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    let private = IngestPr {
        owner: "ORG".into(),
        is_private: true,
        ..other("PR_1")
    };
    h.push(vec![private], vec![e], vec![]);
    let card = h.engine.status(ME, "org/app#1", &h.now).unwrap();
    assert_eq!(card.owner, h.owner_id(ORG));
    assert_eq!(card.pr, "ORG/app#1", "the PR keeps GitHub's spelling");
    assert_eq!(h.badge(), 1);
    assert_eq!(
        h.engine.open_pr("ME", "Org/app#1").unwrap(),
        "https://github.example/PR_1"
    );
    h.snooze("ORG/app#1");
    h.unsnooze("oRg/app#1");
    // DESIGN.md, "CLI": the repository name ignores case too.
    assert_eq!(
        h.engine.status(ME, "org/APP#1", &h.now).unwrap().id,
        full("PR_1")
    );
    assert!(not_found(h.engine.status(ME, "org/other#1", &h.now)));
}

#[test]
fn owner_filters_and_popovers_find_their_target_in_any_case() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let named = ListArgs {
        account: Some("ME".into()),
        owner: Some("ORG".into()),
        ..ListArgs::default()
    };
    assert_eq!(h.list(named).len(), 1);
    let activity = h.activity(ActivityArgs {
        owners: vec!["Org".into()],
        ..ActivityArgs::default()
    });
    assert!(activity.is_empty());
    h.engine.popover_opened("ME").unwrap();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.events(vec![e]);
    assert!(!h.dot(), "the open state reached the same account");
    h.seen(&["E_1"]);
    h.engine.popover_closed("Me").unwrap();
    assert!(!h.row("E_1").unread);
    assert!(not_found(h.engine.list(
        &ListArgs {
            owner: Some("nobody".into()),
            ..ListArgs::default()
        },
        &h.now
    )));
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
        let e = h.ev("E_1", "PR_1", IngestKind::Comment);
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
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.open();
    h.close();
    h.prs(vec![pr("PR_1")]);
    assert!(!h.dot());
}

#[test]
fn a_pr_both_missing_and_fetched_in_one_ingest_stays_readable() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    h.open();
    h.close();
    let ingest = Ingest {
        missing_pr_ids: vec!["PR_1".into()],
        prs: vec![pr("PR_1")],
        ..Ingest::default()
    };
    h.engine.ingest(ACCOUNT, ingest, &h.now).unwrap();
    assert!(h.visible("PR_1"));
    assert!(!h.dot(), "it never went away");
}

#[test]
fn succeeded_owners_move_the_event_window() {
    let mut h = H::new();
    let ingest = Ingest {
        succeeded_owners: Some(vec!["ORG".into(), "public".into(), "nobody".into()]),
        ..Ingest::default()
    };
    let at = h.at();
    h.engine.ingest(ACCOUNT, ingest, &h.now).unwrap();
    let org = h.engine.owner_record(&h.owner_id(ORG)).unwrap().fetched_at;
    let public = h
        .engine
        .owner_record(&h.owner_id("public"))
        .unwrap()
        .fetched_at;
    assert_eq!((org, public), (Some(at), Some(at)));
}

#[test]
fn copying_a_table_copies_only_the_table() {
    let mut h = H::new();
    let org = h.owner_id(ORG);
    let public = h.owner_id("public");
    let now = h.now.clone();
    h.engine
        .owner_events_set(
            &public,
            EventKind::MergedClosed,
            EventColumn::Notify,
            true,
            &now,
        )
        .unwrap_or_else(|_| panic!("set"));
    h.engine.owner_notify(&public, false);
    h.engine
        .owner_exclusions_set(
            &public,
            ExclusionKind::User,
            "bot",
            ExclusionState::Hidden,
            &now,
        )
        .unwrap();
    h.engine.owner_events_copy(&public, &org, &now).unwrap();
    assert!(h.engine.owner_events(&org)["merged_closed"].notify);
    assert!(h.owner(ORG).notify, "the switches stay");
    assert!(
        h.engine.owner_exclusions(&org).users.is_empty(),
        "Exclusions stay"
    );
}

#[test]
fn exclusion_names_are_checked_and_compared_without_case() {
    let mut h = H::new();
    let org = h.owner_id(ORG);
    let now = h.now.clone();
    for bad in ["app", "a/b/c", "/app", "org/", "org/a pp"] {
        assert!(
            invalid(h.engine.owner_exclusions_set(
                &org,
                ExclusionKind::Repo,
                bad,
                ExclusionState::Hidden,
                &now
            )),
            "{bad}"
        );
    }
    h.engine
        .owner_exclusions_set(
            &org,
            ExclusionKind::Repo,
            "Org/App",
            ExclusionState::Hidden,
            &now,
        )
        .unwrap();
    h.engine
        .owner_exclusions_set(
            &org,
            ExclusionKind::Repo,
            "org/app",
            ExclusionState::ListOnly,
            &now,
        )
        .unwrap();
    let list = h.engine.owner_exclusions(&org).repos;
    assert_eq!(list.len(), 1, "set changes the state of the same name");
    assert_eq!(list[0].name, "Org/App");
    assert_eq!(list[0].state, Lenient::Known(ExclusionState::ListOnly));
    assert!(not_found(h.engine.owner_exclusions_remove(
        &org,
        ExclusionKind::User,
        "nobody",
        &now
    )));
    h.engine
        .owner_exclusions_remove(&org, ExclusionKind::Repo, "ORG/APP", &now)
        .unwrap();
    assert!(h.engine.owner_exclusions(&org).repos.is_empty());
}
