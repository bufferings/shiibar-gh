//! Rule tables: accounts and owners, the event table, Exclusions and
//! notification titles. DESIGN.md, "Row kinds and states", "Applying the
//! table", "Exclusions", "Review requested rows" and "macOS notifications".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::engine::{ActivityArgs, ListArgs};
use shiibar_ghd::model::NotifyState;
use support::*;

#[test]
fn the_same_owner_under_two_accounts_keeps_rows_and_notifications_apart() {
    let mut h = H::new();
    h.add_other();
    let ev = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![ev.clone()], vec![]);
    h.push_to(
        OTHER,
        vec![IngestPr {
            author: YOU.into(),
            ..pr("PR_1")
        }],
        vec![ev],
        vec![],
    )
    .unwrap();
    // One PR node, two cards and two rows: the key holds the account.
    let mine = h.list(ListArgs {
        account: Some(ME.into()),
        ..ListArgs::default()
    });
    let yours = h.list(ListArgs {
        account: Some(YOU.into()),
        ..ListArgs::default()
    });
    assert_eq!(mine.len(), 1);
    assert_eq!(yours.len(), 1);
    assert_ne!(mine[0].id, yours[0].id);
    assert_eq!(mine[0].rows[0].id, "1001:E_1");
    assert_eq!(yours[0].rows[0].id, "1002:E_1");
    let sent = h.delivered();
    let titles: Vec<&str> = sent.iter().map(|n| n.title.as_str()).collect();
    assert_eq!(titles, ["me · Comment on my PR", "you · Comment on my PR"]);
    // Reading on one account leaves the other.
    h.read(&["E_1"]);
    assert!(!h.wire_row("E_1").unwrap().unread);
    let other = h
        .list(ListArgs {
            account: Some(YOU.into()),
            ..ListArgs::default()
        })
        .remove(0);
    assert!(other.rows[0].unread);
}

#[test]
fn the_table_decides_notify_when_the_row_is_made() {
    let cases: &[(&str, EventKind, bool, IngestKind, bool)] = &[
        // name, cell, Notify, kind, notified
        (
            "comment default",
            EventKind::Comment,
            true,
            IngestKind::Comment,
            true,
        ),
        (
            "comment notify off",
            EventKind::Comment,
            false,
            IngestKind::Comment,
            false,
        ),
        (
            "approved default",
            EventKind::Approved,
            true,
            IngestKind::Approved,
            true,
        ),
        (
            "merged notify on",
            EventKind::MergedClosed,
            true,
            IngestKind::Merged,
            true,
        ),
    ];
    for (name, event, on, kind, notified) in cases {
        let mut h = H::new();
        h.table(*event, EventColumn::Notify, *on);
        let ev = h.ev("E_1", "PR_1", *kind);
        h.push(vec![pr("PR_1")], vec![ev], vec![]);
        let id = if *kind == IngestKind::Approved {
            "E_1:approved"
        } else {
            "E_1"
        };
        assert!(h.wire_row(id).unwrap().unread, "{name}: unread");
        assert_eq!(!h.delivered().is_empty(), *notified, "{name}: notified");
    }
}

#[test]
fn changing_the_table_leaves_existing_rows() {
    let mut h = H::new();
    let ev = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![ev], vec![]);
    h.table(EventKind::Comment, EventColumn::Notify, false);
    assert_eq!(h.row("E_1").notify, NotifyState::Pending, "made to notify");
    let ev = h.ev("E_2", "PR_1", IngestKind::Comment);
    h.events(vec![ev]);
    assert_eq!(
        h.row("E_2").notify,
        NotifyState::None,
        "made after the change"
    );
}

#[test]
fn list_is_a_filter_that_applies_at_once() {
    let mut h = H::new();
    let ev = h.ev("E_2", "PR_2", IngestKind::Comment);
    h.push(vec![pr("PR_2")], vec![ev], vec![]);
    h.delivered();
    assert!(h.wire_row("E_2").is_some());
    h.table(EventKind::Comment, EventColumn::List, false);
    assert!(h.wire_row("E_2").is_none(), "hidden at once");
    // Recorded while off: read, no notification.
    let ev = h.ev("E_3", "PR_2", IngestKind::Comment);
    h.events(vec![ev]);
    assert!(h.has_row("E_3"));
    assert!(h.delivered().is_empty());
    h.table(EventKind::Comment, EventColumn::List, true);
    let back = h.wire_row("E_3").unwrap();
    assert!(!back.unread);
    assert!(
        h.wire_row("E_2").unwrap().unread,
        "rows from before come back as they were"
    );
}

