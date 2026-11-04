//! Joins the engine, the store and the subscribers. Rule of this file: a change
//! is saved first, and only then does anything leave for a client.

use crate::clock::{Clock, Now};
use crate::engine::{CmdError, Engine};
use crate::keychain::Keychain;
use crate::logging;
use crate::model::TestRec;
use crate::plan::{Outcome, Plan, TokenObs};
use crate::store::{self, OpenOutcome, SaveError, Store};
use shiibar_gh_proto as proto;
use shiibar_gh_proto::paths::StateDir;
use shiibar_gh_proto::{ClientKind, Request, SubscribeEvent, codec};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};

/// A subscriber with more than this many queued events is disconnected.
pub const SEND_QUEUE: usize = 256;

const UNREADABLE: &str = "couldn't read saved state; run `shiibar-gh reset`";

/// One queued line. `ack` names the notification whose delivery a successful
/// write confirms.
#[derive(Debug)]
pub struct Outgoing {
    pub line: String,
    pub ack: Option<String>,
}

struct Subscriber {
    client: ClientKind,
    tx: mpsc::Sender<Outgoing>,
    /// Dropping this ends the connection task.
    kill: Option<oneshot::Sender<()>>,
}

impl Subscriber {
    fn alive(&self) -> bool {
        self.kill.is_some()
    }
}

/// A notification queued for the app and not confirmed yet.
struct Flight {
    rows: Vec<String>,
    connections: BTreeSet<u64>,
}

pub struct Subscribed {
    pub id: u64,
    pub rx: mpsc::Receiver<Outgoing>,
    pub kill: oneshot::Receiver<()>,
}

type Digest = BTreeMap<String, (proto::Scope, Vec<proto::Card>)>;

pub struct Daemon {
    engine: Engine,
    /// `None` while the database is unreadable.
    store: Option<Store>,
    dir: StateDir,
    clock: Clock,
    started_at: i64,
    subscribers: HashMap<u64, Subscriber>,
    next_subscriber: u64,
    flights: HashMap<String, Flight>,
    digest: Digest,
    keychain: Arc<dyn Keychain>,
    /// Tokens read from the Keychain, by account. A Keychain read may ask
    /// the user, so each token is read once.
    tokens: HashMap<String, String>,
}

fn error_line(error: &CmdError) -> String {
    let (code, message) = match error {
        CmdError::NotFound(m) => (proto::ErrorCode::NotFound, m),
        CmdError::Invalid(m) => (proto::ErrorCode::Invalid, m),
        CmdError::Internal(m) => (proto::ErrorCode::Internal, m),
    };
    line(&proto::ErrorResponse::new(code, message.clone()))
}

fn line<T: serde::Serialize>(value: &T) -> String {
    codec::encode_line(value).unwrap_or_else(|_| {
        "{\"ok\":false,\"code\":\"internal\",\"error\":\"cannot encode the response\"}\n".into()
    })
}

/// The line answering a request that could not be decoded.
pub fn invalid_line(message: impl std::fmt::Display) -> String {
    error_line(&CmdError::Invalid(format!("invalid request: {message}")))
}

impl Daemon {
    /// Open the database and run the first periodic pass. An `Err` means the
    /// daemon must exit; an unreadable database is a running state instead.
    pub fn start(dir: StateDir, clock: Clock, keychain: Arc<dyn Keychain>) -> anyhow::Result<Self> {
        let now = clock.now();
        let (mut engine, store) = match Store::open(&dir.db())? {
            OpenOutcome::Ready(store, Some(data)) => (Engine::restore(*data), Some(store)),
            OpenOutcome::Ready(store, None) => (Engine::fresh(&now), Some(store)),
            OpenOutcome::Corrupt => {
                logging::error(format_args!("{UNREADABLE}"));
                (blank_engine(&now, keychain.as_ref()), None)
            }
        };
        engine.set_clock(&now);
        let digest = engine.digest(&now);
        let mut daemon = Self {
            engine,
            store,
            dir,
            clock,
            started_at: now.at,
            subscribers: HashMap::new(),
            next_subscriber: 0,
            flights: HashMap::new(),
            digest,
            keychain,
            tokens: HashMap::new(),
        };
        if daemon.store.is_some() {
            daemon.engine.tick(&now);
            daemon
                .commit(&now, true)
                .map_err(|e| anyhow::anyhow!("cannot save the state: {e:?}"))?;
        }
        Ok(daemon)
    }

