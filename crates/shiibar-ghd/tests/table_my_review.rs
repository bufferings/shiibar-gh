//! Rule table: the My review mark of a card (`my_review`) and the My review
//! rows. DESIGN.md, "Card" ("My review mark"), "Awaiting review", "My review
//! rows", "Applying the table", "Notification decisions" and "Wire format".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::model::NotifyState;
use support::*;

/// alice's PR with the account's newest verdict.
fn reviewed(id: &str, verdict: ReviewVerdict) -> IngestPr {
    IngestPr {
        my_review: Some(verdict),
        ..other(id)
    }
}

fn mark(h: &H, id: &str) -> Option<MyReview> {
    h.card_by_id(id).unwrap().my_review.map(|m| {
        if m.is(MyReview::Approved) {
            MyReview::Approved
        } else {
            MyReview::ChangesRequested
        }
    })
}

/// A My review row of the account's review `id`.
fn my_review(h: &H, id: &str, pr_id: &str, kind: IngestKind) -> IngestEvent {
    IngestEvent {
        actor: Some(ME.into()),
        actor_avatar_url: Some("https://avatars.example/me".into()),
        text: None,
        url: format!("https://github.example/{pr_id}#pullrequestreview-{id}"),
        ..h.ev(id, pr_id, kind)
    }
}

#[test]
fn the_mark_shows_the_newest_verdict() {
    let cases = [
        (ReviewVerdict::Approved, Some(MyReview::Approved)),
        (
            ReviewVerdict::ChangesRequested,
            Some(MyReview::ChangesRequested),
        ),
        (ReviewVerdict::Dismissed, None),
        (ReviewVerdict::None, None),
    ];
    for (verdict, want) in cases {
        let mut h = H::new();
        h.prs(vec![reviewed("PR_1", verdict)]);
        assert_eq!(mark(&h, "PR_1"), want, "{verdict:?}");
        let wire = serde_json::to_value(h.card_by_id("PR_1").unwrap()).unwrap();
        let text = match want {
            Some(MyReview::Approved) => serde_json::json!("approved"),
            Some(MyReview::ChangesRequested) => serde_json::json!("changes_requested"),
            None => serde_json::Value::Null,
        };
        assert_eq!(wire["my_review"], text, "{verdict:?}");
    }
}

#[test]
fn the_mark_shows_no_verdict_where_the_card_shows_none() {
    // (name, PR, dismiss it)
    let cases: [(&str, IngestPr, bool); 5] = [
        (
            "awaiting the account's review",
            IngestPr {
                requested_me: true,
                ..reviewed("PR_1", ReviewVerdict::Approved)
            },
            false,
        ),
        (
            "merged",
            IngestPr {
                state: PrState::Merged,
                ..reviewed("PR_1", ReviewVerdict::Approved)
            },
            false,
        ),
        (
            "closed",
            IngestPr {
                state: PrState::Closed,
                ..reviewed("PR_1", ReviewVerdict::ChangesRequested)
            },
            false,
        ),
        (
            "the account's own PR",
            IngestPr {
                author: ME.into(),
                ..reviewed("PR_1", ReviewVerdict::Approved)
            },
            false,
        ),
        ("dismissed", reviewed("PR_1", ReviewVerdict::Approved), true),
    ];
    for (name, pr, dismiss) in cases {
        let mut h = H::new();
        // Seen open first, so a merged or closed PR keeps its card.
        h.prs(vec![IngestPr {
            state: PrState::Open,
            ..pr.clone()
        }]);
        h.prs(vec![pr]);
        if dismiss {
            h.dismiss(&key("PR_1")).unwrap();
        }
        let card = h.card_by_id("PR_1").unwrap();
        assert_eq!(card.my_review, None, "{name}");
    }
}

#[test]
fn waiting_wins_over_the_verdict_and_ends_with_any_review() {
    let mut h = H::new();
    h.prs(vec![reviewed("PR_1", ReviewVerdict::Approved)]);
    assert_eq!(mark(&h, "PR_1"), Some(MyReview::Approved));
    // Requested again: waiting, the verdict kept underneath.
    let asked = h.ev("RQ_1", "PR_1", IngestKind::ReviewRequested);
    let again = IngestPr {
        requested_me: true,
        my_review_at: Some(T0 - DAY),
        ..reviewed("PR_1", ReviewVerdict::Approved)
    };
    h.push(vec![again], vec![asked], vec![]);
    let card = h.card_by_id("PR_1").unwrap();
    assert!(card.awaiting_review);
    assert_eq!(card.my_review, None);
    // A review without a verdict (COMMENTED) ends the wait; the newest
    // verdict is still the approval.
    let commented = IngestPr {
        requested_me: false,
        my_review_at: Some(h.at()),
        my_review: Some(ReviewVerdict::Approved),
        ..other("PR_1")
    };
    h.prs(vec![commented]);
    let card = h.card_by_id("PR_1").unwrap();
    assert!(!card.awaiting_review);
    assert_eq!(mark(&h, "PR_1"), Some(MyReview::Approved));
}

