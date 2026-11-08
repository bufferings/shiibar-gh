//! The daemon core: every behavior rule of docs/DESIGN.md as state transitions
//! on plain data. No I/O and no clock of its own, so the rule tables in
//! `tests/` run against it directly.

use crate::clock::{ClockTime, Now};
use crate::model::*;
use serde_json::{Value, json};
use shiibar_gh_proto as proto;
use shiibar_gh_proto::{Ingest, IngestEvent, IngestPr, IngestReaction, Lenient, PrFilter};
use std::collections::{BTreeMap, BTreeSet, HashMap};

mod accounts;
mod fetch_api;
pub use accounts::valid_login;
pub use fetch_api::*;

const DAY_SECS: i64 = 86_400;

/// DESIGN.md, "Row kinds and states": line breaks and runs of white space
/// become one space, in notification bodies as on screen.
pub fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Rows kept per PR among read rows and done rows.
const KEEP_ROWS: usize = 3;

/// `ReactionContent` values in display order, with their emoji.
const REACTIONS: [(&str, &str); 8] = [
    ("THUMBS_UP", "👍"),
    ("THUMBS_DOWN", "👎"),
    ("LAUGH", "😄"),
    ("HOORAY", "🎉"),
    ("CONFUSED", "😕"),
    ("HEART", "❤️"),
    ("ROCKET", "🚀"),
    ("EYES", "👀"),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CmdError {
    NotFound(String),
    Invalid(String),
    Unreachable(String),
    KeychainUnavailable(String),
    Internal(String),
}

type Result<T> = std::result::Result<T, CmdError>;

fn not_found(what: impl std::fmt::Display) -> CmdError {
    CmdError::NotFound(format!("not found: {what}"))
}

/// The arguments of `list`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ListArgs {
    pub account: Option<String>,
    pub owner: Option<String>,
    pub todo: bool,
    pub filter: PrFilter,
    pub snoozed: bool,
}

/// The arguments of `activity`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ActivityArgs {
    pub account: Option<String>,
    pub owners: Vec<String>,
    pub todo: bool,
    pub filter: PrFilter,
}

pub struct Engine {
    data: Data,
    dirty: Dirty,
    rows_by_pr: HashMap<String, Vec<String>>,
    /// Accounts with an open popover or window. Never saved.
    open: BTreeSet<String>,
    /// Rows with a notification written to a connection but not confirmed.
    in_flight: BTreeSet<String>,
    /// Rows made since the last hand-over that want an individual notification.
    fresh: Vec<String>,
    /// Rows the last release moved out of hold.
    released: Vec<String>,
    notification_seq: u64,
    /// The time warnings are judged against; the daemon sets it before every
    /// command and pass.
    clock: Now,
    /// What the daemon could make of the Keychain item.
    keychain: proto::KeychainState,
    /// `fetch_failed` of each account's last run: message and retry time.
    failures: BTreeMap<String, (String, i64)>,
    /// When each kind of fetch is due next, per account. Never saved.
    timers: BTreeMap<String, Timers>,
}

/// When each kind of fetch of one account is due next, in epoch seconds.
/// The status fetch is timed per owner.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Timers {
    pub status: BTreeMap<String, i64>,
    pub reactions: i64,
    pub notifications: i64,
}

impl Engine {
    /// A database without saved state: no accounts.
    pub fn fresh(now: &Now) -> Self {
        let data = Data {
            last_release_at: now.at,
            ..Data::default()
        };
        let mut engine = Self::restore(data);
        engine.clock = now.clone();
        engine.dirty = Dirty {
            config: true,
            meta: true,
            ..Dirty::default()
        };
        engine
    }

    pub fn restore(data: Data) -> Self {
        let mut rows_by_pr: HashMap<String, Vec<String>> = HashMap::new();
        for row in data.rows.values() {
            rows_by_pr
                .entry(row.pr.clone())
                .or_default()
                .push(row.id.clone());
        }
        // The next notifications check survives a restart: X-Poll-Interval
        // counts from the last check.
        let timers = data
            .accounts
            .values()
            .map(|a| {
                let notifications = a.fetch.notif_checked_at.map_or(0, |at| {
                    at + a
                        .fetch
                        .poll_interval
                        .unwrap_or(fetch_api::DEFAULT_POLL_INTERVAL)
                        .max(1)
                });
                (
                    a.id.clone(),
                    Timers {
                        notifications,
                        ..Timers::default()
                    },
                )
            })
            .collect();
        Self {
            data,
            dirty: Dirty::default(),
            rows_by_pr,
            open: BTreeSet::new(),
            in_flight: BTreeSet::new(),
            fresh: Vec::new(),
            released: Vec::new(),
            notification_seq: 0,
            clock: Now {
                at: 0,
                tz: jiff::tz::TimeZone::UTC,
            },
            keychain: proto::KeychainState::Ok,
            failures: BTreeMap::new(),
            timers,
        }
    }

    /// The time warnings are judged against.
    pub fn set_clock(&mut self, now: &Now) {
        self.clock = now.clone();
    }

    pub fn data(&self) -> &Data {
        &self.data
    }

    pub fn dirty(&self) -> &Dirty {
        &self.dirty
    }

    pub fn clear_dirty(&mut self) {
        self.dirty = Dirty::default();
    }

    pub fn keychain_state(&self) -> proto::KeychainState {
        self.keychain
    }

    pub fn set_keychain_state(&mut self, state: proto::KeychainState) {
        self.keychain = state;
    }

    pub fn row_record(&self, id: &str) -> Option<&RowRec> {
        self.data.rows.get(id)
    }

    pub fn pr_record(&self, key: &str) -> Option<&PrRec> {
        self.data.prs.get(key)
    }

    pub fn last_release_at(&self) -> i64 {
        self.data.last_release_at
    }

    fn account_mut(&mut self, id: &str) -> Option<&mut AccountRec> {
        self.dirty.accounts.insert(id.to_string());
        self.data.accounts.get_mut(id)
    }

    fn owner_mut(&mut self, id: &str) -> Option<&mut OwnerRec> {
        self.dirty.owners.insert(id.to_string());
        self.data.owners.get_mut(id)
    }

    fn pr_mut(&mut self, key: &str) -> Option<&mut PrRec> {
        self.dirty.prs.insert(key.to_string());
        self.data.prs.get_mut(key)
    }

    fn row_mut(&mut self, id: &str) -> Option<&mut RowRec> {
        self.dirty.rows.insert(id.to_string());
        self.data.rows.get_mut(id)
    }

    fn next_seq(&mut self) -> u64 {
        self.data.seq += 1;
        self.dirty.meta = true;
        self.data.seq
    }

    // ------------------------------------------------------------ lookups

    /// The id of the account with this login, compared without case.
    pub fn account_id(&self, login: &str) -> Result<String> {
        self.data
            .accounts
            .values()
            .find(|a| a.login.eq_ignore_ascii_case(login))
            .map(|a| a.id.clone())
            .ok_or_else(|| not_found(format!("account {login}")))
    }

    pub fn account_record(&self, id: &str) -> Option<&AccountRec> {
        self.data.accounts.get(id)
    }

    pub fn owner_record(&self, id: &str) -> Option<&OwnerRec> {
        self.data.owners.get(id)
    }