#[test]
fn list_off_turns_notify_off_and_notify_needs_list() {
    let mut h = H::new();
    let owner = h.owner_id(ORG);
    h.table(EventKind::Mentioned, EventColumn::List, false);
    let cell = h.engine.owner_events(&owner)["mentioned"];
    assert!(!cell.list && !cell.notify);
    let refused = h.engine.owner_events_set(
        &owner,
        EventKind::Mentioned,
        EventColumn::Notify,
        true,
        &h.now,
    );
    assert!(invalid(refused));
    h.table(EventKind::Mentioned, EventColumn::List, true);
    let cell = h.engine.owner_events(&owner)["mentioned"];
    assert!(cell.list && !cell.notify, "Notify stays off");
}

#[test]
fn the_table_has_two_columns_with_the_design_defaults() {
    // DESIGN.md, "Row kinds and states": every kind List on; Notify off for
    // Added to merge queue and Merged / Closed only.
    let h = H::new();
    let events = h.engine.owner_events(&h.owner_id(ORG));
    assert_eq!(events.len(), 16);
    for (name, cell) in &events {
        let quiet = name == "merge_queue_added" || name == "merged_closed";
        assert!(cell.list, "{name}");
        assert_eq!(cell.notify, !quiet, "{name}");
    }
    let wire = serde_json::to_value(events["comment"]).unwrap();
    assert_eq!(wire, serde_json::json!({"list": true, "notify": true}));
}

#[test]
fn exclusions_hidden_and_list_only() {
    // name, kind, name, state, shown, unread, notified
    let cases: &[(&str, ExclusionKind, &str, ExclusionState, bool, bool, bool)] = &[
        (
            "user list only",
            ExclusionKind::User,
            "alice",
            ExclusionState::ListOnly,
            true,
            true,
            false,
        ),
        (
            "user hidden",
            ExclusionKind::User,
            "ALICE",
            ExclusionState::Hidden,
            false,
            false,
            false,
        ),
        (
            "a REST bot login does not name the GraphQL login",
            ExclusionKind::User,
            "alice[bot]",
            ExclusionState::Hidden,
            true,
            true,
            true,
        ),
        (
            "repo list only",
            ExclusionKind::Repo,
            "org/app",
            ExclusionState::ListOnly,
            true,
            true,
            false,
        ),
        (
            "repo hidden",
            ExclusionKind::Repo,
            "Org/App",
            ExclusionState::Hidden,
            false,
            false,
            false,
        ),
        (
            "another user",
            ExclusionKind::User,
            "bob",
            ExclusionState::Hidden,
            true,
            true,
            true,
        ),
    ];
    for (name, kind, who, state, shown, unread, notified) in cases {
        let mut h = H::new();
        h.exclude(*kind, who, *state);
        let ev = h.ev("E_1", "PR_1", IngestKind::Comment);
        h.push(vec![pr("PR_1")], vec![ev], vec![]);
        let row = h.wire_row("E_1");
        assert_eq!(row.is_some(), *shown, "{name}: shown");
        assert_eq!(row.is_some_and(|r| r.unread), *unread, "{name}: unread");
        assert_eq!(!h.delivered().is_empty(), *notified, "{name}: notified");
    }
}

#[test]
fn a_hidden_repository_has_no_card_and_comes_back_read() {
    let mut h = H::new();
    h.exclude(ExclusionKind::Repo, "org/app", ExclusionState::Hidden);
    let ev = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![ev], vec![]);
    assert!(h.card(&key("PR_1")).is_none());
    assert_eq!(h.owner(ORG).pr_count, 0);
    assert!(!h.dot());
    h.include(ExclusionKind::Repo, "org/app");
    let row = h.wire_row("E_1").unwrap();
    assert!(!row.unread, "recorded while hidden: read");
    assert_eq!(h.owner(ORG).pr_count, 1);
}

#[test]
fn a_team_review_request_counts_only_while_its_list_is_on() {
    let mut h = H::new();
    let ev = h.ev("E_1", "PR_1", IngestKind::TeamReviewRequested);
    let p = IngestPr {
        requested_team: true,
        ..other("PR_1")
    };
    h.push(vec![p], vec![ev], vec![]);
    assert_eq!(h.badge(), 1);
    // List off: no row shown, no count, and the Review requested filter
    // leaves it.
    h.table(EventKind::TeamReviewRequested, EventColumn::List, false);
    assert!(h.wire_row("E_1").is_none());
    assert_eq!(h.badge(), 0);
    let filtered = h.card_ids(ListArgs {
        filter: PrFilter::ReviewRequested,
        ..ListArgs::default()
    });
    assert!(filtered.is_empty(), "{filtered:?}");
    h.table(EventKind::TeamReviewRequested, EventColumn::List, true);
    assert_eq!(h.badge(), 1);
}

