//! Rule table: row state transitions. DESIGN.md, sections "Row state
//! transitions", "Review requested rows" and "State change rows".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::engine::ActivityArgs;
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
fn trigger_table_for_a_todo_row() {
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
        ("done", &[|h| h.done("E_1")], f(true, false, true)),
        (
            "done then undone",
            &[|h| h.done("E_1"), |h| h.undone("E_1")],
            f(true, false, false),
        ),
        (
            "done does not change seen tracking",
            &[|h| h.seen(&["E_1"]), |h| h.done("E_1")],
            f(true, true, true),
        ),
    ];
    for (name, steps, want) in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", IngestKind::Comment);
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
fn every_event_kind_follows_the_default_table() {
    // DESIGN.md, "Row kinds and states": the Todo column of the defaults.
    let cases = [
        (IngestKind::Mentioned, true),
        (IngestKind::TeamMentioned, true),
        (IngestKind::Comment, true),
        (IngestKind::Reply, true),
        (IngestKind::ReplyMentioned, true),
        (IngestKind::Approved, false),
        (IngestKind::MergeQueueAdded, false),
        (IngestKind::MergeQueueRemoved, false),
        (IngestKind::Merged, false),
        (IngestKind::Closed, false),
    ];
    for (kind, want) in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", kind);
        h.push(vec![pr("PR_1")], vec![e], vec![]);
        let id = if kind == IngestKind::Approved {
            "E_1:approved"
        } else {
            "E_1"
        };
        assert_eq!(h.wire_row(id).unwrap().todo, want, "{kind:?}");
    }
}

#[test]
fn done_does_not_touch_rows_that_are_not_todo() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Merged);
    let stale = h.ev("E_2", "PR_2", IngestKind::ReviewRequested);
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
    h.done("E_1");
    h.done("E_2");
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
        team: bool,
        todo: bool,
    }
    let cases = [
        Case {
            name: "latest, open, requested",
            state: PrState::Open,
            requested_me: true,
            newer_row: false,
            team: false,
            todo: true,
        },
        Case {
            name: "request withdrawn",
            state: PrState::Open,
            requested_me: false,
            newer_row: false,
            team: false,
            todo: false,
        },
        Case {
            name: "merged",
            state: PrState::Merged,
            requested_me: true,
            newer_row: false,
            team: false,
            todo: false,
        },
        Case {
            name: "closed",
            state: PrState::Closed,
            requested_me: true,
            newer_row: false,
            team: false,
            todo: false,
        },
        Case {
            name: "not the latest row",
            state: PrState::Open,
            requested_me: true,
            newer_row: true,
            team: false,
            todo: false,
        },
    ];
    let cases = cases.into_iter().chain([
        Case {
            name: "team: latest, open, requested",
            state: PrState::Open,
            requested_me: true,
            newer_row: false,
            team: true,
            todo: true,
        },
        Case {
            name: "team: request withdrawn",
            state: PrState::Open,
            requested_me: false,
            newer_row: false,
            team: true,
            todo: false,
        },
        Case {
            name: "team: a newer direct request is the latest",
            state: PrState::Open,
            requested_me: true,
            newer_row: true,
            team: true,
            todo: false,
        },
    ]);
    for c in cases {
        let mut h = H::new();
        let kind = if c.team {
            IngestKind::TeamReviewRequested
        } else {
            IngestKind::ReviewRequested
        };
        let e = h.ev("E_1", "PR_1", kind);
        let asked = |on: bool| IngestPr {
            requested_me: on && !c.team,
            requested_team: on && c.team,
            ..other("PR_1")
        };
        h.push(vec![asked(true)], vec![e], vec![]);
        let later = IngestPr {
            state: c.state,
            ..asked(c.requested_me)
        };
        let events = if c.newer_row {
            vec![h.ev("E_2", "PR_1", IngestKind::ReviewRequested)]
        } else {
            vec![]
        };
        h.push(vec![later], events, vec![]);
        // The row may have left the card list; `status` still shows it.
        let card = h.engine.status(ME, &key("PR_1"), &h.now).unwrap();
        let row = card.rows.iter().find(|r| r.id == full("E_1")).unwrap();
        assert_eq!(row.todo, c.todo, "{}", c.name);
    }
}

#[test]
fn a_row_that_stopped_being_todo_keeps_done_and_unread() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::ReviewRequested);
    let open = IngestPr {
        requested_me: true,
        ..other("PR_1")
    };
    h.push(vec![open.clone()], vec![e], vec![]);
    h.done("E_1");
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
fn reopening_returns_a_pruned_review_requested_row_to_todo() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::ReviewRequested);
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
        .map(|n| h.ev(&format!("E_{n}"), "PR_1", IngestKind::Closed))
        .collect();
    h.events(newer);
    let all: Vec<String> = (1..6).map(|n| format!("E_{n}")).collect();
    h.engine
        .seen(&all.iter().map(|s| full(s)).collect::<Vec<_>>());
    h.close();
    assert!(h.row("E_1").pruned, "older read rows are pruned");
    h.prs(vec![open]);
    assert!(!h.row("E_1").pruned);
    assert!(h.wire_row("E_1").unwrap().todo);
    assert_eq!(h.badge(), 1);
}

#[test]
fn the_same_event_never_makes_two_rows() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e.clone()], vec![]);
    h.done("E_1");
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    let rows = h.activity(ActivityArgs::default());
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
        let rows = h.activity(ActivityArgs::default());
        assert_eq!(rows.len(), 1, "{}", c.name);
        let row = &rows[0];
        assert_eq!(row.kind, Lenient::Known(c.kind), "{}", c.name);
        assert_eq!(row.text.as_deref(), c.text, "{}", c.name);
        assert_eq!(row.url, c.url, "{}", c.name);
        assert_eq!(row.occurred_at, detected, "{}", c.name);
        assert_eq!(row.actor, None, "{}", c.name);
        assert!(!row.todo, "{}", c.name);
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
        let rows = h.engine.status(ME, &key("PR_1"), &h.now).unwrap().rows;
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
    let rows = h.activity(ActivityArgs::default());
    assert_eq!(rows.len(), 2);
    assert_ne!(rows[0].id, rows[1].id);
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.checks, Lenient::Known(Checks::Failed));
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
            .status(ME, &key("PR_1"), &h.now)
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
