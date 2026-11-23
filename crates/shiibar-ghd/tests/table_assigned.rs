//! Rule table: the Assigned row in the core. DESIGN.md: "Row kinds and
//! states"; "Rows of the account's own events"; "Events before the watch
//! started"; "Review"; "Dismiss" ("Return triggers"); "Notification
//! decisions". Which assignments become an Assigned event is the converter's
//! part (`table_convert.rs`); here the events arrive as the fetcher hands
//! them over.

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::model::NotifyState;
use support::*;

fn merged(pr: IngestPr) -> IngestPr {
    IngestPr {
        state: PrState::Merged,
        ..pr
    }
}

/// An Assigned event of PR_1 at the current time by `actor`, as the
/// converter hands it over: the PR page as its target and no text.
fn assigned(h: &H, id: &str, actor: Option<&str>) -> IngestEvent {
    IngestEvent {
        url: "https://github.example/PR_1".into(),
        actor: actor.map(str::to_string),
        actor_avatar_url: actor.map(|a| format!("https://avatars.example/{a}")),
        text: None,
        ..h.ev(id, "PR_1", IngestKind::Assigned)
    }
}

#[test]
fn who_assigned_decides_read_and_notification() {
    // (name, actor, want unread and notified)
    let cases = [
        ("someone else", Some("alice"), true),
        ("me", Some(ME), false),
        ("me, spelled in another case", Some("ME"), false),
        ("a bot", Some("example-bot"), true),
        // DESIGN.md, "Rows of the account's own events": without an actor
        // the row is not the account's own action.
        ("no actor", None, true),
    ];
    for (name, actor, want) in cases {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.close();
        let e = assigned(&h, "A_1", actor);
        h.events(vec![e]);
        let row = h.wire_row("A_1").expect(name);
        assert_eq!(row.kind.as_text(), "assigned", "{name}");
        assert_eq!(row.unread, want, "{name}: unread");
        assert_eq!(row.actor.as_deref(), actor, "{name}: actor");
        assert_eq!(row.text, None, "{name}: no text");
        assert_eq!(row.url, "https://github.example/PR_1", "{name}: PR page");
        assert_eq!(h.dot(), want, "{name}: dot");
        let out = h.delivered();
        assert_eq!(out.len(), usize::from(want), "{name}: notified");
        if want {
            assert_eq!(out[0].title, "me · Assigned", "{name}");
        }
    }
}

#[test]
fn the_notification_follows_the_table_the_owner_draft_and_mute() {
    type Setup = fn(&mut H);
    // (name, setup, PR is a draft, want notified, want a blue row)
    let cases: [(&str, Setup, bool, bool, bool); 8] = [
        ("defaults", |_| {}, false, true, true),
        (
            "the kind's Notify off",
            |h| h.table(EventKind::Assigned, EventColumn::Notify, false),
            false,
            false,
            true,
        ),
        (
            "another kind's Notify off",
            |h| h.table(EventKind::ReviewRequested, EventColumn::Notify, false),
            false,
            true,
            true,
        ),
        (
            "the owner's Notify off",
            |h| {
                let owner = h.owner_id(ORG);
                h.engine.owner_notify(&owner, false);
            },
            false,
            false,
            true,
        ),
        // Skip draft pull requests is on by default (DESIGN.md, "Owners").
        ("a draft", |_| {}, true, false, true),
        (
            "a draft, Skip draft pull requests off",
            |h| {
                let owner = h.owner_id(ORG);
                h.engine.owner_skip_drafts(&owner, false);
            },
            true,
            true,
            true,
        ),
        (
            "the one who assigned muted",
            |h| h.mute(MuteKind::User, "alice"),
            false,
            false,
            false,
        ),
        (
            "the repository muted",
            |h| h.mute(MuteKind::Repo, "org/app"),
            false,
            false,
            false,
        ),
    ];
    for (name, setup, draft, notified, blue) in cases {
        let mut h = H::new();
        setup(&mut h);
        h.prs(vec![IngestPr {
            is_draft: draft,
            ..other("PR_1")
        }]);
        h.close();
        let e = assigned(&h, "A_1", Some("alice"));
        h.events(vec![e]);
        assert!(h.row("A_1").unread, "{name}: unread");
        assert_eq!(h.dot(), blue, "{name}: dot");
        let state = if notified {
            NotifyState::Delivered
        } else {
            NotifyState::None
        };
        assert_eq!(h.delivered().len(), usize::from(notified), "{name}");
        assert_eq!(h.row("A_1").notify, state, "{name}");
    }
}

#[test]
fn an_assignment_with_the_list_off_is_recorded_read() {
    // DESIGN.md, "Applying the table".
    let mut h = H::new();
    h.table(EventKind::Assigned, EventColumn::List, false);
    h.prs(vec![other("PR_1")]);
    let e = assigned(&h, "A_1", Some("alice"));
    h.events(vec![e]);
    assert!(h.wire_row("A_1").is_none(), "not shown");
    assert!(!h.row("A_1").unread);
    assert!(h.delivered().is_empty());
}

#[test]
fn an_assigned_row_places_nothing() {
    // DESIGN.md, "Review": Assigned rows do not place the PR.
    let mut h = H::new();
    h.prs(vec![IngestPr {
        assignees: vec![ME.into()],
        ..other("PR_1")
    }]);
    assert_eq!(h.placement("PR_1"), None);
    let e = assigned(&h, "A_1", Some("alice"));
    h.events(vec![e]);
    assert!(h.has_row("A_1"));
    assert_eq!(h.placement("PR_1"), None, "still unplaced");
    let mine = assigned(&h, "A_2", Some(ME));
    h.events(vec![mine]);
    assert_eq!(h.placement("PR_1"), None, "still unplaced");
    // A placed card stays where it is.
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Waiting),
        None,
        None,
    )
    .unwrap();
    let again = assigned(&h, "A_3", Some("bob"));
    h.events(vec![again]);
    assert_eq!(
        h.placement("PR_1").map(|p| (p.0, p.1)),
        Some(("review".into(), "waiting".into()))
    );
}

