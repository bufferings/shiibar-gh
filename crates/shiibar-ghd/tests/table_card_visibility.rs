//! Rule table: when a card shows. DESIGN.md, sections "When cards appear and
//! disappear", "Card state" and the card header.

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
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
    row: Option<EventKind>,
    unread: bool,
    done: bool,
    snoozed: bool,
    show_snoozed: bool,
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
    done: false,
    snoozed: false,
    show_snoozed: false,
    unreadable: false,
    want: true,
};

fn run(c: Case) {
    let mut h = H::new();
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
        h.seen(&["E_1"]);
        h.close();
    }
    if c.done {
        h.engine.done("E_1").unwrap();
    }
    h.set_time(T0 + 100);
    h.prs(vec![IngestPr {
        state: c.state,
        is_draft: c.draft,
        updated_at: T0 + 150 - c.age * DAY,
        ..base
    }]);
    if c.unreadable {
        h.missing("PR_1");
    }
    h.set_time(T0 + 100 + 50);
    let filter = Filter {
        snoozed: c.show_snoozed,
        ..Filter::default()
    };
    let shown = h.card_ids(&filter).contains(&"PR_1".to_string());
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
            row: Some(EventKind::Merged),
            unread: true,
            ..BASE
        },
        Case {
            name: "someone else's draft with an open needs action row",
            draft: true,
            row: Some(EventKind::Comment),
            ..BASE
        },
        Case {
            name: "someone else's draft, row done",
            draft: true,
            row: Some(EventKind::Comment),
            done: true,
            want: false,
            ..BASE
        },
        Case {
            name: "merged with unread row",
            mine: true,
            state: PrState::Merged,
            row: Some(EventKind::Merged),
            unread: true,
            ..BASE
        },
        Case {
            name: "merged, read: confirmed and gone",
            mine: true,
            state: PrState::Merged,
            row: Some(EventKind::Merged),
            want: false,
            ..BASE
        },
        Case {
            name: "merged with an open comment stays until done",
            state: PrState::Merged,
            row: Some(EventKind::Comment),
            ..BASE
        },
        Case {
            name: "merged, comment done",
            state: PrState::Merged,
            row: Some(EventKind::Comment),
            done: true,
            want: false,
            ..BASE
        },
        Case {
            name: "stale PR with unread row",
            age: 30,
            row: Some(EventKind::Merged),
            unread: true,
            ..BASE
        },
        Case {
            name: "stale PR with an open needs action row",
            age: 30,
            row: Some(EventKind::Reply),
            ..BASE
        },
        Case {
            name: "snoozed, Show snoozed off",
            mine: true,
            snoozed: true,
            want: false,
            ..BASE
        },
        Case {
            name: "snoozed, Show snoozed on",
            mine: true,
            snoozed: true,
            show_snoozed: true,
            ..BASE
        },
        Case {
            name: "snoozed with unread, Show snoozed off",
            row: Some(EventKind::Comment),
            unread: true,
            snoozed: true,
            want: false,
            ..BASE
        },
        Case {
            name: "snoozed that would otherwise be gone, Show snoozed on",
            state: PrState::Closed,
            snoozed: true,
            show_snoozed: true,
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
            row: Some(EventKind::Comment),
            unread: true,
            unreadable: true,
            want: false,
            ..BASE
        },
        Case {
            name: "unreadable and snoozed, Show snoozed on",
            mine: true,
            snoozed: true,
            show_snoozed: true,
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
        let e = h.ev("E_1", "PR_1", EventKind::Merged);
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
fn newest_card_first_with_ties_by_id() {
    let mut h = H::new();
    h.prs(vec![pr("PR_2"), pr("PR_1")]);
    h.prs(vec![pr("PR_3")]);
    assert_eq!(h.card_ids(&Filter::default()), ["PR_3", "PR_1", "PR_2"]);
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
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![ready.clone()], vec![e], vec![]);
    assert_eq!(
        h.card_ids(&Filter::default()),
        ["PR_2", "PR_1"],
        "events do not move cards"
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
    let e = h.ev("E_1", "PR_1", EventKind::Merged);
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
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.events(vec![e]);
    assert!(h.visible("PR_1"));
}

#[test]
fn an_unreadable_pr_comes_back_with_its_state() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    let added = h.card(&key("PR_1")).unwrap().added_at;
    h.engine.done("E_1").unwrap();
    h.missing("PR_1");
    assert!(!h.visible("PR_1"));
    assert!(not_found(h.engine.status(&key("PR_1"), &h.now)));
    h.prs(vec![pr("PR_1")]);
    assert!(h.visible("PR_1"));
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.added_at, added);
    assert!(card.rows[0].done);
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
    let a = h.ev_at("E_2", "PR_1", EventKind::Comment, at);
    let b = h.ev_at("E_1", "PR_2", EventKind::Comment, at);
    let c = h.ev_at("E_3", "PR_1", EventKind::Comment, at + 5);
    h.push(vec![pr("PR_1"), pr("PR_2")], vec![a, b, c], vec![]);
    let rows = h.engine.activity(&Filter::default(), &h.now).unwrap();
    assert_eq!(ids(&rows), ["E_3", "E_1", "E_2"]);
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(ids(&card.rows), ["E_3", "E_2"]);

    h.snooze(&key("PR_1"));
    let rows = h.engine.activity(&Filter::default(), &h.now).unwrap();
    assert_eq!(ids(&rows), ["E_1"]);
    let rows = h.engine.activity(&show_snoozed(), &h.now).unwrap();
    assert_eq!(ids(&rows), ["E_3", "E_1", "E_2"]);
}

#[test]
fn mine_and_others_filters() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), other("PR_2")]);
    let mine = Filter {
        mine: true,
        ..Filter::default()
    };
    let others = Filter {
        others: true,
        ..Filter::default()
    };
    assert_eq!(h.card_ids(&mine), ["PR_1"]);
    assert_eq!(h.card_ids(&others), ["PR_2"]);
    let both = Filter {
        mine: true,
        others: true,
        ..Filter::default()
    };
    assert!(invalid(h.engine.list(&both, &h.now)));
}
