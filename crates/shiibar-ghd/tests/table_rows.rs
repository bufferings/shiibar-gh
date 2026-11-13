//! Rule table: the rows of 0.4. DESIGN.md, sections "Rows in a card",
//! "State change rows" (Checks as settled results), "Merged, Closed and
//! Reopened rows", "Comment and Reply sources" and "Applying the table".

mod support;

use shiibar_gh_proto::*;
use support::*;

fn comments(h: &H, range: std::ops::Range<i64>) -> Vec<IngestEvent> {
    range
        .map(|n| h.ev_at(&format!("E_{n:02}"), "PR_1", IngestKind::Comment, T0 + n))
        .collect()
}

// ------------------------------------------------------------ 20 rows

#[test]
fn the_newest_20_rows_stay_and_older_ones_leave_their_ids() {
    let mut h = H::new();
    h.set_time(T0 + 100);
    let first = comments(&h, 0..21);
    h.push(vec![pr("PR_1")], first.clone(), vec![]);
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.rows.len(), 20);
    assert!(card.older_rows);
    assert!(!h.has_row("E_00"), "the oldest went, unread as it was");
    assert!(h.engine.row_deleted(&full("E_00")));
    assert!(not_found(h.engine.read(&[full("E_00")])));
    // The same event fetched again makes no row.
    h.events(vec![first[0].clone()]);
    assert!(!h.has_row("E_00"));
    assert!(
        !h.card(&key("PR_1"))
            .unwrap()
            .rows
            .iter()
            .any(|r| short(&r.id) == "E_00")
    );
    // A card with 20 rows or fewer has nothing older.
    h.prs(vec![pr("PR_2")]);
    assert!(!h.card(&key("PR_2")).unwrap().older_rows);
}

#[test]
fn rows_recorded_with_their_list_off_are_not_counted() {
    // DESIGN.md, "Applying the table": not in the 20, `+ N more` or
    // `older_rows` while the List is off.
    let mut h = H::new();
    h.table(EventKind::MergedClosed, EventColumn::List, false);
    h.set_time(T0 + 100);
    let mut events = comments(&h, 0..20);
    events.push(h.ev_at("MG_1", "PR_1", IngestKind::Merged, T0 + 50));
    h.push(vec![pr("PR_1")], events, vec![]);
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.rows.len(), 20);
    assert!(!card.older_rows);
    assert!(h.has_row("MG_1"), "recorded");
    assert!(!h.row("MG_1").unread);
    assert!(!h.row("MG_1").listed);
}

#[test]
fn rows_recorded_with_their_list_off_are_capped_among_themselves() {
    // DESIGN.md, "Rows in a card": at most 20 of them per PR, the oldest
    // dropped, so what is kept stays bounded.
    let mut h = H::new();
    h.table(EventKind::Comment, EventColumn::List, false);
    h.set_time(T0 + 100);
    let mut events = comments(&h, 0..25);
    events.push(h.ev_at("M_1", "PR_1", IngestKind::Mentioned, T0 + 1));
    h.push(vec![pr("PR_1")], events, vec![]);
    assert!(!h.has_row("E_04"), "the oldest hidden rows went");
    assert!(h.engine.row_deleted(&full("E_04")));
    assert!(h.has_row("E_05"));
    assert!(h.has_row("E_24"));
    assert!(h.has_row("M_1"), "the shown rows are counted apart");
    h.table(EventKind::Comment, EventColumn::List, true);
    let card = h.card(&key("PR_1")).unwrap();
    assert_eq!(card.rows.len(), 20);
    assert!(card.older_rows, "rows of the PR were deleted");
}

// ------------------------------------------------------------- Checks

