//! Rule table: row state transitions. DESIGN.md, sections "Row state
//! transitions", "Review requested rows" and "State change rows".

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use support::*;

type Step = fn(&mut H);
/// Name, first fetch, second fetch, whether the first fetch happens.
type NoRowCase = (&'static str, fn() -> IngestPr, fn() -> IngestPr, bool);

struct Flags {
    unread: bool,
    seen_pending: bool,
    done: bool,
}

const fn f(unread: bool, seen_pending: bool, done: bool) -> Flags {
    Flags {
        unread,
        seen_pending,
        done,
    }
}

#[test]
fn trigger_table_for_a_needs_action_row() {
    let cases: &[(&str, &[Step], Flags)] = &[
        ("creation", &[], f(true, false, false)),
        ("seen", &[|h| h.seen(&["E_1"])], f(true, true, false)),
        (
            "seen then popover_closed",
            &[|h| h.seen(&["E_1"]), H::close],
            f(false, false, false),
        ),
        (
            "popover_closed without seen keeps unread",
            &[H::close],
            f(true, false, false),
        ),
        (
            "done",
            &[|h| h.engine.done("E_1").unwrap()],
            f(true, false, true),
        ),
        (
            "done then undone",
            &[
                |h| h.engine.done("E_1").unwrap(),
                |h| h.engine.undone("E_1").unwrap(),
            ],
            f(true, false, false),
        ),
        (
            "done does not change seen tracking",
            &[|h| h.seen(&["E_1"]), |h| h.engine.done("E_1").unwrap()],
            f(true, true, true),
        ),
    ];
    for (name, steps, want) in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", EventKind::Comment);
        h.push(vec![pr("PR_1")], vec![e], vec![]);
        for step in *steps {
            step(&mut h);
        }
        let row = h.row("E_1");
        assert_eq!(row.unread, want.unread, "{name}: unread");
        assert_eq!(row.seen_pending, want.seen_pending, "{name}: seen_pending");
        assert_eq!(row.done, want.done, "{name}: done");
    }
}

#[test]
fn every_event_kind_has_its_class() {
    let cases = [
        (EventKind::Mentioned, RowClass::NeedsAction),
        (EventKind::Comment, RowClass::NeedsAction),
        (EventKind::Reply, RowClass::NeedsAction),
        (EventKind::AddedToMergeQueue, RowClass::Event),
        (EventKind::RemovedFromMergeQueue, RowClass::Event),
        (EventKind::Merged, RowClass::Event),
        (EventKind::Closed, RowClass::Event),
        (EventKind::BotComment, RowClass::Event),
    ];
    for (kind, want) in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", kind);
        h.push(vec![pr("PR_1")], vec![e], vec![]);
        assert_eq!(class(&h.wire_row("E_1").unwrap()), want, "{kind:?}");
    }
}

#[test]
fn done_and_undone_do_not_touch_rows_that_are_not_needs_action() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Merged);
    let stale = h.ev("E_2", "PR_2", EventKind::ReviewRequested);
    h.push(
        vec![
            pr("PR_1"),
            IngestPr {
                state: PrState::Open,
                requested_me: false,
                ..other("PR_2")
            },
        ],
        vec![e, stale],
        vec![],
    );
    h.engine.done("E_1").unwrap();
    h.engine.done("E_2").unwrap();
    assert!(!h.row("E_1").done);
    assert!(!h.row("E_2").done);
}

