//! Rule table: Todo PRs and the menu bar number. DESIGN.md, sections "Todo
//! definition", "Row kinds and states" and "Rows shown in Activity".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::engine::{ActivityArgs, ListArgs};
use support::*;

struct Case {
    name: &'static str,
    pr: fn() -> IngestPr,
    row: Option<IngestKind>,
    done: bool,
    snoozed: bool,
    unreadable: bool,
    want: bool,
}

const fn case(
    name: &'static str,
    pr: fn() -> IngestPr,
    row: Option<IngestKind>,
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
fn todo_table() {
    let cases = [
        // DESIGN.md, "Todo definition": a red status icon alone is no Todo.
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
            false,
        ),
        case(
            "own PR, checks red",
            || IngestPr {
                checks: Checks::Failed,
                ..pr("PR_1")
            },
            None,
            false,
        ),
        case(
            "own PR, base red",
            || IngestPr {
                base_status: BaseStatus::Conflicts,
                ..pr("PR_1")
            },
            None,
            false,
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
            false,
        ),
        case(
            "own merged PR, checks red",
            || IngestPr {
                state: PrState::Merged,
                checks: Checks::Failed,
                ..pr("PR_1")
            },
            Some(IngestKind::Merged),
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
        case("comment", || other("PR_1"), Some(IngestKind::Comment), true),
        case(
            "mention",
            || other("PR_1"),
            Some(IngestKind::Mentioned),
            true,
        ),
        case("reply", || other("PR_1"), Some(IngestKind::Reply), true),
        case(
            "review request still open",
            || IngestPr {
                requested_me: true,
                ..other("PR_1")
            },
            Some(IngestKind::ReviewRequested),
            true,
        ),
        case(
            "review request withdrawn",
            || other("PR_1"),
            Some(IngestKind::ReviewRequested),
            false,
        ),
        case(
            "merged PR, comment not done",
            || IngestPr {
                state: PrState::Merged,
                ..other("PR_1")
            },
            Some(IngestKind::Comment),
            true,
        ),
        case(
            "approved is not Todo by default",
            || pr("PR_1"),
            Some(IngestKind::Approved),
            false,
        ),
        case(
            "team mention",
            || other("PR_1"),
            Some(IngestKind::TeamMentioned),
            true,
        ),
        case(
            "reply where mentioned",
            || other("PR_1"),
            Some(IngestKind::ReplyMentioned),
            true,
        ),
        case(
            "team review request still open",
            || IngestPr {
                requested_team: true,
                ..other("PR_1")
            },
            Some(IngestKind::TeamReviewRequested),
            true,
        ),
        case(
            "team review request withdrawn",
            || other("PR_1"),
            Some(IngestKind::TeamReviewRequested),
            false,
        ),
        case(
            "event row only",
            || other("PR_1"),
            Some(IngestKind::MergeQueueAdded),
            false,
        ),
        Case {
            done: true,
            ..case(
                "comment done",
                || other("PR_1"),
                Some(IngestKind::Comment),
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
                Some(IngestKind::Comment),
                false,
            )
        },
        Case {
            snoozed: true,
            ..case(
                "snoozed comment",
                || other("PR_1"),
                Some(IngestKind::Comment),
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
                Some(IngestKind::Comment),
                false,
            )
        },
    ];
    for c in cases {
        let mut h = H::new();
        let events = c.row.map(|k| h.ev("E_1", "PR_1", k)).into_iter().collect();
        h.push(vec![(c.pr)()], events, vec![]);
        if c.done {
            h.done("E_1");
        }
        if c.snoozed {
            h.snooze(&key("PR_1"));
        }
        if c.unreadable {
            h.missing("PR_1");
        }
        assert_eq!(h.badge(), u32::from(c.want), "{}: badge", c.name);
        assert_eq!(
            h.todo_ids().len(),
            usize::from(c.want),
            "{}: Todo filter",
            c.name
        );
        assert_eq!(
            h.owner(ORG).todo_count,
            u32::from(c.want),
            "{}: owner",
            c.name
        );
    }
}

#[test]
fn the_badge_counts_prs_not_rows() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let b = h.ev("E_2", "PR_1", IngestKind::Mentioned);
    let c = h.ev("E_3", "PR_2", IngestKind::Reply);
    h.push(vec![other("PR_1"), other("PR_2")], vec![a, b, c], vec![]);
    assert_eq!(h.badge(), 2);
}

#[test]
fn the_filter_is_per_pr_and_keeps_every_row_of_the_pr() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let b = h.ev("E_2", "PR_1", IngestKind::Closed);
    let c = h.ev("E_3", "PR_2", IngestKind::Closed);
    h.push(vec![other("PR_1"), other("PR_2")], vec![a, b, c], vec![]);
    let todo = ListArgs {
        todo: true,
        ..ListArgs::default()
    };
    assert_eq!(h.card_ids(todo.clone()), ["PR_1"]);
    assert_eq!(h.list(todo)[0].rows.len(), 2);
    let rows = h.activity(ActivityArgs {
        todo: true,
        ..ActivityArgs::default()
    });
    assert_eq!(rows.len(), 2);
}

#[test]
fn a_snoozed_pr_is_never_a_todo_pr() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![a], vec![]);
    h.snooze(&key("PR_1"));
    assert!(h.todo_ids().is_empty());
    assert_eq!(h.badge(), 0);
    // Implementer's reading: in the Snoozed section the Todo filter keeps
    // the PRs with an open Todo row (a snoozed PR is never a Todo PR).
    let snoozed = h.card_ids(ListArgs {
        todo: true,
        snoozed: true,
        ..ListArgs::default()
    });
    assert_eq!(snoozed, ["PR_1"]);
}

#[test]
fn done_changes_only_todo_rows_and_todo_only_rows_not_done() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let b = h.ev("E_2", "PR_1", IngestKind::Merged);
    h.push(vec![pr("PR_1")], vec![a, b], vec![]);
    // DESIGN.md, "Row state transitions": done on a non-Todo row changes
    // nothing.
    h.done("E_2");
    assert!(!h.row("E_2").done);
    h.done("E_1");
    assert!(h.row("E_1").done);
    // todo on a Done row changes nothing.
    h.todo("E_1", false);
    assert_eq!(h.row("E_1").todo_manual, None);
    h.todo("E_2", true);
    assert_eq!(h.row("E_2").todo_manual, Some(true));
    assert_eq!(h.badge(), 1);
}

#[test]
fn a_disabled_owner_counts_nothing() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![a], vec![]);
    assert_eq!(h.badge(), 1);
    let owner = h.owner_id(ORG);
    h.engine.owner_enable(&owner, false, &h.now);
    assert_eq!(h.badge(), 0);
    assert_eq!(h.owner(ORG).todo_count, 0);
    assert!(h.cards().is_empty());
}