    /// Answer one request. `subscribe` and `shutdown` are the server's.
    pub fn handle(&mut self, request: Request) -> String {
        let result = match request {
            Request::Info => Ok(line(&proto::InfoResponse {
                ok: true,
                version: env!("CARGO_PKG_VERSION").to_string(),
                started_at: self.started_at,
            })),
            Request::Reset => self.reset(),
            Request::Subscribe { .. } | Request::Shutdown => {
                Err(CmdError::Internal("handled by the server".into()))
            }
            other => self.run(other),
        };
        result.unwrap_or_else(|e| error_line(&e))
    }

    fn run(&mut self, request: Request) -> Result<String, CmdError> {
        self.check_db()?;
        let now = self.clock.now();
        self.engine.set_clock(&now);
        let result = self.apply(request, &now);
        self.commit(&now, false)?;
        result
    }

    fn apply(&mut self, request: Request, now: &Now) -> Result<String, CmdError> {
        let ack = || line(&proto::AckResponse::new());
        let engine = &mut self.engine;
        Ok(match request {
            Request::List { filter } => line(&proto::ListResponse {
                ok: true,
                cards: engine.list(&filter, now)?,
            }),
            Request::Activity { filter } => line(&proto::ActivityResponse {
                ok: true,
                rows: engine.activity(&filter, now)?,
            }),
            Request::Status { pr } => line(&proto::StatusResponse {
                ok: true,
                card: engine.status(&pr, now)?,
            }),
            Request::Seen { row_ids } => {
                engine.seen(&row_ids);
                ack()
            }
            Request::PopoverOpened { scope } => {
                engine.popover_opened(&scope)?;
                ack()
            }
            Request::PopoverClosed { scope } => {
                engine.popover_closed(&scope)?;
                ack()
            }
            Request::Done { row } => {
                engine.done(&row)?;
                ack()
            }
            Request::Undone { row } => {
                engine.undone(&row)?;
                ack()
            }
            Request::Snooze { pr } => {
                engine.snooze(&pr, now)?;
                ack()
            }
            Request::Unsnooze { pr } => {
                engine.unsnooze(&pr, now)?;
                ack()
            }
            Request::Refresh { scope } => {
                // The server fetches and answers; this path only checks.
                let scope = scope.map(|s| engine.require_scope(&s)).transpose()?;
                line(&proto::RefreshResponse {
                    ok: true,
                    warnings: engine.refresh_warnings(scope.as_deref()),
                })
            }
            Request::Open { pr, row } => {
                let url = match (pr, row) {
                    (Some(pr), None) => engine.open_pr(&pr)?,
                    (None, Some(row)) => engine.open_row(&row)?,
                    _ => {
                        return Err(CmdError::Invalid("open takes either pr or row".into()));
                    }
                };
                line(&proto::OpenResponse { ok: true, url })
            }
            Request::ConfigGet { key } => line(&proto::ConfigResponse {
                ok: true,
                value: engine.config_get(&key)?,
            }),
            Request::ConfigSet { key, value } => line(&proto::ConfigResponse {
                ok: true,
                value: engine.config_set(&key, &value, now)?,
            }),
            Request::ScopeList => line(&proto::ScopesResponse {
                ok: true,
                scopes: engine.scopes(),
            }),
            Request::ScopeAdd { owner } => {
                engine.scope_add(&owner, now)?;
                line(&proto::ScopesResponse {
                    ok: true,
                    scopes: engine.scopes(),
                })
            }
            Request::ScopeRemove { owner } => {
                // The Keychain entry goes first: a failure leaves the scope.
                if let Some(account) = engine.scope_token_account(&owner)? {
                    self.keychain
                        .delete(&account)
                        .map_err(|e| CmdError::Internal(e.to_string()))?;
                    self.tokens.remove(&account);
                }
                let engine = &mut self.engine;
                if engine.scope_remove(&owner)?.is_some() {
                    engine.token_removed(&owner);
                }
                let response = line(&proto::ScopesResponse {
                    ok: true,
                    scopes: engine.scopes(),
                });
                self.save_now()?;
                self.disconnect_all();
                response
            }
            Request::ScopeEnable { scope } => {
                engine.scope_enable(&scope, now)?;
                ack()
            }
            Request::ScopeDisable { scope } => {
                engine.scope_disable(&scope)?;
                ack()
            }
            Request::ScopeNotify { scope, on } => {
                engine.scope_notify(&scope, on)?;
                ack()
            }
            Request::TokenSet { target, token } => {
                let token = token.trim();
                if token.is_empty() {
                    return Err(CmdError::Invalid("the token is empty".into()));
                }
                let key = engine.token_key(&target)?;
                let account = crate::model::scope_account(&key);
                self.keychain
                    .set(&account, token)
                    .map_err(|e| CmdError::Internal(e.to_string()))?;
                self.tokens.insert(account, token.to_string());
                self.engine.token_saved(&key);
                ack()
            }
            Request::SettingsStatus => {
                let (api_usage, tokens) = engine.settings_status();
                line(&proto::SettingsStatusResponse {
                    ok: true,
                    api_usage,
                    tokens,
                })
            }
            #[cfg(feature = "dev-ingest")]
            Request::DevIngest { ingest } => {
                engine.ingest(ingest, now)?;
                ack()
            }
            #[cfg(feature = "dev-ingest")]
            Request::DevClockSet { now: at, tz } => {
                let fixed = Now::fixed(at, &tz).map_err(CmdError::Invalid)?;
                self.clock.fix(fixed.clone());
                self.engine.tick(&fixed);
                self.commit(&fixed, true)?;
                ack()
            }
            Request::Subscribe { .. }
            | Request::Reset
            | Request::Info
            | Request::Shutdown
            | Request::TokenTest { .. } => {
                return Err(CmdError::Internal("handled elsewhere".into()));
            }
        })
    }

