//! Rule table: Dismiss, Restore, the automatic Dismiss, the end of the
//! Dismissed list, the return triggers and the Dismiss record. DESIGN.md,
//! sections "Dismiss", "Dismiss record", "Dismissed list", "Card states" and
//! "API usage" (the items below the table).

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use support::*;

fn merged(pr: IngestPr) -> IngestPr {
    IngestPr {
        state: PrState::Merged,
        ..pr
    }
}

fn hit(id: &str, updated_at: i64, open: bool) -> SearchHit {
    SearchHit {
        id: id.into(),
        updated_at,
        open,
        events_fetched: true,
    }
}

fn search(h: &mut H, hits: Vec<SearchHit>) {
    let ingest = Ingest {
        search: hits,
        ..Ingest::default()
    };
    h.engine.ingest(ACCOUNT, ingest, &h.now.clone()).unwrap();
    h.advance(1);
}

// --------------------------------------------------------- Dismiss, Restore

#[test]
fn dismiss_and_restore() {
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    let card = h.dismiss(&key("PR_1")).unwrap();
    let at = card.dismissed_at.unwrap();
    assert_eq!(card.dismiss_expires_at, Some(at + 7 * DAY));
    assert!(!h.visible("PR_1"));
    assert!(invalid(h.dismiss(&key("PR_1"))), "already dismissed");
    assert!(invalid(h.restore(&key("PR_2"))), "not dismissed");
    assert!(not_found(h.dismiss("org/app#99")));
    h.advance(10);
    h.dismiss(&key("PR_2")).unwrap();
    let list: Vec<String> = h.dismissed_cards().iter().map(|c| short(&c.id)).collect();
    assert_eq!(list, ["PR_2", "PR_1"], "newest Dismiss first");
    let card = h.restore(&key("PR_1")).unwrap();
    assert_eq!((card.dismissed_at, card.dismiss_expires_at), (None, None));
    assert!(h.visible("PR_1"));
    assert!(h.engine.pr_record(&full("PR_1")).unwrap().restored);
}

#[test]
fn dismissed_keep_days_applies_to_the_dismissed_cards() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let at = h.dismiss(&key("PR_1")).unwrap().dismissed_at.unwrap();
    h.set("dismissed_keep_days", json!(2));
    assert_eq!(
        h.dismissed_cards()[0].dismiss_expires_at,
        Some(at + 2 * DAY)
    );
}

// ----------------------------------------------------------- the clocks

#[test]
fn the_automatic_dismiss_table() {
    // (name, setup after the merge, days passed, want dismissed)
    type Step = fn(&mut H);
    let cases: [(&str, Step, i64, bool); 12] = [
        ("before n days", |_| {}, 2, false),
        ("after n days", |_| {}, 3, true),
        (
            "with unread rows",
            |h| {
                let e = h.ev("C_1", "PR_1", IngestKind::Comment);
                h.events(vec![e]);
            },
            3,
            true,
        ),
        (
            "a mention after the merge",
            |h| {
                let e = h.ev("M_1", "PR_1", IngestKind::Mentioned);
                h.events(vec![e]);
            },
            3,
            false,
        ),
        (
            "a reply after the merge",
            |h| {
                let e = h.ev("R_1", "PR_1", IngestKind::Reply);
                h.events(vec![e]);
            },
            3,
            false,
        ),
        (
            "a mention recorded with its List off",
            |h| {
                h.table(EventKind::Mentioned, EventColumn::List, false);
                let e = h.ev("M_1", "PR_1", IngestKind::Mentioned);
                h.events(vec![e]);
            },
            3,
            true,
        ),
        (
            "a reply where I or my team was mentioned",
            |h| {
                let e = h.ev("R_1", "PR_1", IngestKind::ReplyMentioned);
                h.events(vec![e]);
            },
            3,
            false,
        ),
        (
            "a team mention after the merge",
            |h| {
                let e = h.ev("M_1", "PR_1", IngestKind::TeamMentioned);
                h.events(vec![e]);
            },
            3,
            false,
        ),
        (
            "a team mention recorded with its List off",
            |h| {
                h.table(EventKind::TeamMentioned, EventColumn::List, false);
                let e = h.ev("M_1", "PR_1", IngestKind::TeamMentioned);
                h.events(vec![e]);
            },
            3,
            true,
        ),
        (
            "a review request after the merge",
            |h| {
                let e = h.ev("RR_1", "PR_1", IngestKind::ReviewRequested);
                h.events(vec![e]);
            },
            3,
            true,
        ),
        (
            "restored",
            |h| {
                h.dismiss(&key("PR_1")).unwrap();
                h.restore(&key("PR_1")).unwrap();
            },
            30,
            false,
        ),
        (
            "n set to 0",
            |h| h.set("auto_dismiss_after_days", json!(0)),
            0,
            true,
        ),
    ];
    for (name, step, days, want) in cases {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.place(
            &key("PR_1"),
            PlaceTab::Review,
            Some(Section::Doing),
            None,
            None,
        )
        .unwrap();
        let merged_at = h.at();
        h.prs(vec![merged(other("PR_1"))]);
        step(&mut h);
        h.set_time(merged_at + days * DAY);
        h.tick();
        assert_eq!(h.dismissed("PR_1"), want, "{name}");
        if want {
            let card = h.card_by_id("PR_1").unwrap();
            assert_eq!(
                card.placement.map(|p| p.section.as_text()),
                Some("done".into()),
                "{name}: the place is kept"
            );
        }
    }
}

