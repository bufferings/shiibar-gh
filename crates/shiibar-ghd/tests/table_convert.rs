//! GitHub answers to `Ingest` values. Every table reads GraphQL or REST JSON
//! and checks the `Ingest` piece it becomes. docs/tasks/M2.md, "PR values",
//! "Failed check names", "Event kinds" and "Collecting a newly found PR";
//! DESIGN.md (M4), "Row kind decisions".

use serde_json::{Value, json};
use shiibar_gh_proto::{BaseStatus, Checks, IngestKind as EventKind, Review};
use shiibar_ghd::convert::{self, Ctx, EventInput, StatusExtra};
use shiibar_ghd::model::{self, OwnComment, TeamRec, ThreadRec};
use std::collections::{BTreeMap, BTreeSet};

const ME: &str = "me";
/// 2027-01-15T08:00:00Z
const T0: i64 = 1_800_000_000;

fn iso(at: i64) -> String {
    shiibar_ghd::github::format_time(at)
}

fn teams() -> Vec<TeamRec> {
    vec![TeamRec {
        database_id: 42,
        slug: "core".into(),
    }]
}

fn ctx(teams: &[TeamRec]) -> Ctx<'_> {
    Ctx { viewer: ME, teams }
}

fn user(login: &str) -> Value {
    json!({"__typename":"User","login":login})
}

fn bot(login: &str) -> Value {
    json!({"__typename":"Bot","login":login})
}

fn reviews(list: &[(&str, &str)]) -> Value {
    json!({"nodes": list.iter().map(|(state, who)| json!({"state":state,"author":{"login":who}})).collect::<Vec<_>>()})
}

// ------------------------------------------------------------- PR values

#[test]
fn changes_requested_by_names_the_first_reviewer_and_counts_the_rest() {
    let cases = [
        (vec![], None),
        (vec![("APPROVED", "a")], None),
        (vec![("CHANGES_REQUESTED", "alice")], Some("alice")),
        (
            vec![
                ("CHANGES_REQUESTED", "alice"),
                ("APPROVED", "x"),
                ("CHANGES_REQUESTED", "bob"),
            ],
            Some("alice +1"),
        ),
        (
            vec![
                ("CHANGES_REQUESTED", "a"),
                ("CHANGES_REQUESTED", "b"),
                ("CHANGES_REQUESTED", "c"),
            ],
            Some("a +2"),
        ),
    ];
    for (list, expect) in cases {
        assert_eq!(
            convert::changes_requested_by(&reviews(&list)).as_deref(),
            expect,
            "{list:?}"
        );
    }
}

#[test]
fn review_comes_from_the_decision_else_from_the_latest_reviews() {
    let cases = [
        (json!("APPROVED"), vec![], Review::Approved),
        (json!("CHANGES_REQUESTED"), vec![], Review::ChangesRequested),
        (
            json!("REVIEW_REQUIRED"),
            vec![("APPROVED", "a")],
            Review::ReviewRequired,
        ),
        (json!(null), vec![], Review::None),
        (json!(null), vec![("APPROVED", "a")], Review::Approved),
        (
            json!(null),
            vec![("APPROVED", "a"), ("CHANGES_REQUESTED", "b")],
            Review::ChangesRequested,
        ),
        (json!(null), vec![("COMMENTED", "a")], Review::None),
    ];
    for (decision, list, expect) in cases {
        assert_eq!(
            convert::review_value(&decision, &reviews(&list)),
            expect,
            "{decision} {list:?}"
        );
    }
}

#[test]
fn checks_follow_the_rollup_state() {
    let cases = [
        (json!({"state":"SUCCESS"}), Checks::Passed),
        (json!({"state":"PENDING"}), Checks::InProgress),
        (json!({"state":"EXPECTED"}), Checks::InProgress),
        (json!({"state":"FAILURE"}), Checks::Failed),
        (json!({"state":"ERROR"}), Checks::Failed),
        (json!(null), Checks::None),
    ];
    for (rollup, expect) in cases {
        assert_eq!(convert::checks_value(&rollup), expect, "{rollup}");
    }
}

#[test]
fn base_and_mergeable_from_mergeable_merge_state_and_behind_by() {
    use model::BaseStatus as Stored;
    type Case = (
        &'static str,
        &'static str,
        Option<i64>,
        Option<(Stored, bool)>,
        (BaseStatus, bool),
    );
    let cases: [Case; 10] = [
        (
            "MERGEABLE",
            "CLEAN",
            Some(0),
            None,
            (BaseStatus::UpToDate, true),
        ),
        (
            "MERGEABLE",
            "BEHIND",
            Some(3),
            None,
            (BaseStatus::Behind, false),
        ),
        (
            "MERGEABLE",
            "BLOCKED",
            Some(0),
            None,
            (BaseStatus::UpToDate, false),
        ),
        (
            "CONFLICTING",
            "DIRTY",
            Some(2),
            None,
            (BaseStatus::Conflicts, false),
        ),
        (
            "CONFLICTING",
            "DIRTY",
            None,
            None,
            (BaseStatus::Conflicts, false),
        ),
        // behindBy unreadable: Conflicts or blank.
        ("MERGEABLE", "CLEAN", None, None, (BaseStatus::None, true)),
        // UNKNOWN keeps both previous values.
        (
            "UNKNOWN",
            "UNKNOWN",
            Some(0),
            Some((Stored::Behind, true)),
            (BaseStatus::Behind, true),
        ),
        (
            "UNKNOWN",
            "UNKNOWN",
            None,
            Some((Stored::Conflicts, false)),
            (BaseStatus::Conflicts, false),
        ),
        // UNKNOWN on a PR seen for the first time: blank and not mergeable.
        (
            "UNKNOWN",
            "UNKNOWN",
            Some(0),
            None,
            (BaseStatus::None, false),
        ),
        ("UNKNOWN", "CLEAN", Some(0), None, (BaseStatus::None, false)),
    ];
    for (mergeable, state, behind, previous, expect) in cases {
        assert_eq!(
            convert::base_values(mergeable, state, behind, previous),
            expect,
            "{mergeable} {state} {behind:?} {previous:?}"
        );
    }
}

