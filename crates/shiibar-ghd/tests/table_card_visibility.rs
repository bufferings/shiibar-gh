//! Rule table: when a card shows. DESIGN.md, sections "When cards appear and
//! disappear", "Card state" and the card header.

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use shiibar_ghd::engine::{ActivityArgs, ListArgs};
use shiibar_ghd::model::OwnerKind;
use support::*;

#[derive(Clone, Copy)]
struct Case {
    name: &'static str,
    mine: bool,
    state: PrState,
    draft: bool,
    /// Days since the PR was last updated.
    age: i64,
    /// Make a row of this kind, read unless `unread`.
    row: Option<IngestKind>,
    unread: bool,
    /// A review is requested from the account.
    requested: bool,
    snoozed: bool,
    /// Look in the Snoozed section instead of the owner sections.
    in_snoozed: bool,
    unreadable: bool,
    want: bool,
}

const BASE: Case = Case {
    name: "",
    mine: false,
    state: PrState::Open,
    draft: false,
    age: 0,
    row: None,
    unread: false,
    requested: false,
    snoozed: false,
    in_snoozed: false,
    unreadable: false,
    want: true,
};

fn run(c: Case) {
    let mut h = H::new();
    if c.name.contains("Hidden repository") {
        h.exclude(ExclusionKind::Repo, "org/app", ExclusionState::Hidden);
    }
    // Start visible so the PR can be snoozed, then apply the final shape.
    let base = if c.mine { pr("PR_1") } else { other("PR_1") };
    h.prs(vec![base.clone()]);
    if let Some(kind) = c.row {
        let e = h.ev("E_1", "PR_1", kind);
        h.events(vec![e]);
    }
    if c.snoozed {
        h.snooze(&key("PR_1"));
    }
    if c.row.is_some() && !c.unread {
        h.read(&["E_1"]);
    }
    h.set_time(T0 + 100);
    h.prs(vec![IngestPr {
        state: c.state,
        is_draft: c.draft,
        requested_me: c.requested,
        updated_at: T0 + 150 - c.age * DAY,
        ..base
    }]);
    if c.unreadable {
        h.missing("PR_1");
    }
    h.set_time(T0 + 100 + 50);
    let args = ListArgs {
        snoozed: c.in_snoozed,
        ..ListArgs::default()
    };
    let shown = h.card_ids(args).contains(&"PR_1".to_string());
    assert_eq!(shown, c.want, "{}", c.name);
}