    /// The owners of an account in section order: registration order,
    /// Public last.
    pub fn owners_of(&self, account: &str) -> Vec<&OwnerRec> {
        let mut owners: Vec<&OwnerRec> = self
            .data
            .owners
            .values()
            .filter(|o| o.account == account)
            .collect();
        owners.sort_by_key(|o| (o.is_public(), o.seq));
        owners
    }

    /// The id of an account's owner by login, or Public by `public`.
    pub fn owner_id(&self, account: &str, name: &str) -> Result<String> {
        let public = name.eq_ignore_ascii_case(PUBLIC);
        self.data
            .owners
            .values()
            .find(|o| {
                o.account == account
                    && if public {
                        o.is_public()
                    } else {
                        !o.is_public() && o.name.eq_ignore_ascii_case(name)
                    }
            })
            .map(|o| o.id.clone())
            .ok_or_else(|| not_found(format!("owner {name}")))
    }

    /// DESIGN.md, "Owners": the account's owner of the repository owner
    /// when registered, else the account's Public for a public repository,
    /// else nothing.
    fn resolve_owner(
        &self,
        account: &str,
        repo_owner: &str,
        is_private: bool,
    ) -> Option<&OwnerRec> {
        let mut public = None;
        for owner in self.data.owners.values().filter(|o| o.account == account) {
            if owner.is_public() {
                public = Some(owner);
            } else if owner.name.eq_ignore_ascii_case(repo_owner) {
                return Some(owner);
            }
        }
        public.filter(|_| !is_private)
    }

    fn owner_of(&self, pr: &PrRec) -> Option<&OwnerRec> {
        self.resolve_owner(&pr.account, &pr.owner, pr.is_private)
    }

    fn enabled_owner_of(&self, pr: &PrRec) -> Option<&OwnerRec> {
        self.owner_of(pr).filter(|o| o.enabled)
    }

    fn login_of(&self, account: &str) -> &str {
        self.data
            .accounts
            .get(account)
            .map_or("", |a| a.login.as_str())
    }

    pub fn authored_by_me(&self, pr: &PrRec) -> bool {
        !pr.author.is_empty() && pr.author.eq_ignore_ascii_case(self.login_of(&pr.account))
    }

    fn assigned_to_me(&self, pr: &PrRec) -> bool {
        let login = self.login_of(&pr.account);
        pr.assignees.iter().any(|a| a.eq_ignore_ascii_case(login))
    }

    /// DESIGN.md, "What the filters mean": a review is still requested from
    /// the account, or from its team while the team kind's List is on.
    fn review_requested(&self, pr: &PrRec, owner: &OwnerRec) -> bool {
        pr.state == PrState::Open
            && (pr.requested_me
                || (pr.requested_team && owner.events.cell(EventKind::TeamReviewRequested).list))
    }

    fn rows_of(&self, pr: &str) -> impl Iterator<Item = &RowRec> {
        self.rows_by_pr
            .get(pr)
            .into_iter()
            .flatten()
            .filter_map(|id| self.data.rows.get(id))
    }

    // ---------------------------------------------------------- exclusions

    fn repo_exclusion(&self, pr: &PrRec, owner: &OwnerRec) -> Option<ExclusionState> {
        let name = pr.repo_name();
        owner
            .repos
            .iter()
            .find(|e| e.name.eq_ignore_ascii_case(&name))
            .map(|e| e.state)
    }

    fn user_exclusion(&self, row: &RowRec, owner: &OwnerRec) -> Option<ExclusionState> {
        if !row.kind.has_actor() {
            return None;
        }
        let actor = user_key(row.actor.as_deref()?);
        owner
            .users
            .iter()
            .find(|e| user_key(&e.name) == actor)
            .map(|e| e.state)
    }

    /// The stronger of the repository's and the actor's exclusion.
    fn exclusion(&self, row: &RowRec, pr: &PrRec, owner: &OwnerRec) -> Option<ExclusionState> {
        match (
            self.repo_exclusion(pr, owner),
            self.user_exclusion(row, owner),
        ) {
            (Some(ExclusionState::Hidden), _) | (_, Some(ExclusionState::Hidden)) => {
                Some(ExclusionState::Hidden)
            }
            (Some(_), _) | (_, Some(_)) => Some(ExclusionState::ListOnly),
            _ => None,
        }
    }

    /// A row the list shows: not pruned, its kind's List on, not Hidden.
    fn row_shown(&self, row: &RowRec, pr: &PrRec, owner: &OwnerRec) -> bool {
        !row.pruned
            && owner.events.cell(row.kind.event()).list
            && self.exclusion(row, pr, owner) != Some(ExclusionState::Hidden)
    }

    fn repo_hidden(&self, pr: &PrRec, owner: &OwnerRec) -> bool {
        self.repo_exclusion(pr, owner) == Some(ExclusionState::Hidden)
    }

    // ---------------------------------------------------------------- Todo

    /// The newest shown Review requested row of a PR, of either kind.
    fn latest_review_request(&self, pr: &PrRec, owner: &OwnerRec) -> Option<&RowRec> {
        self.rows_of(&pr.key)
            .filter(|r| r.kind.is_review_request() && self.row_shown_unpruned(r, pr, owner))
            .min_by(|a, b| {
                b.occurred_at
                    .cmp(&a.occurred_at)
                    .then_with(|| a.id.cmp(&b.id))
            })
    }

    /// Like [`Self::row_shown`] without the pruning: a pruned request row is
    /// still the latest one.
    fn row_shown_unpruned(&self, row: &RowRec, pr: &PrRec, owner: &OwnerRec) -> bool {
        owner.events.cell(row.kind.event()).list
            && self.exclusion(row, pr, owner) != Some(ExclusionState::Hidden)
    }

    /// DESIGN.md, "Review requested rows": whether a Review requested row
    /// is still something to do.
    fn still_requested(&self, row: &RowRec, pr: &PrRec, owner: &OwnerRec) -> bool {
        pr.state == PrState::Open
            && (pr.requested_me
                || (pr.requested_team && owner.events.cell(EventKind::TeamReviewRequested).todo))
            && self
                .latest_review_request(pr, owner)
                .is_some_and(|latest| latest.id == row.id)
    }

    /// DESIGN.md, "Row state transitions": the hand value when set, else the
    /// table's value. Review requested rows follow the table as it is now
    /// and count only while still requested.
    fn row_todo(&self, row: &RowRec, pr: &PrRec, owner: &OwnerRec) -> bool {
        let rr = row.kind.is_review_request();
        let base = match row.todo_manual {
            Some(value) => value,
            None if rr => {
                owner.events.cell(row.kind.event()).todo && self.exclusion(row, pr, owner).is_none()
            }
            None => row.todo_auto,
        };
        base && (!rr || self.still_requested(row, pr, owner))
    }

    /// Unread, or Todo and not done, among the rows shown.
    fn has_business(&self, pr: &PrRec, owner: &OwnerRec) -> bool {
        self.rows_of(&pr.key).any(|row| {
            self.row_shown(row, pr, owner)
                && (row.unread || (!row.done && self.row_todo(row, pr, owner)))
        })
    }

    /// DESIGN.md, "When cards appear and disappear", without the Snooze rule.
    fn would_show(&self, pr: &PrRec, owner: &OwnerRec, now: i64) -> bool {
        if pr.unreadable || self.repo_hidden(pr, owner) {
            return false;
        }
        if self.has_business(pr, owner) {
            return true;
        }
        if pr.state != PrState::Open {
            return false;
        }
        if self.authored_by_me(pr) {
            return true;
        }
        if pr.is_draft {
            return false;
        }
        let limit = self.data.config.drop_after_days.saturating_mul(DAY_SECS);
        now.saturating_sub(pr.updated_at) <= limit
    }

