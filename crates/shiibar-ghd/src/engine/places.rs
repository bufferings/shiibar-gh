//! Placement, Dismiss and Mute: where a card is in Review and Mine, its
//! position, the Dismissed list and its clocks, and the Mute lists.
//! DESIGN.md, "Review", "Mine", "Dismiss", "Mute" and "Card states".

use super::{DAY_SECS, Engine, PlaceArgs, Result, invalid, not_found, same_pr, view_of};
use crate::clock::Now;
use crate::model::*;
use shiibar_gh_proto as proto;
use std::collections::{BTreeSet, HashMap};

/// A section of a tab while open, as a card's `place` holds it.
fn wire_section(section: Section) -> proto::Section {
    match section {
        Section::Doing => proto::Section::Doing,
        Section::Todo => proto::Section::Todo,
        Section::Waiting => proto::Section::Waiting,
        Section::Main => proto::Section::Main,
    }
}

impl Engine {
    // ------------------------------------------------------------ positions

    /// The order key of a card inside its section: muted cards last, then
    /// the user's rank, or in Done the newest entry first (the detection of
    /// the merge or close, or the user's move to Done).
    fn order_key(&self, pr: &PrRec) -> (bool, i64, String) {
        let primary = match pr.done_at {
            Some(at) => -at,
            None => pr.place.map_or(0, |p| p.rank),
        };
        (self.card_muted(pr), primary, pr.key.clone())
    }

    /// The position of every placed card in the lists, by PR key. DESIGN.md,
    /// "Wire format": `position` counts from 0, muted cards last.
    pub(super) fn positions(&self) -> HashMap<String, u32> {
        let mut sections: HashMap<(String, PlacedTab, proto::Section), Vec<&PrRec>> =
            HashMap::new();
        for pr in self.data.prs.values() {
            if !self.in_lists(pr) {
                continue;
            }
            if let Some((tab, section)) = view_of(pr) {
                sections
                    .entry((pr.account.clone(), tab, section))
                    .or_default()
                    .push(pr);
            }
        }
        let mut out = HashMap::new();
        for (_, mut members) in sections {
            members.sort_by_cached_key(|pr| self.order_key(pr));
            for (i, pr) in members.iter().enumerate() {
                out.insert(pr.key.clone(), i as u32);
            }
        }
        out
    }

    /// The position a card not in the lists (dismissed, or of a disabled
    /// owner) would have if it came back now.
    pub(super) fn position_alone(&self, pr: &PrRec) -> u32 {
        let Some(view) = view_of(pr) else {
            return 0;
        };
        let mine = self.order_key(pr);
        self.data
            .prs
            .values()
            .filter(|other| {
                other.account == pr.account
                    && other.key != pr.key
                    && self.in_lists(other)
                    && view_of(other) == Some(view)
                    && self.order_key(other) < mine
            })
            .count() as u32
    }

    /// The cards of an account placed in a section while open, the closed
    /// and hidden ones included, in rank order.
    fn section_members(&self, account: &str, tab: PlacedTab, section: Section) -> Vec<String> {
        let mut members: Vec<(i64, String)> = self
            .data
            .prs
            .values()
            .filter(|pr| {
                pr.account == account
                    && pr
                        .place
                        .is_some_and(|p| p.tab == tab && p.section == section)
            })
            .map(|pr| (pr.place.map_or(0, |p| p.rank), pr.key.clone()))
            .collect();
        members.sort();
        members.into_iter().map(|(_, key)| key).collect()
    }

    /// Put a card at `index` among the other cards of the section and number
    /// the section again; ranks keep the order of the hidden cards too.
    fn place_at(&mut self, key: &str, tab: PlacedTab, section: Section, index: usize) {
        let Some(account) = self.data.prs.get(key).map(|p| p.account.clone()) else {
            return;
        };
        let mut members: Vec<String> = self
            .section_members(&account, tab, section)
            .into_iter()
            .filter(|k| k != key)
            .collect();
        let index = index.min(members.len());
        members.insert(index, key.to_string());
        for (rank, member) in members.iter().enumerate() {
            let rank = rank as i64;
            let changed = self
                .data
                .prs
                .get(member)
                .is_none_or(|pr| pr.place != Some(PlaceRec { tab, section, rank }));
            if changed && let Some(pr) = self.pr_mut(member) {
                pr.place = Some(PlaceRec { tab, section, rank });
            }
        }
    }

