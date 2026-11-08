//! Joins the engine, the store, the Keychain and the subscribers. Rule of
//! this file: a change is saved first, and only then does anything leave for
//! a client.

use crate::clock::{Clock, Now};
use crate::engine::{ActivityArgs, CmdError, Engine, ListArgs};
use crate::github::{CallError, Recorder, Rest};
use crate::keychain::{Keychain, KeychainError, StoredAccount};
use crate::logging;
use crate::model::{OwnerKind, PUBLIC, TestRec};
use crate::plan::{Outcome, Plan};
use crate::store::{self, OpenOutcome, SaveError, Store};
use crate::tokentest::{Expect, OwnerProbe};
use shiibar_gh_proto as proto;
use shiibar_gh_proto::paths::StateDir;
use shiibar_gh_proto::{ClientKind, KeychainState, Lenient, Request, SubscribeEvent, codec};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};

pub use crate::engine::valid_login;

/// A subscriber with more than this many queued events is disconnected.
pub const SEND_QUEUE: usize = 256;

const UNREADABLE: &str = "couldn't read saved state; run `shiibar-gh reset`";
const KEYCHAIN: &str = "Couldn't read tokens from Keychain";

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

type Digest = BTreeMap<String, (proto::Account, Vec<proto::Card>)>;

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
    /// Tokens read from the Keychain, by account id. Never logged.
    tokens: HashMap<String, String>,
    /// The login each account has in the Keychain item, as last read or
    /// written: a login that differs from the account's is written back.
    stored_logins: HashMap<String, String>,
    /// The Keychain item was read since the start (or since `reset`).
    loaded: bool,
    /// The Keychain state last sent to subscribers.
    sent_keychain: KeychainState,
    /// Settings changed by the request being handled, sent once saved.
    config_events: Vec<(String, serde_json::Value)>,
}

fn error_line(error: &CmdError) -> String {
    let (code, message) = match error {
        CmdError::NotFound(m) => (proto::ErrorCode::NotFound, m),
        CmdError::Invalid(m) => (proto::ErrorCode::Invalid, m),
        CmdError::Unreachable(m) => (proto::ErrorCode::Unreachable, m),
        CmdError::KeychainUnavailable(m) => (proto::ErrorCode::KeychainUnavailable, m),
        CmdError::Internal(m) => (proto::ErrorCode::Internal, m),
    };
    line(&proto::ErrorResponse::new(code, message.clone()))
}

pub fn line<T: serde::Serialize>(value: &T) -> String {
    codec::encode_line(value).unwrap_or_else(|_| {
        "{\"ok\":false,\"code\":\"internal\",\"error\":\"cannot encode the response\"}\n".into()
    })
}

/// The line answering a request that could not be decoded.
pub fn invalid_line(message: impl std::fmt::Display) -> String {
    error_line(&CmdError::Invalid(format!("invalid request: {message}")))
}

pub fn error_of(error: CmdError) -> String {
    error_line(&error)
}

fn keychain_refused() -> CmdError {
    CmdError::KeychainUnavailable(KEYCHAIN.into())
}

/// What a call to GitHub that checks a token answered, as a command error.
pub fn call_error(error: &CallError) -> CmdError {
    match error {
        CallError::Unauthorized => CmdError::Invalid("Token is invalid".into()),
        CallError::Network(_) => CmdError::Unreachable("Couldn't reach GitHub".into()),
        CallError::RateLimited { .. } => CmdError::Internal("GitHub's limit reached".into()),
        other => CmdError::Internal(format!("GitHub answered: {other}")),
    }
}