fn status_node(patch: Value) -> Value {
    let mut node = json!({
        "id":"PR_1","number":7,"url":"https://github.com/org/app/pull/7","title":"Fix",
        "state":"OPEN","isDraft":false,"updatedAt":iso(T0),"isCrossRepository":false,
        "author":user(ME),"repository":{"name":"app","isPrivate":true,"owner":{"login":"Org"}},
        "baseRefName":"main","headRefName":"fix","headRefOid":"abc",
        "reviewDecision":null,"latestOpinionatedReviews":{"nodes":[]},
        "statusCheckRollup":{"state":"FAILURE"},"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",
        "reviewRequests":{"nodes":[]}
    });
    for (key, value) in patch.as_object().unwrap() {
        node[key] = value.clone();
    }
    node
}

#[test]
fn a_status_node_becomes_an_ingest_pr() {
    let t = teams();
    let extra = StatusExtra {
        behind_by: Some(2),
        failed_check: Some("build +1".into()),
        ..StatusExtra::default()
    };
    let pr = convert::pr_values(&status_node(json!({})), &extra, ctx(&t)).unwrap();
    assert_eq!(pr.id, "PR_1");
    assert_eq!(
        (pr.owner.as_str(), pr.repo.as_str(), pr.number),
        ("Org", "app", 7)
    );
    assert_eq!(pr.author, "me");
    assert_eq!(pr.author_avatar_url, None, "no avatarUrl in the answer");
    assert_eq!((pr.base.as_str(), pr.head.as_str()), ("main", "fix"));
    assert_eq!(pr.state, shiibar_gh_proto::PrState::Open);
    assert_eq!(pr.checks, Checks::Failed);
    assert_eq!(pr.base_status, BaseStatus::Behind);
    assert!(!pr.mergeable);
    assert_eq!(pr.failed_check.as_deref(), Some("build +1"));
    assert_eq!(pr.updated_at, T0);
    assert!(pr.is_private);
    assert_eq!(pr.links.checks, "https://github.com/org/app/pull/7/checks");
    assert_eq!(pr.links.review, pr.url);
    assert_eq!(pr.links.base, pr.url);
}

#[test]
fn a_deleted_author_is_an_empty_login() {
    let t = teams();
    let pr = convert::pr_values(
        &status_node(json!({"author":null})),
        &StatusExtra::default(),
        ctx(&t),
    )
    .unwrap();
    assert_eq!(pr.author, "");
    assert_eq!(pr.author_avatar_url, None);
}

#[test]
fn the_author_avatar_comes_from_avatar_url() {
    let t = teams();
    let author = json!({"__typename":"User","login":"alice",
        "avatarUrl":"https://avatars.githubusercontent.com/u/1?s=32&v=4"});
    let pr = convert::pr_values(
        &status_node(json!({ "author": author })),
        &StatusExtra::default(),
        ctx(&t),
    )
    .unwrap();
    assert_eq!(
        pr.author_avatar_url.as_deref(),
        Some("https://avatars.githubusercontent.com/u/1?s=32&v=4")
    );
}

#[test]
fn states_become_lowercase() {
    let t = teams();
    for (state, expect) in [
        ("OPEN", shiibar_gh_proto::PrState::Open),
        ("MERGED", shiibar_gh_proto::PrState::Merged),
        ("CLOSED", shiibar_gh_proto::PrState::Closed),
    ] {
        let pr = convert::pr_values(
            &status_node(json!({"state":state})),
            &StatusExtra::default(),
            ctx(&t),
        )
        .unwrap();
        assert_eq!(pr.state, expect);
    }
}

#[test]
fn review_requests_split_the_viewer_and_the_viewers_teams() {
    let t = teams();
    let request = |reviewer: Value| json!({"requestedReviewer": reviewer});
    let cases = [
        (vec![request(user("ME"))], (true, false)),
        (vec![request(user("alice"))], (false, false)),
        (
            vec![request(
                json!({"__typename":"Team","databaseId":42,"slug":"core"}),
            )],
            (false, true),
        ),
        (
            vec![request(
                json!({"__typename":"Team","databaseId":7,"slug":"other"}),
            )],
            (false, false),
        ),
        (
            vec![request(json!({"__typename":"Bot","login":"x"}))],
            (false, false),
        ),
        (vec![request(json!(null))], (false, false)),
    ];
    for (nodes, (me, team)) in cases {
        let r = convert::requested(&json!({"nodes": nodes}), ctx(&t));
        assert_eq!((r.me, r.team), (me, team), "{nodes:?}");
    }
}

#[test]
fn assignees_come_from_the_assignees_connection() {
    let t = teams();
    let node =
        status_node(json!({"assignees":{"nodes":[{"login":"me"},{"login":"bob"},{"login":null}]}}));
    let pr = convert::pr_values(&node, &StatusExtra::default(), ctx(&t)).unwrap();
    assert_eq!(pr.assignees, ["me", "bob"]);
    let none =
        convert::pr_values(&status_node(json!({})), &StatusExtra::default(), ctx(&t)).unwrap();
    assert!(none.assignees.is_empty());
}

// ------------------------------------------------------ failed check names

fn job(name: &str, conclusion: Value) -> Value {
    json!({"name":name,"status":"completed","conclusion":conclusion})
}

