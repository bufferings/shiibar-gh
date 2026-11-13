//! Rule table: where a card is placed and its position. DESIGN.md, sections
//! "Tabs", "Review", "Mine", "Card states" and "Wire format" (`place`).

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::engine::ListArgs;
use support::*;

fn place(tab: &str, section: &str, position: u32) -> Option<(String, String, u32)> {
    Some((tab.into(), section.into(), position))
}

/// A PR of someone else with a review request row for the account.
fn requested(h: &mut H, id: &str, at: i64) {
    let e = h.ev_at(&format!("RR_{id}"), id, IngestKind::ReviewRequested, at);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other(id)
        }],
        vec![e],
        vec![],
    );
}

fn closed(id: &str, author_me: bool) -> IngestPr {
    IngestPr {
        state: PrState::Merged,
        ..if author_me { pr(id) } else { other(id) }
    }
}

// ------------------------------------------------------------ Card states

#[test]
fn a_new_open_pr_of_the_account_goes_to_the_end_of_mine() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), other("PR_2")]);
    assert_eq!(h.placement("PR_1"), place("mine", "main", 0));
    assert_eq!(h.placement("PR_2"), None, "someone else's PR: no place");
    h.prs(vec![pr("PR_3")]);
    assert_eq!(h.placement("PR_3"), place("mine", "main", 1));
}

#[test]
fn several_new_prs_go_to_mine_oldest_created_first() {
    // DESIGN.md, "Mine": when an owner is added, for one.
    let mut h = H::new();
    let made = |id: &str, created_at| IngestPr {
        created_at,
        ..pr(id)
    };
    h.prs(vec![
        made("PR_1", T0 - DAY),
        made("PR_2", T0 - 3 * DAY),
        made("PR_3", T0 - 2 * DAY),
    ]);
    assert_eq!(h.tab(Tab::Mine), ["PR_2", "PR_3", "PR_1"]);
}

#[test]
fn a_review_request_row_puts_an_unplaced_pr_at_the_end_of_todo() {
    let mut h = H::new();
    requested(&mut h, "PR_1", T0);
    requested(&mut h, "PR_2", T0);
    assert_eq!(h.section(Tab::Review, Section::Todo), ["PR_1", "PR_2"]);
    assert_eq!(h.placement("PR_2"), place("review", "todo", 1));
}

#[test]
fn todo_takes_several_requests_oldest_request_first() {
    let mut h = H::new();
    let a = h.ev_at("RR_1", "PR_1", IngestKind::ReviewRequested, T0 + 5);
    let b = h.ev_at("RR_2", "PR_2", IngestKind::ReviewRequested, T0 + 2);
    h.set_time(T0 + 10);
    h.push(vec![other("PR_1"), other("PR_2")], vec![a, b], vec![]);
    assert_eq!(h.section(Tab::Review, Section::Todo), ["PR_2", "PR_1"]);
}

#[test]
fn review_request_rows_and_todo() {
    // (name, kind, List off, want Todo)
    let cases = [
        ("to me", IngestKind::ReviewRequested, None, true),
        ("to my team", IngestKind::TeamReviewRequested, None, true),
        (
            "to my team, its List off",
            IngestKind::TeamReviewRequested,
            Some(EventKind::TeamReviewRequested),
            false,
        ),
        (
            "to me, its List off",
            IngestKind::ReviewRequested,
            Some(EventKind::ReviewRequested),
            false,
        ),
    ];
    for (name, kind, off, want) in cases {
        let mut h = H::new();
        if let Some(kind) = off {
            h.table(kind, EventColumn::List, false);
        }
        let e = h.ev("RR_1", "PR_1", kind);
        h.push(vec![other("PR_1")], vec![e], vec![]);
        let todo = h.placement("PR_1") == place("review", "todo", 0);
        assert_eq!(todo, want, "{name}");
    }
}

#[test]
fn a_placed_pr_does_not_move_on_a_review_request() {
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
    h.place(&key("PR_2"), PlaceTab::Mine, None, None, None)
        .unwrap();
    let a = h.ev("RR_1", "PR_1", IngestKind::ReviewRequested);
    let b = h.ev("RR_2", "PR_2", IngestKind::ReviewRequested);
    h.events(vec![a, b]);
    assert_eq!(h.placement("PR_1"), place("review", "waiting", 0));
    assert_eq!(h.placement("PR_2"), place("mine", "main", 0));
}