impl Daemon {
    /// Open the database and run the first periodic pass. An `Err` means the
    /// daemon must exit; an unreadable database is a running state instead.
    pub fn start(dir: StateDir, clock: Clock, keychain: Arc<dyn Keychain>) -> anyhow::Result<Self> {
        let now = clock.now();
        let (mut engine, store) = match Store::open(&dir.db())? {
            OpenOutcome::Ready(store, Some(data)) => (Engine::restore(*data), Some(store)),
            OpenOutcome::Ready(store, None) => (Engine::fresh(&now), Some(store)),
            OpenOutcome::Unreadable => {
                logging::error(format_args!("{UNREADABLE}"));
                let mut engine = Engine::fresh(&now);
                engine.clear_dirty();
                (engine, None)
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
            stored_logins: HashMap::new(),
            loaded: false,
            sent_keychain: KeychainState::Ok,
            config_events: Vec::new(),
        };
        if daemon.store.is_some() {
            daemon.engine.tick(&now);
            daemon
                .commit(&now, true)
                .map_err(|e| anyhow::anyhow!("cannot save the state: {e:?}"))?;
        }
        Ok(daemon)
    }

    /// Answer one request. `subscribe`, `shutdown` and the requests that
    /// call GitHub are the server's.
    pub fn handle(&mut self, request: Request) -> String {
        let result = match request {
            Request::Info => Ok(line(&proto::InfoResponse {
                ok: true,
                version: env!("CARGO_PKG_VERSION").to_string(),
                started_at: self.started_at,
            })),
            Request::Reset => self.reset(),
            other => self.run(other),
        };
        result.unwrap_or_else(|e| error_line(&e))
    }

    fn run(&mut self, request: Request) -> Result<String, CmdError> {
        self.check_db()?;
        let now = self.clock.now();
        self.engine.set_clock(&now);
        let result = self.apply(request, &now);
        let saved = self.commit(&now, false);
        // A changed setting goes to the subscribers once it is saved.
        let events = std::mem::take(&mut self.config_events);
        saved?;
        for (key, value) in events {
            self.publish_config(key, value);
        }
        result
    }

    fn account_of(&self, login: &str) -> Result<String, CmdError> {
        self.engine.account_id(login)
    }

    fn owner_of(&self, account: &str, owner: &str) -> Result<(String, String), CmdError> {
        let account = self.account_of(account)?;
        let owner = self.engine.owner_id(&account, owner)?;
        Ok((account, owner))
    }

    fn account_line(&self, account: &str) -> Result<String, CmdError> {
        let value = self
            .engine
            .account_value(account)
            .ok_or_else(|| CmdError::NotFound(format!("not found: account {account}")))?;
        Ok(line(&proto::AccountResponse {
            ok: true,
            account: value,
        }))
    }

    fn apply(&mut self, request: Request, now: &Now) -> Result<String, CmdError> {
        let ack = || line(&proto::AckResponse::new());
        Ok(match request {
            Request::List {
                account,
                owner,
                todo,
                filter,
                snoozed,
            } => line(&proto::ListResponse {
                ok: true,
                cards: self.engine.list(
                    &ListArgs {
                        account,
                        owner,
                        todo,
                        filter,
                        snoozed,
                    },
                    now,
                )?,
            }),
            Request::Activity {
                account,
                owners,
                todo,
                filter,
            } => line(&proto::ActivityResponse {
                ok: true,
                rows: self.engine.activity(
                    &ActivityArgs {
                        account,
                        owners,
                        todo,
                        filter,
                    },
                    now,
                )?,
            }),
            Request::Status { account, pr } => line(&proto::StatusResponse {
                ok: true,
                card: self.engine.status(&account, &pr, now)?,
            }),
            Request::Seen { row_ids } => {
                self.engine.seen(&row_ids);
                ack()
            }
            Request::PopoverOpened { account } => {
                self.engine.popover_opened(&account)?;
                ack()
            }
            Request::PopoverClosed { account } => {
                self.engine.popover_closed(&account)?;
                ack()
            }
            Request::Done { row, on } => {
                self.engine.done(&row, on)?;
                ack()
            }
            Request::Todo { row, on } => {
                self.engine.todo(&row, on, now)?;
                ack()
            }
            Request::Snooze { account, pr } => {
                self.engine.snooze(&account, &pr, now)?;
                ack()
            }
            Request::Unsnooze { account, pr } => {
                self.engine.unsnooze(&account, &pr, now)?;
                ack()
            }
            Request::Open { account, pr, row } => {
                let url = match (account, pr, row) {
                    (Some(account), Some(pr), None) => self.engine.open_pr(&account, &pr)?,
                    (None, Some(_), None) => {
                        return Err(CmdError::Invalid("open of a PR needs the account".into()));
                    }
                    (account, None, Some(row)) => self.engine.open_row(account.as_deref(), &row)?,
                    _ => return Err(CmdError::Invalid("open takes either pr or row".into())),
                };
                line(&proto::OpenResponse { ok: true, url })
            }
            Request::ConfigGet { key } => line(&proto::ConfigResponse {
                ok: true,
                value: self.engine.config_get(&key)?,
            }),
            Request::ConfigSet { key, value } => {
                let before = self.engine.config_get(&key).ok();
                let value = self.engine.config_set(&key, &value, now)?;
                if before.as_ref() != Some(&value) {
                    self.config_events.push((key, value.clone()));
                }
                line(&proto::ConfigResponse { ok: true, value })
            }
            Request::AccountList => line(&proto::AccountsResponse {
                ok: true,
                accounts: self.engine.accounts(),
            }),
            Request::AccountRemove { account } => {
                let id = self.account_of(&account)?;
                self.require_keychain()?;
                // The Keychain goes first: a failure leaves the account.
                let mut stored = self.read_item()?;
                let before = stored.len();
                stored.retain(|a| a.id != id);
                if stored.len() != before {
                    self.write_item(&stored)?;
                }
                self.tokens.remove(&id);
                self.engine.account_remove(&id);
                ack()
            }
            Request::AccountColor { account, color } => {
                self.engine.account_color(&account, color)?;
                ack()
            }
            Request::OwnerRemove { account, owner } => {
                let (account, owner) = self.owner_of(&account, &owner)?;
                self.engine.owner_remove(&owner);
                self.account_line(&account)?
            }
            Request::OwnerEnable { account, owner } => {
                let (_, owner) = self.owner_of(&account, &owner)?;
                self.engine.owner_enable(&owner, true, now);
                ack()
            }
            Request::OwnerDisable { account, owner } => {
                let (_, owner) = self.owner_of(&account, &owner)?;
                self.engine.owner_enable(&owner, false, now);
                ack()
            }
            Request::OwnerNotify { account, owner, on } => {
                let (_, owner) = self.owner_of(&account, &owner)?;
                self.engine.owner_notify(&owner, on);
                ack()
            }
            Request::OwnerSkipDrafts { account, owner, on } => {
                let (_, owner) = self.owner_of(&account, &owner)?;
                self.engine.owner_skip_drafts(&owner, on);
                ack()
            }
            Request::OwnerEventsGet { account, owner } => {
                let (_, owner) = self.owner_of(&account, &owner)?;
                line(&proto::EventsResponse {
                    ok: true,
                    events: self.engine.owner_events(&owner),
                })
            }
            Request::OwnerEventsSet {
                account,
                owner,
                event,
                column,
                on,
            } => {
                let (_, owner) = self.owner_of(&account, &owner)?;
                self.engine
                    .owner_events_set(&owner, event, column, on, now)?;
                line(&proto::EventsResponse {
                    ok: true,
                    events: self.engine.owner_events(&owner),
                })
            }
            Request::OwnerEventsCopy {
                account,
                from_owner,
                to_owner,
            } => {
                let (account, from) = self.owner_of(&account, &from_owner)?;
                let to = self.engine.owner_id(&account, &to_owner)?;
                self.engine.owner_events_copy(&from, &to, now)?;
                line(&proto::EventsResponse {
                    ok: true,
                    events: self.engine.owner_events(&to),
                })
            }
            Request::OwnerExclusionsGet { account, owner } => {
                let (_, owner) = self.owner_of(&account, &owner)?;
                line(&proto::ExclusionsResponse {
                    ok: true,
                    exclusions: self.engine.owner_exclusions(&owner),
                })
            }
            Request::OwnerExclusionsSet {
                account,
                owner,
                kind,
                name,
                state,
            } => {
                let (_, owner) = self.owner_of(&account, &owner)?;
                self.engine
                    .owner_exclusions_set(&owner, kind, &name, state, now)?;
                line(&proto::ExclusionsResponse {
                    ok: true,
                    exclusions: self.engine.owner_exclusions(&owner),
                })
            }
            Request::OwnerExclusionsRemove {
                account,
                owner,
                kind,
                name,
            } => {
                let (_, owner) = self.owner_of(&account, &owner)?;
                self.engine
                    .owner_exclusions_remove(&owner, kind, &name, now)?;
                line(&proto::ExclusionsResponse {
                    ok: true,
                    exclusions: self.engine.owner_exclusions(&owner),
                })
            }
            Request::OwnerAdd { account, owner } if owner.eq_ignore_ascii_case(PUBLIC) => {
                let id = self.account_of(&account)?;
                self.engine
                    .owner_add(&id, PUBLIC, OwnerKind::Public, None, now)?;
                self.account_line(&id)?
            }
            Request::TokenReset => {
                self.token_reset()?;
                ack()
            }
            #[cfg(feature = "dev-ingest")]
            Request::DevIngest { account, ingest } => {
                let id = self.account_of(&account)?;
                self.engine.ingest(&id, ingest, now)?;
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
            #[cfg(feature = "dev-ingest")]
            Request::DevAccountAdd { id, login, token } => {
                if let Some(token) = &token {
                    let mut stored = self.read_item()?;
                    stored.retain(|a| a.id != id);
                    stored.push(StoredAccount {
                        id: id.clone(),
                        login: login.clone(),
                        token: token.clone(),
                    });
                    self.engine.account_create(&id, &login)?;
                    if let Err(e) = self.write_item(&stored) {
                        self.engine.account_remove(&id);
                        return Err(e);
                    }
                    self.tokens.insert(id.clone(), token.clone());
                    self.engine.token_saved(&id);
                } else {
                    self.engine.account_create(&id, &login)?;
                }
                self.account_line(&id)?
            }
            #[cfg(feature = "dev-ingest")]
            Request::DevOwnerAdd {
                account,
                owner,
                kind,
                github_id,
            } => {
                let id = self.account_of(&account)?;
                let name = if kind == proto::OwnerKind::Public {
                    PUBLIC.to_string()
                } else {
                    owner
                };
                self.engine
                    .owner_add(&id, &name, kind.into(), github_id, now)?;
                self.account_line(&id)?
            }
            Request::Subscribe { .. }
            | Request::Reset
            | Request::Info
            | Request::Shutdown
            | Request::Refresh { .. }
            | Request::AccountAdd { .. }
            | Request::OwnerLookup { .. }
            | Request::OwnerAdd { .. }
            | Request::TokenSet { .. }
            | Request::TokenTest { .. } => {
                return Err(CmdError::Internal("handled elsewhere".into()));
            }
        })
    }

    // ------------------------------------------------------------ Keychain

    /// DESIGN.md, "When the Keychain cannot be read": requests that touch
    /// tokens are refused while the item could not be read.
    fn require_keychain(&self) -> Result<(), CmdError> {
        match self.engine.keychain_state() {
            KeychainState::Ok => Ok(()),
            _ => Err(keychain_refused()),
        }
    }

    fn set_keychain(&mut self, state: KeychainState) {
        self.engine.set_keychain_state(state);
    }

    /// Read the item. A success records every token of a known account,
    /// clears the registration of an account without one, and after `reset`
    /// brings the accounts back. A failure sets the Keychain state.
    fn read_item(&mut self) -> Result<Vec<StoredAccount>, CmdError> {
        // Tried, whatever the outcome: a failure is read again only by
        // `refresh` and `token_reset` (DESIGN.md, "When the Keychain cannot
        // be read").
        self.loaded = true;
        match self.keychain.load() {
            Ok(stored) => {
                let stored = stored.unwrap_or_default();
                self.stored_logins = stored
                    .iter()
                    .map(|a| (a.id.clone(), a.login.clone()))
                    .collect();
                self.set_keychain(KeychainState::Ok);
                self.loaded = true;
                if self.engine.data().restore_accounts {
                    self.restore_accounts(&stored);
                }
                let ids: Vec<String> = self.engine.data().accounts.keys().cloned().collect();
                for id in ids {
                    match stored.iter().find(|a| a.id == id) {
                        Some(found) => {
                            self.tokens.insert(id.clone(), found.token.clone());
                            if !self
                                .engine
                                .account_record(&id)
                                .is_some_and(|a| a.token.registered)
                            {
                                self.engine.token_saved(&id);
                            }
                        }
                        None => {
                            self.tokens.remove(&id);
                            self.engine.token_cleared(&id);
                        }
                    }
                }
                Ok(stored)
            }
            Err(e) => {
                logging::error(format_args!("{e}"));
                self.tokens.clear();
                self.set_keychain(match e {
                    KeychainError::Unavailable(_) => KeychainState::Unavailable,
                    KeychainError::Unreadable(_) => KeychainState::Unreadable,
                });
                Err(keychain_refused())
            }
        }
    }

    /// DESIGN.md, "When the database cannot be read": after `reset`, the
    /// accounts come back from the item (id, login); owners do not.
    fn restore_accounts(&mut self, stored: &[StoredAccount]) {
        for account in stored {
            if self
                .engine
                .account_create(&account.id, &account.login)
                .is_ok()
            {
                self.engine.token_saved(&account.id);
            }
        }
        self.engine.restored();
    }

    fn write_item(&mut self, stored: &[StoredAccount]) -> Result<(), CmdError> {
        match self.keychain.save(stored) {
            Ok(()) => {
                self.stored_logins = stored
                    .iter()
                    .map(|a| (a.id.clone(), a.login.clone()))
                    .collect();
                Ok(())
            }
            Err(e) => {
                logging::error(format_args!("{e}"));
                if let KeychainError::Unavailable(_) = e {
                    self.set_keychain(KeychainState::Unavailable);
                }
                Err(keychain_refused())
            }
        }
    }

    /// DESIGN.md, "Tokens": the Keychain item follows the account's login.
    /// Written only when the login known to be in the item differs, so a
    /// fetch reads the Keychain only after a login change.
    fn follow_login(&mut self, account: &str) {
        let Some(login) = self.account_login(account) else {
            return;
        };
        let differs = self
            .stored_logins
            .get(account)
            .is_some_and(|stored| *stored != login);
        if !differs || self.engine.keychain_state() != KeychainState::Ok {
            return;
        }
        let Ok(mut stored) = self.read_item() else {
            return;
        };
        if let Some(entry) = stored.iter_mut().find(|a| a.id == account)
            && entry.login != login
        {
            entry.login = login;
            if let Err(e) = self.write_item(&stored) {
                logging::error(format_args!("cannot save the new login: {e:?}"));
            }
        }
    }

    /// The first read after the start, or after `reset`: only while there
    /// is an account (or one to restore), so an empty state never touches
    /// the Keychain.
    pub fn load_tokens(&mut self) {
        if self.loaded || self.store.is_none() || self.check_db().is_err() {
            return;
        }
        let data = self.engine.data();
        if data.accounts.is_empty() && !data.restore_accounts {
            return;
        }
        // A read that failed is not tried again by the next cycle: only
        // `refresh` and `token_reset` read again.
        self.loaded = true;
        let _ = self.read_item();
        self.after_keychain_change();
    }

    /// `refresh` reads the item again, once, while it could not be read,
    /// with or without accounts: a failed first `account_add` recovers too.
    /// The cycle that follows does not read it a second time.
    pub fn reload_tokens(&mut self) {
        if self.store.is_none() || self.check_db().is_err() {
            return;
        }
        if self.engine.keychain_state() != KeychainState::Ok {
            self.loaded = true;
            let _ = self.read_item();
            self.after_keychain_change();
        } else {
            self.load_tokens();
        }
    }

    /// After a request that read the Keychain and failed: save and send
    /// `keychain_changed` before the error answer goes out.
    fn publish_failure(&mut self) {
        let now = self.clock.now();
        if let Err(e) = self.commit(&now, true) {
            logging::error(format_args!("cannot save after a Keychain failure: {e:?}"));
        }
    }

    fn token_reset(&mut self) -> Result<(), CmdError> {
        if let Err(e) = self.keychain.delete() {
            logging::error(format_args!("{e}"));
            self.set_keychain(KeychainState::Unavailable);
            return Err(keychain_refused());
        }
        self.tokens.clear();
        let ids: Vec<String> = self.engine.data().accounts.keys().cloned().collect();
        for id in ids {
            self.engine.token_cleared(&id);
        }
        let _ = self.read_item();
        Ok(())
    }

    /// Save and tell the subscribers after a Keychain read outside a request.
    fn after_keychain_change(&mut self) {
        let now = self.clock.now();
        if let Err(e) = self.commit(&now, true) {
            logging::error(format_args!(
                "cannot save after reading the Keychain: {e:?}"
            ));
        }
    }

    /// A token for the account, from the cache, reading the item when it
    /// was not read yet.
    fn saved_token(&mut self, account: &str) -> Result<Option<String>, CmdError> {
        self.require_keychain()?;
        if !self.loaded {
            self.read_item()?;
        }
        Ok(self.tokens.get(account).cloned())
    }

    // ------------------------------------------------------------ database

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
        self.engine = Engine::fresh(&now);
        self.engine.clear_dirty();
        self.tokens.clear();
        self.loaded = false;
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
        self.publish_keychain();
        if changed || self.engine.keychain_state() != KeychainState::Ok {
            self.publish_accounts(now);
        }
        self.send_notifications(notifications, None);
        Ok(())
    }

    fn broadcast(&mut self, text: String) {
        let ids: Vec<u64> = self.subscribers.keys().copied().collect();
        for id in ids {
            self.enqueue(id, text.clone(), None);
        }
    }

    fn publish_keychain(&mut self) {
        let state = self.engine.keychain_state();
        if state != self.sent_keychain {
            self.sent_keychain = state;
            self.broadcast(line(&SubscribeEvent::KeychainChanged {
                keychain: Lenient::Known(state),
            }));
        }
    }

    fn publish_accounts(&mut self, now: &Now) {
        self.engine.set_clock(now);
        let digest = self.engine.digest(now);
        let removed: Vec<String> = self
            .digest
            .keys()
            .filter(|id| !digest.contains_key(*id))
            .cloned()
            .collect();
        let changed: Vec<proto::Account> = digest
            .iter()
            .filter(|(id, value)| self.digest.get(*id) != Some(value))
            .map(|(_, (account, _))| account.clone())
            .collect();
        self.digest = digest;
        for id in removed {
            self.broadcast(line(&SubscribeEvent::AccountRemoved { id }));
        }
        for account in changed {
            self.broadcast(line(&SubscribeEvent::AccountChanged { account }));
        }
    }

    /// `config_changed` to every subscriber (DESIGN.md, "Launch at login
    /// sync": the app follows a setting changed elsewhere).
    fn publish_config(&mut self, key: String, value: serde_json::Value) {
        self.broadcast(line(&SubscribeEvent::ConfigChanged { key, value }));
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
        let unreadable = self.store.is_none();
        let snapshot = SubscribeEvent::Snapshot {
            accounts: if unreadable {
                Vec::new()
            } else {
                self.engine.accounts()
            },
            keychain: Lenient::Known(self.engine.keychain_state()),
            db_unreadable: unreadable,
        };
        self.enqueue(id, line(&snapshot), None);
        if client == ClientKind::App && !unreadable {
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
            OpenOutcome::Unreadable => {
                return Err(internal("the new database is damaged".into()));
            }
        };
        self.store = Some(store);
        self.engine = Engine::fresh(&now);
        // The first fetch reads the Keychain and brings the accounts back.
        self.engine.restore_after_reset();
        self.tokens.clear();
        self.loaded = false;
        self.save_now()?;
        self.digest = self.engine.digest(&now);
        self.disconnect_all();
        logging::info(format_args!("saved state reset"));
        Ok(line(&proto::AckResponse::new()))
    }

    // ------------------------------------------------------------ fetching

    pub fn now(&self) -> Now {
        self.clock.now()
    }

    pub fn clock_fixed(&self) -> bool {
        self.clock.is_fixed()
    }

    /// The runs due now, one per account: not while the database or the
    /// Keychain cannot be read, and not for an account without a usable
    /// token or stopped by a rate limit.
    pub fn fetch_plans(&mut self, forced: bool, only: Option<&str>) -> Vec<Plan> {
        if self.check_db().is_err() || self.engine.keychain_state() != KeychainState::Ok {
            return Vec::new();
        }
        let now = self.clock.now();
        self.engine.set_clock(&now);
        let ids: Vec<String> = self.engine.data().accounts.keys().cloned().collect();
        let mut plans = Vec::new();
        for id in ids {
            if only.is_some_and(|o| o != id) || !self.engine.may_fetch(&id, now.at, forced) {
                continue;
            }
            let due = self.engine.due(&id, now.at, forced);
            if !due.any() {
                continue;
            }
            let Some(token) = self.tokens.get(&id).cloned() else {
                continue;
            };
            plans.extend(self.engine.fetch_plan(&id, &now, due, forced, token));
        }
        plans
    }

    /// Apply a run's outcome, save, then tell the subscribers.
    pub fn apply_fetch(&mut self, account: &str, outcome: Outcome) {
        if self.check_db().is_err() {
            return;
        }
        let now = self.clock.now();
        self.engine.apply_fetch(account, outcome, &now);
        self.follow_login(account);
        if let Err(e) = self.commit(&now, true) {
            logging::error(format_args!("cannot save a fetch: {e:?}"));
        }
    }

    /// Check a `refresh` before the server runs it: the account id it names.
    pub fn precheck(&mut self, account: Option<&str>) -> Result<Option<String>, String> {
        self.check_db().map_err(|e| error_line(&e))?;
        account
            .map(|a| self.account_of(a))
            .transpose()
            .map_err(|e| error_line(&e))
    }

    /// The `refresh` answer once fetching is done.
    pub fn refresh_answer(&mut self, account: Option<&str>) -> String {
        let now = self.clock.now();
        self.engine.set_clock(&now);
        line(&proto::RefreshResponse {
            ok: true,
            warnings: self.engine.refresh_warnings(account),
        })
    }

    // ------------------------------------------------------------- tokens

    pub fn account_login(&self, id: &str) -> Option<String> {
        self.engine.account_record(id).map(|a| a.login.clone())
    }

    /// `account_add` before GitHub is asked.
    pub fn account_add_check(&mut self) -> Result<(), String> {
        self.check_db().map_err(|e| error_line(&e))?;
        self.require_keychain().map_err(|e| error_line(&e))
    }

    /// `account_add` once `viewer` answered: create the account and save the
    /// token. Returns the account id.
    pub fn account_add_finish(
        &mut self,
        id: &str,
        login: &str,
        token: &str,
    ) -> Result<String, String> {
        let result = (|| {
            self.check_db()?;
            if let Some(existing) = self.engine.account_record(id) {
                return Err(CmdError::Invalid(format!(
                    "{} is already added",
                    existing.login
                )));
            }
            let mut stored = self.read_item()?;
            stored.retain(|a| a.id != id);
            stored.push(StoredAccount {
                id: id.to_string(),
                login: login.to_string(),
                token: token.to_string(),
            });
            self.engine.account_create(id, login)?;
            if let Err(e) = self.write_item(&stored) {
                self.engine.account_remove(id);
                return Err(e);
            }
            self.tokens.insert(id.to_string(), token.to_string());
            self.engine.token_saved(id);
            let now = self.clock.now();
            self.commit(&now, false)?;
            self.account_line(id)
        })();
        if result.is_err() {
            self.publish_failure();
        }
        result.map_err(|e| error_line(&e))
    }

    /// `token_set` before GitHub is asked: the account id.
    pub fn token_set_check(&mut self, account: &str) -> Result<String, String> {
        self.check_db().map_err(|e| error_line(&e))?;
        let id = self.account_of(account).map_err(|e| error_line(&e))?;
        self.require_keychain().map_err(|e| error_line(&e))?;
        Ok(id)
    }

    /// `token_set` once `viewer` answered with `owner_id`.
    pub fn token_set_finish(
        &mut self,
        account: &str,
        owner_id: &str,
        owner_login: &str,
        token: &str,
    ) -> Result<String, String> {
        let result = (|| {
            self.check_db()?;
            if owner_id != account {
                return Err(CmdError::Invalid(format!("Belongs to {owner_login}")));
            }
            if self.engine.account_record(account).is_none() {
                return Err(CmdError::NotFound("not found: account".into()));
            }
            // The token's owner may have a new login: the item and the
            // account take it at once (DESIGN.md, "Tokens").
            let mut stored = self.read_item()?;
            stored.retain(|a| a.id != account);
            stored.push(StoredAccount {
                id: account.to_string(),
                login: owner_login.to_string(),
                token: token.to_string(),
            });
            self.write_item(&stored)?;
            self.tokens.insert(account.to_string(), token.to_string());
            self.engine.token_saved(account);
            self.engine.login_seen(account, owner_login);
            let now = self.clock.now();
            self.commit(&now, false)?;
            Ok(line(&proto::AckResponse::new()))
        })();
        if result.is_err() {
            self.publish_failure();
        }
        result.map_err(|e| error_line(&e))
    }

    /// What `token_test` needs. `given` is the token from standard input.
    pub fn test_target(
        &mut self,
        account: Option<&str>,
        given: Option<String>,
    ) -> Result<TestTarget, String> {
        let result = (|| {
            self.check_db()?;
            let given = given
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty());
            let id = account.map(|a| self.account_of(a)).transpose()?;
            let saved = given.is_none();
            let token = match (&id, given) {
                (_, Some(token)) => token,
                (Some(id), None) => self.saved_token(id)?.ok_or_else(|| {
                    CmdError::Invalid(
                        "no token for the account: pipe one to the command or run `shiibar-gh token set`"
                            .into(),
                    )
                })?,
                (None, None) => {
                    return Err(CmdError::Invalid(
                        "token_test without an account needs a token".into(),
                    ));
                }
            };
            let (expect, owners) = match &id {
                Some(id) => (
                    Expect::Account { id: id.clone() },
                    self.engine
                        .owners_of(id)
                        .into_iter()
                        .map(|o| OwnerProbe {
                            id: o.id.clone(),
                            name: o.name.clone(),
                            kind: o.kind,
                            github_id: o.github_id,
                        })
                        .collect(),
                ),
                None => (
                    Expect::New {
                        taken: self
                            .engine
                            .data()
                            .accounts
                            .values()
                            .map(|a| (a.id.clone(), a.login.clone()))
                            .collect(),
                    },
                    Vec::new(),
                ),
            };
            Ok(TestTarget {
                account: id,
                token,
                saved,
                expect,
                owners,
                now: self.clock.now().at,
            })
        })();
        if result.is_err() {
            self.publish_failure();
        }
        result.map_err(|e| error_line(&e))
    }