#[test]
fn failed_check_names_come_from_jobs_then_commit_statuses() {
    let runs = json!({"workflow_runs":[
        {"id":1,"event":"pull_request"},
        {"id":2,"event":"dynamic"},
        {"id":3,"event":"push"}
    ]});
    let jobs = vec![
        (
            1,
            json!({"jobs":[
                job("lint", json!("success")),
                job("build", json!("failure")),
                job("docs", json!("skipped")),
                job("slow", json!(null)),
                job("flaky", json!("neutral")),
            ]}),
        ),
        (2, json!({"jobs":[job("Copilot review", json!("failure"))]})),
        (
            3,
            json!({"jobs":[job("deploy", json!("cancelled")), job("e2e", json!("timed_out"))]}),
        ),
    ];
    let contexts = json!({"nodes":[
        {"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"},
        {"__typename":"StatusContext","context":"ci/pending","state":"PENDING"},
        {"__typename":"StatusContext","context":"ci/expected","state":"EXPECTED"},
        {"__typename":"StatusContext","context":"ci/error","state":"ERROR"},
        null
    ]});
    assert_eq!(
        convert::failed_check_name(&runs, &jobs, &contexts).as_deref(),
        Some("build +4"),
        "build, deploy, e2e, ci/legacy, ci/error; dynamic left out"
    );
    assert_eq!(convert::runs_to_read(&runs), [1, 3]);
}

#[test]
fn failed_check_name_cases() {
    let none = json!(null);
    let cases = [
        // Only a Commit status failed.
        (
            json!({"workflow_runs":[]}),
            vec![],
            json!({"nodes":[{"context":"ci/x","state":"ERROR"}]}),
            Some("ci/x"),
        ),
        // One job, nothing else.
        (
            json!({"workflow_runs":[{"id":9,"event":"pull_request"}]}),
            vec![(9, json!({"jobs":[job("test", json!("action_required"))]}))],
            none.clone(),
            Some("test"),
        ),
        // Nothing named: no text.
        (json!(null), vec![], none.clone(), None),
        (
            json!({"workflow_runs":[{"id":9,"event":"pull_request"}]}),
            vec![(9, json!({"jobs":[job("test", json!("success"))]}))],
            none.clone(),
            None,
        ),
    ];
    for (runs, jobs, contexts, expect) in cases {
        assert_eq!(
            convert::failed_check_name(&runs, &jobs, &contexts).as_deref(),
            expect,
            "{runs}"
        );
    }
}

// ---------------------------------------------------------------- events

struct Pr {
    node: Value,
    timeline: Vec<Value>,
    threads: Vec<Value>,
    queue: Option<Vec<Value>>,
    since: i64,
    recorded: BTreeMap<String, ThreadRec>,
}

impl Pr {
    /// Record a thread: the time of my first comment, of the first mention.
    fn record(&mut self, id: &str, mine_at: Option<i64>, mention_at: Option<i64>) {
        self.recorded.insert(
            id.into(),
            ThreadRec {
                id: id.into(),
                pr_id: "PR_1".into(),
                mine_at,
                mention_at,
            },
        );
    }

    fn new(author: Value) -> Self {
        Self {
            node: json!({"id":"PR_1","url":"https://github.com/o/r/pull/1","author":author,
                         "bodyHTML":"","bodyText":"","createdAt":iso(T0 - 86_400)}),
            timeline: vec![],
            threads: vec![],
            queue: None,
            since: T0,
            recorded: BTreeMap::new(),
        }
    }

    fn mine() -> Self {
        Self::new(user(ME))
    }

    fn others() -> Self {
        Self::new(user("alice"))
    }

    fn run(&self) -> convert::EventOutput {
        let t = teams();
        convert::events(
            &EventInput {
                pr: &self.node,
                timeline: &self.timeline,
                threads: &self.threads,
                merge_queue: self.queue.as_deref(),
                since: self.since,
                zero_after: T0,
                recorded: &self.recorded,
            },
            ctx(&t),
        )
    }

    fn kinds(&self) -> Vec<(String, EventKind)> {
        self.run()
            .events
            .into_iter()
            .map(|e| (e.id, e.kind))
            .collect()
    }
}

fn comment(id: &str, author: Value, at: i64, html: &str) -> Value {
    json!({"__typename":"IssueComment","id":id,"url":format!("https://c/{id}"),
           "createdAt":iso(at),"bodyText":format!("text {id}"),"bodyHTML":html,"author":author})
}

fn review(id: &str, author: Value, at: i64, state: &str, body: &str) -> Value {
    json!({"__typename":"PullRequestReview","id":id,"url":format!("https://r/{id}"),
           "createdAt":iso(at - 30),"submittedAt":iso(at),"state":state,
           "bodyText":body,"bodyHTML":body,"author":author})
}

fn thread(id: &str, comments: Vec<Value>) -> Value {
    json!({"id":id,"comments":{"nodes":comments}})
}

fn inline(id: &str, author: Value, at: i64, html: &str) -> Value {
    json!({"id":id,"url":format!("https://i/{id}"),"createdAt":iso(at),
           "bodyText":format!("text {id}"),"bodyHTML":html,"author":author})
}

fn mention_link(login: &str) -> String {
    format!(
        "<p>hi <a class=\"user-mention notranslate\" data-hovercard-type=\"user\" href=\"https://github.com/{login}\">@{login}</a></p>"
    )
}

fn team_link(id: i64) -> String {
    format!(
        "<p><a class=\"team-mention js-team-mention notranslate\" data-id=\"{id}\" href=\"https://github.com/orgs/o/teams/core\">@o/core</a></p>"
    )
}

