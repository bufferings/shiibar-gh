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
    let cases: [Case; 14] = [
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
            false,
            true,
        ),
        (
            "a team mention from a muted user",
            MuteKind::User,
            "bob",
            "carol",
            IngestKind::TeamMentioned,
            "bob",
            &[],
            false,
            true,
        ),
        (
            "the repository of my own PR: its card stays",
            MuteKind::Repo,
            "org/app",
            ME,
            IngestKind::Comment,
            "bob",
            &[],
            false,
            true,
        ),
        (
            "a muted user's row in my own PR stays muted",
            MuteKind::User,
            "bob",
            ME,
            IngestKind::Comment,
            "bob",
            &[],
            true,
            false,
        ),
        (
            "myself muted: my own PR stays",
            MuteKind::User,
            ME,
            ME,
            IngestKind::Comment,
            "bob",
            &[],
            false,
            true,
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
            "example-bot[bot]",
            "carol",
            IngestKind::Comment,
            "example-bot",
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
    let t = h.ev("E_3", "PR_1", IngestKind::TeamMentioned);
    h.push(vec![other("PR_1")], vec![e, m, t], vec![]);
    h.offline();
    h.mute(MuteKind::Repo, "org/app");
    let out = h.reconnect();
    assert_eq!(out.len(), 1);
    let mut rows = out[0].rows.clone();
    rows.sort();
    assert_eq!(rows, [full("E_2"), full("E_3")], "the mentions still go");
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
    h.engine.mute(ME, MuteKind::User, "Example-Bot").unwrap();
    assert_eq!(
        h.engine.mutes_get(ME).unwrap(),
        Mutes {
            repos: vec!["Org/App".into()],
            users: vec!["Example-Bot".into()],
            prs: vec!["org/app#1".into()],
        }
    );
    assert!(not_found(h.engine.unmute(ME, MuteKind::User, "nobody")));
    h.engine.unmute(ME, MuteKind::Repo, "ORG/APP").unwrap();
    h.engine.unmute(ME, MuteKind::User, "example-bot").unwrap();
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

// ------------------------------------------------------- the decision

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Own {
    None,
    Mute,
    Unmute,
}

/// PR_1 with its own setting, authored by `author`. Unmute is reached the
/// way the menu reaches it: the repository muted for a moment, then
/// `unmute pr`, then the repository back; the final author comes after.
fn with_setting(h: &mut H, own: Own, author: &str) {
    h.prs(vec![other("PR_1")]);
    match own {
        Own::None => {}
        Own::Mute => h.mute(MuteKind::Pr, &key("PR_1")),
        Own::Unmute => {
            h.mute(MuteKind::Repo, "org/app");
            h.unmute(MuteKind::Pr, &key("PR_1"));
            h.unmute(MuteKind::Repo, "org/app");
        }
    }
    h.prs(vec![IngestPr {
        author: author.into(),
        ..other("PR_1")
    }]);
}

#[test]
fn the_mute_decision_of_every_combination() {
    // DESIGN.md, "Mute", the decision; "Wire format", `muted` and
    // `pr_mute`. The bot is a muted user that acts in every PR.
    for own in [Own::None, Own::Mute, Own::Unmute] {
        for repo in [false, true] {
            for author_muted in [false, true] {
                for mine in [false, true] {
                    let name = format!(
                        "own {own:?}, repo {repo}, author muted {author_muted}, mine {mine}"
                    );
                    let author = if mine { ME } else { "alice" };
                    let mut h = H::new();
                    with_setting(&mut h, own, author);
                    h.mute(MuteKind::User, "bot");
                    if repo {
                        h.mute(MuteKind::Repo, "org/app");
                    }
                    if author_muted {
                        h.mute(MuteKind::User, author);
                    }
                    let mut events = Vec::new();
                    for (id, kind, actor) in [
                        ("E_1", IngestKind::Comment, "bot"),
                        ("E_2", IngestKind::Mentioned, "bot"),
                        ("E_3", IngestKind::TeamMentioned, "bot"),
                        ("E_4", IngestKind::Comment, "carol"),
                    ] {
                        let mut e = h.ev(id, "PR_1", kind);
                        e.actor = Some(actor.into());
                        events.push(e);
                    }
                    h.events(events);

                    let mut want: Vec<&str> = Vec::new();
                    if own == Own::Mute {
                        want.push("pr");
                    }
                    if own != Own::Unmute && !mine {
                        if repo {
                            want.push("repo");
                        }
                        if author_muted {
                            want.push("author");
                        }
                    }
                    let card = h.card(&key("PR_1")).unwrap();
                    let got: Vec<String> = card.muted.iter().map(|r| r.as_text()).collect();
                    assert_eq!(got, want, "{name}: muted");
                    let pr_mute = match own {
                        Own::None => "none",
                        Own::Mute => "mute",
                        Own::Unmute => "unmute",
                    };
                    assert_eq!(card.pr_mute.as_text(), pr_mute, "{name}: pr_mute");
                    let card_muted = !want.is_empty();
                    let row =
                        |id: &str| card.rows.iter().find(|r| short(&r.id) == id).unwrap().muted;
                    assert_eq!(
                        row("E_1"),
                        card_muted || own != Own::Unmute,
                        "{name}: a muted user's row"
                    );
                    assert!(!row("E_2"), "{name}: Mentioned passes");
                    assert!(!row("E_3"), "{name}: My team mentioned passes");
                    assert_eq!(row("E_4"), card_muted, "{name}: another row");
                    let mut sent: Vec<String> = h
                        .delivered()
                        .into_iter()
                        .flat_map(|n| n.rows)
                        .map(|r| short(&r))
                        .collect();
                    sent.sort();
                    let mut expected = vec!["E_2".to_string(), "E_3".to_string()];
                    if !(card_muted || own != Own::Unmute) {
                        expected.push("E_1".into());
                    }
                    if !card_muted {
                        expected.push("E_4".into());
                    }
                    expected.sort();
                    assert_eq!(sent, expected, "{name}: notified");
                }
            }
        }
    }
}

fn pr_mute(h: &H) -> String {
    h.card(&key("PR_1")).unwrap().pr_mute.as_text()
}

#[test]
fn unmute_pr_takes_the_pr_out_of_mute() {
    // DESIGN.md, "Wire format", `unmute` of a PR.
    // From Mute to none.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.mute(MuteKind::Pr, &key("PR_1"));
    h.unmute(MuteKind::Pr, &key("PR_1"));
    assert_eq!(pr_mute(&h), "none");
    assert!(h.engine.mutes_get(ME).unwrap().prs.is_empty());
    assert!(h.card(&key("PR_1")).unwrap().muted.is_empty());

    // From Mute, the repository still muting it: Unmute.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.mute(MuteKind::Repo, "org/app");
    h.mute(MuteKind::Pr, &key("PR_1"));
    h.unmute(MuteKind::Pr, &key("PR_1"));
    assert_eq!(pr_mute(&h), "unmute");
    assert!(h.card(&key("PR_1")).unwrap().muted.is_empty());
    assert!(h.engine.mutes_get(ME).unwrap().prs.is_empty(), "not listed");

    // None, the author muted: Unmute; again: no change, `ok`.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.mute(MuteKind::User, "alice");
    h.unmute(MuteKind::Pr, &key("PR_1"));
    assert_eq!(pr_mute(&h), "unmute");
    h.unmute(MuteKind::Pr, &key("PR_1"));
    assert_eq!(pr_mute(&h), "unmute");
    // Later Mutes of the repository and the author leave it alone.
    h.mute(MuteKind::Repo, "org/app");
    assert!(h.card(&key("PR_1")).unwrap().muted.is_empty());
    // `mute pr` makes Unmute Mute.
    h.mute(MuteKind::Pr, &key("PR_1"));
    assert_eq!(pr_mute(&h), "mute");
    assert_eq!(h.engine.mutes_get(ME).unwrap().prs, ["org/app#1"]);
    assert!(!h.engine.pr_record(&full("PR_1")).unwrap().unmuted);
}

#[test]
fn unmute_pr_is_not_found_only_without_anything_to_take_out() {
    let mut h = H::new();
    h.prs(vec![other("PR_1"), pr("PR_2")]);
    assert!(
        not_found(h.engine.unmute(ME, MuteKind::Pr, "org/app#9")),
        "neither listed nor known"
    );
    assert!(
        not_found(h.engine.unmute(ME, MuteKind::Pr, &key("PR_1"))),
        "known, none, not muted otherwise"
    );
    h.mute(MuteKind::Repo, "org/app");
    assert!(
        not_found(h.engine.unmute(ME, MuteKind::Pr, &key("PR_2"))),
        "my own PR: the repository does not mute it"
    );
    assert_eq!(h.card(&key("PR_2")).unwrap().pr_mute.as_text(), "none");
}

#[test]
fn unmute_pr_of_a_name_without_a_record_only_leaves_the_list() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.mute(MuteKind::Pr, &key("PR_1"));
    let org = h.owner_id(ORG);
    h.engine.owner_remove(&org);
    assert!(h.engine.pr_record(&full("PR_1")).is_none());
    assert_eq!(h.engine.mutes_get(ME).unwrap().prs, ["org/app#1"]);
    let mutes = h.engine.unmute(ME, MuteKind::Pr, "ORG/app#1").unwrap();
    assert!(mutes.prs.is_empty());
    assert!(not_found(h.engine.unmute(ME, MuteKind::Pr, "org/app#1")));
}

