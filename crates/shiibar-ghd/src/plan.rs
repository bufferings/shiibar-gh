//! What a fetch run of one account reads from the core before it starts, and
//! what it hands back when it ends. The core keeps everything; the fetcher
//! only works on these copies. PR, thread and comment ids are node ids.

use crate::model::{
    BaseStatus, Checks, FailedRequest, LimitRec, OwnComment, OwnerKind, PrState, TeamRec, ThreadRec,
};
use shiibar_gh_proto::Ingest;
use std::collections::{BTreeMap, BTreeSet};

/// Which kinds of fetch this run does. `status` is the account run: every
/// enabled owner's search and status, and the notifications check when
/// `notifications` is set too.
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
    pub account: String,
    pub login: String,
    /// Never logged.
    pub token: String,
    pub notif_last_modified: Option<String>,
    pub notif_since: Option<String>,
    pub owners: Vec<OwnerPlan>,
    /// Lowercase logins of every registered owner of the account.
    pub registered_owners: BTreeSet<String>,
    pub prs: BTreeMap<String, PrInfo>,
    /// Lowercase `owner/repo#number` of every saved PR of the account, to
    /// its node id.
    pub pr_ids: BTreeMap<String, String>,
    pub threads: BTreeMap<String, ThreadRec>,
    pub own: BTreeMap<String, OwnComment>,
    /// PR id to the `since` its events are fetched again from.
    pub retries: BTreeMap<String, i64>,
    /// The owner id of each retry of a PR the core does not know.
    pub retry_owners: BTreeMap<String, String>,
    pub pending_signals: BTreeSet<String>,
    pub teams: Vec<TeamRec>,
    pub status_interval_minutes: i64,
    /// DESIGN.md, "Constants": the D of the open PR searches, in days.
    pub discovery_days: i64,
    /// The account's Dismiss records by PR node id: an open PR that left
    /// the Dismissed list. Its events are fetched only when a search finds
    /// it with a newer `updatedAt`, and it is taken (as an `IngestPr` with
    /// its events) only when they make a return trigger row; the core
    /// decides that.
    pub records: BTreeMap<String, RecordInfo>,
    /// PR node ids whose status request failed even alone: fetched again
    /// every run (`status_fetch_failed`).
    pub status_retries: BTreeSet<String>,
    /// The requests the last run could not make.
    pub failed_requests: Vec<FailedRequest>,
    /// The start of the last full run.
    pub full_run_started_at: Option<i64>,
}

/// A Dismiss record as a run needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordInfo {
    /// The owner id the PR belonged to.
    pub owner_id: String,
    /// The `updatedAt` a search hit has to pass before its events are
    /// fetched.
    pub updated_at: i64,
}

#[derive(Debug, Clone)]
pub struct OwnerPlan {
    pub id: String,
    /// The owner login; `None` for Public.
    pub login: Option<String>,
    pub kind: OwnerKind,
    pub enabled: bool,
    /// The search and status fetch of this owner is due in this run.
    pub status_due: bool,
    pub fetched_at: Option<i64>,
    pub watch_started_at: i64,
    /// The List of Review requested to my team: off searches with
    /// `user-review-requested:@me`.
    pub team_requests: bool,
}

impl OwnerPlan {
    pub fn public(&self) -> bool {
        self.login.is_none()
    }

    /// DESIGN.md, "Events before the watch started": five minutes before the
    /// last success, never before the watch started.
    pub fn since(&self) -> i64 {
        match self.fetched_at {
            Some(at) => (at - 300).max(self.watch_started_at),
            None => self.watch_started_at,
        }
    }

    /// The time a new comment of the account starts from zero after.
    pub fn reaction_zero_after(&self) -> i64 {
        self.fetched_at.unwrap_or(self.watch_started_at)
    }
}