#[test]
fn an_assignment_before_the_watch_started_makes_no_row() {
    // DESIGN.md, "Events before the watch started": the exception of the
    // review requests still open is not for assignments, even when the
    // account is still assigned.
    let mut h = H::new();
    let old = h.ev_at("A_1", "PR_1", IngestKind::Assigned, T0 - DAY);
    h.push(
        vec![IngestPr {
            assignees: vec![ME.into()],
            ..other("PR_1")
        }],
        vec![old],
        vec![],
    );
    assert!(!h.has_row("A_1"), "first fetch of a new PR");
    // The watch restarts: still none for an assignment before it.
    let owner = h.owner_id(ORG);
    h.engine.owner_enable(&owner, false, &h.now.clone());
    h.advance(100);
    h.engine.owner_enable(&owner, true, &h.now.clone());
    let before = h.ev_at("A_2", "PR_1", IngestKind::Assigned, h.at() - 1);
    h.push(
        vec![IngestPr {
            assignees: vec![ME.into()],
            ..other("PR_1")
        }],
        vec![before],
        vec![],
    );
    assert!(!h.has_row("A_2"), "first fetch after the restart");
    assert!(h.delivered().is_empty());
}

#[test]
fn the_same_assignment_makes_one_row_and_a_new_one_another() {
    // DESIGN.md, "Row kinds and states": one row per event id; assigning
    // again after an unassignment is a new AssignedEvent.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let first = assigned(&h, "A_1", Some("alice"));
    h.events(vec![first.clone()]);
    h.events(vec![first]);
    let rows = h.card(&key("PR_1")).unwrap().rows;
    assert_eq!(ids(&rows), ["A_1"]);
    h.dismiss(&key("PR_1")).unwrap();
    let second = assigned(&h, "A_2", Some("alice"));
    h.events(vec![second]);
    assert!(!h.dismissed("PR_1"), "back again");
    let rows = h.card(&key("PR_1")).unwrap().rows;
    assert_eq!(ids(&rows), ["A_2", "A_1"]);
}

#[test]
fn a_closed_card_back_through_an_assignment_counts_n_days() {
    // DESIGN.md, "Dismiss": like a review request or Reopened, an Assigned
    // row that brings back a closed card leaves the automatic Dismiss on.
    for actor in ["alice", ME] {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.prs(vec![merged(other("PR_1"))]);
        h.dismiss(&key("PR_1")).unwrap();
        h.set_time(T0 + 5 * DAY);
        let back_at = h.at();
        let e = assigned(&h, "A_1", Some(actor));
        h.events(vec![e]);
        assert!(!h.dismissed("PR_1"), "{actor}: back");
        assert_eq!(
            h.card_by_id("PR_1").unwrap().auto_dismiss_at,
            Some(back_at + 3 * DAY),
            "{actor}"
        );
        h.set_time(back_at + 3 * DAY);
        h.tick();
        assert!(h.dismissed("PR_1"), "{actor}: dismissed after n days");
    }
}

#[test]
fn a_muted_card_comes_back_through_an_assignment_with_a_gray_row() {
    // DESIGN.md, "Mute": Dismiss is unrelated; the row is muted, whatever
    // mutes the card: the PR itself, its author or its repository.
    // (name, what is muted)
    let cases = [
        ("the PR", MuteKind::Pr, "org/app#1"),
        ("its author", MuteKind::User, "alice"),
        ("its repository", MuteKind::Repo, "org/app"),
    ];
    for (name, kind, target) in cases {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.mute(kind, target);
        h.dismiss(&key("PR_1")).unwrap();
        h.close();
        let e = assigned(&h, "A_1", Some("bob"));
        h.events(vec![e]);
        assert!(!h.dismissed("PR_1"), "{name}: back");
        let row = h.wire_row("A_1").unwrap();
        assert!(row.unread, "{name}: a gray unread mark");
        assert!(row.muted, "{name}: muted");
        assert!(!h.dot(), "{name}: a muted row raises no dot");
        assert!(h.delivered().is_empty(), "{name}: not notified");
        assert_eq!(h.row("A_1").notify, NotifyState::None, "{name}");
    }
}

#[test]
fn an_open_pr_with_only_a_dismiss_record_comes_back_through_an_assignment() {
    // DESIGN.md, "Dismiss record": past m days the card leaves the
    // Dismissed list and only a record stays; an Assigned row, a return
    // trigger, shows it again, unread and notified.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.dismiss(&key("PR_1")).unwrap();
    h.set_time(T0 + 8 * DAY);
    h.tick();
    assert!(
        h.engine.pr_record(&full("PR_1")).is_none(),
        "the card is gone"
    );
    assert!(h.engine.record(&full("PR_1")).is_some(), "a record stays");
    h.close();
    let later = IngestPr {
        updated_at: T0 + 8 * DAY + 10,
        ..other("PR_1")
    };
    let e = assigned(&h, "A_1", Some("bob"));
    h.push(vec![later], vec![e], vec![]);
    assert!(h.visible("PR_1"), "back");
    assert!(h.engine.record(&full("PR_1")).is_none(), "the record ends");
    assert!(h.wire_row("A_1").unwrap().unread);
    assert!(h.dot());
    let out = h.delivered();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].title, "me · Assigned");
}
