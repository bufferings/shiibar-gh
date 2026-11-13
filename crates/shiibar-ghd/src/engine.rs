//! The daemon core: every behavior rule of docs/DESIGN.md as state transitions
//! on plain data. No I/O and no clock of its own, so the rule tables in
//! `tests/` run against it directly.

use crate::clock::Now;
use crate::model::*;
use serde_json::{Value, json};
use shiibar_gh_proto as proto;
use shiibar_gh_proto::{
    DismissedFilter, Ingest, IngestEvent, IngestPr, IngestReaction, Lenient, PrFilter, Tab,
};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

mod accounts;
mod fetch_api;
mod places;
pub use accounts::valid_login;
pub use fetch_api::*;

const DAY_SECS: i64 = 86_400;

/// DESIGN.md, "Row kinds and states": line breaks and runs of white space
/// become one space, in notification bodies as on screen.
pub fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

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

fn invalid(what: impl std::fmt::Display) -> CmdError {
    CmdError::Invalid(what.to_string())
}

/// The arguments of `list`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ListArgs {
    pub account: Option<String>,
    pub tab: Tab,
    pub owner: Option<String>,
    pub filter: PrFilter,
    pub search: Option<String>,
    pub dismissed: DismissedFilter,
}

/// The arguments of `activity`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ActivityArgs {
    pub account: Option<String>,
    pub owners: Vec<String>,
    pub filter: PrFilter,
    pub search: Option<String>,
}

/// The arguments of `place`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaceArgs {
    pub tab: proto::PlaceTab,
    pub section: Option<proto::Section>,
    pub before: Option<String>,
    pub at: Option<proto::At>,
}

/// Per account: its value, every card a client would show for it (the
/// dismissed ones included) and its Mute lists. Two equal digests mean no
/// `account_changed` is due.
pub type Digest = BTreeMap<String, (proto::Account, Vec<proto::Card>, proto::Mutes)>;

pub struct Engine {
    data: Data,
    dirty: Dirty,
    rows_by_pr: HashMap<String, Vec<String>>,
    /// PR keys with deleted rows (`older_rows`).
    pruned_prs: HashSet<String>,
    /// Accounts with an open popover or window. Never saved.
    open: BTreeSet<String>,
    /// Rows with a notification written to a connection but not confirmed.
    in_flight: BTreeSet<String>,
    /// Rows made since the last hand-over that want an individual notification.
    fresh: Vec<String>,
    notification_seq: u64,
    /// The time warnings and rows are judged against; the daemon sets it
    /// before every command and pass.
    clock: Now,
    /// What the daemon could make of the Keychain item.
    keychain: proto::KeychainState,
    /// Failed runs in a row of each account and when the first of them
    /// ended. Never saved: a restart forgets it.
    failures: BTreeMap<String, Failures>,
    /// When each kind of fetch is due next, per account. Never saved.
    timers: BTreeMap<String, Timers>,
}

/// DESIGN.md, "Fetch success and failure": the account's failed runs since
/// its last success, and the end of the first of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Failures {
    pub count: u32,
    pub first_at: i64,
}

/// When each kind of fetch of one account may run next, in epoch seconds.
/// `run` is the account run (every owner's search and status, and the
/// notifications check); `notifications` is the earliest check
/// `X-Poll-Interval` allows; `reactions` keeps its own interval.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Timers {
    pub run: i64,
    pub reactions: i64,
    pub notifications: i64,
}

/// How a row is made.
#[derive(Debug, Clone, Copy, Default)]
struct Making {
    /// No notification (a request older than the watch, the account's own
    /// reopen).
    silent: bool,
    /// Made read (the account's own reopen).
    read: bool,
}

/// Where a card shows inside its tab: its section, or Done for a card that
/// entered Done (by a merge or close, or by the user) and has not left it.
fn view_of(pr: &PrRec) -> Option<(PlacedTab, proto::Section)> {
    let place = pr.place?;
    let section = if pr.done_at.is_some() {
        proto::Section::Done
    } else {
        match place.section {
            Section::Doing => proto::Section::Doing,
            Section::Todo => proto::Section::Todo,
            Section::Waiting => proto::Section::Waiting,
            Section::Main => proto::Section::Main,
        }
    };
    Some((place.tab, section))
}

/// The order of sections in `list` of a tab.
fn section_index(section: proto::Section) -> u8 {
    match section {
        proto::Section::Doing | proto::Section::Main => 0,
        proto::Section::Todo => 1,
        proto::Section::Waiting => 2,
        proto::Section::Done => 3,
    }
}

