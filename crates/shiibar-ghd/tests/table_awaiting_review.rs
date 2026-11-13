//! Rule table: PRs awaiting the account's review (`awaiting_review`).
//! DESIGN.md, sections "Awaiting review", "Card states" and "What the
//! filters mean".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::engine::ListArgs;
use support::*;

/// Who asks for the review in the request rows of the table, and the author
/// of the PR.
const ASKER: &str = "alice";

/// The request of a row in a case.
#[derive(Clone, Copy)]
enum Request {
    /// GitHub lists no request now.
    None,
    Me,
    Team,
}

struct Case {
    name: &'static str,
    request: Request,
    /// A Review requested event (of the request's kind) at this time.
    row_at: Option<i64>,
    /// The account's newest review.
    reviewed_at: Option<i64>,
    /// Off: the team kind's List, or the account kind's List.
    list_off: Option<EventKind>,
    /// The author is muted.
    muted: bool,
    /// The account's own PR.
    mine: bool,
    want: bool,
}

const fn case(name: &'static str, request: Request, row_at: Option<i64>, want: bool) -> Case {
    Case {
        name,
        request,
        row_at,
        reviewed_at: None,
        list_off: None,
        muted: false,
        mine: false,
        want,
    }
}

#[test]
fn awaiting_review_table() {
    let cases = [
        case("nothing requested", Request::None, None, false),
        case("requested from me, with a row", Request::Me, Some(T0), true),
        // DESIGN.md, "Awaiting review": neither the row nor its List decides
        // a request to the account.
        case("requested from me, no row", Request::Me, None, true),
        Case {
            list_off: Some(EventKind::ReviewRequested),
            ..case(
                "requested from me, Review requested List off",
                Request::Me,
                Some(T0),
                true,
            )
        },
        case("requested from my team", Request::Team, Some(T0), true),
        case("requested from my team, no row", Request::Team, None, true),
        Case {
            list_off: Some(EventKind::TeamReviewRequested),
            ..case("my team, team List off", Request::Team, Some(T0), false)
        },
        Case {
            reviewed_at: Some(T0 + 5),
            ..case("I reviewed after the request", Request::Me, Some(T0), false)
        },
        Case {
            reviewed_at: Some(T0 + 5),
            ..case(
                "I reviewed after the team request",
                Request::Team,
                Some(T0),
                false,
            )
        },
        Case {
            reviewed_at: Some(T0 - 5),
            ..case(
                "requested again after my review",
                Request::Me,
                Some(T0),
                true,
            )
        },
        Case {
            reviewed_at: Some(T0 - 5),
            ..case("no row and a review of mine", Request::Me, None, false)
        },
        Case {
            reviewed_at: Some(T0),
            ..case(
                "a review in the same second is not after the request",
                Request::Me,
                Some(T0),
                true,
            )
        },
        Case {
            list_off: Some(EventKind::ReviewRequested),
            reviewed_at: Some(T0 + 5),
            ..case(
                "a request recorded without a row still dates the request",
                Request::Me,
                Some(T0 + 8),
                true,
            )
        },
        Case {
            muted: true,
            ..case("Mute plays no part", Request::Me, Some(T0), true)
        },
        Case {
            mine: true,
            ..case("my own PR", Request::Me, Some(T0), false)
        },
        Case {
            mine: true,
            ..case("my own PR, a team request", Request::Team, Some(T0), false)
        },
    ];
    for c in cases {
        let mut h = H::new();
        if let Some(kind) = c.list_off {
            h.table(kind, EventColumn::List, false);
        }
        if c.muted {
            h.mute(MuteKind::User, ASKER);
        }
        let pr = IngestPr {
            requested_me: matches!(c.request, Request::Me),
            requested_team: matches!(c.request, Request::Team),
            my_review_at: c.reviewed_at,
            ..if c.mine { pr("PR_1") } else { other("PR_1") }
        };
        let events = match (c.row_at, c.request) {
            (Some(at), Request::Team) => {
                vec![h.ev_at("RR_1", "PR_1", IngestKind::TeamReviewRequested, at)]
            }
            (Some(at), _) => vec![h.ev_at("RR_1", "PR_1", IngestKind::ReviewRequested, at)],
            (None, _) => vec![],
        };
        h.set_time(T0 + 10);
        h.push(vec![pr], events, vec![]);
        let card = h.card(&key("PR_1"));
        assert_eq!(
            card.as_ref().is_some_and(|c| c.awaiting_review),
            c.want,
            "{}: card",
            c.name
        );
    }
}

/// A PR asking the account for a review, with a request row.
fn asked(h: &mut H, id: &str) {
    let e = h.ev(&format!("RR_{id}"), id, IngestKind::ReviewRequested);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other(id)
        }],
        vec![e],
        vec![],
    );
}

#[test]
fn awaiting_review_is_apart_from_the_read_state() {
    // DESIGN.md, "How unread rows go away": reading the Review requested row
    // keeps the mark.
    let mut h = H::new();
    asked(&mut h, "PR_1");
    h.read(&["RR_PR_1"]);
    h.open();
    h.close();
    assert!(h.card(&key("PR_1")).unwrap().awaiting_review);
}