    /// Before any command: `internal` while unreadable, and a file damaged
    /// since the last command moves the daemon to the unreadable state.
    fn check_db(&mut self) -> Result<(), CmdError> {
        match &self.store {
            None => Err(CmdError::Internal(UNREADABLE.into())),
            Some(store) if store.check() => Ok(()),
            Some(_) => {
                self.enter_unreadable();
                Err(CmdError::Internal(UNREADABLE.into()))
            }
        }
    }

    fn enter_unreadable(&mut self) {
        logging::error(format_args!("{UNREADABLE}"));
        if let Some(store) = self.store.take() {
            store.abandon();
        }
        let now = self.clock.now();
        self.engine = blank_engine(&now, self.keychain.as_ref());
        self.digest = self.engine.digest(&now);
        self.flights.clear();
        self.disconnect_all();
    }

    fn save_now(&mut self) -> Result<(), CmdError> {
        let Some(store) = &mut self.store else {
            return Err(CmdError::Internal(UNREADABLE.into()));
        };
        if self.engine.dirty().is_empty() {
            return Ok(());
        }
        match store.save(self.engine.data(), self.engine.dirty()) {
            Ok(()) => {
                self.engine.clear_dirty();
                Ok(())
            }
            Err(SaveError::Corrupt) => {
                self.enter_unreadable();
                Err(CmdError::Internal(UNREADABLE.into()))
            }
            Err(SaveError::Other(e)) => {
                logging::error(format_args!("cannot save the state: {e}"));
                Err(CmdError::Internal(format!("cannot save the state: {e}")))
            }
        }
    }