impl Engine {
    /// A database without saved state: no accounts.
    pub fn fresh(now: &Now) -> Self {
        let mut engine = Self::restore(Data::default());
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
        let pruned_prs = data.deleted_rows.values().cloned().collect();
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
            pruned_prs,
            open: BTreeSet::new(),
            in_flight: BTreeSet::new(),
            fresh: Vec::new(),
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

    /// The time warnings and rows are judged against.
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

    /// An unreadable Keychain stops every fetch: the failures counted so far
    /// are forgotten (DESIGN.md, "Fetch success and failure").
    pub fn set_keychain_state(&mut self, state: proto::KeychainState) {
        self.keychain = state;
        if state != proto::KeychainState::Ok {
            self.failures.clear();
        }
    }

    pub fn row_record(&self, id: &str) -> Option<&RowRec> {
        self.data.rows.get(id)
    }

    pub fn pr_record(&self, key: &str) -> Option<&PrRec> {
        self.data.prs.get(key)
    }

    pub fn record(&self, key: &str) -> Option<&DismissRecord> {
        self.data.records.get(key)
    }

    /// The row id was deleted with the rows beyond the newest 20.
    pub fn row_deleted(&self, id: &str) -> bool {
        self.data.deleted_rows.contains_key(id)
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

    fn is_me(&self, account: &str, login: Option<&str>) -> bool {
        login.is_some_and(|l| !l.is_empty() && l.eq_ignore_ascii_case(self.login_of(account)))
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

    /// The card can show at all: an enabled owner and a readable PR.
    /// DESIGN.md, "When cards show, and watching".
    fn shown_owner(&self, pr: &PrRec) -> Option<&OwnerRec> {
        if pr.unreadable {
            return None;
        }
        self.enabled_owner_of(pr)
    }

    /// The card is in All (and in its tab): shown and not dismissed.
    fn in_lists(&self, pr: &PrRec) -> bool {
        pr.dismissed_at.is_none() && self.shown_owner(pr).is_some()
    }

    // ---------------------------------------------------------------- Mute

    fn mutes_of(&self, account: &str) -> Option<&MuteRec> {
        self.data.accounts.get(account).map(|a| &a.mutes)
    }

    /// DESIGN.md, "Mute": the PR, its repository or its author is muted.
    fn mute_reasons(&self, pr: &PrRec) -> Vec<proto::MuteReason> {
        let Some(mutes) = self.mutes_of(&pr.account) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        let key = pr.display_key();
        if mutes.prs.iter().any(|m| m.eq_ignore_ascii_case(&key)) {
            out.push(proto::MuteReason::Pr);
        }
        let repo = pr.repo_name();
        if mutes.repos.iter().any(|m| m.eq_ignore_ascii_case(&repo)) {
            out.push(proto::MuteReason::Repo);
        }
        if !pr.author.is_empty() && self.user_muted(&pr.account, &pr.author) {
            out.push(proto::MuteReason::Author);
        }
        out
    }

    fn card_muted(&self, pr: &PrRec) -> bool {
        !self.mute_reasons(pr).is_empty()
    }

    fn user_muted(&self, account: &str, login: &str) -> bool {
        let key = user_key(login);
        self.mutes_of(account)
            .is_some_and(|m| m.users.iter().any(|u| user_key(u) == key))
    }

    /// DESIGN.md, "Mute": every row of a muted card, and the rows a muted
    /// user caused, except Mentioned.
    fn row_muted(&self, row: &RowRec, pr: &PrRec) -> bool {
        if row.kind == RowKind::Mentioned {
            return false;
        }
        self.card_muted(pr)
            || (row.kind.has_actor()
                && row
                    .actor
                    .as_deref()
                    .is_some_and(|a| self.user_muted(&pr.account, a)))
    }

    /// A row the card shows: its kind's List is on.
    fn row_shown(&self, row: &RowRec, owner: &OwnerRec) -> bool {
        owner.events.cell(row.kind.event()).list
    }

    /// DESIGN.md, "How unread rows go away": the blue unread rows of the
    /// account's cards in the lists.
    fn blue_rows(&self, account: &str) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        for pr in self.data.prs.values().filter(|p| p.account == account) {
            if !self.in_lists(pr) {
                continue;
            }
            let Some(owner) = self.owner_of(pr) else {
                continue;
            };
            for row in self.rows_of(&pr.key) {
                if row.unread && self.row_shown(row, owner) && !self.row_muted(row, pr) {
                    out.insert(row.id.clone());
                }
            }
        }
        out
    }

    /// The menu bar dot goes up when blue unread rows appeared, unless the
    /// popover or window is open.
    fn raise_dot_if_new(&mut self, account: &str, before: &BTreeSet<String>) {
        if self.open.contains(account) {
            return;
        }
        let after = self.blue_rows(account);
        if after.difference(before).next().is_some()
            && let Some(record) = self.account_mut(account)
        {
            record.dot = true;
        }
    }

    // ------------------------------------------------------ awaiting review

    /// DESIGN.md, "Awaiting review": an open, readable PR the account did
    /// not author, with a review requested from the account, or from its team
    /// while the team kind's List is on, and no review of the account after
    /// the newest request.
    pub fn awaiting_review(&self, pr: &PrRec, owner: &OwnerRec) -> bool {
        if pr.state != PrState::Open || pr.unreadable || self.authored_by_me(pr) {
            return false;
        }
        let asked = pr.requested_me
            || (pr.requested_team && owner.events.cell(EventKind::TeamReviewRequested).list);
        if !asked {
            return false;
        }
        match pr.last_request_at {
            Some(at) => pr.my_review_at.is_none_or(|mine| mine <= at),
            None => pr.my_review_at.is_none(),
        }
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
            text: row.text.clone(),
            counts: row.counts.clone(),
            actor: row.actor.clone(),
            url: row.url.clone(),
            occurred_at: row.occurred_at,
            unread: row.unread,
            muted: self.row_muted(row, pr),
        }
    }

    /// The rows a card has: those of kinds whose List is on, newest first.
    fn wire_rows(&self, pr: &PrRec, owner: &OwnerRec) -> Vec<proto::Row> {
        let mut rows: Vec<proto::Row> = self
            .rows_of(&pr.key)
            .filter(|row| self.row_shown(row, owner))
            .map(|row| self.wire_row(row, pr, owner))
            .collect();
        sort_rows(&mut rows);
        rows
    }

    fn wire_card(
        &self,
        pr: &PrRec,
        owner: &OwnerRec,
        positions: &HashMap<String, u32>,
    ) -> proto::Card {
        let label = match pr.state {
            PrState::Merged => proto::StateLabel::Merged,
            PrState::Closed => proto::StateLabel::Closed,
            PrState::Open if pr.is_draft => proto::StateLabel::Draft,
            PrState::Open if pr.mergeable => proto::StateLabel::Mergeable,
            PrState::Open => proto::StateLabel::Open,
        };
        let placement = view_of(pr).map(|(tab, section)| {
            let position = match positions.get(&pr.key) {
                Some(position) => *position,
                None => self.position_alone(pr),
            };
            proto::Placement {
                tab: Lenient::Known(tab.into()),
                section: Lenient::Known(section),
                position,
            }
        });
        let keep = self
            .data
            .config
            .dismissed_keep_days
            .saturating_mul(DAY_SECS);
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
            awaiting_review: self.awaiting_review(pr, owner),
            state_label: Lenient::Known(label),
            review: Lenient::Known(pr.review.into()),
            checks: Lenient::Known(pr.checks.into()),
            base_status: Lenient::Known(pr.base_status.into()),
            base: pr.base.clone(),
            head: pr.head.clone(),
            added_at: pr.added_at,
            created_at: pr.created_at,
            updated_at: pr.updated_at,
            placement,
            muted: self
                .mute_reasons(pr)
                .into_iter()
                .map(Lenient::Known)
                .collect(),
            dismissed_at: pr.dismissed_at,
            dismiss_expires_at: pr.dismissed_at.map(|at| at.saturating_add(keep)),
            auto_dismiss_at: self.auto_dismiss_at(pr),
            older_rows: self.pruned_prs.contains(&pr.key),
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

    fn account_seq(&self, id: &str) -> u64 {
        self.data.accounts.get(id).map_or(0, |a| a.seq)
    }

    /// `list`. DESIGN.md, "CLI (AI integration)": `all` in owner order, open
    /// PRs first, then the newest `updatedAt`; `review` and `mine` in
    /// section order and position; the Dismissed list newest Dismiss first.
    pub fn list(&self, args: &ListArgs, _now: &Now) -> Result<Vec<proto::Card>> {
        let accounts = self.accounts_named(args.account.as_deref())?;
        let owners = args
            .owner
            .as_ref()
            .map(|o| self.owners_named(&accounts, std::slice::from_ref(o)))
            .transpose()?;
        let words = search_words(args.search.as_deref());
        let positions = self.positions();
        let mut active: Vec<(&PrRec, &OwnerRec)> = Vec::new();
        let mut dismissed: Vec<(&PrRec, &OwnerRec)> = Vec::new();
        for pr in self.data.prs.values() {
            if !accounts.contains(&pr.account) {
                continue;
            }
            let Some(owner) = self.shown_owner(pr) else {
                continue;
            };
            if owners.as_ref().is_some_and(|set| !set.contains(&owner.id))
                || !self.passes(pr, owner, args.filter)
            {
                continue;
            }
            let in_tab = match args.tab {
                Tab::All => true,
                Tab::Review => pr.place.is_some_and(|p| p.tab == PlacedTab::Review),
                Tab::Mine => pr.place.is_some_and(|p| p.tab == PlacedTab::Mine),
            };
            match (pr.dismissed_at.is_some(), args.dismissed) {
                (false, DismissedFilter::Exclude | DismissedFilter::Include) if in_tab => {
                    active.push((pr, owner));
                }
                (true, DismissedFilter::Only) => dismissed.push((pr, owner)),
                (true, DismissedFilter::Include) if in_tab => dismissed.push((pr, owner)),
                _ => {}
            }
        }
        match args.tab {
            Tab::All => active.sort_by(|(a, ao), (b, bo)| {
                (self.account_seq(&a.account), ao.is_public(), ao.seq)
                    .cmp(&(self.account_seq(&b.account), bo.is_public(), bo.seq))
                    .then_with(|| (a.state != PrState::Open).cmp(&(b.state != PrState::Open)))
                    .then_with(|| b.updated_at.cmp(&a.updated_at))
                    .then_with(|| a.key.cmp(&b.key))
            }),
            Tab::Review | Tab::Mine => active.sort_by_key(|(pr, _)| {
                let section = view_of(pr).map_or(0, |(_, s)| section_index(s));
                (
                    self.account_seq(&pr.account),
                    section,
                    positions.get(&pr.key).copied().unwrap_or(u32::MAX),
                    pr.key.clone(),
                )
            }),
        }
        dismissed.sort_by(|(a, _), (b, _)| {
            (self.account_seq(&a.account), b.dismissed_at, &a.key).cmp(&(
                self.account_seq(&b.account),
                a.dismissed_at,
                &b.key,
            ))
        });
        Ok(active
            .into_iter()
            .chain(dismissed)
            .map(|(pr, owner)| self.wire_card(pr, owner, &positions))
            .filter(|card| card_matches(card, &words))
            .collect())
    }

    /// `activity`: the rows of the cards that are not dismissed.
    pub fn activity(&self, args: &ActivityArgs, now: &Now) -> Result<Vec<proto::Row>> {
        let accounts = self.accounts_named(args.account.as_deref())?;
        let owners = (!args.owners.is_empty())
            .then(|| self.owners_named(&accounts, &args.owners))
            .transpose()?;
        let words = search_words(args.search.as_deref());
        let mut rows: Vec<proto::Row> = Vec::new();
        let list = self.list(
            &ListArgs {
                account: args.account.clone(),
                filter: args.filter,
                ..ListArgs::default()
            },
            now,
        )?;
        let keys: BTreeSet<String> = list.into_iter().map(|c| c.id).collect();
        for key in keys {
            let Some(pr) = self.data.prs.get(&key) else {
                continue;
            };
            let Some(owner) = self.shown_owner(pr) else {
                continue;
            };
            if owners.as_ref().is_some_and(|set| !set.contains(&owner.id)) {
                continue;
            }
            let fields = pr_fields(pr);
            rows.extend(
                self.wire_rows(pr, owner)
                    .into_iter()
                    .filter(|row| row_matches(&fields, row, &words)),
            );
        }
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
            .filter(|pr| self.shown_owner(pr).is_some())
            .ok_or_else(|| not_found(format!("PR {key}")))
    }

    /// A row a command may act on.
    fn usable_row(&self, id: &str) -> Result<(&RowRec, &PrRec, &OwnerRec)> {
        self.data
            .rows
            .get(id)
            .and_then(|row| {
                let pr = self.data.prs.get(&row.pr)?;
                Some((row, pr, self.shown_owner(pr)?))
            })
            .ok_or_else(|| not_found(format!("row {id}")))
    }

    /// The card of a PR as `status`, `place`, `dismiss` and `restore` answer.
    fn card_of(&self, key: &str) -> Result<proto::Card> {
        let pr = self
            .data
            .prs
            .get(key)
            .ok_or_else(|| not_found(format!("PR {key}")))?;
        let owner = self
            .shown_owner(pr)
            .ok_or_else(|| not_found(format!("PR {key}")))?;
        Ok(self.wire_card(pr, owner, &self.positions()))
    }

    pub fn status(&self, account: &str, key: &str, _now: &Now) -> Result<proto::Card> {
        let key = self.usable_pr(account, key)?.key.clone();
        self.card_of(&key)
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

    /// Per account, what an `account_changed` is about.
    pub fn digest(&self, now: &Now) -> Digest {
        let mut digest = BTreeMap::new();
        for account in self.accounts() {
            let cards = self
                .list(
                    &ListArgs {
                        account: Some(account.login.clone()),
                        dismissed: DismissedFilter::Include,
                        ..ListArgs::default()
                    },
                    now,
                )
                .unwrap_or_default();
            let mutes = self.wire_mutes(&account.id);
            digest.insert(account.id.clone(), (account, cards, mutes));
        }
        digest
    }

    // ------------------------------------------------------------- ingest

    /// Apply what a fetch of one account, or `dev_ingest`, brought.
    pub fn ingest(&mut self, account: &str, ingest: Ingest, now: &Now) -> Result<()> {
        if !self.data.accounts.contains_key(account) {
            return Err(not_found(format!("account {account}")));
        }
        self.clock = now.clone();
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

        let mut events = ingest.events;
        events.sort_by(|a, b| {
            a.occurred_at
                .cmp(&b.occurred_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        // DESIGN.md, "Merged, Closed and Reopened rows": the time of each
        // PR's MERGED_EVENT, so its paired CLOSED_EVENT makes no row
        // whatever order they come in.
        let mut merged_at: BTreeMap<String, i64> = BTreeMap::new();
        for event in &events {
            if event.kind == proto::IngestKind::Merged {
                let at = merged_at.entry(event.pr_id.clone()).or_insert(i64::MAX);
                *at = (*at).min(event.occurred_at);
            }
        }

        // PRs fetched for the first time since they were found or their
        // owner's watch started: the review requests still open become rows.
        let mut first_fetch = BTreeSet::new();
        // PRs that show only through a return trigger: closed ones the core
        // did not know, and those with a Dismiss record.
        let mut quiet: BTreeSet<String> = BTreeSet::new();
        let mut prs = ingest.prs;
        // DESIGN.md, "Mine": several new PRs are added oldest first.
        prs.sort_by(|a, b| {
            a.created_at
                .cmp(&b.created_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        for incoming in prs {
            let Some(owner) = self.resolve_owner(account, &incoming.owner, incoming.is_private)
            else {
                continue;
            };
            if !owner.enabled {
                continue;
            }
            let owner_id = owner.id.clone();
            let key = join_key(account, &incoming.id);
            match self.data.prs.get(&key) {
                Some(existing) => {
                    if existing.watch_reset
                        && existing.dismissed_at.is_none()
                        && incoming.state == proto::PrState::Open
                    {
                        first_fetch.insert(key.clone());
                    }
                    self.apply_pr(account, incoming, now);
                }
                None => {
                    let candidate = self.data.records.contains_key(&key)
                        || incoming.state != proto::PrState::Open;
                    if candidate {
                        let own: Vec<&IngestEvent> =
                            events.iter().filter(|e| e.pr_id == incoming.id).collect();
                        if !self.would_return(account, &incoming, &own, &owner_id, &merged_at) {
                            continue;
                        }
                        if self.data.records.remove(&key).is_some() {
                            self.dirty.records.insert(key.clone());
                        }
                        quiet.insert(key.clone());
                    } else {
                        first_fetch.insert(key.clone());
                    }
                    self.new_pr(account, incoming, now);
                    // DESIGN.md, "Dismiss": what happened before this return
                    // makes no row later either, when a later fetch sends it
                    // again (the overlap of the event window).
                    if candidate && let Some(pr) = self.pr_mut(&key) {
                        pr.quiet_from = Some(0);
                        pr.quiet_until = Some(now.at);
                    }
                }
            }
        }
        for (pr_id, at) in &merged_at {
            let key = join_key(account, pr_id);
            if let Some(pr) = self.data.prs.get(&key)
                && pr.merged_event_at.is_none_or(|old| old < *at)
                && let Some(pr) = self.pr_mut(&key)
            {
                pr.merged_event_at = Some(*at);
            }
        }
        // Every dismissed PR of the account is quiet: only a return trigger
        // makes a row (DESIGN.md, "Dismiss").
        let dismissed_before: BTreeSet<String> = self
            .data
            .prs
            .values()
            .filter(|p| p.account == account && p.dismissed_at.is_some())
            .map(|p| p.key.clone())
            .collect();
        quiet.extend(dismissed_before.iter().cloned());
        for event in events {
            self.apply_event(account, event, &first_fetch, &quiet, &dismissed_before);
        }
        for reaction in ingest.reactions {
            // Reactions are not watched while dismissed: a return in this
            // batch counts from the next fetch.
            if dismissed_before.contains(&join_key(account, &reaction.pr_id)) {
                continue;
            }
            self.apply_reaction(account, reaction, now);
        }
        for hit in ingest.search {
            self.apply_hit(account, &hit);
        }
        if let Some(list) = ingest.succeeded_owners {
            for name in list {
                let at = ingest
                    .owner_run_started
                    .get(&name)
                    .copied()
                    .unwrap_or(now.at);
                if let Ok(id) = self.owner_id(account, &name)
                    && let Some(owner) = self.owner_mut(&id)
                {
                    owner.fetched_at = Some(at);
                }
            }
        }
        self.settle(now);
        Ok(())
    }

    /// DESIGN.md, "API usage": a closed PR the core does not know, or a PR
    /// with only a Dismiss record, is taken only when one of its events makes
    /// a return trigger row (List on, inside the event window).
    fn would_return(
        &self,
        account: &str,
        pr: &IngestPr,
        events: &[&IngestEvent],
        owner: &str,
        merged_at: &BTreeMap<String, i64>,
    ) -> bool {
        let Some(owner) = self.data.owners.get(owner) else {
            return false;
        };
        events.iter().any(|event| {
            let kind: RowKind = event.kind.into();
            let paired = kind == RowKind::Closed
                && merged_at
                    .get(&pr.id)
                    .is_some_and(|at| event.occurred_at >= *at);
            kind.is_return_trigger()
                && !paired
                && owner.events.cell(kind.event()).list
                && event.occurred_at >= owner.watch_started_at
                && !self.data.deleted_rows.contains_key(&row_id(account, event))
        })
    }

    /// A PR the core did not know: its card, placed by DESIGN.md, "Card
    /// states" (the account's own PR in Mine; a closed one in its Done).
    fn new_pr(&mut self, account: &str, p: IngestPr, now: &Now) {
        let key = join_key(account, &p.id);
        let closed = p.state != proto::PrState::Open;
        let mut record = pr_from(account, p, None);
        record.added_at = Some(now.at);
        record.watch_reset = false;
        record.prev = Some(PrevValues {
            review: record.review,
            checks: record.checks,
            base_status: record.base_status,
            mergeable: record.mergeable,
        });
        if closed {
            record.closed_at = Some(now.at);
            record.done_at = Some(now.at);
        }
        record.settled = settled_of(record.checks);
        record.settled_head = record.head_oid.clone();
        let authored = self.authored_by_me(&record);
        self.dirty.prs.insert(key.clone());
        self.data.prs.insert(key.clone(), record);
        if authored {
            self.place_at_end(&key, PlacedTab::Mine, Section::Main);
        }
    }

    /// A known PR's new status. Returns nothing: the rows it makes are its
    /// state change rows.
    fn apply_pr(&mut self, account: &str, p: IngestPr, now: &Now) {
        let key = join_key(account, &p.id);
        let Some(existing) = self.data.prs.get(&key).cloned() else {
            return;
        };
        // A PR readable again raises the dot like a Restore (DESIGN.md,
        // "When cards show, and watching").
        let before = if existing.unreadable {
            self.blue_rows(account)
        } else {
            BTreeSet::new()
        };
        let dismissed = existing.dismissed_at.is_some();
        let mut record = pr_from(account, p, Some(&existing));
        let was_open = existing.state == PrState::Open;
        let open = record.state == PrState::Open;
        if !open && (was_open || record.closed_at.is_none()) {
            // DESIGN.md, "Review": the detection moves the card to Done
            // once, as newly done (a card already in Done takes this time
            // too); n days count from now. Later fetches of the closed PR
            // move nothing, so a card the user moved out of Done stays out.
            record.closed_at = Some(now.at);
            record.done_at = Some(now.at);
        }
        if open && !was_open {
            // A reopen takes a card in Done back to the section and rank it
            // had before Done; a card outside Done stays where it is. The
            // exceptions to the automatic Dismiss end with the reopen, so a
            // new merge or close counts its n days (DESIGN.md, "Dismiss").
            record.closed_at = None;
            record.done_at = None;
            record.keep_after_close = false;
            record.restored = false;
        }
        let prev = existing.prev;
        // A dismissed card is compared with nothing: its status comes back
        // with its return (DESIGN.md, "Dismiss").
        record.prev = if dismissed {
            None
        } else {
            Some(PrevValues {
                review: record.review,
                checks: record.checks,
                base_status: record.base_status,
                mergeable: record.mergeable,
            })
        };
        record.watch_reset = false;
        self.dirty.prs.insert(key.clone());
        self.data.prs.insert(key.clone(), record);
        match prev {
            Some(prev) if !dismissed => self.state_change_rows(&key, prev, now),
            _ => {
                if let Some(pr) = self.pr_mut(&key) {
                    pr.settled = settled_of(pr.checks);
                    pr.settled_head = pr.head_oid.clone();
                }
            }
        }
        if existing.unreadable {
            self.raise_dot_if_new(account, &before);
        }
    }

    /// DESIGN.md, "State change rows", with Checks compared as settled
    /// results.
    fn state_change_rows(&mut self, key: &str, prev: PrevValues, now: &Now) {
        let Some(pr) = self.data.prs.get(key) else {
            return;
        };
        let checks = pr.checks;
        let settled_now = settled_of(checks);
        let new_settle =
            settled_now.is_some() && (prev.checks != checks || pr.settled_head != pr.head_oid);
        let mut made = Vec::new();
        if self.authored_by_me(pr) && pr.state == PrState::Open {
            let mergeable = !prev.mergeable && pr.mergeable;
            if new_settle && checks == Checks::Failed {
                made.push((
                    RowKind::ChecksFailed,
                    pr.failed_check.clone(),
                    pr.link_checks.clone(),
                ));
            }
            if new_settle
                && checks == Checks::Passed
                && pr.settled != Some(Checks::Passed)
                && !mergeable
            {
                made.push((RowKind::ChecksPassed, None, pr.link_checks.clone()));
            }
            if prev.base_status != BaseStatus::Conflicts && pr.base_status == BaseStatus::Conflicts
            {
                made.push((RowKind::Conflicts, None, pr.link_base.clone()));
            }
            if prev.review != Review::ChangesRequested && pr.review == Review::ChangesRequested {
                made.push((
                    RowKind::ChangesRequested,
                    pr.changes_requested_by.clone(),
                    pr.link_review.clone(),
                ));
            }
            if mergeable {
                made.push((RowKind::Mergeable, None, pr.url.clone()));
            }
        }
        let account = pr.account.clone();
        let node = pr.id.clone();
        if new_settle && let Some(pr) = self.pr_mut(key) {
            pr.settled = settled_now;
            pr.settled_head = pr.head_oid.clone();
        }
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
                Making::default(),
            );
        }
    }

    /// One event of a fetch. DESIGN.md, "Events before the watch started",
    /// "Dismiss" and "Review".
    fn apply_event(
        &mut self,
        account: &str,
        event: IngestEvent,
        first_fetch: &BTreeSet<String>,
        quiet: &BTreeSet<String>,
        dismissed_before: &BTreeSet<String>,
    ) {
        let key = join_key(account, &event.pr_id);
        let Some(pr) = self.data.prs.get(&key) else {
            return;
        };
        let Some(owner) = self.enabled_owner_of(pr) else {
            return;
        };
        let kind: RowKind = event.kind.into();
        let watch_started = owner.watch_started_at;
        let listed = owner.events.cell(kind.event()).list;
        let requested_now = match kind {
            RowKind::ReviewRequested => pr.requested_me,
            RowKind::TeamReviewRequested => pr.requested_team,
            _ => false,
        };
        let open = pr.state == PrState::Open;
        // DESIGN.md, "Awaiting review": the newest request is kept whether
        // or not it makes a row.
        if kind.is_review_request()
            && pr.last_request_at.is_none_or(|at| at < event.occurred_at)
            && let Some(pr) = self.pr_mut(&key)
        {
            pr.last_request_at = Some(event.occurred_at);
        }
        if kind == RowKind::Closed
            && self
                .data
                .prs
                .get(&key)
                .and_then(|p| p.merged_event_at)
                .is_some_and(|at| event.occurred_at >= at)
        {
            return;
        }
        let quiet_pr = quiet.contains(&key);
        // DESIGN.md, "Dismiss": what happened while dismissed makes no row
        // after the return either.
        let pr = &self.data.prs[&key];
        let while_dismissed = !quiet_pr
            && pr.quiet_from.is_some_and(|from| event.occurred_at >= from)
            && pr
                .quiet_until
                .is_some_and(|until| event.occurred_at < until);
        if while_dismissed {
            return;
        }
        if quiet_pr {
            let dismissed = self
                .data
                .prs
                .get(&key)
                .is_some_and(|p| p.dismissed_at.is_some());
            if dismissed && let Some(pr) = self.pr_mut(&key) {
                match kind {
                    RowKind::Merged | RowKind::Closed => pr.seen_closed = true,
                    RowKind::Reopened => pr.seen_closed = false,
                    _ => {}
                }
            }
            if !kind.is_return_trigger() {
                return;
            }
        }
        let mut making = Making::default();
        if event.occurred_at < watch_started {
            let exception = first_fetch.contains(&key) && open && requested_now && !quiet_pr;
            if !exception {
                return;
            }
            making.silent = true;
        }
        if kind == RowKind::Reopened && self.is_me(account, event.actor.as_deref()) {
            making.silent = true;
            making.read = true;
        }
        let row = RowRec {
            id: row_id(account, &event),
            account: account.to_string(),
            pr: key.clone(),
            kind,
            text: event.text,
            actor: event.actor,
            url: event.url,
            occurred_at: event.occurred_at,
            comment_id: event.comment_id,
            ..row_defaults()
        };
        if self.data.rows.contains_key(&row.id) || self.data.deleted_rows.contains_key(&row.id) {
            return;
        }
        let returning = quiet_pr && listed && kind.is_return_trigger();
        if returning
            && self
                .data
                .prs
                .get(&key)
                .is_some_and(|p| p.dismissed_at.is_some())
        {
            self.return_card(&key, false);
        }
        if !self.add_row(row, making) {
            return;
        }
        // DESIGN.md, "Review": a review request row puts an unplaced PR at
        // the end of Todo; a dismissed PR does not move by this rule.
        if listed && kind.is_review_request() && !dismissed_before.contains(&key) {
            let unplaced = self.data.prs.get(&key).is_some_and(|p| p.place.is_none());
            if unplaced {
                self.place_at_end(&key, PlacedTab::Review, Section::Todo);
            }
        }
    }

    /// DESIGN.md, "Reaction rows".
    fn apply_reaction(&mut self, account: &str, reaction: IngestReaction, now: &Now) {
        let key = join_key(account, &reaction.pr_id);
        let Some(pr) = self.data.prs.get(&key) else {
            return;
        };
        if pr.dismissed_at.is_some() {
            return;
        }
        let Some(owner) = self.enabled_owner_of(pr) else {
            return;
        };
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
                    Making::default(),
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
    }

    /// DESIGN.md, "API usage": a search hit of a dismissed card or of a
    /// Dismiss record. Without a return, the kept `updatedAt` moves on to the
    /// hit's, and a record of a closed PR goes.
    fn apply_hit(&mut self, account: &str, hit: &proto::SearchHit) {
        let key = join_key(account, &hit.id);
        if let Some(pr) = self.data.prs.get(&key) {
            if pr.dismissed_at.is_none() {
                return;
            }
            let advance = hit.events_fetched && hit.updated_at > pr.updated_at;
            let closed = !hit.open && !pr.seen_closed;
            if (advance || closed)
                && let Some(pr) = self.pr_mut(&key)
            {
                if advance {
                    pr.updated_at = hit.updated_at;
                }
                if closed {
                    pr.seen_closed = true;
                }
            }
            return;
        }
        let Some(record) = self.data.records.get(&key) else {
            return;
        };
        if !hit.open {
            self.data.records.remove(&key);
            self.dirty.records.insert(key);
        } else if hit.events_fetched && hit.updated_at > record.updated_at {
            if let Some(record) = self.data.records.get_mut(&key) {
                record.updated_at = hit.updated_at;
            }
            self.dirty.records.insert(key);
        }
    }

    /// DESIGN.md, "Applying the table" and "Notification decisions": List
    /// and Notify of the owner's table, Mute, Dismiss and Skip draft pull
    /// requests decide the row when it is made. The same event never makes a
    /// second row, a deleted one included. Returns whether it was made.
    fn add_row(&mut self, mut row: RowRec, making: Making) -> bool {
        if self.data.rows.contains_key(&row.id) || self.data.deleted_rows.contains_key(&row.id) {
            return false;
        }
        let Some(pr) = self.data.prs.get(&row.pr) else {
            return false;
        };
        let Some(owner) = self.owner_of(pr) else {
            return false;
        };
        let cell = owner.events.cell(row.kind.event());
        row.listed = cell.list;
        row.made_at = self.clock.at;
        // Recorded while List is off: read, no notification.
        row.unread = cell.list && !making.read;
        let muted = self.row_muted(&row, pr);
        let notifies = !making.silent
            && cell.list
            && cell.notify
            && owner.notify
            && !(owner.skip_drafts && pr.is_draft)
            && !pr.unreadable
            && !muted
            && pr.dismissed_at.is_none();
        row.notify = if notifies {
            NotifyState::Pending
        } else {
            NotifyState::None
        };
        let blue = row.unread && !muted && self.in_lists(pr);
        let after_close = pr.closed_at.is_some()
            && cell.list
            && matches!(row.kind, RowKind::Mentioned | RowKind::Reply);
        let account = pr.account.clone();
        let key = pr.key.clone();
        if row.notify == NotifyState::Pending {
            self.fresh.push(row.id.clone());
        }
        if blue
            && !self.open.contains(&account)
            && let Some(account) = self.account_mut(&account)
        {
            account.dot = true;
        }
        if after_close && let Some(pr) = self.pr_mut(&key) {
            pr.keep_after_close = true;
        }
        self.rows_by_pr
            .entry(row.pr.clone())
            .or_default()
            .push(row.id.clone());
        self.dirty.rows.insert(row.id.clone());
        self.data.rows.insert(row.id.clone(), row);
        self.tidy_rows(&key);
        true
    }

    /// DESIGN.md, "Rows in a card": the newest 20 rows of kinds whose List
    /// is on stay; older ones go, unread or not, and only their ids are kept.
    /// The rows of kinds whose List is off are capped the same way among
    /// themselves, so what is kept stays bounded.
    fn tidy_rows(&mut self, key: &str) {
        let Some(pr) = self.data.prs.get(key) else {
            return;
        };
        let Some(owner) = self.owner_of(pr) else {
            return;
        };
        let (mut shown, mut hidden): (Vec<&RowRec>, Vec<&RowRec>) = self
            .rows_of(key)
            .partition(|row| self.row_shown(row, owner));
        if shown.len() <= KEEP_ROWS && hidden.len() <= KEEP_ROWS {
            return;
        }
        let newest_first = |a: &&RowRec, b: &&RowRec| {
            b.occurred_at
                .cmp(&a.occurred_at)
                .then_with(|| a.id.cmp(&b.id))
        };
        shown.sort_by(newest_first);
        hidden.sort_by(newest_first);
        let drop: Vec<String> = shown
            .iter()
            .skip(KEEP_ROWS)
            .chain(hidden.iter().skip(KEEP_ROWS))
            .map(|row| row.id.clone())
            .collect();
        for id in drop {
            self.data.rows.remove(&id);
            self.dirty.rows.insert(id.clone());
            self.in_flight.remove(&id);
            self.data.deleted_rows.insert(id.clone(), key.to_string());
            self.dirty.deleted_rows.insert(id.clone());
            if let Some(list) = self.rows_by_pr.get_mut(key) {
                list.retain(|r| *r != id);
            }
        }
        self.pruned_prs.insert(key.to_string());
        self.fresh.retain(|id| self.data.rows.contains_key(id));
    }

    /// The passes that follow time and changes: rows beyond the newest 20,
    /// the automatic Dismiss and the end of the Dismissed list, and what
    /// leaving the watch forgets.
    fn settle(&mut self, now: &Now) {
        let keys: Vec<String> = self.data.prs.keys().cloned().collect();
        for key in &keys {
            self.tidy_rows(key);
        }
        self.dismiss_by_time(now);
        self.track_watching(now);
    }

    // ------------------------------------------------------- row commands

    /// `read`: unread falls on the given rows. An unknown id changes
    /// nothing and is `not_found`. DESIGN.md, "Row state transitions".
    pub fn read(&mut self, row_ids: &[String]) -> Result<()> {
        if let Some(id) = row_ids.iter().find(|id| !self.data.rows.contains_key(*id)) {
            return Err(not_found(format!("row {id}")));
        }
        for id in row_ids {
            self.mark_read(id);
        }
        Ok(())
    }

    /// Unread falls, and a notification not handed over yet is cleared:
    /// a read row is neither notified later nor counted in a summary.
    fn mark_read(&mut self, id: &str) {
        let Some(row) = self.data.rows.get(id) else {
            return;
        };
        let waiting = row.notify == NotifyState::Pending && !self.in_flight.contains(id);
        if !row.unread && !waiting {
            return;
        }
        if let Some(row) = self.row_mut(id) {
            row.unread = false;
            if waiting {
                row.notify = NotifyState::None;
            }
        }
    }

    /// `read_all`: unread falls on every row of the account except those of
    /// dismissed PRs, muted rows and rows the list does not show included.
    pub fn read_all(&mut self, account: &str) -> Result<()> {
        let id = self.account_id(account)?;
        let rows: Vec<String> = self
            .data
            .rows
            .values()
            .filter(|row| {
                row.account == id
                    && !self
                        .data
                        .prs
                        .get(&row.pr)
                        .is_some_and(|pr| pr.dismissed_at.is_some())
            })
            .map(|row| row.id.clone())
            .collect();
        for row in rows {
            self.mark_read(&row);
        }
        Ok(())
    }

    pub fn popover_opened(&mut self, account: &str) -> Result<()> {
        let id = self.account_id(account)?;
        self.open.insert(id.clone());
        if let Some(account) = self.account_mut(&id) {
            account.dot = false;
        }
        Ok(())
    }

    /// The popover closed: the automatic Dismiss and the end of the
    /// Dismissed list held while it was open happen now. Unread stays.
    pub fn popover_closed(&mut self, account: &str) -> Result<()> {
        let id = self.account_id(account)?;
        self.open.remove(&id);
        let now = self.clock.clone();
        self.settle(&now);
        Ok(())
    }

    /// The connection of the app went away, or the daemon just started: the
    /// open state ends without counting as `popover_closed`.
    pub fn app_disconnected(&mut self) {
        self.open.clear();
    }

    /// The periodic pass.
    pub fn tick(&mut self, now: &Now) {
        self.clock = now.clone();
        self.settle(now);
    }

    pub fn config_get(&self, key: &str) -> Result<Value> {
        read_config(&self.data.config, key)
            .ok_or_else(|| CmdError::Invalid(format!("unknown setting: {key}")))
    }

    /// A changed n or m applies to the cards there are (DESIGN.md, "Wire
    /// format").
    pub fn config_set(&mut self, key: &str, value: &Value, now: &Now) -> Result<Value> {
        let mut config = self.data.config.clone();
        write_config(&mut config, key, value).map_err(CmdError::Invalid)?;
        self.data.config = config;
        self.dirty.config = true;
        self.settle(now);
        self.config_get(key)
    }

    // ------------------------------------------------------- notifications

    /// The check at hand-over: returns the account and owner when the row
    /// may still be notified, and clears the record otherwise. DESIGN.md,
    /// "Notification decisions".
    fn gate(&mut self, row_id: &str) -> Option<(String, String)> {
        let row = self.data.rows.get(row_id)?;
        if row.notify != NotifyState::Pending || self.in_flight.contains(row_id) {
            return None;
        }
        let pr = self.data.prs.get(&row.pr)?;
        let target = self
            .enabled_owner_of(pr)
            .filter(|owner| {
                !pr.unreadable
                    && owner.notify
                    && pr.dismissed_at.is_none()
                    && !self.row_muted(row, pr)
            })
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

    /// What goes to the app after this command. Without an app the rows
    /// stay undelivered for the summary after it reconnects.
    pub fn take_notifications(
        &mut self,
        app_connected: bool,
        now: &Now,
    ) -> Vec<proto::Notification> {
        let fresh = std::mem::take(&mut self.fresh);
        if !app_connected {
            return Vec::new();
        }
        self.deliver(fresh, now)
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
                out.push(self.summary_of(&account, &owner, rows, now));
            }
        }
        out
    }

    /// What an app gets when it connects: undelivered rows, grouped like any
    /// delivery (DESIGN.md, "Notification decisions").
    pub fn pending_summaries(&mut self, now: &Now) -> Vec<proto::Notification> {
        let pending: Vec<String> = self
            .data
            .rows
            .values()
            .filter(|row| row.notify == NotifyState::Pending && !self.in_flight.contains(&row.id))
            .map(|row| row.id.clone())
            .collect();
        self.deliver(pending, now)
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
    ) -> proto::Notification {
        let prs: BTreeSet<&str> = rows
            .iter()
            .filter_map(|id| self.data.rows.get(id))
            .map(|row| row.pr.as_str())
            .collect();
        let pr_count = prs.len();
        let login = self.login_of(account).to_string();
        let name = self.owner_name(owner);
        let title = format!(
            "{login} · {}",
            plural(rows.len(), "new event", "new events")
        );
        let subtitle = format!("{name} · in {}", plural(pr_count, "PR", "PRs"));
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

/// The row id an event makes. An approving review with a body also makes a
/// Comment row keyed by the review itself.
fn row_id(account: &str, event: &IngestEvent) -> String {
    match event.kind {
        proto::IngestKind::Approved => join_key(account, &format!("{}:approved", event.id)),
        _ => join_key(account, &event.id),
    }
}

/// A Checks value that is a settled result.
fn settled_of(checks: Checks) -> Option<Checks> {
    matches!(checks, Checks::Passed | Checks::Failed).then_some(checks)
}

/// The record of a fetched PR, keeping what the core decided about it.
fn pr_from(account: &str, p: IngestPr, existing: Option<&PrRec>) -> PrRec {
    let key = join_key(account, &p.id);
    let keep = |f: fn(&PrRec) -> Option<i64>| existing.and_then(f);
    PrRec {
        key,
        account: account.to_string(),
        unreadable: false,
        added_at: keep(|p| p.added_at),
        prev: existing.and_then(|p| p.prev),
        settled: existing.and_then(|p| p.settled),
        settled_head: existing.and_then(|p| p.settled_head.clone()),
        watch_reset: existing.is_some_and(|p| p.watch_reset),
        place: existing.and_then(|p| p.place),
        closed_at: keep(|p| p.closed_at),
        done_at: keep(|p| p.done_at),
        keep_after_close: existing.is_some_and(|p| p.keep_after_close),
        dismissed_at: keep(|p| p.dismissed_at),
        restored: existing.is_some_and(|p| p.restored),
        seen_closed: existing.is_some_and(|p| p.seen_closed),
        quiet_from: keep(|p| p.quiet_from),
        quiet_until: keep(|p| p.quiet_until),
        merged_event_at: keep(|p| p.merged_event_at),
        last_request_at: keep(|p| p.last_request_at),
        collected: existing.is_some_and(|p| p.collected),
        state: p.state.into(),
        is_draft: p.is_draft,
        review: p.review.into(),
        checks: p.checks.into(),
        base_status: p.base_status.into(),
        mergeable: p.mergeable,
        failed_check: p.failed_check,
        changes_requested_by: p.changes_requested_by,
        updated_at: p.updated_at,
        created_at: Some(p.created_at),
        my_review_at: p.my_review_at,
        is_private: p.is_private,
        requested_me: p.requested_me,
        requested_team: p.requested_team,
        assignees: p.assignees,
        link_review: p.links.review,
        link_checks: p.links.checks,
        link_base: p.links.base,
        head_oid: p.head_oid,
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
    }
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
        listed: true,
        made_at: 0,
        notify: NotifyState::None,
    }
}

/// DESIGN.md, "What the filters mean": the search text split at white
/// space, each word lowercased. No words means no search.
pub fn search_words(search: Option<&str>) -> Vec<String> {
    search
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_lowercase)
        .collect()
}

/// The PR's own fields a search word may match: the title,
/// `owner/repo#number`, the author's login and the base and head branches,
/// lowercased.
fn pr_fields(pr: &PrRec) -> Vec<String> {
    [
        pr.title.as_str(),
        &pr.display_key(),
        &pr.author,
        &pr.base,
        &pr.head,
    ]
    .iter()
    .map(|f| f.to_lowercase())
    .collect()
}

/// The text and actor of a row, lowercased.
fn row_fields(row: &proto::Row) -> impl Iterator<Item = String> + '_ {
    [row.text.as_deref(), row.actor.as_deref()]
        .into_iter()
        .flatten()
        .map(str::to_lowercase)
}

/// Every word is part of one of the fields, without regard to case.
fn all_words_in(fields: &[String], words: &[String]) -> bool {
    words
        .iter()
        .all(|word| fields.iter().any(|field| field.contains(word.as_str())))
}

/// DESIGN.md, "What the filters mean": a card matches when every word is in
/// the PR's fields or in the text or actor of one of its rows.
pub fn card_matches(card: &proto::Card, words: &[String]) -> bool {
    if words.is_empty() {
        return true;
    }
    let mut fields: Vec<String> = [
        card.title.as_str(),
        &card.pr,
        &card.author,
        &card.base,
        &card.head,
    ]
    .iter()
    .map(|f| f.to_lowercase())
    .collect();
    for row in &card.rows {
        fields.extend(row_fields(row));
    }
    all_words_in(&fields, words)
}

/// An Activity row matches when every word is in its PR's fields or in the
/// row's own text or actor.
fn row_matches(pr_fields: &[String], row: &proto::Row, words: &[String]) -> bool {
    if words.is_empty() {
        return true;
    }
    let mut fields = pr_fields.to_vec();
    fields.extend(row_fields(row));
    all_words_in(&fields, words)
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
    "text_size",
    "status_interval_minutes",
    "reactions_interval_minutes",
    "auto_dismiss_after_days",
    "dismissed_keep_days",
];

pub fn read_config(config: &Config, key: &str) -> Option<Value> {
    Some(match key {
        "launch_at_login" => json!(config.launch_at_login),
        "status_interval_minutes" => json!(config.status_interval_minutes),
        "reactions_interval_minutes" => json!(config.reactions_interval_minutes),
        "appearance" => json!(config.appearance.as_str()),
        "text_size" => json!(config.text_size),
        "auto_dismiss_after_days" => json!(config.auto_dismiss_after_days),
        "dismissed_keep_days" => json!(config.dismissed_keep_days),
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
        "appearance" => {
            config.appearance = value
                .as_str()
                .and_then(Appearance::parse)
                .ok_or_else(|| format!("{key} must be system, light or dark"))?;
        }
        "text_size" => {
            config.text_size = integer(key, value, TEXT_SIZE_MIN)
                .ok()
                .filter(|size| *size <= TEXT_SIZE_MAX)
                .ok_or_else(|| {
                    format!("{key} must be an integer from {TEXT_SIZE_MIN} to {TEXT_SIZE_MAX}")
                })?;
        }
        "auto_dismiss_after_days" => config.auto_dismiss_after_days = integer(key, value, 0)?,
        "dismissed_keep_days" => config.dismissed_keep_days = integer(key, value, 1)?,
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