    /// Record what a test found and answer it.
    pub fn test_done(
        &mut self,
        target: &TestTarget,
        report: crate::tokentest::Report,
        rec: Recorder,
    ) -> String {
        let now = self.clock.now();
        // DESIGN.md, "Token registration and test": only the saved token's
        // usage and limits are recorded on the account; a pasted token's
        // are not, even when it belongs to the account.
        if self.check_db().is_ok()
            && let Some(account) = &target.account
            && target.saved
        {
            self.engine
                .usage_seen(account, rec.graphql, rec.rest, rec.stop);
            {
                let login = report
                    .viewer
                    .as_ref()
                    .filter(|(id, _)| id == account)
                    .map(|(_, login)| login.clone());
                self.engine.token_tested(
                    account,
                    TestRec {
                        at: now.at,
                        results: report.results.clone(),
                    },
                    rec.token.clone(),
                    login,
                );
            }
            self.follow_login(account);
            if let Err(e) = self.commit(&now, true) {
                logging::error(format_args!("cannot save a token test: {e:?}"));
            }
        }
        line(&proto::TokenTestResponse {
            ok: true,
            results: report.results,
        })
    }

    /// `owner_lookup` and `owner_add` before GitHub is asked: the account id
    /// and the token to ask with (empty without one).
    pub fn lookup_target(
        &mut self,
        account: &str,
        owner: &str,
        adding: bool,
    ) -> Result<(String, String), String> {
        let result = (|| {
            self.check_db()?;
            let id = self.account_of(account)?;
            if !valid_login(owner) || owner.eq_ignore_ascii_case(PUBLIC) {
                return Err(CmdError::Invalid(format!("not a GitHub login: {owner}")));
            }
            if adding && self.engine.owner_id(&id, owner).is_ok() {
                return Err(CmdError::Invalid(format!("{owner} is already added")));
            }
            // DESIGN.md, "Add owner…": asked with the account's token only.
            let token = self
                .saved_token(&id)?
                .ok_or_else(|| CmdError::Invalid("Account has no token".into()))?;
            Ok((id, token))
        })();
        if result.is_err() {
            self.publish_failure();
        }
        result.map_err(|e| error_line(&e))
    }