#[test]
fn card_table() {
    let cases = [
        Case {
            name: "own open PR",
            mine: true,
            ..BASE
        },
        Case {
            name: "own open PR past the drop age",
            mine: true,
            age: 400,
            ..BASE
        },
        Case {
            name: "own draft",
            mine: true,
            draft: true,
            ..BASE
        },
        Case {
            name: "own merged, nothing left",
            mine: true,
            state: PrState::Merged,
            want: false,
            ..BASE
        },
        Case {
            name: "own closed, nothing left",
            mine: true,
            state: PrState::Closed,
            want: false,
            ..BASE
        },
        Case {
            name: "someone else's open PR",
            ..BASE
        },
        Case {
            name: "someone else's PR at 14 days",
            age: 14,
            want: true,
            ..BASE
        },
        Case {
            name: "someone else's PR past 14 days",
            age: 15,
            want: false,
            ..BASE
        },
        Case {
            name: "someone else's draft",
            draft: true,
            want: false,
            ..BASE
        },
        Case {
            name: "someone else's closed PR",
            state: PrState::Closed,
            want: false,
            ..BASE
        },
        Case {
            name: "someone else's draft with an unread row",
            draft: true,
            row: Some(IngestKind::Merged),
            unread: true,
            ..BASE
        },
        Case {
            name: "someone else's draft, row read",
            draft: true,
            row: Some(IngestKind::Comment),
            want: false,
            ..BASE
        },
        Case {
            name: "someone else's draft awaiting my review",
            draft: true,
            requested: true,
            ..BASE
        },
        Case {
            name: "merged with unread row",
            mine: true,
            state: PrState::Merged,
            row: Some(IngestKind::Merged),
            unread: true,
            ..BASE
        },
        Case {
            name: "merged, read: confirmed and gone",
            mine: true,
            state: PrState::Merged,
            row: Some(IngestKind::Merged),
            want: false,
            ..BASE
        },
        Case {
            name: "merged, comment read",
            state: PrState::Merged,
            row: Some(IngestKind::Comment),
            want: false,
            ..BASE
        },
        Case {
            name: "merged: a closed PR never awaits review",
            state: PrState::Merged,
            requested: true,
            want: false,
            ..BASE
        },
        Case {
            name: "stale PR with unread row",
            age: 30,
            row: Some(IngestKind::Merged),
            unread: true,
            ..BASE
        },
        Case {
            name: "stale PR, row read",
            age: 30,
            row: Some(IngestKind::Reply),
            want: false,
            ..BASE
        },
        Case {
            name: "stale PR awaiting my review",
            age: 30,
            requested: true,
            ..BASE
        },
        Case {
            name: "snoozed, not in the owner section",
            mine: true,
            snoozed: true,
            want: false,
            ..BASE
        },
        Case {
            name: "snoozed, in the Snoozed section",
            mine: true,
            snoozed: true,
            in_snoozed: true,
            ..BASE
        },
        Case {
            name: "snoozed with unread, not in the owner section",
            row: Some(IngestKind::Comment),
            unread: true,
            snoozed: true,
            want: false,
            ..BASE
        },
        Case {
            name: "snoozed that would otherwise be gone, in the Snoozed section",
            state: PrState::Closed,
            snoozed: true,
            in_snoozed: true,
            ..BASE
        },
        Case {
            name: "unreadable",
            mine: true,
            unreadable: true,
            want: false,
            ..BASE
        },
        Case {
            name: "unreadable with unread and open rows",
            mine: true,
            row: Some(IngestKind::Comment),
            unread: true,
            unreadable: true,
            want: false,
            ..BASE
        },
        Case {
            name: "not snoozed, not in the Snoozed section",
            mine: true,
            in_snoozed: true,
            want: false,
            ..BASE
        },
        Case {
            name: "someone else's open PR in a Hidden repository",
            row: Some(IngestKind::Comment),
            unread: true,
            want: false,
            ..BASE
        },
        Case {
            name: "unreadable and snoozed, in the Snoozed section",
            mine: true,
            snoozed: true,
            in_snoozed: true,
            unreadable: true,
            want: false,
            ..BASE
        },
    ];
    for c in cases {
        run(c);
    }
}

#[test]
fn state_label_table() {
    let cases = [
        (PrState::Merged, true, true, StateLabel::Merged),
        (PrState::Closed, true, true, StateLabel::Closed),
        (PrState::Open, true, true, StateLabel::Draft),
        (PrState::Open, false, true, StateLabel::Mergeable),
        (PrState::Open, false, false, StateLabel::Open),
    ];
    for (state, is_draft, mergeable, want) in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", IngestKind::Merged);
        h.push(
            vec![IngestPr {
                state,
                is_draft,
                mergeable,
                ..pr("PR_1")
            }],
            vec![e],
            vec![],
        );
        let card = h.card(&key("PR_1")).unwrap();
        assert_eq!(card.state_label, Lenient::Known(want), "{state:?}");
    }
}

#[test]
fn list_puts_open_prs_first_then_the_newest_update_with_ties_by_id() {
    // DESIGN.md, "CLI": `Recently updated` within an owner, open PRs first.
    let mut h = H::new();
    let at = |id: &str, updated_at| IngestPr {
        updated_at,
        ..pr(id)
    };
    h.prs(vec![at("PR_2", T0 + 5), at("PR_1", T0 + 5)]);
    h.prs(vec![at("PR_3", T0 + 1), at("PR_4", T0 + 9)]);
    let merged = IngestPr {
        state: PrState::Merged,
        updated_at: T0 + 20,
        ..pr("PR_5")
    };
    let e = h.ev("E_5", "PR_5", IngestKind::Merged);
    h.push(vec![merged], vec![e], vec![]);
    assert_eq!(
        h.card_ids(ListArgs::default()),
        ["PR_4", "PR_1", "PR_2", "PR_3", "PR_5"]
    );
}