#[test]
fn the_request_ends_when_github_drops_it_and_comes_back_when_asked_again() {
    let mut h = H::new();
    asked(&mut h, "PR_1");
    assert_eq!(h.awaiting_ids(), ["PR_1"]);
    h.prs(vec![other("PR_1")]);
    assert!(h.awaiting_ids().is_empty(), "the request was withdrawn");
    let e = h.ev("RR_2", "PR_1", IngestKind::ReviewRequested);
    h.push(
        vec![IngestPr {
            requested_me: true,
            my_review_at: Some(h.at() - 100),
            ..other("PR_1")
        }],
        vec![e],
        vec![],
    );
    assert_eq!(h.awaiting_ids(), ["PR_1"], "asked again after the review");
}

#[test]
fn unreadable_closed_and_disabled_never_await() {
    type Change = fn(&mut H);
    let cases: [(&str, Change); 3] = [
        ("unreadable", |h| h.missing("PR_1")),
        ("closed", |h| {
            h.prs(vec![IngestPr {
                requested_me: true,
                state: PrState::Closed,
                ..other("PR_1")
            }])
        }),
        ("disabled owner", |h| {
            let owner = h.owner_id(ORG);
            h.engine.owner_enable(&owner, false, &h.now.clone());
        }),
    ];
    for (name, change) in cases {
        let mut h = H::new();
        asked(&mut h, "PR_1");
        assert_eq!(h.awaiting_ids(), ["PR_1"], "{name}: before");
        change(&mut h);
        assert!(h.awaiting_ids().is_empty(), "{name}");
    }
}

#[test]
fn the_filter_is_github_s_request_and_the_mark_is_this_app_s() {
    // DESIGN.md, "What the filters mean": the Review requested filter is
    // GitHub's request; the mark is the review still owed.
    let mut h = H::new();
    let e = h.ev_at("RR_1", "PR_1", IngestKind::ReviewRequested, T0);
    h.set_time(T0 + 10);
    h.push(
        vec![IngestPr {
            requested_me: true,
            my_review_at: Some(T0 + 5),
            ..other("PR_1")
        }],
        vec![e],
        vec![],
    );
    let card = h.card(&key("PR_1")).unwrap();
    assert!(card.review_requested);
    assert!(!card.awaiting_review);
    let filtered = h.card_ids(ListArgs {
        filter: PrFilter::ReviewRequested,
        ..ListArgs::default()
    });
    assert_eq!(filtered, ["PR_1"]);
}

/// DESIGN.md, "Awaiting review": the time of the newest request is kept
/// apart from the rows, so a request that made no row still dates it.
#[test]
fn the_newest_request_time_moves_without_a_row() {
    type Setup = fn(&mut H);
    let cases: [(&str, Setup); 4] = [
        ("List off", |h| {
            h.table(EventKind::ReviewRequested, EventColumn::List, false)
        }),
        ("dismissed", |h| {
            h.dismiss(&key("PR_1")).unwrap();
        }),
        ("team List off, a team request", |h| {
            h.table(EventKind::TeamReviewRequested, EventColumn::List, false)
        }),
        ("the row was deleted", |_| {}),
    ];
    for (name, setup) in cases {
        let mut h = H::new();
        // Requested at T0+2, reviewed at T0+5: not awaiting.
        let first = h.ev_at("RR_1", "PR_1", IngestKind::ReviewRequested, T0 + 2);
        h.set_time(T0 + 10);
        let asked = IngestPr {
            requested_me: true,
            my_review_at: Some(T0 + 5),
            ..other("PR_1")
        };
        h.push(vec![asked.clone()], vec![first], vec![]);
        assert!(
            !h.engine
                .pr_record(&full("PR_1"))
                .unwrap()
                .dismissed_at
                .is_some()
        );
        setup(&mut h);
        if name == "the row was deleted" {
            // 20 newer rows push the request row out.
            let newer: Vec<IngestEvent> = (0..20)
                .map(|n| h.ev_at(&format!("E_{n}"), "PR_1", IngestKind::Comment, T0 + 20 + n))
                .collect();
            h.events(newer);
            assert!(!h.has_row("RR_1"), "{name}: deleted");
        }
        // Asked again at T0+8, after the review.
        let kind = if name.starts_with("team") {
            IngestKind::TeamReviewRequested
        } else {
            IngestKind::ReviewRequested
        };
        let again = h.ev_at("RR_2", "PR_1", kind, T0 + 8);
        let pr = IngestPr {
            requested_team: name.starts_with("team"),
            ..asked
        };
        h.push(vec![pr], vec![again], vec![]);
        assert_eq!(
            h.engine.pr_record(&full("PR_1")).unwrap().last_request_at,
            Some(T0 + 8),
            "{name}"
        );
        let shown = h
            .engine
            .pr_record(&full("PR_1"))
            .and_then(|pr| {
                let owner = h.engine.owner_record(&h.owner_id(ORG))?;
                Some(h.engine.awaiting_review(pr, owner))
            })
            .unwrap();
        assert!(shown, "{name}: awaiting again");
    }
}

#[test]
fn a_request_older_than_the_watch_still_dates_the_request() {
    // DESIGN.md, "Awaiting review": every fetched request event updates it.
    let mut h = H::new();
    let old = h.ev_at("RR_1", "PR_1", IngestKind::ReviewRequested, T0 - DAY);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_1")
        }],
        vec![old],
        vec![],
    );
    assert_eq!(
        h.engine.pr_record(&full("PR_1")).unwrap().last_request_at,
        Some(T0 - DAY)
    );
}
