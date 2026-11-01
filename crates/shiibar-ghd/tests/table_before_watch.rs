//! Rule table: events before the watch started. DESIGN.md, section "Events
//! before the watch started", and the brief's matching rules.

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::model::NotifyState;
use support::*;

const BEFORE: i64 = T0 - 100;
const AFTER: i64 = T0 + 1;

#[test]
fn event_table() {
    // (name, kind, occurred_at, requested_me, pr seen before, row, notified)
    let cases = [
        (
            "old comment",
            EventKind::Comment,
            BEFORE,
            false,
            false,
            false,
            false,
        ),
        (
            "old mention",
            EventKind::Mentioned,
            BEFORE,
            false,
            false,
            false,
            false,
        ),
        (
            "old merge",
            EventKind::Merged,
            BEFORE,
            false,
            false,
            false,
            false,
        ),
        (
            "old request, still requested, first fetch",
            EventKind::ReviewRequested,
            BEFORE,
            true,
            false,
            true,
            false,
        ),
        (
            "old request, no longer requested",
            EventKind::ReviewRequested,
            BEFORE,
            false,
            false,
            false,
            false,
        ),
        (
            "old request on a PR already fetched",
            EventKind::ReviewRequested,
            BEFORE,
            true,
            true,
            false,
            false,
        ),
        (
            "exactly at the watch start",
            EventKind::Comment,
            T0,
            false,
            false,
            true,
            true,
        ),
        (
            "new comment on a new PR",
            EventKind::Comment,
            AFTER,
            false,
            false,
            true,
            true,
        ),
        (
            "new request on a new PR",
            EventKind::ReviewRequested,
            AFTER,
            true,
            false,
            true,
            true,
        ),
        (
            "new comment on a known PR",
            EventKind::Comment,
            AFTER,
            false,
            true,
            true,
            true,
        ),
    ];
    for (name, kind, at, requested_me, known, row, notified) in cases {
        let mut h = H::new();
        let p = IngestPr {
            requested_me,
            ..other("PR_1")
        };
        if known {
            h.prs(vec![p.clone()]);
        }
        let e = h.ev_at("E_1", "PR_1", kind, at);
        h.push(vec![p], vec![e], vec![]);
        assert_eq!(h.has_row("E_1"), row, "{name}: row");
        if row {
            assert!(h.row("E_1").unread, "{name}: unread");
            let want = if notified {
                NotifyState::Pending
            } else {
                NotifyState::None
            };
            assert_eq!(h.row("E_1").notify, want, "{name}: notify");
        }
    }
}

#[test]
fn an_old_request_is_needs_action_with_a_badge() {
    let mut h = H::new();
    let e = h.ev_at("E_1", "PR_1", EventKind::ReviewRequested, BEFORE);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_1")
        }],
        vec![e],
        vec![],
    );
    assert_eq!(h.badge(), 1);
    assert_eq!(class(&h.wire_row("E_1").unwrap()), RowClass::NeedsAction);
}

#[test]
fn enabling_a_scope_restarts_the_watch_and_forgets_previous_values() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    h.engine.scope_disable(ORG).unwrap();
    h.advance(100);
    let watch = h.at();
    h.engine.scope_enable(ORG, &h.now).unwrap();
    let old = h.ev_at("E_1", "PR_1", EventKind::Comment, watch - 1);
    let new = h.ev_at("E_2", "PR_1", EventKind::Comment, watch);
    // Failing on the first fetch after the restart is not a change.
    h.push(
        vec![IngestPr {
            checks: Checks::Failed,
            ..pr("PR_1")
        }],
        vec![old, new],
        vec![],
    );
    assert!(!h.has_row("E_1"));
    assert!(h.has_row("E_2"));
    let rows = h.engine.status(&key("PR_1"), &h.now).unwrap().rows;
    assert_eq!(ids(&rows), ["E_2"]);
}

#[test]
fn enabling_an_enabled_scope_changes_nothing() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    h.advance(100);
    h.engine.scope_enable(ORG, &h.now).unwrap();
    h.prs(vec![IngestPr {
        checks: Checks::Failed,
        ..pr("PR_1")
    }]);
    assert_eq!(h.engine.status(&key("PR_1"), &h.now).unwrap().rows.len(), 1);
}

#[test]
fn adding_a_scope_again_restarts_its_watch() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    h.engine.scope_remove(ORG).unwrap();
    h.advance(100);
    let watch = h.at();
    h.engine.scope_add(ORG, &h.now).unwrap();
    let old = h.ev_at("E_1", "PR_1", EventKind::Comment, watch - 1);
    h.push(
        vec![IngestPr {
            checks: Checks::Failed,
            ..pr("PR_1")
        }],
        vec![old],
        vec![],
    );
    assert!(!h.has_row("E_1"));
    assert!(
        h.engine
            .status(&key("PR_1"), &h.now)
            .unwrap()
            .rows
            .is_empty()
    );
}

#[test]
fn each_scope_has_its_own_watch_start() {
    let mut h = H::new();
    h.advance(1000);
    h.engine.scope_add("late", &h.now).unwrap();
    let late = IngestPr {
        owner: "late".into(),
        ..other("PR_2")
    };
    let a = h.ev_at("E_1", "PR_1", EventKind::Comment, T0 + 500);
    let b = h.ev_at("E_2", "PR_2", EventKind::Comment, T0 + 500);
    h.push(vec![other("PR_1"), late], vec![a, b], vec![]);
    assert!(h.has_row("E_1"));
    assert!(!h.has_row("E_2"));
}
