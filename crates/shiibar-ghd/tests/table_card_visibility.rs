//! Rule table: when a card shows. DESIGN.md, sections "Overview and scope"
//! (the basic idea), "When cards show, and watching", "Card states" and the
//! card header.

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::engine::{ActivityArgs, ListArgs};
use shiibar_ghd::model::OwnerKind;
use support::*;

#[derive(Clone, Copy)]
struct Case {
    name: &'static str,
    mine: bool,
    state: PrState,
    draft: bool,
    /// Days since the PR was last updated.
    age: i64,
    /// Make a row of this kind, read unless `unread`.
    row: Option<IngestKind>,
    unread: bool,
    requested: bool,
    dismissed: bool,
    unreadable: bool,
    disabled: bool,
    /// In All.
    want: bool,
}

const BASE: Case = Case {
    name: "",
    mine: false,
    state: PrState::Open,
    draft: false,
    age: 0,
    row: None,
    unread: false,
    requested: false,
    dismissed: false,
    unreadable: false,
    disabled: false,
    want: true,
};

fn run(c: Case) {
    let mut h = H::new();
    let base = if c.mine { pr("PR_1") } else { other("PR_1") };
    h.prs(vec![base.clone()]);
    if let Some(kind) = c.row {
        let e = h.ev("E_1", "PR_1", kind);
        h.events(vec![e]);
    }
    if c.row.is_some() && !c.unread {
        h.read(&["E_1"]);
    }
    if c.dismissed {
        h.dismiss(&key("PR_1")).unwrap();
    }
    h.prs(vec![IngestPr {
        state: c.state,
        is_draft: c.draft,
        requested_me: c.requested,
        updated_at: T0 - c.age * DAY,
        ..base
    }]);
    if c.unreadable {
        h.missing("PR_1");
    }
    if c.disabled {
        let owner = h.owner_id(ORG);
        h.engine.owner_enable(&owner, false, &h.now);
    }
    h.advance(c.age.max(1) * DAY / 2);
    let shown = h.visible("PR_1");
    assert_eq!(shown, c.want, "{}", c.name);
    // DESIGN.md, "Dismissed list": only a dismissed card that can show.
    let listed = h
        .dismissed_cards()
        .iter()
        .any(|card| short(&card.id) == "PR_1");
    assert_eq!(
        listed,
        c.dismissed && !c.unreadable && !c.disabled,
        "{} in the Dismissed list",
        c.name
    );
}

#[test]
fn card_table() {
    // DESIGN.md, "Overview and scope": only a Dismiss takes a card out of the
    // lists; reading, age, Draft and the state do not.
    let cases = [
        Case {
            name: "own open PR",
            mine: true,
            ..BASE
        },
        Case {
            name: "someone else's open PR, old and read",
            age: 60,
            row: Some(IngestKind::Comment),
            ..BASE
        },
        Case {
            name: "someone else's Draft",
            draft: true,
            ..BASE
        },
        Case {
            name: "merged, every row read",
            state: PrState::Merged,
            row: Some(IngestKind::Merged),
            ..BASE
        },
        Case {
            name: "closed, no rows",
            state: PrState::Closed,
            ..BASE
        },
        Case {
            name: "awaiting review",
            requested: true,
            ..BASE
        },
        Case {
            name: "unread row",
            row: Some(IngestKind::Mentioned),
            unread: true,
            ..BASE
        },
        Case {
            name: "dismissed",
            dismissed: true,
            want: false,
            ..BASE
        },
        Case {
            name: "dismissed with an unread row",
            dismissed: true,
            row: Some(IngestKind::Comment),
            unread: true,
            want: false,
            ..BASE
        },
        Case {
            name: "unreadable",
            unreadable: true,
            row: Some(IngestKind::Mentioned),
            unread: true,
            want: false,
            ..BASE
        },
        Case {
            name: "unreadable and dismissed",
            unreadable: true,
            dismissed: true,
            want: false,
            ..BASE
        },
        Case {
            name: "disabled owner",
            disabled: true,
            want: false,
            ..BASE
        },
        Case {
            name: "disabled owner, dismissed",
            disabled: true,
            dismissed: true,
            want: false,
            ..BASE
        },
    ];
    for case in cases {
        run(case);
    }
}

