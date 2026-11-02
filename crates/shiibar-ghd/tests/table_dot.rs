//! Rule table: the blue dot in the menu bar. DESIGN.md, section "How unread
//! disappears".

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use support::*;

type Step = fn(&mut H);

fn comment(h: &mut H) {
    let e = h.ev("E_1", "PR_1", EventKind::Comment);
    h.events(vec![e]);
}

#[test]
fn dot_table() {
    let cases: &[(&str, &[Step], bool)] = &[
        ("nothing happened", &[], false),
        ("a new row", &[comment], true),
        (
            "a new event row",
            &[|h| {
                let e = h.ev("E_1", "PR_1", EventKind::Merged);
                h.events(vec![e]);
            }],
            true,
        ),
        ("opening clears it", &[comment, H::open], false),
        (
            "closing with unread rows left does not bring it back",
            &[comment, H::open, H::close],
            false,
        ),
        (
            "no dot for a new row while open",
            &[H::open, comment],
            false,
        ),
        (
            "still none after closing",
            &[H::open, comment, H::close],
            false,
        ),
        (
            "a new row after closing sets it",
            &[H::open, H::close, comment],
            true,
        ),
        (
            "no dot on a snoozed PR",
            &[|h| h.snooze(&key("PR_1")), comment],
            false,
        ),
        (
            "manual unsnooze with unread sets it",
            &[
                |h| h.snooze(&key("PR_1")),
                comment,
                |h| h.unsnooze(&key("PR_1")),
            ],
            true,
        ),
        (
            "manual unsnooze without unread does not",
            &[|h| h.snooze(&key("PR_1")), |h| h.unsnooze(&key("PR_1"))],
            false,
        ),
        (
            "manual unsnooze while open does not",
            &[
                |h| h.snooze(&key("PR_1")),
                comment,
                H::open,
                |h| h.unsnooze(&key("PR_1")),
            ],
            false,
        ),
        (
            "the morning release with unread sets it",
            &[
                |h| h.snooze(&key("PR_1")),
                comment,
                |h| {
                    h.advance(DAY);
                    h.tick();
                },
            ],
            true,
        ),
        (
            "the morning release while open does not",
            &[
                |h| h.snooze(&key("PR_1")),
                comment,
                H::open,
                |h| {
                    h.advance(DAY);
                    h.tick();
                },
            ],
            false,
        ),
        (
            "the morning release without unread does not",
            &[
                |h| h.snooze(&key("PR_1")),
                |h| {
                    h.advance(DAY);
                    h.tick();
                },
            ],
            false,
        ),
        (
            "hidden bot comments do not",
            &[
                |h| h.set("bot_comments", json!("hide")),
                |h| {
                    let e = h.ev("E_1", "PR_1", EventKind::BotComment);
                    h.events(vec![e]);
                },
            ],
            false,
        ),
    ];
    for (name, steps, want) in cases {
        let mut h = H::new();
        h.prs(vec![pr("PR_1")]);
        for step in *steps {
            step(&mut h);
        }
        assert_eq!(h.dot(), *want, "{name}");
    }
}

#[test]
fn an_app_disconnect_releases_the_open_state_but_keeps_seen_pending() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.open();
    comment(&mut h);
    h.seen(&["E_1"]);
    h.engine.app_disconnected();
    assert!(
        h.row("E_1").seen_pending,
        "kept until the next popover_closed"
    );
    assert!(h.row("E_1").unread);
    let e = h.ev("E_2", "PR_1", EventKind::Comment);
    h.events(vec![e]);
    assert!(h.dot(), "the dot works again after a crash of the app");
    h.close();
    assert!(!h.row("E_1").unread);
}

#[test]
fn the_open_state_is_per_scope() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.engine.popover_opened("public").unwrap();
    comment(&mut h);
    assert!(h.dot());
}