    /// Save, then tell the subscribers what changed. `force` also compares
    /// when nothing was written, for changes that come from time passing.
    fn commit(&mut self, now: &Now, force: bool) -> Result<(), CmdError> {
        let app = self.app_connected();
        let notifications = self.engine.take_notifications(app, now);
        let changed = force || !self.engine.dirty().is_empty();
        if let Err(e) = self.save_now() {
            for notification in &notifications {
                self.engine.delivery_failed(&notification.rows);
            }
            return Err(e);
        }
        if changed {
            self.publish_scopes(now);
        }
        self.send_notifications(notifications, None);
        Ok(())
    }

    fn publish_scopes(&mut self, now: &Now) {
        self.engine.set_clock(now);
        let digest = self.engine.digest(now);
        let changed: Vec<proto::Scope> = digest
            .iter()
            .filter(|(id, value)| self.digest.get(*id) != Some(value))
            .map(|(_, (scope, _))| scope.clone())
            .collect();
        self.digest = digest;
        for scope in changed {
            let text = line(&SubscribeEvent::ScopeChanged { scope });
            let ids: Vec<u64> = self.subscribers.keys().copied().collect();
            for id in ids {
                self.enqueue(id, text.clone(), None);
            }
        }
    }

    fn app_connected(&self) -> bool {
        self.subscribers
            .values()
            .any(|s| s.alive() && s.client == ClientKind::App)
    }

    fn app_ids(&self) -> BTreeSet<u64> {
        self.subscribers
            .iter()
            .filter(|(_, s)| s.alive() && s.client == ClientKind::App)
            .map(|(id, _)| *id)
            .collect()
    }

    /// Queue a line. A full queue is a slow client, which is disconnected and
    /// recovers through reconnecting.
    fn enqueue(&mut self, id: u64, line: String, ack: Option<String>) {
        let Some(subscriber) = self.subscribers.get_mut(&id) else {
            return;
        };
        if !subscriber.alive() {
            return;
        }
        if subscriber.tx.try_send(Outgoing { line, ack }).is_err() {
            logging::info(format_args!("disconnecting slow subscriber {id}"));
            subscriber.kill = None;
        }
    }

    /// Notifications go to every subscriber; only a write to an `app`
    /// connection counts as delivery. `only` limits the app side to one.
    fn send_notifications(&mut self, notifications: Vec<proto::Notification>, only: Option<u64>) {
        for notification in notifications {
            let event = SubscribeEvent::Notify {
                notification: notification.clone(),
            };
            let text = line(&event);
            let apps = match only {
                Some(id) => BTreeSet::from([id]),
                None => self.app_ids(),
            };
            self.flights.insert(
                notification.id.clone(),
                Flight {
                    rows: notification.rows,
                    connections: apps.clone(),
                },
            );
            for id in &apps {
                self.enqueue(*id, text.clone(), Some(notification.id.clone()));
            }
            let others: Vec<u64> = self
                .subscribers
                .iter()
                .filter(|(_, s)| s.client == ClientKind::Cli)
                .map(|(id, _)| *id)
                .collect();
            for id in others {
                self.enqueue(id, text.clone(), None);
            }
        }
    }

    pub fn subscribe(&mut self, client: ClientKind) -> Subscribed {
        // The snapshot has to tell the truth about the file on disk.
        let _ = self.check_db();
        let now = self.clock.now();
        self.engine.set_clock(&now);
        let (tx, rx) = mpsc::channel(SEND_QUEUE);
        let (kill_tx, kill) = oneshot::channel();
        let id = self.next_subscriber;
        self.next_subscriber += 1;
        self.subscribers.insert(
            id,
            Subscriber {
                client,
                tx,
                kill: Some(kill_tx),
            },
        );
        let snapshot = SubscribeEvent::Snapshot {
            scopes: self.engine.scopes(),
            db_unreadable: self.store.is_none(),
        };
        self.enqueue(id, line(&snapshot), None);
        if client == ClientKind::App && self.store.is_some() {
            self.send_summaries(id, &now);
        }
        Subscribed { id, rx, kill }
    }

