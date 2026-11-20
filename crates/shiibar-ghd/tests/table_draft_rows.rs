//! Rule table: Ready for review and Converted to draft rows. DESIGN.md,
//! "Ready for review and Converted to draft rows", "Rows of the account's own
//! events", "macOS notifications" and "Notification decisions".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::model::NotifyState;
use support::*;

fn draft(id: &str) -> IngestPr {
    IngestPr {
        is_draft: true,
        ..other(id)
    }
}

/// An event of the kind by alice, without a body, opening its place on the
/// PR page.
fn draft_event(h: &H, id: &str, kind: IngestKind) -> IngestEvent {
    IngestEvent {
        text: None,
        url: format!("https://github.example/PR_1#event-{id}"),
        ..h.ev(id, "PR_1", kind)
    }
}

fn skip_drafts(h: &mut H, on: bool) {
    let owner = h.owner_id(ORG);
    h.engine.owner_skip_drafts(&owner, on);
}

#[test]
fn the_rows_carry_their_actor_and_url_and_no_body() {
    let mut h = H::new();
    let ready = draft_event(&h, "E_R", IngestKind::ReadyForReview);
    let back = IngestEvent {
        actor: None,
        ..draft_event(&h, "E_D", IngestKind::ConvertedToDraft)
    };
    h.push(vec![other("PR_1")], vec![ready, back], vec![]);
    let row = h.wire_row("E_R").unwrap();
    assert!(row.kind.is(RowKind::ReadyForReview));
    assert_eq!(
        serde_json::to_value(&row).unwrap()["kind"],
        "ready_for_review"
    );
    assert_eq!(row.text, None);
    assert_eq!(row.actor.as_deref(), Some("alice"));
    assert_eq!(row.url, "https://github.example/PR_1#event-E_R");
    assert!(row.unread);
    let row = h.wire_row("E_D").unwrap();
    assert_eq!(
        serde_json::to_value(&row).unwrap()["kind"],
        "converted_to_draft"
    );
    assert_eq!(row.actor, None, "an event whose actor is null");
    assert_eq!(row.text, None);
}

#[test]
fn by_default_ready_for_review_notifies_and_converted_to_draft_does_not() {
    for skip in [true, false] {
        let mut h = H::new();
        skip_drafts(&mut h, skip);
        let ready = draft_event(&h, "E_R", IngestKind::ReadyForReview);
        let back = draft_event(&h, "E_D", IngestKind::ConvertedToDraft);
        h.push(vec![other("PR_1")], vec![ready, back], vec![]);
        let out = h.delivered();
        assert_eq!(out.len(), 1, "skip {skip}");
        assert_eq!(out[0].title, "me · Ready for review", "skip {skip}");
        assert_eq!(h.row("E_D").notify, NotifyState::None, "skip {skip}");
        assert!(h.row("E_D").unread, "listed and unread: skip {skip}");
    }
}

#[test]
fn skip_drafts_holds_a_review_request_on_a_draft_and_not_its_end() {
    let mut h = H::new();
    skip_drafts(&mut h, true);
    let asked = h.ev("E_Q", "PR_1", IngestKind::ReviewRequested);
    h.push(vec![draft("PR_1")], vec![asked], vec![]);
    assert!(
        h.delivered().is_empty(),
        "a draft's review request is quiet"
    );
    assert!(h.row("E_Q").unread);
    // The status still says draft right after the draft ended.
    let ready = draft_event(&h, "E_R", IngestKind::ReadyForReview);
    h.push(vec![draft("PR_1")], vec![ready], vec![]);
    let out = h.delivered();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].rows, [full("E_R")]);
}

#[test]
fn converted_to_draft_is_judged_by_its_kind_not_by_the_saved_draft_flag() {
    // The status still says ready, and the table notifies the kind.
    let run = |skip: bool| {
        let mut h = H::new();
        skip_drafts(&mut h, skip);
        h.table(EventKind::ConvertedToDraft, EventColumn::Notify, true);
        let back = draft_event(&h, "E_D", IngestKind::ConvertedToDraft);
        h.push(vec![other("PR_1")], vec![back], vec![]);
        h.delivered().len()
    };
    assert_eq!(run(true), 0, "Skip draft pull requests on: never");
    assert_eq!(run(false), 1, "off: the table's Notify");
}

#[test]
fn both_kinds_in_one_fetch_are_judged_each_by_its_kind() {
    for is_draft in [true, false] {
        let mut h = H::new();
        skip_drafts(&mut h, true);
        h.table(EventKind::ConvertedToDraft, EventColumn::Notify, true);
        let back = draft_event(&h, "E_D", IngestKind::ConvertedToDraft);
        let ready = draft_event(&h, "E_R", IngestKind::ReadyForReview);
        let pr = IngestPr {
            is_draft,
            ..other("PR_1")
        };
        h.push(vec![pr], vec![back, ready], vec![]);
        let out = h.delivered();
        assert_eq!(out.len(), 1, "draft {is_draft}");
        assert_eq!(out[0].rows, [full("E_R")], "draft {is_draft}");
        assert_eq!(h.row("E_D").notify, NotifyState::None, "draft {is_draft}");
    }
}

#[test]
fn the_accounts_own_change_is_read_and_quiet() {
    for kind in [IngestKind::ReadyForReview, IngestKind::ConvertedToDraft] {
        let mut h = H::new();
        h.table(EventKind::ConvertedToDraft, EventColumn::Notify, true);
        let own = IngestEvent {
            actor: Some("Me".into()),
            ..draft_event(&h, "E_1", kind)
        };
        h.push(vec![pr("PR_1")], vec![own], vec![]);
        assert!(h.delivered().is_empty(), "{kind:?}");
        assert!(!h.row("E_1").unread, "{kind:?}");
        assert!(!h.dot(), "{kind:?}");
    }
}

#[test]
fn the_rows_neither_bring_a_card_back_nor_place_it_in_review() {
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    h.dismiss("org/app#1").unwrap();
    let ready = draft_event(&h, "E_R", IngestKind::ReadyForReview);
    let back = IngestEvent {
        pr_id: "PR_2".into(),
        ..draft_event(&h, "E_D", IngestKind::ConvertedToDraft)
    };
    let ready2 = IngestEvent {
        pr_id: "PR_2".into(),
        ..draft_event(&h, "E_R2", IngestKind::ReadyForReview)
    };
    h.push(vec![], vec![ready, back, ready2], vec![]);
    assert!(h.dismissed("PR_1"), "no return");
    assert!(!h.has_row("E_R"), "no row on a dismissed card");
    assert!(h.has_row("E_D") && h.has_row("E_R2"));
    assert_eq!(h.placement("PR_2"), None, "not placed in Review");
}

#[test]
fn a_muted_actor_grays_the_rows() {
    let mut h = H::new();
    h.mute(MuteKind::User, "alice");
    let ready = draft_event(&h, "E_R", IngestKind::ReadyForReview);
    h.push(vec![pr("PR_1")], vec![ready], vec![]);
    assert!(h.wire_row("E_R").unwrap().muted);
    assert!(h.delivered().is_empty());
}