    /// The card of an unsnoozed PR shows, or a snoozed one would.
    fn shows(&self, pr: &PrRec, owner: &OwnerRec, now: i64) -> bool {
        !pr.unreadable
            && !self.repo_hidden(pr, owner)
            && (pr.snoozed || self.would_show(pr, owner, now))
    }

    fn has_open_todo(&self, pr: &PrRec, owner: &OwnerRec) -> bool {
        self.rows_of(&pr.key)
            .any(|row| self.row_shown(row, pr, owner) && !row.done && self.row_todo(row, pr, owner))
    }

    /// DESIGN.md, "Todo definition": not snoozed, with an open Todo row.
    fn pr_todo(&self, pr: &PrRec, owner: &OwnerRec) -> bool {
        !pr.snoozed
            && !pr.unreadable
            && !self.repo_hidden(pr, owner)
            && self.has_open_todo(pr, owner)
    }

    // ------------------------------------------------------------ wire

    fn wire_row(&self, row: &RowRec, pr: &PrRec, owner: &OwnerRec) -> proto::Row {
        proto::Row {
            id: row.id.clone(),
            pr: pr.display_key(),
            pr_title: pr.title.clone(),
            account: pr.account.clone(),
            owner: owner.id.clone(),
            kind: Lenient::Known(row.kind.into()),
            todo: self.row_todo(row, pr, owner),
            done: row.done,
            text: row.text.clone(),
            counts: row.counts.clone(),
            actor: row.actor.clone(),
            url: row.url.clone(),
            occurred_at: row.occurred_at,
            unread: row.unread,
        }
    }

    fn wire_rows(&self, pr: &PrRec, owner: &OwnerRec) -> Vec<proto::Row> {
        let mut rows: Vec<proto::Row> = self
            .rows_of(&pr.key)
            .filter(|row| self.row_shown(row, pr, owner))
            .map(|row| self.wire_row(row, pr, owner))
            .collect();
        sort_rows(&mut rows);
        rows
    }

    fn wire_card(&self, pr: &PrRec, owner: &OwnerRec, now: &Now) -> proto::Card {
        let label = match pr.state {
            PrState::Merged => proto::StateLabel::Merged,
            PrState::Closed => proto::StateLabel::Closed,
            PrState::Open if pr.is_draft => proto::StateLabel::Draft,
            PrState::Open if pr.mergeable => proto::StateLabel::Mergeable,
            PrState::Open => proto::StateLabel::Open,
        };
        let return_time = self.data.config.snooze_return_time;
        proto::Card {
            id: pr.key.clone(),
            pr: pr.display_key(),
            account: pr.account.clone(),
            owner: owner.id.clone(),
            title: pr.title.clone(),
            url: pr.url.clone(),
            author: pr.author.clone(),
            author_avatar_url: pr.author_avatar_url.clone(),
            authored_by_me: self.authored_by_me(pr),
            assigned_to_me: self.assigned_to_me(pr),
            review_requested: self.review_requested(pr, owner),
            state_label: Lenient::Known(label),
            review: Lenient::Known(pr.review.into()),
            checks: Lenient::Known(pr.checks.into()),
            base_status: Lenient::Known(pr.base_status.into()),
            base: pr.base.clone(),
            head: pr.head.clone(),
            snoozed: pr.snoozed,
            snoozed_until: pr.snoozed.then(|| now.next_return_at(return_time)),
            added_at: pr.added_at,
            links: proto::Links {
                review: pr.link_review.clone(),
                checks: pr.link_checks.clone(),
                base: pr.link_base.clone(),
            },
            rows: self.wire_rows(pr, owner),
        }
    }

    fn passes(&self, pr: &PrRec, owner: &OwnerRec, filter: PrFilter) -> bool {
        match filter {
            PrFilter::All => true,
            PrFilter::Authored => self.authored_by_me(pr),
            PrFilter::Assigned => self.assigned_to_me(pr),
            PrFilter::ReviewRequested => self.review_requested(pr, owner),
        }
    }

    /// The accounts a request names: one, or every account.
    fn accounts_named(&self, account: Option<&str>) -> Result<Vec<String>> {
        match account {
            Some(login) => Ok(vec![self.account_id(login)?]),
            None => Ok(self.data.accounts.keys().cloned().collect()),
        }
    }

    /// Owner ids by name across the given accounts; a name no account has
    /// is `not_found`.
    fn owners_named(&self, accounts: &[String], names: &[String]) -> Result<BTreeSet<String>> {
        let mut out = BTreeSet::new();
        for name in names {
            let found: Vec<String> = accounts
                .iter()
                .filter_map(|a| self.owner_id(a, name).ok())
                .collect();
            if found.is_empty() {
                return Err(not_found(format!("owner {name}")));
            }
            out.extend(found);
        }
        Ok(out)
    }

    /// The PRs a `list` or `activity` covers, in section order.
    fn matching(
        &self,
        accounts: &[String],
        owners: Option<&BTreeSet<String>>,
        todo: bool,
        filter: PrFilter,
        snoozed: bool,
        now: i64,
    ) -> Vec<(&PrRec, &OwnerRec)> {
        let mut out = Vec::new();
        for pr in self.data.prs.values() {
            if !accounts.contains(&pr.account) {
                continue;
            }
            let Some(owner) = self.enabled_owner_of(pr) else {
                continue;
            };
            if owners.is_some_and(|set| !set.contains(&owner.id))
                || !self.shows(pr, owner, now)
                || pr.snoozed != snoozed
                || !self.passes(pr, owner, filter)
            {
                continue;
            }
            // A snoozed PR is never a Todo PR; in the Snoozed section the
            // Todo filter keeps the PRs with an open Todo row.
            if todo && !self.has_open_todo(pr, owner) {
                continue;
            }
            out.push((pr, owner));
        }
        let account_seq = |id: &str| self.data.accounts.get(id).map_or(0, |a| a.seq);
        out.sort_by(|(a, ao), (b, bo)| {
            (account_seq(&a.account), ao.is_public(), ao.seq)
                .cmp(&(account_seq(&b.account), bo.is_public(), bo.seq))
                .then_with(|| b.added_at.cmp(&a.added_at))
                .then_with(|| a.key.cmp(&b.key))
        });
        out
    }

    pub fn list(&self, args: &ListArgs, now: &Now) -> Result<Vec<proto::Card>> {
        let accounts = self.accounts_named(args.account.as_deref())?;
        let owners = args
            .owner
            .as_ref()
            .map(|o| self.owners_named(&accounts, std::slice::from_ref(o)))
            .transpose()?;
        Ok(self
            .matching(
                &accounts,
                owners.as_ref(),
                args.todo,
                args.filter,
                args.snoozed,
                now.at,
            )
            .into_iter()
            .map(|(pr, owner)| self.wire_card(pr, owner, now))
            .collect())
    }

