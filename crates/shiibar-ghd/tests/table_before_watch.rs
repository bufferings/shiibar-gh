//! Rule table: events before the watch started. DESIGN.md, section "Events
//! before the watch started", and the brief's matching rules.

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::model::{NotifyState, OwnerKind};
use support::*;

const BEFORE: i64 = T0 - 100;
const AFTER: i64 = T0 + 1;

#[test]
fn event_table() {
    // (name, kind, occurred_at, requested_me, pr seen before, row, notified)
    let cases = [
        (
            "old comment",
            IngestKind::Comment,
            BEFORE,
            false,
            false,
            false,
            false,
        ),
        (
            "old mention",
            IngestKind::Mentioned,
            BEFORE,
            false,
            false,
            false,
            false,
        ),
        (
            "old merge",
            IngestKind::Merged,
            BEFORE,
            false,
            false,
            false,
            false,
        ),
        (
            "old request, still requested, first fetch",
            IngestKind::ReviewRequested,
            BEFORE,
            true,
            false,
            true,
            false,
        ),
        (
            "old request, no longer requested",
            IngestKind::ReviewRequested,
            BEFORE,
            false,
            false,
            false,
            false,
        ),
        (
            "old request on a PR already fetched",
            IngestKind::ReviewRequested,
            BEFORE,
            true,
            true,
            false,
            false,
        ),
        (
            "exactly at the watch start",
            IngestKind::Comment,
            T0,
            false,
            false,
            true,
            true,
        ),
        (
            "new comment on a new PR",
            IngestKind::Comment,
            AFTER,
            false,
            false,
            true,
            true,
        ),
        (
            "new request on a new PR",
            IngestKind::ReviewRequested,
            AFTER,
            true,
            false,
            true,
            true,
        ),
        (
            "new comment on a known PR",
            IngestKind::Comment,
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
fn an_old_request_still_open_is_an_unread_row_and_awaits_review() {
    let mut h = H::new();
    let e = h.ev_at("E_1", "PR_1", IngestKind::ReviewRequested, BEFORE);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_1")
        }],
        vec![e],
        vec![],
    );
    assert_eq!(h.awaiting_ids().len(), 1);
    assert!(h.wire_row("E_1").unwrap().unread);
    assert!(h.card(&key("PR_1")).unwrap().awaiting_review);
}

#[test]
fn enabling_a_owner_restarts_the_watch_and_forgets_previous_values() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    let owner = h.owner_id(ORG);
    h.engine.owner_enable(&owner, false, &h.now);
    h.advance(100);
    let watch = h.at();
    h.engine.owner_enable(&h.owner_id(ORG), true, &h.now);
    let old = h.ev_at("E_1", "PR_1", IngestKind::Comment, watch - 1);
    let new = h.ev_at("E_2", "PR_1", IngestKind::Comment, watch);
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
    let rows = h.engine.status(ME, &key("PR_1"), &h.now).unwrap().rows;
    assert_eq!(ids(&rows), ["E_2"]);
}

#[test]
fn enabling_an_enabled_owner_changes_nothing() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    h.advance(100);
    h.engine.owner_enable(&h.owner_id(ORG), true, &h.now);
    h.prs(vec![IngestPr {
        checks: Checks::Failed,
        ..pr("PR_1")
    }]);
    assert_eq!(
        h.engine
            .status(ME, &key("PR_1"), &h.now)
            .unwrap()
            .rows
            .len(),
        1
    );
}

#[test]
fn adding_a_owner_again_restarts_its_watch() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    let owner = h.owner_id(ORG);
    h.engine.owner_remove(&owner);
    h.advance(100);
    let watch = h.at();
    h.engine
        .owner_add(ACCOUNT, ORG, OwnerKind::Org, Some(100), &h.now)
        .unwrap();
    let old = h.ev_at("E_1", "PR_1", IngestKind::Comment, watch - 1);
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
            .status(ME, &key("PR_1"), &h.now)
            .unwrap()
            .rows
            .is_empty()
    );
}

#[test]
fn each_owner_has_its_own_watch_start() {
    let mut h = H::new();
    h.advance(1000);
    h.engine
        .owner_add(ACCOUNT, "late", OwnerKind::Org, None, &h.now)
        .unwrap();
    let late = IngestPr {
        owner: "late".into(),
        ..other("PR_2")
    };
    let a = h.ev_at("E_1", "PR_1", IngestKind::Comment, T0 + 500);
    let b = h.ev_at("E_2", "PR_2", IngestKind::Comment, T0 + 500);
    h.push(vec![other("PR_1"), late], vec![a, b], vec![]);
    assert!(h.has_row("E_1"));
    assert!(!h.has_row("E_2"));
}