#[test]
fn review_requested_table() {
    struct Case {
        name: &'static str,
        state: PrState,
        requested_me: bool,
        newer_row: bool,
        class: RowClass,
    }
    let cases = [
        Case {
            name: "latest, open, requested",
            state: PrState::Open,
            requested_me: true,
            newer_row: false,
            class: RowClass::NeedsAction,
        },
        Case {
            name: "request withdrawn",
            state: PrState::Open,
            requested_me: false,
            newer_row: false,
            class: RowClass::Event,
        },
        Case {
            name: "merged",
            state: PrState::Merged,
            requested_me: true,
            newer_row: false,
            class: RowClass::Event,
        },
        Case {
            name: "closed",
            state: PrState::Closed,
            requested_me: true,
            newer_row: false,
            class: RowClass::Event,
        },
        Case {
            name: "not the latest row",
            state: PrState::Open,
            requested_me: true,
            newer_row: true,
            class: RowClass::Event,
        },
    ];
    for c in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", EventKind::ReviewRequested);
        let open = IngestPr {
            requested_me: true,
            ..other("PR_1")
        };
        h.push(vec![open], vec![e], vec![]);
        let later = IngestPr {
            state: c.state,
            requested_me: c.requested_me,
            ..other("PR_1")
        };
        let events = if c.newer_row {
            vec![h.ev("E_2", "PR_1", EventKind::ReviewRequested)]
        } else {
            vec![]
        };
        h.push(vec![later], events, vec![]);
        // The row may have left the card list; `status` still shows it.
        let card = h.engine.status(&key("PR_1"), &h.now).unwrap();
        let row = card.rows.iter().find(|r| r.id == "E_1").unwrap();
        assert_eq!(class(row), c.class, "{}", c.name);
    }
}

#[test]
fn a_row_that_stopped_being_needs_action_keeps_done_and_unread() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::ReviewRequested);
    let open = IngestPr {
        requested_me: true,
        ..other("PR_1")
    };
    h.push(vec![open.clone()], vec![e], vec![]);
    h.engine.done("E_1").unwrap();
    h.prs(vec![IngestPr {
        requested_me: false,
        ..other("PR_1")
    }]);
    assert!(h.row("E_1").done);
    assert!(h.row("E_1").unread);
    h.prs(vec![open]);
    assert!(h.row("E_1").done);
}

#[test]
fn reopening_returns_a_pruned_review_requested_row_to_needs_action() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::ReviewRequested);
    let open = IngestPr {
        requested_me: true,
        ..other("PR_1")
    };
    h.push(vec![open.clone()], vec![e], vec![]);
    h.prs(vec![IngestPr {
        state: PrState::Closed,
        ..open.clone()
    }]);
    let newer: Vec<_> = (2..6)
        .map(|n| h.ev(&format!("E_{n}"), "PR_1", EventKind::Closed))
        .collect();
    h.events(newer);
    let all: Vec<String> = (1..6).map(|n| format!("E_{n}")).collect();
    h.engine.seen(&all);
    h.close();
    assert!(h.row("E_1").pruned, "older read rows are pruned");
    h.prs(vec![open]);
    assert!(!h.row("E_1").pruned);
    assert_eq!(class(&h.wire_row("E_1").unwrap()), RowClass::NeedsAction);
    assert_eq!(h.badge(), 1);
}

#[test]
fn the_same_event_never_makes_two_rows() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![pr("PR_1")], vec![e.clone()], vec![]);
    h.engine.done("E_1").unwrap();
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    let rows = h.engine.activity(&Filter::default(), &h.now).unwrap();
    assert_eq!(ids(&rows), ["E_1"]);
    assert!(h.row("E_1").done, "the existing row is left as it was");
}

