//! Rule table: Snooze release and its summary notification. DESIGN.md,
//! sections "Snooze" and "Notification decisions", and the brief's "Snooze
//! release".

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use shiibar_ghd::clock::Now;
use shiibar_ghd::model::NotifyState;
use support::*;

type Gate = (&'static str, fn(&mut H));

/// 09:00 in Asia/Tokyo on the day after `T0` (17:00 local).
const NEXT_0900: i64 = T0 + 16 * HOUR;

#[test]
fn t0_is_late_afternoon_in_tokyo() {
    let now = Now::fixed(NEXT_0900, "Asia/Tokyo").unwrap();
    assert_eq!(now.latest_return_at((9, 0)), NEXT_0900);
}

#[test]
fn release_time_table() {
    // (name, tick at, released)
    let cases = [
        ("before the Return time", NEXT_0900 - 1, false),
        ("at the Return time", NEXT_0900, true),
        ("after the Return time", NEXT_0900 + 1, true),
        ("waking up days later", NEXT_0900 + 3 * DAY, true),
    ];
    for (name, at, released) in cases {
        let mut h = H::new();
        h.prs(vec![pr("PR_1")]);
        h.snooze(&key("PR_1"));
        h.set_time(at);
        h.tick();
        assert_eq!(h.engine.pr_snoozed("PR_1"), !released, "{name}");
    }
}

#[test]
fn return_time_uses_the_current_time_zone() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.snooze(&key("PR_1"));
    // 09:00 in Los Angeles is hours after 09:00 in Tokyo.
    h.now = Now::fixed(NEXT_0900, "America/Los_Angeles").unwrap();
    h.now.at = T0 + HOUR;
    h.tick();
    assert!(
        h.engine.pr_snoozed("PR_1"),
        "01:00 in LA is before 09:00, and 09:00 yesterday is earlier than the last release"
    );
    h.now.at = T0 + 10 * HOUR;
    h.tick();
    assert!(!h.engine.pr_snoozed("PR_1"), "past 09:00 in LA");
}

#[test]
fn all_snoozes_go_at_once_and_only_once() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), pr("PR_2")]);
    h.snooze(&key("PR_1"));
    h.snooze(&key("PR_2"));
    h.set_time(NEXT_0900);
    h.tick();
    assert!(!h.engine.pr_snoozed("PR_1") && !h.engine.pr_snoozed("PR_2"));
    assert_eq!(h.engine.last_release_at(), NEXT_0900);
    h.snooze(&key("PR_1"));
    h.advance(60);
    h.tick();
    assert!(
        h.engine.pr_snoozed("PR_1"),
        "snoozed after the release stays"
    );
}

#[test]
fn snooze_runs_a_due_release_first() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), pr("PR_2")]);
    h.snooze(&key("PR_1"));
    h.set_time(NEXT_0900 + 5);
    // No periodic pass ran yet. PR_2 must survive the next one.
    h.snooze(&key("PR_2"));
    assert!(!h.engine.pr_snoozed("PR_1"), "the due release ran");
    assert!(h.engine.pr_snoozed("PR_2"));
    h.advance(30);
    h.tick();
    assert!(h.engine.pr_snoozed("PR_2"));
}

#[test]
fn changing_the_return_time_releases_first_and_restarts_from_now() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), pr("PR_2")]);
    h.snooze(&key("PR_1"));
    h.set_time(NEXT_0900 + 5);
    h.set("snooze_return_time", json!("08:00"));
    assert!(
        !h.engine.pr_snoozed("PR_1"),
        "the old Return time still applied"
    );
    assert_eq!(h.engine.last_release_at(), NEXT_0900 + 5);

    // Moving it to a time earlier today must not fire by itself.
    h.snooze(&key("PR_2"));
    h.set("snooze_return_time", json!("07:00"));
    h.advance(60);
    h.tick();
    assert!(h.engine.pr_snoozed("PR_2"));
}