#[test]
fn a_muted_pr_still_goes_to_todo_after_the_others() {
    // DESIGN.md, "Review": an automatic addition goes after the cards that
    // are not muted; a muted PR after the muted ones.
    let mut h = H::new();
    h.prs(vec![other("PR_9")]);
    h.mute(MuteKind::Pr, &key("PR_9"));
    requested(&mut h, "PR_9", T0);
    requested(&mut h, "PR_1", T0);
    assert_eq!(h.section(Tab::Review, Section::Todo), ["PR_1", "PR_9"]);
    assert_eq!(h.placement("PR_9"), place("review", "todo", 1));
    requested(&mut h, "PR_2", T0);
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_1", "PR_2", "PR_9"]
    );
    // Unmuted, it goes back to the rank it had: it was added first.
    h.unmute(MuteKind::Pr, &key("PR_9"));
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_9", "PR_1", "PR_2"]
    );
}

#[test]
fn a_review_stays_in_review_after_the_request_ends() {
    let mut h = H::new();
    requested(&mut h, "PR_1", T0);
    h.prs(vec![IngestPr {
        my_review_at: Some(h.at()),
        ..other("PR_1")
    }]);
    assert_eq!(h.placement("PR_1"), place("review", "todo", 0));
}

// ---------------------------------------------------------- Done and back

#[test]
fn a_merge_moves_the_card_to_done_and_a_reopen_brings_it_back() {
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2"), other("PR_3")]);
    for id in ["PR_1", "PR_2", "PR_3"] {
        h.place(
            &key(id),
            PlaceTab::Review,
            Some(Section::Waiting),
            None,
            None,
        )
        .unwrap();
    }
    assert_eq!(h.placement("PR_2"), place("review", "waiting", 1));
    let merged_at = h.at();
    h.prs(vec![closed("PR_2", false)]);
    assert_eq!(h.placement("PR_2"), place("review", "done", 0));
    assert_eq!(h.section(Tab::Review, Section::Waiting), ["PR_1", "PR_3"]);
    // A reopen (seen by the status) puts it back where it was.
    h.prs(vec![other("PR_2")]);
    assert_eq!(h.placement("PR_2"), place("review", "waiting", 1));
    assert_eq!(h.engine.pr_record(&full("PR_2")).unwrap().done_at, None);
    // Closed again later: newly done, before the ones done earlier; the n
    // days from now.
    h.prs(vec![closed("PR_3", false)]);
    h.advance(100);
    let again = h.at();
    h.prs(vec![closed("PR_2", false)]);
    assert_eq!(
        h.section(Tab::Review, Section::Done),
        ["PR_2", "PR_3"],
        "newest entry first"
    );
    let record = h.engine.pr_record(&full("PR_2")).unwrap();
    assert!(merged_at < again);
    assert_eq!(record.done_at, Some(again));
    assert_eq!(record.closed_at, Some(again));
}

#[test]
fn done_follows_the_status_not_the_reopened_row() {
    // DESIGN.md, "Review": a Reopened row alone moves nothing.
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.prs(vec![closed("PR_1", true)]);
    assert_eq!(h.placement("PR_1"), place("mine", "done", 0));
    let e = h.ev("RO_1", "PR_1", IngestKind::Reopened);
    h.events(vec![e]);
    assert_eq!(h.placement("PR_1"), place("mine", "done", 0));
    h.prs(vec![pr("PR_1")]);
    assert_eq!(h.placement("PR_1"), place("mine", "main", 0));
}

#[test]
fn add_to_a_closed_pr_places_it_in_that_tabs_done() {
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    h.prs(vec![closed("PR_1", false), closed("PR_2", false)]);
    assert_eq!(h.placement("PR_1"), None, "an unplaced PR stays unplaced");
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Doing),
        Some(&key("PR_9")),
        None,
    )
    .unwrap();
    assert_eq!(h.placement("PR_1"), place("review", "done", 0));
    h.place(&key("PR_2"), PlaceTab::Mine, None, None, Some(At::Top))
        .unwrap();
    assert_eq!(h.placement("PR_2"), place("mine", "done", 0));
}

// ------------------------------------------------------------------ place