#[test]
fn state_change_table() {
    struct Case {
        name: &'static str,
        before: fn(IngestPr) -> IngestPr,
        after: fn(IngestPr) -> IngestPr,
        kind: RowKind,
        text: Option<&'static str>,
        url: &'static str,
    }
    let cases = [
        Case {
            name: "checks fail",
            before: |p| IngestPr {
                checks: Checks::Passed,
                ..p
            },
            after: |p| IngestPr {
                checks: Checks::Failed,
                failed_check: Some("build".into()),
                ..p
            },
            kind: RowKind::ChecksFailed,
            text: Some("build"),
            url: "https://github.example/PR_1/c",
        },
        Case {
            name: "checks fail from in progress",
            before: |p| IngestPr {
                checks: Checks::InProgress,
                ..p
            },
            after: |p| IngestPr {
                checks: Checks::Failed,
                failed_check: Some("lint".into()),
                ..p
            },
            kind: RowKind::ChecksFailed,
            text: Some("lint"),
            url: "https://github.example/PR_1/c",
        },
        Case {
            name: "conflicts",
            before: |p| IngestPr {
                base_status: BaseStatus::Behind,
                ..p
            },
            after: |p| IngestPr {
                base_status: BaseStatus::Conflicts,
                ..p
            },
            kind: RowKind::Conflicts,
            text: None,
            url: "https://github.example/PR_1/b",
        },
        Case {
            name: "changes requested",
            before: |p| IngestPr {
                review: Review::ReviewRequired,
                ..p
            },
            after: |p| IngestPr {
                review: Review::ChangesRequested,
                changes_requested_by: Some("bob".into()),
                ..p
            },
            kind: RowKind::ChangesRequested,
            text: Some("bob"),
            url: "https://github.example/PR_1/r",
        },
        Case {
            name: "mergeable",
            before: |p| IngestPr {
                mergeable: false,
                ..p
            },
            after: |p| IngestPr {
                mergeable: true,
                ..p
            },
            kind: RowKind::Mergeable,
            text: None,
            url: "https://github.example/PR_1",
        },
    ];
    for c in cases {
        let mut h = H::new();
        h.prs(vec![(c.before)(pr("PR_1"))]);
        let detected = h.at();
        h.prs(vec![(c.after)(pr("PR_1"))]);
        let rows = h.engine.activity(&Filter::default(), &h.now).unwrap();
        assert_eq!(rows.len(), 1, "{}", c.name);
        let row = &rows[0];
        assert_eq!(row.kind, Lenient::Known(c.kind), "{}", c.name);
        assert_eq!(row.text.as_deref(), c.text, "{}", c.name);
        assert_eq!(row.url, c.url, "{}", c.name);
        assert_eq!(row.occurred_at, detected, "{}", c.name);
        assert_eq!(row.actor, None, "{}", c.name);
        assert_eq!(class(row), RowClass::Event, "{}", c.name);
        assert!(row.unread, "{}", c.name);
    }
}

#[test]
fn state_changes_that_make_no_row() {
    let cases: &[NoRowCase] = &[
        (
            "another check fails while already failed",
            || IngestPr {
                checks: Checks::Failed,
                failed_check: Some("a".into()),
                ..pr("PR_1")
            },
            || IngestPr {
                checks: Checks::Failed,
                failed_check: Some("b".into()),
                ..pr("PR_1")
            },
            true,
        ),
        (
            "another reviewer while already changes_requested",
            || IngestPr {
                review: Review::ChangesRequested,
                changes_requested_by: Some("a".into()),
                ..pr("PR_1")
            },
            || IngestPr {
                review: Review::ChangesRequested,
                changes_requested_by: Some("b".into()),
                ..pr("PR_1")
            },
            true,
        ),
        (
            "still conflicting",
            || IngestPr {
                base_status: BaseStatus::Conflicts,
                ..pr("PR_1")
            },
            || IngestPr {
                base_status: BaseStatus::Conflicts,
                ..pr("PR_1")
            },
            true,
        ),
        (
            "still mergeable",
            || IngestPr {
                mergeable: true,
                ..pr("PR_1")
            },
            || IngestPr {
                mergeable: true,
                ..pr("PR_1")
            },
            true,
        ),
        (
            "mergeable turns off",
            || IngestPr {
                mergeable: true,
                ..pr("PR_1")
            },
            || IngestPr {
                mergeable: false,
                ..pr("PR_1")
            },
            true,
        ),
        (
            "someone else's PR",
            || other("PR_1"),
            || IngestPr {
                checks: Checks::Failed,
                ..other("PR_1")
            },
            true,
        ),
        (
            "own PR that is not open",
            || IngestPr {
                state: PrState::Closed,
                ..pr("PR_1")
            },
            || IngestPr {
                state: PrState::Closed,
                checks: Checks::Failed,
                ..pr("PR_1")
            },
            true,
        ),
        (
            "first detection has no previous value",
            || IngestPr {
                checks: Checks::Failed,
                ..pr("PR_1")
            },
            || IngestPr {
                checks: Checks::Failed,
                ..pr("PR_1")
            },
            false,
        ),
    ];
    for (name, before, after, ingest_before) in cases {
        let mut h = H::new();
        if *ingest_before {
            h.prs(vec![before()]);
        }
        h.prs(vec![after()]);
        let rows = h.engine.status(&key("PR_1"), &h.now).unwrap().rows;
        assert!(rows.is_empty(), "{name}: {rows:?}");
    }
}