#[test]
fn state_label_table() {
    let cases = [
        (PrState::Merged, true, true, StateLabel::Merged),
        (PrState::Closed, true, true, StateLabel::Closed),
        (PrState::Open, true, true, StateLabel::Draft),
        (PrState::Open, false, true, StateLabel::Mergeable),
        (PrState::Open, false, false, StateLabel::Open),
    ];
    for (state, is_draft, mergeable, want) in cases {
        let mut h = H::new();
        h.prs(vec![pr("PR_1")]);
        let e = h.ev("E_1", "PR_1", IngestKind::Merged);
        h.push(
            vec![IngestPr {
                state,
                is_draft,
                mergeable,
                ..pr("PR_1")
            }],
            vec![e],
            vec![],
        );
        let card = h.card(&key("PR_1")).unwrap();
        assert_eq!(card.state_label, Lenient::Known(want), "{state:?}");
    }
}

#[test]
fn list_puts_open_prs_first_then_the_newest_update_with_ties_by_id() {
    // DESIGN.md, "CLI": `Recently updated` within an owner, open PRs first.
    let mut h = H::new();
    let at = |id: &str, updated_at| IngestPr {
        updated_at,
        ..pr(id)
    };
    h.prs(vec![at("PR_2", T0 + 5), at("PR_1", T0 + 5)]);
    h.prs(vec![at("PR_3", T0 + 1), at("PR_4", T0 + 9)]);
    h.prs(vec![at("PR_5", T0)]);
    let merged = IngestPr {
        state: PrState::Merged,
        updated_at: T0 + 20,
        ..pr("PR_5")
    };
    let e = h.ev("E_5", "PR_5", IngestKind::Merged);
    h.push(vec![merged], vec![e], vec![]);
    assert_eq!(
        h.card_ids(ListArgs::default()),
        ["PR_4", "PR_1", "PR_2", "PR_3", "PR_5"]
    );
}

#[test]
fn added_at_is_when_the_card_first_showed_and_never_moves() {
    // DESIGN.md, "When cards show, and watching": Restore and a return do
    // not change it.
    let mut h = H::new();
    let added = h.at();
    let draft = IngestPr {
        is_draft: true,
        ..other("PR_1")
    };
    h.prs(vec![draft]);
    assert!(h.visible("PR_1"), "a Draft of someone else shows too");
    assert_eq!(h.card(&key("PR_1")).unwrap().added_at, Some(added));

    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    assert_eq!(h.card(&key("PR_1")).unwrap().added_at, Some(added));

    h.dismiss(&key("PR_1")).unwrap();
    h.restore(&key("PR_1")).unwrap();
    assert_eq!(h.card(&key("PR_1")).unwrap().added_at, Some(added));
    h.dismiss(&key("PR_1")).unwrap();
    let mention = h.ev("E_2", "PR_1", IngestKind::Mentioned);
    h.events(vec![mention]);
    assert!(h.visible("PR_1"), "back by a mention");
    assert_eq!(h.card(&key("PR_1")).unwrap().added_at, Some(added));
}

#[test]
fn an_old_pr_never_drops_out() {
    // DESIGN.md, "Dismiss": the 0.3 rule of 14 days without an update is
    // gone.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    h.advance(90 * DAY);
    h.tick();
    assert!(h.visible("PR_1"));
}

#[test]
fn an_unreadable_pr_comes_back_with_its_state() {
    let mut h = H::new();
    let e = h.ev("E_1", "PR_1", IngestKind::Comment);
    h.push(vec![pr("PR_1")], vec![e], vec![]);
    let added = h.card(&key("PR_1")).unwrap().added_at;
    h.read(&["E_1"]);
    h.missing("PR_1");
    assert!(!h.visible("PR_1"));
    assert!(not_found(h.engine.status(ME, &key("PR_1"), &h.now)));
    assert!(not_found(h.dismiss(&key("PR_1"))));
    h.prs(vec![pr("PR_1")]);
    assert!(h.visible("PR_1"));
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.added_at, added);
    assert!(!card.rows[0].unread);
}

#[test]
fn a_pr_absent_from_an_ingest_is_unchanged() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    h.prs(vec![pr("PR_2")]);
    assert!(h.visible("PR_1"));
}