#[test]
fn after_the_close_is_judged_when_the_row_is_made() {
    // DESIGN.md, "Dismiss": "after the merge or close" means the PR was
    // known merged or closed when the row was made, whatever the time of
    // the event.
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    let before = h.ev("M_1", "PR_1", IngestKind::TeamMentioned);
    h.events(vec![before]);
    h.advance(600);
    let merged_at = h.at();
    h.prs(vec![merged(other("PR_1")), merged(other("PR_2"))]);
    // An event of before the merge, made into a row after it.
    let late = h.ev_at("M_2", "PR_2", IngestKind::ReplyMentioned, merged_at - 60);
    h.events(vec![late]);
    h.set_time(merged_at + 3 * DAY);
    h.tick();
    assert!(h.dismissed("PR_1"), "the row was made while open");
    assert!(h.has_row("M_2"));
    assert!(!h.dismissed("PR_2"), "the row was made after the merge");
}

#[test]
fn an_open_pr_is_never_dismissed_by_time() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.set_time(T0 + 365 * DAY);
    h.tick();
    assert!(!h.dismissed("PR_1"));
}

#[test]
fn the_clocks_wait_while_the_popover_is_open() {
    // DESIGN.md, "Dismiss": both happen when it closes.
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    h.prs(vec![merged(other("PR_1"))]);
    let dismissed_at = h.at();
    h.dismiss(&key("PR_2")).unwrap();
    h.open();
    h.set_time(T0 + 8 * DAY);
    h.tick();
    assert!(!h.dismissed("PR_1"), "held while open");
    let card = h.card_by_id("PR_2").expect("still in the list while open");
    assert!(card.dismiss_expires_at.unwrap() < h.at(), "0 days left");
    h.close();
    assert!(h.dismissed("PR_1"));
    assert!(h.card_by_id("PR_2").is_none(), "gone once closed");
    assert!(dismissed_at < h.at());
    // Another account's popover does not hold this one's.
    let mut h = H::new();
    h.add_other();
    h.prs(vec![other("PR_1")]);
    h.prs(vec![merged(other("PR_1"))]);
    h.engine.popover_opened(YOU).unwrap();
    h.set_time(T0 + 4 * DAY);
    h.tick();
    assert!(h.dismissed("PR_1"));
}

#[test]
fn the_end_of_the_dismissed_list_leaves_a_record_for_an_open_pr_only() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1"), other("PR_2")], vec![e], vec![]);
    h.prs(vec![merged(other("PR_2"))]);
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Inbox),
        None,
        None,
    )
    .unwrap();
    h.dismiss(&key("PR_1")).unwrap();
    h.dismiss(&key("PR_2")).unwrap();
    h.set_time(T0 + 7 * DAY + 100);
    h.tick();
    assert!(h.engine.pr_record(&full("PR_1")).is_none(), "card gone");
    assert!(!h.has_row("E_1"), "rows gone");
    let record = h
        .engine
        .record(&full("PR_1"))
        .expect("a record of the open PR");
    assert_eq!(record.updated_at, T0);
    assert_eq!(record.owner, h.owner_id(ORG));
    assert!(
        h.engine.record(&full("PR_2")).is_none(),
        "none for a merged PR"
    );
    assert!(h.engine.pr_record(&full("PR_2")).is_none());
}