#[test]
fn snoozed_until_is_the_next_return_time_for_every_snoozed_pr() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    assert_eq!(h.card(&key("PR_1")).unwrap().snoozed_until, None);
    h.snooze(&key("PR_1"));
    let card = h.card(&key("PR_1")).unwrap();
    assert!(card.snoozed);
    assert_eq!(card.snoozed_until, Some(NEXT_0900));
    h.set("snooze_return_time", json!("10:30"));
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.snoozed_until, Some(NEXT_0900 + 90 * 60));
}

#[test]
fn a_released_pr_returns_to_its_position() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.prs(vec![pr("PR_2")]);
    let before = h.card_ids(&Filter::default());
    h.snooze(&key("PR_1"));
    h.set_time(NEXT_0900);
    h.tick();
    assert_eq!(h.card_ids(&Filter::default()), before);
}

#[test]
fn a_new_needs_action_row_does_not_bring_a_snoozed_pr_back() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.snooze(&key("PR_1"));
    let e = h.ev("E_1", "PR_1", EventKind::Mentioned);
    h.events(vec![e]);
    assert!(h.engine.pr_snoozed("PR_1"));
    assert!(!h.visible("PR_1"));
    assert_eq!(h.badge(), 0);
}

#[test]
fn snooze_needs_a_card_without_the_snooze_rule() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        is_draft: true,
        ..other("PR_1")
    }]);
    assert!(not_found(h.engine.snooze(&key("PR_1"), &h.now)));
    assert!(not_found(h.engine.snooze("nobody/none#1", &h.now)));
    assert!(not_found(h.engine.unsnooze("nobody/none#1", &h.now)));
}

struct SummaryCase {
    name: &'static str,
    /// Rows made while snoozed.
    rows: &'static [EventKind],
    done: &'static [usize],
    want_rows: usize,
}

#[test]
fn summary_table() {
    let cases = [
        SummaryCase {
            name: "one comment",
            rows: &[EventKind::Comment],
            done: &[],
            want_rows: 1,
        },
        SummaryCase {
            name: "two rows",
            rows: &[EventKind::Comment, EventKind::Mentioned],
            done: &[],
            want_rows: 2,
        },
        SummaryCase {
            name: "nothing notifiable",
            rows: &[EventKind::AddedToMergeQueue, EventKind::Merged],
            done: &[],
            want_rows: 0,
        },
        SummaryCase {
            name: "a row done before the release goes",
            rows: &[EventKind::Comment, EventKind::Reply],
            done: &[0],
            want_rows: 1,
        },
        SummaryCase {
            name: "all done",
            rows: &[EventKind::Comment],
            done: &[0],
            want_rows: 0,
        },
        SummaryCase {
            name: "nothing happened",
            rows: &[],
            done: &[],
            want_rows: 0,
        },
    ];
    for c in cases {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.snooze(&key("PR_1"));
        for (i, kind) in c.rows.iter().enumerate() {
            let e = h.ev(&format!("E_{i}"), "PR_1", *kind);
            h.events(vec![e]);
        }
        assert!(
            h.delivered().is_empty(),
            "{}: no notification while snoozed",
            c.name
        );
        for i in c.done {
            h.engine.done(&format!("E_{i}")).unwrap();
        }
        h.set_time(NEXT_0900);
        h.tick();
        let out = h.delivered();
        if c.want_rows == 0 {
            assert!(out.is_empty(), "{}", c.name);
            continue;
        }
        assert_eq!(out.len(), 1, "{}", c.name);
        assert_eq!(out[0].rows.len(), c.want_rows, "{}", c.name);
        assert_eq!(out[0].kind, Lenient::Known(NotificationType::Summary));
        assert_eq!(out[0].title, "org · Back from Snooze");
        assert_eq!(out[0].body.as_deref(), Some("1 PR had new events"));
        assert_eq!(out[0].subtitle, None);
        assert_eq!(out[0].pr, None);
        assert_eq!(out[0].url, None);
    }
}

