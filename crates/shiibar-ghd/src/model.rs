//! The daemon's own state types. Deliberately separate from the wire types in
//! `shiibar-gh-proto`: saved values must survive whatever a client can parse.

use shiibar_gh_proto as proto;
use std::collections::{BTreeMap, BTreeSet};

pub const PUBLIC: &str = "public";
/// The token target and Keychain account of the classic PAT.
pub const NOTIFICATIONS: &str = "notifications";
/// The Keychain account of an owner scope is this plus the lowercase owner.
pub const SCOPE_ACCOUNT_PREFIX: &str = "scope:";

/// The Keychain account for a token record key: `notifications`, `public` or
/// `scope:<lowercase owner>`. docs/tasks/M2.md, "Tokens and the Keychain".
pub fn scope_account(key: &str) -> String {
    match key {
        NOTIFICATIONS | PUBLIC => key.to_string(),
        owner => format!("{SCOPE_ACCOUNT_PREFIX}{}", owner.to_lowercase()),
    }
}

macro_rules! stored_enum {
    ($name:ident { $($variant:ident = $text:literal),+ $(,)? }) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

stored_enum!(RowKind {
    ReviewRequested = "review_requested",
    Mentioned = "mentioned",
    Comment = "comment",
    Reply = "reply",
    AddedToMergeQueue = "added_to_merge_queue",
    RemovedFromMergeQueue = "removed_from_merge_queue",
    Merged = "merged",
    Closed = "closed",
    BotComment = "bot_comment",
    ChecksFailed = "checks_failed",
    Conflicts = "conflicts",
    ChangesRequested = "changes_requested",
    Mergeable = "mergeable",
    Reaction = "reaction",
});
both_ways!(RowKind {
    ReviewRequested,
    Mentioned,
    Comment,
    Reply,
    AddedToMergeQueue,
    RemovedFromMergeQueue,
    Merged,
    Closed,
    BotComment,
    ChecksFailed,
    Conflicts,
    ChangesRequested,
    Mergeable,
    Reaction,
});

impl From<proto::EventKind> for RowKind {
    fn from(kind: proto::EventKind) -> Self {
        use proto::EventKind as E;
        match kind {
            E::ReviewRequested => Self::ReviewRequested,
            E::Mentioned => Self::Mentioned,
            E::Comment => Self::Comment,
            E::Reply => Self::Reply,
            E::AddedToMergeQueue => Self::AddedToMergeQueue,
            E::RemovedFromMergeQueue => Self::RemovedFromMergeQueue,
            E::Merged => Self::Merged,
            E::Closed => Self::Closed,
            E::BotComment => Self::BotComment,
        }
    }
}

impl RowKind {
    /// The name in notification titles, in GitHub's own wording.
    pub fn label(self) -> &'static str {
        match self {
            Self::ReviewRequested => "Review requested",
            Self::Mentioned => "Mentioned",
            Self::Comment => "Comment",
            Self::Reply => "Reply",
            Self::AddedToMergeQueue => "Added to merge queue",
            Self::RemovedFromMergeQueue => "Removed from merge queue",
            Self::Merged => "Merged",
            Self::Closed => "Closed",
            // DESIGN.md, "macOS notifications": a bot's comment is titled
            // like any other comment; the row kind stays `bot_comment`.
            Self::BotComment => "Comment",
            Self::ChecksFailed => "Checks failed",
            Self::Conflicts => "Conflicts",
            Self::ChangesRequested => "Changes requested",
            Self::Mergeable => "Mergeable",
            Self::Reaction => "Reaction",
        }
    }
}

stored_enum!(NotifyState {
    // Nothing to send, or the record was cleared.
    None = "none",
    // Waiting for the app. Becomes a summary if the app was not there.
    Pending = "pending",
    // Made on a snoozed PR, waiting for the release.
    Held = "held",
    // Undelivered before the PR was snoozed. The Return time release sends it
    // with the summary; a manual Unsnooze clears it like Held.
    HeldUndelivered = "held_undelivered",
    Delivered = "delivered",
});

stored_enum!(ScopeKind {
    Org = "org",
    User = "user",
});

stored_enum!(ScopeColor {
    Gray = "gray",
    Green = "green",
    Blue = "blue",
    Purple = "purple",
    Pink = "pink",
    Beige = "beige",
});
both_ways!(ScopeColor {
    Gray,
    Green,
    Blue,
    Purple,
    Pink,
    Beige
});