    /// Automatic additions and `Add to …` go to the end: after every card of
    /// the section, so after the cards that are not muted, and a muted card
    /// after the muted ones (DESIGN.md, "Review").
    pub(super) fn place_at_end(&mut self, key: &str, tab: PlacedTab, section: Section) {
        let Some(account) = self.data.prs.get(key).map(|p| p.account.clone()) else {
            return;
        };
        let end = self
            .data
            .prs
            .values()
            .filter(|pr| {
                pr.account == account
                    && pr.key != key
                    && pr
                        .place
                        .is_some_and(|p| p.tab == tab && p.section == section)
            })
            .map(|pr| pr.place.map_or(0, |p| p.rank))
            .max()
            .map_or(0, |rank| rank + 1);
        if let Some(pr) = self.pr_mut(key) {
            pr.place = Some(PlaceRec {
                tab,
                section,
                rank: end,
            });
        }
    }

    // ---------------------------------------------------------------- place

    /// `place`. DESIGN.md, "Wire format": the position defaults, the cases
    /// that are `invalid`, Done, and a merged or closed unplaced PR going
    /// straight to Done.
    pub fn place(&mut self, account: &str, key: &str, args: &PlaceArgs) -> Result<proto::Card> {
        let pr = self.usable_pr(account, key)?;
        let pr_key = pr.key.clone();
        let account_id = pr.account.clone();
        if pr.dismissed_at.is_some() {
            return Err(invalid(format!("{key} is dismissed; restore it first")));
        }
        let open = pr.state == PrState::Open;
        let authored = self.authored_by_me(pr);
        if args.before.is_some() && args.at.is_some() {
            return Err(invalid("place takes before or at, not both"));
        }
        let from = pr.place;
        let from_done = from.is_some() && pr.done_at.is_some();
        let now = self.clock.at;
        // Where the card goes: a tab and its section, or that tab's Done.
        let (tab, section, to_done) = match args.tab {
            proto::PlaceTab::None => {
                if args.section.is_some() || args.before.is_some() || args.at.is_some() {
                    return Err(invalid("place none takes no section or position"));
                }
                if authored {
                    return Err(invalid(format!("{key} is your own and stays in Mine")));
                }
                if let Some(pr) = self.pr_mut(&pr_key) {
                    pr.place = None;
                    // An unplaced open PR is in no Done. An unplaced closed
                    // one keeps the time it entered Done, or counts its n
                    // days from now when it comes from outside Done.
                    pr.done_at = if open { None } else { pr.done_at.or(Some(now)) };
                }
                return self.card_of(&pr_key);
            }
            proto::PlaceTab::Review => {
                if authored {
                    return Err(invalid(format!("{key} is your own and stays in Mine")));
                }
                match args.section {
                    _ if !open && from.is_none() => (PlacedTab::Review, Section::Todo, true),
                    Some(proto::Section::Doing) => (PlacedTab::Review, Section::Doing, false),
                    Some(proto::Section::Todo) => (PlacedTab::Review, Section::Todo, false),
                    Some(proto::Section::Waiting) => (PlacedTab::Review, Section::Waiting, false),
                    Some(proto::Section::Done) => (PlacedTab::Review, Section::Todo, true),
                    Some(_) => return Err(invalid("review takes doing, todo, waiting or done")),
                    None => return Err(invalid("review needs a section")),
                }
            }
            proto::PlaceTab::Mine => match args.section {
                _ if !open && from.is_none() => (PlacedTab::Mine, Section::Main, true),
                None | Some(proto::Section::Main) => (PlacedTab::Mine, Section::Main, false),
                Some(proto::Section::Done) => (PlacedTab::Mine, Section::Main, true),
                Some(_) => return Err(invalid("mine takes main or done")),
            },
        };
        if to_done {
            // DESIGN.md, "Review": Done keeps its own order, newest entry
            // first. A merged or closed unplaced PR goes straight to Done
            // and keeps the time of its detection; another card enters Done
            // now. A card keeps the section and rank it had before Done, or
            // takes the end of Todo (Mine) when it comes from elsewhere.
            if !open && from.is_none() {
                self.place_at_end(&pr_key, tab, section);
                if let Some(pr) = self.pr_mut(&pr_key) {
                    pr.done_at = pr.done_at.or(Some(now));
                }
                return self.card_of(&pr_key);
            }
            if args.before.is_some() || args.at.is_some() {
                return Err(invalid("done keeps its own order and takes no position"));
            }
            let same_tab = from.is_some_and(|p| p.tab == tab);
            if same_tab && from_done {
                return self.card_of(&pr_key);
            }
            if !same_tab {
                self.place_at_end(&pr_key, tab, section);
            }
            if let Some(pr) = self.pr_mut(&pr_key) {
                pr.done_at = Some(now);
            }
            return self.card_of(&pr_key);
        }
        let members: Vec<String> = self
            .section_members(&account_id, tab, section)
            .into_iter()
            .filter(|k| *k != pr_key)
            .collect();
        let index = match (&args.before, args.at) {
            (Some(before), _) => {
                let target = self
                    .data
                    .prs
                    .values()
                    .find(|other| other.account == account_id && same_pr(other, before))
                    .filter(|other| {
                        other.key != pr_key
                            && self.in_lists(other)
                            && view_of(other) == Some((tab, wire_section(section)))
                    })
                    .ok_or_else(|| invalid(format!("{before} is not in that section")))?;
                if self.card_muted(target) {
                    return Err(invalid(format!("{before} is muted")));
                }
                members
                    .iter()
                    .position(|k| *k == target.key)
                    .unwrap_or(members.len())
            }
            (None, Some(proto::At::Top)) => 0,
            (None, Some(proto::At::Bottom)) => members.len(),
            (None, None) => {
                let from_side = !from_done
                    && from.is_some_and(|p| {
                        p.tab == PlacedTab::Review
                            && matches!(p.section, Section::Doing | Section::Waiting)
                    });
                if tab == PlacedTab::Review && section == Section::Todo && from_side {
                    0
                } else {
                    members.len()
                }
            }
        };
        // Out of Done: the card leaves Done for good; a merged or closed
        // card is not moved back by later fetches (DESIGN.md, "Review").
        if let Some(pr) = self.pr_mut(&pr_key)
            && pr.done_at.is_some()
        {
            pr.done_at = None;
        }
        self.place_at(&pr_key, tab, section, index);
        self.card_of(&pr_key)
    }