#[test]
fn undone_before_the_release_puts_a_row_back() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.snooze(&key("PR_1"));
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.events(vec![e]);
    h.engine.done("E_1").unwrap();
    h.engine.undone("E_1").unwrap();
    h.set_time(NEXT_0900);
    h.tick();
    assert_eq!(h.delivered().len(), 1);
}

#[test]
fn the_summary_counts_prs_and_is_one_per_scope() {
    let mut h = H::new();
    h.engine.scope_add("second", &h.now).unwrap();
    let second = IngestPr {
        owner: "second".into(),
        ..other("PR_3")
    };
    h.prs(vec![other("PR_1"), other("PR_2"), second]);
    h.snooze(&key("PR_1"));
    h.snooze(&key("PR_2"));
    h.snooze("second/app#3");
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    let b = h.ev("E_2", "PR_1", EventKind::Comment);
    let c = h.ev("E_3", "PR_2", EventKind::Comment);
    let d = h.ev("E_4", "PR_3", EventKind::Comment);
    h.events(vec![a, b, c, d]);
    h.set_time(NEXT_0900);
    h.tick();
    let out = h.delivered();
    assert_eq!(out.len(), 2);
    assert_eq!(out[0].scope, "org");
    assert_eq!(out[0].body.as_deref(), Some("2 PRs had new events"));
    assert_eq!(out[0].rows.len(), 3);
    assert_eq!(out[1].scope, "second");
    assert_eq!(out[1].body.as_deref(), Some("1 PR had new events"));
}

#[test]
fn manual_unsnooze_stays_silent_and_clears_the_record() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.snooze(&key("PR_1"));
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.events(vec![e]);
    assert_eq!(h.row("E_1").notify, NotifyState::Held);
    h.unsnooze(&key("PR_1"));
    assert_eq!(h.row("E_1").notify, NotifyState::None);
    assert!(h.delivered().is_empty());
    assert!(h.reconnect().is_empty());
}

#[test]
fn the_summary_is_gated_again_when_handed_over() {
    let steps: &[Gate] = &[
        ("scope notifications off", |h| {
            h.engine.scope_notify(ORG, false).unwrap()
        }),
        ("activity notifications off", |h| {
            h.set("notify_activity", json!(false))
        }),
        ("scope disabled", |h| h.engine.scope_disable(ORG).unwrap()),
    ];
    for (name, step) in steps {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.snooze(&key("PR_1"));
        let e = h.ev("E_1", "PR_1", EventKind::Comment);
        h.events(vec![e]);
        step(&mut h);
        h.set_time(NEXT_0900);
        h.tick();
        assert!(h.delivered().is_empty(), "{name}");
        assert_eq!(h.row("E_1").notify, NotifyState::None, "{name}");
    }
}

#[test]
fn a_summary_the_app_did_not_get_joins_the_next_new_events_summary() {
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    h.snooze(&key("PR_1"));
    let a = h.ev("E_1", "PR_1", EventKind::Comment);
    let b = h.ev("E_2", "PR_1", EventKind::Reply);
    h.events(vec![a, b]);
    h.set_time(NEXT_0900);
    h.tick();
    h.offline();
    let c = h.ev("E_3", "PR_2", EventKind::Comment);
    h.events(vec![c]);
    h.offline();
    let out = h.reconnect();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].title, "org · 3 new events");
    assert_eq!(out[0].body.as_deref(), Some("In 2 PRs"));
}

#[test]
fn snoozing_a_pr_with_undelivered_rows_moves_them_to_the_release() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.events(vec![e]);
    h.offline();
    h.snooze(&key("PR_1"));
    assert!(h.reconnect().is_empty(), "no notification for a snoozed PR");
    h.set_time(NEXT_0900);
    h.tick();
    let out = h.delivered();
    assert_eq!(out[0].title, "org · Back from Snooze");
}