#[test]
fn comment_kinds_by_author_and_pr() {
    use EventKind::*;
    // (PR is mine, author, row)
    let cases = [
        (true, user("alice"), Some(Comment)),
        // DESIGN.md: a bot is judged like anyone.
        (true, bot("ci[bot]"), Some(Comment)),
        (true, user(ME), None),
        (true, user("Me"), None),
        (false, user("alice"), None),
        (false, bot("ci[bot]"), None),
    ];
    for (mine, author, expect) in cases {
        let mut pr = if mine { Pr::mine() } else { Pr::others() };
        pr.timeline = vec![comment("C_1", author.clone(), T0 + 10, "")];
        let got: Vec<EventKind> = pr.kinds().into_iter().map(|(_, k)| k).collect();
        assert_eq!(
            got,
            expect.into_iter().collect::<Vec<_>>(),
            "{mine} {author}"
        );
    }
}

#[test]
fn review_bodies_on_my_pr() {
    use EventKind::*;
    let cases: [(&str, &str, &[EventKind]); 6] = [
        ("APPROVED", "LGTM", &[Approved, Comment]),
        ("APPROVED", "", &[Approved]),
        ("CHANGES_REQUESTED", "Please fix", &[Comment]),
        ("CHANGES_REQUESTED", "  ", &[]),
        ("COMMENTED", "Hm", &[Comment]),
        ("PENDING", "draft", &[]),
    ];
    for (state, body, expect) in cases {
        let mut pr = Pr::mine();
        pr.timeline = vec![review("R_1", user("alice"), T0 + 10, state, body)];
        let got: Vec<EventKind> = pr.kinds().into_iter().map(|(_, k)| k).collect();
        assert_eq!(got, expect, "{state} {body:?}");
    }
}

#[test]
fn an_approved_row_per_approving_review_by_someone_else_on_my_pr() {
    // (PR is mine, reviewer, approved rows)
    let cases = [
        (true, user("alice"), 1),
        (true, bot("ci[bot]"), 1),
        (true, user(ME), 0),
        (false, user("alice"), 0),
    ];
    for (mine, author, expect) in cases {
        let mut pr = if mine { Pr::mine() } else { Pr::others() };
        pr.timeline = vec![
            review("R_1", author.clone(), T0 + 10, "APPROVED", ""),
            review("R_2", author.clone(), T0 + 20, "APPROVED", ""),
        ];
        let events = pr.run().events;
        let approved: Vec<_> = events
            .iter()
            .filter(|e| e.kind == EventKind::Approved)
            .collect();
        assert_eq!(approved.len(), expect * 2, "{mine} {author}");
        if let Some(first) = approved.first() {
            assert_eq!(first.id, "R_1");
            assert_eq!(first.url, "https://r/R_1");
            assert_eq!(first.text, None, "an Approved row has no body");
            assert_eq!(first.actor.as_deref(), author["login"].as_str());
        }
    }
}

#[test]
fn inline_comments_on_my_pr_are_comments_one_row_each() {
    let mut pr = Pr::mine();
    pr.threads = vec![thread(
        "T_1",
        vec![
            inline("I_1", user("alice"), T0 + 10, ""),
            inline("I_2", user("bob"), T0 + 20, ""),
        ],
    )];
    assert_eq!(
        pr.kinds(),
        [
            ("I_1".to_string(), EventKind::Comment),
            ("I_2".to_string(), EventKind::Comment)
        ]
    );
}

#[test]
fn events_before_since_make_no_row() {
    let mut pr = Pr::mine();
    pr.timeline = vec![
        comment("OLD", user("alice"), T0 - 1, ""),
        comment("NEW", user("alice"), T0, ""),
    ];
    pr.threads = vec![thread(
        "T",
        vec![inline("I_OLD", user("alice"), T0 - 5, "")],
    )];
    assert_eq!(pr.kinds(), [("NEW".to_string(), EventKind::Comment)]);
}

#[test]
fn a_team_mention_link_of_my_team_is_a_mention() {
    let mut pr = Pr::others();
    pr.timeline = vec![
        comment("C_1", user("alice"), T0 + 10, &team_link(42)),
        comment("C_2", user("alice"), T0 + 20, &team_link(7)),
        comment(
            "C_3",
            user("alice"),
            T0 + 30,
            "<p>@o/core in plain text</p>",
        ),
    ];
    pr.threads = vec![thread(
        "T_1",
        vec![inline("I_1", user("bob"), T0 + 40, &team_link(42))],
    )];
    assert_eq!(
        pr.kinds(),
        [
            ("C_1".to_string(), EventKind::TeamMentioned),
            ("I_1".to_string(), EventKind::TeamMentioned)
        ]
    );
}

#[test]
fn a_mention_of_me_and_my_team_is_mentioned_only() {
    let mut pr = Pr::others();
    let html = format!("{}{}", mention_link(ME), team_link(42));
    pr.timeline = vec![comment("C_1", user("alice"), T0 + 10, &html)];
    assert_eq!(pr.kinds(), [("C_1".to_string(), EventKind::Mentioned)]);
}

#[test]
fn a_team_mention_in_the_body_of_a_new_pr_is_a_mention() {
    let mut pr = Pr::others();
    pr.node["createdAt"] = json!(iso(T0 + 5));
    pr.node["bodyHTML"] = json!(team_link(42));
    pr.node["bodyText"] = json!("cc team");
    let e = pr.run().events.remove(0);
    assert_eq!(e.id, "PR_1:mention");
    assert_eq!(e.kind, EventKind::TeamMentioned);
    assert_eq!(e.text.as_deref(), Some("cc team"));
    pr.node["createdAt"] = json!(iso(T0 - 5));
    assert!(
        pr.run().events.is_empty(),
        "an older PR body is outside the window"
    );
}