#[test]
fn checks_rows_compare_settled_results() {
    // DESIGN.md, "State change rows": (name, the Checks values and head
    // commits each status fetch sees, the rows made after the first).
    use Checks::*;
    type Step = (Checks, &'static str);
    let cases: [(&str, &[Step], &[&str]); 9] = [
        (
            "running when found, then passed",
            &[(InProgress, "a"), (Passed, "a")],
            &["checks_passed"],
        ),
        ("passed when found", &[(Passed, "a"), (Passed, "a")], &[]),
        (
            "failed, then passed",
            &[(Passed, "a"), (Failed, "a"), (Passed, "a")],
            &["checks_failed", "checks_passed"],
        ),
        (
            "failed again after a fix was pushed",
            &[(Failed, "a"), (InProgress, "b"), (Failed, "b")],
            &["checks_failed"],
        ),
        (
            "failed again, the run not seen between",
            &[(Failed, "a"), (Failed, "b")],
            &["checks_failed"],
        ),
        (
            "passed again on a new commit, the run not seen between",
            &[(Passed, "a"), (Passed, "b")],
            &[],
        ),
        (
            "passed, a run, passed",
            &[(Passed, "a"), (InProgress, "b"), (Passed, "b")],
            &[],
        ),
        (
            "failed, a run, failed on the same commit",
            &[(Failed, "a"), (InProgress, "a"), (Failed, "a")],
            &["checks_failed"],
        ),
        (
            "no checks, then passed",
            &[(None, "a"), (Passed, "a")],
            &["checks_passed"],
        ),
    ];
    for (name, steps, want) in cases {
        let mut h = H::new();
        for (checks, head) in steps.iter() {
            h.prs(vec![IngestPr {
                checks: *checks,
                head_oid: Some(head.to_string()),
                ..pr("PR_1")
            }]);
        }
        let mut kinds: Vec<String> = h
            .card(&key("PR_1"))
            .unwrap()
            .rows
            .iter()
            .map(|r| r.kind.as_text())
            .collect();
        kinds.reverse();
        assert_eq!(kinds, want.to_vec(), "{name}");
    }
}

#[test]
fn mergeable_takes_the_place_of_checks_passed() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        checks: Checks::InProgress,
        ..pr("PR_1")
    }]);
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        mergeable: true,
        ..pr("PR_1")
    }]);
    let kinds: Vec<String> = h
        .card(&key("PR_1"))
        .unwrap()
        .rows
        .iter()
        .map(|r| r.kind.as_text())
        .collect();
    assert_eq!(kinds, ["mergeable"]);
    // The result is settled all the same: no Checks passed after.
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    assert_eq!(h.card(&key("PR_1")).unwrap().rows.len(), 1);
}

#[test]
fn a_watch_start_and_a_return_only_keep_the_values() {
    // DESIGN.md, "State change rows": no row at those times.
    let mut h = H::new();
    h.prs(vec![IngestPr {
        checks: Checks::Failed,
        ..pr("PR_1")
    }]);
    let org = h.owner_id(ORG);
    h.engine.owner_enable(&org, false, &h.now.clone());
    h.engine.owner_enable(&org, true, &h.now.clone());
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    assert!(h.card(&key("PR_1")).unwrap().rows.is_empty(), "watch start");
    h.dismiss(&key("PR_1")).unwrap();
    h.restore(&key("PR_1")).unwrap();
    h.prs(vec![IngestPr {
        checks: Checks::Failed,
        ..pr("PR_1")
    }]);
    assert!(h.card(&key("PR_1")).unwrap().rows.is_empty(), "return");
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    let kinds: Vec<String> = h
        .card(&key("PR_1"))
        .unwrap()
        .rows
        .iter()
        .map(|r| r.kind.as_text())
        .collect();
    assert_eq!(kinds, ["checks_passed"], "a failure saved at the return");
}

#[test]
fn checks_passed_opens_the_checks_and_has_no_body() {
    let mut h = H::new();
    h.prs(vec![IngestPr {
        checks: Checks::Failed,
        ..pr("PR_1")
    }]);
    h.prs(vec![IngestPr {
        checks: Checks::Passed,
        ..pr("PR_1")
    }]);
    let row = &h.card(&key("PR_1")).unwrap().rows[0];
    assert!(row.kind.is(RowKind::ChecksPassed));
    assert_eq!(row.text, None);
    assert_eq!(row.url, "https://github.example/PR_1/c");
    let n = h.delivered();
    assert_eq!(n[0].title, "me · Checks passed");
}