#[test]
fn undelivered_rows_from_before_the_snooze_survive_a_manual_unsnooze() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let before = h.ev("BEFORE", "PR_1", EventKind::Comment);
    h.events(vec![before]);
    h.offline();
    h.snooze(&key("PR_1"));
    assert_eq!(h.row("BEFORE").notify, NotifyState::HeldUndelivered);
    let during = h.ev("DURING", "PR_1", EventKind::Comment);
    h.events(vec![during]);
    assert_eq!(h.row("DURING").notify, NotifyState::Held);
    assert!(h.reconnect().is_empty(), "both wait during the Snooze");

    h.unsnooze(&key("PR_1"));
    assert_eq!(h.row("BEFORE").notify, NotifyState::Pending);
    assert_eq!(h.row("DURING").notify, NotifyState::None);
    let out = h.reconnect();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].rows, ["BEFORE"]);
    assert_eq!(out[0].title, "org · 1 new event");
}

#[test]
fn undelivered_rows_from_before_the_snooze_join_the_return_time_summary() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let before = h.ev("BEFORE", "PR_1", EventKind::Comment);
    h.events(vec![before]);
    h.offline();
    h.snooze(&key("PR_1"));
    let during = h.ev("DURING", "PR_1", EventKind::Comment);
    h.events(vec![during]);
    h.set_time(NEXT_0900);
    h.tick();
    let out = h.delivered();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].title, "org · Back from Snooze");
    assert_eq!(out[0].rows.len(), 2);
}

#[test]
fn a_row_from_before_the_snooze_marked_done_leaves_the_return_time_summary() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let before = h.ev("BEFORE", "PR_1", EventKind::Comment);
    h.events(vec![before]);
    h.offline();
    h.snooze(&key("PR_1"));
    h.engine.done("BEFORE").unwrap();
    h.set_time(NEXT_0900);
    h.tick();
    assert!(h.delivered().is_empty());
    assert_eq!(h.row("BEFORE").notify, NotifyState::None);
}

#[test]
fn an_undelivered_row_found_on_a_snoozed_pr_at_reconnect_is_also_kept() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    let out = h.engine.take_notifications(true, &h.now);
    h.snooze(&key("PR_1"));
    h.engine.delivery_failed(&out[0].rows);
    assert!(h.reconnect().is_empty());
    assert_eq!(h.row("E_1").notify, NotifyState::HeldUndelivered);
    h.unsnooze(&key("PR_1"));
    assert_eq!(h.reconnect().len(), 1);
}

#[test]
fn an_unreadable_pr_gets_no_dot_at_release_and_loses_its_summary_record() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.snooze(&key("PR_1"));
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.events(vec![e]);
    h.missing("PR_1");
    h.set_time(NEXT_0900);
    h.tick();
    assert!(!h.dot());
    assert!(h.delivered().is_empty());
    assert_eq!(h.row("E_1").notify, NotifyState::None);
    assert!(h.row("E_1").unread, "state is kept");
    h.prs(vec![other("PR_1")]);
    assert!(h.reconnect().is_empty(), "cleared for good");
    assert!(h.visible("PR_1"));
}

fn zone(tz: &str, at: i64) -> Now {
    Now::fixed(at, tz).unwrap()
}

#[test]
fn a_clock_moved_back_does_not_release_a_return_time_already_covered() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    // The release of NEXT_0900 happened at this later moment.
    let released_at = NEXT_0900 + HOUR;
    h.set_time(released_at);
    h.tick();
    assert_eq!(h.engine.last_release_at(), released_at);

    h.set_time(NEXT_0900 - 3 * HOUR);
    h.snooze(&key("PR_1"));
    h.set_time(NEXT_0900 + 10);
    h.tick();
    assert!(
        h.engine.pr_snoozed("PR_1"),
        "NEXT_0900 is at or before the record"
    );
    h.set_time(released_at);
    h.tick();
    assert!(h.engine.pr_snoozed("PR_1"), "the record itself");

    h.set_time(NEXT_0900 + DAY);
    h.tick();
    assert!(!h.engine.pr_snoozed("PR_1"), "the next new Return time");
}

