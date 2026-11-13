//! Rule table: Mute. DESIGN.md, sections "Mute", "Row looks",
//! "Notification decisions" and "Wire format" (`mute`, `unmute`,
//! `mutes_get`).

mod support;

use shiibar_gh_proto::*;
use support::*;

/// The `muted` of the card of PR_1 and of the row E_1, and whether E_1 was
/// notified.
fn outcome(h: &mut H) -> (Vec<String>, bool, bool) {
    let card = h.card(&key("PR_1")).unwrap();
    let reasons = card.muted.iter().map(|r| r.as_text()).collect();
    let row = card.rows.iter().find(|r| short(&r.id) == "E_1").unwrap();
    let muted = row.muted;
    (reasons, muted, !h.delivered().is_empty())
}

#[test]
fn mute_table() {
    // (name, kind, name, author of PR_1, row kind, actor, card reasons, row
    // muted, notified)
    type Case = (
        &'static str,
        MuteKind,
        &'static str,
        &'static str,
        IngestKind,
        &'static str,
        &'static [&'static str],
        bool,
        bool,
    );
    let cases: [Case; 10] = [
        (
            "the PR",
            MuteKind::Pr,
            "org/app#1",
            "alice",
            IngestKind::Comment,
            "bob",
            &["pr"],
            true,
            false,
        ),
        (
            "the PR in another case",
            MuteKind::Pr,
            "ORG/APP#1",
            "alice",
            IngestKind::Comment,
            "bob",
            &["pr"],
            true,
            false,
        ),
        (
            "the repository",
            MuteKind::Repo,
            "Org/App",
            "alice",
            IngestKind::Comment,
            "bob",
            &["repo"],
            true,
            false,
        ),
        (
            "the author",
            MuteKind::User,
            "ALICE",
            "alice",
            IngestKind::Comment,
            "bob",
            &["author"],
            true,
            false,
        ),
        (
            "an actor on someone else's PR: the row only",
            MuteKind::User,
            "bob",
            "carol",
            IngestKind::Comment,
            "bob",
            &[],
            true,
            false,
        ),
        (
            "a mention from a muted user",
            MuteKind::User,
            "bob",
            "carol",
            IngestKind::Mentioned,
            "bob",
            &[],
            false,
            true,
        ),
        (
            "a mention on a muted PR",
            MuteKind::Pr,
            "org/app#1",
            "alice",
            IngestKind::Mentioned,
            "bob",
            &["pr"],
            false,
            true,
        ),
        (
            "a team mention on a muted PR",
            MuteKind::Repo,
            "org/app",
            "alice",
            IngestKind::TeamMentioned,
            "bob",
            &["repo"],
            true,
            false,
        ),
        (
            "an approval by a muted user",
            MuteKind::User,
            "bob",
            ME,
            IngestKind::Approved,
            "bob",
            &[],
            true,
            false,
        ),
        (
            "a REST bot login does not name the GraphQL login",
            MuteKind::User,
            "renovate[bot]",
            "carol",
            IngestKind::Comment,
            "renovate",
            &[],
            false,
            true,
        ),
    ];
    for (name, kind, who, author, row, actor, reasons, row_muted, notified) in cases {
        let mut h = H::new();
        h.prs(vec![IngestPr {
            author: author.into(),
            ..pr("PR_1")
        }]);
        h.mute(kind, who);
        let mut e = h.ev("E_1", "PR_1", row);
        e.actor = Some(actor.into());
        if row == IngestKind::Approved {
            e.id = "E_1".into();
        }
        h.events(vec![e]);
        if row == IngestKind::Approved {
            let card = h.card(&key("PR_1")).unwrap();
            let r = card
                .rows
                .iter()
                .find(|r| short(&r.id) == "E_1:approved")
                .unwrap();
            assert_eq!(r.muted, row_muted, "{name}: row");
            assert_eq!(!h.delivered().is_empty(), notified, "{name}: notified");
            continue;
        }
        let (got, got_row, got_notified) = outcome(&mut h);
        assert_eq!(got, reasons.to_vec(), "{name}: card");
        assert_eq!(got_row, row_muted, "{name}: row");
        assert_eq!(got_notified, notified, "{name}: notified");
        assert!(h.row("E_1").unread, "{name}: unread is kept");
    }
}