#[test]
fn mention_links_are_read_from_the_html() {
    assert!(convert::mentions_user(&mention_link("Me"), "me"));
    assert!(!convert::mentions_user(&mention_link("meme"), "me"));
    assert!(!convert::mentions_user("<p>@me</p>", "me"));
    assert!(!convert::mentions_user(&mention_link("me"), ""));
    assert_eq!(convert::mentioned_teams(&team_link(42)), [42]);
    assert!(convert::mentioned_teams("<a class=\"user-mention\" data-id=\"3\">x</a>").is_empty());
}

#[test]
fn replies_count_in_recorded_threads_after_their_start() {
    use EventKind::*;
    // (my first comment, first mention, reply time, PR is mine, row)
    let cases = [
        (None, None, T0 + 10, false, None),
        (None, None, T0 + 10, true, Some(Comment)),
        (Some(T0 - 100), None, T0 + 10, false, Some(Reply)),
        (Some(T0 - 100), None, T0 + 10, true, Some(Reply)),
        (None, Some(T0 - 100), T0 + 10, false, Some(ReplyMentioned)),
        (None, Some(T0 - 100), T0 + 10, true, Some(ReplyMentioned)),
        // Both: a thread I commented in wins.
        (Some(T0 - 50), Some(T0 - 100), T0 + 10, false, Some(Reply)),
        // Only comments after the start count.
        (None, Some(T0 + 10), T0 + 10, false, None),
        (Some(T0 + 20), None, T0 + 10, false, None),
        (
            Some(T0 + 20),
            Some(T0 - 100),
            T0 + 10,
            false,
            Some(ReplyMentioned),
        ),
    ];
    for (mine_at, mention_at, at, mine, expect) in cases {
        let mut pr = if mine { Pr::mine() } else { Pr::others() };
        if mine_at.is_some() || mention_at.is_some() {
            pr.record("T_1", mine_at, mention_at);
        }
        pr.threads = vec![thread("T_1", vec![inline("I_1", user("alice"), at, "")])];
        let got: Vec<EventKind> = pr.kinds().into_iter().map(|(_, k)| k).collect();
        assert_eq!(
            got,
            expect.into_iter().collect::<Vec<_>>(),
            "{mine_at:?} {mention_at:?} {at} {mine}"
        );
    }
}

#[test]
fn a_mention_and_a_reply_at_once_is_a_mention() {
    let mut pr = Pr::others();
    pr.record("T_1", Some(T0 - 100), None);
    pr.threads = vec![thread(
        "T_1",
        vec![inline("I_1", user("alice"), T0 + 10, &mention_link(ME))],
    )];
    assert_eq!(pr.kinds(), [("I_1".to_string(), EventKind::Mentioned)]);
}

#[test]
fn threads_are_recorded_when_i_comment_or_am_mentioned() {
    let mut pr = Pr::others();
    pr.threads = vec![
        thread(
            "T_MINE",
            vec![
                inline("A", user("alice"), T0 + 5, ""),
                inline("B", user(ME), T0 + 10, ""),
                inline("C", user("alice"), T0 + 20, ""),
            ],
        ),
        thread(
            "T_MENTION",
            vec![
                inline("D", user("bob"), T0 + 30, &mention_link(ME)),
                inline("E", user("bob"), T0 + 40, ""),
            ],
        ),
        thread("T_OTHER", vec![inline("F", user("bob"), T0 + 50, "")]),
    ];
    let out = pr.run();
    let recorded: BTreeMap<&str, (Option<i64>, Option<i64>)> = out
        .threads
        .iter()
        .map(|t| (t.id.as_str(), (t.mine_at, t.mention_at)))
        .collect();
    assert_eq!(
        recorded,
        BTreeMap::from([
            ("T_MENTION", (None, Some(T0 + 30))),
            ("T_MINE", (Some(T0 + 10), None))
        ])
    );
    let kinds: Vec<(String, EventKind)> = out.events.into_iter().map(|e| (e.id, e.kind)).collect();
    assert_eq!(
        kinds,
        [
            ("C".to_string(), EventKind::Reply),
            ("D".to_string(), EventKind::Mentioned),
            ("E".to_string(), EventKind::ReplyMentioned)
        ],
        "A came before my comment; F is in a thread I am not in"
    );
    assert_eq!(out.own.len(), 1);
    assert_eq!(out.own[0].id, "B");
}

#[test]
fn review_requests_for_me_and_my_teams() {
    let event = |id: &str, reviewer: Value| {
        json!({"__typename":"ReviewRequestedEvent","id":id,"createdAt":iso(T0 + 10),
               "actor":{"login":"alice"},"requestedReviewer":reviewer})
    };
    let mut pr = Pr::others();
    pr.timeline = vec![
        event("RR_1", user(ME)),
        event(
            "RR_2",
            json!({"__typename":"Team","databaseId":42,"slug":"core"}),
        ),
        event(
            "RR_3",
            json!({"__typename":"Team","databaseId":7,"slug":"other"}),
        ),
        event("RR_4", user("bob")),
        event("RR_5", json!(null)),
    ];
    let out = pr.run().events;
    let got: Vec<(&str, Option<&str>, EventKind)> = out
        .iter()
        .map(|e| (e.id.as_str(), e.text.as_deref(), e.kind))
        .collect();
    assert_eq!(
        got,
        [
            ("RR_1", Some("for you"), EventKind::ReviewRequested),
            (
                "RR_2",
                Some("for core team"),
                EventKind::TeamReviewRequested
            )
        ]
    );
    assert!(out.iter().all(|e| e.url == "https://github.com/o/r/pull/1"));
    assert!(out.iter().all(|e| e.actor.as_deref() == Some("alice")));
}

