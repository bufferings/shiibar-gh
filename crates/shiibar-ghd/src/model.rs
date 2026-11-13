//! The daemon's own state types. Deliberately separate from the wire types in
//! `shiibar-gh-proto`: saved values must survive whatever a client can parse.
//!
//! Keys: an account is GitHub's numeric user id as a decimal string. A PR
//! and a row are keyed by the account id and the GitHub node id joined with
//! `:` ([`join_key`]); neither contains `:`, so the key is unambiguous and
//! unique across accounts. An owner has an id the daemon assigns (`o<n>`).

use shiibar_gh_proto as proto;
use std::collections::{BTreeMap, BTreeSet};

pub const PUBLIC: &str = "public";

/// DESIGN.md, "Constants": the discovery range D of the open PR searches.
pub const DISCOVERY_DAYS: i64 = 14;
/// DESIGN.md, "Rows in a card": the rows kept per PR.
pub const KEEP_ROWS: usize = 20;
/// DESIGN.md, "Constants": the defaults of n and m.
pub const AUTO_DISMISS_DAYS_DEFAULT: i64 = 3;
pub const DISMISSED_KEEP_DAYS_DEFAULT: i64 = 7;

/// DESIGN.md, "Constants": `text_size` is a whole number of points.
pub const TEXT_SIZE_DEFAULT: i64 = 12;
pub const TEXT_SIZE_MIN: i64 = 9;
pub const TEXT_SIZE_MAX: i64 = 18;

/// `<account id>:<node id>`, the key of a PR, row, baseline or comment.
pub fn join_key(account: &str, node: &str) -> String {
    format!("{account}:{node}")
}

macro_rules! stored_enum {
    ($name:ident { $($variant:ident = $text:literal),+ $(,)? }) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum $name { $($variant),+ }

        impl $name {
            pub fn as_str(self) -> &'static str {
                match self { $(Self::$variant => $text),+ }
            }

            pub fn parse(text: &str) -> Option<Self> {
                match text { $($text => Some(Self::$variant),)+ _ => None }
            }
        }
    };
}

macro_rules! both_ways {
    ($name:ident { $($variant:ident),+ $(,)? }) => {
        impl From<proto::$name> for $name {
            fn from(value: proto::$name) -> Self {
                match value { $(proto::$name::$variant => Self::$variant),+ }
            }
        }

        impl From<$name> for proto::$name {
            fn from(value: $name) -> Self {
                match value { $($name::$variant => Self::$variant),+ }
            }
        }
    };
}

stored_enum!(PrState {
    Open = "open",
    Merged = "merged",
    Closed = "closed",
});
both_ways!(PrState {
    Open,
    Merged,
    Closed
});

stored_enum!(Review {
    Approved = "approved",
    ReviewRequired = "review_required",
    ChangesRequested = "changes_requested",
    None = "none",
});
both_ways!(Review {
    Approved,
    ReviewRequired,
    ChangesRequested,
    None
});

stored_enum!(Checks {
    Passed = "passed",
    InProgress = "in_progress",
    Failed = "failed",
    None = "none",
});
both_ways!(Checks {
    Passed,
    InProgress,
    Failed,
    None
});

stored_enum!(BaseStatus {
    UpToDate = "up_to_date",
    Behind = "behind",
    Conflicts = "conflicts",
    None = "none",
});
both_ways!(BaseStatus {
    UpToDate,
    Behind,
    Conflicts,
    None
});

stored_enum!(EventKind {
    ReviewRequested = "review_requested",
    TeamReviewRequested = "team_review_requested",
    Mentioned = "mentioned",
    TeamMentioned = "team_mentioned",
    Comment = "comment",
    CommentOther = "comment_other",
    Reply = "reply",
    ReplyMentioned = "reply_mentioned",
    Reaction = "reaction",
    Approved = "approved",
    ChangesRequested = "changes_requested",
    ChecksFailed = "checks_failed",
    ChecksPassed = "checks_passed",
    Conflicts = "conflicts",
    Mergeable = "mergeable",
    MergeQueueAdded = "merge_queue_added",
    MergeQueueRemoved = "merge_queue_removed",
    MergedClosed = "merged_closed",
    Reopened = "reopened",
});
both_ways!(EventKind {
    ReviewRequested,
    TeamReviewRequested,
    Mentioned,
    TeamMentioned,
    Comment,
    CommentOther,
    Reply,
    ReplyMentioned,
    Reaction,
    Approved,
    ChangesRequested,
    ChecksFailed,
    ChecksPassed,
    Conflicts,
    Mergeable,
    MergeQueueAdded,
    MergeQueueRemoved,
    MergedClosed,
    Reopened,
});