#[test]
fn a_status_without_the_verdict_keeps_the_saved_one() {
    let mut h = H::new();
    h.prs(vec![reviewed("PR_1", ReviewVerdict::ChangesRequested)]);
    h.prs(vec![other("PR_1")]);
    assert_eq!(mark(&h, "PR_1"), Some(MyReview::ChangesRequested));
    h.prs(vec![reviewed("PR_1", ReviewVerdict::None)]);
    assert_eq!(mark(&h, "PR_1"), None);
}

#[test]
fn my_review_rows_are_read_and_never_notified() {
    for kind in [
        IngestKind::MyReviewApproved,
        IngestKind::MyReviewChangesRequested,
    ] {
        let mut h = H::new();
        let row = my_review(&h, "PRR_1", "PR_1", kind);
        h.push(vec![other("PR_1")], vec![row], vec![]);
        let r = h.row("PRR_1");
        assert!(!r.unread, "{kind:?}");
        assert_eq!(r.notify, NotifyState::None, "{kind:?}");
        assert!(h.delivered().is_empty(), "{kind:?}");
        assert!(!h.dot(), "{kind:?}");
        let wire = h.wire_row("PRR_1").unwrap();
        assert_eq!(wire.actor.as_deref(), Some(ME));
        assert_eq!(wire.text, None);
        assert_eq!(
            wire.actor_avatar_url.as_deref(),
            Some("https://avatars.example/me")
        );
        assert_eq!(h.placement("PR_1"), None, "{kind:?}: not placed in Review");
    }
}

#[test]
fn my_review_has_no_notify_column() {
    let mut h = H::new();
    let owner = h.owner_id(ORG);
    let refused = h.engine.owner_events_set(
        &owner,
        EventKind::MyReview,
        EventColumn::Notify,
        true,
        &h.now,
    );
    assert!(invalid(refused));
    let cell = h.engine.owner_events(&owner)["my_review"];
    assert!(cell.list && !cell.notify);
    // Turning Notify off is no change and allowed; List switches as usual.
    h.table(EventKind::MyReview, EventColumn::Notify, false);
    h.table(EventKind::MyReview, EventColumn::List, false);
    let cell = h.engine.owner_events(&owner)["my_review"];
    assert!(!cell.list && !cell.notify);
}

#[test]
fn my_review_rows_stay_out_of_dismissed_cards_and_stay_after_the_verdict_ends() {
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    h.dismiss(&key("PR_1")).unwrap();
    let on_dismissed = my_review(&h, "PRR_1", "PR_1", IngestKind::MyReviewApproved);
    let kept = my_review(&h, "PRR_2", "PR_2", IngestKind::MyReviewChangesRequested);
    h.push(vec![], vec![on_dismissed, kept], vec![]);
    assert!(h.dismissed("PR_1"), "no return");
    assert!(!h.has_row("PRR_1"));
    // The review is dismissed and the account asked again: the row stays.
    let asked = h.ev("RQ_2", "PR_2", IngestKind::ReviewRequested);
    let again = IngestPr {
        requested_me: true,
        ..reviewed("PR_2", ReviewVerdict::Dismissed)
    };
    h.push(vec![again], vec![asked], vec![]);
    assert!(h.has_row("PRR_2"));
}

#[test]
fn my_review_rows_count_in_the_order_of_all() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.advance(60);
    h.prs(vec![other("PR_2")]);
    assert_eq!(h.tab(Tab::All), ["PR_2", "PR_1"]);
    h.advance(60);
    let row = my_review(&h, "PRR_1", "PR_1", IngestKind::MyReviewApproved);
    h.events(vec![row]);
    assert_eq!(h.tab(Tab::All), ["PR_1", "PR_2"]);
}

/// DESIGN.md, "Mute": a muted PR or repository greys the My review row like
/// any other row of the card.
#[test]
fn my_review_rows_are_grey_on_a_muted_card() {
    for (kind, name) in [(MuteKind::Pr, "org/app#1"), (MuteKind::Repo, "org/app")] {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.mute(kind, name);
        let row = my_review(&h, "PRR_1", "PR_1", IngestKind::MyReviewApproved);
        h.events(vec![row]);
        assert!(h.wire_row("PRR_1").unwrap().muted, "{name}");
        assert!(h.delivered().is_empty(), "{name}");
    }
}

/// DESIGN.md, "Applying the table": with My review's List off, the row is
/// recorded unlisted and read, notifies nothing and is not shown.
#[test]
fn my_review_rows_with_list_off_are_recorded_only() {
    let mut h = H::new();
    h.table(EventKind::MyReview, EventColumn::List, false);
    let row = my_review(&h, "PRR_1", "PR_1", IngestKind::MyReviewChangesRequested);
    h.push(vec![other("PR_1")], vec![row], vec![]);
    let r = h.row("PRR_1");
    assert!(!r.listed && !r.unread);
    assert_eq!(r.notify, NotifyState::None);
    assert!(h.wire_row("PRR_1").is_none(), "not shown");
    assert!(h.delivered().is_empty());
    // List on again: shown, still read.
    h.table(EventKind::MyReview, EventColumn::List, true);
    let wire = h.wire_row("PRR_1").unwrap();
    assert!(!wire.unread);
}