    fn send_summaries(&mut self, app: u64, now: &Now) {
        let summaries = self.engine.pending_summaries(now);
        match self.save_now() {
            Ok(()) => self.send_notifications(summaries, Some(app)),
            Err(_) => {
                for summary in &summaries {
                    self.engine.delivery_failed(&summary.rows);
                }
            }
        }
    }

    /// A write of this notification to an app connection succeeded.
    pub fn delivered(&mut self, notification: &str) {
        let Some(flight) = self.flights.remove(notification) else {
            return;
        };
        // Nothing is written to a file that was damaged in the meantime.
        if self.check_db().is_err() {
            return;
        }
        self.engine.mark_delivered(&flight.rows);
        if let Err(e) = self.save_now() {
            logging::error(format_args!("cannot record a delivery: {e:?}"));
        }
    }

    /// The connection task of this subscriber ended.
    pub fn connection_closed(&mut self, id: u64) {
        let Some(subscriber) = self.subscribers.remove(&id) else {
            return;
        };
        if subscriber.client != ClientKind::App {
            return;
        }
        let mut failed = Vec::new();
        self.flights.retain(|_, flight| {
            flight.connections.remove(&id);
            let keep = !flight.connections.is_empty();
            if !keep {
                failed.append(&mut flight.rows);
            }
            keep
        });
        self.engine.delivery_failed(&failed);
        match self.app_ids().first().copied() {
            None => self.engine.app_disconnected(),
            Some(other) if self.check_db().is_ok() => {
                let now = self.clock.now();
                self.send_summaries(other, &now);
            }
            Some(_) => {}
        }
    }

    pub fn disconnect_all(&mut self) {
        for subscriber in self.subscribers.values_mut() {
            subscriber.kill = None;
        }
    }

    /// The periodic pass.
    pub fn tick(&mut self) {
        if self.check_db().is_err() {
            return;
        }
        let now = self.clock.now();
        self.engine.tick(&now);
        if let Err(e) = self.commit(&now, true) {
            logging::error(format_args!("periodic pass failed: {e:?}"));
        }
    }

    /// DESIGN.md, "When the database cannot be read".
    fn reset(&mut self) -> Result<String, CmdError> {
        if self.store.is_some() && self.check_db().is_ok() {
            return Err(CmdError::Invalid(
                "saved state is readable; nothing to reset".into(),
            ));
        }
        let now = self.clock.now();
        let path = self.dir.db();
        let internal = |e: String| CmdError::Internal(format!("cannot reset: {e}"));
        store::retire(&path, now.at).map_err(|e| internal(e.to_string()))?;
        let store = match Store::open(&path).map_err(|e| internal(e.to_string()))? {
            OpenOutcome::Ready(store, _) => store,
            OpenOutcome::Corrupt => return Err(internal("the new database is damaged".into())),
        };
        self.store = Some(store);
        self.engine = Engine::fresh_from_accounts(&now, &accounts(self.keychain.as_ref()));
        self.tokens.clear();
        self.save_now()?;
        self.digest = self.engine.digest(&now);
        self.disconnect_all();
        logging::info(format_args!("saved state reset"));
        Ok(line(&proto::AckResponse::new()))
    }
}

/// What the unreadable state shows: the content `reset` would give, with the
/// scopes the Keychain holds tokens for.
fn blank_engine(now: &Now, keychain: &dyn Keychain) -> Engine {
    let mut engine = Engine::fresh_from_accounts(now, &accounts(keychain));
    engine.clear_dirty();
    engine
}

/// The Keychain accounts, or none when the Keychain cannot be listed.
fn accounts(keychain: &dyn Keychain) -> Vec<String> {
    keychain.accounts().unwrap_or_else(|e| {
        logging::error(format_args!("cannot list the saved tokens: {e}"));
        Vec::new()
    })
}

impl Daemon {
    /// A token from the cache, else from the Keychain.
    fn read_token(
        keychain: &dyn Keychain,
        cache: &mut HashMap<String, String>,
        account: &str,
    ) -> Option<String> {
        if let Some(token) = cache.get(account) {
            return Some(token.clone());
        }
        match keychain.get(account) {
            Ok(Some(token)) => {
                cache.insert(account.to_string(), token.clone());
                Some(token)
            }
            Ok(None) => None,
            Err(e) => {
                logging::error(format_args!("{e}"));
                None
            }
        }
    }

