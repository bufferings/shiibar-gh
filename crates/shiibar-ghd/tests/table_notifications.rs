//! Rule table: notification decisions, delivery records and the summary after
//! reconnecting. DESIGN.md, sections "macOS notifications" and "Notification
//! decisions".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::model::{NotifyState, OwnerKind};
use support::*;

/// Name, kind, own PR, table cell to turn off, whether it notifies.
type RuleCase = (&'static str, IngestKind, bool, Option<EventKind>, bool);
type ChangeCase = (
    &'static str,
    fn(IngestPr) -> IngestPr,
    &'static str,
    Option<&'static str>,
);
type Toggle = (&'static str, fn(&mut H), fn(&mut H));

#[test]
fn which_rows_notify() {
    use IngestKind as K;
    // DESIGN.md, "Row kinds and states": the Notify column of the defaults.
    let cases: Vec<RuleCase> = vec![
        ("review requested", K::ReviewRequested, false, None, true),
        (
            "team review requested",
            K::TeamReviewRequested,
            false,
            None,
            true,
        ),
        ("mentioned", K::Mentioned, false, None, true),
        ("team mentioned", K::TeamMentioned, false, None, true),
        ("comment", K::Comment, false, None, true),
        ("reply", K::Reply, false, None, true),
        (
            "reply where mentioned",
            K::ReplyMentioned,
            false,
            None,
            true,
        ),
        ("approved", K::Approved, true, None, true),
        ("merged", K::Merged, true, None, false),
        ("closed", K::Closed, true, None, false),
        (
            "added to merge queue",
            K::MergeQueueAdded,
            true,
            None,
            false,
        ),
        (
            "removed from merge queue, mine",
            K::MergeQueueRemoved,
            true,
            None,
            true,
        ),
        // M4: an "Any pull request" kind, no longer only for own PRs.
        (
            "removed from merge queue, others'",
            K::MergeQueueRemoved,
            false,
            None,
            true,
        ),
        (
            "comment, Notify off",
            K::Comment,
            false,
            Some(EventKind::Comment),
            false,
        ),
        (
            "reply, Notify off",
            K::Reply,
            false,
            Some(EventKind::Reply),
            false,
        ),
        (
            "comment, another kind off",
            K::Comment,
            false,
            Some(EventKind::ChecksFailed),
            true,
        ),
        (
            "removed from queue, Notify off",
            K::MergeQueueRemoved,
            true,
            Some(EventKind::MergeQueueRemoved),
            false,
        ),
    ];
    for (name, kind, mine, off, want) in cases {
        let mut h = H::new();
        if let Some(event) = off {
            h.table(event, EventColumn::Notify, false);
        }
        let p = if mine { pr("PR_1") } else { other("PR_1") };
        let e = h.ev("E_1", "PR_1", kind);
        h.push(vec![p], vec![e], vec![]);
        let out = h.delivered();
        assert_eq!(out.len(), usize::from(want), "{name}");
        let state = if want {
            NotifyState::Delivered
        } else {
            NotifyState::None
        };
        let id = if kind == K::Approved {
            "E_1:approved"
        } else {
            "E_1"
        };
        assert_eq!(h.row(id).notify, state, "{name}");
    }
}

#[test]
fn state_changes_notify_under_the_checks_failed_notify() {
    let run = |on: bool| {
        let mut h = H::new();
        h.table(EventKind::ChecksFailed, EventColumn::Notify, on);
        h.prs(vec![pr("PR_1")]);
        h.prs(vec![IngestPr {
            checks: Checks::Failed,
            failed_check: Some("build".into()),
            ..pr("PR_1")
        }]);
        h.delivered()
    };
    assert!(run(false).is_empty());
    let out = run(true);
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].title, "me · Checks failed");
    assert_eq!(out[0].body.as_deref(), Some("build"));
    assert_eq!(out[0].url.as_deref(), Some("https://github.example/PR_1/c"));
}