#[test]
fn failing_again_after_recovery_makes_a_new_row() {
    let mut h = H::new();
    let failed = IngestPr {
        checks: Checks::Failed,
        ..pr("PR_1")
    };
    let passed = IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    };
    h.prs(vec![passed.clone()]);
    h.prs(vec![failed.clone()]);
    h.prs(vec![passed]);
    h.prs(vec![failed]);
    let rows = h.engine.activity(&Filter::default(), &h.now).unwrap();
    assert_eq!(rows.len(), 2);
    assert_ne!(rows[0].id, rows[1].id);
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.checks, Lenient::Known(Checks::Failed));
}

#[test]
fn hidden_bot_comments_are_recorded_read_and_stay_out_of_everything() {
    let mut h = H::new();
    h.set("bot_comments", json!("hide"));
    let e = h.ev("E_1", "PR_1", EventKind::BotComment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    assert!(h.has_row("E_1"));
    assert!(h.wire_row("E_1").is_none());
    assert!(!h.visible("PR_1") || h.cards(&Filter::default())[0].rows.is_empty());
    assert!(!h.dot());
    h.set("bot_comments", json!("list_only"));
    let row = h.wire_row("E_1").unwrap();
    assert!(!row.unread, "read when shown again");
}

#[test]
fn hide_also_clears_earlier_unread_bot_comments_when_shown_again() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::BotComment);
    h.push(
        vec![IngestPr {
            state: PrState::Closed,
            ..other("PR_1")
        }],
        vec![e],
        vec![],
    );
    assert!(h.visible("PR_1"), "unread shows the card");
    h.set("bot_comments", json!("hide"));
    assert!(!h.visible("PR_1"), "a hidden row is not unread");
    h.set("bot_comments", json!("notify"));
    assert!(!h.visible("PR_1"), "shown again as read");
    assert!(!h.row("E_1").unread);
}

#[test]
fn previous_values_keep_tracking_while_a_pr_is_closed() {
    let closed = |checks| IngestPr {
        state: PrState::Closed,
        checks,
        ..pr("PR_1")
    };
    let open = |checks| IngestPr {
        checks,
        ..pr("PR_1")
    };
    let kinds = |h: &H| {
        h.engine
            .status(&key("PR_1"), &h.now)
            .unwrap()
            .rows
            .iter()
            .filter(|r| r.kind == Lenient::Known(RowKind::ChecksFailed))
            .count()
    };

    // Failed while closed, still failed on reopening: nothing changed.
    let mut h = H::new();
    h.prs(vec![open(Checks::Passed)]);
    h.prs(vec![closed(Checks::Failed)]);
    h.prs(vec![open(Checks::Failed)]);
    assert_eq!(kinds(&h), 0);

    // Passed while closed, failing after reopening: a change.
    let mut h = H::new();
    h.prs(vec![open(Checks::Failed)]);
    h.prs(vec![closed(Checks::Passed)]);
    h.prs(vec![open(Checks::Passed)]);
    h.prs(vec![open(Checks::Failed)]);
    assert_eq!(kinds(&h), 1);

    // Passed while closed, failed in the same fetch as the reopening.
    let mut h = H::new();
    h.prs(vec![open(Checks::Failed)]);
    h.prs(vec![closed(Checks::Passed)]);
    h.prs(vec![open(Checks::Failed)]);
    assert_eq!(kinds(&h), 1);
}