    pub fn activity(&self, args: &ActivityArgs, now: &Now) -> Result<Vec<proto::Row>> {
        let accounts = self.accounts_named(args.account.as_deref())?;
        let owners = (!args.owners.is_empty())
            .then(|| self.owners_named(&accounts, &args.owners))
            .transpose()?;
        let mut rows: Vec<proto::Row> = self
            .matching(
                &accounts,
                owners.as_ref(),
                args.todo,
                args.filter,
                false,
                now.at,
            )
            .into_iter()
            .flat_map(|(pr, owner)| self.wire_rows(pr, owner))
            .collect();
        sort_rows(&mut rows);
        Ok(rows)
    }

    /// A PR a command may act on: known, in an enabled owner and readable.
    fn usable_pr(&self, account: &str, key: &str) -> Result<&PrRec> {
        let account = self.account_id(account)?;
        self.data
            .prs
            .values()
            .find(|pr| pr.account == account && same_pr(pr, key))
            .filter(|pr| !pr.unreadable && self.enabled_owner_of(pr).is_some())
            .ok_or_else(|| not_found(format!("PR {key}")))
    }

    /// A row a command may act on. A pruned row counts as gone.
    fn usable_row(&self, id: &str) -> Result<(&RowRec, &PrRec, &OwnerRec)> {
        self.data
            .rows
            .get(id)
            .filter(|row| !row.pruned)
            .and_then(|row| {
                let pr = self.data.prs.get(&row.pr)?;
                Some((row, pr, self.enabled_owner_of(pr)?))
            })
            .filter(|(_, pr, _)| !pr.unreadable)
            .ok_or_else(|| not_found(format!("row {id}")))
    }

    pub fn status(&self, account: &str, key: &str, now: &Now) -> Result<proto::Card> {
        let pr = self.usable_pr(account, key)?;
        let owner = self
            .enabled_owner_of(pr)
            .ok_or_else(|| not_found(format!("PR {key}")))?;
        Ok(self.wire_card(pr, owner, now))
    }

    pub fn open_pr(&self, account: &str, key: &str) -> Result<String> {
        Ok(self.usable_pr(account, key)?.url.clone())
    }

    pub fn open_row(&self, account: Option<&str>, id: &str) -> Result<String> {
        let (row, _, _) = self.usable_row(id)?;
        if let Some(login) = account
            && self.account_id(login)? != row.account
        {
            return Err(not_found(format!("row {id}")));
        }
        Ok(row.url.clone())
    }

    /// Per account, its value and every card a client would show for it.
    /// Two equal digests mean no `account_changed` is due.
    pub fn digest(&self, now: &Now) -> BTreeMap<String, (proto::Account, Vec<proto::Card>)> {
        let mut digest = BTreeMap::new();
        for account in self.accounts() {
            let ids = vec![account.id.clone()];
            let mut cards = Vec::new();
            for snoozed in [false, true] {
                cards.extend(
                    self.matching(&ids, None, false, PrFilter::All, snoozed, now.at)
                        .into_iter()
                        .map(|(pr, owner)| self.wire_card(pr, owner, now)),
                );
            }
            digest.insert(account.id.clone(), (account, cards));
        }
        digest
    }

    // ------------------------------------------------------------- ingest

    /// Apply what a fetch of one account, or `dev_ingest`, brought.
    pub fn ingest(&mut self, account: &str, ingest: Ingest, now: &Now) -> Result<()> {
        if !self.data.accounts.contains_key(account) {
            return Err(not_found(format!("account {account}")));
        }
        let incoming: BTreeSet<&str> = ingest.prs.iter().map(|p| p.id.as_str()).collect();
        let referenced = ingest
            .events
            .iter()
            .map(|e| e.pr_id.as_str())
            .chain(ingest.reactions.iter().map(|r| r.pr_id.as_str()));
        for pr_id in referenced {
            if !incoming.contains(pr_id) && !self.data.prs.contains_key(&join_key(account, pr_id)) {
                return Err(CmdError::Invalid(format!("unknown pr_id: {pr_id}")));
            }
        }

        for id in &ingest.missing_pr_ids {
            let key = join_key(account, id);
            let owner = self
                .data
                .prs
                .get(&key)
                .and_then(|pr| self.enabled_owner_of(pr))
                .map(|o| o.id.clone());
            if owner.is_some()
                && !incoming.contains(id.as_str())
                && let Some(pr) = self.pr_mut(&key)
            {
                pr.unreadable = true;
            }
        }

        // PRs fetched for the first time since their owner's watch started.
        let mut first_fetch = BTreeSet::new();
        for incoming in ingest.prs {
            let Some(owner) = self.resolve_owner(account, &incoming.owner, incoming.is_private)
            else {
                continue;
            };
            if !owner.enabled {
                continue;
            }
            let key = join_key(account, &incoming.id);
            if self.apply_pr(account, incoming, now) {
                first_fetch.insert(key);
            }
        }
        for event in ingest.events {
            self.apply_event(account, event, &first_fetch);
        }
        for reaction in ingest.reactions {
            self.apply_reaction(account, reaction, now);
        }
        if let Some(list) = ingest.succeeded_owners {
            for name in list {
                if let Ok(id) = self.owner_id(account, &name)
                    && let Some(owner) = self.owner_mut(&id)
                {
                    owner.fetched_at = Some(now.at);
                }
            }
        }
        self.settle(now);
        Ok(())
    }

    /// Returns true when there was no previous value to compare against.
    fn apply_pr(&mut self, account: &str, p: IngestPr, now: &Now) -> bool {
        let key = join_key(account, &p.id);
        let existing = self.data.prs.get(&key);
        let prev = existing.and_then(|pr| pr.prev);
        let reopened =
            p.state == proto::PrState::Open && existing.is_some_and(|pr| pr.state != PrState::Open);
        let readable_again = existing.is_some_and(|pr| pr.unreadable);
        let record = PrRec {
            key: key.clone(),
            account: account.to_string(),
            unreadable: false,
            snoozed: existing.is_some_and(|pr| pr.snoozed),
            added_at: existing.and_then(|pr| pr.added_at),
            prev: Some(PrevValues {
                review: p.review.into(),
                checks: p.checks.into(),
                base_status: p.base_status.into(),
                mergeable: p.mergeable,
            }),
            state: p.state.into(),
            is_draft: p.is_draft,
            review: p.review.into(),
            checks: p.checks.into(),
            base_status: p.base_status.into(),
            mergeable: p.mergeable,
            failed_check: p.failed_check,
            changes_requested_by: p.changes_requested_by,
            updated_at: p.updated_at,
            is_private: p.is_private,
            requested_me: p.requested_me,
            requested_team: p.requested_team,
            assignees: p.assignees,
            gone_at: existing.and_then(|pr| pr.gone_at),
            collected: existing.is_some_and(|pr| pr.collected),
            link_review: p.links.review,
            link_checks: p.links.checks,
            link_base: p.links.base,
            id: p.id,
            owner: p.owner,
            repo: p.repo,
            number: p.number,
            url: p.url,
            title: p.title,
            author: p.author,
            author_avatar_url: p.author_avatar_url,
            base: p.base,
            head: p.head,
        };
        self.dirty.prs.insert(key.clone());
        self.data.prs.insert(key.clone(), record);
        if reopened {
            self.restore_review_request(&key);
        }
        if readable_again && !self.data.prs[&key].snoozed {
            self.raise_dot_for_unread(&key);
        }
        match prev {
            Some(prev) => {
                self.state_change_rows(&key, prev, now);
                false
            }
            None => true,
        }
    }

