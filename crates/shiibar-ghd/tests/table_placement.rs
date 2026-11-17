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
fn a_new_open_pr_of_the_account_goes_to_the_end_of_mines_todo() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), other("PR_2")]);
    assert_eq!(h.placement("PR_1"), place("mine", "todo", 0));
    assert_eq!(h.placement("PR_2"), None, "someone else's PR: no place");
    h.prs(vec![pr("PR_3")]);
    assert_eq!(h.placement("PR_3"), place("mine", "todo", 1));
    // After the cards the user put in Todo, and never in another section.
    h.prs(vec![pr("PR_4"), other("PR_5")]);
    h.place(
        &key("PR_1"),
        PlaceTab::Mine,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_5"),
        PlaceTab::Mine,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    h.prs(vec![pr("PR_6")]);
    assert_eq!(
        h.section(Tab::Mine, Section::Todo),
        ["PR_3", "PR_4", "PR_5", "PR_6"]
    );
    assert_eq!(h.section(Tab::Mine, Section::Doing), ["PR_1"]);
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
    assert_eq!(
        h.section(Tab::Mine, Section::Todo),
        ["PR_2", "PR_3", "PR_1"]
    );
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
    h.place(
        &key("PR_2"),
        PlaceTab::Mine,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    let a = h.ev("RR_1", "PR_1", IngestKind::ReviewRequested);
    let b = h.ev("RR_2", "PR_2", IngestKind::ReviewRequested);
    h.events(vec![a, b]);
    assert_eq!(h.placement("PR_1"), place("review", "waiting", 0));
    assert_eq!(h.placement("PR_2"), place("mine", "todo", 0));
}

#[test]
fn an_automatic_addition_goes_to_the_end_muted_or_not() {
    // DESIGN.md, "Review": placement and ranks have nothing to do with
    // Mute; an automatic addition goes to the end of the section.
    let mut h = H::new();
    h.prs(vec![other("PR_9")]);
    h.mute(MuteKind::Pr, &key("PR_9"));
    requested(&mut h, "PR_9", T0);
    requested(&mut h, "PR_1", T0);
    assert_eq!(h.section(Tab::Review, Section::Todo), ["PR_9", "PR_1"]);
    assert_eq!(h.placement("PR_9"), place("review", "todo", 0));
    h.prs(vec![other("PR_2")]);
    h.mute(MuteKind::Pr, &key("PR_2"));
    requested(&mut h, "PR_2", T0);
    requested(&mut h, "PR_3", T0);
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_9", "PR_1", "PR_2", "PR_3"]
    );
    h.unmute(MuteKind::Pr, &key("PR_9"));
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_9", "PR_1", "PR_2", "PR_3"],
        "Unmute moves nothing"
    );
    // The account's own PR goes to the end of Mine's Todo though its
    // repository is muted.
    h.mute(MuteKind::Repo, "org/app");
    h.prs(vec![pr("PR_5"), pr("PR_6")]);
    h.mute(MuteKind::Pr, &key("PR_5"));
    h.prs(vec![pr("PR_7")]);
    assert_eq!(
        h.section(Tab::Mine, Section::Todo),
        ["PR_5", "PR_6", "PR_7"]
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
    assert_eq!(h.placement("PR_1"), place("mine", "todo", 0));
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
    // The section is needed, but its value and the position are ignored.
    h.place(
        &key("PR_2"),
        PlaceTab::Mine,
        Some(Section::Waiting),
        None,
        Some(At::Top),
    )
    .unwrap();
    assert_eq!(h.placement("PR_2"), place("mine", "done", 0));
    // Its place before Done is the end of Todo.
    assert_eq!(h.engine.open_section(&full("PR_2")), Some(Section::Todo));
}

