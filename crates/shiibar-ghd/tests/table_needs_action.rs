//! Rule table: Needs action and the badge. DESIGN.md, sections "Needs action
//! definition" and "Rows shown in Activity".

mod support;

use shiibar_gh_proto::*;
use support::*;

struct Case {
    name: &'static str,
    pr: fn() -> IngestPr,
    row: Option<EventKind>,
    done: bool,
    snoozed: bool,
    unreadable: bool,
    want: bool,
}

const fn case(
    name: &'static str,
    pr: fn() -> IngestPr,
    row: Option<EventKind>,
    want: bool,
) -> Case {
    Case {
        name,
        pr,
        row,
        done: false,
        snoozed: false,
        unreadable: false,
        want,
    }
}

#[test]
fn needs_action_table() {
    let cases = [
        case("own PR, nothing red", || pr("PR_1"), None, false),
        case(
            "own PR with no reviewer requested yet",
            || IngestPr {
                review: Review::ReviewRequired,
                ..pr("PR_1")
            },
            None,
            false,
        ),
        case(
            "own PR, review red",
            || IngestPr {
                review: Review::ChangesRequested,
                ..pr("PR_1")
            },
            None,
            true,
        ),
        case(
            "own PR, checks red",
            || IngestPr {
                checks: Checks::Failed,
                ..pr("PR_1")
            },
            None,
            true,
        ),
        case(
            "own PR, base red",
            || IngestPr {
                base_status: BaseStatus::Conflicts,
                ..pr("PR_1")
            },
            None,
            true,
        ),
        case(
            "own PR, behind is not red",
            || IngestPr {
                base_status: BaseStatus::Behind,
                ..pr("PR_1")
            },
            None,
            false,
        ),
        case(
            "own draft, checks red",
            || IngestPr {
                is_draft: true,
                checks: Checks::Failed,
                ..pr("PR_1")
            },
            None,
            true,
        ),
        case(
            "own merged PR, checks red",
            || IngestPr {
                state: PrState::Merged,
                checks: Checks::Failed,
                ..pr("PR_1")
            },
            Some(EventKind::Merged),
            false,
        ),
        case(
            "someone else's PR, checks red",
            || IngestPr {
                checks: Checks::Failed,
                ..other("PR_1")
            },
            None,
            false,
        ),
        case("comment", || other("PR_1"), Some(EventKind::Comment), true),
        case(
            "mention",
            || other("PR_1"),
            Some(EventKind::Mentioned),
            true,
        ),
        case("reply", || other("PR_1"), Some(EventKind::Reply), true),
        case(
            "review request still open",
            || IngestPr {
                requested_me: true,
                ..other("PR_1")
            },
            Some(EventKind::ReviewRequested),
            true,
        ),
        case(
            "review request withdrawn",
            || other("PR_1"),
            Some(EventKind::ReviewRequested),
            false,
        ),
        case(
            "merged PR, comment not done",
            || IngestPr {
                state: PrState::Merged,
                ..other("PR_1")
            },
            Some(EventKind::Comment),
            true,
        ),
        case(
            "event row only",
            || other("PR_1"),
            Some(EventKind::AddedToMergeQueue),
            false,
        ),
        Case {
            done: true,
            ..case(
                "comment done",
                || other("PR_1"),
                Some(EventKind::Comment),
                false,
            )
        },
        Case {
            done: true,
            ..case(
                "comment done, red own PR",
                || IngestPr {
                    checks: Checks::Failed,
                    ..pr("PR_1")
                },
                Some(EventKind::Comment),
                true,
            )
        },
        Case {
            snoozed: true,
            ..case(
                "snoozed comment",
                || other("PR_1"),
                Some(EventKind::Comment),
                false,
            )
        },
        Case {
            snoozed: true,
            ..case(
                "snoozed red own PR",
                || IngestPr {
                    checks: Checks::Failed,
                    ..pr("PR_1")
                },
                None,
                false,
            )
        },
        Case {
            unreadable: true,
            ..case(
                "unreadable comment",
                || other("PR_1"),
                Some(EventKind::Comment),
                false,
            )
        },
    ];
    for c in cases {
        let mut h = H::new();
        let events = c.row.map(|k| h.ev("E_1", "PR_1", k)).into_iter().collect();
        h.push(vec![(c.pr)()], events, vec![]);
        if c.done {
            h.engine.done("E_1").unwrap();
        }
        if c.snoozed {
            h.snooze(&key("PR_1"));
        }
        if c.unreadable {
            h.missing("PR_1");
        }
        assert_eq!(h.badge(), u32::from(c.want), "{}: badge", c.name);
        let filter = Filter {
            needs_action: true,
            ..Filter::default()
        };
        assert_eq!(
            h.cards(&filter).len(),
            usize::from(c.want),
            "{}: chip",
            c.name
        );
    }
}

#[test]
fn the_badge_counts_prs_not_rows() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    let b = h.ev("E_2", "PR_1", EventKind::Mentioned);
    let c = h.ev("E_3", "PR_2", EventKind::Reply);
    h.push(vec![other("PR_1"), other("PR_2")], vec![a, b, c], vec![]);
    assert_eq!(h.badge(), 2);
}

#[test]
fn the_filter_is_per_pr_and_keeps_every_row_of_the_pr() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    let b = h.ev("E_2", "PR_1", EventKind::Closed);
    let c = h.ev("E_3", "PR_2", EventKind::Closed);
    h.push(vec![other("PR_1"), other("PR_2")], vec![a, b, c], vec![]);
    let filter = Filter {
        needs_action: true,
        ..Filter::default()
    };
    assert_eq!(h.card_ids(&filter), ["PR_1"]);
    assert_eq!(h.cards(&filter)[0].rows.len(), 2);
    let rows = h.engine.activity(&filter, &h.now).unwrap();
    assert_eq!(rows.len(), 2);
}

#[test]
fn needs_action_never_shows_snoozed_prs_even_with_show_snoozed() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![other("PR_1")], vec![a], vec![]);
    h.snooze(&key("PR_1"));
    let filter = Filter {
        needs_action: true,
        snoozed: true,
        ..Filter::default()
    };
    assert!(h.cards(&filter).is_empty());
}