#[test]
fn added_at_is_when_the_card_first_qualified_and_never_moves() {
    let mut h = H::new();
    let draft = IngestPr {
        is_draft: true,
        ..other("PR_1")
    };
    h.prs(vec![draft]);
    assert!(!h.visible("PR_1"));
    let ready_at = h.at();
    let ready = other("PR_1");
    h.prs(vec![ready.clone()]);
    assert_eq!(h.card(&key("PR_1")).unwrap().added_at, Some(ready_at));

    h.prs(vec![pr("PR_2")]);
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![ready.clone()], vec![e], vec![]);
    assert_eq!(
        h.card(&key("PR_1")).unwrap().added_at,
        Some(ready_at),
        "events do not move the added time"
    );

    h.snooze(&key("PR_1"));
    h.unsnooze(&key("PR_1"));
    assert_eq!(h.card(&key("PR_1")).unwrap().added_at, Some(ready_at));
}

#[test]
fn a_dropped_pr_returns_on_a_new_event_at_its_old_position() {
    let mut h = H::new();
    let stale = other("PR_1");
    h.prs(vec![stale.clone()]);
    let added = h.card(&key("PR_1")).unwrap().added_at;
    h.advance(15 * DAY);
    assert!(!h.visible("PR_1"));
    let e = h.ev("E_1", "PR_1", IngestKind::Merged);
    h.events(vec![e]);
    assert!(h.visible("PR_1"));
    assert_eq!(h.card(&key("PR_1")).unwrap().added_at, added);
}

#[test]
fn drop_after_days_is_read_from_the_setting() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.set("drop_after_days", json!(1));
    h.advance(DAY + 1);
    assert!(!h.visible("PR_1"));
    h.set("drop_after_days", json!(14));
    assert!(h.visible("PR_1"));
}

#[test]
fn ready_for_review_brings_a_draft_back_as_open() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        is_draft: true,
        ..other("PR_1")
    }]);
    assert!(!h.visible("PR_1"));
    h.prs(vec![other("PR_1")]);
    assert!(h.visible("PR_1"));
}

#[test]
fn a_closed_pr_with_a_new_event_shows_again() {
    let mut h = H::new();
    let closed = IngestPr {
        state: PrState::Closed,
        ..other("PR_1")
    };
    h.prs(vec![closed]);
    assert!(!h.visible("PR_1"));
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.events(vec![e]);
    assert!(h.visible("PR_1"));
}

#[test]
fn an_unreadable_pr_comes_back_with_its_state() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    let added = h.card(&key("PR_1")).unwrap().added_at;
    h.read(&["E_1"]);
    h.missing("PR_1");
    assert!(!h.visible("PR_1"));
    assert!(not_found(h.engine.status(ME, &key("PR_1"), &h.now)));
    h.prs(vec![pr("PR_1")]);
    assert!(h.visible("PR_1"));
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.added_at, added);
    assert!(!card.rows[0].unread);
}

#[test]
fn a_pr_absent_from_an_ingest_is_unchanged() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.prs(vec![pr("PR_2")]);
    assert!(h.visible("PR_1"));
}

#[test]
fn activity_shows_only_rows_of_shown_cards_newest_first_ties_by_id() {
    let mut h = H::new();
    let at = h.at();
    let a = h.ev_at("E_2", "PR_1", IngestKind::Comment, at);
    let b = h.ev_at("E_1", "PR_2", IngestKind::Comment, at);
    let c = h.ev_at("E_3", "PR_1", IngestKind::Comment, at + 5);
    h.push(vec![pr("PR_1"), pr("PR_2")], vec![a, b, c], vec![]);
    let rows = h.activity(ActivityArgs::default());
    assert_eq!(ids(&rows), ["E_3", "E_1", "E_2"]);
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(ids(&card.rows), ["E_3", "E_2"]);

    // DESIGN.md, "Rows shown in Activity": no rows of a snoozed PR.
    h.snooze(&key("PR_1"));
    let rows = h.activity(ActivityArgs::default());
    assert_eq!(ids(&rows), ["E_1"]);
}