    /// DESIGN.md, "Review requested rows": reopening returns the row to
    /// Todo, even from the pruned rows.
    fn restore_review_request(&mut self, key: &str) {
        let Some(pr) = self.data.prs.get(key) else {
            return;
        };
        let Some(owner) = self.owner_of(pr) else {
            return;
        };
        let restored = self
            .latest_review_request(pr, owner)
            .filter(|latest| latest.pruned && self.row_todo(latest, pr, owner))
            .map(|latest| latest.id.clone());
        if let Some(row) = restored.and_then(|id| self.row_mut(&id)) {
            row.pruned = false;
        }
    }

    /// DESIGN.md, "State change rows".
    fn state_change_rows(&mut self, key: &str, prev: PrevValues, now: &Now) {
        let Some(pr) = self.data.prs.get(key) else {
            return;
        };
        if !self.authored_by_me(pr) || pr.state != PrState::Open {
            return;
        }
        let mut made = Vec::new();
        if prev.checks != Checks::Failed && pr.checks == Checks::Failed {
            made.push((
                RowKind::ChecksFailed,
                pr.failed_check.clone(),
                pr.link_checks.clone(),
            ));
        }
        if prev.base_status != BaseStatus::Conflicts && pr.base_status == BaseStatus::Conflicts {
            made.push((RowKind::Conflicts, None, pr.link_base.clone()));
        }
        if prev.review != Review::ChangesRequested && pr.review == Review::ChangesRequested {
            made.push((
                RowKind::ChangesRequested,
                pr.changes_requested_by.clone(),
                pr.link_review.clone(),
            ));
        }
        if !prev.mergeable && pr.mergeable {
            made.push((RowKind::Mergeable, None, pr.url.clone()));
        }
        let account = pr.account.clone();
        let node = pr.id.clone();
        for (kind, text, url) in made {
            self.add_row(
                RowRec {
                    id: join_key(&account, &format!("{node}:{}:{}", kind.as_str(), now.at)),
                    account: account.clone(),
                    pr: key.to_string(),
                    kind,
                    text,
                    url,
                    occurred_at: now.at,
                    ..row_defaults()
                },
                false,
            );
        }
    }

    /// DESIGN.md, "Events before the watch started". Returns the owner when
    /// the event's PR belongs to an enabled one.
    fn apply_event(
        &mut self,
        account: &str,
        event: IngestEvent,
        first_fetch: &BTreeSet<String>,
    ) -> Option<String> {
        let key = join_key(account, &event.pr_id);
        let pr = self.data.prs.get(&key)?;
        let owner = self.enabled_owner_of(pr)?;
        let owner_id = owner.id.clone();
        let mut silent = false;
        if event.occurred_at < owner.watch_started_at {
            let requested = match event.kind {
                proto::IngestKind::ReviewRequested => pr.requested_me,
                proto::IngestKind::TeamReviewRequested => pr.requested_team,
                _ => false,
            };
            if !(requested && first_fetch.contains(&key)) {
                return Some(owner_id);
            }
            silent = true;
        }
        let id = match event.kind {
            // An approving review with a body also makes a Comment row
            // keyed by the review itself.
            proto::IngestKind::Approved => join_key(account, &format!("{}:approved", event.id)),
            _ => join_key(account, &event.id),
        };
        self.add_row(
            RowRec {
                id,
                account: account.to_string(),
                pr: key,
                kind: event.kind.into(),
                text: event.text,
                actor: event.actor,
                url: event.url,
                occurred_at: event.occurred_at,
                comment_id: event.comment_id,
                ..row_defaults()
            },
            silent,
        );
        Some(owner_id)
    }

    /// DESIGN.md, "Reaction rows".
    fn apply_reaction(
        &mut self,
        account: &str,
        reaction: IngestReaction,
        now: &Now,
    ) -> Option<String> {
        let key = join_key(account, &reaction.pr_id);
        let pr = self.data.prs.get(&key)?;
        let owner = self.enabled_owner_of(pr)?;
        let owner_id = owner.id.clone();
        let baseline_key = join_key(account, &reaction.comment_id);
        let base = match self.data.baselines.get(&baseline_key) {
            Some(baseline) => Some(baseline.counts.clone()),
            None if reaction.comment_created_at < owner.watch_started_at => None,
            None => Some(BTreeMap::new()),
        };
        if reaction.watching
            && let Some(base) = base
        {
            for (content, count) in &reaction.counts {
                let delta = count.saturating_sub(base.get(content).copied().unwrap_or(0));
                if delta == 0 {
                    continue;
                }
                self.add_row(
                    RowRec {
                        id: join_key(
                            account,
                            &format!("{}:{content}:{}", reaction.comment_id, now.at),
                        ),
                        account: account.to_string(),
                        pr: key.clone(),
                        kind: RowKind::Reaction,
                        text: Some(reaction.text.clone()),
                        counts: Some(BTreeMap::from([(content.clone(), delta)])),
                        url: reaction.url.clone(),
                        occurred_at: now.at,
                        comment_id: Some(reaction.comment_id.clone()),
                        ..row_defaults()
                    },
                    false,
                );
            }
        }
        self.dirty.baselines.insert(baseline_key.clone());
        self.data.baselines.insert(
            baseline_key.clone(),
            Baseline {
                key: baseline_key,
                pr: key,
                counts: reaction.counts,
            },
        );
        Some(owner_id)
    }

    /// DESIGN.md, "Applying the table" and "Notification decisions": List,
    /// Todo and Notify of the owner's table, the Exclusions and Skip draft
    /// pull requests decide the row when it is made. The same event never
    /// makes a second row.
    fn add_row(&mut self, mut row: RowRec, silent: bool) {
        if self.data.rows.contains_key(&row.id) {
            return;
        }
        let Some(pr) = self.data.prs.get(&row.pr) else {
            return;
        };
        let Some(owner) = self.owner_of(pr) else {
            return;
        };
        let cell = owner.events.cell(row.kind.event());
        let exclusion = self.exclusion(&row, pr, owner);
        // Recorded while List is off or the row is Hidden: read, no Todo,
        // no notification.
        let quiet = !cell.list || exclusion == Some(ExclusionState::Hidden);
        row.unread = !quiet;
        row.todo_auto = !quiet && cell.todo && exclusion.is_none();
        let notifies = !silent
            && !quiet
            && exclusion.is_none()
            && cell.notify
            && owner.notify
            && !(owner.skip_drafts && pr.is_draft)
            && !pr.unreadable;
        let snoozed = pr.snoozed;
        let unreadable = pr.unreadable;
        let account = pr.account.clone();
        row.notify = match (notifies, snoozed) {
            (false, _) => NotifyState::None,
            (true, true) => NotifyState::Held,
            (true, false) => NotifyState::Pending,
        };
        if row.notify == NotifyState::Pending {
            self.fresh.push(row.id.clone());
        }
        if row.unread
            && !snoozed
            && !unreadable
            && !self.open.contains(&account)
            && let Some(account) = self.account_mut(&account)
        {
            account.dot = true;
        }
        self.rows_by_pr
            .entry(row.pr.clone())
            .or_default()
            .push(row.id.clone());
        self.dirty.rows.insert(row.id.clone());
        self.data.rows.insert(row.id.clone(), row);
    }