#[test]
fn add_to_a_closed_pr_needs_a_section_all_the_same() {
    // DESIGN.md, "Wire format": the section is needed in every case, also
    // for a merged or closed unplaced PR.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.prs(vec![closed("PR_1", false)]);
    for tab in [PlaceTab::Review, PlaceTab::Mine] {
        assert!(
            invalid(h.place(&key("PR_1"), tab, None, None, None)),
            "{tab:?}"
        );
        assert_eq!(h.placement("PR_1"), None, "{tab:?}");
    }
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
    // Review lists its sections in the screen's order: Done, Waiting,
    // Doing, Todo.
    to(&mut h, "PR_1", Section::Waiting, None, None);
    to(&mut h, "PR_4", Section::Doing, None, None);
    assert_eq!(h.tab(Tab::Review), ["PR_1", "PR_4", "PR_2", "PR_3"]);
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
            "review without a section",
            h.place(&key("PR_3"), r, None, None, None),
        ),
        (
            "mine without a section",
            h.place(&key("PR_3"), PlaceTab::Mine, None, None, None),
        ),
        (
            "mine without a section, for the account's own PR",
            h.place(&key("PR_1"), PlaceTab::Mine, None, None, Some(At::Top)),
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
            "before a PR of the same section in the other tab",
            h.place(
                &key("PR_3"),
                PlaceTab::Mine,
                Some(Section::Todo),
                Some(&key("PR_4")),
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
fn place_has_nothing_to_do_with_mute() {
    // DESIGN.md, "Wire format": `position` counts the muted cards where
    // their rank puts them; `before` may name a muted card, and `at` and the
    // default count every card of the section.
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
        ["PR_1", "PR_2", "PR_3"]
    );
    assert_eq!(h.placement("PR_1"), place("review", "doing", 0));
    // Before a muted card.
    h.place(
        &key("PR_3"),
        PlaceTab::Review,
        Some(Section::Doing),
        Some(&key("PR_1")),
        None,
    )
    .unwrap();
    assert_eq!(
        h.section(Tab::Review, Section::Doing),
        ["PR_3", "PR_1", "PR_2"]
    );
    // A muted card moves like any other: to the bottom, then to the top.
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        Some(At::Bottom),
    )
    .unwrap();
    assert_eq!(
        h.section(Tab::Review, Section::Doing),
        ["PR_3", "PR_2", "PR_1"]
    );
    h.mute(MuteKind::Pr, &key("PR_4"));
    h.place(
        &key("PR_4"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        Some(At::Top),
    )
    .unwrap();
    assert_eq!(
        h.section(Tab::Review, Section::Doing),
        ["PR_4", "PR_3", "PR_2", "PR_1"]
    );
    // The default to Todo from Doing is its top, muted cards included.
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_1"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Todo), ["PR_1", "PR_2"]);
    assert_eq!(h.placement("PR_1"), place("review", "todo", 0));
}

#[test]
fn ranks_saved_by_0_4_for_muted_cards_show_where_they_are() {
    // docs/tasks/M7.md, "Database and migration": 0.4 kept one rank order
    // for a section, muted cards included, and showed the muted ones last.
    // 0.5 shows every card at its rank.
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
    h.mute(MuteKind::Pr, &key("PR_2"));
    let ranks: Vec<i64> = ["PR_1", "PR_2", "PR_3"]
        .iter()
        .map(|id| h.engine.pr_record(&full(id)).unwrap().place.unwrap().rank)
        .collect();
    assert_eq!(ranks, [0, 1, 2]);
    assert_eq!(
        h.section(Tab::Review, Section::Waiting),
        ["PR_1", "PR_2", "PR_3"]
    );
    assert_eq!(h.placement("PR_2"), place("review", "waiting", 1));
}

#[test]
fn done_puts_the_later_move_first_within_one_second() {
    // DESIGN.md, "Review": cards moved to Done at the same time, the later
    // move first.
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2"), other("PR_3")]);
    for id in ["PR_1", "PR_2", "PR_3"] {
        h.place(&key(id), PlaceTab::Review, Some(Section::Doing), None, None)
            .unwrap();
    }
    for id in ["PR_3", "PR_1", "PR_2"] {
        h.place(&key(id), PlaceTab::Review, Some(Section::Done), None, None)
            .unwrap();
    }
    assert_eq!(
        h.section(Tab::Review, Section::Done),
        ["PR_2", "PR_1", "PR_3"]
    );
    // A later second still goes first.
    h.prs(vec![other("PR_4")]);
    h.place(
        &key("PR_4"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Done)[0], "PR_4");
}

#[test]
fn done_keeps_the_key_order_for_one_fetch() {
    // DESIGN.md, "Review": cards one fetch moved to Done keep the order of
    // their keys, as in 0.4, also after a move by hand in the same second.
    let mut h = H::new();
    h.prs(vec![other("PR_3"), other("PR_1"), other("PR_2")]);
    for id in ["PR_3", "PR_1", "PR_2"] {
        h.place(&key(id), PlaceTab::Review, Some(Section::Doing), None, None)
            .unwrap();
    }
    h.prs(vec![other("PR_9")]);
    h.place(
        &key("PR_9"),
        PlaceTab::Review,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    // The fetch in the same second as that move.
    h.prs(vec![
        closed("PR_3", false),
        closed("PR_1", false),
        closed("PR_2", false),
    ]);
    assert_eq!(
        h.section(Tab::Review, Section::Done),
        ["PR_1", "PR_2", "PR_3", "PR_9"]
    );
}

#[test]
fn add_to_closed_prs_keeps_the_order_of_their_detection() {
    // DESIGN.md, "Multiple cards": `Add to Review` of merged or closed
    // unplaced PRs keeps the time of the detection, so the order of Done is
    // that of the detections, whatever order the requests come in.
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2"), other("PR_3")]);
    h.prs(vec![closed("PR_2", false)]);
    h.prs(vec![closed("PR_1", false), closed("PR_3", false)]);
    for id in ["PR_3", "PR_2", "PR_1"] {
        h.place(&key(id), PlaceTab::Review, Some(Section::Todo), None, None)
            .unwrap();
    }
    assert_eq!(
        h.section(Tab::Review, Section::Done),
        ["PR_1", "PR_3", "PR_2"],
        "the later detection first; one fetch in key order"
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
    h.prs(vec![
        pr("PR_1"),
        pr("PR_2"),
        other("PR_3"),
        pr("PR_4"),
        pr("PR_5"),
    ]);
    h.prs(vec![closed("PR_1", true)]);
    assert_eq!(
        h.tab(Tab::Mine),
        ["PR_1", "PR_2", "PR_4", "PR_5"],
        "done, then todo"
    );
    assert_eq!(h.placement("PR_1"), place("mine", "done", 0));
    // Mine lists Done, Waiting, Doing and Todo in that order, as Review.
    h.place(
        &key("PR_5"),
        PlaceTab::Mine,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_2"),
        PlaceTab::Mine,
        Some(Section::Waiting),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.tab(Tab::Mine), ["PR_1", "PR_2", "PR_5", "PR_4"]);
    assert_eq!(h.placement("PR_5"), place("mine", "doing", 0));
    assert_eq!(h.placement("PR_4"), place("mine", "todo", 0));
    assert_eq!(h.placement("PR_2"), place("mine", "waiting", 0));
    let cards = h.list(ListArgs {
        tab: Tab::Mine,
        dismissed: DismissedFilter::Include,
        ..ListArgs::default()
    });
    assert_eq!(cards.len(), 4);
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
    h.place(
        &key("PR_1"),
        PlaceTab::Mine,
        Some(Section::Todo),
        None,
        Some(At::Top),
    )
    .unwrap();
    assert_eq!(h.placement("PR_1"), place("mine", "todo", 0));
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
    h.place(
        &key("PR_1"),
        PlaceTab::Mine,
        Some(Section::Waiting),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.placement("PR_2"), place("review", "doing", 0));
    assert_eq!(h.placement("PR_1"), place("mine", "waiting", 0));
    // Later fetches of the closed PRs move nothing.
    h.advance(DAY);
    h.prs(vec![closed("PR_1", true), closed("PR_2", false)]);
    assert_eq!(h.placement("PR_2"), place("review", "doing", 0));
    assert_eq!(h.placement("PR_1"), place("mine", "waiting", 0));
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

// ------------------------------------------------------------------ Mine

#[test]
fn mine_takes_the_sections_and_positions_of_review() {
    // DESIGN.md, "Mine" and "Wire format": the four sections, `before` and
    // `at`, and the default positions, as in Review.
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), pr("PR_2"), pr("PR_3"), pr("PR_4")]);
    assert_eq!(
        h.section(Tab::Mine, Section::Todo),
        ["PR_1", "PR_2", "PR_3", "PR_4"]
    );
    let to = |h: &mut H, id: &str, section: Section, before: Option<&str>, at: Option<At>| {
        h.place(&key(id), PlaceTab::Mine, Some(section), before, at)
            .unwrap()
    };
    to(&mut h, "PR_1", Section::Doing, None, None);
    to(&mut h, "PR_2", Section::Doing, None, None);
    assert_eq!(
        h.section(Tab::Mine, Section::Doing),
        ["PR_1", "PR_2"],
        "end"
    );
    to(&mut h, "PR_3", Section::Doing, None, Some(At::Top));
    assert_eq!(
        h.section(Tab::Mine, Section::Doing),
        ["PR_3", "PR_1", "PR_2"]
    );
    let card = to(&mut h, "PR_4", Section::Doing, Some(&key("PR_1")), None);
    assert_eq!(card.placement.unwrap().position, 1);
    assert_eq!(
        h.section(Tab::Mine, Section::Doing),
        ["PR_3", "PR_4", "PR_1", "PR_2"]
    );
    to(&mut h, "PR_4", Section::Doing, None, Some(At::Bottom));
    assert_eq!(
        h.section(Tab::Mine, Section::Doing),
        ["PR_3", "PR_1", "PR_2", "PR_4"]
    );
    // From Doing or Waiting of Mine to Todo without a position: the top.
    to(&mut h, "PR_1", Section::Todo, None, None);
    to(&mut h, "PR_2", Section::Waiting, None, None);
    to(&mut h, "PR_2", Section::Todo, None, None);
    assert_eq!(h.section(Tab::Mine, Section::Todo), ["PR_2", "PR_1"]);
    // Inside Todo without a position: the end.
    to(&mut h, "PR_2", Section::Todo, None, None);
    assert_eq!(h.section(Tab::Mine, Section::Todo), ["PR_1", "PR_2"]);
    // From Done to Todo without a position: the end.
    to(&mut h, "PR_3", Section::Done, None, None);
    to(&mut h, "PR_3", Section::Todo, None, None);
    assert_eq!(
        h.section(Tab::Mine, Section::Todo),
        ["PR_1", "PR_2", "PR_3"]
    );
    assert_eq!(h.placement("PR_3"), place("mine", "todo", 2));
    assert_eq!(h.placement("PR_4"), place("mine", "doing", 0));
}

#[test]
fn todo_takes_a_card_from_elsewhere_at_its_end() {
    // DESIGN.md, "Wire format": the top of Todo is only for a card from
    // Doing or Waiting of the same tab; one from the other tab, from Done or
    // unplaced goes to the end, in Review and Mine alike.
    let mut h = H::new();
    h.prs(vec![
        pr("PR_1"),
        other("PR_2"),
        other("PR_3"),
        other("PR_4"),
        other("PR_5"),
    ]);
    // Unplaced to Mine's Todo (`Add to Mine`): after the account's own PR.
    h.place(
        &key("PR_2"),
        PlaceTab::Mine,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Mine, Section::Todo), ["PR_1", "PR_2"]);
    // Review's Doing to Mine's Todo: the end.
    h.place(
        &key("PR_3"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_3"),
        PlaceTab::Mine,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    assert_eq!(
        h.section(Tab::Mine, Section::Todo),
        ["PR_1", "PR_2", "PR_3"]
    );
    // Mine's Waiting to Review's Todo: the end.
    h.place(
        &key("PR_4"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_5"),
        PlaceTab::Mine,
        Some(Section::Waiting),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_5"),
        PlaceTab::Review,
        Some(Section::Todo),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Review, Section::Todo), ["PR_4", "PR_5"]);
    // Review's Doing to Review's Todo: the top.
    h.place(
        &key("PR_2"),
        PlaceTab::Review,
        Some(Section::Doing),
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
    assert_eq!(
        h.section(Tab::Review, Section::Todo),
        ["PR_2", "PR_4", "PR_5"]
    );
}

#[test]
fn mine_done_and_a_reopen_bring_a_card_back_to_its_section() {
    // DESIGN.md, "Mine" and "Review": a card in Done goes back to the
    // section and rank it had before Done on a reopen.
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), pr("PR_2"), pr("PR_3"), pr("PR_4")]);
    for id in ["PR_1", "PR_2", "PR_3"] {
        h.place(&key(id), PlaceTab::Mine, Some(Section::Waiting), None, None)
            .unwrap();
    }
    // A merge moves it to Done; a reopen brings it back.
    h.prs(vec![closed("PR_2", true)]);
    assert_eq!(h.placement("PR_2"), place("mine", "done", 0));
    assert_eq!(h.section(Tab::Mine, Section::Waiting), ["PR_1", "PR_3"]);
    h.prs(vec![pr("PR_2")]);
    assert_eq!(h.placement("PR_2"), place("mine", "waiting", 1));
    // A move to Done by hand, then a close and a reopen: back as well.
    h.place(
        &key("PR_4"),
        PlaceTab::Mine,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_4"),
        PlaceTab::Mine,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.placement("PR_4"), place("mine", "done", 0));
    assert!(h.section(Tab::Mine, Section::Doing).is_empty());
    h.prs(vec![closed("PR_4", true)]);
    h.prs(vec![pr("PR_4")]);
    assert_eq!(h.placement("PR_4"), place("mine", "doing", 0));
    // From another tab to Mine's Done: it keeps the end of Todo.
    h.prs(vec![other("PR_5")]);
    h.place(
        &key("PR_5"),
        PlaceTab::Review,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    h.place(
        &key("PR_5"),
        PlaceTab::Mine,
        Some(Section::Done),
        None,
        None,
    )
    .unwrap();
    h.prs(vec![closed("PR_5", false)]);
    h.prs(vec![other("PR_5")]);
    assert_eq!(h.placement("PR_5"), place("mine", "todo", 0));
    // Out of Done by hand, to any section.
    h.prs(vec![closed("PR_1", true)]);
    h.place(
        &key("PR_1"),
        PlaceTab::Mine,
        Some(Section::Doing),
        None,
        None,
    )
    .unwrap();
    assert_eq!(h.section(Tab::Mine, Section::Doing), ["PR_4", "PR_1"]);
}

#[test]
fn a_closed_pr_of_the_account_found_new_goes_to_mines_done() {
    // DESIGN.md, "Mine": found with its return trigger row; its place
    // before Done is the end of Todo, where a reopen takes it.
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let mention = h.ev("M_2", "PR_2", IngestKind::Mentioned);
    h.push(vec![closed("PR_2", true)], vec![mention], vec![]);
    assert_eq!(h.placement("PR_2"), place("mine", "done", 0));
    h.prs(vec![pr("PR_2")]);
    assert_eq!(h.section(Tab::Mine, Section::Todo), ["PR_1", "PR_2"]);
}

#[test]
fn list_of_review_has_its_four_sections_in_the_screens_order() {
    // DESIGN.md, "Review" and "CLI": Done, Waiting, Doing, Todo, every
    // section with a card.
    let mut h = H::new();
    h.prs(vec![
        other("PR_1"),
        other("PR_2"),
        other("PR_3"),
        other("PR_4"),
    ]);
    for (id, section) in [
        ("PR_1", Section::Todo),
        ("PR_2", Section::Doing),
        ("PR_3", Section::Waiting),
        ("PR_4", Section::Done),
    ] {
        h.place(&key(id), PlaceTab::Review, Some(section), None, None)
            .unwrap();
    }
    assert_eq!(h.tab(Tab::Review), ["PR_4", "PR_3", "PR_2", "PR_1"]);
}