#[test]
fn the_authored_by_me_filter() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), other("PR_2")]);
    let authored = ListArgs {
        filter: PrFilter::Authored,
        ..ListArgs::default()
    };
    assert_eq!(h.card_ids(authored), ["PR_1"]);
    assert_eq!(h.card_ids(ListArgs::default()).len(), 2);
}

#[test]
fn sections_follow_the_registration_order_with_public_last() {
    let mut h = H::new();
    h.engine
        .owner_add(ACCOUNT, "later", OwnerKind::Org, None, &h.now)
        .unwrap();
    let public = IngestPr {
        owner: "elsewhere".into(),
        ..other("PR_1")
    };
    let later = IngestPr {
        owner: "later".into(),
        ..other("PR_2")
    };
    h.prs(vec![public]);
    h.prs(vec![later]);
    h.prs(vec![other("PR_3")]);
    // org, later, then Public, whatever the order the cards came in.
    assert_eq!(h.card_ids(ListArgs::default()), ["PR_3", "PR_2", "PR_1"]);
    let names: Vec<String> = h.account().owners.into_iter().map(|o| o.name).collect();
    assert_eq!(names, ["org", "later", "Public"]);
}

// ------------------------------------------- cards held while the popover is open

/// A merged PR of someone else with one unread row: it goes once the row is
/// read.
fn merged_with_a_row(h: &mut H) {
    let e = h.ev("E_1", "PR_1", IngestKind::Merged);
    h.push(
        vec![IngestPr {
            state: PrState::Merged,
            ..other("PR_1")
        }],
        vec![e],
        vec![],
    );
}

#[test]
fn a_card_the_open_popover_listed_stays_until_it_closes() {
    // DESIGN.md, "When cards appear and disappear".
    let mut h = H::new();
    merged_with_a_row(&mut h);
    h.open();
    assert_eq!(h.app_list(), ["PR_1"]);
    h.read(&["E_1"]);
    assert_eq!(h.app_list(), ["PR_1"], "held while open");
    assert!(h.visible("PR_1"));
    assert_eq!(h.owner(ORG).pr_count, 1, "pr_count counts it too");
    h.tick();
    assert!(h.visible("PR_1"), "a periodic pass keeps it");
    h.close();
    assert!(!h.visible("PR_1"), "gone when the popover closes");
    assert_eq!(h.owner(ORG).pr_count, 0);
}

#[test]
fn only_a_list_while_open_holds_a_card() {
    let mut h = H::new();
    merged_with_a_row(&mut h);
    // Listed before the popover opened: nothing held.
    assert_eq!(h.app_list(), ["PR_1"]);
    h.open();
    h.read(&["E_1"]);
    assert!(!h.visible("PR_1"), "never listed while open");
}

#[test]
fn an_app_disconnect_and_a_restart_forget_the_held_cards() {
    let mut h = H::new();
    merged_with_a_row(&mut h);
    h.open();
    h.app_list();
    h.read(&["E_1"]);
    h.engine.app_disconnected();
    assert!(!h.visible("PR_1"), "the app went away");

    let mut h = H::new();
    merged_with_a_row(&mut h);
    h.open();
    h.app_list();
    h.read(&["E_1"]);
    let restored = shiibar_ghd::engine::Engine::restore(h.engine.data().clone());
    let cards = restored.list_view(&ListArgs::default(), &h.now).unwrap();
    assert!(cards.is_empty(), "a restart starts with nothing held");
}

#[test]
fn held_cards_are_per_account() {
    let mut h = H::new();
    h.add_other();
    merged_with_a_row(&mut h);
    h.engine.popover_opened(YOU).unwrap();
    h.engine
        .list(
            &ListArgs {
                account: Some(ME.into()),
                ..ListArgs::default()
            },
            &h.now,
        )
        .unwrap();
    h.read(&["E_1"]);
    assert!(!h.visible("PR_1"), "the open popover is another account's");
}