// ----------------------------------------------- Merged, Closed, Reopened

#[test]
fn the_closed_event_paired_with_a_merge_makes_no_row() {
    // (name, events as (kind, at), the row ids made)
    type Ev = (&'static str, IngestKind, i64);
    let cases: [(&str, &[Ev], &[&str]); 4] = [
        (
            "merged and closed at the same time",
            &[
                ("CL", IngestKind::Closed, T0 + 5),
                ("MG", IngestKind::Merged, T0 + 5),
            ],
            &["MG"],
        ),
        (
            "closed after the merge",
            &[
                ("MG", IngestKind::Merged, T0 + 5),
                ("CL", IngestKind::Closed, T0 + 6),
            ],
            &["MG"],
        ),
        (
            "closed, reopened, then merged",
            &[
                ("CL", IngestKind::Closed, T0 + 2),
                ("RO", IngestKind::Reopened, T0 + 3),
                ("MG", IngestKind::Merged, T0 + 5),
            ],
            &["CL", "RO", "MG"],
        ),
        (
            "closed alone",
            &[("CL", IngestKind::Closed, T0 + 5)],
            &["CL"],
        ),
    ];
    for (name, events, want) in cases {
        let mut h = H::new();
        h.prs(vec![other("PR_1")]);
        h.set_time(T0 + 10);
        let events: Vec<IngestEvent> = events
            .iter()
            .map(|(id, kind, at)| h.ev_at(id, "PR_1", *kind, *at))
            .collect();
        h.events(events);
        for id in ["CL", "RO", "MG"] {
            assert_eq!(h.has_row(id), want.contains(&id), "{name}: {id}");
        }
    }
    // The pair arriving in a later fetch makes no row either.
    let mut h = H::new();
    h.prs(vec![other("PR_1")]);
    let merged = h.ev_at("MG", "PR_1", IngestKind::Merged, T0 + 5);
    h.events(vec![merged]);
    let closed = h.ev_at("CL", "PR_1", IngestKind::Closed, T0 + 5);
    h.events(vec![closed]);
    assert!(!h.has_row("CL"));
}

#[test]
fn a_reopen_is_a_row_and_my_own_is_read_and_quiet() {
    let mut h = H::new();
    h.prs(vec![other("PR_1"), other("PR_2")]);
    let theirs = h.ev("RO_1", "PR_1", IngestKind::Reopened);
    let mut mine = h.ev("RO_2", "PR_2", IngestKind::Reopened);
    mine.actor = Some("ME".into());
    h.events(vec![theirs, mine]);
    assert!(h.row("RO_1").unread);
    assert!(!h.row("RO_2").unread);
    let out = h.delivered();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].title, "me · Reopened");
    assert_eq!(out[0].rows, [full("RO_1")]);
}

#[test]
fn a_comment_on_someone_elses_pr_has_its_own_kind_and_table_line() {
    let mut h = H::new();
    let e = h.ev("C_1", "PR_1", IngestKind::CommentOther);
    h.push(vec![other("PR_1")], vec![e], vec![]);
    let row = &h.card(&key("PR_1")).unwrap().rows[0];
    assert!(row.kind.is(RowKind::CommentOther));
    assert_eq!(h.delivered()[0].title, "me · Comment on other PRs");
    h.table(EventKind::CommentOther, EventColumn::List, false);
    assert!(h.card(&key("PR_1")).unwrap().rows.is_empty());
    let cell = h.engine.owner_events(&h.owner_id(ORG))["comment_other"];
    assert!(!cell.list && !cell.notify);
}

#[test]
fn the_defaults_of_the_new_kinds() {
    // DESIGN.md, "Row kinds and states": List and Notify on.
    let h = H::new();
    let events = h.engine.owner_events(&h.owner_id(ORG));
    for kind in ["comment_other", "checks_passed", "reopened"] {
        assert!(events[kind].list && events[kind].notify, "{kind}");
    }
}
