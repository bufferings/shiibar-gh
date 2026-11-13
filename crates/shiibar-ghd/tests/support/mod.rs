//! Shared helpers for the rule tables: a daemon core without sockets or a
//! database, plus short builders for ingested values.
//!
//! The core keys PRs and rows by `<account id>:<node id>`. The helpers take
//! and give the short node ids of the default account, so the tables read
//! like the events they feed.
#![allow(dead_code)]

use serde_json::Value;
use shiibar_gh_proto::*;
use shiibar_ghd::clock::Now;
use shiibar_ghd::engine::{ActivityArgs, CmdError, Engine, ListArgs, PlaceArgs};
use shiibar_ghd::model::{OwnerKind as Kind, RowRec};
use std::collections::BTreeMap;

pub const T0: i64 = 1_800_000_000;
pub const DAY: i64 = 86_400;
pub const HOUR: i64 = 3_600;
pub const ORG: &str = "org";
pub const ME: &str = "me";
/// The account id of `me`.
pub const ACCOUNT: &str = "1001";
/// A second account, for the tables about two accounts.
pub const OTHER: &str = "1002";
pub const YOU: &str = "you";

/// The full key of a node of the default account. A key that starts with a
/// numeric account id is already full.
pub fn full(id: &str) -> String {
    let full = id.split_once(':').is_some_and(|(account, _)| {
        !account.is_empty() && account.bytes().all(|b| b.is_ascii_digit())
    });
    if full {
        id.to_string()
    } else {
        format!("{ACCOUNT}:{id}")
    }
}

/// The short id of a key of the default account.
pub fn short(id: &str) -> String {
    id.strip_prefix(&format!("{ACCOUNT}:"))
        .unwrap_or(id)
        .to_string()
}

/// An open PR in the `org` owner, authored by the viewer, updated at `T0`.
pub fn pr(id: &str) -> IngestPr {
    let number = id.rsplit('_').next().unwrap().parse().unwrap_or(1);
    IngestPr {
        id: id.into(),
        owner: ORG.into(),
        repo: "app".into(),
        number,
        url: format!("https://github.example/{id}"),
        title: format!("Title {id}"),
        author: ME.into(),
        author_avatar_url: None,
        base: "main".into(),
        head: "topic".into(),
        head_oid: None,
        state: PrState::Open,
        is_draft: false,
        review: Review::None,
        checks: Checks::None,
        base_status: BaseStatus::None,
        mergeable: false,
        failed_check: None,
        changes_requested_by: None,
        updated_at: T0,
        created_at: T0 - DAY,
        my_review_at: None,
        is_private: false,
        requested_me: false,
        requested_team: false,
        assignees: vec![],
        links: Links {
            review: format!("https://github.example/{id}/r"),
            checks: format!("https://github.example/{id}/c"),
            base: format!("https://github.example/{id}/b"),
        },
    }
}

pub fn other(id: &str) -> IngestPr {
    IngestPr {
        author: "alice".into(),
        ..pr(id)
    }
}

/// Short ids of rows.
pub fn ids(rows: &[Row]) -> Vec<String> {
    rows.iter().map(|r| short(&r.id)).collect()
}

/// A core at a fixed time, with the account `me`, its `org` owner and its
/// Public registered at `T0`.
pub struct H {
    pub engine: Engine,
    pub now: Now,
}

impl Default for H {
    fn default() -> Self {
        Self::new()
    }
}

impl H {
    /// Ten seconds after a watch that started at `T0`.
    pub fn new() -> Self {
        let now = Now::fixed(T0, "Asia/Tokyo").unwrap();
        let mut engine = Engine::fresh(&now);
        engine.account_create(ACCOUNT, ME).unwrap();
        engine.token_saved(ACCOUNT);
        engine
            .owner_add(ACCOUNT, ORG, Kind::Org, Some(100), &now)
            .unwrap();
        engine
            .owner_add(ACCOUNT, "public", Kind::Public, None, &now)
            .unwrap();
        let mut h = Self { engine, now };
        h.advance(10);
        h
    }

    /// A second account `you` with its own `org` owner, registered now.
    pub fn add_other(&mut self) {
        self.engine.account_create(OTHER, YOU).unwrap();
        self.engine.token_saved(OTHER);
        self.engine
            .owner_add(OTHER, ORG, Kind::Org, Some(100), &self.now)
            .unwrap();
    }

    pub fn at(&self) -> i64 {
        self.now.at
    }

    pub fn advance(&mut self, secs: i64) {
        self.now.at += secs;
    }

    pub fn set_time(&mut self, at: i64) {
        self.now.at = at;
    }

    pub fn ev(&self, id: &str, pr_id: &str, kind: IngestKind) -> IngestEvent {
        self.ev_at(id, pr_id, kind, self.now.at)
    }

    pub fn ev_at(&self, id: &str, pr_id: &str, kind: IngestKind, at: i64) -> IngestEvent {
        IngestEvent {
            id: id.into(),
            pr_id: pr_id.into(),
            kind,
            occurred_at: at,
            url: format!("https://github.example/{id}"),
            actor: Some("alice".into()),
            text: Some(format!("text {id}")),
            comment_id: None,
        }
    }

