//! Shared helpers for the rule tables: a daemon core without sockets or a
//! database, plus short builders for ingested values.
#![allow(dead_code)]

use serde_json::Value;
use shiibar_gh_proto::*;
use shiibar_ghd::clock::Now;
use shiibar_ghd::engine::{CmdError, Engine};
use shiibar_ghd::model::RowRec;
use std::collections::BTreeMap;

pub const T0: i64 = 1_800_000_000;
pub const DAY: i64 = 86_400;
pub const HOUR: i64 = 3_600;
pub const ORG: &str = "org";
pub const ME: &str = "me";

/// An open PR in the `org` scope, authored by the viewer, updated at `T0`.
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
        base: "main".into(),
        head: "topic".into(),
        state: PrState::Open,
        is_draft: false,
        review: Review::None,
        checks: Checks::None,
        base_status: BaseStatus::None,
        mergeable: false,
        failed_check: None,
        changes_requested_by: None,
        updated_at: T0,
        is_private: false,
        requested_me: false,
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

pub fn ids(rows: &[Row]) -> Vec<String> {
    rows.iter().map(|r| r.id.clone()).collect()
}

pub fn class(row: &Row) -> RowClass {
    match row.class {
        Lenient::Known(c) => c,
        Lenient::Unknown(_) => panic!("unknown class"),
    }
}

pub fn show_snoozed() -> Filter {
    Filter {
        snoozed: true,
        ..Filter::default()
    }
}

/// A core at a fixed time, with the `org` scope registered at `T0`.
pub struct H {
    pub engine: Engine,
    pub now: Now,
}

impl H {
    /// Ten seconds after a watch that started at `T0`.
    pub fn new() -> Self {
        let now = Now::fixed(T0, "Asia/Tokyo").unwrap();
        let mut engine = Engine::fresh(&now);
        engine.scope_add(ORG, &now).unwrap();
        let mut h = Self { engine, now };
        h.advance(10);
        h
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

    pub fn ev(&self, id: &str, pr_id: &str, kind: EventKind) -> IngestEvent {
        self.ev_at(id, pr_id, kind, self.now.at)
    }

    pub fn ev_at(&self, id: &str, pr_id: &str, kind: EventKind, at: i64) -> IngestEvent {
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

    /// Apply one ingest, then move the clock on one second.
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
        let ingest = Ingest {
            viewer: ME.into(),
            missing_pr_ids: vec![],
            prs,
            events,
            reactions,
        };
        let result = self.engine.ingest(ingest, &self.now);
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
            viewer: ME.into(),
            missing_pr_ids: vec![id.into()],
            prs: vec![],
            events: vec![],
            reactions: vec![],
        };
        self.engine.ingest(ingest, &self.now).unwrap();
    }

    pub fn row(&self, id: &str) -> &RowRec {
        self.engine
            .row_record(id)
            .unwrap_or_else(|| panic!("no row {id}"))
    }

    pub fn has_row(&self, id: &str) -> bool {
        self.engine.row_record(id).is_some()
    }

    pub fn wire_row(&self, id: &str) -> Option<Row> {
        self.engine
            .activity(&show_snoozed(), &self.now)
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
    }

    pub fn card(&self, pr_key: &str) -> Option<Card> {
        self.cards(&show_snoozed())
            .into_iter()
            .find(|c| c.pr == pr_key)
    }

    pub fn cards(&self, filter: &Filter) -> Vec<Card> {
        self.engine.list(filter, &self.now).unwrap()
    }

    pub fn card_ids(&self, filter: &Filter) -> Vec<String> {
        self.cards(filter).into_iter().map(|c| c.id).collect()
    }

    pub fn visible(&self, id: &str) -> bool {
        self.card_ids(&Filter::default()).iter().any(|c| c == id)
    }

    pub fn scope(&self, id: &str) -> Scope {
        self.engine
            .scopes()
            .into_iter()
            .find(|s| s.id == id)
            .unwrap_or_else(|| panic!("no scope {id}"))
    }

    pub fn badge(&self) -> u32 {
        self.scope(ORG).badge
    }

    pub fn dot(&self) -> bool {
        self.scope(ORG).dot
    }

    pub fn set(&mut self, key: &str, value: Value) {
        self.engine.config_set(key, &value, &self.now).unwrap();
    }

    pub fn snooze(&mut self, key: &str) {
        self.engine.snooze(key, &self.now).unwrap();
    }

    pub fn unsnooze(&mut self, key: &str) {
        self.engine.unsnooze(key, &self.now).unwrap();
    }

    pub fn seen(&mut self, rows: &[&str]) {
        let rows: Vec<String> = rows.iter().map(|r| r.to_string()).collect();
        self.engine.seen(&rows);
    }

    pub fn close(&mut self) {
        self.engine.popover_closed(ORG).unwrap();
    }

    pub fn open(&mut self) {
        self.engine.popover_opened(ORG).unwrap();
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