impl EventKind {
    pub const ALL: [EventKind; 19] = [
        EventKind::ReviewRequested,
        EventKind::TeamReviewRequested,
        EventKind::Mentioned,
        EventKind::TeamMentioned,
        EventKind::Comment,
        EventKind::CommentOther,
        EventKind::Reply,
        EventKind::ReplyMentioned,
        EventKind::Reaction,
        EventKind::Approved,
        EventKind::ChangesRequested,
        EventKind::ChecksFailed,
        EventKind::ChecksPassed,
        EventKind::Conflicts,
        EventKind::Mergeable,
        EventKind::MergeQueueAdded,
        EventKind::MergeQueueRemoved,
        EventKind::MergedClosed,
        EventKind::Reopened,
    ];

    /// The defaults of DESIGN.md, "Row kinds and states": List and Notify.
    pub fn default_cell(self) -> Cell {
        use EventKind::*;
        let notify = !matches!(self, MergeQueueAdded | MergedClosed);
        Cell { list: true, notify }
    }
}

stored_enum!(RowKind {
    ReviewRequested = "review_requested",
    TeamReviewRequested = "team_review_requested",
    Mentioned = "mentioned",
    TeamMentioned = "team_mentioned",
    Comment = "comment",
    CommentOther = "comment_other",
    Reply = "reply",
    ReplyMentioned = "reply_mentioned",
    Reaction = "reaction",
    Approved = "approved",
    ChangesRequested = "changes_requested",
    ChecksFailed = "checks_failed",
    ChecksPassed = "checks_passed",
    Conflicts = "conflicts",
    Mergeable = "mergeable",
    MergeQueueAdded = "merge_queue_added",
    MergeQueueRemoved = "merge_queue_removed",
    Merged = "merged",
    Closed = "closed",
    Reopened = "reopened",
});
both_ways!(RowKind {
    ReviewRequested,
    TeamReviewRequested,
    Mentioned,
    TeamMentioned,
    Comment,
    CommentOther,
    Reply,
    ReplyMentioned,
    Reaction,
    Approved,
    ChangesRequested,
    ChecksFailed,
    ChecksPassed,
    Conflicts,
    Mergeable,
    MergeQueueAdded,
    MergeQueueRemoved,
    Merged,
    Closed,
    Reopened,
});

impl From<proto::IngestKind> for RowKind {
    fn from(kind: proto::IngestKind) -> Self {
        use proto::IngestKind as I;
        match kind {
            I::ReviewRequested => Self::ReviewRequested,
            I::TeamReviewRequested => Self::TeamReviewRequested,
            I::Mentioned => Self::Mentioned,
            I::TeamMentioned => Self::TeamMentioned,
            I::Comment => Self::Comment,
            I::CommentOther => Self::CommentOther,
            I::Reply => Self::Reply,
            I::ReplyMentioned => Self::ReplyMentioned,
            I::Approved => Self::Approved,
            I::MergeQueueAdded => Self::MergeQueueAdded,
            I::MergeQueueRemoved => Self::MergeQueueRemoved,
            I::Merged => Self::Merged,
            I::Closed => Self::Closed,
            I::Reopened => Self::Reopened,
        }
    }
}

impl RowKind {
    /// The kind of the event table this row follows.
    pub fn event(self) -> EventKind {
        use RowKind::*;
        match self {
            ReviewRequested => EventKind::ReviewRequested,
            TeamReviewRequested => EventKind::TeamReviewRequested,
            Mentioned => EventKind::Mentioned,
            TeamMentioned => EventKind::TeamMentioned,
            Comment => EventKind::Comment,
            CommentOther => EventKind::CommentOther,
            Reply => EventKind::Reply,
            ReplyMentioned => EventKind::ReplyMentioned,
            Reaction => EventKind::Reaction,
            Approved => EventKind::Approved,
            ChangesRequested => EventKind::ChangesRequested,
            ChecksFailed => EventKind::ChecksFailed,
            ChecksPassed => EventKind::ChecksPassed,
            Conflicts => EventKind::Conflicts,
            Mergeable => EventKind::Mergeable,
            MergeQueueAdded => EventKind::MergeQueueAdded,
            MergeQueueRemoved => EventKind::MergeQueueRemoved,
            Merged | Closed => EventKind::MergedClosed,
            Reopened => EventKind::Reopened,
        }
    }

