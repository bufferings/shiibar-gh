//! Rule table: row state transitions. DESIGN.md, sections "Row state
//! transitions", "Review requested rows" and "State change rows".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::engine::ActivityArgs;
use support::*;

type Step = fn(&mut H);
/// Name, first fetch, second fetch, whether the first fetch happens.
type NoRowCase = (&'static str, fn() -> IngestPr, fn() -> IngestPr, bool);

#[test]
fn trigger_table() {
    // DESIGN.md, "Row state transitions": unread is the only state.
    let cases: &[(&str, &[Step], bool)] = &[
        ("creation", &[], true),
        ("read", &[|h| h.read(&["E_1"])], false),
        (
            "popover_opened and popover_closed keep unread",
            &[H::open, H::close],
            true,
        ),
        ("read while open", &[H::open, |h| h.read(&["E_1"])], false),
        ("read_all", &[H::read_all], false),
        (
            "read twice",
            &[|h| h.read(&["E_1"]), |h| h.read(&["E_1"])],
            false,
        ),
    ];
    for (name, steps, unread) in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", IngestKind::Comment);
        h.push(vec![pr("PR_1")], vec![e], vec![]);
        for step in *steps {
            step(&mut h);
        }
        assert_eq!(h.row("E_1").unread, *unread, "{name}");
    }
}

#[test]
fn every_event_kind_makes_an_unread_row() {
    let cases = [
        IngestKind::ReviewRequested,
        IngestKind::Mentioned,
        IngestKind::TeamMentioned,
        IngestKind::Comment,
        IngestKind::Reply,
        IngestKind::ReplyMentioned,
        IngestKind::Approved,
        IngestKind::MergeQueueAdded,
        IngestKind::MergeQueueRemoved,
        IngestKind::Merged,
        IngestKind::Closed,
    ];
    for kind in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", kind);
        h.push(vec![pr("PR_1")], vec![e], vec![]);
        let id = if kind == IngestKind::Approved {
            "E_1:approved"
        } else {
            "E_1"
        };
        assert!(h.wire_row(id).unwrap().unread, "{kind:?}");
    }
}

#[test]
fn read_all_reads_every_row_of_the_account_but_those_of_dismissed_prs() {
    // DESIGN.md, "Wire format": `read_all`, rows the list does not show
    // included.
    let mut h = H::new();
    h.add_other();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let b = h.ev("E_2", "PR_2", IngestKind::Comment);
    let mut hidden = h.ev("E_3", "PR_1", IngestKind::Mentioned);
    hidden.actor = Some("bot".into());
    h.push(vec![pr("PR_1"), pr("PR_2")], vec![a, b], vec![]);
    h.push_to(
        OTHER,
        vec![IngestPr {
            author: YOU.into(),
            ..pr("PR_1")
        }],
        vec![h.ev("E_1", "PR_1", IngestKind::Comment)],
        vec![],
    )
    .unwrap();
    h.dismiss(&key("PR_2")).unwrap();
    // A row made while its kind's List is on, then hidden by the List.
    h.events(vec![hidden]);
    h.table(EventKind::Mentioned, EventColumn::List, false);
    assert!(h.row("E_3").unread);
    h.read_all();
    assert!(!h.row("E_1").unread);
    assert!(!h.row("E_3").unread, "a row the list does not show");
    assert!(h.row("E_2").unread, "a dismissed PR keeps its unread rows");
    assert!(
        h.engine.row_record("1002:E_1").unwrap().unread,
        "another account"
    );
    assert!(not_found(h.engine.read_all("nobody")));
}

#[test]
fn a_review_request_row_is_a_record_and_the_pr_state_awaits() {
    // DESIGN.md, "Review requested rows".
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::ReviewRequested);
    let open = IngestPr {
        requested_me: true,
        ..other("PR_1")
    };
    h.push(vec![open.clone()], vec![e], vec![]);
    h.read(&["E_1"]);
    assert_eq!(
        h.awaiting_ids().len(),
        1,
        "reading the row keeps the request"
    );
    h.prs(vec![IngestPr {
        requested_me: false,
        ..other("PR_1")
    }]);
    assert_eq!(h.awaiting_ids().len(), 0, "withdrawn");
    assert!(!h.row("E_1").unread);
    h.prs(vec![open]);
    assert_eq!(h.awaiting_ids().len(), 1);
}

#[test]
fn the_same_event_never_makes_two_rows() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e.clone()], vec![]);
    h.read(&["E_1"]);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    let rows = h.activity(ActivityArgs::default());
    assert_eq!(ids(&rows), ["E_1"]);
    assert!(!h.row("E_1").unread, "the existing row is left as it was");
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
            if before().state != PrState::Open {
                // DESIGN.md, "API usage": a closed PR is taken only when
                // known; this one was open first.
                h.prs(vec![pr("PR_1")]);
            }
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
    let kinds: Vec<String> = rows.iter().map(|r| r.kind.as_text()).collect();
    // DESIGN.md, "State change rows": Checks passed after a failure too.
    assert_eq!(kinds, ["checks_failed", "checks_passed", "checks_failed"]);
    assert_ne!(rows[0].id, rows[2].id);
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