    pub fn now(&self) -> Now {
        self.clock.now()
    }

    pub fn clock_fixed(&self) -> bool {
        self.clock.is_fixed()
    }

    /// What a fetch run needs, or `None` when nothing is to be fetched: the
    /// database is unreadable, fetching is stopped, or nothing is due.
    pub fn fetch_plan(&mut self, forced: bool, only_scope: Option<String>) -> Option<Plan> {
        if self.check_db().is_err() {
            return None;
        }
        let now = self.clock.now();
        self.engine.set_clock(&now);
        if self.engine.stopped_until(now.at).is_some() {
            return None;
        }
        let due = self.engine.due(now.at, forced);
        if !due.any() {
            return None;
        }
        let keychain = self.keychain.clone();
        let cache = &mut self.tokens;
        let mut read = |account: &str| Self::read_token(keychain.as_ref(), cache, account);
        Some(
            self.engine
                .fetch_plan(&now, due, forced, only_scope, &mut read),
        )
    }

    /// Apply a run's outcome, save, then tell the subscribers.
    pub fn apply_fetch(&mut self, outcome: Outcome) {
        if self.check_db().is_err() {
            return;
        }
        let now = self.clock.now();
        self.engine.apply_fetch(outcome, &now);
        if let Err(e) = self.commit(&now, true) {
            logging::error(format_args!("cannot save a fetch: {e:?}"));
        }
    }

    /// Check a `refresh` or `token_test` before the server runs it.
    pub fn precheck(&mut self, scope: Option<&str>) -> Result<Option<String>, String> {
        self.check_db().map_err(|e| error_line(&e))?;
        scope
            .map(|s| self.engine.require_scope(s))
            .transpose()
            .map_err(|e| error_line(&e))
    }

    /// The `refresh` answer once fetching is done.
    pub fn refresh_answer(&mut self, scope: Option<&str>) -> String {
        let now = self.clock.now();
        self.engine.set_clock(&now);
        line(&proto::RefreshResponse {
            ok: true,
            warnings: self.engine.refresh_warnings(scope),
        })
    }

    /// Whether every fetch is stopped now.
    pub fn stopped(&mut self) -> bool {
        let now = self.clock.now();
        self.engine.stopped_until(now.at).is_some()
    }

    /// What `token_test` needs: the record key, the token to test (given, or
    /// the saved one), whether it is the saved one, and the reference owner.
    pub fn test_target(
        &mut self,
        target: &str,
        given: Option<String>,
    ) -> Result<TestTarget, String> {
        self.check_db().map_err(|e| error_line(&e))?;
        let key = self.engine.token_key(target).map_err(|e| error_line(&e))?;
        let saved = given.is_none();
        let token = match given {
            Some(token) => Some(token),
            None if self.engine.token_record(&key).is_some() => {
                let account = crate::model::scope_account(&key);
                Self::read_token(self.keychain.as_ref(), &mut self.tokens, &account)
            }
            None => None,
        };
        let Some(token) = token.filter(|t| !t.trim().is_empty()) else {
            return Err(error_line(&CmdError::Invalid(format!(
                "no token for {target}: pipe one to the command or run `shiibar-gh token set {target}`"
            ))));
        };
        let owner = self
            .engine
            .scope_of_token(&key)
            .filter(|scope| scope != crate::model::PUBLIC)
            .map(|scope| {
                self.engine
                    .scopes()
                    .into_iter()
                    .find(|s| s.id == scope)
                    .map_or(scope, |s| s.name)
            });
        let fetch = self.engine.data().fetch.clone();
        let viewer = self.engine.viewer();
        // Public's Team membership is checked with the classic PAT.
        let team_token = if key == crate::model::PUBLIC
            && self
                .engine
                .token_record(crate::model::NOTIFICATIONS)
                .is_some()
        {
            Self::read_token(
                self.keychain.as_ref(),
                &mut self.tokens,
                crate::model::NOTIFICATIONS,
            )
        } else {
            None
        };
        // The reference owner, when unknown, is read with the classic PAT.
        let classic = match (&viewer, key.as_str()) {
            (None, k)
                if k != crate::model::NOTIFICATIONS
                    && self
                        .engine
                        .token_record(crate::model::NOTIFICATIONS)
                        .is_some() =>
            {
                Self::read_token(
                    self.keychain.as_ref(),
                    &mut self.tokens,
                    crate::model::NOTIFICATIONS,
                )
            }
            _ => None,
        };
        Ok(TestTarget {
            key,
            token: token.trim().to_string(),
            saved,
            owner,
            viewer,
            classic,
            team_token,
            now: self.clock.now().at,
            cost_cap: self.engine.data().config.graphql_cost_cap,
            costs: fetch.costs,
        })
    }