#[test]
fn place_positions_and_their_defaults() {
    let mut h = H::new();
    h.prs(vec![
        other("PR_1"),
        other("PR_2"),
        other("PR_3"),
        other("PR_4"),
    ]);
    let to = |h: &mut H, id: &str, section: Section, before: Option<&str>, at: Option<At>| {
        h.place(&key(id), PlaceTab::Review, Some(section), before, at)
            .unwrap()
    };
    to(&mut h, "PR_1", Section::Todo, None, None);
    to(&mut h, "PR_2", Section::Todo, None, None);
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_1", "PR_2"],
        "end"
    );
    to(&mut h, "PR_3", Section::Todo, None, Some(At::Top));
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_3", "PR_1", "PR_2"]
    );
    let card = to(&mut h, "PR_4", Section::Todo, Some(&key("PR_1")), None);
    assert_eq!(
        card.placement.unwrap().position,
        1,
        "the answer is the card"
    );
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_3", "PR_4", "PR_1", "PR_2"]
    );
    // From Doing or Waiting to Todo without a position: the top.
    to(&mut h, "PR_2", Section::Doing, None, None);
    to(&mut h, "PR_2", Section::Todo, None, None);
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_2", "PR_3", "PR_4", "PR_1"]
    );
    to(&mut h, "PR_3", Section::Waiting, None, None);
    to(&mut h, "PR_3", Section::Todo, None, None);
    assert_eq!(h.section(Tab::Review, Section::Todo)[0], "PR_3");
    // Inside Todo without a position: the end.
    to(&mut h, "PR_3", Section::Todo, None, None);
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_2", "PR_4", "PR_1", "PR_3"]
    );
    to(&mut h, "PR_3", Section::Todo, None, Some(At::Bottom));
    assert_eq!(
        h.section(Tab::Review, Section::Todo).last().unwrap(),
        "PR_3"
    );
    // Review lists its sections in order.
    to(&mut h, "PR_1", Section::Waiting, None, None);
    to(&mut h, "PR_4", Section::Doing, None, None);
    assert_eq!(h.tab(Tab::Review), ["PR_4", "PR_2", "PR_3", "PR_1"]);
    // None takes it out; the PR stays in All.
    h.place(&key("PR_4"), PlaceTab::None, None, None, None)
        .unwrap();
    assert_eq!(h.placement("PR_4"), None);
    assert!(h.visible("PR_4"));
}