#[test]
fn merged_and_closed_carry_who_and_no_text() {
    let mut pr = Pr::others();
    pr.timeline = vec![
        json!({"__typename":"MergedEvent","id":"ME_1","createdAt":iso(T0 + 1),"url":"https://m","actor":{"login":"bob"}}),
        json!({"__typename":"ClosedEvent","id":"CE_1","createdAt":iso(T0 + 2),"url":"https://c","actor":{"login":"me"}}),
    ];
    let out = pr.run().events;
    assert_eq!(out[0].kind, EventKind::Merged);
    assert_eq!(
        (out[0].actor.as_deref(), out[0].text.as_deref()),
        (Some("bob"), None)
    );
    assert_eq!(out[0].url, "https://m");
    assert_eq!(out[1].kind, EventKind::Closed);
    assert_eq!(
        out[1].actor.as_deref(),
        Some("me"),
        "who did it does not matter"
    );
}

#[test]
fn merge_queue_removals_name_the_reason_and_who_added_the_pr() {
    let added = |id: &str, at: i64, who: &str| json!({"__typename":"AddedToMergeQueueEvent","id":id,"createdAt":iso(at),"actor":{"login":who}});
    let removed = |id: &str, at: i64, who: &str, reason: &str| json!({"__typename":"RemovedFromMergeQueueEvent","id":id,"createdAt":iso(at),"actor":{"login":who},"reason":reason});
    let queue = vec![
        added("A_1", T0 - 50, "alice"),
        removed("X_1", T0 - 40, "github-merge-queue", "failed_checks"),
        added("A_2", T0 + 10, "bob"),
        removed("X_2", T0 + 20, "bob", "manual"),
        added("A_3", T0 + 30, "carol"),
        removed("X_3", T0 + 40, "github-merge-queue", "merged"),
        added("A_4", T0 + 50, "dave"),
        removed("X_4", T0 + 60, "github-merge-queue", "something_new"),
    ];
    let mut pr = Pr::mine();
    pr.timeline = queue
        .iter()
        .filter(|e| e["createdAt"].as_str() >= Some(&iso(T0)))
        .cloned()
        .collect();
    let first = pr.run();
    assert!(first.needs_merge_queue, "the adders need every queue event");
    pr.queue = Some(queue);
    let out = pr.run();
    assert!(!out.needs_merge_queue);
    let got: Vec<(&str, EventKind, Option<&str>, Option<&str>)> = out
        .events
        .iter()
        .map(|e| (e.id.as_str(), e.kind, e.actor.as_deref(), e.text.as_deref()))
        .collect();
    assert_eq!(
        got,
        [
            ("A_2", EventKind::MergeQueueAdded, Some("bob"), None),
            (
                "X_2",
                EventKind::MergeQueueRemoved,
                Some("bob"),
                Some("Removed manually · added by bob")
            ),
            ("A_3", EventKind::MergeQueueAdded, Some("carol"), None),
            ("A_4", EventKind::MergeQueueAdded, Some("dave"), None),
            (
                "X_4",
                EventKind::MergeQueueRemoved,
                Some("github-merge-queue"),
                Some("something_new · added by dave")
            ),
        ],
        "a merged removal makes no row"
    );
    assert!(
        out.events
            .iter()
            .all(|e| e.url == "https://github.com/o/r/pull/1")
    );
    assert_eq!(
        convert::enqueuer(pr.queue.as_ref().unwrap(), "X_1").as_deref(),
        Some("alice")
    );
}

#[test]
fn my_own_posts_are_collected_for_reactions() {
    let mut pr = Pr::others();
    pr.timeline = vec![
        comment("C_OLD", user(ME), T0 - 10, ""),
        comment("C_NEW", user(ME), T0 + 10, ""),
        review("R_EMPTY", user(ME), T0 + 20, "APPROVED", ""),
        review("R_BODY", user(ME), T0 + 30, "COMMENTED", "nit"),
    ];
    let own: Vec<(String, bool)> = pr
        .run()
        .own
        .into_iter()
        .map(|o| (o.id, o.baseline_done))
        .collect();
    assert_eq!(
        own,
        [
            ("C_OLD".to_string(), false),
            ("C_NEW".to_string(), true),
            ("R_BODY".to_string(), true)
        ],
        "after the last fetch a comment starts from zero"
    );
}

// ------------------------------------------------ collecting a found PR

fn collected_pr() -> Value {
    json!({
        "id":"PR_1","url":"https://github.com/o/r/pull/1","createdAt":iso(T0 - 1000),
        "author":user(ME),"bodyHTML":"","bodyText":"body",
        "comments":{"nodes":[comment("C_1", user(ME), T0 - 900, ""), comment("C_2", user("alice"), T0 - 800, "")]},
        "reviews":{"nodes":[review("R_1", user(ME), T0 - 700, "COMMENTED", "x"), review("R_2", user(ME), T0 - 600, "APPROVED", "")]},
        "reviewThreads":{"nodes":[
            thread("T_1", vec![inline("I_1", user("alice"), T0 - 500, ""), inline("I_2", user(ME), T0 - 400, "")]),
            thread("T_2", vec![inline("I_3", user("bob"), T0 - 300, &mention_link(ME))]),
            thread("T_3", vec![inline("I_4", user("bob"), T0 - 200, &team_link(42))]),
            thread("T_4", vec![inline("I_5", user("bob"), T0 - 100, "")])
        ]},
        "reviewRequests":{"nodes":[
            {"requestedReviewer":user(ME)},
            {"requestedReviewer":{"__typename":"Team","databaseId":42,"slug":"core"}},
            {"requestedReviewer":user("bob")}
        ]},
        "requestEvents":{"nodes":[
            {"id":"RR_OLD","createdAt":iso(T0 - 5000),"actor":{"login":"x"},"requestedReviewer":user(ME)},
            {"id":"RR_NEW","createdAt":iso(T0 - 3000),"actor":{"login":"y"},"requestedReviewer":user(ME)},
            {"id":"RR_TEAM","createdAt":iso(T0 - 4000),"actor":{"login":"z"},"requestedReviewer":{"__typename":"Team","databaseId":42,"slug":"core"}},
            {"id":"RR_BOB","createdAt":iso(T0 - 4000),"actor":{"login":"z"},"requestedReviewer":user("bob")}
        ]}
    })
}