    pub fn reaction(&self, comment: &str, pr_id: &str, counts: &[(&str, u32)]) -> IngestReaction {
        IngestReaction {
            comment_id: comment.into(),
            pr_id: pr_id.into(),
            url: format!("https://github.example/{comment}"),
            text: format!("comment {comment}"),
            comment_created_at: self.now.at,
            counts: counts
                .iter()
                .map(|(k, v)| (k.to_string(), *v))
                .collect::<BTreeMap<_, _>>(),
            watching: true,
        }
    }

    /// Apply one ingest to `me`, then move the clock on one second.
    pub fn push(
        &mut self,
        prs: Vec<IngestPr>,
        events: Vec<IngestEvent>,
        reactions: Vec<IngestReaction>,
    ) {
        self.try_push(prs, events, reactions).unwrap();
    }

    pub fn try_push(
        &mut self,
        prs: Vec<IngestPr>,
        events: Vec<IngestEvent>,
        reactions: Vec<IngestReaction>,
    ) -> Result<(), CmdError> {
        self.push_to(ACCOUNT, prs, events, reactions)
    }

    /// Apply one ingest to an account, then move the clock on one second.
    pub fn push_to(
        &mut self,
        account: &str,
        prs: Vec<IngestPr>,
        events: Vec<IngestEvent>,
        reactions: Vec<IngestReaction>,
    ) -> Result<(), CmdError> {
        let ingest = Ingest {
            prs,
            events,
            reactions,
            ..Ingest::default()
        };
        let result = self.engine.ingest(account, ingest, &self.now);
        self.advance(1);
        result
    }

    pub fn prs(&mut self, prs: Vec<IngestPr>) {
        self.push(prs, vec![], vec![]);
    }

    pub fn events(&mut self, events: Vec<IngestEvent>) {
        self.push(vec![], events, vec![]);
    }

    pub fn missing(&mut self, id: &str) {
        let ingest = Ingest {
            missing_pr_ids: vec![id.into()],
            ..Ingest::default()
        };
        self.engine.ingest(ACCOUNT, ingest, &self.now).unwrap();
    }

    pub fn row(&self, id: &str) -> &RowRec {
        self.engine
            .row_record(&full(id))
            .unwrap_or_else(|| panic!("no row {id}"))
    }

    /// Whether a PR of the default account is dismissed.
    pub fn dismissed(&self, id: &str) -> bool {
        self.engine
            .pr_record(&full(id))
            .is_some_and(|pr| pr.dismissed_at.is_some())
    }

    pub fn has_row(&self, id: &str) -> bool {
        self.engine.row_record(&full(id)).is_some()
    }

    /// Every row the lists show, dismissed PRs included.
    pub fn all_rows(&self) -> Vec<Row> {
        self.all_cards().into_iter().flat_map(|c| c.rows).collect()
    }

    pub fn wire_row(&self, id: &str) -> Option<Row> {
        let id = full(id);
        self.all_rows().into_iter().find(|r| r.id == id)
    }

    /// The card of a PR, dismissed or not.
    pub fn card(&self, pr_key: &str) -> Option<Card> {
        self.all_cards().into_iter().find(|c| c.pr == pr_key)
    }

    /// What `list` answers.
    pub fn list(&self, args: ListArgs) -> Vec<Card> {
        self.engine.list(&args, &self.now).unwrap()
    }

    /// The All tab.
    pub fn cards(&self) -> Vec<Card> {
        self.list(ListArgs::default())
    }

    /// The Dismissed list.
    pub fn dismissed_cards(&self) -> Vec<Card> {
        self.list(ListArgs {
            dismissed: DismissedFilter::Only,
            ..ListArgs::default()
        })
    }

    /// Short ids of a tab's cards, in order.
    pub fn tab(&self, tab: Tab) -> Vec<String> {
        self.card_ids(ListArgs {
            tab,
            ..ListArgs::default()
        })
    }

    /// Short ids of the cards of one section, in order.
    pub fn section(&self, tab: Tab, section: Section) -> Vec<String> {
        self.list(ListArgs {
            tab,
            ..ListArgs::default()
        })
        .into_iter()
        .filter(|c| c.placement.as_ref().is_some_and(|p| p.section.is(section)))
        .map(|c| short(&c.id))
        .collect()
    }

    /// The placement of a PR's card: tab, section and position.
    pub fn placement(&self, id: &str) -> Option<(String, String, u32)> {
        let card = self.card_by_id(id)?;
        card.placement
            .map(|p| (p.tab.as_text(), p.section.as_text(), p.position))
    }

    /// Every card, the dismissed ones included.
    pub fn all_cards(&self) -> Vec<Card> {
        self.list(ListArgs {
            dismissed: DismissedFilter::Include,
            ..ListArgs::default()
        })
    }

    /// The card of a short PR id, dismissed or not.
    pub fn card_by_id(&self, id: &str) -> Option<Card> {
        let id = full(id);
        self.all_cards().into_iter().find(|c| c.id == id)
    }

