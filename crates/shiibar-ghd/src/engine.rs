//! The daemon core: every behavior rule of docs/DESIGN.md as state transitions
//! on plain data. No I/O and no clock of its own, so the rule tables in
//! `tests/` run against it directly.

use crate::clock::{ClockTime, Now};
use crate::model::*;
use serde_json::{Value, json};
use shiibar_gh_proto as proto;
use shiibar_gh_proto::{Filter, Ingest, IngestEvent, IngestPr, IngestReaction, Lenient};
use std::collections::{BTreeMap, BTreeSet, HashMap};

const DAY_SECS: i64 = 86_400;
/// Rows kept per PR among read events and done rows.
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
    Internal(String),
}

type Result<T> = std::result::Result<T, CmdError>;

fn not_found(what: impl std::fmt::Display) -> CmdError {
    CmdError::NotFound(format!("not found: {what}"))
}

pub struct Engine {
    data: Data,
    dirty: Dirty,
    rows_by_pr: HashMap<String, Vec<String>>,
    /// Scopes with an open popover or window. Never saved.
    open: BTreeSet<String>,
    /// Rows with a notification written to a connection but not confirmed.
    in_flight: BTreeSet<String>,
    /// Rows made since the last hand-over that want an individual notification.
    fresh: Vec<String>,
    /// Rows the last release moved out of hold.
    released: Vec<String>,
    notification_seq: u64,
}