#[test]
fn a_dismissed_pr_found_closed_leaves_no_record() {
    // DESIGN.md, "Dismiss": a search or an event that showed it closed.
    type Step = fn(&mut H);
    let cases: [(&str, Step); 2] = [
        ("search", |h| search(h, vec![hit("PR_1", T0 + 50, false)])),
        ("merged event", |h| {
            let e = h.ev("MG_1", "PR_1", IngestKind::Merged);
            h.events(vec![e]);
        }),
    ];
    for (name, step) in cases {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.dismiss(&key("PR_1")).unwrap();
        step(&mut h);
        assert!(!h.has_row("MG_1"), "{name}: no row while dismissed");
        h.set_time(T0 + 8 * DAY);
        h.tick();
        assert!(h.engine.record(&full("PR_1")).is_none(), "{name}");
    }
}

#[test]
fn disabled_and_unreadable_cards_keep_their_state_and_their_clocks() {
    // DESIGN.md, "When cards show, and watching".
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Waiting),
        None,
        None,
    )
    .unwrap();
    h.dismiss(&key("PR_2")).unwrap();
    h.prs(vec![merged(other("PR_1"))]);
    let org = h.owner_id(ORG);
    h.engine.owner_enable(&org, false, &h.now.clone());
    assert!(h.dismissed_cards().is_empty(), "not in the Dismissed list");
    h.set_time(T0 + 4 * DAY);
    h.tick();
    assert!(h.dismissed("PR_1"), "n days counted while disabled");
    h.engine.owner_enable(&org, true, &h.now.clone());
    let back = h.card_by_id("PR_1").unwrap();
    assert!(back.dismissed_at.is_some());
    assert_eq!(back.placement.unwrap().tab.as_text(), "review");
    // m days count while disabled too.
    h.engine.owner_enable(&org, false, &h.now.clone());
    h.set_time(T0 + 8 * DAY);
    h.tick();
    assert!(h.engine.pr_record(&full("PR_2")).is_none());
    assert!(h.engine.record(&full("PR_2")).is_some());
}

// ------------------------------------------------------- return triggers

#[test]
fn return_trigger_table() {
    // (name, kind, actor, List off, returns)
    // DESIGN.md, "Dismiss": the seven return trigger rows.
    let cases = [
        ("mention", IngestKind::Mentioned, "alice", None, true),
        (
            "team mention",
            IngestKind::TeamMentioned,
            "alice",
            None,
            true,
        ),
        (
            "reply to my comment",
            IngestKind::Reply,
            "alice",
            None,
            true,
        ),
        (
            "reply where I or my team was mentioned",
            IngestKind::ReplyMentioned,
            "alice",
            None,
            true,
        ),
        (
            "review request to me",
            IngestKind::ReviewRequested,
            "alice",
            None,
            true,
        ),
        (
            "review request to my team",
            IngestKind::TeamReviewRequested,
            "alice",
            None,
            true,
        ),
        ("reopen", IngestKind::Reopened, "alice", None, true),
        ("my own reopen", IngestKind::Reopened, ME, None, true),
        ("comment", IngestKind::Comment, "alice", None, false),
        (
            "comment on others",
            IngestKind::CommentOther,
            "alice",
            None,
            false,
        ),
        ("approval", IngestKind::Approved, "alice", None, false),
        ("merged", IngestKind::Merged, "alice", None, false),
        (
            "mention, its List off",
            IngestKind::Mentioned,
            "alice",
            Some(EventKind::Mentioned),
            false,
        ),
        (
            "review request to my team, its List off",
            IngestKind::TeamReviewRequested,
            "alice",
            Some(EventKind::TeamReviewRequested),
            false,
        ),
    ];
    for (name, kind, actor, off, returns) in cases {
        let mut h = H::new();
        if let Some(kind) = off {
            h.table(kind, EventColumn::List, false);
        }
        h.prs(vec![other("PR_1")]);
        h.place(
            &key("PR_1"),
            PlaceTab::Review,
            Some(Section::Waiting),
            None,
            None,
        )
        .unwrap();
        h.dismiss(&key("PR_1")).unwrap();
        h.open();
        h.close();
        let mut e = h.ev("E_1", "PR_1", kind);
        e.actor = Some(actor.into());
        h.events(vec![e]);
        assert_eq!(!h.dismissed("PR_1"), returns, "{name}");
        if returns {
            assert_eq!(
                h.placement("PR_1").map(|p| p.1),
                Some("waiting".into()),
                "{name}: back to its place"
            );
            let row = h.row("E_1");
            let own = actor == ME;
            assert_eq!(row.unread, !own, "{name}: unread");
            assert_eq!(h.dot(), !own, "{name}: dot");
            assert_eq!(h.delivered().len(), usize::from(!own), "{name}: notified");
        } else if off.is_none() {
            assert!(!h.has_row("E_1"), "{name}: no row while dismissed");
        } else {
            assert!(!h.dot(), "{name}: no dot");
            assert!(h.delivered().is_empty(), "{name}: not notified");
        }
    }
}

