//! What a fetch run reads from the core before it starts, and what it hands
//! back when it ends. docs/tasks/M2.md, "Fetcher and core": the core keeps
//! everything; the fetcher only works on these copies.

use crate::model::{BaseStatus, Checks, OwnComment, PrState, ScopeKind, TeamRec, ThreadRec};
use shiibar_gh_proto::{Ingest, Warning};
use std::collections::{BTreeMap, BTreeSet};

/// Which kinds of fetch this run does.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Due {
    pub status: bool,
    pub reactions: bool,
    pub notifications: bool,
}

impl Due {
    pub fn any(self) -> bool {
        self.status || self.reactions || self.notifications
    }
}

#[derive(Debug, Clone)]
pub struct Plan {
    pub now: i64,
    pub due: Due,
    /// `refresh <scope>`: only this scope, plus the notifications.
    pub only_scope: Option<String>,
    /// `refresh` also fetches a scope stopped by a 401, once.
    pub forced: bool,
    pub notifications: TokenUse,
    pub notif_last_modified: Option<String>,
    pub notif_since: Option<String>,
    pub scopes: Vec<ScopePlan>,
    /// Lowercase logins of every registered owner.
    pub registered_owners: BTreeSet<String>,
    pub prs: BTreeMap<String, PrInfo>,
    pub pr_ids: BTreeMap<String, String>,
    pub threads: BTreeMap<String, ThreadRec>,
    pub own: BTreeMap<String, OwnComment>,
    /// PR id to the `since` its events are fetched again from.
    pub retries: BTreeMap<String, i64>,
    pub pending_signals: BTreeSet<String>,
    /// Every enabled scope, in this run or not.
    pub enabled_scopes: BTreeSet<String>,
    /// Scopes whose saved token owner differs from the notifications owner.
    pub mismatched: BTreeSet<String>,
    pub status_interval_minutes: i64,
    pub drop_after_days: i64,
    pub include_team_requests: bool,
    pub cost_cap: i64,
    pub costs: Vec<(i64, i64)>,
}

/// A token as the run may use it.
#[derive(Debug, Clone, Default)]
pub struct TokenUse {
    pub registered: bool,
    /// `None` when the Keychain has nothing for a registered token.
    pub token: Option<String>,
    /// Stopped by a 401 or past its expiry.
    pub invalid: bool,
    pub owner: Option<String>,
}

impl TokenUse {
    /// The token, when the run may call GitHub with it.
    pub fn usable(&self, forced: bool) -> Option<&str> {
        if self.invalid && !forced {
            return None;
        }
        self.token.as_deref()
    }
}

#[derive(Debug, Clone)]
pub struct ScopePlan {
    pub id: String,
    /// The search and status fetch of this scope is due in this run.
    pub status_due: bool,
    /// The owner login to search with; `None` for Public.
    pub owner: Option<String>,
    pub kind: Option<ScopeKind>,
    /// The key of the scope's token record.
    pub token_key: String,
    pub token: TokenUse,
    pub fetched_at: Option<i64>,
    pub watch_started_at: i64,
    pub teams: Vec<TeamRec>,
}

impl ScopePlan {
    pub fn public(&self) -> bool {
        self.owner.is_none()
    }

    /// DESIGN.md, "Events before the watch started": five minutes before the
    /// last success, never before the watch started.
    pub fn since(&self) -> i64 {
        match self.fetched_at {
            Some(at) => (at - 300).max(self.watch_started_at),
            None => self.watch_started_at,
        }
    }

    /// The time a new comment of the viewer starts from zero after:
    /// docs/tasks/M2.md, "Reaction".
    pub fn reaction_zero_after(&self) -> i64 {
        self.fetched_at.unwrap_or(self.watch_started_at)
    }
}

/// What the core knows about one PR.
#[derive(Debug, Clone)]
pub struct PrInfo {
    pub id: String,
    pub owner: String,
    pub repo: String,
    pub number: u64,
    pub scope: Option<String>,
    pub updated_at: i64,
    pub state: PrState,
    pub mine: bool,
    pub checks: Checks,
    pub base_status: BaseStatus,
    pub mergeable: bool,
    pub watched: bool,
    pub collected: bool,
    pub unreadable: bool,
}

impl PrInfo {
    pub fn key(&self) -> String {
        pr_key(&self.owner, &self.repo, self.number)
    }
}

/// The lowercase `owner/repo#number` the id map is keyed by.
pub fn pr_key(owner: &str, repo: &str, number: u64) -> String {
    format!("{}/{}#{number}", owner.to_lowercase(), repo.to_lowercase())
}

/// What one response said about the token it was sent with.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TokenObs {
    pub owner: Option<String>,
    pub expires_at: Option<i64>,
    pub scopes: Option<Vec<String>>,
    pub sso: bool,
    pub sso_urls: Vec<String>,
    /// `Some(true)` after a 401, `Some(false)` after any other answer.
    pub invalid: Option<bool>,
}

/// What a run learned about one scope.
#[derive(Debug, Clone, Default)]
pub struct ScopeObs {
    pub kind: Option<ScopeKind>,
    pub name: Option<String>,
    pub teams: Option<Vec<TeamRec>>,
    /// Replaces the scope's `fetch_failed` and `permission_missing`.
    pub warnings: Option<Vec<Warning>>,
}

#[derive(Debug, Clone, Default)]
pub struct Outcome {
    pub ingest: Option<Ingest>,
    pub due: Due,
    /// Scopes whose status fetch was due in this run; their timers restart.
    pub status_ran: Vec<String>,
    /// The notifications check of this run: `Some(None)` succeeded,
    /// `Some(Some(message))` failed for a reason other than 401 or a rate
    /// limit, `None` did not run or ended otherwise.
    pub notifications_check: Option<Option<String>>,
    pub tokens: BTreeMap<String, TokenObs>,
    pub scopes: BTreeMap<String, ScopeObs>,
    pub pr_ids: Vec<(String, String)>,
    pub threads: Vec<ThreadRec>,
    pub own: Vec<OwnComment>,
    pub own_gone: Vec<String>,
    /// Comments whose first Reaction fetch set the baseline.
    pub baselines_set: Vec<String>,
    /// PRs whose comments and threads were collected.
    pub collected: Vec<String>,
    pub retries_ok: Vec<String>,
    pub retries_failed: Vec<(String, i64)>,
    pub pending_signals: Option<BTreeSet<String>>,
    pub notif_last_modified: Option<String>,
    pub notif_since: Option<String>,
    pub poll_interval: Option<i64>,
    pub costs: Vec<(i64, i64)>,
    pub rest: Option<(i64, i64)>,
    pub graphql: Option<(i64, i64)>,
    pub cost_per_poll: Option<i64>,
    pub stop: Option<(i64, String)>,
}
