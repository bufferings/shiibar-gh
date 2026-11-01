//! Rule table: which rows are kept. DESIGN.md, section "How many rows are kept".

mod support;

use serde_json::json;
use shiibar_gh_proto::*;
use support::*;

/// Row descriptions, oldest first: `U` unread event, `R` read event, `O` open
/// needs action row, `D` done row. The strings hold what stays, oldest first.
#[test]
fn pruning_table() {
    let cases = [
        ("three read rows stay", "RRR", "RRR"),
        ("the fourth read row goes", "RRRR", "_RRR"),
        ("only the newest three stay", "RRRRRR", "___RRR"),
        ("done rows share the limit", "DRDR", "_RDR"),
        ("unread rows stay and do not count", "UUUURRR", "UUUURRR"),
        ("open rows stay and do not count", "OOOORRR", "OOOORRR"),
        ("old unread stays below pruned rows", "URRRR", "U_RRR"),
        (
            "open row is not pruned, older read rows are",
            "RRRRO",
            "_RRRO",
        ),
        ("mixed", "RDUORRD", "__UORRD"),
    ];
    for (name, rows, want) in cases {
        let mut h = H::new();
        h.prs(vec![IngestPr {
            state: PrState::Open,
            ..other("PR_1")
        }]);
        let mut seen = vec![];
        for (i, c) in rows.chars().enumerate() {
            let id = format!("E_{i}");
            let kind = if matches!(c, 'O' | 'D') {
                EventKind::Comment
            } else {
                EventKind::Closed
            };
            let e = h.ev(&id, "PR_1", kind);
            h.events(vec![e]);
            if c == 'D' {
                h.engine.done(&id).unwrap();
            }
            if c != 'U' {
                seen.push(id);
            }
        }
        h.engine.seen(&seen);
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
        .map(|i| h.ev_at(&format!("E_{i}"), "PR_1", EventKind::Closed, h.at() + i))
        .collect();
    h.events(events);
    h.seen(&["E_0", "E_1", "E_2", "E_3", "E_4"]);
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
            let e = h.ev(&id, pr_id, EventKind::Closed);
            h.events(vec![e]);
            all.push(id);
        }
    }
    h.engine.seen(&all);
    h.close();
    assert!(all.iter().all(|id| !h.row(id).pruned));
}

#[test]
fn a_pruned_row_is_hidden_and_does_not_come_back_on_refetch() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let events: Vec<_> = (0..4)
        .map(|i| h.ev_at(&format!("E_{i}"), "PR_1", EventKind::Closed, h.at() + i))
        .collect();
    h.events(events.clone());
    h.seen(&["E_0", "E_1", "E_2", "E_3"]);
    h.close();
    assert!(h.wire_row("E_0").is_none());
    h.events(events);
    assert!(h.row("E_0").pruned);
    assert!(h.wire_row("E_0").is_none());
    assert!(not_found(h.engine.open_row("E_0")));
    assert!(not_found(h.engine.done("E_0")));
}

#[test]
fn a_stale_review_request_is_pruned_like_a_read_event_but_unread_stays() {
    let mut h = H::new();
    let e = h.ev("RR", "PR_1", EventKind::ReviewRequested);
    h.push(
        vec![IngestPr {
            requested_me: true,
            ..other("PR_1")
        }],
        vec![e],
        vec![],
    );
    h.prs(vec![other("PR_1")]);
    let events: Vec<_> = (0..3)
        .map(|i| h.ev_at(&format!("E_{i}"), "PR_1", EventKind::Closed, h.at() + i))
        .collect();
    h.events(events);
    h.seen(&["E_0", "E_1", "E_2"]);
    h.close();
    assert!(!h.row("RR").pruned, "unread stays");
    h.seen(&["RR"]);
    h.close();
    assert!(h.row("RR").pruned, "read and stale goes");
}

#[test]
fn hidden_bot_comments_do_not_take_a_slot_and_are_not_pruned() {
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let bot = h.ev("BOT", "PR_1", EventKind::BotComment);
    h.events(vec![bot]);
    h.set("bot_comments", json!("hide"));
    let late = h.ev("BOT2", "PR_1", EventKind::BotComment);
    h.events(vec![late]);
    let events: Vec<_> = (0..3)
        .map(|i| h.ev_at(&format!("E_{i}"), "PR_1", EventKind::Closed, h.at() + i))
        .collect();
    h.events(events);
    h.seen(&["E_0", "E_1", "E_2"]);
    h.close();
    assert!(!h.row("BOT").pruned);
    assert!(!h.row("BOT2").pruned);
    assert!(!h.row("E_0").pruned, "hidden rows take no slot");
}