    /// Record what a test found and answer it.
    pub fn test_done(
        &mut self,
        target: &TestTarget,
        report: Result<crate::tokentest::Report, crate::github::CallError>,
        rec: crate::github::Recorder,
    ) -> String {
        let now = self.clock.now();
        // A limit the test ran into stops every fetch, like any fetch.
        let usage = Outcome {
            costs: rec.added.clone(),
            rest: rec.rest,
            graphql: rec.graphql,
            stop: rec.stop.clone(),
            ..Outcome::default()
        };
        let report = match report {
            Ok(report) => report,
            Err(e) => {
                if self.check_db().is_ok() {
                    self.engine.apply_fetch(usage, &now);
                    if let Err(e) = self.commit(&now, true) {
                        logging::error(format_args!("cannot save a token test: {e:?}"));
                    }
                }
                return test_failed(e);
            }
        };
        let mismatch = target.key != crate::model::NOTIFICATIONS
            && matches!((&report.owner, &target.viewer), (Some(o), Some(v)) if !o.eq_ignore_ascii_case(v));
        if self.check_db().is_ok() {
            if let Some(scope) = self.engine.scope_of_token(&target.key)
                && scope != crate::model::PUBLIC
            {
                self.engine
                    .scope_observed(&scope, report.kind, report.name.clone());
            }
            if let Some(viewer) = target.viewer.clone().filter(|_| target.classic.is_some()) {
                self.engine
                    .token_tested_owner(crate::model::NOTIFICATIONS, viewer);
            }
            if target.saved {
                let obs = rec.tokens.get(&target.key).cloned().unwrap_or_default();
                let test = TestRec {
                    at: now.at,
                    results: report
                        .results
                        .iter()
                        .map(crate::engine::stored_test_item)
                        .collect(),
                };
                self.engine.token_tested(
                    &target.key,
                    test,
                    TokenObs {
                        owner: report.owner.clone(),
                        ..obs
                    },
                );
            }
            self.engine.apply_fetch(usage, &now);
            if let Err(e) = self.commit(&now, true) {
                logging::error(format_args!("cannot save a token test: {e:?}"));
            }
        }
        line(&proto::TokenTestResponse {
            ok: true,
            results: report.results,
            owner: report.owner,
            owner_mismatch: mismatch,
        })
    }
}

/// A token about to be tested. Never logged: it holds the token.
pub struct TestTarget {
    pub key: String,
    pub token: String,
    pub saved: bool,
    /// The owner login of an owner scope.
    pub owner: Option<String>,
    pub viewer: Option<String>,
    /// The classic PAT, when the reference owner has to be read first.
    pub classic: Option<String>,
    /// The classic PAT for Public's Team membership item.
    pub team_token: Option<String>,
    pub now: i64,
    pub cost_cap: i64,
    pub costs: Vec<(i64, i64)>,
}

/// The line for a failed `token_test`.
pub fn test_failed(error: impl std::fmt::Display) -> String {
    error_line(&CmdError::Internal(format!(
        "the test could not run: {error}"
    )))
}