#[test]
fn activity_shows_only_rows_of_shown_cards_newest_first_ties_by_id() {
    let mut h = H::new();
    let at = h.at();
    let a = h.ev_at("E_2", "PR_1", IngestKind::Comment, at);
    let b = h.ev_at("E_1", "PR_2", IngestKind::Comment, at);
    let c = h.ev_at("E_3", "PR_1", IngestKind::Comment, at + 5);
    h.push(vec![pr("PR_1"), pr("PR_2")], vec![a, b, c], vec![]);
    let rows = h.activity(ActivityArgs::default());
    assert_eq!(ids(&rows), ["E_3", "E_1", "E_2"]);
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(ids(&card.rows), ["E_3", "E_2"]);

    // DESIGN.md, "CLI activity": no rows of a dismissed PR.
    h.dismiss(&key("PR_1")).unwrap();
    let rows = h.activity(ActivityArgs::default());
    assert_eq!(ids(&rows), ["E_1"]);
}

#[test]
fn the_authored_by_me_filter() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1"), other("PR_2")]);
    let authored = ListArgs {
        filter: PrFilter::Authored,
        ..ListArgs::default()
    };
    assert_eq!(h.card_ids(authored), ["PR_1"]);
    assert_eq!(h.card_ids(ListArgs::default()).len(), 2);
}

#[test]
fn sections_follow_the_registration_order_with_public_last() {
    let mut h = H::new();
    h.engine
        .owner_add(ACCOUNT, "later", OwnerKind::Org, None, &h.now)
        .unwrap();
    let public = IngestPr {
        owner: "elsewhere".into(),
        ..other("PR_1")
    };
    let later = IngestPr {
        owner: "later".into(),
        ..other("PR_2")
    };
    h.prs(vec![public]);
    h.prs(vec![later]);
    h.prs(vec![other("PR_3")]);
    // org, later, then Public, whatever the order the cards came in.
    assert_eq!(h.card_ids(ListArgs::default()), ["PR_3", "PR_2", "PR_1"]);
    let names: Vec<String> = h.account().owners.into_iter().map(|o| o.name).collect();
    assert_eq!(names, ["org", "later", "Public"]);
}

// ---------------------------------------------------------------- search

/// DESIGN.md, "What the filters mean": the examples the Swift tests share.
#[test]
fn search_follows_the_examples_of_the_design() {
    let mut h = H::new();
    let example = IngestPr {
        owner: "example-org".into(),
        repo: "api".into(),
        number: 407,
        title: "Retry the upload".into(),
        author: "alice".into(),
        base: "main".into(),
        head: "fix/retry".into(),
        ..other("PR_407")
    };
    let mut row = h.ev("E_1", "PR_407", IngestKind::Comment);
    row.actor = Some("bob".into());
    row.text = Some("Looks good to me".into());
    h.push(vec![example, other("PR_2")], vec![row], vec![]);
    let found = |h: &H, text: &str| {
        let mut ids = h.card_ids(ListArgs {
            search: Some(text.into()),
            ..ListArgs::default()
        });
        ids.sort();
        ids
    };
    // (text, matches example-org/api#407)
    let cases = [
        ("api 407", true),
        ("#407", true),
        ("api #407", true),
        ("API", true),
        ("example-org/api#407", true),
        ("retry upload", true),
        ("ALICE", true),
        ("fix/retry", true),
        ("good bob", true),
        ("api #408", false),
        ("nobody", false),
    ];
    for (text, matches) in cases {
        assert_eq!(
            found(&h, text).contains(&"PR_407".to_string()),
            matches,
            "{text}"
        );
    }
    assert_eq!(found(&h, "  "), ["PR_2", "PR_407"], "blank is no search");
    assert_eq!(found(&h, ""), ["PR_2", "PR_407"]);
    // Activity hides rows: the PR's fields or the row's own text and actor.
    let rows = |text: &str| {
        ids(&h.activity(ActivityArgs {
            search: Some(text.into()),
            ..ActivityArgs::default()
        }))
    };
    assert_eq!(rows("api #407"), ["E_1"]);
    assert_eq!(rows("bob"), ["E_1"]);
    assert!(rows("bob PR_2").is_empty());
}