    /// A card gets its fixed position the first time it qualifies.
    fn settle(&mut self, now: &Now) {
        let add: Vec<String> = self
            .data
            .prs
            .values()
            .filter(|pr| {
                pr.added_at.is_none()
                    && self
                        .enabled_owner_of(pr)
                        .is_some_and(|owner| self.would_show(pr, owner, now.at))
            })
            .map(|pr| pr.key.clone())
            .collect();
        for key in add {
            if let Some(pr) = self.pr_mut(&key) {
                pr.added_at = Some(now.at);
            }
        }
    }

    // ------------------------------------------------------- row commands

    pub fn seen(&mut self, row_ids: &[String]) {
        for id in row_ids {
            if self.data.rows.contains_key(id)
                && let Some(row) = self.row_mut(id)
            {
                row.seen_pending = true;
            }
        }
    }

    pub fn popover_opened(&mut self, account: &str) -> Result<()> {
        let id = self.account_id(account)?;
        self.open.insert(id.clone());
        if let Some(account) = self.account_mut(&id) {
            account.dot = false;
        }
        Ok(())
    }

    pub fn popover_closed(&mut self, account: &str) -> Result<()> {
        let id = self.account_id(account)?;
        self.open.remove(&id);
        let prs: Vec<String> = self
            .data
            .prs
            .values()
            .filter(|pr| pr.account == id)
            .map(|pr| pr.key.clone())
            .collect();
        for key in prs {
            self.close_rows(&key);
        }
        Ok(())
    }