#[test]
fn a_held_card_can_be_snoozed_and_unsnoozed() {
    let mut h = H::new();
    merged_with_a_row(&mut h);
    let open = IngestPr {
        updated_at: T0 - 30 * DAY,
        ..other("PR_2")
    };
    let e = h.ev("E_2", "PR_2", IngestKind::Comment);
    h.push(vec![open], vec![e], vec![]);
    h.open();
    h.app_list();
    h.read(&["E_2"]);
    h.snooze(&key("PR_2"));
    assert!(h.snoozed("PR_2"));
    h.unsnooze(&key("PR_2"));
    assert!(h.visible("PR_2"), "still held");
    h.close();
    assert!(!h.visible("PR_2"));
}

#[test]
fn the_review_count_is_not_held() {
    // DESIGN.md, "Card states": `review_count` is the PR state now.
    let mut h = H::new();
    let asked = IngestPr {
        requested_me: true,
        updated_at: T0 - 30 * DAY,
        ..other("PR_1")
    };
    h.prs(vec![asked.clone()]);
    h.open();
    assert_eq!(h.app_list(), ["PR_1"]);
    assert_eq!(h.badge(), 1);
    h.prs(vec![IngestPr {
        requested_me: false,
        ..asked
    }]);
    assert_eq!(h.badge(), 0, "withdrawn: no longer counted");
    assert!(h.visible("PR_1"), "but the card stays while open");
    assert!(!h.card(&key("PR_1")).unwrap().awaiting_review);
    h.close();
    assert!(!h.visible("PR_1"));
}

#[test]
fn an_unreadable_or_hidden_held_card_goes_at_once() {
    // DESIGN.md, "Card states": those never show.
    let mut h = H::new();
    merged_with_a_row(&mut h);
    h.open();
    h.app_list();
    h.missing("PR_1");
    assert!(!h.visible("PR_1"));
    let mut h = H::new();
    merged_with_a_row(&mut h);
    h.open();
    h.app_list();
    h.exclude(ExclusionKind::Repo, "org/app", ExclusionState::Hidden);
    assert!(!h.visible("PR_1"));
}

// ---------------------------------------------------------------- search

/// DESIGN.md, "What the filters mean": the examples the Swift tests share.
#[test]
fn search_follows_the_examples_of_the_design() {
    let mut h = H::new();
    let example = IngestPr {
        owner: "example-org".into(),
        repo: "api".into(),
        number: 407,
        title: "Retry the upload".into(),
        author: "alice".into(),
        base: "main".into(),
        head: "fix/retry".into(),
        ..other("PR_407")
    };
    let mut row = h.ev("E_1", "PR_407", IngestKind::Comment);
    row.actor = Some("bob".into());
    row.text = Some("Looks good to me".into());
    h.push(vec![example, other("PR_2")], vec![row], vec![]);
    let found = |h: &H, text: &str| {
        let mut ids = h.card_ids(ListArgs {
            search: Some(text.into()),
            ..ListArgs::default()
        });
        ids.sort();
        ids
    };
    // (text, matches example-org/api#407)
    let cases = [
        ("api 407", true),
        ("#407", true),
        ("api #407", true),
        ("API", true),
        ("example-org/api#407", true),
        ("retry upload", true),
        ("ALICE", true),
        ("fix/retry", true),
        ("good bob", true),
        ("api #408", false),
        ("nobody", false),
    ];
    for (text, matches) in cases {
        assert_eq!(
            found(&h, text).contains(&"PR_407".to_string()),
            matches,
            "{text}"
        );
    }
    assert_eq!(found(&h, "  "), ["PR_2", "PR_407"], "blank is no search");
    assert_eq!(found(&h, ""), ["PR_2", "PR_407"]);
    // Activity hides rows: the PR's fields or the row's own text and actor.
    let rows = |text: &str| {
        ids(&h.activity(ActivityArgs {
            search: Some(text.into()),
            ..ActivityArgs::default()
        }))
    };
    assert_eq!(rows("api #407"), ["E_1"]);
    assert_eq!(rows("bob"), ["E_1"]);
    assert!(rows("bob PR_2").is_empty());
}
