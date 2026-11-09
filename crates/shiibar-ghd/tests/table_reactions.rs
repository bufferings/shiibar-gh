//! Rule table: Reaction rows. DESIGN.md, section "Reaction rows".

mod support;

use shiibar_gh_proto::*;
use shiibar_ghd::engine::ActivityArgs;
use std::collections::BTreeMap;
use support::*;

type Counts = &'static [(&'static str, u32)];

struct Step {
    counts: Counts,
    watching: bool,
    /// The rows this fetch makes: (kind, delta).
    want: Counts,
}

const fn w(counts: Counts, want: Counts) -> Step {
    Step {
        counts,
        watching: true,
        want,
    }
}

const fn outside(counts: Counts) -> Step {
    Step {
        counts,
        watching: false,
        want: &[],
    }
}

const UP: &str = "THUMBS_UP";
const TADA: &str = "HOORAY";

#[test]
fn reaction_table_for_a_comment_posted_after_the_watch_started() {
    let cases: &[(&str, &[Step])] = &[
        ("first fetch counts from zero", &[w(&[(UP, 2)], &[(UP, 2)])]),
        ("first fetch with nothing", &[w(&[], &[])]),
        (
            "increase is the delta",
            &[w(&[(UP, 2)], &[(UP, 2)]), w(&[(UP, 5)], &[(UP, 3)])],
        ),
        (
            "no change",
            &[w(&[(UP, 2)], &[(UP, 2)]), w(&[(UP, 2)], &[])],
        ),
        (
            "a decrease makes no row",
            &[w(&[(UP, 2)], &[(UP, 2)]), w(&[(UP, 1)], &[])],
        ),
        (
            "removed and added again is new",
            &[
                w(&[(UP, 1)], &[(UP, 1)]),
                w(&[], &[]),
                w(&[(UP, 1)], &[(UP, 1)]),
            ],
        ),
        (
            "each kind that grew has a row",
            &[w(&[(UP, 1), (TADA, 1)], &[(TADA, 1), (UP, 1)])],
        ),
        (
            "one up, one down",
            &[
                w(&[(UP, 2), (TADA, 2)], &[(TADA, 2), (UP, 2)]),
                w(&[(UP, 4), (TADA, 1)], &[(UP, 2)]),
            ],
        ),
        (
            "outside the watch window is not a row",
            &[outside(&[(UP, 3)])],
        ),
        (
            "the count when watching returns is the baseline",
            &[
                w(&[(UP, 1)], &[(UP, 1)]),
                outside(&[(UP, 4)]),
                w(&[(UP, 4)], &[]),
                w(&[(UP, 5)], &[(UP, 1)]),
            ],
        ),
    ];
    for (name, steps) in cases {
        let mut h = H::new();
        h.prs(vec![pr("PR_1")]);
        let created = h.at();
        for step in *steps {
            let before: Vec<_> = reaction_rows(&h);
            let mut r = h.reaction("C_1", "PR_1", step.counts);
            r.comment_created_at = created;
            r.watching = step.watching;
            h.push(vec![], vec![], vec![r]);
            let new: Vec<(String, u32)> = reaction_rows(&h)
                .into_iter()
                .filter(|row| !before.iter().any(|b| b.id == row.id))
                .flat_map(|row| row.counts.unwrap().into_iter().collect::<Vec<_>>())
                .collect();
            let mut new: BTreeMap<String, u32> = new.into_iter().collect();
            let want: BTreeMap<String, u32> =
                step.want.iter().map(|(k, v)| (k.to_string(), *v)).collect();
            assert_eq!(std::mem::take(&mut new), want, "{name}");
        }
    }
}

fn reaction_rows(h: &H) -> Vec<Row> {
    h.activity(ActivityArgs::default())
        .into_iter()
        .filter(|r| r.kind == Lenient::Known(RowKind::Reaction))
        .collect()
}

#[test]
fn first_fetch_of_a_comment_posted_before_the_watch_started_takes_the_count_as_baseline() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let mut r = h.reaction("C_1", "PR_1", &[(UP, 2)]);
    r.comment_created_at = T0 - 1;
    h.push(vec![], vec![], vec![r.clone()]);
    assert!(reaction_rows(&h).is_empty());
    r.counts.insert(UP.into(), 3);
    h.push(vec![], vec![], vec![r]);
    let rows = reaction_rows(&h);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].counts.as_ref().unwrap()[UP], 1);
}

#[test]
fn a_comment_posted_exactly_at_the_watch_start_counts_from_zero() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let mut r = h.reaction("C_1", "PR_1", &[(UP, 2)]);
    r.comment_created_at = T0;
    h.push(vec![], vec![], vec![r]);
    assert_eq!(reaction_rows(&h).len(), 1);
}

#[test]
fn a_row_carries_the_comment_and_the_detection_time() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let at = h.at();
    let r = h.reaction("C_1", "PR_1", &[(UP, 2)]);
    h.push(vec![], vec![], vec![r]);
    let row = &reaction_rows(&h)[0];
    assert_eq!(row.occurred_at, at);
    assert_eq!(row.text.as_deref(), Some("comment C_1"));
    assert_eq!(row.url, "https://github.example/C_1");
    assert_eq!(row.actor, None);
    assert!(row.unread);
    assert!(
        row.id.starts_with("1001:")
            && row.id.contains("C_1")
            && row.id.contains(UP)
            && row.id.contains(&at.to_string())
    );
}

#[test]
fn counts_reset_when_the_watch_restarts() {
    let mut h = H::new();
    h.prs(vec![pr("PR_1")]);
    let mut r = h.reaction("C_1", "PR_1", &[(UP, 1)]);
    r.comment_created_at = T0 + 20;
    h.push(vec![], vec![], vec![r.clone()]);
    let owner = h.owner_id(ORG);
    h.engine.owner_enable(&owner, false, &h.now);
    h.advance(100);
    h.engine.owner_enable(&owner, true, &h.now);
    // Posted before the new watch started: the fetched count is the baseline.
    r.counts.insert(UP.into(), 9);
    let before = reaction_rows(&h).len();
    h.push(vec![pr("PR_1")], vec![], vec![r.clone()]);
    assert_eq!(reaction_rows(&h).len(), before);
    r.counts.insert(UP.into(), 10);
    h.push(vec![], vec![], vec![r]);
    assert_eq!(reaction_rows(&h).len(), before + 1);
}