#[test]
fn state_change_titles_and_bodies() {
    let cases: [ChangeCase; 3] = [
        (
            "conflicts",
            |p| IngestPr {
                base_status: BaseStatus::Conflicts,
                ..p
            },
            "me · Conflicts",
            None,
        ),
        (
            "changes requested",
            |p| IngestPr {
                review: Review::ChangesRequested,
                changes_requested_by: Some("bob".into()),
                ..p
            },
            "me · Changes requested",
            Some("bob"),
        ),
        (
            "mergeable",
            |p| IngestPr {
                mergeable: true,
                ..p
            },
            "me · Mergeable",
            None,
        ),
    ];
    for (name, change, title, body) in cases {
        let mut h = H::new();
        h.prs(vec![pr("PR_1")]);
        h.prs(vec![change(pr("PR_1"))]);
        let out = h.delivered();
        assert_eq!(out[0].title, title, "{name}");
        assert_eq!(out[0].body.as_deref(), body, "{name}");
    }
}

#[test]
fn notify_for_the_owner_off_silences_everything() {
    let mut h = H::new();
    let owner = h.owner_id(ORG);
    h.engine.owner_notify(&owner, false);
    let a = h.ev("E_1", "PR_1", IngestKind::Mentioned);
    let b = h.ev("E_2", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![a, b], vec![]);
    assert!(h.delivered().is_empty());
    assert!(h.reconnect().is_empty());
    assert_eq!(h.row("E_1").notify, NotifyState::None);
}

#[test]
fn the_single_notification_text() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Mentioned);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    let out = h.delivered();
    let n = &out[0];
    assert_eq!(n.kind, Lenient::Known(NotificationType::Single));
    assert_eq!(n.account, ACCOUNT);
    assert_eq!(n.owner, h.owner_id(ORG));
    assert_eq!(n.rows, [full("E_1")]);
    assert_eq!(n.pr.as_deref(), Some("org/app#1"));
    assert_eq!(n.url.as_deref(), Some("https://github.example/E_1"));
    assert_eq!(n.title, "me · Mentioned");
    assert_eq!(n.subtitle.as_deref(), Some("org/app #1 · Title PR_1"));
    assert_eq!(n.body.as_deref(), Some("text E_1"));
}

#[test]
fn the_row_kind_labels() {
    // DESIGN.md, "macOS notifications": the names of the event table.
    let cases = [
        (IngestKind::ReviewRequested, "Review requested"),
        (
            IngestKind::TeamReviewRequested,
            "Review requested to my team",
        ),
        (IngestKind::Mentioned, "Mentioned"),
        (IngestKind::TeamMentioned, "My team mentioned"),
        (IngestKind::Comment, "Comment on my PR"),
        (IngestKind::Reply, "Reply in a thread I commented in"),
        (
            IngestKind::ReplyMentioned,
            "Reply in a thread I was mentioned in",
        ),
        (IngestKind::MergeQueueRemoved, "Removed from merge queue"),
    ];
    for (kind, label) in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", kind);
        h.push(vec![other("PR_1")], vec![e], vec![]);
        assert_eq!(h.delivered()[0].title, format!("me · {label}"));
    }
}

#[test]
fn reactions_of_one_fetch_on_one_comment_are_one_notification() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let a = h.reaction("C_1", "PR_1", &[("THUMBS_UP", 3), ("HOORAY", 1)]);
    h.push(vec![], vec![], vec![a]);
    let out = h.delivered();
    assert_eq!(out.len(), 1, "one comment: one individual notification");
    assert_eq!(out[0].rows.len(), 2);
    assert_eq!(out[0].title, "me · Reaction to my comment");
    assert_eq!(out[0].body.as_deref(), Some("👍3 🎉1 “comment C_1”"));
    assert_eq!(out[0].url.as_deref(), Some("https://github.example/C_1"));
}

/// DESIGN.md, "macOS notifications" (M2): the Reactions of two comments are
/// two would-be notifications, so one delivery sums them up.
#[test]
fn reactions_on_two_comments_in_one_fetch_are_a_summary() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let a = h.reaction("C_1", "PR_1", &[("THUMBS_UP", 3), ("HOORAY", 1)]);
    let b = h.reaction("C_2", "PR_1", &[("HEART", 1)]);
    h.push(vec![], vec![], vec![a, b]);
    let out = h.delivered();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].rows.len(), 3, "N counts the rows");
    assert_eq!(out[0].title, "me · 3 new events");
    assert_eq!(out[0].subtitle.as_deref(), Some("org · in 1 PR"));
    assert_eq!(out[0].body, None);
}

#[test]
fn reactions_follow_their_notify_cell() {
    let mut h = H::new();
    h.table(EventKind::Reaction, EventColumn::Notify, false);
    h.prs(vec![pr("PR_1")]);
    let a = h.reaction("C_1", "PR_1", &[("THUMBS_UP", 3)]);
    h.push(vec![], vec![], vec![a]);
    assert!(h.delivered().is_empty());
}