    pub fn is_review_request(self) -> bool {
        matches!(self, Self::ReviewRequested | Self::TeamReviewRequested)
    }

    /// Rows a muted user applies to by their actor: not the state changes
    /// and not reactions (DESIGN.md, "Mute").
    pub fn has_actor(self) -> bool {
        !matches!(
            self,
            Self::Reaction
                | Self::ChangesRequested
                | Self::ChecksFailed
                | Self::ChecksPassed
                | Self::Conflicts
                | Self::Mergeable
        )
    }

    /// DESIGN.md, "Dismiss": the rows that bring a dismissed card back.
    /// A review request to a team is not one.
    pub fn is_return_trigger(self) -> bool {
        matches!(
            self,
            Self::Mentioned | Self::Reply | Self::ReviewRequested | Self::Reopened
        )
    }

    /// The name in notification titles: the table's, with Merged / Closed
    /// told apart (DESIGN.md, "macOS notifications").
    pub fn label(self) -> &'static str {
        use RowKind::*;
        match self {
            ReviewRequested => "Review requested",
            TeamReviewRequested => "Review requested to my team",
            Mentioned => "Mentioned",
            TeamMentioned => "My team mentioned",
            Comment => "Comment on my PR",
            CommentOther => "Comment on other PRs",
            Reply => "Reply in a thread I commented in",
            ReplyMentioned => "Reply in a thread I was mentioned in",
            Reaction => "Reaction to my comment",
            Approved => "Approved",
            ChangesRequested => "Changes requested",
            ChecksFailed => "Checks failed",
            ChecksPassed => "Checks passed",
            Conflicts => "Conflicts",
            Mergeable => "Mergeable",
            MergeQueueAdded => "Added to merge queue",
            MergeQueueRemoved => "Removed from merge queue",
            Merged => "Merged",
            Closed => "Closed",
            Reopened => "Reopened",
        }
    }
}

stored_enum!(NotifyState {
    // Nothing to send, or the record was cleared.
    None = "none",
    // Waiting for the app. Becomes a summary if the app was not there.
    Pending = "pending",
    Delivered = "delivered",
});

stored_enum!(OwnerKind {
    Org = "org",
    User = "user",
    Public = "public",
});
both_ways!(OwnerKind { Org, User, Public });

stored_enum!(AccountColor {
    None = "none",
    Red = "red",
    Orange = "orange",
    Yellow = "yellow",
    Green = "green",
    Blue = "blue",
    Purple = "purple",
});
both_ways!(AccountColor {
    None,
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple
});

impl AccountColor {
    /// DESIGN.md, "Account colors": the order second and later accounts take
    /// unused colors in.
    pub const CYCLE: [AccountColor; 6] = [
        AccountColor::Red,
        AccountColor::Orange,
        AccountColor::Yellow,
        AccountColor::Green,
        AccountColor::Blue,
        AccountColor::Purple,
    ];
}

stored_enum!(PlacedTab {
    Review = "review",
    Mine = "mine",
});
both_ways!(PlacedTab { Review, Mine });

// The section a placed card is in. A card in Done (`PrRec::done_at`) keeps
// this as the section it was in before it entered Done.
stored_enum!(Section {
    Doing = "doing",
    Todo = "todo",
    Waiting = "waiting",
    Main = "main",
});

stored_enum!(Appearance {
    System = "system",
    Light = "light",
    Dark = "dark",
});

/// One line of an owner's event table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    pub list: bool,
    pub notify: bool,
}

/// An owner's event table, every kind present.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventTable(pub BTreeMap<EventKind, Cell>);

impl Default for EventTable {
    fn default() -> Self {
        Self(
            EventKind::ALL
                .iter()
                .map(|k| (*k, k.default_cell()))
                .collect(),
        )
    }
}

impl EventTable {
    pub fn cell(&self, kind: EventKind) -> Cell {
        self.0.get(&kind).copied().unwrap_or(kind.default_cell())
    }
}

/// A login compared for Mute: without case, as GraphQL spells it.
/// DESIGN.md, "Mute": a bot is compared by `Bot.login` (`renovate`, without
/// `[bot]`). Every actor shiibar-gh records comes from GraphQL, so no REST
/// `[bot]` suffix ever needs removing.
pub fn user_key(login: &str) -> String {
    login.to_lowercase()
}