#[test]
fn place_is_invalid_in_these_cases() {
    let mut h = H::new();
    h.prs(vec![
        pr("PR_1"),
        other("PR_2"),
        other("PR_3"),
        other("PR_4"),
    ]);
    h.place(
        &key("PR_3"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_4"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    h.mute(MuteKind::Pr, &key("PR_4"));
    h.dismiss(&key("PR_2")).unwrap();
    let r = PlaceTab::Review;
    let cases: Vec<(&str, Result<Card, _>)> = vec![
        (
            "done with a position",
            h.place(&key("PR_3"), r, Some(Section::Done), None, Some(At::Top)),
        ),
        (
            "done before a PR",
            h.place(
                &key("PR_3"),
                PlaceTab::Mine,
                Some(Section::Done),
                Some(&key("PR_1")),
                None,
            ),
        ),
        (
            "main in mine's done is not a section of review",
            h.place(
                &key("PR_3"),
                r,
                Some(Section::Main),
                Some(&key("PR_1")),
                None,
            ),
        ),
        (
            "review without a section",
            h.place(&key("PR_3"), r, None, None, None),
        ),
        (
            "main in review",
            h.place(&key("PR_3"), r, Some(Section::Main), None, None),
        ),
        (
            "before a PR of another section",
            h.place(
                &key("PR_3"),
                r,
                Some(Section::Todo),
                Some(&key("PR_1")),
                None,
            ),
        ),
        (
            "before a muted PR",
            h.place(
                &key("PR_3"),
                r,
                Some(Section::Todo),
                Some(&key("PR_4")),
                None,
            ),
        ),
        (
            "before itself",
            h.place(
                &key("PR_3"),
                r,
                Some(Section::Doing),
                Some(&key("PR_3")),
                None,
            ),
        ),
        (
            "before and at",
            h.place(
                &key("PR_3"),
                r,
                Some(Section::Doing),
                Some(&key("PR_4")),
                Some(At::Top),
            ),
        ),
        (
            "own PR to review",
            h.place(&key("PR_1"), r, Some(Section::Todo), None, None),
        ),
        (
            "own PR to none",
            h.place(&key("PR_1"), PlaceTab::None, None, None, None),
        ),
        (
            "a dismissed card",
            h.place(&key("PR_2"), r, Some(Section::Todo), None, None),
        ),
        (
            "mine with a section other than main or done",
            h.place(
                &key("PR_3"),
                PlaceTab::Mine,
                Some(Section::Todo),
                None,
                None,
            ),
        ),
    ];
    for (name, result) in cases {
        assert!(invalid(result), "{name}");
    }
    assert!(not_found(h.place(
        "org/app#99",
        r,
        Some(Section::Todo),
        None,
        None
    )));
}

#[test]
fn muted_cards_go_last_and_move_only_among_themselves() {
    // DESIGN.md, "Review": `position` puts the muted cards last; D/T/W move
    // a muted card among the muted ones of the target section.
    let mut h = H::new();
    h.prs(vec![
        other("PR_1"),
        other("PR_2"),
        other("PR_3"),
        other("PR_4"),
    ]);
    for id in ["PR_1", "PR_2", "PR_3"] {
        h.place(&key(id), PlaceTab::Review, Some(Section::Doing), None, None)
            .unwrap();
    }
    h.mute(MuteKind::Pr, &key("PR_1"));
    assert_eq!(
        h.section(Tab::Review, Section::Doing),
        ["PR_2", "PR_3", "PR_1"]
    );
    assert_eq!(h.placement("PR_1"), place("review", "doing", 2));
    h.place(
        &key("PR_4"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    h.mute(MuteKind::Pr, &key("PR_4"));
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    // A muted card to the top of Todo: first among the muted ones.
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_2", "PR_1", "PR_4"]
    );
    // The repository muted: every card of it is muted, in rank order.
    h.mute(MuteKind::Repo, "org/app");
    let card = h.card(&key("PR_2")).unwrap();
    assert_eq!(
        card.muted,
        [Lenient::Known(MuteReason::Repo)],
        "{:?}",
        card.muted
    );
}

#[test]
fn a_dismissed_card_keeps_its_rank_and_returns_by_it() {
    // DESIGN.md, "Dismiss": the place is kept, and the card comes back
    // where its rank puts it among the cards there now.
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2"), other("PR_3")]);
    for id in ["PR_1", "PR_2", "PR_3"] {
        h.place(
            &key(id),
            PlaceTab::Review,
            Some(Section::Waiting),
            None,
            None,
        )
        .unwrap();
    }
    h.dismiss(&key("PR_2")).unwrap();
    assert_eq!(h.section(Tab::Review, Section::Waiting), ["PR_1", "PR_3"]);
    let dismissed = h.card_by_id("PR_2").unwrap();
    assert_eq!(
        dismissed.placement.map(|p| p.position),
        Some(1),
        "the place it comes back to"
    );
    h.place(
        &key("PR_3"),
        PlaceTab::Review,
        Some(Section::Waiting),
        None,
        Some(At::Top),
    )
    .unwrap();
    h.restore(&key("PR_2")).unwrap();
    assert_eq!(
        h.section(Tab::Review, Section::Waiting),
        ["PR_3", "PR_1", "PR_2"]
    );
}

#[test]
fn list_of_review_and_mine_in_section_order() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), pr("PR_2"), other("PR_3")]);
    h.prs(vec![closed("PR_1", true)]);
    assert_eq!(h.tab(Tab::Mine), ["PR_2", "PR_1"], "main, then done");
    assert_eq!(h.placement("PR_1"), place("mine", "done", 0));
    let cards = h.list(ListArgs {
        tab: Tab::Mine,
        dismissed: DismissedFilter::Include,
        ..ListArgs::default()
    });
    assert_eq!(cards.len(), 2);
    assert!(h.tab(Tab::Review).is_empty());
}

// ------------------------------------------------------------ Done by hand

#[test]
fn an_open_card_moves_to_done_by_hand_newest_entry_first() {
    // DESIGN.md, "Review" and "Mine": the user moves an open PR to Done;
    // Done keeps the newest entry first.
    let mut h = H::new();
    h.prs(vec![
        pr("PR_1"),
        other("PR_2"),
        other("PR_3"),
        other("PR_4"),
    ]);
    for id in ["PR_2", "PR_3"] {
        h.place(&key(id), PlaceTab::Review, Some(Section::Doing), None, None)
            .unwrap();
    }
    h.place(
        &key("PR_4"),
        PlaceTab::Review,
        Some(Section::Waiting),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    h.advance(10);
    h.place(
        &key("PR_4"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Done), ["PR_4", "PR_2"]);
    assert_eq!(h.section(Tab::Review, Section::Doing), ["PR_3"]);
    assert_eq!(h.placement("PR_4"), place("review", "done", 0));
    // Placing it in the Done it is in again changes nothing.
    h.advance(10);
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Done), ["PR_4", "PR_2"]);
    // Mine: the account's own PR too.
    h.place(
        &key("PR_1"),
        PlaceTab::Mine,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.placement("PR_1"), place("mine", "done", 0));
    // An unplaced open PR goes to Done by `place … done` as well.
    h.prs(vec![other("PR_5")]);
    h.advance(10);
    h.place(
        &key("PR_5"),
        PlaceTab::Mine,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.placement("PR_5"), place("mine", "done", 0));
    // The All tab tag reads the same.
    let card = h.card(&key("PR_2")).unwrap();
    assert_eq!(
        card.placement.unwrap().section,
        Lenient::Known(Section::Done)
    );
}