#[test]
fn only_the_return_trigger_rows_are_made_while_dismissed() {
    let mut h = H::new();
    let c = h.reaction("C_1", "PR_1", &[("HEART", 1)]);
    h.push(vec![pr("PR_1")], vec![], vec![c]);
    h.dismiss(&key("PR_1")).unwrap();
    let comment = h.ev("E_1", "PR_1", IngestKind::Comment);
    let mention = h.ev("E_2", "PR_1", IngestKind::Mentioned);
    let reaction = h.reaction("C_1", "PR_1", &[("HEART", 3)]);
    h.push(
        vec![IngestPr {
            checks: Checks::Failed,
            ..pr("PR_1")
        }],
        vec![comment, mention],
        vec![reaction],
    );
    let kinds: Vec<String> = h
        .card(&key("PR_1"))
        .unwrap()
        .rows
        .iter()
        .map(|r| r.kind.as_text())
        .collect();
    assert_eq!(
        kinds,
        ["mentioned", "reaction"],
        "no comment, no Checks failed, no new Reaction"
    );
    assert!(!h.dismissed("PR_1"));
}

#[test]
fn a_merged_pr_returns_to_done_and_counts_n_days_again() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.prs(vec![merged(pr("PR_1"))]);
    h.dismiss(&key("PR_1")).unwrap();
    h.set_time(T0 + 5 * DAY);
    let back_at = h.at();
    let e = h.ev("E_1", "PR_1", IngestKind::Mentioned);
    h.events(vec![e]);
    assert_eq!(h.placement("PR_1").map(|p| p.1), Some("done".into()));
    assert_eq!(
        h.engine.pr_record(&full("PR_1")).unwrap().closed_at,
        Some(back_at)
    );
    // The mention after the merge keeps it from the automatic Dismiss.
    h.set_time(back_at + 10 * DAY);
    h.tick();
    assert!(!h.dismissed("PR_1"));
}

#[test]
fn a_merge_while_dismissed_is_seen_by_the_status_after_the_return() {
    // DESIGN.md, "Dismiss": its place in Done and the n days count from
    // that detection.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    h.dismiss(&key("PR_1")).unwrap();
    h.set_time(T0 + 2 * DAY);
    h.restore(&key("PR_1")).unwrap();
    assert_eq!(h.placement("PR_1").map(|p| p.1), Some("doing".into()));
    let seen = h.at();
    h.prs(vec![merged(other("PR_1"))]);
    let record = h.engine.pr_record(&full("PR_1")).unwrap();
    assert_eq!((record.closed_at, record.done_at), (Some(seen), Some(seen)));
    assert_eq!(h.placement("PR_1").map(|p| p.1), Some("done".into()));
}

#[test]
fn rows_made_before_the_return_stay_out() {
    // DESIGN.md, "Dismiss": what happened while dismissed is not made a
    // row after the return either.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.dismiss(&key("PR_1")).unwrap();
    let comment = h.ev_at("E_1", "PR_1", IngestKind::Comment, T0 + 20);
    let mention = h.ev_at("E_2", "PR_1", IngestKind::Mentioned, T0 + 30);
    h.set_time(T0 + 40);
    h.events(vec![comment.clone(), mention]);
    assert!(!h.dismissed("PR_1"));
    h.events(vec![comment]);
    assert!(!h.has_row("E_1"));
}

// ------------------------------------------------- records and discovery

/// A PR with a Dismiss record: open, left the Dismissed list.
fn recorded(h: &mut H) {
    h.prs(vec![other("PR_1")]);
    h.dismiss(&key("PR_1")).unwrap();
    h.set_time(T0 + 8 * DAY);
    h.tick();
    assert!(h.engine.record(&full("PR_1")).is_some());
}