/// The three Mute lists of an account, in the order they were added.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MuteRec {
    /// `owner/repo`.
    pub repos: Vec<String>,
    /// Logins.
    pub users: Vec<String>,
    /// `owner/repo#number`.
    pub prs: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnerRec {
    pub id: String,
    pub account: String,
    /// The login as GitHub spells it, or `Public`.
    pub name: String,
    pub kind: OwnerKind,
    pub github_id: Option<i64>,
    /// Registration order within the account.
    pub seq: u64,
    pub enabled: bool,
    pub notify: bool,
    pub skip_drafts: bool,
    pub watch_started_at: i64,
    /// The last time the search and status fetch of this owner succeeded.
    pub fetched_at: Option<i64>,
    pub events: EventTable,
}

impl OwnerRec {
    pub fn is_public(&self) -> bool {
        self.kind == OwnerKind::Public
    }
}

/// A rate limit as the last response said.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct LimitRec {
    pub limit: i64,
    pub remaining: i64,
    pub reset_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TestRec {
    pub at: i64,
    pub results: Vec<proto::TestResult>,
}

/// What the daemon knows about an account's token. The token itself lives
/// in the Keychain only.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct TokenRec {
    pub registered: bool,
    /// The last fetch got a 401: fetching stops until it is replaced.
    pub invalid: bool,
    pub expires_at: Option<i64>,
    /// `X-OAuth-Scopes` of the last response that had it.
    pub scopes: Option<Vec<String>>,
    /// Scopes an endpoint refused for lack of (`read:org`, `notifications`).
    pub refused: BTreeSet<String>,
    /// The last run saw `X-GitHub-SSO`: its organization ids and URLs.
    pub sso: bool,
    pub sso_orgs: Vec<i64>,
    pub sso_urls: Vec<String>,
    /// Owner ids whose search the last run was refused with the
    /// single-organization form of `X-GitHub-SSO`, with its URL.
    pub sso_owners: BTreeMap<String, Option<String>>,
    pub last_test: Option<TestRec>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TeamRec {
    pub database_id: i64,
    pub slug: String,
}

/// A review thread whose comments become Reply rows.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ThreadRec {
    pub id: String,
    pub pr_id: String,
    /// The account's first comment in it.
    pub mine_at: Option<i64>,
    /// The first mention of the account or its team in it.
    pub mention_at: Option<i64>,
}

/// One of the account's comments, reviews, review comments or PR bodies.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct OwnComment {
    pub id: String,
    pub pr_id: String,
    pub url: String,
    pub text: String,
    pub created_at: i64,
    /// The core already holds a baseline, or this comment starts from zero.
    pub baseline_done: bool,
}

/// One request of a run that failed, kept so that the next run makes only
/// the failed requests again (DESIGN.md, "Fetch success and failure"). The
/// fetch layer decides what it needs to make a request again; the core only
/// keeps the list.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct FailedRequest {
    /// The log name: `Search`, `Status`, `Compare`, `Contexts`, `Events`,
    /// `Reactions`, or `GET <path>` for REST.
    pub name: String,
    /// The owner id of an owner's request.
    #[serde(default)]
    pub owner: Option<String>,
    /// The ids (PR or comment node ids) or search texts it carried.
    #[serde(default)]
    pub items: Vec<String>,
    /// The start of the event window, for `Events`.
    #[serde(default)]
    pub since: Option<i64>,
}

/// A PR whose events must be fetched again from `since`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RetryRec {
    pub pr_id: String,
    pub since: i64,
    pub failures: u32,
    /// The owner id of a PR the core does not know (a closed PR found by a
    /// search, shown only through a return trigger): the run of that owner
    /// fetches it again.
    #[serde(default)]
    pub owner: Option<String>,
}