#[test]
fn unmute_goes_with_the_pr_record() {
    // DESIGN.md, "Mute": Unmute is deleted with the PR record (card).
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.mute(MuteKind::Repo, "org/app");
    h.unmute(MuteKind::Pr, &key("PR_1"));
    assert_eq!(pr_mute(&h), "unmute");
    h.dismiss(&key("PR_1")).unwrap();
    h.set_time(T0 + 8 * DAY);
    h.tick();
    assert!(h.engine.pr_record(&full("PR_1")).is_none(), "the card went");
    // Found again through its Dismiss record: a new record, no Unmute.
    let later = IngestPr {
        updated_at: T0 + 8 * DAY + 10,
        ..other("PR_1")
    };
    let mention = h.ev("M_1", "PR_1", IngestKind::Mentioned);
    h.push(vec![later], vec![mention], vec![]);
    assert_eq!(pr_mute(&h), "none");
    assert_eq!(
        h.card(&key("PR_1")).unwrap().muted,
        [Lenient::Known(MuteReason::Repo)]
    );
}

#[test]
fn unmuting_a_pr_with_unread_muted_rows_raises_the_dot() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.mute(MuteKind::Repo, "org/app");
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.events(vec![e]);
    assert!(!h.dot());
    h.unmute(MuteKind::Pr, &key("PR_1"));
    assert!(h.dot());
}

#[test]
fn unmute_pr_of_my_own_pr_with_setting_none_is_not_found() {
    // A repository or user Mute never mutes the account's own PR, so with
    // its own setting none there is nothing to take out.
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.mute(MuteKind::Repo, "org/app");
    h.mute(MuteKind::User, ME);
    assert!(not_found(h.engine.unmute(ME, MuteKind::Pr, &key("PR_1"))));
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.pr_mute.as_text(), "none");
    assert!(card.muted.is_empty());
}