#[test]
fn collecting_records_my_comments_threads_and_open_requests() {
    let t = teams();
    let found = convert::collect(&collected_pr(), T0 - 650, ctx(&t));
    let own: Vec<(&str, bool)> = found
        .own
        .iter()
        .map(|o| (o.id.as_str(), o.baseline_done))
        .collect();
    assert_eq!(
        own,
        [
            ("PR_1", false),
            ("C_1", false),
            ("R_1", false),
            ("I_2", true)
        ],
        "my PR body, comment, review with a body and review comment"
    );
    let threads: BTreeMap<&str, (Option<i64>, Option<i64>)> = found
        .threads
        .iter()
        .map(|t| (t.id.as_str(), (t.mine_at, t.mention_at)))
        .collect();
    assert_eq!(
        threads,
        BTreeMap::from([
            ("T_1", (Some(T0 - 400), None)),
            ("T_2", (None, Some(T0 - 300))),
            ("T_3", (None, Some(T0 - 200)))
        ])
    );
    let ongoing: Vec<(&str, i64, Option<&str>, EventKind)> = found
        .ongoing
        .iter()
        .map(|e| (e.id.as_str(), e.occurred_at, e.actor.as_deref(), e.kind))
        .collect();
    assert_eq!(
        ongoing,
        [
            ("RR_NEW", T0 - 3000, Some("y"), EventKind::ReviewRequested),
            (
                "RR_TEAM",
                T0 - 4000,
                Some("z"),
                EventKind::TeamReviewRequested
            )
        ],
        "each open request with its newest event, of any age"
    );
}

// ---------------------------------------------------------------- reactions

#[test]
fn reaction_counts_leave_out_my_own() {
    let own = OwnComment {
        id: "C_1".into(),
        pr_id: "PR_1".into(),
        url: "https://c/1".into(),
        text: "my comment".into(),
        created_at: T0,
        baseline_done: true,
    };
    let node = json!({"__typename":"IssueComment","id":"C_1","reactionGroups":[
        {"content":"THUMBS_UP","viewerHasReacted":true,"reactors":{"totalCount":3}},
        {"content":"HEART","viewerHasReacted":true,"reactors":{"totalCount":1}},
        {"content":"ROCKET","viewerHasReacted":false,"reactors":{"totalCount":2}},
        {"content":"EYES","viewerHasReacted":false,"reactors":{"totalCount":0}}
    ]});
    let reaction = convert::reaction(&node, &own, true);
    assert_eq!(
        reaction.counts,
        BTreeMap::from([("ROCKET".to_string(), 2), ("THUMBS_UP".to_string(), 2)])
    );
    assert!(reaction.watching);
    assert_eq!(reaction.comment_created_at, T0);
    assert_eq!(reaction.text, "my comment");
    assert!(!convert::reaction(&node, &own, false).watching);
}

// ---------------------------------------------------------- notifications

#[test]
fn notified_prs_and_the_newest_update() {
    let body = json!([
        {"updated_at":"2027-01-15T08:00:00Z","reason":"mention","subject":{"type":"PullRequest","url":"https://api.github.com/repos/Org/App/pulls/12"}},
        {"updated_at":"2027-01-15T09:00:00Z","reason":"team_mention","subject":{"type":"Issue","url":"https://api.github.com/repos/o/r/issues/3"}},
        {"updated_at":"2027-01-15T08:30:00Z","reason":"subscribed","subject":{"type":"PullRequest","url":"https://api.github.com/repos/o/r/pulls/4"}}
    ]);
    let (prs, newest) = convert::notified_prs(&body);
    assert_eq!(
        prs,
        [
            ("Org".to_string(), "App".to_string(), 12),
            ("o".to_string(), "r".to_string(), 4)
        ]
    );
    assert_eq!(newest.as_deref(), Some("2027-01-15T09:00:00Z"));
    assert_eq!(
        convert::next_link("<https://api.github.com/notifications?page=2>; rel=\"next\", <https://x?page=9>; rel=\"last\"").as_deref(),
        Some("https://api.github.com/notifications?page=2")
    );
    assert_eq!(convert::next_link("<https://x?page=1>; rel=\"prev\""), None);
}

// ------------------------------------------------------------------ search

#[test]
fn the_four_searches_of_an_owner() {
    assert_eq!(
        convert::search_queries("org:acme", "2027-01-01", true),
        [
            "is:pr is:open involves:@me updated:>=2027-01-01 org:acme",
            "is:pr is:open reviewed-by:@me updated:>=2027-01-01 org:acme",
            "is:pr is:open author:@me org:acme",
            "is:pr is:open review-requested:@me org:acme",
        ]
    );
    assert_eq!(
        convert::search_queries("is:public", "2027-01-01", false)[3],
        "is:pr is:open user-review-requested:@me is:public"
    );
}