    // -------------------------------------------------------------- Dismiss

    /// `dismiss`: the card leaves All, Review and Mine for the Dismissed
    /// list, keeping its place.
    pub fn dismiss(&mut self, account: &str, key: &str, now: &Now) -> Result<proto::Card> {
        let pr = self.usable_pr(account, key)?;
        if pr.dismissed_at.is_some() {
            return Err(invalid(format!("{key} is already dismissed")));
        }
        let pr_key = pr.key.clone();
        if let Some(pr) = self.pr_mut(&pr_key) {
            pr.dismissed_at = Some(now.at);
            pr.seen_closed = false;
        }
        self.card_of(&pr_key)
    }

    /// `restore`: back to the place it had, never dismissed automatically
    /// again.
    pub fn restore_pr(&mut self, account: &str, key: &str) -> Result<proto::Card> {
        let pr = self.usable_pr(account, key)?;
        if pr.dismissed_at.is_none() {
            return Err(invalid(format!("{key} is not in the Dismissed list")));
        }
        let pr_key = pr.key.clone();
        let account = pr.account.clone();
        let before = self.blue_rows(&account);
        self.return_card(&pr_key, true);
        self.raise_dot_if_new(&account, &before);
        self.card_of(&pr_key)
    }

    /// A dismissed card comes back to its place: by a return trigger row, or
    /// by `restore`. Its status, Checks and reactions start over from what
    /// the next fetch sees (DESIGN.md, "Dismiss").
    pub(super) fn return_card(&mut self, key: &str, restored: bool) {
        let now = self.clock.at;
        let Some(pr) = self.pr_mut(key) else {
            return;
        };
        pr.quiet_from = pr.dismissed_at;
        pr.quiet_until = Some(now);
        pr.dismissed_at = None;
        pr.prev = None;
        pr.collected = false;
        pr.seen_closed = false;
        if restored {
            pr.restored = true;
        }
        // A PR merged or closed before it was dismissed counts its n days
        // again from its return.
        if pr.state != PrState::Open {
            pr.closed_at = Some(now);
        }
        let account = pr.account.clone();
        let node = pr.id.clone();
        self.forget_baselines(&account, &node, key);
    }

    /// The Reaction counts of the PR start again from the next fetch.
    pub(super) fn forget_baselines(&mut self, account: &str, node: &str, key: &str) {
        let baselines: Vec<String> = self
            .data
            .baselines
            .values()
            .filter(|b| b.pr == key)
            .map(|b| b.key.clone())
            .collect();
        for baseline in baselines {
            self.data.baselines.remove(&baseline);
            self.dirty.baselines.insert(baseline);
        }
        if let Some(record) = self.data.accounts.get_mut(account) {
            let mut changed = false;
            for own in record.fetch.own.values_mut() {
                if own.pr_id == node && own.baseline_done {
                    own.baseline_done = false;
                    changed = true;
                }
            }
            if changed {
                self.dirty.accounts.insert(account.to_string());
            }
        }
    }