#[test]
fn a_record_shows_again_only_through_a_return_trigger() {
    let mut h = H::new();
    recorded(&mut h);
    let later = IngestPr {
        updated_at: T0 + 8 * DAY + 10,
        ..other("PR_1")
    };
    let comment = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![later.clone()], vec![comment], vec![]);
    assert!(
        h.engine.pr_record(&full("PR_1")).is_none(),
        "a comment is not one"
    );
    assert!(h.engine.record(&full("PR_1")).is_some());
    let request = h.ev("E_2", "PR_1", IngestKind::ReviewRequested);
    let comment = h.ev("E_3", "PR_1", IngestKind::Comment);
    h.push(vec![later], vec![request, comment], vec![]);
    // Like a newly found PR: a request puts it in Inbox.
    assert!(h.visible("PR_1"));
    assert_eq!(h.placement("PR_1").map(|p| p.1), Some("inbox".into()));
    assert!(h.engine.record(&full("PR_1")).is_none());
    assert!(h.has_row("E_2"));
    assert!(!h.has_row("E_3"), "only the trigger row");
    assert!(h.dot());
}

#[test]
fn a_search_hit_moves_the_record_on_or_ends_it() {
    let mut h = H::new();
    recorded(&mut h);
    let later = T0 + 9 * DAY;
    search(
        &mut h,
        vec![SearchHit {
            events_fetched: false,
            ..hit("PR_1", later, true)
        }],
    );
    assert_eq!(
        h.engine.record(&full("PR_1")).unwrap().updated_at,
        T0,
        "events failed"
    );
    search(&mut h, vec![hit("PR_1", later, true)]);
    assert_eq!(h.engine.record(&full("PR_1")).unwrap().updated_at, later);
    search(&mut h, vec![hit("PR_1", later + 5, false)]);
    assert!(h.engine.record(&full("PR_1")).is_none(), "closed: gone");
}

#[test]
fn a_search_hit_moves_a_dismissed_card_on() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.dismiss(&key("PR_1")).unwrap();
    search(&mut h, vec![hit("PR_1", T0 + 500, true)]);
    let record = h.engine.pr_record(&full("PR_1")).unwrap();
    assert_eq!(record.updated_at, T0 + 500);
    assert!(!record.seen_closed);
    // Not for a card in the lists: its status says.
    h.prs(vec![other("PR_2")]);
    search(&mut h, vec![hit("PR_2", T0 + 900, true)]);
    assert_eq!(h.engine.pr_record(&full("PR_2")).unwrap().updated_at, T0);
}

#[test]
fn removing_the_owner_or_the_account_removes_the_records() {
    let mut h = H::new();
    recorded(&mut h);
    let org = h.owner_id(ORG);
    h.engine.owner_remove(&org);
    assert!(h.engine.record(&full("PR_1")).is_none());
    let mut h = H::new();
    recorded(&mut h);
    h.engine.account_remove(ACCOUNT);
    assert!(h.engine.records_of(ACCOUNT).is_empty());
}

#[test]
fn a_closed_pr_found_new_shows_only_through_a_return_trigger() {
    // (name, author is me, trigger, want place)
    let cases = [
        ("someone else's, merged event only", false, None, None),
        (
            "someone else's, a comment",
            false,
            Some(IngestKind::CommentOther),
            None,
        ),
        (
            "someone else's, a mention",
            false,
            Some(IngestKind::Mentioned),
            Some(None),
        ),
        (
            "someone else's, a team mention",
            false,
            Some(IngestKind::TeamMentioned),
            Some(None),
        ),
        (
            "someone else's, a reply where my team was mentioned",
            false,
            Some(IngestKind::ReplyMentioned),
            Some(None),
        ),
        (
            "someone else's, a reply to my comment",
            false,
            Some(IngestKind::Reply),
            Some(None),
        ),
        (
            "someone else's, a reopen",
            false,
            Some(IngestKind::Reopened),
            Some(None),
        ),
        (
            "someone else's, a review request to my team",
            false,
            Some(IngestKind::TeamReviewRequested),
            Some(Some(("review", "done"))),
        ),
        (
            "mine, a mention",
            true,
            Some(IngestKind::Mentioned),
            Some(Some(("mine", "done"))),
        ),
        (
            "mine, a team mention",
            true,
            Some(IngestKind::TeamMentioned),
            Some(Some(("mine", "done"))),
        ),
    ];
    for (name, mine, trigger, want) in cases {
        let mut h = H::new();
        let found = merged(if mine { pr("PR_1") } else { other("PR_1") });
        let mut events = vec![h.ev("MG_1", "PR_1", IngestKind::Merged)];
        if let Some(kind) = trigger {
            events.push(h.ev("T_1", "PR_1", kind));
        }
        let detected = h.at();
        h.push(vec![found], events, vec![]);
        let record = h.engine.pr_record(&full("PR_1"));
        assert_eq!(record.is_some(), want.is_some(), "{name}");
        let Some(place) = want else { continue };
        assert!(!h.has_row("MG_1"), "{name}: only the trigger row");
        assert_eq!(
            h.placement("PR_1").map(|p| (p.0, p.1)),
            place.map(|(t, s)| (t.to_string(), s.to_string())),
            "{name}"
        );
        assert_eq!(record.unwrap().closed_at, Some(detected), "{name}: n days");
    }
}

