//! Rule table: PRs awaiting the account's review, `awaiting_review` and
//! `review_count`. DESIGN.md, sections "Awaiting review", "Card states" and
//! "What the filters mean".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::engine::ListArgs;
use support::*;

/// Who asks for the review in the request rows of the table.
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
    /// A Review requested row (of the request's kind) at this time.
    row_at: Option<i64>,
    /// The account's newest review.
    reviewed_at: Option<i64>,
    /// Off: the team kind's List, or the account kind's List.
    list_off: Option<EventKind>,
    /// An Exclusion of the user who asked.
    asker: Option<ExclusionState>,
    want: bool,
}

const fn case(name: &'static str, request: Request, row_at: Option<i64>, want: bool) -> Case {
    Case {
        name,
        request,
        row_at,
        reviewed_at: None,
        list_off: None,
        asker: None,
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
            asker: Some(ExclusionState::ListOnly),
            ..case(
                "a recorded-only row still names the asker",
                Request::Me,
                Some(T0),
                false,
            )
        },
        Case {
            asker: Some(ExclusionState::Hidden),
            ..case("the asker is Hidden", Request::Me, Some(T0), false)
        },
        Case {
            asker: Some(ExclusionState::ListOnly),
            ..case("the asker is List only", Request::Me, Some(T0), false)
        },
        Case {
            asker: Some(ExclusionState::ListOnly),
            ..case(
                "the team's asker is List only",
                Request::Team,
                Some(T0),
                false,
            )
        },
        Case {
            asker: Some(ExclusionState::Hidden),
            ..case("no row: the asker is unknown", Request::Me, None, true)
        },
    ];
    for c in cases {
        let mut h = H::new();
        if let Some(kind) = c.list_off {
            h.table(kind, EventColumn::List, false);
        }
        if let Some(state) = c.asker {
            h.exclude(ExclusionKind::User, ASKER, state);
        }
        let pr = IngestPr {
            requested_me: matches!(c.request, Request::Me),
            requested_team: matches!(c.request, Request::Team),
            my_review_at: c.reviewed_at,
            ..other("PR_1")
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
        assert_eq!(h.badge(), u32::from(c.want), "{}: account", c.name);
        assert_eq!(
            h.owner(ORG).review_count,
            u32::from(c.want),
            "{}: owner",
            c.name
        );
    }
}

/// A PR asking the account for a review, with a request row of `alice`.
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
fn the_badge_counts_prs_not_rows() {
    let mut h = H::new();
    let a = h.ev("E_1", "PR_1", IngestKind::ReviewRequested);
    let b = h.ev("E_2", "PR_1", IngestKind::Mentioned);
    let c = h.ev("E_3", "PR_2", IngestKind::Comment);
    h.push(
        vec![
            IngestPr {
                requested_me: true,
                ..other("PR_1")
            },
            other("PR_2"),
        ],
        vec![a, b, c],
        vec![],
    );
    assert_eq!(h.badge(), 1);
    assert_eq!(h.awaiting_ids(), ["PR_1"]);
}

#[test]
fn awaiting_review_is_apart_from_the_read_state() {
    // DESIGN.md, "How unread goes away": reading the Review requested row
    // keeps the mark and the number.
    let mut h = H::new();
    asked(&mut h, "PR_1");
    h.read(&["RR_PR_1"]);
    h.open();
    h.close();
    assert!(h.card(&key("PR_1")).unwrap().awaiting_review);
    assert_eq!(h.badge(), 1);
    assert!(h.visible("PR_1"), "a PR awaiting review keeps its card");
}

#[test]
fn the_request_ends_when_github_drops_it_and_comes_back_when_asked_again() {
    let mut h = H::new();
    asked(&mut h, "PR_1");
    assert_eq!(h.badge(), 1);
    h.prs(vec![other("PR_1")]);
    assert_eq!(h.badge(), 0, "the request was withdrawn");
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
    assert_eq!(h.badge(), 1, "asked again after the review");
}

#[test]
fn snoozed_unreadable_hidden_closed_and_disabled_never_count() {
    type Change = fn(&mut H);
    let cases: [(&str, Change); 5] = [
        ("snoozed", |h| h.snooze(&key("PR_1"))),
        ("unreadable", |h| h.missing("PR_1")),
        ("Hidden repository", |h| {
            h.exclude(ExclusionKind::Repo, "org/app", ExclusionState::Hidden)
        }),
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
        assert_eq!(h.badge(), 1, "{name}: before");
        change(&mut h);
        assert_eq!(h.badge(), 0, "{name}");
        assert_eq!(h.owner(ORG).review_count, 0, "{name}: owner");
        assert!(h.awaiting_ids().is_empty(), "{name}: card");
    }
}