impl ScopeColor {
    /// The order new scopes take colors in. DESIGN.md, "Adding a scope and
    /// registering a token in Settings": each newly added scope takes the next
    /// color, cycling through all six.
    pub const CYCLE: [ScopeColor; 6] = [
        ScopeColor::Gray,
        ScopeColor::Green,
        ScopeColor::Blue,
        ScopeColor::Purple,
        ScopeColor::Pink,
        ScopeColor::Beige,
    ];
    /// Public starts beige (DESIGN.md, "Overview and scope").
    pub const PUBLIC: ScopeColor = ScopeColor::Beige;

    /// The color of the `seq`-th owner scope ever added.
    pub fn nth(seq: u32) -> ScopeColor {
        Self::CYCLE[seq as usize % Self::CYCLE.len()]
    }
}

stored_enum!(BotComments {
    Notify = "notify",
    ListOnly = "list_only",
    Hide = "hide",
});

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopeRec {
    pub id: String,
    /// Removed scopes stay so adding the owner again restores them.
    pub removed: bool,
    pub enabled: bool,
    pub notify: bool,
    pub watch_started_at: i64,
    pub updated_at: Option<i64>,
    pub dot: bool,
    /// `org` or `user` once a fetch read it; never set for Public.
    pub kind: Option<ScopeKind>,
    /// The owner login as GitHub spells it, once a fetch read it.
    pub name: Option<String>,
    /// The last time the search and status fetch of this scope succeeded.
    pub fetched_at: Option<i64>,
    pub color: ScopeColor,
}

/// The values a state change row compares against.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrevValues {
    pub review: Review,
    pub checks: Checks,
    pub base_status: BaseStatus,
    pub mergeable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrRec {
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
    pub state: PrState,
    pub is_draft: bool,
    pub review: Review,
    pub checks: Checks,
    pub base_status: BaseStatus,
    pub mergeable: bool,
    pub failed_check: Option<String>,
    pub changes_requested_by: Option<String>,
    pub updated_at: i64,
    pub is_private: bool,
    pub requested_me: bool,
    pub requested_team: bool,
    pub link_review: String,
    pub link_checks: String,
    pub link_base: String,
    pub mine: bool,
    pub unreadable: bool,
    pub snoozed: bool,
    pub added_at: Option<i64>,
    pub prev: Option<PrevValues>,
    /// When the card was last seen to disappear, recorded by the periodic
    /// pass. `None` while the card shows.
    pub gone_at: Option<i64>,
    /// The viewer's comments and threads were collected since the PR last
    /// became watched.
    pub collected: bool,
}

impl PrRec {
    /// `owner/repo#number`, the `<pr>` of the wire format.
    pub fn key(&self) -> String {
        format!("{}/{}#{}", self.owner, self.repo, self.number)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowRec {
    pub id: String,
    pub pr_id: String,
    pub kind: RowKind,
    pub text: Option<String>,
    pub counts: Option<BTreeMap<String, u32>>,
    pub actor: Option<String>,
    pub url: String,
    pub occurred_at: i64,
    pub comment_id: Option<String>,
    pub unread: bool,
    pub seen_pending: bool,
    pub done: bool,
    pub pruned: bool,
    pub notify: NotifyState,
    /// A Review requested row addressed to one of the viewer's teams.
    pub team: bool,
}

/// The last counted reactions of one of the viewer's comments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Baseline {
    pub comment_id: String,
    pub pr_id: String,
    pub counts: BTreeMap<String, u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub launch_at_login: bool,
    pub status_interval_minutes: i64,
    pub reactions_interval_minutes: i64,
    pub graphql_cost_cap: i64,
    pub notify_activity: bool,
    pub notify_state: bool,
    pub notify_reactions: bool,
    pub snooze_return_time: (u8, u8),
    pub bot_comments: BotComments,
    pub include_team_requests: bool,
    pub keep_watching_days: i64,
    pub drop_after_days: i64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            launch_at_login: true,
            status_interval_minutes: 1,
            reactions_interval_minutes: 3,
            graphql_cost_cap: 1500,
            notify_activity: true,
            notify_state: true,
            notify_reactions: true,
            snooze_return_time: (9, 0),
            bot_comments: BotComments::ListOnly,
            include_team_requests: true,
            keep_watching_days: 3,
            drop_after_days: 14,
        }
    }
}