impl Engine {
    /// A database without saved state: only Public, watching from now.
    pub fn fresh(now: &Now) -> Self {
        let mut data = Data {
            last_release_at: now.at,
            ..Data::default()
        };
        data.scopes.insert(
            PUBLIC.into(),
            ScopeRec {
                id: PUBLIC.into(),
                removed: false,
                enabled: true,
                notify: true,
                watch_started_at: now.at,
                updated_at: None,
                dot: false,
            },
        );
        let mut engine = Self::restore(data);
        engine.dirty = Dirty {
            scopes: engine.data.scopes.keys().cloned().collect(),
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
                .entry(row.pr_id.clone())
                .or_default()
                .push(row.id.clone());
        }
        Self {
            data,
            dirty: Dirty::default(),
            rows_by_pr,
            open: BTreeSet::new(),
            in_flight: BTreeSet::new(),
            fresh: Vec::new(),
            released: Vec::new(),
            notification_seq: 0,
        }
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

    pub fn row_record(&self, id: &str) -> Option<&RowRec> {
        self.data.rows.get(id)
    }

    pub fn pr_snoozed(&self, id: &str) -> bool {
        self.data.prs.get(id).is_some_and(|pr| pr.snoozed)
    }

    pub fn last_release_at(&self) -> i64 {
        self.data.last_release_at
    }

    fn scope_mut(&mut self, id: &str) -> Option<&mut ScopeRec> {
        self.dirty.scopes.insert(id.to_string());
        self.data.scopes.get_mut(id)
    }

    fn pr_mut(&mut self, id: &str) -> Option<&mut PrRec> {
        self.dirty.prs.insert(id.to_string());
        self.data.prs.get_mut(id)
    }

    fn row_mut(&mut self, id: &str) -> Option<&mut RowRec> {
        self.dirty.rows.insert(id.to_string());
        self.data.rows.get_mut(id)
    }

    fn registered_scope(&self, id: &str) -> Option<&ScopeRec> {
        self.data.scopes.get(id).filter(|s| !s.removed)
    }

    /// DESIGN.md, "Scopes": the owner's scope when registered, else Public for
    /// a public repository, else nothing.
    fn resolve_scope(&self, owner: &str, is_private: bool) -> Option<&str> {
        if owner != PUBLIC && self.registered_scope(owner).is_some() {
            return self.data.scopes.get(owner).map(|s| s.id.as_str());
        }
        (!is_private).then_some(PUBLIC)
    }

    fn scope_of(&self, pr: &PrRec) -> Option<&ScopeRec> {
        let id = self.resolve_scope(&pr.owner, pr.is_private)?;
        self.data.scopes.get(id)
    }

    fn enabled_scope_of(&self, pr: &PrRec) -> Option<&ScopeRec> {
        self.scope_of(pr).filter(|s| s.enabled)
    }

    fn rows_of(&self, pr_id: &str) -> impl Iterator<Item = &RowRec> {
        self.rows_by_pr
            .get(pr_id)
            .into_iter()
            .flatten()
            .filter_map(|id| self.data.rows.get(id))
    }

    fn hidden(&self, row: &RowRec) -> bool {
        row.kind == RowKind::BotComment && self.data.config.bot_comments == BotComments::Hide
    }

    /// The Review requested row that can still be something to do.
    fn latest_review_request(&self, pr_id: &str) -> Option<&RowRec> {
        self.rows_of(pr_id)
            .filter(|r| r.kind == RowKind::ReviewRequested)
            .min_by(|a, b| {
                b.occurred_at
                    .cmp(&a.occurred_at)
                    .then_with(|| a.id.cmp(&b.id))
            })
    }

    /// DESIGN.md, "Review requested rows" and the row table.
    fn is_needs_action(&self, row: &RowRec, pr: &PrRec) -> bool {
        match row.kind {
            RowKind::Mentioned | RowKind::Comment | RowKind::Reply => true,
            RowKind::ReviewRequested => {
                pr.state == PrState::Open
                    && pr.requested_me
                    && self
                        .latest_review_request(&pr.id)
                        .is_some_and(|latest| latest.id == row.id)
            }
            _ => false,
        }
    }

    /// Unread, or Needs action and not done, among the rows shown.
    fn has_business(&self, pr: &PrRec) -> bool {
        self.rows_of(&pr.id).any(|row| {
            !row.pruned
                && !self.hidden(row)
                && (row.unread || (!row.done && self.is_needs_action(row, pr)))
        })
    }

    /// DESIGN.md, "When cards appear and disappear", without the Snooze rule.
    fn would_show(&self, pr: &PrRec, now: i64) -> bool {
        if pr.unreadable {
            return false;
        }
        if self.has_business(pr) {
            return true;
        }
        if pr.state != PrState::Open {
            return false;
        }
        if pr.mine {
            return true;
        }
        if pr.is_draft {
            return false;
        }
        let limit = self.data.config.drop_after_days.saturating_mul(DAY_SECS);
        now.saturating_sub(pr.updated_at) <= limit
    }

    fn shows(&self, pr: &PrRec, show_snoozed: bool, now: i64) -> bool {
        if pr.unreadable {
            return false;
        }
        if pr.snoozed {
            return show_snoozed;
        }
        self.would_show(pr, now)
    }

    /// DESIGN.md, "Needs action definition".
    fn pr_needs_action(&self, pr: &PrRec) -> bool {
        if pr.snoozed || pr.unreadable {
            return false;
        }
        let red = pr.review == Review::ChangesRequested
            || pr.checks == Checks::Failed
            || pr.base_status == BaseStatus::Conflicts;
        if pr.mine && pr.state == PrState::Open && red {
            return true;
        }
        self.rows_of(&pr.id).any(|row| {
            !row.pruned && !self.hidden(row) && !row.done && self.is_needs_action(row, pr)
        })
    }

    fn wire_row(&self, row: &RowRec, pr: &PrRec) -> proto::Row {
        let class = if self.is_needs_action(row, pr) {
            proto::RowClass::NeedsAction
        } else {
            proto::RowClass::Event
        };
        proto::Row {
            id: row.id.clone(),
            pr: pr.key(),
            pr_title: pr.title.clone(),
            kind: Lenient::Known(row.kind.into()),
            class: Lenient::Known(class),
            text: row.text.clone(),
            counts: row.counts.clone(),
            actor: row.actor.clone(),
            url: row.url.clone(),
            occurred_at: row.occurred_at,
            unread: row.unread,
            done: row.done,
        }
    }

    fn wire_rows(&self, pr: &PrRec) -> Vec<proto::Row> {
        let mut rows: Vec<proto::Row> = self
            .rows_of(&pr.id)
            .filter(|row| !row.pruned && !self.hidden(row))
            .map(|row| self.wire_row(row, pr))
            .collect();
        sort_rows(&mut rows);
        rows
    }

    fn wire_card(&self, pr: &PrRec, scope: &str, now: &Now) -> proto::Card {
        let label = match pr.state {
            PrState::Merged => proto::StateLabel::Merged,
            PrState::Closed => proto::StateLabel::Closed,
            PrState::Open if pr.is_draft => proto::StateLabel::Draft,
            PrState::Open if pr.mergeable => proto::StateLabel::Mergeable,
            PrState::Open => proto::StateLabel::Open,
        };
        let return_time = self.data.config.snooze_return_time;
        proto::Card {
            id: pr.id.clone(),
            pr: pr.key(),
            scope: scope.to_string(),
            title: pr.title.clone(),
            url: pr.url.clone(),
            author: pr.author.clone(),
            mine: pr.mine,
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
            rows: self.wire_rows(pr),
        }
    }

    fn matching_prs(&self, filter: &Filter, now: i64) -> Result<Vec<(&PrRec, String)>> {
        if filter.mine && filter.others {
            return Err(CmdError::Invalid(
                "mine and others cannot both be set".into(),
            ));
        }
        if let Some(scope) = &filter.scope
            && self.registered_scope(scope).is_none()
        {
            return Err(not_found(format!("scope {scope}")));
        }
        let mut out = Vec::new();
        for pr in self.data.prs.values() {
            let Some(scope) = self.enabled_scope_of(pr) else {
                continue;
            };
            if filter.scope.as_ref().is_some_and(|s| *s != scope.id)
                || !self.shows(pr, filter.snoozed, now)
                || (filter.mine && !pr.mine)
                || (filter.others && pr.mine)
                || (filter.needs_action && !self.pr_needs_action(pr))
            {
                continue;
            }
            out.push((pr, scope.id.clone()));
        }
        Ok(out)
    }

    pub fn list(&self, filter: &Filter, now: &Now) -> Result<Vec<proto::Card>> {
        let mut cards: Vec<proto::Card> = self
            .matching_prs(filter, now.at)?
            .into_iter()
            .map(|(pr, scope)| self.wire_card(pr, &scope, now))
            .collect();
        cards.sort_by(|a, b| b.added_at.cmp(&a.added_at).then_with(|| a.id.cmp(&b.id)));
        Ok(cards)
    }

    pub fn activity(&self, filter: &Filter, now: &Now) -> Result<Vec<proto::Row>> {
        let mut rows: Vec<proto::Row> = self
            .matching_prs(filter, now.at)?
            .into_iter()
            .flat_map(|(pr, _)| self.wire_rows(pr))
            .collect();
        sort_rows(&mut rows);
        Ok(rows)
    }

    /// A PR a command may act on: known, in an enabled scope and readable.
    fn usable_pr(&self, key: &str) -> Result<&PrRec> {
        self.data
            .prs
            .values()
            .find(|pr| pr.key() == key)
            .filter(|pr| !pr.unreadable && self.enabled_scope_of(pr).is_some())
            .ok_or_else(|| not_found(format!("PR {key}")))
    }

    /// A row a command may act on. A pruned row counts as gone.
    fn usable_row(&self, id: &str) -> Result<(&RowRec, &PrRec)> {
        self.data
            .rows
            .get(id)
            .filter(|row| !row.pruned)
            .and_then(|row| Some((row, self.data.prs.get(&row.pr_id)?)))
            .filter(|(_, pr)| !pr.unreadable && self.enabled_scope_of(pr).is_some())
            .ok_or_else(|| not_found(format!("row {id}")))
    }

    pub fn status(&self, key: &str, now: &Now) -> Result<proto::Card> {
        let pr = self.usable_pr(key)?;
        let scope = self
            .enabled_scope_of(pr)
            .map(|s| s.id.clone())
            .unwrap_or_default();
        Ok(self.wire_card(pr, &scope, now))
    }

    pub fn open_pr(&self, key: &str) -> Result<String> {
        Ok(self.usable_pr(key)?.url.clone())
    }

    pub fn open_row(&self, id: &str) -> Result<String> {
        Ok(self.usable_row(id)?.0.url.clone())
    }

    fn badge(&self, scope: &ScopeRec) -> u32 {
        if !scope.enabled {
            return 0;
        }
        self.data
            .prs
            .values()
            .filter(|pr| {
                self.scope_of(pr).is_some_and(|s| s.id == scope.id) && self.pr_needs_action(pr)
            })
            .count() as u32
    }

    fn wire_scope(&self, scope: &ScopeRec) -> proto::Scope {
        let public = scope.id == PUBLIC;
        proto::Scope {
            id: scope.id.clone(),
            name: if public {
                "Public".into()
            } else {
                scope.id.clone()
            },
            kind: public.then_some(Lenient::Known(proto::ScopeKind::Public)),
            enabled: scope.enabled,
            notify: scope.notify,
            badge: self.badge(scope),
            dot: scope.enabled && scope.dot,
            warnings: Vec::new(),
            updated_at: scope.updated_at,
        }
    }

    pub fn scopes(&self) -> Vec<proto::Scope> {
        self.data
            .scopes
            .values()
            .filter(|s| !s.removed)
            .map(|s| self.wire_scope(s))
            .collect()
    }

    /// Per scope, its value and everything a client would show for it. Two
    /// equal digests mean no `scope_changed` is due.
    pub fn digest(&self, now: &Now) -> BTreeMap<String, (proto::Scope, Vec<proto::Card>)> {
        let filter = Filter {
            snoozed: true,
            ..Filter::default()
        };
        let mut digest: BTreeMap<String, (proto::Scope, Vec<proto::Card>)> = self
            .scopes()
            .into_iter()
            .map(|scope| (scope.id.clone(), (scope, Vec::new())))
            .collect();
        if let Ok(cards) = self.list(&filter, now) {
            for card in cards {
                if let Some(entry) = digest.get_mut(&card.scope) {
                    entry.1.push(card);
                }
            }
        }
        digest
    }

    pub fn ingest(&mut self, ingest: Ingest, now: &Now) -> Result<()> {
        let incoming: BTreeSet<&str> = ingest.prs.iter().map(|p| p.id.as_str()).collect();
        let referenced = ingest
            .events
            .iter()
            .map(|e| e.pr_id.as_str())
            .chain(ingest.reactions.iter().map(|r| r.pr_id.as_str()));
        for pr_id in referenced {
            if !incoming.contains(pr_id) && !self.data.prs.contains_key(pr_id) {
                return Err(CmdError::Invalid(format!("unknown pr_id: {pr_id}")));
            }
        }

        let mut touched = BTreeSet::new();
        for id in &ingest.missing_pr_ids {
            let scope = self
                .data
                .prs
                .get(id)
                .and_then(|pr| self.enabled_scope_of(pr))
                .map(|s| s.id.clone());
            if let Some(scope) = scope {
                if let Some(pr) = self.pr_mut(id) {
                    pr.unreadable = true;
                }
                touched.insert(scope);
            }
        }

        // PRs fetched for the first time since their scope's watch started.
        let mut first_fetch = BTreeSet::new();
        for incoming in ingest.prs {
            let Some(scope) = self.resolve_scope(&incoming.owner, incoming.is_private) else {
                continue;
            };
            let scope = scope.to_string();
            if !self.data.scopes[&scope].enabled {
                continue;
            }
            if self.apply_pr(incoming.clone(), &ingest.viewer, now) {
                first_fetch.insert(incoming.id);
            }
            touched.insert(scope);
        }
        for event in ingest.events {
            if let Some(scope) = self.apply_event(event, &first_fetch) {
                touched.insert(scope);
            }
        }
        for reaction in ingest.reactions {
            if let Some(scope) = self.apply_reaction(reaction, now) {
                touched.insert(scope);
            }
        }
        for scope in touched {
            if let Some(scope) = self.scope_mut(&scope) {
                scope.updated_at = Some(now.at);
            }
        }
        self.settle(now);
        Ok(())
    }

    /// Returns true when there was no previous value to compare against.
    fn apply_pr(&mut self, p: IngestPr, viewer: &str, now: &Now) -> bool {
        let existing = self.data.prs.get(&p.id);
        let prev = existing.and_then(|pr| pr.prev);
        let reopened =
            p.state == proto::PrState::Open && existing.is_some_and(|pr| pr.state != PrState::Open);
        let record = PrRec {
            mine: p.author == viewer,
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
            base: p.base,
            head: p.head,
        };
        let id = record.id.clone();
        self.dirty.prs.insert(id.clone());
        self.data.prs.insert(id.clone(), record);
        if reopened {
            self.restore_review_request(&id);
        }
        match prev {
            Some(prev) => {
                self.state_change_rows(&id, prev, now);
                false
            }
            None => true,
        }
    }

    /// DESIGN.md, "Review requested rows": reopening returns the row to Needs
    /// action, even from the pruned rows. Only the reopening does: a Done row
    /// pruned while requested stays pruned.
    fn restore_review_request(&mut self, pr_id: &str) {
        let Some(pr) = self.data.prs.get(pr_id) else {
            return;
        };
        let restored = self
            .latest_review_request(pr_id)
            .filter(|latest| latest.pruned && self.is_needs_action(latest, pr))
            .map(|latest| latest.id.clone());
        if let Some(row) = restored.and_then(|id| self.row_mut(&id)) {
            row.pruned = false;
        }
    }

    /// DESIGN.md, "State change rows".
    fn state_change_rows(&mut self, pr_id: &str, prev: PrevValues, now: &Now) {
        let Some(pr) = self.data.prs.get(pr_id) else {
            return;
        };
        if !pr.mine || pr.state != PrState::Open {
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
        for (kind, text, url) in made {
            let id = format!("{pr_id}:{}:{}", kind.as_str(), now.at);
            self.add_row(
                RowRec {
                    id,
                    pr_id: pr_id.to_string(),
                    kind,
                    text,
                    counts: None,
                    actor: None,
                    url,
                    occurred_at: now.at,
                    comment_id: None,
                    ..row_defaults()
                },
                false,
            );
        }
    }

    /// DESIGN.md, "Events before the watch started". Returns the scope when
    /// the event's PR belongs to an enabled one.
    fn apply_event(
        &mut self,
        event: IngestEvent,
        first_fetch: &BTreeSet<String>,
    ) -> Option<String> {
        let pr = self.data.prs.get(&event.pr_id)?;
        let scope = self.enabled_scope_of(pr)?;
        let scope_id = scope.id.clone();
        let mut silent = false;
        if event.occurred_at < scope.watch_started_at {
            let kept = event.kind == proto::EventKind::ReviewRequested
                && pr.requested_me
                && first_fetch.contains(&event.pr_id);
            if !kept {
                return Some(scope_id);
            }
            silent = true;
        }
        self.add_row(
            RowRec {
                id: event.id,
                pr_id: event.pr_id,
                kind: event.kind.into(),
                text: event.text,
                counts: None,
                actor: event.actor,
                url: event.url,
                occurred_at: event.occurred_at,
                comment_id: event.comment_id,
                ..row_defaults()
            },
            silent,
        );
        Some(scope_id)
    }

    /// DESIGN.md, "Reaction rows".
    fn apply_reaction(&mut self, reaction: IngestReaction, now: &Now) -> Option<String> {
        let pr = self.data.prs.get(&reaction.pr_id)?;
        let scope = self.enabled_scope_of(pr)?;
        let scope_id = scope.id.clone();
        let base = match self.data.baselines.get(&reaction.comment_id) {
            Some(baseline) => Some(baseline.counts.clone()),
            None if reaction.comment_created_at < scope.watch_started_at => None,
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
                let id = format!("{}:{content}:{}", reaction.comment_id, now.at);
                self.add_row(
                    RowRec {
                        id,
                        pr_id: reaction.pr_id.clone(),
                        kind: RowKind::Reaction,
                        text: Some(reaction.text.clone()),
                        counts: Some(BTreeMap::from([(content.clone(), delta)])),
                        actor: None,
                        url: reaction.url.clone(),
                        occurred_at: now.at,
                        comment_id: Some(reaction.comment_id.clone()),
                        ..row_defaults()
                    },
                    false,
                );
            }
        }
        self.dirty.baselines.insert(reaction.comment_id.clone());
        self.data.baselines.insert(
            reaction.comment_id.clone(),
            Baseline {
                comment_id: reaction.comment_id,
                pr_id: reaction.pr_id,
                counts: reaction.counts,
            },
        );
        Some(scope_id)
    }

    /// Whether a row of this kind is to be notified under the current settings.
    /// DESIGN.md, "macOS notifications".
    fn kind_notifies(&self, row: &RowRec, pr: &PrRec) -> bool {
        let config = &self.data.config;
        match row.kind {
            RowKind::ReviewRequested | RowKind::Mentioned | RowKind::Comment | RowKind::Reply => {
                config.notify_activity
            }
            RowKind::Reaction => config.notify_reactions,
            RowKind::ChecksFailed
            | RowKind::Conflicts
            | RowKind::ChangesRequested
            | RowKind::Mergeable => config.notify_state,
            RowKind::RemovedFromMergeQueue => pr.mine && config.notify_state,
            RowKind::BotComment => config.bot_comments == BotComments::Notify,
            RowKind::AddedToMergeQueue | RowKind::Merged | RowKind::Closed => false,
        }
    }

    /// DESIGN.md, "Row state transitions" and "Notification decisions". The
    /// same event never makes a second row.
    fn add_row(&mut self, mut row: RowRec, silent: bool) {
        if self.data.rows.contains_key(&row.id) {
            return;
        }
        let Some(pr) = self.data.prs.get(&row.pr_id) else {
            return;
        };
        let Some(scope) = self.scope_of(pr) else {
            return;
        };
        let scope_id = scope.id.clone();
        let hidden = self.hidden(&row);
        row.unread = !hidden;
        let snoozed = pr.snoozed;
        let unreadable = pr.unreadable;
        row.notify = if !silent && !unreadable && scope.notify && self.kind_notifies(&row, pr) {
            if snoozed {
                NotifyState::Held
            } else {
                NotifyState::Pending
            }
        } else {
            NotifyState::None
        };
        if row.notify == NotifyState::Pending {
            self.fresh.push(row.id.clone());
        }
        if row.unread
            && !snoozed
            && !unreadable
            && !self.open.contains(&scope_id)
            && let Some(scope) = self.scope_mut(&scope_id)
        {
            scope.dot = true;
        }
        self.rows_by_pr
            .entry(row.pr_id.clone())
            .or_default()
            .push(row.id.clone());
        self.dirty.rows.insert(row.id.clone());
        self.data.rows.insert(row.id.clone(), row);
    }

    /// A card gets its fixed position the first time it qualifies.
    fn settle(&mut self, now: &Now) {
        let mut add = Vec::new();
        for pr in self.data.prs.values() {
            if pr.added_at.is_none()
                && self.enabled_scope_of(pr).is_some()
                && self.would_show(pr, now.at)
            {
                add.push(pr.id.clone());
            }
        }
        for id in add {
            if let Some(pr) = self.pr_mut(&id) {
                pr.added_at = Some(now.at);
            }
        }
    }

    pub fn seen(&mut self, row_ids: &[String]) {
        for id in row_ids {
            if self.data.rows.contains_key(id)
                && let Some(row) = self.row_mut(id)
            {
                row.seen_pending = true;
            }
        }
    }

    pub fn require_scope(&self, id: &str) -> Result<()> {
        self.registered_scope(id)
            .map(|_| ())
            .ok_or_else(|| not_found(format!("scope {id}")))
    }

    pub fn popover_opened(&mut self, scope: &str) -> Result<()> {
        self.require_scope(scope)?;
        self.open.insert(scope.to_string());
        if let Some(scope) = self.scope_mut(scope) {
            scope.dot = false;
        }
        Ok(())
    }

    pub fn popover_closed(&mut self, scope: &str) -> Result<()> {
        self.require_scope(scope)?;
        self.open.remove(scope);
        let prs: Vec<String> = self
            .data
            .prs
            .values()
            .filter(|pr| self.scope_of(pr).is_some_and(|s| s.id == scope))
            .map(|pr| pr.id.clone())
            .collect();
        for id in prs {
            self.close_rows(&id);
        }
        Ok(())
    }

    /// Unread falls on rows that were shown, then the rows of the PR are
    /// pruned. DESIGN.md, "How many rows are kept".
    fn close_rows(&mut self, pr_id: &str) {
        let shown: Vec<String> = self
            .rows_of(pr_id)
            .filter(|row| row.seen_pending)
            .map(|row| row.id.clone())
            .collect();
        for id in shown {
            if let Some(row) = self.row_mut(&id) {
                row.seen_pending = false;
                row.unread = false;
            }
        }
        let Some(pr) = self.data.prs.get(pr_id) else {
            return;
        };
        let mut candidates: Vec<&RowRec> = self
            .rows_of(pr_id)
            .filter(|row| {
                !row.pruned
                    && !row.unread
                    && !self.hidden(row)
                    && (row.done || !self.is_needs_action(row, pr))
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

    fn set_done(&mut self, id: &str, done: bool) -> Result<()> {
        let (row, pr) = self.usable_row(id)?;
        if self.is_needs_action(row, pr)
            && let Some(row) = self.row_mut(id)
        {
            row.done = done;
        }
        Ok(())
    }

    pub fn done(&mut self, id: &str) -> Result<()> {
        self.set_done(id, true)
    }

    pub fn undone(&mut self, id: &str) -> Result<()> {
        self.set_done(id, false)
    }

    pub fn snooze(&mut self, key: &str, now: &Now) -> Result<()> {
        self.release_if_due(now);
        let pr = self.usable_pr(key)?;
        if !self.would_show(pr, now.at) {
            return Err(not_found(format!("no card for PR {key}")));
        }
        let id = pr.id.clone();
        if let Some(pr) = self.pr_mut(&id) {
            pr.snoozed = true;
        }
        self.hold_undelivered(&id);
        Ok(())
    }

    fn hold_undelivered(&mut self, pr_id: &str) {
        let rows: Vec<String> = self
            .rows_of(pr_id)
            .filter(|row| row.notify == NotifyState::Pending && !self.in_flight.contains(&row.id))
            .map(|row| row.id.clone())
            .collect();
        for id in rows {
            if let Some(row) = self.row_mut(&id) {
                row.notify = NotifyState::HeldUndelivered;
            }
        }
    }

    pub fn unsnooze(&mut self, key: &str, now: &Now) -> Result<()> {
        let id = self.usable_pr(key)?.id.clone();
        if !self.pr_snoozed(&id) {
            return Ok(());
        }
        self.end_snooze(&id);
        let held: Vec<(String, NotifyState)> = self
            .rows_of(&id)
            .filter_map(|row| match row.notify {
                NotifyState::Held => Some((row.id.clone(), NotifyState::None)),
                NotifyState::HeldUndelivered => Some((row.id.clone(), NotifyState::Pending)),
                _ => None,
            })
            .collect();
        for (row, notify) in held {
            if let Some(row) = self.row_mut(&row) {
                row.notify = notify;
            }
        }
        self.settle(now);
        Ok(())
    }

    /// Clear the flag and bring back the blue dot for unread rows.
    fn end_snooze(&mut self, pr_id: &str) {
        if let Some(pr) = self.pr_mut(pr_id) {
            pr.snoozed = false;
        }
        let Some(pr) = self.data.prs.get(pr_id).filter(|pr| !pr.unreadable) else {
            return;
        };
        let Some(scope) = self.scope_of(pr).map(|s| s.id.clone()) else {
            return;
        };
        let unread = self
            .rows_of(pr_id)
            .any(|row| row.unread && !row.pruned && !self.hidden(row));
        if unread
            && !self.open.contains(&scope)
            && let Some(scope) = self.scope_mut(&scope)
        {
            scope.dot = true;
        }
    }

    /// The brief's "Snooze release": everything goes when a Return time passed
    /// since the last release. Waking from sleep lands here too.
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
            .map(|pr| pr.id.clone())
            .collect();
        for pr_id in snoozed {
            self.end_snooze(&pr_id);
            let held: Vec<(String, bool)> = self
                .rows_of(&pr_id)
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
        self.release_if_due(now);
        self.settle(now);
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
        let was_hidden = self.data.config.bot_comments == BotComments::Hide;
        self.data.config = config;
        self.dirty.config = true;
        if was_hidden && self.data.config.bot_comments != BotComments::Hide {
            self.mark_bot_comments_read();
        }
        self.settle(now);
        self.config_get(key)
    }

    /// Rows hidden by Bot comments return as read.
    fn mark_bot_comments_read(&mut self) {
        let rows: Vec<String> = self
            .data
            .rows
            .values()
            .filter(|row| row.kind == RowKind::BotComment && (row.unread || row.seen_pending))
            .map(|row| row.id.clone())
            .collect();
        for id in rows {
            if let Some(row) = self.row_mut(&id) {
                row.unread = false;
                row.seen_pending = false;
            }
        }
    }

    pub fn scope_add(&mut self, owner: &str, now: &Now) -> Result<()> {
        if owner == PUBLIC {
            return Err(CmdError::Invalid("public cannot be added".into()));
        }
        if owner.is_empty() {
            return Err(CmdError::Invalid("owner is empty".into()));
        }
        if self.registered_scope(owner).is_some() {
            return Err(CmdError::Invalid(format!("scope {owner} already exists")));
        }
        self.dirty.scopes.insert(owner.to_string());
        self.data
            .scopes
            .entry(owner.to_string())
            .and_modify(|scope| scope.removed = false)
            .or_insert_with(|| ScopeRec {
                id: owner.to_string(),
                removed: false,
                enabled: true,
                notify: true,
                watch_started_at: now.at,
                updated_at: None,
                dot: false,
            });
        self.start_watch(owner, now);
        self.settle(now);
        Ok(())
    }

    /// The brief's rule: a new watch start forgets the scope's previous values
    /// and Reaction baselines.
    fn start_watch(&mut self, scope: &str, now: &Now) {
        if let Some(record) = self.scope_mut(scope) {
            record.watch_started_at = now.at;
        }
        let prs: Vec<String> = self
            .data
            .prs
            .values()
            .filter(|pr| self.scope_of(pr).is_some_and(|s| s.id == scope))
            .map(|pr| pr.id.clone())
            .collect();
        for id in &prs {
            if let Some(pr) = self.pr_mut(id) {
                pr.prev = None;
            }
        }
        let comments: Vec<String> = self
            .data
            .baselines
            .values()
            .filter(|b| prs.contains(&b.pr_id))
            .map(|b| b.comment_id.clone())
            .collect();
        for comment in comments {
            self.data.baselines.remove(&comment);
            self.dirty.baselines.insert(comment);
        }
    }

    pub fn scope_remove(&mut self, owner: &str) -> Result<()> {
        if owner == PUBLIC {
            return Err(CmdError::Invalid("public cannot be removed".into()));
        }
        self.require_scope(owner)?;
        if let Some(scope) = self.scope_mut(owner) {
            scope.removed = true;
        }
        self.open.remove(owner);
        Ok(())
    }

    pub fn scope_enable(&mut self, scope: &str, now: &Now) -> Result<()> {
        self.require_scope(scope)?;
        if !self.data.scopes[scope].enabled {
            if let Some(record) = self.scope_mut(scope) {
                record.enabled = true;
            }
            self.start_watch(scope, now);
            self.settle(now);
        }
        Ok(())
    }

    pub fn scope_disable(&mut self, scope: &str) -> Result<()> {
        self.require_scope(scope)?;
        if let Some(record) = self.scope_mut(scope) {
            record.enabled = false;
        }
        Ok(())
    }

    pub fn scope_notify(&mut self, scope: &str, on: bool) -> Result<()> {
        self.require_scope(scope)?;
        if let Some(record) = self.scope_mut(scope) {
            record.notify = on;
        }
        Ok(())
    }

    /// The check at hand-over: returns the scope when the row may still be
    /// notified, and clears the record otherwise.
    fn gate(&mut self, row_id: &str) -> Option<String> {
        let row = self.data.rows.get(row_id)?;
        if row.notify != NotifyState::Pending || self.in_flight.contains(row_id) {
            return None;
        }
        let pr = self.data.prs.get(&row.pr_id)?;
        let scope = self
            .enabled_scope_of(pr)
            .filter(|scope| !pr.unreadable && scope.notify && self.kind_notifies(row, pr))
            .map(|scope| scope.id.clone());
        if scope.is_none()
            && let Some(row) = self.row_mut(row_id)
        {
            row.notify = NotifyState::None;
        }
        scope
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
        let mut groups: Vec<(String, Vec<String>)> = Vec::new();
        for id in fresh {
            let Some(scope) = self.gate(&id) else {
                continue;
            };
            let comment = self
                .data
                .rows
                .get(&id)
                .filter(|row| row.kind == RowKind::Reaction)
                .and_then(|row| row.comment_id.clone());
            let group = comment.as_ref().and_then(|comment| {
                groups.iter_mut().find(|(group_scope, rows)| {
                    *group_scope == scope
                        && rows.first().is_some_and(|first| {
                            self.data
                                .rows
                                .get(first)
                                .is_some_and(|row| row.comment_id.as_ref() == Some(comment))
                        })
                })
            });
            match group {
                Some((_, rows)) => rows.push(id),
                None => groups.push((scope, vec![id])),
            }
        }
        for (scope, rows) in groups {
            if let Some(notification) = self.single(&scope, rows, now) {
                out.push(notification);
            }
        }
        out
    }

    /// The summaries an app gets when it connects.
    pub fn pending_summaries(&mut self, now: &Now) -> Vec<proto::Notification> {
        let pending: Vec<(String, String)> = self
            .data
            .rows
            .values()
            .filter(|row| row.notify == NotifyState::Pending)
            .map(|row| (row.id.clone(), row.pr_id.clone()))
            .collect();
        let mut rows = Vec::new();
        for (id, pr_id) in pending {
            if self.pr_snoozed(&pr_id) && !self.in_flight.contains(&id) {
                if let Some(row) = self.row_mut(&id) {
                    row.notify = NotifyState::HeldUndelivered;
                }
            } else {
                rows.push(id);
            }
        }
        self.summaries(rows, now, Summary::NewEvents)
    }

    /// One summary per scope, in scope order.
    fn summaries(
        &mut self,
        rows: Vec<String>,
        now: &Now,
        summary: Summary,
    ) -> Vec<proto::Notification> {
        let mut by_scope: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for id in rows {
            if let Some(scope) = self.gate(&id) {
                by_scope.entry(scope).or_default().push(id);
            }
        }
        let mut out = Vec::new();
        for (scope, rows) in by_scope {
            let prs: BTreeSet<&str> = rows
                .iter()
                .filter_map(|id| self.data.rows.get(id))
                .map(|row| row.pr_id.as_str())
                .collect();
            let pr_count = prs.len();
            let name = self.display_name(&scope);
            let (title, body) = match summary {
                Summary::NewEvents => (
                    format!("{name} · {}", plural(rows.len(), "new event", "new events")),
                    format!("In {}", plural(pr_count, "PR", "PRs")),
                ),
                Summary::BackFromSnooze => (
                    format!("{name} · Back from Snooze"),
                    format!("{} had new events", plural(pr_count, "PR", "PRs")),
                ),
            };
            self.in_flight.extend(rows.iter().cloned());
            out.push(proto::Notification {
                id: self.next_notification_id(now),
                kind: Lenient::Known(proto::NotificationType::Summary),
                scope,
                rows,
                pr: None,
                url: None,
                title,
                subtitle: None,
                body: Some(body),
            });
        }
        out
    }

    fn display_name(&self, scope: &str) -> String {
        if scope == PUBLIC {
            "Public".into()
        } else {
            scope.to_string()
        }
    }

    /// DESIGN.md, "macOS notifications": title, subtitle and body of a row, or
    /// of the Reaction rows of one comment.
    fn single(&mut self, scope: &str, rows: Vec<String>, now: &Now) -> Option<proto::Notification> {
        let row = self.data.rows.get(rows.first()?)?;
        let pr = self.data.prs.get(&row.pr_id)?;
        let body = if row.kind == RowKind::Reaction {
            let mut counts: BTreeMap<String, u32> = BTreeMap::new();
            for id in &rows {
                let row_counts = self.data.rows.get(id).and_then(|r| r.counts.as_ref());
                for (content, count) in row_counts.into_iter().flatten() {
                    *counts.entry(content.clone()).or_default() += count;
                }
            }
            let text = row.text.as_deref().unwrap_or_default();
            Some(format!("{} “{text}”", reaction_summary(&counts)))
        } else {
            row.text.clone()
        };
        let title = format!("{} · {}", self.display_name(scope), row.kind.label());
        let subtitle = format!("{}/{} #{} · {}", pr.owner, pr.repo, pr.number, pr.title);
        let key = pr.key();
        let url = row.url.clone();
        self.in_flight.extend(rows.iter().cloned());
        Some(proto::Notification {
            id: self.next_notification_id(now),
            kind: Lenient::Known(proto::NotificationType::Single),
            scope: scope.to_string(),
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

enum Summary {
    NewEvents,
    BackFromSnooze,
}

fn plural(count: usize, one: &str, many: &str) -> String {
    format!("{count} {}", if count == 1 { one } else { many })
}

fn row_defaults() -> RowRec {
    RowRec {
        id: String::new(),
        pr_id: String::new(),
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

pub const CONFIG_KEYS: [&str; 12] = [
    "launch_at_login",
    "status_interval_minutes",
    "reactions_interval_minutes",
    "graphql_cost_cap",
    "notify_activity",
    "notify_state",
    "notify_reactions",
    "snooze_return_time",
    "bot_comments",
    "include_team_requests",
    "keep_watching_days",
    "drop_after_days",
];

pub fn read_config(config: &Config, key: &str) -> Option<Value> {
    Some(match key {
        "launch_at_login" => json!(config.launch_at_login),
        "status_interval_minutes" => json!(config.status_interval_minutes),
        "reactions_interval_minutes" => json!(config.reactions_interval_minutes),
        "graphql_cost_cap" => json!(config.graphql_cost_cap),
        "notify_activity" => json!(config.notify_activity),
        "notify_state" => json!(config.notify_state),
        "notify_reactions" => json!(config.notify_reactions),
        "snooze_return_time" => {
            let (hour, minute) = config.snooze_return_time;
            json!(format!("{hour:02}:{minute:02}"))
        }
        "bot_comments" => json!(config.bot_comments.as_str()),
        "include_team_requests" => json!(config.include_team_requests),
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
        "graphql_cost_cap" => config.graphql_cost_cap = integer(key, value, 100)?,
        "notify_activity" => config.notify_activity = boolean(key, value)?,
        "notify_state" => config.notify_state = boolean(key, value)?,
        "notify_reactions" => config.notify_reactions = boolean(key, value)?,
        "snooze_return_time" => {
            config.snooze_return_time = value
                .as_str()
                .and_then(parse_clock_time)
                .ok_or_else(|| format!("{key} must be HH:MM"))?;
        }
        "bot_comments" => {
            config.bot_comments = value
                .as_str()
                .and_then(BotComments::parse)
                .ok_or_else(|| format!("{key} must be notify, list_only or hide"))?;
        }
        "include_team_requests" => config.include_team_requests = boolean(key, value)?,
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
        Value::String(text) if text.bytes().all(|b| b.is_ascii_digit()) => text.parse().ok(),
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