#[test]
fn every_reaction_content_value_has_an_emoji() {
    let cases = [
        ("THUMBS_UP", "👍"),
        ("THUMBS_DOWN", "👎"),
        ("LAUGH", "😄"),
        ("HOORAY", "🎉"),
        ("CONFUSED", "😕"),
        ("HEART", "❤️"),
        ("ROCKET", "🚀"),
        ("EYES", "👀"),
    ];
    for (content, emoji) in cases {
        let mut h = H::new();
        h.prs(vec![pr("PR_1")]);
        let a = h.reaction("C_1", "PR_1", &[(content, 2)]);
        h.push(vec![], vec![], vec![a]);
        let body = h.delivered()[0].body.clone().unwrap();
        assert!(body.starts_with(&format!("{emoji}2 ")), "{content}: {body}");
    }
}

#[test]
fn what_was_handed_over_is_not_sent_again() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    assert_eq!(h.delivered().len(), 1);
    assert!(h.delivered().is_empty());
    assert!(h.reconnect().is_empty());
}

#[test]
fn undelivered_rows_are_one_summary_per_owner_on_reconnect() {
    let mut h = H::new();
    h.engine
        .owner_add(ACCOUNT, "second", OwnerKind::Org, None, &h.now)
        .unwrap();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let b = h.ev("E_2", "PR_1", IngestKind::Reply);
    let c = h.ev("E_3", "PR_2", IngestKind::Comment);
    let d = h.ev("E_4", "PR_3", IngestKind::Comment);
    let second = IngestPr {
        owner: "second".into(),
        ..other("PR_3")
    };
    h.push(
        vec![other("PR_1"), other("PR_2"), second],
        vec![a, b, c, d],
        vec![],
    );
    h.offline();
    let out = h.reconnect();
    assert_eq!(out.len(), 2);
    assert_eq!(out[0].title, "me · 3 new events");
    assert_eq!(out[0].subtitle.as_deref(), Some("org · in 2 PRs"));
    assert_eq!(out[0].body, None);
    assert_eq!(out[1].title, "me · Comment on my PR", "one is individual");
    assert_eq!(out[1].owner, h.owner_id("second"));
    assert_eq!(out[1].kind, Lenient::Known(NotificationType::Single));
    assert!(h.reconnect().is_empty(), "sent once");
}

#[test]
fn a_failed_write_keeps_rows_for_the_next_reconnect() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    let out = h.engine.take_notifications(true, &h.now);
    assert!(h.engine.pending_summaries(&h.now).is_empty(), "on its way");
    h.engine.delivery_failed(&out[0].rows);
    assert_eq!(h.reconnect().len(), 1);
}

#[test]
fn gating_at_hand_over_clears_the_record_for_good() {
    let steps: &[Toggle] = &[
        // DESIGN.md, "Notification decisions": the hand-over checks the
        // owner's Notify, enabled and readability; the table's Notify was
        // decided when the row was made.
        (
            "Notify for the owner",
            |h| {
                let owner = h.owner_id(ORG);
                h.engine.owner_notify(&owner, false)
            },
            |h| {
                let owner = h.owner_id(ORG);
                h.engine.owner_notify(&owner, true)
            },
        ),
        (
            "disabled",
            |h| {
                let owner = h.owner_id(ORG);
                h.engine.owner_enable(&owner, false, &h.now.clone())
            },
            |h| {
                let owner = h.owner_id(ORG);
                h.engine.owner_enable(&owner, true, &h.now.clone())
            },
        ),
    ];
    for (name, off, on) in steps {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", IngestKind::Comment);
        h.push(vec![other("PR_1")], vec![e], vec![]);
        h.offline();
        off(&mut h);
        assert!(h.reconnect().is_empty(), "{name}");
        assert_eq!(h.row("E_1").notify, NotifyState::None, "{name}");
        on(&mut h);
        assert!(
            h.reconnect().is_empty(),
            "{name}: not sent after turning it back on"
        );
    }
}

#[test]
fn a_table_change_after_the_row_does_not_change_its_notification() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    h.offline();
    h.table(EventKind::Comment, EventColumn::Notify, false);
    assert_eq!(h.reconnect().len(), 1);
}