#[test]
fn the_request_exception_applies_to_a_known_pr_when_the_watch_restarts() {
    let mut h = H::new();
    let requested = IngestPr {
        requested_me: true,
        ..other("PR_1")
    };
    h.prs(vec![requested.clone()]);
    let owner = h.owner_id(ORG);
    h.engine.owner_enable(&owner, false, &h.now);
    h.advance(100);
    let asked = h.at();
    h.advance(100);
    h.engine.owner_enable(&h.owner_id(ORG), true, &h.now);
    let e = h.ev_at("E_1", "PR_1", IngestKind::ReviewRequested, asked);
    h.push(vec![requested], vec![e.clone()], vec![]);
    assert!(h.has_row("E_1"), "the first fetch after the restart");
    assert_eq!(h.row("E_1").notify, NotifyState::None);
    assert_eq!(h.awaiting_ids().len(), 1);
}

#[test]
fn the_request_exception_needs_the_first_fetch_after_the_restart() {
    let mut h = H::new();
    let requested = IngestPr {
        requested_me: true,
        ..other("PR_1")
    };
    let owner = h.owner_id(ORG);
    h.engine.owner_enable(&owner, false, &h.now);
    h.advance(100);
    let asked = h.at();
    h.advance(100);
    h.engine.owner_enable(&h.owner_id(ORG), true, &h.now);
    h.prs(vec![requested.clone()]);
    let e = h.ev_at("E_1", "PR_1", IngestKind::ReviewRequested, asked);
    h.push(vec![requested], vec![e], vec![]);
    assert!(!h.has_row("E_1"));
}

#[test]
fn the_request_exception_applies_to_a_pr_moved_into_a_new_owner() {
    let mut h = H::new();
    let stranger = IngestPr {
        owner: "later".into(),
        requested_me: true,
        ..other("PR_1")
    };
    h.prs(vec![stranger.clone()]);
    assert_eq!(h.card("later/app#1").unwrap().owner, h.owner_id("public"));
    h.advance(100);
    let asked = h.at();
    h.advance(100);
    h.engine
        .owner_add(ACCOUNT, "later", OwnerKind::Org, None, &h.now)
        .unwrap();
    let e = h.ev_at("E_1", "PR_1", IngestKind::ReviewRequested, asked);
    h.push(vec![stranger], vec![e], vec![]);
    assert!(h.has_row("E_1"));
    assert_eq!(h.row("E_1").notify, NotifyState::None);
    assert_eq!(h.card("later/app#1").unwrap().owner, h.owner_id("later"));
}

#[test]
fn a_removed_owner_forgets_its_prs_so_public_fetches_them_as_new() {
    // DESIGN.md, "Owners": removing an owner deletes its PRs. The PR then
    // comes to Public as a first fetch, so the still open request is kept
    // as a silent unread row.
    let mut h = H::new();
    let requested = IngestPr {
        requested_me: true,
        ..other("PR_1")
    };
    h.prs(vec![requested.clone()]);
    let owner = h.owner_id(ORG);
    h.engine.owner_remove(&owner);
    let e = h.ev_at("E_1", "PR_1", IngestKind::ReviewRequested, T0 - 1);
    h.push(vec![requested], vec![e], vec![]);
    assert!(h.has_row("E_1"));
    assert_eq!(h.row("E_1").notify, NotifyState::None);
    assert_eq!(h.card(&key("PR_1")).unwrap().owner, h.owner_id("public"));
}

#[test]
fn an_old_team_request_still_open_is_a_silent_unread_row() {
    let mut h = H::new();
    let e = h.ev_at("E_1", "PR_1", IngestKind::TeamReviewRequested, BEFORE);
    h.push(
        vec![IngestPr {
            requested_team: true,
            ..other("PR_1")
        }],
        vec![e],
        vec![],
    );
    assert!(h.has_row("E_1"));
    assert_eq!(h.row("E_1").notify, NotifyState::None);
    assert!(h.wire_row("E_1").unwrap().unread);
    assert_eq!(h.awaiting_ids().len(), 1);
    let e = h.ev_at("E_2", "PR_2", IngestKind::TeamReviewRequested, BEFORE);
    h.push(vec![other("PR_2")], vec![e], vec![]);
    assert!(!h.has_row("E_2"), "no longer requested");
}
