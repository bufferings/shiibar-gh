//! Rule table: the blue dot in the menu bar. DESIGN.md, sections "How
//! unread rows go away" and "Mute".

mod support;

use shiibar_gh_proto::*;
use support::*;

type Step = fn(&mut H);

fn comment(h: &mut H) {
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
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
                let e = h.ev("E_1", "PR_1", IngestKind::Merged);
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
            "no dot on a dismissed PR",
            &[|h| drop(h.dismiss(&key("PR_1"))), comment],
            false,
        ),
        (
            "Restore with unread sets it",
            &[
                comment,
                H::open,
                H::close,
                |h| drop(h.dismiss(&key("PR_1"))),
                |h| drop(h.restore(&key("PR_1"))),
            ],
            true,
        ),
        (
            "Restore without unread does not",
            &[
                |h| drop(h.dismiss(&key("PR_1"))),
                |h| drop(h.restore(&key("PR_1"))),
            ],
            false,
        ),
        (
            "Restore while open does not",
            &[
                comment,
                |h| drop(h.dismiss(&key("PR_1"))),
                H::open,
                |h| drop(h.restore(&key("PR_1"))),
            ],
            false,
        ),
        (
            "a mention brings a dismissed card back with the dot",
            &[
                |h| drop(h.dismiss(&key("PR_1"))),
                |h| {
                    let e = h.ev("E_9", "PR_1", IngestKind::Mentioned);
                    h.events(vec![e]);
                },
            ],
            true,
        ),
        (
            // DESIGN.md, "Mute": a muted row does not raise the dot.
            "a muted user does not",
            &[|h| h.mute(MuteKind::User, "alice"), comment],
            false,
        ),
        (
            "a muted repository does not",
            &[|h| h.mute(MuteKind::Repo, "Org/App"), comment],
            false,
        ),
        (
            "a mention on a muted PR does",
            &[
                |h| h.mute(MuteKind::Pr, &key("PR_1")),
                |h| {
                    let e = h.ev("E_9", "PR_1", IngestKind::Mentioned);
                    h.events(vec![e]);
                },
            ],
            true,
        ),
        (
            "unmuting with unread muted rows sets it",
            &[
                |h| h.mute(MuteKind::User, "alice"),
                comment,
                |h| h.unmute(MuteKind::User, "ALICE"),
            ],
            true,
        ),
        (
            "unmuting while open does not",
            &[
                |h| h.mute(MuteKind::User, "alice"),
                comment,
                H::open,
                |h| h.unmute(MuteKind::User, "alice"),
            ],
            false,
        ),
        (
            "unmuting without unread does not",
            &[
                |h| h.mute(MuteKind::User, "alice"),
                comment,
                |h| h.read(&["E_1"]),
                |h| h.unmute(MuteKind::User, "alice"),
            ],
            false,
        ),
        (
            "a row whose List is off does not",
            &[
                |h| h.table(EventKind::Comment, EventColumn::List, false),
                comment,
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
fn an_app_disconnect_releases_the_open_state() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.open();
    comment(&mut h);
    h.engine.app_disconnected();
    assert!(
        h.row("E_1").unread,
        "the end of the open state reads nothing"
    );
    let e = h.ev("E_2", "PR_1", IngestKind::Comment);
    h.events(vec![e]);
    assert!(h.dot(), "the dot works again after a crash of the app");
    h.close();
    assert!(h.row("E_1").unread, "closing reads nothing either");
}

#[test]
fn the_open_state_is_per_account() {
    let mut h = H::new();
    h.add_other();
    h.prs(vec![pr("PR_1")]);
    h.engine.popover_opened(YOU).unwrap();
    comment(&mut h);
    assert!(h.dot());
    assert!(!h.account_of(OTHER).unread);
}