#[test]
fn turning_a_kind_back_on_does_not_notify_rows_made_while_off() {
    let mut h = H::new();
    h.table(EventKind::Comment, EventColumn::Notify, false);
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    h.table(EventKind::Comment, EventColumn::Notify, true);
    assert!(h.delivered().is_empty());
    assert!(h.reconnect().is_empty());
}

#[test]
fn an_unreadable_pr_loses_its_undelivered_record_at_reconnect() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    h.offline();
    h.missing("PR_1");
    assert!(h.reconnect().is_empty());
    assert_eq!(h.row("E_1").notify, NotifyState::None);
}

#[test]
fn a_new_row_on_an_unreadable_pr_neither_notifies_nor_raises_the_dot() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.missing("PR_1");
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.events(vec![e]);
    assert!(h.delivered().is_empty());
    assert!(!h.dot());
    assert_eq!(h.row("E_1").notify, NotifyState::None);
}

#[test]
fn done_rows_stay_out_of_the_reconnect_summary_outside_snooze() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    let b = h.ev("E_2", "PR_2", IngestKind::Comment);
    h.push(vec![other("PR_1"), other("PR_2")], vec![a, b], vec![]);
    h.offline();
    h.done("E_1");
    let out = h.reconnect();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].rows, [full("E_2")]);
    assert_eq!(
        out[0].title, "me · Comment on my PR",
        "one left: individual"
    );
    assert_eq!(out[0].body.as_deref(), Some("text E_2"));
    assert_eq!(h.row("E_1").notify, NotifyState::None);
}

#[test]
fn only_done_rows_mean_no_summary() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![a], vec![]);
    h.offline();
    h.done("E_1");
    assert!(h.reconnect().is_empty());
    h.undone("E_1");
    assert!(
        h.reconnect().is_empty(),
        "the record is gone at the summary"
    );
}

#[test]
fn undone_before_the_reconnect_keeps_a_row_in_the_summary() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![a], vec![]);
    h.offline();
    h.done("E_1");
    h.undone("E_1");
    assert_eq!(h.reconnect().len(), 1);
}

#[test]
fn a_row_done_after_a_missed_release_stays_out_of_the_summary() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.snooze(&key("PR_1"));
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.events(vec![e]);
    h.advance(DAY);
    h.tick();
    h.offline();
    h.done("E_1");
    assert!(h.reconnect().is_empty());
}

/// DESIGN.md, "macOS notifications" and "Notification decisions": the
/// grouping on reconnect is the grouping of any delivery.
#[test]
fn a_single_undelivered_row_comes_back_as_an_individual_notification() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Mentioned);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    h.offline();
    let out = h.reconnect();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].kind, Lenient::Known(NotificationType::Single));
    assert_eq!(out[0].title, "me · Mentioned");
    assert_eq!(out[0].url.as_deref(), Some("https://github.example/E_1"));
}

#[test]
fn reactions_of_one_comment_count_once_on_reconnect() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let a = h.reaction("C_1", "PR_1", &[("THUMBS_UP", 3), ("HOORAY", 1)]);
    h.push(vec![], vec![], vec![a]);
    h.offline();
    let out = h.reconnect();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].kind, Lenient::Known(NotificationType::Single));
    assert_eq!(out[0].rows.len(), 2);
    assert_eq!(out[0].body.as_deref(), Some("👍3 🎉1 “comment C_1”"));

    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let a = h.reaction("C_1", "PR_1", &[("THUMBS_UP", 1)]);
    let b = h.reaction("C_2", "PR_1", &[("HEART", 1)]);
    h.push(vec![], vec![], vec![a, b]);
    h.offline();
    let out = h.reconnect();
    assert_eq!(
        out[0].title, "me · 2 new events",
        "two comments: two notifications"
    );
}

#[test]
fn notification_bodies_collapse_line_breaks_and_runs_of_spaces() {
    // DESIGN.md, "Row kinds and states": the same rule as the rows on screen.
    let cases = [
        ("one\nline", "one line"),
        ("  a \t b\r\n\n  c  ", "a b c"),
        ("plain", "plain"),
    ];
    for (text, want) in cases {
        let mut h = H::new();
        let mut e = h.ev("E_1", "PR_1", IngestKind::Comment);
        e.text = Some(text.into());
        h.push(vec![other("PR_1")], vec![e], vec![]);
        assert_eq!(h.delivered()[0].body.as_deref(), Some(want), "{text:?}");
    }
}
