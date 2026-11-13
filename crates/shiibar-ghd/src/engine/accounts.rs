//! Accounts and owners: adding, removing, their switches and event tables,
//! and their wire values. DESIGN.md, "Settings" and "Owners".

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
                mutes: MuteRec::default(),
            },
        );
        Ok(())
    }

    /// Everything of the account goes: owners, PRs, rows, places, Dismiss
    /// records, Mute lists and its fetch records. DESIGN.md, "Owners".
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
        self.forget_records_of_account(id);
        self.data.accounts.remove(id);
        self.dirty.accounts.insert(id.to_string());
        self.open.remove(id);
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
            unread: account.dot,
            warnings: self.warnings(account),
            rate_limit,
            owners,
        }
    }

    /// `pr_count` is the owner's cards that are not dismissed. A disabled
    /// owner counts nothing.
    fn wire_owner(&self, owner: &OwnerRec) -> proto::Owner {
        let mut pr_count = 0;
        if owner.enabled {
            for pr in self.data.prs.values() {
                if pr.account == owner.account
                    && self.owner_of(pr).is_some_and(|o| o.id == owner.id)
                    && self.in_lists(pr)
                {
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
            },
        );
        self.start_watch(&id, now);
        self.settle(now);
        Ok(id)
    }

    /// Delete the PRs and everything recorded about them.
    pub(super) fn delete_prs(&mut self, keys: &[String]) {
        let set: BTreeSet<&String> = keys.iter().collect();
        for key in keys {
            if let Some(rows) = self.rows_by_pr.remove(key) {
                for id in rows {
                    self.data.rows.remove(&id);
                    self.dirty.rows.insert(id.clone());
                    self.in_flight.remove(&id);
                }
            }
            if self.pruned_prs.remove(key) {
                let deleted: Vec<String> = self
                    .data
                    .deleted_rows
                    .iter()
                    .filter(|(_, pr)| *pr == key)
                    .map(|(id, _)| id.clone())
                    .collect();
                for id in deleted {
                    self.data.deleted_rows.remove(&id);
                    self.dirty.deleted_rows.insert(id);
                }
            }
            if let Some(pr) = self.data.prs.remove(key) {
                self.dirty.prs.insert(key.clone());
                if let Some(account) = self.data.accounts.get_mut(&pr.account) {
                    let fetch = &mut account.fetch;
                    fetch.own.retain(|_, c| c.pr_id != pr.id);
                    fetch.threads.retain(|_, t| t.pr_id != pr.id);
                    fetch.retries.remove(&pr.id);
                    fetch.status_failures.remove(&pr.id);
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
    }

    /// Remove an owner and its PRs, rows, places, Dismiss records and
    /// settings.
    pub fn owner_remove(&mut self, id: &str) {
        let prs: Vec<String> = self
            .data
            .prs
            .values()
            .filter(|pr| self.owner_of(pr).is_some_and(|o| o.id == id))
            .map(|pr| pr.key.clone())
            .collect();
        self.delete_prs(&prs);
        self.forget_records_of_owner(id);
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
                pr.watch_reset = true;
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

    /// Copy the table only; the switches stay.
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
}