    /// `owner_add` once `GET /users/{owner}` answered.
    pub fn owner_add_finish(&mut self, account: &str, found: Lookup) -> String {
        let result = (|| {
            self.check_db()?;
            let now = self.clock.now();
            self.engine.set_clock(&now);
            self.engine
                .owner_add(account, &found.login, found.kind, Some(found.id), &now)?;
            self.commit(&now, false)?;
            self.account_line(account)
        })();
        result.unwrap_or_else(|e| error_line(&e))
    }
}

/// A token about to be tested. Never logged: it holds the token.
pub struct TestTarget {
    pub account: Option<String>,
    pub token: String,
    pub saved: bool,
    pub expect: Expect,
    pub owners: Vec<OwnerProbe>,
    pub now: i64,
}

/// What `GET /users/{owner}` said.
#[derive(Debug, Clone)]
pub struct Lookup {
    pub login: String,
    pub kind: OwnerKind,
    pub id: i64,
}

/// The answer of `GET /users/{owner}`: `type` Organization is `org`, User
/// is `user`; 404 is `not_found`, a network failure `unreachable`.
pub fn lookup_answer(answer: Result<Rest, CallError>) -> Result<Lookup, CmdError> {
    match answer {
        Ok(rest) => {
            let kind = match rest.body["type"].as_str() {
                Some("Organization") => OwnerKind::Org,
                Some("User") => OwnerKind::User,
                other => {
                    return Err(CmdError::Internal(format!(
                        "cannot look the owner up: GitHub gave the type {}",
                        other.unwrap_or("nothing")
                    )));
                }
            };
            let id = rest.body["id"].as_i64().ok_or_else(|| {
                CmdError::Internal("cannot look the owner up: GitHub gave no id".into())
            })?;
            Ok(Lookup {
                login: rest.body["login"].as_str().unwrap_or_default().to_string(),
                kind,
                id,
            })
        }
        Err(CallError::NotFound) => Err(CmdError::NotFound("Owner not found".into())),
        Err(CallError::Network(_)) => Err(CmdError::Unreachable("Couldn't reach GitHub".into())),
        Err(e) => Err(CmdError::Internal(format!("cannot look the owner up: {e}"))),
    }
}

pub fn lookup_line(found: &Lookup) -> String {
    line(&proto::OwnerLookupResponse {
        ok: true,
        owner: found.login.clone(),
        kind: Lenient::Known(found.kind.into()),
        id: found.id,
    })
}
