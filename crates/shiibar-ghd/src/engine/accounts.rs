//! Accounts and owners: adding, removing, their switches, event tables and
//! Exclusions, and their wire values. DESIGN.md, "Settings" and "Owners".

use super::{CmdError, Engine, Result, not_found};
use crate::clock::Now;
use crate::model::*;
use shiibar_gh_proto as proto;
use shiibar_gh_proto::Lenient;
use std::collections::{BTreeMap, BTreeSet};

/// A GitHub login: letters, digits and single hyphens, not at either end,
/// at most 39 characters. DESIGN.md, "Wire format" (`owner_lookup`).
pub fn valid_login(owner: &str) -> bool {
    !owner.is_empty()
        && owner.len() <= 39
        && !owner.starts_with('-')
        && !owner.ends_with('-')
        && owner.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

impl Engine {
    // ------------------------------------------------------------ accounts

    /// After `reset`: the next Keychain read brings the accounts back.
    pub fn restore_after_reset(&mut self) {
        self.data.restore_accounts = true;
        self.dirty.meta = true;
    }

    /// The accounts came back from the Keychain.
    pub fn restored(&mut self) {
        self.data.restore_accounts = false;
        self.dirty.meta = true;
    }

    /// A new account. DESIGN.md, "Account colors": the first account is
    /// None, later ones take the first unused color, and once all are used
    /// the cycle starts again from Red.
    pub fn account_create(&mut self, id: &str, login: &str) -> Result<()> {
        if id.is_empty() || login.is_empty() {
            return Err(CmdError::Invalid(
                "the account needs an id and a login".into(),
            ));
        }
        if let Some(existing) = self.data.accounts.get(id) {
            return Err(CmdError::Invalid(format!(
                "{} is already added",
                existing.login
            )));
        }
        let color = if self.data.accounts.is_empty() {
            AccountColor::None
        } else {
            let used: BTreeSet<AccountColor> =
                self.data.accounts.values().map(|a| a.color).collect();
            AccountColor::CYCLE
                .iter()
                .copied()
                .find(|c| !used.contains(c))
                .unwrap_or_else(|| {
                    let colored = self
                        .data
                        .accounts
                        .values()
                        .filter(|a| a.color != AccountColor::None)
                        .count();
                    AccountColor::CYCLE[colored % AccountColor::CYCLE.len()]
                })
        };
        let seq = self.next_seq();
        self.dirty.accounts.insert(id.to_string());
        self.data.accounts.insert(
            id.to_string(),
            AccountRec {
                id: id.to_string(),
                login: login.to_string(),
                color,
                seq,
                token: TokenRec::default(),
                updated_at: None,
                dot: false,
                teams: Vec::new(),
                graphql: None,
                rest: None,
                stopped_until: None,
                fetch: FetchRec::default(),
            },
        );
        Ok(())
    }

    /// Everything of the account goes: owners, PRs, rows, Snooze and its
    /// fetch records. DESIGN.md, "Owners".
    pub fn account_remove(&mut self, id: &str) {
        let owners: Vec<String> = self
            .data
            .owners
            .values()
            .filter(|o| o.account == id)
            .map(|o| o.id.clone())
            .collect();
        for owner in owners {
            self.owner_remove(&owner);
        }
        let prs: Vec<String> = self
            .data
            .prs
            .values()
            .filter(|pr| pr.account == id)
            .map(|pr| pr.key.clone())
            .collect();
        self.delete_prs(&prs);
        self.data.accounts.remove(id);
        self.dirty.accounts.insert(id.to_string());
        self.open.remove(id);
        self.held.remove(id);
        self.timers.remove(id);
        self.failures.remove(id);
    }

    pub fn account_color(&mut self, login: &str, color: proto::AccountColor) -> Result<()> {
        let id = self.account_id(login)?;
        if let Some(account) = self.account_mut(&id) {
            account.color = color.into();
        }
        Ok(())
    }

    /// The accounts in registration order.
    pub fn accounts(&self) -> Vec<proto::Account> {
        let mut list: Vec<&AccountRec> = self.data.accounts.values().collect();
        list.sort_by_key(|a| a.seq);
        list.into_iter().map(|a| self.wire_account(a)).collect()
    }

    pub fn account_value(&self, id: &str) -> Option<proto::Account> {
        self.data.accounts.get(id).map(|a| self.wire_account(a))
    }

    fn wire_account(&self, account: &AccountRec) -> proto::Account {
        let owners: Vec<proto::Owner> = self
            .owners_of(&account.id)
            .into_iter()
            .map(|o| self.wire_owner(o))
            .collect();
        // A disabled owner counts nothing (`wire_owner`).
        let review_count = owners.iter().map(|o| o.review_count).sum();
        let limit = |l: &Option<LimitRec>| {
            l.map(|l| proto::Limit {
                used: (l.limit - l.remaining).max(0),
                limit: l.limit,
                reset_at: l.reset_at,
            })
        };
        let rate_limit =
            (account.graphql.is_some() || account.rest.is_some()).then(|| proto::RateLimit {
                graphql: limit(&account.graphql),
                rest: limit(&account.rest),
            });
        proto::Account {
            id: account.id.clone(),
            login: account.login.clone(),
            color: Lenient::Known(account.color.into()),
            token: proto::TokenInfo {
                registered: account.token.registered,
                expires_at: account.token.expires_at,
                last_test: account.token.last_test.as_ref().map(|t| proto::LastTest {
                    at: t.at,
                    results: t.results.clone(),
                }),
            },
            updated_at: account.updated_at,
            review_count,
            unread: account.dot,
            warnings: self.warnings(account),
            rate_limit,
            owners,
        }
    }

    /// `pr_count` is the cards `list` has for the owner outside Snoozed,
    /// the held ones included; `review_count` the PRs awaiting review
    /// (DESIGN.md, "Card states"). A disabled owner counts nothing.
    fn wire_owner(&self, owner: &OwnerRec) -> proto::Owner {
        let now = self.clock.at;
        let mut review_count = 0;
        let mut pr_count = 0;
        if owner.enabled {
            for pr in self.data.prs.values() {
                if pr.account != owner.account
                    || pr.snoozed
                    || self.owner_of(pr).is_none_or(|o| o.id != owner.id)
                {
                    continue;
                }
                if self.awaiting_review(pr, owner) {
                    review_count += 1;
                }
                if self.shows_unsnoozed(pr, owner, now) {
                    pr_count += 1;
                }
            }
        }
        proto::Owner {
            id: owner.id.clone(),
            name: owner.name.clone(),
            kind: Lenient::Known(owner.kind.into()),
            github_id: owner.github_id,
            enabled: owner.enabled,
            notify: owner.notify,
            skip_drafts: owner.skip_drafts,
            review_count,
            pr_count,
        }
    }

    // -------------------------------------------------------------- owners

    /// Register an owner, or Public with kind `public`. Its watch starts now.
    pub fn owner_add(
        &mut self,
        account: &str,
        name: &str,
        kind: OwnerKind,
        github_id: Option<i64>,
        now: &Now,
    ) -> Result<String> {
        if !self.data.accounts.contains_key(account) {
            return Err(not_found(format!("account {account}")));
        }
        let public = kind == OwnerKind::Public;
        if !public && (name.eq_ignore_ascii_case(PUBLIC) || !valid_login(name)) {
            return Err(CmdError::Invalid(format!("not an owner login: {name}")));
        }
        let lookup = if public { PUBLIC } else { name };
        if self.owner_id(account, lookup).is_ok() {
            let shown = if public { "Public" } else { name };
            return Err(CmdError::Invalid(format!("{shown} is already added")));
        }
        let seq = self.next_seq();
        let id = format!("o{seq}");
        self.dirty.owners.insert(id.clone());
        self.data.owners.insert(
            id.clone(),
            OwnerRec {
                id: id.clone(),
                account: account.to_string(),
                name: if public { "Public".into() } else { name.into() },
                kind,
                github_id: if public { None } else { github_id },
                seq,
                enabled: true,
                notify: true,
                skip_drafts: true,
                watch_started_at: now.at,
                fetched_at: None,
                events: EventTable::default(),
                repos: Vec::new(),
                users: Vec::new(),
            },
        );
        self.start_watch(&id, now);
        self.settle(now);
        Ok(id)
    }

    /// Delete the PRs and everything recorded about them.
    fn delete_prs(&mut self, keys: &[String]) {
        let set: BTreeSet<&String> = keys.iter().collect();
        for key in keys {
            if let Some(rows) = self.rows_by_pr.remove(key) {
                for id in rows {
                    self.data.rows.remove(&id);
                    self.dirty.rows.insert(id.clone());
                    self.in_flight.remove(&id);
                }
            }
            if let Some(pr) = self.data.prs.remove(key) {
                self.dirty.prs.insert(key.clone());
                if let Some(account) = self.data.accounts.get_mut(&pr.account) {
                    let fetch = &mut account.fetch;
                    fetch.own.retain(|_, c| c.pr_id != pr.id);
                    fetch.threads.retain(|_, t| t.pr_id != pr.id);
                    fetch.retries.remove(&pr.id);
                    fetch
                        .pending_signals
                        .remove(&crate::plan::pr_key(&pr.owner, &pr.repo, pr.number));
                    self.dirty.accounts.insert(pr.account.clone());
                }
            }
        }
        let baselines: Vec<String> = self
            .data
            .baselines
            .values()
            .filter(|b| set.contains(&b.pr))
            .map(|b| b.key.clone())
            .collect();
        for key in baselines {
            self.data.baselines.remove(&key);
            self.dirty.baselines.insert(key);
        }
        self.fresh.retain(|id| self.data.rows.contains_key(id));
        self.released.retain(|id| self.data.rows.contains_key(id));
    }

    /// Remove an owner and its PRs, rows, snoozes and settings.
    pub fn owner_remove(&mut self, id: &str) {
        let prs: Vec<String> = self
            .data
            .prs
            .values()
            .filter(|pr| self.owner_of(pr).is_some_and(|o| o.id == id))
            .map(|pr| pr.key.clone())
            .collect();
        self.delete_prs(&prs);
        self.data.owners.remove(id);
        self.dirty.owners.insert(id.to_string());
    }

    /// A new watch start forgets the owner's previous values and Reaction
    /// baselines. DESIGN.md, "Events before the watch started".
    pub(super) fn start_watch(&mut self, owner: &str, now: &Now) {
        if let Some(record) = self.owner_mut(owner) {
            record.watch_started_at = now.at;
        }
        let prs: Vec<(String, String, String)> = self
            .data
            .prs
            .values()
            .filter(|pr| self.owner_of(pr).is_some_and(|o| o.id == owner))
            .map(|pr| (pr.key.clone(), pr.account.clone(), pr.id.clone()))
            .collect();
        for (key, _, _) in &prs {
            if let Some(pr) = self.pr_mut(key) {
                pr.prev = None;
            }
        }
        let keys: BTreeSet<&String> = prs.iter().map(|(k, _, _)| k).collect();
        let baselines: Vec<String> = self
            .data
            .baselines
            .values()
            .filter(|b| keys.contains(&b.pr))
            .map(|b| b.key.clone())
            .collect();
        for key in baselines {
            self.data.baselines.remove(&key);
            self.dirty.baselines.insert(key);
        }
        // The next Reaction fetch sets the baselines again without rows.
        for (_, account, node) in &prs {
            if let Some(record) = self.data.accounts.get_mut(account) {
                for own in record.fetch.own.values_mut() {
                    if own.pr_id == *node {
                        own.baseline_done = false;
                    }
                }
                self.dirty.accounts.insert(account.clone());
            }
        }
    }

    pub fn owner_enable(&mut self, id: &str, on: bool, now: &Now) {
        let was = self.data.owners.get(id).is_some_and(|o| o.enabled);
        if let Some(owner) = self.owner_mut(id) {
            owner.enabled = on;
        }
        if on && !was {
            self.start_watch(id, now);
            self.settle(now);
        }
    }

    pub fn owner_notify(&mut self, id: &str, on: bool) {
        if let Some(owner) = self.owner_mut(id) {
            owner.notify = on;
        }
    }

    pub fn owner_skip_drafts(&mut self, id: &str, on: bool) {
        if let Some(owner) = self.owner_mut(id) {
            owner.skip_drafts = on;
        }
    }

    pub fn owner_events(&self, id: &str) -> BTreeMap<String, proto::EventCell> {
        self.data
            .owners
            .get(id)
            .map(|o| {
                o.events
                    .0
                    .iter()
                    .map(|(k, c)| {
                        (
                            k.as_str().to_string(),
                            proto::EventCell {
                                list: c.list,
                                notify: c.notify,
                            },
                        )
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// DESIGN.md, "Applying the table": List off turns Notify off; Notify
    /// cannot be on while List is off.
    pub fn owner_events_set(
        &mut self,
        id: &str,
        kind: proto::EventKind,
        column: proto::EventColumn,
        on: bool,
        now: &Now,
    ) -> Result<()> {
        let kind: EventKind = kind.into();
        let Some(owner) = self.data.owners.get(id) else {
            return Err(not_found(format!("owner {id}")));
        };
        let mut cell = owner.events.cell(kind);
        match column {
            proto::EventColumn::List => {
                cell.list = on;
                if !on {
                    cell.notify = false;
                }
            }
            proto::EventColumn::Notify if on && !cell.list => {
                return Err(CmdError::Invalid(format!(
                    "List is off for {}: turn it on first",
                    kind.as_str()
                )));
            }
            proto::EventColumn::Notify => cell.notify = on,
        }
        if let Some(owner) = self.owner_mut(id) {
            owner.events.0.insert(kind, cell);
        }
        self.settle(now);
        Ok(())
    }

    /// Copy the table only; the switches and Exclusions stay.
    pub fn owner_events_copy(&mut self, from: &str, to: &str, now: &Now) -> Result<()> {
        let table = self
            .data
            .owners
            .get(from)
            .map(|o| o.events.clone())
            .ok_or_else(|| not_found(format!("owner {from}")))?;
        if let Some(owner) = self.owner_mut(to) {
            owner.events = table;
        }
        self.settle(now);
        Ok(())
    }

    pub fn owner_exclusions(&self, id: &str) -> proto::Exclusions {
        let wire = |list: &[ExclusionRec]| {
            list.iter()
                .map(|e| proto::Exclusion {
                    name: e.name.clone(),
                    state: Lenient::Known(e.state.into()),
                })
                .collect()
        };
        match self.data.owners.get(id) {
            Some(o) => proto::Exclusions {
                repos: wire(&o.repos),
                users: wire(&o.users),
            },
            None => proto::Exclusions {
                repos: Vec::new(),
                users: Vec::new(),
            },
        }
    }

    /// Add a name, or change the state of the one already there.
    pub fn owner_exclusions_set(
        &mut self,
        id: &str,
        kind: proto::ExclusionKind,
        name: &str,
        state: proto::ExclusionState,
        now: &Now,
    ) -> Result<()> {
        let name = name.trim();
        let valid = match kind {
            proto::ExclusionKind::Repo => {
                name.split_once('/')
                    .is_some_and(|(o, r)| !o.is_empty() && !r.is_empty() && !r.contains('/'))
                    && !name.contains(char::is_whitespace)
            }
            proto::ExclusionKind::User => {
                !name.is_empty() && !name.contains('/') && !name.contains(char::is_whitespace)
            }
        };
        if !valid {
            return Err(CmdError::Invalid(match kind {
                proto::ExclusionKind::Repo => format!("a repository is owner/repo, not {name}"),
                proto::ExclusionKind::User => format!("not a user login: {name}"),
            }));
        }
        let state: ExclusionState = state.into();
        let Some(owner) = self.owner_mut(id) else {
            return Err(not_found(format!("owner {id}")));
        };
        let list = match kind {
            proto::ExclusionKind::Repo => &mut owner.repos,
            proto::ExclusionKind::User => &mut owner.users,
        };
        let same = |e: &ExclusionRec| match kind {
            proto::ExclusionKind::Repo => e.name.eq_ignore_ascii_case(name),
            proto::ExclusionKind::User => user_key(&e.name) == user_key(name),
        };
        match list.iter_mut().find(|e| same(e)) {
            Some(item) => item.state = state,
            None => list.push(ExclusionRec {
                name: name.to_string(),
                state,
            }),
        }
        self.settle(now);
        Ok(())
    }

    pub fn owner_exclusions_remove(
        &mut self,
        id: &str,
        kind: proto::ExclusionKind,
        name: &str,
        now: &Now,
    ) -> Result<()> {
        let name = name.trim();
        let Some(owner) = self.data.owners.get(id) else {
            return Err(not_found(format!("owner {id}")));
        };
        let list = match kind {
            proto::ExclusionKind::Repo => &owner.repos,
            proto::ExclusionKind::User => &owner.users,
        };
        let position = list.iter().position(|e| match kind {
            proto::ExclusionKind::Repo => e.name.eq_ignore_ascii_case(name),
            proto::ExclusionKind::User => user_key(&e.name) == user_key(name),
        });
        let Some(position) = position else {
            return Err(not_found(format!("exclusion {name}")));
        };
        if let Some(owner) = self.owner_mut(id) {
            match kind {
                proto::ExclusionKind::Repo => owner.repos.remove(position),
                proto::ExclusionKind::User => owner.users.remove(position),
            };
        }
        self.settle(now);
        Ok(())
    }
}