#[test]
fn the_ongoing_request_exception_is_not_for_dismissed_cards() {
    // DESIGN.md, "Events before the watch started".
    let mut h = H::new();
    h.prs(vec![IngestPr {
        requested_me: true,
        ..other("PR_1")
    }]);
    h.dismiss(&key("PR_1")).unwrap();
    let org = h.owner_id(ORG);
    h.engine.owner_enable(&org, false, &h.now.clone());
    h.engine.owner_enable(&org, true, &h.now.clone());
    let old = h.ev_at("RR_1", "PR_1", IngestKind::ReviewRequested, T0 - DAY);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_1")
        }],
        vec![old],
        vec![],
    );
    assert!(!h.has_row("RR_1"));
    assert!(h.dismissed("PR_1"));
}

#[test]
fn events_of_the_dismissed_period_stay_out_after_a_return_through_a_record_or_a_closed_find() {
    // DESIGN.md, "Dismiss": what happened while dismissed makes no row after
    // the return either, also when the next fetch sends it again (the
    // five-minute overlap of the event window).
    // (name, how the PR comes back)
    type Back = fn(&mut H) -> IngestPr;
    let cases: [(&str, Back); 2] = [
        ("a Dismiss record", |h| {
            recorded(h);
            IngestPr {
                updated_at: T0 + 8 * DAY + 10,
                ..other("PR_1")
            }
        }),
        ("a closed PR found new", |_| merged(other("PR_1"))),
    ];
    for (name, back) in cases {
        let mut h = H::new();
        let found = back(&mut h);
        let start = h.at();
        let comment = h.ev_at("E_1", "PR_1", IngestKind::Comment, start + 10);
        let mention = h.ev_at("E_2", "PR_1", IngestKind::Mentioned, start + 20);
        h.set_time(start + 30);
        h.push(
            vec![found.clone()],
            vec![comment.clone(), mention.clone()],
            vec![],
        );
        assert!(h.visible("PR_1"), "{name}: back");
        assert!(!h.has_row("E_1"), "{name}: only the trigger row");
        h.advance(60);
        h.push(vec![found], vec![comment, mention], vec![]);
        assert!(!h.has_row("E_1"), "{name}: not made by the next fetch");
        assert!(h.has_row("E_2"), "{name}");
        // What happens after the return makes rows as usual.
        let later = h.ev_at("E_3", "PR_1", IngestKind::Comment, h.at() + 5);
        h.set_time(h.at() + 10);
        h.events(vec![later]);
        assert!(h.has_row("E_3"), "{name}: after the return");
    }
}

#[test]
fn a_closed_pr_found_with_a_review_request_to_me_goes_to_reviews_done() {
    // DESIGN.md, "Review" and "Card states": placed directly in Review's
    // Done, its place in Done and the n days from the detection.
    let mut h = H::new();
    let request = h.ev("RR_1", "PR_1", IngestKind::ReviewRequested);
    let detected = h.at();
    h.push(vec![merged(other("PR_1"))], vec![request], vec![]);
    assert_eq!(
        h.placement("PR_1").map(|p| (p.0, p.1)),
        Some(("review".to_string(), "done".to_string()))
    );
    let record = h.engine.pr_record(&full("PR_1")).unwrap();
    assert_eq!(
        (record.closed_at, record.done_at),
        (Some(detected), Some(detected))
    );
    assert!(h.has_row("RR_1"));
}

#[test]
fn a_reopen_ends_the_restore_exception() {
    // DESIGN.md, "Dismiss": the Restore exception lasts until the PR is
    // reopened; a new merge counts its n days again.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.prs(vec![merged(other("PR_1"))]);
    h.dismiss(&key("PR_1")).unwrap();
    h.restore(&key("PR_1")).unwrap();
    h.set_time(T0 + 30 * DAY);
    h.tick();
    assert!(!h.dismissed("PR_1"), "restored");
    h.prs(vec![other("PR_1")]);
    assert!(!h.engine.pr_record(&full("PR_1")).unwrap().restored);
    let merged_again = h.at();
    h.prs(vec![merged(other("PR_1"))]);
    h.set_time(merged_again + 3 * DAY);
    h.tick();
    assert!(h.dismissed("PR_1"), "n days after the new merge");
}