/// What the core knows about one PR of the account.
#[derive(Debug, Clone)]
pub struct PrInfo {
    pub id: String,
    pub owner: String,
    pub repo: String,
    pub number: u64,
    /// The enabled owner it belongs to.
    pub owner_id: Option<String>,
    pub updated_at: i64,
    pub state: PrState,
    pub mine: bool,
    pub checks: Checks,
    pub base_status: BaseStatus,
    pub mergeable: bool,
    /// Not dismissed, in an enabled owner and readable: status, events and
    /// reactions are fetched.
    pub watched: bool,
    /// Dismissed: only its events are fetched, for a return trigger
    /// (DESIGN.md, "Dismiss"), never its status or reactions.
    pub dismissed: bool,
    pub collected: bool,
    pub unreadable: bool,
    /// The head commit of the last status, and the one of the last settled
    /// Checks result: a new head is a new result, whose failed check names
    /// are wanted again.
    pub head_oid: Option<String>,
    pub settled_head: Option<String>,
}

/// The lowercase `owner/repo#number` the id map is keyed by.
pub fn pr_key(owner: &str, repo: &str, number: u64) -> String {
    format!("{}/{}#{number}", owner.to_lowercase(), repo.to_lowercase())
}

/// What the responses of a run said about the account's token.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TokenObs {
    pub expires_at: Option<i64>,
    pub scopes: Option<Vec<String>>,
    /// `X-GitHub-SSO` was seen: organization ids and URLs.
    pub sso: bool,
    pub sso_orgs: Vec<i64>,
    pub sso_urls: Vec<String>,
    /// Owner ids whose search had the single-organization form, with its
    /// URL.
    pub sso_owners: BTreeMap<String, Option<String>>,
    /// `Some(true)` after a 401, `Some(false)` after any other answer.
    pub invalid: Option<bool>,
}

#[derive(Debug, Clone, Default)]
pub struct Outcome {
    pub ingest: Option<Ingest>,
    pub due: Due,
    /// The run made at least one call.
    pub ran: bool,
    /// The login `viewer` answered.
    pub login: Option<String>,
    pub teams: Option<Vec<TeamRec>>,
    pub token: TokenObs,
    /// Scopes an endpoint refused this run, and whether the endpoints that
    /// show them answered (to clear an earlier refusal).
    pub refused: BTreeSet<String>,
    pub checked: BTreeSet<String>,
    /// Why the account run failed (DESIGN.md, "Fetch success and failure"),
    /// when it did. The reaction fetch never sets it.
    pub failed: Option<String>,
    pub threads: Vec<ThreadRec>,
    pub own: Vec<OwnComment>,
    pub own_gone: Vec<String>,
    pub baselines_set: Vec<String>,
    pub collected: Vec<String>,
    pub retries_ok: Vec<String>,
    pub retries_failed: Vec<(String, i64)>,
    /// The owner id of each PR of `retries_failed` the core does not know.
    pub retry_owners: BTreeMap<String, String>,
    pub pending_signals: Option<BTreeSet<String>>,
    pub notif_last_modified: Option<String>,
    pub notif_since: Option<String>,
    pub poll_interval: Option<i64>,
    pub notifications_checked: bool,
    /// PR node ids whose `Status`, `Compare` or `Contexts` request failed
    /// even alone this run (`status_fetch_failed`), and those whose status
    /// came back this run.
    pub status_failed: Vec<String>,
    pub status_ok: Vec<String>,
    /// The requests still failed after this run; `None` keeps the list.
    pub failed_requests: Option<Vec<FailedRequest>>,
    /// Set when this run made every request.
    pub full_run_started_at: Option<i64>,
    /// This run made only the requests the last one could not, and the
    /// owners (ids) whose requests it made: what it says about SSO holds
    /// only for those owners.
    pub retry_only: bool,
    pub owners_fetched: BTreeSet<String>,
    pub rest: Option<LimitRec>,
    pub graphql: Option<LimitRec>,
    pub stop: Option<i64>,
}