#[test]
fn a_direct_review_request_counts_whatever_its_list() {
    let mut h = H::new();
    let ev = h.ev("E_1", "PR_1", IngestKind::ReviewRequested);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_1")
        }],
        vec![ev],
        vec![],
    );
    assert_eq!(h.badge(), 1);
    h.table(EventKind::ReviewRequested, EventColumn::List, false);
    assert_eq!(h.badge(), 1, "DESIGN.md, Awaiting review");
    assert!(h.wire_row("E_1").is_none());
}

#[test]
fn an_approved_row_per_review_and_its_comment() {
    let mut h = H::new();
    let mut approved = h.ev("R_1", "PR_1", IngestKind::Approved);
    approved.text = None;
    let comment = h.ev("R_1", "PR_1", IngestKind::Comment);
    let second = h.ev("R_2", "PR_1", IngestKind::Approved);
    h.push(vec![pr("PR_1")], vec![approved, comment, second], vec![]);
    assert!(h.has_row("R_1:approved"));
    assert!(h.has_row("R_2:approved"));
    assert!(h.has_row("R_1"), "the body makes a Comment row");
    assert_eq!(h.row("R_1:approved").actor.as_deref(), Some("alice"));
}

#[test]
fn notifications_are_titled_by_account_and_summed_up_per_owner() {
    let mut h = H::new();
    let ev = h.ev("E_1", "PR_1", IngestKind::Mentioned);
    h.push(vec![pr("PR_1")], vec![ev], vec![]);
    let one = h.delivered();
    assert_eq!(one.len(), 1);
    assert_eq!(one[0].title, "me · Mentioned");
    assert_eq!(one[0].subtitle.as_deref(), Some("org/app #1 · Title PR_1"));
    assert_eq!(one[0].account, ACCOUNT);
    assert_eq!(one[0].owner, h.owner_id(ORG));
    let a = h.ev("E_2", "PR_1", IngestKind::Comment);
    let b = h.ev("E_3", "PR_2", IngestKind::Comment);
    h.push(vec![pr("PR_2")], vec![a, b], vec![]);
    let summary = h.delivered();
    assert_eq!(summary.len(), 1);
    assert_eq!(summary[0].title, "me · 2 new events");
    assert_eq!(summary[0].subtitle.as_deref(), Some("org · in 2 PRs"));
    assert_eq!(summary[0].body, None);
    let c = h.ev("E_4", "PR_1", IngestKind::Merged);
    let d = h.ev("E_5", "PR_1", IngestKind::Closed);
    h.table(EventKind::MergedClosed, EventColumn::Notify, true);
    h.events(vec![c]);
    let merged = h.delivered();
    assert_eq!(merged[0].title, "me · Merged");
    h.events(vec![d]);
    assert_eq!(h.delivered()[0].title, "me · Closed");
}

#[test]
fn skip_drafts_records_without_notifying() {
    let mut h = H::new();
    let ev = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(
        vec![IngestPr {
            is_draft: true,
            ..pr("PR_1")
        }],
        vec![ev],
        vec![],
    );
    assert!(h.wire_row("E_1").is_some());
    assert!(h.delivered().is_empty());
}

#[test]
fn the_filters_of_the_prs_tab() {
    let mut h = H::new();
    h.prs(vec![
        pr("PR_1"),
        IngestPr {
            assignees: vec!["ME".into()],
            ..other("PR_2")
        },
        IngestPr {
            requested_me: true,
            ..other("PR_3")
        },
    ]);
    let of = |f: PrFilter| {
        let mut ids = h.card_ids(ListArgs {
            filter: f,
            ..ListArgs::default()
        });
        ids.sort();
        ids
    };
    assert_eq!(of(PrFilter::All), ["PR_1", "PR_2", "PR_3"]);
    assert_eq!(of(PrFilter::Authored), ["PR_1"]);
    assert_eq!(of(PrFilter::Assigned), ["PR_2"]);
    assert_eq!(of(PrFilter::ReviewRequested), ["PR_3"]);
    let card = h.card(&key("PR_2")).unwrap();
    assert!(card.assigned_to_me && !card.authored_by_me);
}

#[test]
fn activity_filters_by_owner() {
    let mut h = H::new();
    let ev = h.ev("E_1", "PR_1", IngestKind::Mentioned);
    let public = IngestPr {
        owner: "elsewhere".into(),
        ..other("PR_2")
    };
    let ev2 = h.ev("E_2", "PR_2", IngestKind::Mentioned);
    h.push(vec![pr("PR_1"), public], vec![ev, ev2], vec![]);
    let all = h.activity(ActivityArgs::default());
    assert_eq!(ids(&all), ["E_1", "E_2"]);
    let only = h.activity(ActivityArgs {
        owners: vec!["public".into()],
        ..ActivityArgs::default()
    });
    assert_eq!(ids(&only), ["E_2"]);
}