#[test]
fn a_closed_pr_found_with_a_team_request_whose_list_is_off_is_not_taken() {
    let mut h = H::new();
    h.table(EventKind::TeamReviewRequested, EventColumn::List, false);
    let request = h.ev("RR_1", "PR_1", IngestKind::TeamReviewRequested);
    h.push(vec![merged(other("PR_1"))], vec![request], vec![]);
    assert!(h.engine.pr_record(&full("PR_1")).is_none());
}

#[test]
fn a_closed_pr_found_new_counts_n_days_only_through_a_request_or_a_reopen() {
    // DESIGN.md, "Dismiss": a mention or reply row is after the close, so
    // no automatic Dismiss; a review request or Reopened counts n days.
    // (name, trigger, counts n days)
    let cases = [
        ("review request", IngestKind::ReviewRequested, true),
        ("team review request", IngestKind::TeamReviewRequested, true),
        ("reopened", IngestKind::Reopened, true),
        ("mention", IngestKind::Mentioned, false),
        ("team mention", IngestKind::TeamMentioned, false),
        ("reply", IngestKind::Reply, false),
        ("reply where mentioned", IngestKind::ReplyMentioned, false),
    ];
    for (name, kind, counts) in cases {
        let mut h = H::new();
        let detected = h.at();
        let trigger = h.ev("T_1", "PR_1", kind);
        h.push(vec![merged(other("PR_1"))], vec![trigger], vec![]);
        let card = h.card_by_id("PR_1").expect(name);
        assert_eq!(
            card.auto_dismiss_at,
            counts.then_some(detected + 3 * DAY),
            "{name}"
        );
    }
}

#[test]
fn a_record_shows_again_through_each_return_trigger() {
    for kind in [
        IngestKind::Mentioned,
        IngestKind::TeamMentioned,
        IngestKind::Reply,
        IngestKind::ReplyMentioned,
        IngestKind::ReviewRequested,
        IngestKind::TeamReviewRequested,
        IngestKind::Reopened,
    ] {
        let mut h = H::new();
        recorded(&mut h);
        let later = IngestPr {
            updated_at: T0 + 8 * DAY + 10,
            ..other("PR_1")
        };
        let trigger = h.ev("T_1", "PR_1", kind);
        h.push(vec![later], vec![trigger], vec![]);
        assert!(h.visible("PR_1"), "{kind:?}");
        assert!(h.engine.record(&full("PR_1")).is_none(), "{kind:?}");
    }
}

/// An open PR only a team mention search found (`Ingest::team_only`).
fn found_by_team(h: &mut H, events: Vec<IngestEvent>) {
    let ingest = Ingest {
        prs: vec![IngestPr {
            requested_team: true,
            ..other("PR_1")
        }],
        events,
        team_only: vec!["PR_1".into()],
        ..Ingest::default()
    };
    h.engine.ingest(ACCOUNT, ingest, &h.now.clone()).unwrap();
    h.advance(1);
}

#[test]
fn an_open_pr_found_only_by_a_team_search_shows_only_through_a_return_trigger() {
    // DESIGN.md, "API usage": taken like a closed PR the core does not know.
    let mut h = H::new();
    let comment = h.ev("E_1", "PR_1", IngestKind::CommentOther);
    found_by_team(&mut h, vec![comment]);
    assert!(h.engine.pr_record(&full("PR_1")).is_none(), "a comment");
    let mention = h.ev("E_2", "PR_1", IngestKind::TeamMentioned);
    let comment = h.ev("E_3", "PR_1", IngestKind::CommentOther);
    found_by_team(&mut h, vec![mention, comment]);
    assert!(h.visible("PR_1"));
    assert!(h.has_row("E_2"));
    assert!(!h.has_row("E_3"), "only the trigger row");
    assert_eq!(h.placement("PR_1"), None);
    assert_eq!(h.delivered().len(), 1);
}

#[test]
fn a_team_only_pr_has_no_ongoing_request_exception() {
    // A request older than the watch makes no row, so the PR is not taken.
    let mut h = H::new();
    let old = h.ev_at("RR_1", "PR_1", IngestKind::TeamReviewRequested, T0 - DAY);
    found_by_team(&mut h, vec![old]);
    assert!(h.engine.pr_record(&full("PR_1")).is_none());
}

