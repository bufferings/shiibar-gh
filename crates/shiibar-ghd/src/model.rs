//! The daemon's own state types. Deliberately separate from the wire types in
//! `shiibar-gh-proto`: saved values must survive whatever a client can parse.

use shiibar_gh_proto as proto;
use std::collections::{BTreeMap, BTreeSet};

pub const PUBLIC: &str = "public";

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
            Self::BotComment => "Bot comment",
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
    // On a snoozed PR, waiting for the release.
    Held = "held",
    Delivered = "delivered",
});

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
    pub link_review: String,
    pub link_checks: String,
    pub link_base: String,
    pub mine: bool,
    pub unreadable: bool,
    pub snoozed: bool,
    pub added_at: Option<i64>,
    pub prev: Option<PrevValues>,
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

/// Everything that outlives the process.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Data {
    pub scopes: BTreeMap<String, ScopeRec>,
    pub prs: BTreeMap<String, PrRec>,
    pub rows: BTreeMap<String, RowRec>,
    pub baselines: BTreeMap<String, Baseline>,
    pub config: Config,
    pub last_release_at: i64,
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
}

impl Dirty {
    pub fn is_empty(&self) -> bool {
        self.scopes.is_empty()
            && self.prs.is_empty()
            && self.rows.is_empty()
            && self.baselines.is_empty()
            && !self.config
            && !self.meta
    }
}