#[test]
fn removing_an_owner_removes_its_prs_and_adding_it_again_starts_empty() {
    let mut h = H::new();
    let ev = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![ev], vec![]);
    h.read(&["E_1"]);
    let owner = h.owner_id(ORG);
    h.engine.owner_remove(&owner);
    assert!(!h.has_row("E_1"));
    assert!(h.engine.pr_record("1001:PR_1").is_none());
    let id = h
        .engine
        .owner_add(
            ACCOUNT,
            ORG,
            shiibar_ghd::model::OwnerKind::Org,
            Some(100),
            &h.now,
        )
        .unwrap();
    assert_ne!(id, owner, "a new owner id");
    assert!(h.cards().is_empty());
}

#[test]
fn account_colors_are_assigned_in_order() {
    let mut h = H::new();
    assert!(h.account().color.is(AccountColor::None));
    h.add_other();
    assert!(h.account_of(OTHER).color.is(AccountColor::Red));
    h.engine.account_create("1003", "third").unwrap();
    assert!(h.account_of("1003").color.is(AccountColor::Orange));
    assert!(invalid(h.engine.account_create("1003", "third")));
}

#[test]
fn a_color_freed_by_a_change_is_taken_next_and_the_first_account_again_has_none() {
    let mut h = H::new();
    h.add_other();
    // `you` moves from Red to Blue: Red is unused again.
    h.engine.account_color(YOU, AccountColor::Blue).unwrap();
    h.engine.account_create("1003", "third").unwrap();
    assert!(h.account_of("1003").color.is(AccountColor::Red));
    for id in [ACCOUNT, OTHER, "1003"] {
        h.engine.account_remove(id);
    }
    h.engine.account_create("1004", "fourth").unwrap();
    assert!(h.account_of("1004").color.is(AccountColor::None));
}

#[test]
fn user_exclusions_cover_approved_rows_but_not_state_changes_or_reactions() {
    let mut h = H::new();
    h.exclude(ExclusionKind::User, "alice", ExclusionState::Hidden);
    let approved = h.ev("R_1", "PR_1", IngestKind::Approved);
    h.push(vec![pr("PR_1")], vec![approved], vec![]);
    assert!(h.has_row("R_1:approved"));
    assert!(
        h.wire_row("R_1:approved").is_none(),
        "the approver is hidden"
    );
    // A state change row has no actor; a reaction row names nobody.
    h.prs(vec![IngestPr {
        checks: Checks::Failed,
        ..pr("PR_1")
    }]);
    let reaction = h.reaction("C_1", "PR_1", &[("THUMBS_UP", 1)]);
    h.push(vec![], vec![], vec![reaction]);
    let kinds: Vec<String> = h
        .card(&key("PR_1"))
        .unwrap()
        .rows
        .iter()
        .map(|r| r.kind.as_text())
        .collect();
    assert!(kinds.contains(&"checks_failed".to_string()), "{kinds:?}");
    assert!(kinds.contains(&"reaction".to_string()), "{kinds:?}");
}

#[test]
fn rows_from_before_hidden_keep_their_state_and_a_request_recorded_while_hidden_comes_back_read() {
    // DESIGN.md, "Exclusions" (3-2 (a) and (b)).
    let mut h = H::new();
    let before = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![before], vec![]);
    h.exclude(ExclusionKind::User, "alice", ExclusionState::Hidden);
    let request = h.ev("E_2", "PR_2", IngestKind::ReviewRequested);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_2")
        }],
        vec![request],
        vec![],
    );
    assert!(h.wire_row("E_1").is_none() && h.wire_row("E_2").is_none());
    h.include(ExclusionKind::User, "alice");
    let old = h.wire_row("E_1").unwrap();
    assert!(old.unread, "(a) as it was before Hidden");
    let back = h.wire_row("E_2").unwrap();
    assert!(!back.unread, "(b) recorded while hidden: read");
    assert!(
        h.card(&key("PR_2")).unwrap().awaiting_review,
        "(b) the request goes on: it awaits review"
    );
}

#[test]
fn an_owner_login_has_at_most_39_characters() {
    let mut h = H::new();
    let ok = "a".repeat(39);
    let long = "a".repeat(40);
    assert!(
        h.engine
            .owner_add(
                ACCOUNT,
                &ok,
                shiibar_ghd::model::OwnerKind::Org,
                Some(1),
                &h.now
            )
            .is_ok()
    );
    assert!(invalid(h.engine.owner_add(
        ACCOUNT,
        &long,
        shiibar_ghd::model::OwnerKind::Org,
        Some(2),
        &h.now
    )));
    assert!(shiibar_ghd::engine::valid_login(&ok));
    assert!(!shiibar_ghd::engine::valid_login(&long));
}