#[test]
fn state_changes_and_reactions_are_not_a_users_rows() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.mute(MuteKind::User, "alice");
    h.prs(vec![IngestPr {
        checks: Checks::Failed,
        ..pr("PR_1")
    }]);
    let r = h.reaction("C_1", "PR_1", &[("HEART", 1)]);
    h.push(vec![], vec![], vec![r]);
    let rows = h.card(&key("PR_1")).unwrap().rows;
    assert_eq!(rows.len(), 2);
    assert!(rows.iter().all(|r| !r.muted), "{rows:?}");
}

#[test]
fn a_mute_at_the_hand_over_clears_the_notification() {
    // DESIGN.md, "Notification decisions": checked again when the
    // notification goes to the app.
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    let m = h.ev("E_2", "PR_1", IngestKind::Mentioned);
    h.push(vec![other("PR_1")], vec![e, m], vec![]);
    h.offline();
    h.mute(MuteKind::Repo, "org/app");
    let out = h.reconnect();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].rows, [full("E_2")], "the mention still goes");
    h.unmute(MuteKind::Repo, "org/app");
    assert!(h.reconnect().is_empty(), "cleared, never sent later");
}

#[test]
fn a_dismiss_at_the_hand_over_clears_the_notification() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Mentioned);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    h.offline();
    h.dismiss(&key("PR_1")).unwrap();
    assert!(h.reconnect().is_empty());
}

#[test]
fn mute_names_are_checked_and_compared_without_case() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    for (kind, bad) in [
        (MuteKind::Repo, "app"),
        (MuteKind::Repo, "a/b/c"),
        (MuteKind::Repo, "/app"),
        (MuteKind::Repo, "org/"),
        (MuteKind::Repo, "org/a pp"),
        (MuteKind::Pr, "org/app"),
        (MuteKind::Pr, "org/app#x"),
        (MuteKind::User, ""),
        (MuteKind::User, "a b"),
        (MuteKind::User, "org/app"),
    ] {
        assert!(invalid(h.engine.mute(ME, kind, bad)), "{bad}");
    }
    assert!(not_found(h.engine.mute(ME, MuteKind::Pr, "org/app#2")));
    assert!(not_found(h.engine.mute("nobody", MuteKind::User, "x")));
    let mutes = h.engine.mute(ME, MuteKind::Repo, "Org/App").unwrap();
    assert_eq!(mutes.repos, ["Org/App"]);
    let again = h.engine.mute(ME, MuteKind::Repo, "org/app").unwrap();
    assert_eq!(again.repos, ["Org/App"], "already there: no change");
    h.engine.mute(ME, MuteKind::Pr, "ORG/app#1").unwrap();
    h.engine.mute(ME, MuteKind::User, "Renovate").unwrap();
    assert_eq!(
        h.engine.mutes_get(ME).unwrap(),
        Mutes {
            repos: vec!["Org/App".into()],
            users: vec!["Renovate".into()],
            prs: vec!["org/app#1".into()],
        }
    );
    assert!(not_found(h.engine.unmute(ME, MuteKind::User, "nobody")));
    h.engine.unmute(ME, MuteKind::Repo, "ORG/APP").unwrap();
    h.engine.unmute(ME, MuteKind::User, "renovate").unwrap();
    assert_eq!(h.engine.mutes_get(ME).unwrap().prs, ["org/app#1"]);
}

#[test]
fn mutes_are_per_account() {
    let mut h = H::new();
    h.add_other();
    h.prs(vec![other("PR_1")]);
    h.push_to(OTHER, vec![other("PR_1")], vec![], vec![])
        .unwrap();
    h.mute(MuteKind::User, "alice");
    let theirs = h.engine.status(YOU, &key("PR_1"), &h.now).unwrap().muted;
    assert!(theirs.is_empty());
    assert!(h.engine.mutes_get(YOU).unwrap().users.is_empty());
}

#[test]
fn a_muted_card_still_gets_its_return_triggers() {
    // DESIGN.md, "Mute": Dismiss is unrelated.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.mute(MuteKind::User, "alice");
    h.dismiss(&key("PR_1")).unwrap();
    let e = h.ev("E_1", "PR_1", IngestKind::ReviewRequested);
    h.events(vec![e]);
    assert!(!h.dismissed("PR_1"));
    assert!(h.row("E_1").unread, "a gray unread mark");
    assert!(!h.dot(), "a muted row raises no dot");
}