/// A token registration. The token itself lives in the Keychain only.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TokenRec {
    /// `notifications`, `public` or a lowercase owner login.
    pub target: String,
    pub registered: bool,
    /// The last fetch got a 401: fetching with it stops until it is replaced.
    pub invalid: bool,
    pub owner: Option<String>,
    pub expires_at: Option<i64>,
    /// Granted scopes of a classic PAT.
    pub scopes: Option<Vec<String>>,
    /// A response carried `X-GitHub-SSO`.
    pub sso: bool,
    pub sso_urls: Vec<String>,
    pub last_test: Option<TestRec>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestRec {
    pub at: i64,
    pub results: Vec<TestItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestItem {
    pub item: String,
    /// `ok`, `failed` or `unverifiable`.
    pub outcome: String,
    pub missing: Option<String>,
    pub reason: Option<String>,
}

/// A review thread whose comments become Reply rows after `from_at`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadRec {
    pub id: String,
    pub pr_id: String,
    pub from_at: i64,
}

/// One of the viewer's comments, reviews, review comments or PR bodies.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnComment {
    pub id: String,
    pub pr_id: String,
    pub url: String,
    pub text: String,
    pub created_at: i64,
    /// The core already holds a baseline, or this comment starts from zero.
    pub baseline_done: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TeamRec {
    pub database_id: i64,
    pub slug: String,
}

/// A PR whose events must be fetched again from `since`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetryRec {
    pub pr_id: String,
    pub since: i64,
    pub failures: u32,
}

/// Remaining API budget as the last responses said.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Usage {
    pub rest_remaining: Option<i64>,
    pub rest_limit: Option<i64>,
    pub graphql_remaining: Option<i64>,
    pub graphql_limit: Option<i64>,
    pub cost_per_poll: Option<i64>,
}

/// What the fetcher keeps between runs. docs/tasks/M2.md, "Fetcher and core".
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FetchData {
    pub tokens: BTreeMap<String, TokenRec>,
    /// Lowercase `owner/repo#number` to PR id.
    pub pr_ids: BTreeMap<String, String>,
    pub own: BTreeMap<String, OwnComment>,
    pub threads: BTreeMap<String, ThreadRec>,
    /// Scope id to the viewer's teams that scope's token can read.
    pub teams: BTreeMap<String, Vec<TeamRec>>,
    pub retries: BTreeMap<String, RetryRec>,
    /// Notified PRs (lowercase `owner/repo#number`) not fetched yet.
    pub pending_signals: BTreeSet<String>,
    pub notif_last_modified: Option<String>,
    pub notif_since: Option<String>,
    pub poll_interval: Option<i64>,
    /// GraphQL cost by time, for the last hour.
    pub costs: Vec<(i64, i64)>,
    pub usage: Usage,
    /// Every fetch stops until this time.
    pub stopped_until: Option<i64>,
    pub stop_reason: Option<String>,
    /// The last time Include requests to my teams was turned on.
    pub team_requests_on_at: i64,
    /// The last run where the notifications check was due, even if it
    /// stopped before `/notifications`. With `poll_interval` it times the
    /// next check across restarts.
    pub notif_checked_at: Option<i64>,
}

/// Everything that outlives the process.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Data {
    pub scopes: BTreeMap<String, ScopeRec>,
    pub prs: BTreeMap<String, PrRec>,
    pub rows: BTreeMap<String, RowRec>,
    pub baselines: BTreeMap<String, Baseline>,
    pub config: Config,
    pub last_release_at: i64,
    /// How many owner scopes were ever added, for the color cycle. Saved
    /// with the meta values.
    pub color_seq: u32,
    pub fetch: FetchData,
}

/// What changed in [`Data`] since the last save.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Dirty {
    pub scopes: BTreeSet<String>,
    pub prs: BTreeSet<String>,
    pub rows: BTreeSet<String>,
    pub baselines: BTreeSet<String>,
    pub config: bool,
    pub meta: bool,
    /// Everything in [`FetchData`]; saved as a whole.
    pub fetch: bool,
}

impl Dirty {
    pub fn is_empty(&self) -> bool {
        self.scopes.is_empty()
            && self.prs.is_empty()
            && self.rows.is_empty()
            && self.baselines.is_empty()
            && !self.config
            && !self.meta
            && !self.fetch
    }
}