/// What the fetcher keeps between runs for one account. PR, thread and
/// comment ids here are GitHub node ids.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct FetchRec {
    pub own: BTreeMap<String, OwnComment>,
    pub threads: BTreeMap<String, ThreadRec>,
    pub retries: BTreeMap<String, RetryRec>,
    /// Notified PRs (lowercase `owner/repo#number`) not fetched yet.
    pub pending_signals: BTreeSet<String>,
    pub notif_last_modified: Option<String>,
    pub notif_since: Option<String>,
    pub poll_interval: Option<i64>,
    pub notif_checked_at: Option<i64>,
    /// PRs (node ids) whose `Status`, `Compare` or `Contexts` request failed
    /// even alone: `status_fetch_failed`, fetched again every run.
    pub status_failures: BTreeSet<String>,
    /// Requests the last run could not make; the next run makes only these
    /// unless a full run is due.
    pub failed_requests: Vec<FailedRequest>,
    /// The start of the last full run (every request).
    pub full_run_started_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountRec {
    /// GitHub's numeric user id (`viewer { databaseId }`), as a decimal
    /// string.
    pub id: String,
    pub login: String,
    pub color: AccountColor,
    /// Registration order.
    pub seq: u64,
    pub token: TokenRec,
    /// The end of the last fetch run (Updated … ago).
    pub updated_at: Option<i64>,
    /// The blue dot of the menu bar icon.
    pub dot: bool,
    pub teams: Vec<TeamRec>,
    pub graphql: Option<LimitRec>,
    pub rest: Option<LimitRec>,
    /// Every fetch of the account stops until this time.
    pub stopped_until: Option<i64>,
    pub fetch: FetchRec,
    pub mutes: MuteRec,
}

/// The values a state change row compares against: what the last status
/// fetch saw.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrevValues {
    pub review: Review,
    pub checks: Checks,
    pub base_status: BaseStatus,
    pub mergeable: bool,
}

/// Where a card is placed. DESIGN.md, "Card states".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlaceRec {
    pub tab: PlacedTab,
    /// The section; in Done, the section before Done.
    pub section: Section,
    /// The order in the section, the smallest first. Kept while dismissed
    /// and while in Done.
    pub rank: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrRec {
    /// `<account>:<node id>`.
    pub key: String,
    pub account: String,
    pub id: String,
    pub owner: String,
    pub repo: String,
    pub number: u64,
    pub url: String,
    pub title: String,
    pub author: String,
    pub author_avatar_url: Option<String>,
    pub base: String,
    pub head: String,
    /// GraphQL `headRefOid` of the last status fetch.
    pub head_oid: Option<String>,
    pub state: PrState,
    pub is_draft: bool,
    pub review: Review,
    pub checks: Checks,
    pub base_status: BaseStatus,
    pub mergeable: bool,
    pub failed_check: Option<String>,
    pub changes_requested_by: Option<String>,
    pub updated_at: i64,
    /// GraphQL `createdAt`.
    pub created_at: Option<i64>,
    /// The newest review the account submitted on the PR, from the last
    /// status fetch. DESIGN.md, "Awaiting review".
    pub my_review_at: Option<i64>,
    /// The newest REVIEW_REQUESTED_EVENT to the account or one of its
    /// teams, rows or not. DESIGN.md, "Awaiting review".
    pub last_request_at: Option<i64>,
    pub is_private: bool,
    pub requested_me: bool,
    pub requested_team: bool,
    pub assignees: Vec<String>,
    pub link_review: String,
    pub link_checks: String,
    pub link_base: String,
    pub unreadable: bool,
    /// When the card first showed (`Recently added`).
    pub added_at: Option<i64>,
    /// `None` when there is nothing to compare against: the PR was just
    /// found, its owner's watch started, or it came back from Dismiss.
    pub prev: Option<PrevValues>,
    /// The last settled Checks result (`passed` or `failed`) and the head
    /// commit it was seen on. DESIGN.md, "State change rows".
    pub settled: Option<Checks>,
    pub settled_head: Option<String>,
    /// The watch of the PR's owner started and the PR was not fetched since:
    /// the review requests still open become rows (DESIGN.md, "Events before
    /// the watch started").
    pub watch_reset: bool,
    pub place: Option<PlaceRec>,
    /// When the merge or close now in effect was detected; `None` while the
    /// PR is open. The n days count from it.
    pub closed_at: Option<i64>,
    /// When the card entered Done: the detection of the merge or close, or
    /// the user's move to Done. `None` while the card is not in Done (open,
    /// or merged or closed and moved out of Done by the user, DESIGN.md,
    /// "Review"). On an unplaced PR, the detection of its merge or close.
    /// The order in Done, newest first.
    pub done_at: Option<i64>,
    /// A Mentioned or Reply in a thread I commented in row came after the
    /// merge or close: no automatic Dismiss.
    pub keep_after_close: bool,
    pub dismissed_at: Option<i64>,
    /// The user restored the card: no automatic Dismiss.
    pub restored: bool,
    /// While dismissed, a search or an event showed the PR closed.
    pub seen_closed: bool,
    /// The last time the card was dismissed until it came back: events of
    /// that time make no rows after the return either (DESIGN.md,
    /// "Dismiss").
    pub quiet_from: Option<i64>,
    pub quiet_until: Option<i64>,
    /// The time of the newest MERGED_EVENT: a CLOSED_EVENT at or after it is
    /// its pair and makes no row.
    pub merged_event_at: Option<i64>,
    /// The account's comments and threads were collected since the PR last
    /// became watched.
    pub collected: bool,
}