#[test]
fn an_open_card_in_done_moves_out_and_is_removed_like_any_other() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), other("PR_2"), other("PR_3")]);
    for id in ["PR_2", "PR_3"] {
        h.place(&key(id), PlaceTab::Review, Some(Section::Doing), None, None)
            .unwrap();
    }
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    // Out of Done to Todo without a position: the end (not from Doing).
    h.prs(vec![other("PR_4")]);
    h.place(
        &key("PR_4"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Todo), ["PR_4", "PR_2"]);
    assert!(h.section(Tab::Review, Section::Done).is_empty());
    // Out of Done to a position.
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Doing),
        Some(&key("PR_3")),
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Doing), ["PR_2", "PR_3"]);
    // Removed from Done.
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    h.place(&key("PR_2"), PlaceTab::None, None, None, None)
        .unwrap();
    assert_eq!(h.placement("PR_2"), None);
    assert_eq!(h.engine.pr_record(&full("PR_2")).unwrap().done_at, None);
    // The account's own PR leaves Mine's Done only within Mine.
    h.place(
        &key("PR_1"),
        PlaceTab::Mine,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert!(invalid(h.place(
        &key("PR_1"),
        PlaceTab::None,
        None,
        None,
        None
    )));
    h.place(&key("PR_1"), PlaceTab::Mine, None, None, Some(At::Top))
        .unwrap();
    assert_eq!(h.placement("PR_1"), place("mine", "main", 0));
}

#[test]
fn an_open_card_in_done_merged_later_is_newly_done() {
    // DESIGN.md, "Review": the detection of the merge is its entry time and
    // the start of the n days.
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    h.advance(10);
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Done), ["PR_2", "PR_1"]);
    assert_eq!(h.card(&key("PR_1")).unwrap().auto_dismiss_at, None);
    h.advance(10 * DAY);
    h.tick();
    assert!(
        !h.dismissed("PR_1"),
        "an open PR in Done is never dismissed"
    );
    let merged = h.at();
    h.prs(vec![closed("PR_1", false)]);
    assert_eq!(h.section(Tab::Review, Section::Done), ["PR_1", "PR_2"]);
    let record = h.engine.pr_record(&full("PR_1")).unwrap();
    assert_eq!(
        (record.done_at, record.closed_at),
        (Some(merged), Some(merged))
    );
    assert_eq!(
        h.card(&key("PR_1")).unwrap().auto_dismiss_at,
        Some(merged + 3 * DAY)
    );
}

#[test]
fn new_activity_and_a_review_request_leave_a_card_in_done() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    let a = h.ev("RR_1", "PR_1", IngestKind::ReviewRequested);
    let b = h.ev("C_1", "PR_1", IngestKind::Mentioned);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_1")
        }],
        vec![a, b],
        vec![],
    );
    assert!(h.has_row("RR_1") && h.row("RR_1").unread);
    assert!(h.row("C_1").unread);
    assert_eq!(h.placement("PR_1"), place("review", "done", 0));
}

