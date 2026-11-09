//! Rule table: which rows are kept. DESIGN.md, section "How many rows are kept".

mod support;

use shiibar_gh_proto::*;
use support::*;

/// Row descriptions, oldest first: `U` unread event, `R` read event. The
/// strings hold what stays, oldest first.
#[test]
fn pruning_table() {
    let cases = [
        ("three read rows stay", "RRR", "RRR"),
        ("the fourth read row goes", "RRRR", "_RRR"),
        ("only the newest three stay", "RRRRRR", "___RRR"),
        ("unread rows stay and do not count", "UUUURRR", "UUUURRR"),
        ("old unread stays below pruned rows", "URRRR", "U_RRR"),
        ("mixed", "RRURRUR", "__URRUR"),
    ];
    for (name, rows, want) in cases {
        let mut h = H::new();
        h.prs(vec![IngestPr {
            state: PrState::Open,
            ..other("PR_1")
        }]);
        h.open();
        let mut read = vec![];
        for (i, c) in rows.chars().enumerate() {
            let id = format!("E_{i}");
            let kind = if i % 2 == 0 {
                IngestKind::Comment
            } else {
                IngestKind::Closed
            };
            let e = h.ev(&id, "PR_1", kind);
            h.events(vec![e]);
            if c != 'U' {
                read.push(id);
            }
        }
        let read: Vec<&str> = read.iter().map(String::as_str).collect();
        h.read(&read);
        h.close();
        let got: String = rows
            .chars()
            .enumerate()
            .map(|(i, c)| {
                if h.row(&format!("E_{i}")).pruned {
                    '_'
                } else {
                    c
                }
            })
            .collect();
        assert_eq!(got, want, "{name}");
    }
}

#[test]
fn pruning_runs_on_close_only() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let events: Vec<_> = (0..5)
        .map(|i| h.ev_at(&format!("E_{i}"), "PR_1", IngestKind::Closed, h.at() + i))
        .collect();
    h.events(events);
    h.open();
    h.read(&["E_0", "E_1", "E_2", "E_3", "E_4"]);
    h.tick();
    assert!(!h.row("E_0").pruned);
    h.close();
    assert!(h.row("E_0").pruned);
}

#[test]
fn pruning_is_per_pr() {
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    let mut all = vec![];
    for pr_id in ["PR_1", "PR_2"] {
        for i in 0..3 {
            let id = format!("{pr_id}_{i}");
            let e = h.ev(&id, pr_id, IngestKind::Closed);
            h.events(vec![e]);
            all.push(id);
        }
    }
    let all: Vec<&str> = all.iter().map(String::as_str).collect();
    h.read(&all);
    h.close();
    assert!(all.iter().all(|id| !h.row(id).pruned));
}

#[test]
fn a_pruned_row_is_hidden_and_does_not_come_back_on_refetch() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let events: Vec<_> = (0..4)
        .map(|i| h.ev_at(&format!("E_{i}"), "PR_1", IngestKind::Closed, h.at() + i))
        .collect();
    h.events(events.clone());
    h.read(&["E_0", "E_1", "E_2", "E_3"]);
    h.close();
    assert!(h.wire_row("E_0").is_none());
    h.events(events);
    assert!(h.row("E_0").pruned);
    assert!(h.wire_row("E_0").is_none());
    assert!(not_found(h.engine.open_row(None, &full("E_0"))));
}

#[test]
fn a_read_review_request_is_pruned_like_any_row_but_unread_stays() {
    // DESIGN.md, "Review requested rows": a record like any other row.
    let mut h = H::new();
    let e = h.ev("RR", "PR_1", IngestKind::ReviewRequested);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_1")
        }],
        vec![e],
        vec![],
    );
    let events: Vec<_> = (0..3)
        .map(|i| h.ev_at(&format!("E_{i}"), "PR_1", IngestKind::Closed, h.at() + i))
        .collect();
    h.events(events);
    h.read(&["E_0", "E_1", "E_2"]);
    h.close();
    assert!(!h.row("RR").pruned, "unread stays");
    h.read(&["RR"]);
    h.close();
    assert!(h.row("RR").pruned, "read and older goes");
    // DESIGN.md, "Awaiting review": the request still counts.
    assert_eq!(h.badge(), 1);
    assert!(h.card(&key("PR_1")).unwrap().awaiting_review);
    h.tick();
    h.prs(vec![IngestPr {
        requested_me: true,
        ..other("PR_1")
    }]);
    assert!(h.row("RR").pruned, "across a pass and a fetch");
}

#[test]
fn hidden_rows_do_not_take_a_slot_and_are_not_pruned() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let mut bot = h.ev("BOT", "PR_1", IngestKind::Closed);
    // GraphQL spells a bot without `[bot]` (DESIGN.md, "Exclusions").
    bot.actor = Some("renovate".into());
    h.events(vec![bot]);
    // DESIGN.md, "Exclusions": a Hidden user's rows are recorded, not shown.
    h.exclude(ExclusionKind::User, "renovate", ExclusionState::Hidden);
    let events: Vec<_> = (0..3)
        .map(|i| h.ev_at(&format!("E_{i}"), "PR_1", IngestKind::Closed, h.at() + i))
        .collect();
    h.events(events);
    h.read(&["BOT", "E_0", "E_1", "E_2"]);
    h.close();
    assert!(!h.row("BOT").pruned);
    assert!(!h.row("E_0").pruned, "hidden rows take no slot");
}

#[test]
fn a_reopened_pr_awaits_review_again_without_bringing_rows_back() {
    // 0.2 brought a pruned request row back as Todo; 0.3 judges the PR.
    let mut h = H::new();
    let requested = IngestPr {
        requested_me: true,
        ..other("PR_1")
    };
    let e = h.ev("RR", "PR_1", IngestKind::ReviewRequested);
    h.push(vec![requested.clone()], vec![e], vec![]);
    h.prs(vec![IngestPr {
        state: PrState::Closed,
        ..requested.clone()
    }]);
    assert_eq!(h.badge(), 0, "closed");
    let events: Vec<_> = (0..3)
        .map(|i| h.ev_at(&format!("E_{i}"), "PR_1", IngestKind::Closed, h.at() + i))
        .collect();
    h.events(events);
    h.read(&["RR", "E_0", "E_1", "E_2"]);
    h.close();
    assert!(h.row("RR").pruned);
    h.prs(vec![requested]);
    assert!(h.row("RR").pruned, "the row stays pruned");
    assert_eq!(h.badge(), 1, "reopened and still requested");
}