#[test]
fn a_return_time_exactly_at_the_record_does_not_release_again() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.set_time(NEXT_0900);
    h.tick();
    assert_eq!(h.engine.last_release_at(), NEXT_0900);
    h.snooze(&key("PR_1"));
    h.tick();
    assert!(h.engine.pr_snoozed("PR_1"));
}

#[test]
fn time_zone_move_table() {
    // (zone, seconds from T0 to its next 09:00)
    let cases = [
        ("Europe/London", HOUR),
        ("America/New_York", 6 * HOUR),
        ("America/Los_Angeles", 9 * HOUR),
        ("Asia/Kolkata", 19 * HOUR + 1800),
        ("Pacific/Auckland", 12 * HOUR),
        ("Pacific/Honolulu", 11 * HOUR),
        ("Asia/Tokyo", 16 * HOUR),
    ];
    for (tz, offset) in cases {
        let mut h = H::new();
        h.prs(vec![pr("PR_1")]);
        h.snooze(&key("PR_1"));
        h.now = zone(tz, T0 + 10);
        let card = h.card(&key("PR_1")).unwrap();
        assert_eq!(card.snoozed_until, Some(T0 + offset), "{tz}: snoozed_until");

        h.now.at = T0 + offset - 1;
        h.tick();
        assert!(h.engine.pr_snoozed("PR_1"), "{tz}: before");
        h.now.at = T0 + offset;
        h.tick();
        assert!(!h.engine.pr_snoozed("PR_1"), "{tz}: at the Return time");
    }
}

#[test]
fn moving_west_after_a_release_gives_a_new_return_time_today() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.set_time(NEXT_0900);
    h.tick();
    h.snooze(&key("PR_1"));
    // 09:00 in London is nine hours after 09:00 in Tokyo.
    h.now = zone("Europe/London", NEXT_0900 + 8 * HOUR);
    assert_eq!(
        h.card(&key("PR_1")).unwrap().snoozed_until,
        Some(NEXT_0900 + 9 * HOUR)
    );
    h.tick();
    assert!(h.engine.pr_snoozed("PR_1"));
    h.now.at = NEXT_0900 + 9 * HOUR;
    h.tick();
    assert!(!h.engine.pr_snoozed("PR_1"));
}

#[test]
fn moving_east_after_a_release_does_not_repeat_it() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.now = zone("Europe/London", NEXT_0900 + 9 * HOUR);
    h.tick();
    h.snooze(&key("PR_1"));
    // Tokyo's latest 09:00 is older than the release just made.
    h.now = zone("Asia/Tokyo", NEXT_0900 + 10 * HOUR);
    h.tick();
    assert!(h.engine.pr_snoozed("PR_1"));
    assert_eq!(
        h.card(&key("PR_1")).unwrap().snoozed_until,
        Some(NEXT_0900 + DAY)
    );
}

/// New York repeats 01:00-02:00 on 2027-11-07: first at -0400, then at -0500.
#[test]
fn a_return_time_inside_a_fold_fires_once_at_its_first_occurrence() {
    let parse = |text| {
        jiff::Timestamp::strptime("%Y-%m-%d %H:%M %z", text)
            .unwrap()
            .as_second()
    };
    let first = parse("2027-11-07 01:30 -0400");
    let second = parse("2027-11-07 01:30 -0500");
    assert_eq!(second, first + HOUR);
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.now = zone("America/New_York", first - HOUR);
    h.set("snooze_return_time", json!("01:30"));
    h.snooze(&key("PR_1"));
    assert_eq!(h.card(&key("PR_1")).unwrap().snoozed_until, Some(first));
    h.now.at = first - 1;
    h.tick();
    assert!(h.engine.pr_snoozed("PR_1"));
    h.now.at = first;
    h.tick();
    assert!(!h.engine.pr_snoozed("PR_1"));

    h.snooze(&key("PR_1"));
    h.now.at = second;
    h.tick();
    assert!(
        h.engine.pr_snoozed("PR_1"),
        "the repeated hour is not a new Return time"
    );
    assert_eq!(
        h.card(&key("PR_1")).unwrap().snoozed_until,
        Some(second + DAY)
    );
}