#[test]
fn a_closed_card_moves_out_of_done_and_stays_out() {
    // DESIGN.md, "Review": the move to Done happens once, at the detection.
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), other("PR_2")]);
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Waiting),
        None,
        None,
    )
    .unwrap();
    h.prs(vec![closed("PR_1", true), closed("PR_2", false)]);
    assert_eq!(h.placement("PR_2"), place("review", "done", 0));
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    h.place(&key("PR_1"), PlaceTab::Mine, None, None, None)
        .unwrap();
    assert_eq!(h.placement("PR_2"), place("review", "doing", 0));
    assert_eq!(h.placement("PR_1"), place("mine", "main", 0));
    // Later fetches of the closed PRs move nothing.
    h.advance(DAY);
    h.prs(vec![closed("PR_1", true), closed("PR_2", false)]);
    assert_eq!(h.placement("PR_2"), place("review", "doing", 0));
    assert_eq!(h.placement("PR_1"), place("mine", "main", 0));
    // Outside Done: no automatic Dismiss.
    assert_eq!(h.card(&key("PR_2")).unwrap().auto_dismiss_at, None);
    h.advance(10 * DAY);
    h.tick();
    assert!(!h.dismissed("PR_1") && !h.dismissed("PR_2"));
    // Ranked like any other card of the section.
    h.prs(vec![other("PR_3")]);
    h.place(
        &key("PR_3"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        Some(At::Top),
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Doing), ["PR_3", "PR_2"]);
    h.place(
        &key("PR_3"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        Some(At::Bottom),
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Doing), ["PR_2", "PR_3"]);
    // Back to Done: the n days count from the re-entry.
    let back = h.at();
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.placement("PR_2"), place("review", "done", 0));
    assert_eq!(
        h.card(&key("PR_2")).unwrap().auto_dismiss_at,
        Some(back + 3 * DAY)
    );
    h.advance(3 * DAY);
    h.tick();
    assert!(h.dismissed("PR_2"));
    // A closed card can be removed; the account's own is not.
    h.place(
        &key("PR_1"),
        PlaceTab::Mine,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert!(invalid(h.place(
        &key("PR_1"),
        PlaceTab::None,
        None,
        None,
        None
    )));
}

#[test]
fn a_reopen_takes_a_card_in_done_back_and_leaves_one_outside() {
    // DESIGN.md, "Dismiss": a card in Done goes back to the section and rank
    // it had before; one the user moved out of Done stays where it is.
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2"), other("PR_3")]);
    for id in ["PR_1", "PR_2", "PR_3"] {
        h.place(
            &key(id),
            PlaceTab::Review,
            Some(Section::Waiting),
            None,
            None,
        )
        .unwrap();
    }
    h.prs(vec![closed("PR_1", false), closed("PR_2", false)]);
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    assert_eq!(h.placement("PR_1"), place("review", "waiting", 0));
    assert_eq!(h.placement("PR_2"), place("review", "doing", 0));
    // An open card moved to Done, closed, then reopened: back to the
    // section it had before Done.
    h.place(
        &key("PR_3"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    h.prs(vec![closed("PR_3", false)]);
    h.prs(vec![other("PR_3")]);
    assert_eq!(h.placement("PR_3"), place("review", "waiting", 1));
}

#[test]
fn auto_dismiss_at_shows_when_the_automatic_dismiss_is_due() {
    // DESIGN.md, "Dismiss" and "Wire format": `auto_dismiss_at`.
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), other("PR_2"), pr("PR_3")]);
    assert_eq!(h.card(&key("PR_1")).unwrap().auto_dismiss_at, None, "open");
    let merged = h.at();
    h.prs(vec![
        closed("PR_1", true),
        closed("PR_2", false),
        closed("PR_3", true),
    ]);
    assert_eq!(
        h.card(&key("PR_1")).unwrap().auto_dismiss_at,
        Some(merged + 3 * DAY),
        "in Done"
    );
    assert_eq!(
        h.card(&key("PR_2")).unwrap().auto_dismiss_at,
        Some(merged + 3 * DAY),
        "unplaced"
    );
    // The setting moves it.
    h.set("auto_dismiss_after_days", serde_json::json!(5));
    assert_eq!(
        h.card(&key("PR_1")).unwrap().auto_dismiss_at,
        Some(merged + 5 * DAY)
    );
    // A Mentioned row after the merge: none.
    let e = h.ev("M_3", "PR_3", IngestKind::Mentioned);
    h.events(vec![e]);
    assert_eq!(
        h.card(&key("PR_3")).unwrap().auto_dismiss_at,
        None,
        "mentioned"
    );
    // Dismissed, then restored: none.
    h.dismiss(&key("PR_1")).unwrap();
    assert_eq!(
        h.card_by_id("PR_1").unwrap().auto_dismiss_at,
        None,
        "dismissed"
    );
    h.restore(&key("PR_1")).unwrap();
    assert_eq!(
        h.card(&key("PR_1")).unwrap().auto_dismiss_at,
        None,
        "restored"
    );
}