    /// Short ids of the cards a list gives.
    pub fn card_ids(&self, args: ListArgs) -> Vec<String> {
        self.list(args).into_iter().map(|c| short(&c.id)).collect()
    }

    /// The card shows in an owner section.
    pub fn visible(&self, id: &str) -> bool {
        self.card_ids(ListArgs::default()).iter().any(|c| c == id)
    }

    /// Short ids of the cards awaiting review, in the owner sections.
    pub fn awaiting_ids(&self) -> Vec<String> {
        self.cards()
            .into_iter()
            .filter(|c| c.awaiting_review)
            .map(|c| short(&c.id))
            .collect()
    }

    pub fn activity(&self, args: ActivityArgs) -> Vec<Row> {
        self.engine.activity(&args, &self.now).unwrap()
    }

    pub fn account(&self) -> Account {
        self.account_of(ACCOUNT)
    }

    pub fn account_of(&self, id: &str) -> Account {
        self.engine
            .account_value(id)
            .unwrap_or_else(|| panic!("no account {id}"))
    }

    pub fn owner(&self, name: &str) -> Owner {
        self.account()
            .owners
            .into_iter()
            .find(|o| o.name.eq_ignore_ascii_case(name))
            .unwrap_or_else(|| panic!("no owner {name}"))
    }

    pub fn owner_id(&self, name: &str) -> String {
        self.engine.owner_id(ACCOUNT, name).unwrap()
    }

    /// The blue dot of the account.
    pub fn dot(&self) -> bool {
        self.account().unread
    }

    pub fn set(&mut self, key: &str, value: Value) {
        self.engine.config_set(key, &value, &self.now).unwrap();
    }

    /// Change one cell of `org`'s event table.
    pub fn table(&mut self, event: EventKind, column: EventColumn, on: bool) {
        let owner = self.owner_id(ORG);
        self.engine
            .owner_events_set(&owner, event, column, on, &self.now)
            .unwrap();
    }

    pub fn mute(&mut self, kind: MuteKind, name: &str) {
        self.engine.mute(ME, kind, name).unwrap();
    }

    pub fn unmute(&mut self, kind: MuteKind, name: &str) {
        self.engine.unmute(ME, kind, name).unwrap();
    }

    /// `dismiss` of a PR by its `<pr>` key.
    pub fn dismiss(&mut self, key: &str) -> Result<Card, CmdError> {
        let now = self.now.clone();
        self.engine.dismiss(ME, key, &now)
    }

    pub fn restore(&mut self, key: &str) -> Result<Card, CmdError> {
        self.engine.set_clock(&self.now.clone());
        self.engine.restore_pr(ME, key)
    }

    /// `place` of a PR by its `<pr>` key.
    pub fn place(
        &mut self,
        key: &str,
        tab: PlaceTab,
        section: Option<Section>,
        before: Option<&str>,
        at: Option<At>,
    ) -> Result<Card, CmdError> {
        self.engine.set_clock(&self.now.clone());
        self.engine.place(
            ME,
            key,
            &PlaceArgs {
                tab,
                section,
                before: before.map(str::to_string),
                at,
            },
        )
    }

    /// `read`: the rows were selected or opened.
    pub fn read(&mut self, rows: &[&str]) {
        let rows: Vec<String> = rows.iter().map(|r| full(r)).collect();
        self.engine.read(&rows).unwrap();
    }

    pub fn read_all(&mut self) {
        self.engine.read_all(ME).unwrap();
    }

    pub fn close(&mut self) {
        self.engine.set_clock(&self.now.clone());
        self.engine.popover_closed(ME).unwrap();
    }

    pub fn open(&mut self) {
        self.engine.popover_opened(ME).unwrap();
    }

    pub fn tick(&mut self) {
        self.engine.tick(&self.now);
    }

    /// What a connected app receives now; every notification is written.
    pub fn delivered(&mut self) -> Vec<Notification> {
        let out = self.engine.take_notifications(true, &self.now);
        for n in &out {
            self.engine.mark_delivered(&n.rows);
        }
        out
    }

    /// Nothing is connected: new notifications stay undelivered.
    pub fn offline(&mut self) {
        assert!(self.engine.take_notifications(false, &self.now).is_empty());
    }

    /// The app reconnects: the summaries it gets, marked as written.
    pub fn reconnect(&mut self) -> Vec<Notification> {
        let out = self.engine.pending_summaries(&self.now);
        for n in &out {
            self.engine.mark_delivered(&n.rows);
        }
        out
    }
}

/// The key `list` and `status` use for a default PR.
pub fn key(id: &str) -> String {
    let number = id.rsplit('_').next().unwrap();
    format!("{ORG}/app#{number}")
}

pub fn not_found<T: std::fmt::Debug>(result: Result<T, CmdError>) -> bool {
    matches!(result, Err(CmdError::NotFound(_)))
}

pub fn invalid<T: std::fmt::Debug>(result: Result<T, CmdError>) -> bool {
    matches!(result, Err(CmdError::Invalid(_)))
}