    /// DESIGN.md, "Dismiss": when the automatic Dismiss of a card not
    /// dismissed is due, or `None` when none is scheduled. A merged or closed
    /// card in Done goes n days after it entered Done or after the detection
    /// of the merge or close, whichever is later; an unplaced one n days
    /// after the detection or its removal from outside Done; one outside Done
    /// never. A restored card and one
    /// with a Mentioned or Reply row after the close never go.
    pub(super) fn auto_dismiss_at(&self, pr: &PrRec) -> Option<i64> {
        if pr.state == PrState::Open
            || pr.dismissed_at.is_some()
            || pr.restored
            || pr.keep_after_close
        {
            return None;
        }
        let n = self
            .data
            .config
            .auto_dismiss_after_days
            .saturating_mul(DAY_SECS);
        let closed = pr.closed_at?;
        let from = match pr.place {
            None => closed.max(pr.done_at.unwrap_or(closed)),
            Some(_) => closed.max(pr.done_at?),
        };
        Some(from.saturating_add(n))
    }

    /// DESIGN.md, "Dismiss": the automatic Dismiss n days after a merge or
    /// close, and the end of the Dismissed list m days after a Dismiss. Both
    /// wait while the account's popover or window is open.
    pub(super) fn dismiss_by_time(&mut self, now: &Now) {
        let m = self
            .data
            .config
            .dismissed_keep_days
            .saturating_mul(DAY_SECS);
        let mut dismiss = Vec::new();
        let mut expire = Vec::new();
        for pr in self.data.prs.values() {
            if self.open.contains(&pr.account) {
                continue;
            }
            match pr.dismissed_at {
                Some(at) if now.at >= at.saturating_add(m) => expire.push(pr.key.clone()),
                Some(_) => {}
                None => {
                    if self.auto_dismiss_at(pr).is_some_and(|at| now.at >= at) {
                        dismiss.push(pr.key.clone());
                    }
                }
            }
        }
        for key in dismiss {
            if let Some(pr) = self.pr_mut(&key) {
                pr.dismissed_at = Some(now.at);
            }
        }
        for key in expire {
            self.expire(&key);
        }
    }

    /// The card leaves the Dismissed list: its PR, rows and place go. An
    /// open PR leaves a Dismiss record (DESIGN.md, "Dismiss record").
    fn expire(&mut self, key: &str) {
        let Some(pr) = self.data.prs.get(key) else {
            return;
        };
        let keep = pr.state == PrState::Open && !pr.seen_closed;
        let owner = self.owner_of(pr).map(|o| o.id.clone());
        let record = DismissRecord {
            key: key.to_string(),
            account: pr.account.clone(),
            pr_id: pr.id.clone(),
            owner: owner.clone().unwrap_or_default(),
            updated_at: pr.updated_at,
        };
        self.delete_prs(&[key.to_string()]);
        if keep && owner.is_some() {
            self.data.records.insert(key.to_string(), record);
            self.dirty.records.insert(key.to_string());
        }
    }

    // ----------------------------------------------------------------- Mute

    pub(super) fn wire_mutes(&self, account: &str) -> proto::Mutes {
        self.mutes_of(account)
            .map(|m| proto::Mutes {
                repos: m.repos.clone(),
                users: m.users.clone(),
                prs: m.prs.clone(),
            })
            .unwrap_or_default()
    }

    pub fn mutes_get(&self, account: &str) -> Result<proto::Mutes> {
        let id = self.account_id(account)?;
        Ok(self.wire_mutes(&id))
    }

    /// `mute`. DESIGN.md, "Wire format": a malformed name is `invalid`, one
    /// already there changes nothing, and a PR has to be one the account
    /// knows.
    pub fn mute(
        &mut self,
        account: &str,
        kind: proto::MuteKind,
        name: &str,
    ) -> Result<proto::Mutes> {
        let id = self.account_id(account)?;
        let name = name.trim();
        let stored = match kind {
            proto::MuteKind::Pr => {
                if !valid_pr_name(name) {
                    return Err(invalid(format!(
                        "a pull request is owner/repo#number, not {name}"
                    )));
                }
                self.data
                    .prs
                    .values()
                    .find(|pr| pr.account == id && same_pr(pr, name))
                    .map(|pr| pr.display_key())
                    .ok_or_else(|| not_found(format!("PR {name}")))?
            }
            proto::MuteKind::Repo => {
                if !valid_repo_name(name) {
                    return Err(invalid(format!("a repository is owner/repo, not {name}")));
                }
                name.to_string()
            }
            proto::MuteKind::User => {
                if name.is_empty()
                    || name.contains(['/', '#'])
                    || name.contains(char::is_whitespace)
                {
                    return Err(invalid(format!("not a user login: {name}")));
                }
                name.to_string()
            }
        };
        let Some(record) = self.data.accounts.get(&id) else {
            return Err(not_found(format!("account {account}")));
        };
        let present = mute_list(&record.mutes, kind)
            .iter()
            .any(|m| same_mute(kind, m, &stored));
        if !present && let Some(record) = self.account_mut(&id) {
            mute_list_mut(&mut record.mutes, kind).push(stored);
        }
        Ok(self.wire_mutes(&id))
    }