    /// Unread falls on rows that were shown, then the rows of the PR are
    /// pruned. DESIGN.md, "How many rows are kept".
    fn close_rows(&mut self, key: &str) {
        let shown: Vec<String> = self
            .rows_of(key)
            .filter(|row| row.seen_pending)
            .map(|row| row.id.clone())
            .collect();
        for id in shown {
            if let Some(row) = self.row_mut(&id) {
                row.seen_pending = false;
                row.unread = false;
            }
        }
        let Some(pr) = self.data.prs.get(key) else {
            return;
        };
        let Some(owner) = self.owner_of(pr) else {
            return;
        };
        let mut candidates: Vec<&RowRec> = self
            .rows_of(key)
            .filter(|row| {
                self.row_shown(row, pr, owner)
                    && !row.unread
                    && (row.done || !self.row_todo(row, pr, owner))
            })
            .collect();
        candidates.sort_by(|a, b| {
            b.occurred_at
                .cmp(&a.occurred_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        let drop: Vec<String> = candidates
            .iter()
            .skip(KEEP_ROWS)
            .map(|row| row.id.clone())
            .collect();
        for id in drop {
            if let Some(row) = self.row_mut(&id) {
                row.pruned = true;
            }
        }
    }

    /// The connection of the app went away, or the daemon just started: the
    /// open state ends without counting as `popover_closed`.
    pub fn app_disconnected(&mut self) {
        self.open.clear();
    }

    /// `done`: only a Todo row changes. DESIGN.md, "Row state transitions".
    pub fn done(&mut self, id: &str, on: bool) -> Result<()> {
        let (row, pr, owner) = self.usable_row(id)?;
        if self.row_todo(row, pr, owner)
            && let Some(row) = self.row_mut(id)
        {
            row.done = on;
        }
        Ok(())
    }

    /// `todo`: the hand value of a row that is not done.
    pub fn todo(&mut self, id: &str, on: bool, now: &Now) -> Result<()> {
        let (row, _, _) = self.usable_row(id)?;
        if !row.done
            && let Some(row) = self.row_mut(id)
        {
            row.todo_manual = Some(on);
        }
        self.settle(now);
        Ok(())
    }

    pub fn snooze(&mut self, account: &str, key: &str, now: &Now) -> Result<()> {
        self.release_if_due(now);
        let pr = self.usable_pr(account, key)?;
        let shows = self
            .enabled_owner_of(pr)
            .is_some_and(|owner| self.would_show(pr, owner, now.at));
        if !shows {
            return Err(not_found(format!("no card for PR {key}")));
        }
        let key = pr.key.clone();
        if let Some(pr) = self.pr_mut(&key) {
            pr.snoozed = true;
        }
        self.hold_undelivered(&key);
        Ok(())
    }

    fn hold_undelivered(&mut self, key: &str) {
        let rows: Vec<String> = self
            .rows_of(key)
            .filter(|row| row.notify == NotifyState::Pending && !self.in_flight.contains(&row.id))
            .map(|row| row.id.clone())
            .collect();
        for id in rows {
            if let Some(row) = self.row_mut(&id) {
                row.notify = NotifyState::HeldUndelivered;
            }
        }
    }

    pub fn unsnooze(&mut self, account: &str, key: &str, now: &Now) -> Result<()> {
        let key = self.usable_pr(account, key)?.key.clone();
        if !self.data.prs[&key].snoozed {
            return Ok(());
        }
        self.end_snooze(&key);
        // DESIGN.md, "Snooze": a manual Unsnooze notifies nothing, and clears
        // what was held as well as what went undelivered before the Snooze.
        let held: Vec<String> = self
            .rows_of(&key)
            .filter(|row| matches!(row.notify, NotifyState::Held | NotifyState::HeldUndelivered))
            .map(|row| row.id.clone())
            .collect();
        for row in held {
            if let Some(row) = self.row_mut(&row) {
                row.notify = NotifyState::None;
            }
        }
        self.settle(now);
        Ok(())
    }

    /// Clear the flag and bring back the blue dot for unread rows.
    fn end_snooze(&mut self, key: &str) {
        if let Some(pr) = self.pr_mut(key) {
            pr.snoozed = false;
        }
        self.raise_dot_for_unread(key);
    }

    /// The rule shared by a Snooze ending and a PR becoming readable again:
    /// unread rows raise the dot unless the popover or window is open.
    fn raise_dot_for_unread(&mut self, key: &str) {
        let Some(pr) = self.data.prs.get(key).filter(|pr| !pr.unreadable) else {
            return;
        };
        let Some(owner) = self.owner_of(pr) else {
            return;
        };
        let unread = self
            .rows_of(key)
            .any(|row| row.unread && self.row_shown(row, pr, owner));
        let account = pr.account.clone();
        if unread
            && !self.open.contains(&account)
            && let Some(account) = self.account_mut(&account)
        {
            account.dot = true;
        }
    }

    /// Everything goes when a Return time passed since the last release.
    /// Waking from sleep lands here too.
    fn release_if_due(&mut self, now: &Now) {
        let latest = now.latest_return_at(self.data.config.snooze_return_time);
        if latest <= self.data.last_release_at {
            return;
        }
        self.data.last_release_at = now.at;
        self.dirty.meta = true;
        let snoozed: Vec<String> = self
            .data
            .prs
            .values()
            .filter(|pr| pr.snoozed)
            .map(|pr| pr.key.clone())
            .collect();
        for key in snoozed {
            self.end_snooze(&key);
            let held: Vec<(String, bool)> = self
                .rows_of(&key)
                .filter(|row| {
                    matches!(row.notify, NotifyState::Held | NotifyState::HeldUndelivered)
                })
                .map(|row| (row.id.clone(), row.done))
                .collect();
            for (id, done) in held {
                if let Some(row) = self.row_mut(&id) {
                    row.notify = if done {
                        NotifyState::None
                    } else {
                        NotifyState::Pending
                    };
                }
                if !done {
                    self.released.push(id);
                }
            }
        }
    }

    /// The periodic pass.
    pub fn tick(&mut self, now: &Now) {
        self.clock = now.clone();
        self.release_if_due(now);
        self.settle(now);
        self.track_watching(now);
    }

    pub fn config_get(&self, key: &str) -> Result<Value> {
        read_config(&self.data.config, key)
            .ok_or_else(|| CmdError::Invalid(format!("unknown setting: {key}")))
    }

    pub fn config_set(&mut self, key: &str, value: &Value, now: &Now) -> Result<Value> {
        let mut config = self.data.config.clone();
        write_config(&mut config, key, value).map_err(CmdError::Invalid)?;
        if key == "snooze_return_time" {
            self.release_if_due(now);
            self.data.last_release_at = now.at;
            self.dirty.meta = true;
        }
        self.data.config = config;
        self.dirty.config = true;
        self.settle(now);
        self.config_get(key)
    }

    // ------------------------------------------------------- notifications

    /// The check at hand-over: returns the account and owner when the row
    /// may still be notified, and clears the record otherwise.
    fn gate(&mut self, row_id: &str) -> Option<(String, String)> {
        let row = self.data.rows.get(row_id)?;
        if row.notify != NotifyState::Pending || self.in_flight.contains(row_id) {
            return None;
        }
        let pr = self.data.prs.get(&row.pr)?;
        let target = self
            .enabled_owner_of(pr)
            .filter(|owner| !pr.unreadable && owner.notify)
            .map(|owner| (pr.account.clone(), owner.id.clone()));
        if target.is_none()
            && let Some(row) = self.row_mut(row_id)
        {
            row.notify = NotifyState::None;
        }
        target
    }

    fn next_notification_id(&mut self, now: &Now) -> String {
        self.notification_seq += 1;
        format!("n-{}-{}", now.at, self.notification_seq)
    }

    /// What goes to the app after this command: the summaries of the release,
    /// then individual notifications. Without an app the rows stay undelivered
    /// for the summary after it reconnects.
    pub fn take_notifications(
        &mut self,
        app_connected: bool,
        now: &Now,
    ) -> Vec<proto::Notification> {
        let released = std::mem::take(&mut self.released);
        let fresh = std::mem::take(&mut self.fresh);
        if !app_connected {
            return Vec::new();
        }
        let mut out = self.summaries(released, now, Summary::BackFromSnooze);
        out.extend(self.deliver(fresh, now));
        out
    }

    /// DESIGN.md, "macOS notifications": per owner, one would-be individual
    /// notification goes out as it is, two or more become one summary. The
    /// Reaction rows of one comment from one fetch are one notification.
    fn deliver(&mut self, ids: Vec<String>, now: &Now) -> Vec<proto::Notification> {
        type Target = (String, String);
        let mut groups: Vec<(Target, Vec<String>)> = Vec::new();
        for id in ids {
            let Some(target) = self.gate(&id) else {
                continue;
            };
            let same_fetch = |row: &RowRec| (row.comment_id.clone(), row.occurred_at);
            let reaction = self
                .data
                .rows
                .get(&id)
                .filter(|row| row.kind == RowKind::Reaction)
                .map(same_fetch);
            let group = reaction.as_ref().and_then(|key| {
                groups.iter_mut().find(|(group_target, rows)| {
                    *group_target == target
                        && rows.first().is_some_and(|first| {
                            self.data.rows.get(first).is_some_and(|row| {
                                row.kind == RowKind::Reaction && same_fetch(row) == *key
                            })
                        })
                })
            });
            match group {
                Some((_, rows)) => rows.push(id),
                None => groups.push((target, vec![id])),
            }
        }
        let mut by_target: BTreeMap<Target, Vec<Vec<String>>> = BTreeMap::new();
        for (target, rows) in groups {
            by_target.entry(target).or_default().push(rows);
        }
        let mut out = Vec::new();
        for ((account, owner), groups) in by_target {
            if groups.len() == 1 {
                let rows = groups.into_iter().next().unwrap_or_default();
                if let Some(notification) = self.single(&account, &owner, rows, now) {
                    out.push(notification);
                }
            } else {
                let rows: Vec<String> = groups.into_iter().flatten().collect();
                out.push(self.summary_of(&account, &owner, rows, now, Summary::NewEvents));
            }
        }
        out
    }

    /// What an app gets when it connects: undelivered rows, grouped like any
    /// delivery (DESIGN.md, "Notification decisions").
    pub fn pending_summaries(&mut self, now: &Now) -> Vec<proto::Notification> {
        let pending: Vec<(String, String, bool)> = self
            .data
            .rows
            .values()
            .filter(|row| row.notify == NotifyState::Pending)
            .map(|row| (row.id.clone(), row.pr.clone(), row.done))
            .collect();
        let mut rows = Vec::new();
        for (id, pr, done) in pending {
            if self.in_flight.contains(&id) {
                continue;
            }
            let snoozed = self.data.prs.get(&pr).is_some_and(|p| p.snoozed);
            if snoozed {
                if let Some(row) = self.row_mut(&id) {
                    row.notify = NotifyState::HeldUndelivered;
                }
            } else if done {
                if let Some(row) = self.row_mut(&id) {
                    row.notify = NotifyState::None;
                }
            } else {
                rows.push(id);
            }
        }
        self.deliver(rows, now)
    }

    /// One summary per owner.
    fn summaries(
        &mut self,
        rows: Vec<String>,
        now: &Now,
        summary: Summary,
    ) -> Vec<proto::Notification> {
        let mut by_target: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();
        for id in rows {
            if let Some(target) = self.gate(&id) {
                by_target.entry(target).or_default().push(id);
            }
        }
        by_target
            .into_iter()
            .map(|((account, owner), rows)| self.summary_of(&account, &owner, rows, now, summary))
            .collect()
    }

    fn owner_name(&self, owner: &str) -> String {
        self.data
            .owners
            .get(owner)
            .map(|o| o.name.clone())
            .unwrap_or_default()
    }

    /// A summary of rows that already passed the gate.
    fn summary_of(
        &mut self,
        account: &str,
        owner: &str,
        rows: Vec<String>,
        now: &Now,
        summary: Summary,
    ) -> proto::Notification {
        let prs: BTreeSet<&str> = rows
            .iter()
            .filter_map(|id| self.data.rows.get(id))
            .map(|row| row.pr.as_str())
            .collect();
        let pr_count = prs.len();
        let login = self.login_of(account).to_string();
        let name = self.owner_name(owner);
        let (title, subtitle) = match summary {
            Summary::NewEvents => (
                format!(
                    "{login} · {}",
                    plural(rows.len(), "new event", "new events")
                ),
                format!("{name} · in {}", plural(pr_count, "PR", "PRs")),
            ),
            Summary::BackFromSnooze => (
                format!("{login} · Back from Snooze"),
                format!("{name} · {} had new events", plural(pr_count, "PR", "PRs")),
            ),
        };
        self.in_flight.extend(rows.iter().cloned());
        proto::Notification {
            id: self.next_notification_id(now),
            kind: Lenient::Known(proto::NotificationType::Summary),
            account: account.to_string(),
            owner: owner.to_string(),
            rows,
            pr: None,
            url: None,
            title,
            subtitle: Some(subtitle),
            body: None,
        }
    }

    /// DESIGN.md, "macOS notifications": title, subtitle and body of a row, or
    /// of the Reaction rows of one comment.
    fn single(
        &mut self,
        account: &str,
        owner: &str,
        rows: Vec<String>,
        now: &Now,
    ) -> Option<proto::Notification> {
        let row = self.data.rows.get(rows.first()?)?;
        let pr = self.data.prs.get(&row.pr)?;
        let body = if row.kind == RowKind::Reaction {
            let mut counts: BTreeMap<String, u32> = BTreeMap::new();
            for id in &rows {
                let row_counts = self.data.rows.get(id).and_then(|r| r.counts.as_ref());
                for (content, count) in row_counts.into_iter().flatten() {
                    *counts.entry(content.clone()).or_default() += count;
                }
            }
            let text = collapse_whitespace(row.text.as_deref().unwrap_or_default());
            Some(format!("{} “{text}”", reaction_summary(&counts)))
        } else {
            row.text.as_deref().map(collapse_whitespace)
        };
        let title = format!("{} · {}", self.login_of(account), row.kind.label());
        let subtitle = format!("{}/{} #{} · {}", pr.owner, pr.repo, pr.number, pr.title);
        let key = pr.display_key();
        let url = row.url.clone();
        self.in_flight.extend(rows.iter().cloned());
        Some(proto::Notification {
            id: self.next_notification_id(now),
            kind: Lenient::Known(proto::NotificationType::Single),
            account: account.to_string(),
            owner: owner.to_string(),
            rows,
            pr: Some(key),
            url: Some(url),
            title,
            subtitle: Some(subtitle),
            body,
        })
    }

    /// The notification of these rows reached the app.
    pub fn mark_delivered(&mut self, rows: &[String]) {
        for id in rows {
            self.in_flight.remove(id);
            let pending = self
                .data
                .rows
                .get(id)
                .is_some_and(|row| row.notify == NotifyState::Pending);
            if pending && let Some(row) = self.row_mut(id) {
                row.notify = NotifyState::Delivered;
            }
        }
    }

    /// The notification of these rows did not reach the app: they stay
    /// undelivered and join the next summary.
    pub fn delivery_failed(&mut self, rows: &[String]) {
        for id in rows {
            self.in_flight.remove(id);
        }
    }
}

#[derive(Clone, Copy)]
enum Summary {
    NewEvents,
    BackFromSnooze,
}

/// `<pr>` with the owner and the repository compared without regard to case,
/// the way GitHub resolves them (DESIGN.md, "CLI").
fn same_pr(pr: &PrRec, key: &str) -> bool {
    key.split_once('/').is_some_and(|(owner, rest)| {
        owner.eq_ignore_ascii_case(&pr.owner)
            && rest.eq_ignore_ascii_case(&format!("{}#{}", pr.repo, pr.number))
    })
}

fn plural(count: usize, one: &str, many: &str) -> String {
    format!("{count} {}", if count == 1 { one } else { many })
}

fn row_defaults() -> RowRec {
    RowRec {
        id: String::new(),
        account: String::new(),
        pr: String::new(),
        kind: RowKind::Comment,
        text: None,
        counts: None,
        actor: None,
        url: String::new(),
        occurred_at: 0,
        comment_id: None,
        unread: true,
        seen_pending: false,
        done: false,
        pruned: false,
        notify: NotifyState::None,
        todo_auto: false,
        todo_manual: None,
    }
}

fn sort_rows(rows: &mut [proto::Row]) {
    rows.sort_by(|a, b| {
        b.occurred_at
            .cmp(&a.occurred_at)
            .then_with(|| a.id.cmp(&b.id))
    });
}

/// `👍3 🎉1`: known reactions in a fixed order, then anything newer by name.
fn reaction_summary(counts: &BTreeMap<String, u32>) -> String {
    let known = REACTIONS
        .iter()
        .filter_map(|(content, emoji)| counts.get(*content).map(|count| format!("{emoji}{count}")));
    let unknown = counts
        .iter()
        .filter(|(content, _)| !REACTIONS.iter().any(|(known, _)| known == content))
        .map(|(content, count)| format!("{content}{count}"));
    known.chain(unknown).collect::<Vec<_>>().join(" ")
}

pub const CONFIG_KEYS: [&str; 7] = [
    "launch_at_login",
    "appearance",
    "status_interval_minutes",
    "reactions_interval_minutes",
    "snooze_return_time",
    "keep_watching_days",
    "drop_after_days",
];

pub fn read_config(config: &Config, key: &str) -> Option<Value> {
    Some(match key {
        "launch_at_login" => json!(config.launch_at_login),
        "status_interval_minutes" => json!(config.status_interval_minutes),
        "reactions_interval_minutes" => json!(config.reactions_interval_minutes),
        "snooze_return_time" => {
            let (hour, minute) = config.snooze_return_time;
            json!(format!("{hour:02}:{minute:02}"))
        }
        "appearance" => json!(config.appearance.as_str()),
        "keep_watching_days" => json!(config.keep_watching_days),
        "drop_after_days" => json!(config.drop_after_days),
        _ => return None,
    })
}

/// Validate and store one setting. The command line sends text, so a value may
/// come as its text form as well as its JSON type.
pub fn write_config(
    config: &mut Config,
    key: &str,
    value: &Value,
) -> std::result::Result<(), String> {
    match key {
        "launch_at_login" => config.launch_at_login = boolean(key, value)?,
        "status_interval_minutes" => config.status_interval_minutes = integer(key, value, 1)?,
        "reactions_interval_minutes" => config.reactions_interval_minutes = integer(key, value, 1)?,
        "snooze_return_time" => {
            config.snooze_return_time = value
                .as_str()
                .and_then(parse_clock_time)
                .ok_or_else(|| format!("{key} must be HH:MM"))?;
        }
        "appearance" => {
            config.appearance = value
                .as_str()
                .and_then(Appearance::parse)
                .ok_or_else(|| format!("{key} must be system, light or dark"))?;
        }
        "keep_watching_days" => config.keep_watching_days = integer(key, value, 0)?,
        "drop_after_days" => config.drop_after_days = integer(key, value, 1)?,
        _ => return Err(format!("unknown setting: {key}")),
    }
    Ok(())
}

fn boolean(key: &str, value: &Value) -> std::result::Result<bool, String> {
    match value {
        Value::Bool(flag) => Some(*flag),
        Value::String(text) if text == "true" => Some(true),
        Value::String(text) if text == "false" => Some(false),
        _ => None,
    }
    .ok_or_else(|| format!("{key} must be true or false"))
}

fn integer(key: &str, value: &Value, min: i64) -> std::result::Result<i64, String> {
    let number = match value {
        Value::Number(number) => number.as_i64(),
        Value::String(text) if !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()) => {
            text.parse().ok()
        }
        _ => None,
    };
    number
        .filter(|n| *n >= min)
        .ok_or_else(|| format!("{key} must be an integer of at least {min}"))
}

fn parse_clock_time(text: &str) -> Option<ClockTime> {
    let bytes = text.as_bytes();
    if bytes.len() != 5 || bytes[2] != b':' {
        return None;
    }
    let digits = |pair: &[u8]| -> Option<u8> {
        pair.iter().try_fold(0u8, |sum, byte| {
            byte.is_ascii_digit().then(|| sum * 10 + (byte - b'0'))
        })
    };
    let hour = digits(&bytes[0..2])?;
    let minute = digits(&bytes[3..5])?;
    (hour < 24 && minute < 60).then_some((hour, minute))
}