impl PrRec {
    /// `owner/repo#number`, the `<pr>` of the wire format.
    pub fn display_key(&self) -> String {
        format!("{}/{}#{}", self.owner, self.repo, self.number)
    }

    pub fn repo_name(&self) -> String {
        format!("{}/{}", self.owner, self.repo)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowRec {
    /// `<account>:<event node id or synthesized id>`.
    pub id: String,
    pub account: String,
    /// The PR key.
    pub pr: String,
    pub kind: RowKind,
    pub text: Option<String>,
    pub counts: Option<BTreeMap<String, u32>>,
    pub actor: Option<String>,
    pub url: String,
    pub occurred_at: i64,
    pub comment_id: Option<String>,
    pub unread: bool,
    /// The kind's List was on when the row was made. A row recorded while
    /// it was off triggers nothing (DESIGN.md, "Applying the table").
    pub listed: bool,
    /// When the row was made.
    pub made_at: i64,
    pub notify: NotifyState,
}

/// DESIGN.md, "Dismiss record": an open PR that left the Dismissed list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DismissRecord {
    /// `<account>:<node id>`, the key the PR had.
    pub key: String,
    pub account: String,
    pub pr_id: String,
    /// The owner id the PR belonged to.
    pub owner: String,
    /// `updatedAt` when recorded, moved on when a search finds it again
    /// without a return.
    pub updated_at: i64,
}

/// The last counted reactions of one of the account's comments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Baseline {
    /// `<account>:<comment node id>`.
    pub key: String,
    pub pr: String,
    pub counts: BTreeMap<String, u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub launch_at_login: bool,
    pub status_interval_minutes: i64,
    pub reactions_interval_minutes: i64,
    /// n: days after a merge or close before the automatic Dismiss.
    pub auto_dismiss_after_days: i64,
    /// m: days a dismissed card stays in the Dismissed list.
    pub dismissed_keep_days: i64,
    pub appearance: Appearance,
    /// The body text size of the popover and its window, in points.
    pub text_size: i64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            launch_at_login: true,
            status_interval_minutes: 1,
            reactions_interval_minutes: 3,
            auto_dismiss_after_days: AUTO_DISMISS_DAYS_DEFAULT,
            dismissed_keep_days: DISMISSED_KEEP_DAYS_DEFAULT,
            appearance: Appearance::System,
            text_size: TEXT_SIZE_DEFAULT,
        }
    }
}

/// Everything that outlives the process.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Data {
    pub accounts: BTreeMap<String, AccountRec>,
    pub owners: BTreeMap<String, OwnerRec>,
    pub prs: BTreeMap<String, PrRec>,
    pub rows: BTreeMap<String, RowRec>,
    /// Ids of deleted rows, to the PR key: the same event never makes a row
    /// again (DESIGN.md, "Rows in a card").
    pub deleted_rows: BTreeMap<String, String>,
    pub records: BTreeMap<String, DismissRecord>,
    pub baselines: BTreeMap<String, Baseline>,
    pub config: Config,
    /// The last number given to an account, owner (ids and order).
    pub seq: u64,
    /// After `reset`: the next Keychain read restores the accounts.
    pub restore_accounts: bool,
}

/// What changed in [`Data`] since the last save.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Dirty {
    pub accounts: BTreeSet<String>,
    pub owners: BTreeSet<String>,
    pub prs: BTreeSet<String>,
    pub rows: BTreeSet<String>,
    pub deleted_rows: BTreeSet<String>,
    pub records: BTreeSet<String>,
    pub baselines: BTreeSet<String>,
    pub config: bool,
    pub meta: bool,
}

impl Dirty {
    pub fn is_empty(&self) -> bool {
        self.accounts.is_empty()
            && self.owners.is_empty()
            && self.prs.is_empty()
            && self.rows.is_empty()
            && self.deleted_rows.is_empty()
            && self.records.is_empty()
            && self.baselines.is_empty()
            && !self.config
            && !self.meta
    }
}