#[test]
fn the_account_number_is_the_sum_of_its_owners() {
    let mut h = H::new();
    asked(&mut h, "PR_1");
    let e = h.ev("RR_2", "PR_2", IngestKind::ReviewRequested);
    h.push(
        vec![IngestPr {
            owner: "stranger".into(),
            requested_me: true,
            ..other("PR_2")
        }],
        vec![e],
        vec![],
    );
    assert_eq!(h.owner(ORG).review_count, 1);
    assert_eq!(h.owner("public").review_count, 1);
    assert_eq!(h.badge(), 2);
}

#[test]
fn the_filter_is_github_s_request_and_the_mark_is_this_app_s() {
    // DESIGN.md, "What the filters mean": the Review requested filter does
    // not look at the Exclusions; the mark does.
    let mut h = H::new();
    h.exclude(ExclusionKind::User, ASKER, ExclusionState::ListOnly);
    asked(&mut h, "PR_1");
    let card = h.card(&key("PR_1")).unwrap();
    assert!(card.review_requested);
    assert!(!card.awaiting_review);
    let filtered = h.card_ids(ListArgs {
        filter: PrFilter::ReviewRequested,
        ..ListArgs::default()
    });
    assert_eq!(filtered, ["PR_1"]);
}

#[test]
fn the_newest_request_row_decides_even_when_pruned() {
    // The asker of the newest request row decides, after it was pruned; an
    // older row of another user does not.
    let mut h = H::new();
    h.exclude(ExclusionKind::User, "renovate", ExclusionState::ListOnly);
    let old = h.ev_at("RR_1", "PR_1", IngestKind::ReviewRequested, T0);
    let mut new = h.ev_at("RR_2", "PR_1", IngestKind::ReviewRequested, T0 + 5);
    new.actor = Some("renovate".into());
    let later: Vec<IngestEvent> = (6..9)
        .map(|n| h.ev_at(&format!("E_{n}"), "PR_1", IngestKind::Comment, T0 + n))
        .collect();
    h.set_time(T0 + 10);
    let mut events = vec![old, new];
    events.extend(later);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_1")
        }],
        events,
        vec![],
    );
    h.read(&["RR_1", "RR_2", "E_6", "E_7", "E_8"]);
    h.close();
    assert!(h.row("RR_2").pruned, "the newest request row is pruned");
    assert_eq!(h.badge(), 0, "renovate asked last");
    h.include(ExclusionKind::User, "renovate");
    assert_eq!(h.badge(), 1, "the pruned row still decides");
}

/// A request to the account is judged by the account's request rows, a
/// request to a team by the team's rows; they never stand in for each
/// other.
#[test]
fn requests_to_me_and_to_my_team_are_judged_apart() {
    // (requested_me, requested_team, the asker of my row, the asker of the
    // team row, want)
    let cases = [
        (true, false, "renovate", "alice", false),
        (false, true, "renovate", "alice", true),
        (false, true, "alice", "renovate", false),
        (true, false, "alice", "renovate", true),
        (true, true, "renovate", "alice", true),
        (true, true, "alice", "renovate", true),
        (true, true, "renovate", "renovate", false),
    ];
    for (me, team, my_asker, team_asker, want) in cases {
        let mut h = H::new();
        h.exclude(ExclusionKind::User, "renovate", ExclusionState::ListOnly);
        let mut mine = h.ev_at("RR_ME", "PR_1", IngestKind::ReviewRequested, T0);
        mine.actor = Some(my_asker.into());
        let mut ours = h.ev_at("RR_TEAM", "PR_1", IngestKind::TeamReviewRequested, T0 + 1);
        ours.actor = Some(team_asker.into());
        h.set_time(T0 + 10);
        h.push(
            vec![IngestPr {
                requested_me: me,
                requested_team: team,
                ..other("PR_1")
            }],
            vec![mine, ours],
            vec![],
        );
        assert_eq!(
            h.badge(),
            u32::from(want),
            "me {me}, team {team}, {my_asker}/{team_asker}"
        );
    }
}