    /// `unmute`: muted rows that are unread turn blue, and raise the menu bar
    /// dot (DESIGN.md, "How unread rows go away").
    pub fn unmute(
        &mut self,
        account: &str,
        kind: proto::MuteKind,
        name: &str,
    ) -> Result<proto::Mutes> {
        let id = self.account_id(account)?;
        let name = name.trim();
        let Some(record) = self.data.accounts.get(&id) else {
            return Err(not_found(format!("account {account}")));
        };
        let Some(index) = mute_list(&record.mutes, kind)
            .iter()
            .position(|m| same_mute(kind, m, name))
        else {
            return Err(not_found(format!("mute {name}")));
        };
        let before = self.blue_rows(&id);
        if let Some(record) = self.account_mut(&id) {
            mute_list_mut(&mut record.mutes, kind).remove(index);
        }
        self.raise_dot_if_new(&id, &before);
        Ok(self.wire_mutes(&id))
    }

    /// The Mute lists and Dismiss records an owner removal takes with it.
    pub(super) fn forget_records_of_owner(&mut self, owner: &str) {
        let keys: Vec<String> = self
            .data
            .records
            .values()
            .filter(|r| r.owner == owner)
            .map(|r| r.key.clone())
            .collect();
        for key in keys {
            self.data.records.remove(&key);
            self.dirty.records.insert(key);
        }
    }

    pub(super) fn forget_records_of_account(&mut self, account: &str) {
        let keys: Vec<String> = self
            .data
            .records
            .values()
            .filter(|r| r.account == account)
            .map(|r| r.key.clone())
            .collect();
        for key in keys {
            self.data.records.remove(&key);
            self.dirty.records.insert(key);
        }
    }

    /// A card's section, for tests and the CLI.
    pub fn view(&self, key: &str) -> Option<(PlacedTab, proto::Section)> {
        self.data.prs.get(key).and_then(view_of)
    }

    /// The section a PR is placed in while open.
    pub fn open_section(&self, key: &str) -> Option<proto::Section> {
        self.data
            .prs
            .get(key)
            .and_then(|p| p.place)
            .map(|p| wire_section(p.section))
    }

    /// The keys of the Dismiss records of an account.
    pub fn records_of(&self, account: &str) -> BTreeSet<String> {
        self.data
            .records
            .values()
            .filter(|r| r.account == account)
            .map(|r| r.key.clone())
            .collect()
    }
}

fn mute_list(mutes: &MuteRec, kind: proto::MuteKind) -> &Vec<String> {
    match kind {
        proto::MuteKind::Pr => &mutes.prs,
        proto::MuteKind::Repo => &mutes.repos,
        proto::MuteKind::User => &mutes.users,
    }
}

fn mute_list_mut(mutes: &mut MuteRec, kind: proto::MuteKind) -> &mut Vec<String> {
    match kind {
        proto::MuteKind::Pr => &mut mutes.prs,
        proto::MuteKind::Repo => &mut mutes.repos,
        proto::MuteKind::User => &mut mutes.users,
    }
}

/// Names compare without case (DESIGN.md, "Mute").
fn same_mute(kind: proto::MuteKind, a: &str, b: &str) -> bool {
    match kind {
        proto::MuteKind::User => user_key(a) == user_key(b),
        _ => a.eq_ignore_ascii_case(b),
    }
}

/// `owner/repo`: two parts, neither empty, no white space or `#`.
fn valid_repo_name(name: &str) -> bool {
    name.split_once('/')
        .is_some_and(|(o, r)| !o.is_empty() && !r.is_empty() && !r.contains('/'))
        && !name.contains(char::is_whitespace)
        && !name.contains('#')
}

/// `owner/repo#number`.
fn valid_pr_name(name: &str) -> bool {
    name.split_once('#').is_some_and(|(repo, number)| {
        valid_repo_name(repo) && !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit())
    })
}