#[test]
fn a_team_only_pr_with_a_team_request_follows_the_list() {
    // DESIGN.md, "API usage": `team:` may match a PR with only a request to
    // the team; it is taken only when that request makes a row.
    let mut h = H::new();
    h.table(EventKind::TeamReviewRequested, EventColumn::List, false);
    let request = h.ev("RR_1", "PR_1", IngestKind::TeamReviewRequested);
    found_by_team(&mut h, vec![request]);
    assert!(h.engine.pr_record(&full("PR_1")).is_none(), "List off");
    let mut h = H::new();
    let request = h.ev("RR_1", "PR_1", IngestKind::TeamReviewRequested);
    found_by_team(&mut h, vec![request]);
    assert_eq!(
        h.placement("PR_1").map(|p| (p.0, p.1)),
        Some(("review".to_string(), "inbox".to_string())),
        "List on: a request row puts it in Inbox"
    );
}

#[test]
fn a_pr_closed_while_dismissed_keeps_the_after_close_exception_of_its_trigger() {
    // DESIGN.md, "Dismiss": the exception is judged when the row is made.
    // While dismissed no status is fetched, but the events show the merge:
    // a mention or reply that brings the card back comes after the close.
    // A review request counts n days from the detection by the status.
    // (name, trigger, the merge in an earlier fetch, want kept)
    let cases = [
        ("mention, same fetch", IngestKind::Mentioned, false, true),
        ("mention, earlier fetch", IngestKind::Mentioned, true, true),
        ("team mention", IngestKind::TeamMentioned, false, true),
        ("reply", IngestKind::Reply, true, true),
        (
            "reply where mentioned",
            IngestKind::ReplyMentioned,
            false,
            true,
        ),
        ("review request", IngestKind::ReviewRequested, false, false),
        (
            "team review request",
            IngestKind::TeamReviewRequested,
            true,
            false,
        ),
    ];
    for (name, kind, earlier, kept) in cases {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.place(
            &key("PR_1"),
            PlaceTab::Review,
            Some(Section::Waiting),
            None,
            None,
        )
        .unwrap();
        h.dismiss(&key("PR_1")).unwrap();
        h.advance(60);
        let merge = h.ev("MG_1", "PR_1", IngestKind::Merged);
        h.advance(5);
        let trigger = h.ev("T_1", "PR_1", kind);
        if earlier {
            h.events(vec![merge]);
            h.events(vec![trigger]);
        } else {
            h.events(vec![merge, trigger]);
        }
        assert!(!h.dismissed("PR_1"), "{name}: back");
        assert!(!h.has_row("MG_1"), "{name}: the merge made no row");
        // The first status after the return detects the merge.
        h.advance(60);
        let detected = h.at();
        h.prs(vec![merged(other("PR_1"))]);
        let card = h.card_by_id("PR_1").unwrap();
        assert_eq!(
            card.placement.as_ref().map(|p| p.section.as_text()),
            Some("done".into()),
            "{name}: to Done at the detection"
        );
        assert_eq!(
            card.auto_dismiss_at,
            (!kept).then_some(detected + 3 * DAY),
            "{name}"
        );
        h.set_time(detected + 3 * DAY);
        h.tick();
        assert_eq!(h.dismissed("PR_1"), !kept, "{name}: after n days");
    }
}

#[test]
fn a_reopen_seen_while_dismissed_leaves_no_after_close_exception() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.dismiss(&key("PR_1")).unwrap();
    h.advance(60);
    let close = h.ev("CL_1", "PR_1", IngestKind::Closed);
    h.advance(5);
    let reopen = h.ev("RO_1", "PR_1", IngestKind::Reopened);
    h.advance(5);
    let mention = h.ev("M_1", "PR_1", IngestKind::Mentioned);
    h.events(vec![close, reopen, mention]);
    assert!(!h.dismissed("PR_1"));
    assert!(!h.engine.pr_record(&full("PR_1")).unwrap().keep_after_close);
    // Closed later: n days from that detection.
    h.prs(vec![other("PR_1")]);
    let detected = h.at();
    h.prs(vec![IngestPr {
        state: PrState::Closed,
        ..other("PR_1")
    }]);
    assert_eq!(
        h.card_by_id("PR_1").unwrap().auto_dismiss_at,
        Some(detected + 3 * DAY)
    );
}
