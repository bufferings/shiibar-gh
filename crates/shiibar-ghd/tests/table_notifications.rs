//! Rule table: notification decisions, delivery records and the summary after
//! reconnecting. DESIGN.md, sections "macOS notifications" and "Notification
//! decisions".

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use shiibar_ghd::model::NotifyState;
use support::*;

/// Name, kind, own PR, setting to apply, whether it notifies.
type RuleCase = (
    &'static str,
    EventKind,
    bool,
    Option<(&'static str, serde_json::Value)>,
    bool,
);
type ChangeCase = (
    &'static str,
    fn(IngestPr) -> IngestPr,
    &'static str,
    Option<&'static str>,
);
type Toggle = (&'static str, fn(&mut H), fn(&mut H));

#[test]
fn which_rows_notify() {
    let k = EventKind::Comment;
    // (name, kind, mine, setting key, setting value, notified)
    let cases: Vec<RuleCase> = vec![
        (
            "review requested",
            EventKind::ReviewRequested,
            false,
            None,
            true,
        ),
        ("mentioned", EventKind::Mentioned, false, None, true),
        ("comment", k, false, None, true),
        ("reply", EventKind::Reply, false, None, true),
        ("merged", EventKind::Merged, true, None, false),
        ("closed", EventKind::Closed, true, None, false),
        (
            "added to merge queue",
            EventKind::AddedToMergeQueue,
            true,
            None,
            false,
        ),
        (
            "removed from merge queue, mine",
            EventKind::RemovedFromMergeQueue,
            true,
            None,
            true,
        ),
        (
            "removed from merge queue, others'",
            EventKind::RemovedFromMergeQueue,
            false,
            None,
            false,
        ),
        (
            "bot comment, list only",
            EventKind::BotComment,
            false,
            None,
            false,
        ),
        (
            "bot comment, notify",
            EventKind::BotComment,
            false,
            Some(("bot_comments", json!("notify"))),
            true,
        ),
        (
            "bot comment, hide",
            EventKind::BotComment,
            false,
            Some(("bot_comments", json!("hide"))),
            false,
        ),
        (
            "bot comment ignores the kind toggles",
            EventKind::BotComment,
            false,
            Some(("bot_comments", json!("notify"))),
            true,
        ),
        (
            "comment, activity off",
            k,
            false,
            Some(("notify_activity", json!(false))),
            false,
        ),
        (
            "reply, activity off",
            EventKind::Reply,
            false,
            Some(("notify_activity", json!(false))),
            false,
        ),
        (
            "comment, state off",
            k,
            false,
            Some(("notify_state", json!(false))),
            true,
        ),
        (
            "removed from queue, state off",
            EventKind::RemovedFromMergeQueue,
            true,
            Some(("notify_state", json!(false))),
            false,
        ),
    ];
    for (name, kind, mine, setting, want) in cases {
        let mut h = H::new();
        if let Some((key, value)) = setting {
            h.set(key, value);
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
        assert_eq!(h.row("E_1").notify, state, "{name}");
    }
}

#[test]
fn bot_comments_on_notify_ignore_activity_off() {
    let mut h = H::new();
    h.set("bot_comments", json!("notify"));
    h.set("notify_activity", json!(false));
    h.set("notify_state", json!(false));
    h.set("notify_reactions", json!(false));
    let e = h.ev("E_1", "PR_1", EventKind::BotComment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    assert_eq!(h.delivered().len(), 1);
}

#[test]
fn state_changes_notify_under_notify_state() {
    let run = |on: bool| {
        let mut h = H::new();
        h.set("notify_state", json!(on));
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
    assert_eq!(out[0].title, "org · Checks failed");
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
            "org · Conflicts",
            None,
        ),
        (
            "changes requested",
            |p| IngestPr {
                review: Review::ChangesRequested,
                changes_requested_by: Some("bob".into()),
                ..p
            },
            "org · Changes requested",
            Some("bob"),
        ),
        (
            "mergeable",
            |p| IngestPr {
                mergeable: true,
                ..p
            },
            "org · Mergeable",
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
fn scope_notifications_off_silences_everything() {
    let mut h = H::new();
    h.set("bot_comments", json!("notify"));
    h.engine.scope_notify(ORG, false).unwrap();
    let a = h.ev("E_1", "PR_1", EventKind::Mentioned);
    let b = h.ev("E_2", "PR_1", EventKind::BotComment);
    h.push(vec![other("PR_1")], vec![a, b], vec![]);
    assert!(h.delivered().is_empty());
    assert!(h.reconnect().is_empty());
    assert_eq!(h.row("E_1").notify, NotifyState::None);
}

#[test]
fn the_single_notification_text() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Mentioned);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    let out = h.delivered();
    let n = &out[0];
    assert_eq!(n.kind, Lenient::Known(NotificationType::Single));
    assert_eq!(n.scope, "org");
    assert_eq!(n.rows, ["E_1"]);
    assert_eq!(n.pr.as_deref(), Some("org/app#1"));
    assert_eq!(n.url.as_deref(), Some("https://github.example/E_1"));
    assert_eq!(n.title, "org · Mentioned");
    assert_eq!(n.subtitle.as_deref(), Some("org/app #1 · Title PR_1"));
    assert_eq!(n.body.as_deref(), Some("text E_1"));
}

#[test]
fn the_row_kind_labels() {
    let cases = [
        (EventKind::ReviewRequested, "Review requested"),
        (EventKind::Mentioned, "Mentioned"),
        (EventKind::Comment, "Comment"),
        (EventKind::Reply, "Reply"),
    ];
    for (kind, label) in cases {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", kind);
        h.push(vec![other("PR_1")], vec![e], vec![]);
        assert_eq!(h.delivered()[0].title, format!("org · {label}"));
    }
    let mut h = H::new();
    h.set("bot_comments", json!("notify"));
    let e = h.ev("E_1", "PR_1", EventKind::BotComment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    assert_eq!(
        h.delivered()[0].title,
        "org · Comment",
        "a bot comment is titled Comment; the row stays bot_comment"
    );
    let e = h.ev("E_2", "PR_2", EventKind::RemovedFromMergeQueue);
    h.push(vec![pr("PR_2")], vec![e], vec![]);
    assert_eq!(h.delivered()[0].title, "org · Removed from merge queue");
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
    assert_eq!(out[0].title, "org · Reaction");
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
    assert_eq!(out[0].title, "org · 3 new events");
    assert_eq!(out[0].body.as_deref(), Some("In 1 PR"));
}

#[test]
fn reactions_follow_their_toggle() {
    let mut h = H::new();
    h.set("notify_reactions", json!(false));
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
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    assert_eq!(h.delivered().len(), 1);
    assert!(h.delivered().is_empty());
    assert!(h.reconnect().is_empty());
}

#[test]
fn undelivered_rows_are_one_summary_per_scope_on_reconnect() {
    let mut h = H::new();
    h.engine.scope_add("second", &h.now).unwrap();
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    let b = h.ev("E_2", "PR_1", EventKind::Reply);
    let c = h.ev("E_3", "PR_2", EventKind::Comment);
    let d = h.ev("E_4", "PR_3", EventKind::Comment);
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
    assert_eq!(out[0].title, "org · 3 new events");
    assert_eq!(out[0].body.as_deref(), Some("In 2 PRs"));
    assert_eq!(out[0].subtitle, None);
    assert_eq!(out[1].title, "second · Comment", "one is individual");
    assert_eq!(out[1].kind, Lenient::Known(NotificationType::Single));
    assert!(h.reconnect().is_empty(), "sent once");
}

#[test]
fn a_failed_write_keeps_rows_for_the_next_reconnect() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    let out = h.engine.take_notifications(true, &h.now);
    assert!(h.engine.pending_summaries(&h.now).is_empty(), "on its way");
    h.engine.delivery_failed(&out[0].rows);
    assert_eq!(h.reconnect().len(), 1);
}

#[test]
fn gating_at_hand_over_clears_the_record_for_good() {
    let steps: &[Toggle] = &[
        (
            "scope notifications",
            |h| h.engine.scope_notify(ORG, false).unwrap(),
            |h| h.engine.scope_notify(ORG, true).unwrap(),
        ),
        (
            "kind toggle",
            |h| h.set("notify_activity", json!(false)),
            |h| h.set("notify_activity", json!(true)),
        ),
        (
            "disabled",
            |h| h.engine.scope_disable(ORG).unwrap(),
            |h| h.engine.scope_enable(ORG, &h.now.clone()).unwrap(),
        ),
    ];
    for (name, off, on) in steps {
        let mut h = H::new();
        let e = h.ev("E_1", "PR_1", EventKind::Comment);
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
fn bot_comment_gate_at_hand_over_is_the_bot_setting() {
    let mut h = H::new();
    h.set("bot_comments", json!("notify"));
    let e = h.ev("E_1", "PR_1", EventKind::BotComment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    h.offline();
    h.set("bot_comments", json!("list_only"));
    assert!(h.reconnect().is_empty());
}

#[test]
fn turning_a_kind_back_on_does_not_notify_rows_made_while_off() {
    let mut h = H::new();
    h.set("notify_activity", json!(false));
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    h.set("notify_activity", json!(true));
    assert!(h.delivered().is_empty());
    assert!(h.reconnect().is_empty());
}

#[test]
fn an_unreadable_pr_loses_its_undelivered_record_at_reconnect() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
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
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.events(vec![e]);
    assert!(h.delivered().is_empty());
    assert!(!h.dot());
    assert_eq!(h.row("E_1").notify, NotifyState::None);
}

#[test]
fn done_rows_stay_out_of_the_reconnect_summary_outside_snooze() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    let b = h.ev("E_2", "PR_2", EventKind::Comment);
    h.push(vec![other("PR_1"), other("PR_2")], vec![a, b], vec![]);
    h.offline();
    h.engine.done("E_1").unwrap();
    let out = h.reconnect();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].rows, ["E_2"]);
    assert_eq!(out[0].title, "org · Comment", "one left: individual");
    assert_eq!(out[0].body.as_deref(), Some("text E_2"));
    assert_eq!(h.row("E_1").notify, NotifyState::None);
}

#[test]
fn only_done_rows_mean_no_summary() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![other("PR_1")], vec![a], vec![]);
    h.offline();
    h.engine.done("E_1").unwrap();
    assert!(h.reconnect().is_empty());
    h.engine.undone("E_1").unwrap();
    assert!(
        h.reconnect().is_empty(),
        "the record is gone at the summary"
    );
}

#[test]
fn undone_before_the_reconnect_keeps_a_row_in_the_summary() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![other("PR_1")], vec![a], vec![]);
    h.offline();
    h.engine.done("E_1").unwrap();
    h.engine.undone("E_1").unwrap();
    assert_eq!(h.reconnect().len(), 1);
}

#[test]
fn a_row_done_after_a_missed_release_stays_out_of_the_summary() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.snooze(&key("PR_1"));
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.events(vec![e]);
    h.advance(DAY);
    h.tick();
    h.offline();
    h.engine.done("E_1").unwrap();
    assert!(h.reconnect().is_empty());
}

/// DESIGN.md, "macOS notifications" and "Notification decisions": the
/// grouping on reconnect is the grouping of any delivery.
#[test]
fn a_single_undelivered_row_comes_back_as_an_individual_notification() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Mentioned);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    h.offline();
    let out = h.reconnect();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].kind, Lenient::Known(NotificationType::Single));
    assert_eq!(out[0].title, "org · Mentioned");
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
        out[0].title, "org · 2 new events",
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
        let mut e = h.ev("E_1", "PR_1", EventKind::Comment);
        e.text = Some(text.into());
        h.push(vec![other("PR_1")], vec![e], vec![]);
        assert_eq!(h.delivered()[0].body.as_deref(), Some(want), "{text:?}");
    }
}