#[test]
fn public_search_leaves_out_registered_owners() {
    let connection = json!({"nodes":[
        {"id":"A","repository":{"owner":{"login":"Acme"}}},
        {"id":"B","repository":{"owner":{"login":"other"}}},
        {}
    ]});
    let exclude = BTreeSet::from(["acme".to_string()]);
    assert_eq!(convert::search_ids(&connection, &exclude), ["B"]);
    assert_eq!(
        convert::search_ids(&connection, &BTreeSet::new()),
        ["A", "B"]
    );
}

// ------------------------------------------- mentions from bodyHTML links

/// The quote of a mention, as GitHub rendered it in a Quote reply on
/// bufferings-hello/hello-merge-queue#10 (2026-11-05): no class.
fn quoted_link(login: &str) -> String {
    format!(
        "<blockquote><p><a href=\"https://github.com/{login}\">@{login}</a> test</p></blockquote>"
    )
}

#[test]
fn a_link_to_me_in_any_post_is_one_mentioned_row() {
    let mut pr = Pr::others();
    let mut body = review("R_1", user("carol"), T0 + 20, "COMMENTED", "see");
    body["bodyHTML"] = json!(mention_link(ME));
    pr.timeline = vec![
        comment("C_1", user("alice"), T0 + 10, &mention_link(ME)),
        body,
    ];
    pr.threads = vec![thread(
        "T_1",
        vec![inline("I_1", user("bob"), T0 + 30, &mention_link(ME))],
    )];
    let out = pr.run();
    let got: Vec<(&str, EventKind, Option<&str>)> = out
        .events
        .iter()
        .map(|e| (e.id.as_str(), e.kind, e.actor.as_deref()))
        .collect();
    assert_eq!(
        got,
        [
            ("C_1", EventKind::Mentioned, Some("alice")),
            ("R_1", EventKind::Mentioned, Some("carol")),
            ("I_1", EventKind::Mentioned, Some("bob"))
        ]
    );
    assert_eq!(out.events[0].url, "https://c/C_1");
    assert_eq!(out.events[0].text.as_deref(), Some("text C_1"));
    assert_eq!(out.events[0].comment_id.as_deref(), Some("C_1"));
}

#[test]
fn a_mention_on_my_pr_is_mentioned_not_comment_or_reply() {
    let mut pr = Pr::mine();
    pr.record("T_1", Some(T0 - 100), None);
    pr.timeline = vec![comment("C_1", user("alice"), T0 + 10, &mention_link(ME))];
    pr.threads = vec![thread(
        "T_1",
        vec![inline("I_1", user("bob"), T0 + 20, &mention_link(ME))],
    )];
    assert_eq!(
        pr.kinds(),
        [
            ("C_1".to_string(), EventKind::Mentioned),
            ("I_1".to_string(), EventKind::Mentioned)
        ]
    );
}

#[test]
fn a_link_to_me_in_the_body_of_a_new_pr_is_a_mention() {
    let mut pr = Pr::others();
    pr.node["createdAt"] = json!(iso(T0 + 5));
    pr.node["bodyHTML"] = json!(mention_link(ME));
    pr.node["bodyText"] = json!("ping @me");
    let e = pr.run().events.remove(0);
    assert_eq!(
        (e.id.as_str(), e.kind),
        ("PR_1:mention", EventKind::Mentioned)
    );
    assert_eq!(e.actor.as_deref(), Some("alice"));
    assert_eq!(e.text.as_deref(), Some("ping @me"));
    assert_eq!(e.url, "https://github.com/o/r/pull/1");
    let mut mine = Pr::mine();
    mine.node["createdAt"] = json!(iso(T0 + 5));
    mine.node["bodyHTML"] = json!(mention_link(ME));
    assert!(mine.run().events.is_empty(), "my own PR body");
}

#[test]
fn what_is_not_a_mention_of_me() {
    use EventKind::*;
    // (author, bodyHTML, PR is mine, row)
    let cases = [
        // A quote reply keeps the link but loses the class.
        (user("bob"), quoted_link(ME), false, None),
        (user("bob"), quoted_link(ME), true, Some(Comment)),
        // My own post linking to me.
        (user(ME), mention_link(ME), false, None),
        // A link to someone else.
        (user("bob"), mention_link("someone"), false, None),
        (user("bob"), mention_link("meme"), false, None),
        // The login compares without case.
        (user("bob"), mention_link("ME"), false, Some(Mentioned)),
        // A bot is not special: its mention of me is a mention.
        (bot("ci[bot]"), mention_link(ME), false, Some(Mentioned)),
        (bot("ci[bot]"), mention_link(ME), true, Some(Mentioned)),
        // Plain text `@me` is no link.
        (user("bob"), "<p>@me</p>".to_string(), false, None),
    ];
    for (author, html, mine, expect) in cases {
        let mut pr = if mine { Pr::mine() } else { Pr::others() };
        pr.timeline = vec![comment("C_1", author.clone(), T0 + 10, &html)];
        let got: Vec<EventKind> = pr.kinds().into_iter().map(|(_, k)| k).collect();
        assert_eq!(
            got,
            expect.into_iter().collect::<Vec<_>>(),
            "{author} {html} {mine}"
        );
    }
}

#[test]
fn a_user_mention_link_points_at_the_user_page() {
    let link = |href: &str| format!("<a class=\"user-mention notranslate\" href=\"{href}\">@x</a>");
    assert!(convert::mentions_user(&link("https://github.com/me"), "me"));
    assert!(convert::mentions_user(
        &link("https://github.com/Me/"),
        "ME"
    ));
    assert!(convert::mentions_user(&link("/me"), "me"));
    assert!(!convert::mentions_user(
        &link("https://github.com/me/repo"),
        "me"
    ));
    assert!(!convert::mentions_user(
        &link("https://github.com/someone"),
        "me"
    ));
    assert!(!convert::mentions_user(&quoted_link("me"), "me"));
}
