//! SQLite persistence. One long-lived WAL connection writes; every save ends
//! with a truncating checkpoint so the main file alone holds the saved state.
//! That keeps `check` honest: it opens a separate read-only connection with an
//! empty page cache, which is what notices a file damaged under a running
//! daemon. A long-lived connection would keep answering from its own cache.

use crate::model::*;
use anyhow::Context;
use rusqlite::config::DbConfig;
use rusqlite::{Connection, ErrorCode, OpenFlags, OptionalExtension, Transaction, params};
use std::collections::BTreeMap;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// M6 (0.4). Versions 5 (0.3) and 4 (0.2) move to 6 at startup, keeping
/// only the accounts. Versions 1 to 3 are the 0.1 schema, which is not
/// migrated: such a database is treated like an unreadable one (DESIGN.md,
/// "Saved state").
pub const SCHEMA_VERSION: i64 = 6;
/// The 0.3 and 0.2 schemas, moved to 6 at startup.
const MOVED_VERSIONS: [i64; 2] = [4, 5];
/// The newest version of the 0.1 schema.
const LAST_V01_VERSION: i64 = 3;
const BUSY_TIMEOUT: Duration = Duration::from_secs(2);
const FILE_MODE: u32 = 0o600;
const SIDE_FILES: [&str; 2] = ["-wal", "-shm"];

/// The 0.4 schema. A PR's placement, Dismiss state, Checks results and
/// newest review request are columns of `prs`; Mute lists hang off the
/// account; deleted row ids and Dismiss records have their own tables.
const SCHEMA_V6: &str = "
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE accounts (
    id TEXT PRIMARY KEY,
    login TEXT NOT NULL,
    color TEXT NOT NULL,
    seq INTEGER NOT NULL,
    token TEXT NOT NULL,
    updated_at INTEGER,
    dot INTEGER NOT NULL,
    teams TEXT NOT NULL,
    graphql_limit TEXT,
    rest_limit TEXT,
    stopped_until INTEGER,
    fetch TEXT NOT NULL
);
CREATE TABLE mutes (
    account TEXT NOT NULL,
    kind TEXT NOT NULL,
    position INTEGER NOT NULL,
    name TEXT NOT NULL,
    PRIMARY KEY (account, kind, position)
);
CREATE TABLE owners (
    id TEXT PRIMARY KEY,
    account TEXT NOT NULL,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    github_id INTEGER,
    seq INTEGER NOT NULL,
    enabled INTEGER NOT NULL,
    notify INTEGER NOT NULL,
    skip_drafts INTEGER NOT NULL,
    watch_started_at INTEGER NOT NULL,
    fetched_at INTEGER
);
CREATE TABLE owner_events (
    owner TEXT NOT NULL,
    event TEXT NOT NULL,
    list INTEGER NOT NULL,
    notify INTEGER NOT NULL,
    PRIMARY KEY (owner, event)
);
CREATE TABLE prs (
    key TEXT PRIMARY KEY,
    account TEXT NOT NULL,
    id TEXT NOT NULL,
    owner TEXT NOT NULL,
    repo TEXT NOT NULL,
    number INTEGER NOT NULL,
    url TEXT NOT NULL,
    title TEXT NOT NULL,
    author TEXT NOT NULL,
    author_avatar_url TEXT,
    base TEXT NOT NULL,
    head TEXT NOT NULL,
    head_oid TEXT,
    state TEXT NOT NULL,
    is_draft INTEGER NOT NULL,
    review TEXT NOT NULL,
    checks TEXT NOT NULL,
    base_status TEXT NOT NULL,
    mergeable INTEGER NOT NULL,
    failed_check TEXT,
    changes_requested_by TEXT,
    updated_at INTEGER NOT NULL,
    created_at INTEGER,
    my_review_at INTEGER,
    last_request_at INTEGER,
    is_private INTEGER NOT NULL,
    requested_me INTEGER NOT NULL,
    requested_team INTEGER NOT NULL,
    assignees TEXT NOT NULL,
    link_review TEXT NOT NULL,
    link_checks TEXT NOT NULL,
    link_base TEXT NOT NULL,
    unreadable INTEGER NOT NULL,
    added_at INTEGER,
    prev_review TEXT,
    prev_checks TEXT,
    prev_base_status TEXT,
    prev_mergeable INTEGER,
    settled TEXT,
    settled_head TEXT,
    watch_reset INTEGER NOT NULL,
    place_tab TEXT,
    place_section TEXT,
    place_rank INTEGER,
    closed_at INTEGER,
    done_at INTEGER,
    keep_after_close INTEGER NOT NULL,
    dismissed_at INTEGER,
    restored INTEGER NOT NULL,
    seen_closed INTEGER NOT NULL,
    quiet_from INTEGER,
    quiet_until INTEGER,
    merged_event_at INTEGER,
    collected INTEGER NOT NULL
);
CREATE TABLE pr_rows (
    id TEXT PRIMARY KEY,
    account TEXT NOT NULL,
    pr TEXT NOT NULL,
    kind TEXT NOT NULL,
    text TEXT,
    counts TEXT,
    actor TEXT,
    url TEXT NOT NULL,
    occurred_at INTEGER NOT NULL,
    comment_id TEXT,
    unread INTEGER NOT NULL,
    listed INTEGER NOT NULL,
    made_at INTEGER NOT NULL,
    notify TEXT NOT NULL
);
CREATE TABLE deleted_rows (id TEXT PRIMARY KEY, pr TEXT NOT NULL);
CREATE TABLE dismiss_records (
    key TEXT PRIMARY KEY,
    account TEXT NOT NULL,
    pr_id TEXT NOT NULL,
    owner TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE TABLE reaction_baselines (
    key TEXT PRIMARY KEY,
    pr TEXT NOT NULL,
    counts TEXT NOT NULL
);
";

/// DESIGN.md, "Updating from 0.3 and 0.2": inside the caller's transaction,
/// keep each account's id, login, color and order, drop every table, create
/// the version 6 tables, put the accounts back and set `user_version`. The
/// `accounts` table of versions 4 and 5 has the same four columns. Any error
/// leaves the transaction for the caller to roll back.
fn migrate_to_v6(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    let mut accounts: Vec<(String, String, String, i64)> = Vec::new();
    {
        let mut statement = tx.prepare("SELECT id, login, color, seq FROM accounts")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?;
        for row in rows {
            let (id, login, color, seq): (String, String, String, i64) = row?;
            // A color no build knows would make the moved state unreadable.
            stored(2, &color, AccountColor::parse)?;
            accounts.push((id, login, color, seq));
        }
    }
    let tables: Vec<String> = {
        let mut statement = tx.prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )?;
        let names = statement.query_map([], |row| row.get(0))?;
        names.collect::<rusqlite::Result<_>>()?
    };
    for table in tables {
        tx.execute_batch(&format!("DROP TABLE \"{}\"", table.replace('"', "\"\"")))?;
    }
    tx.execute_batch(SCHEMA_V6)?;
    let token = to_json(&TokenRec::default());
    let fetch = to_json(&FetchRec::default());
    let mut seq = 0;
    for (id, login, color, order) in &accounts {
        tx.execute(
            "INSERT INTO accounts
             (id, login, color, seq, token, updated_at, dot, teams, graphql_limit, rest_limit,
              stopped_until, fetch)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, 0, '[]', NULL, NULL, NULL, ?6)",
            params![id, login, color, order, token, fetch],
        )?;
        seq = seq.max(*order);
    }
    for (key, value) in [
        ("seq", seq.to_string()),
        ("restore_accounts", "false".to_string()),
    ] {
        tx.execute(
            "INSERT INTO meta (key, value) VALUES (?1, ?2)",
            params![key, value],
        )?;
    }
    tx.pragma_update(None, "user_version", SCHEMA_VERSION)
}

#[derive(Debug)]
pub enum OpenOutcome {
    /// The saved state, or `None` for a database without any.
    Ready(Store, Option<Box<Data>>),
    /// The file is damaged, or holds the 0.1 schema. Nothing was changed.
    Unreadable,
}

pub struct Store {
    conn: Connection,
    path: PathBuf,
}

impl std::fmt::Debug for Store {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Store").field("path", &self.path).finish()
    }
}

#[derive(Debug)]
pub enum SaveError {
    Corrupt,
    Other(rusqlite::Error),
}

impl std::fmt::Display for SaveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SaveError::Corrupt => write!(f, "the database is damaged"),
            SaveError::Other(e) => write!(f, "{e}"),
        }
    }
}

fn is_corruption(error: &rusqlite::Error) -> bool {
    matches!(
        error.sqlite_error_code(),
        Some(ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase)
    )
}

fn side_file(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

fn restrict(path: &Path) -> std::io::Result<()> {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(FILE_MODE))
}

fn restrict_side_files(path: &Path) -> std::io::Result<()> {
    for suffix in SIDE_FILES {
        let side = side_file(path, suffix);
        if side.exists() {
            restrict(&side)?;
        }
    }
    Ok(())
}

/// A `file:` URI for any path. Every byte outside a safe set is percent-encoded,
/// so `?`, `#` and `%` in a directory name stay part of the path.
fn immutable_uri(path: &Path) -> String {
    let mut uri = String::from(if path.is_absolute() {
        "file://"
    } else {
        "file:"
    });
    for byte in path.as_os_str().as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'.' | b'-' | b'_' | b'~' => {
                uri.push(*byte as char)
            }
            other => uri.push_str(&format!("%{other:02X}")),
        }
    }
    uri.push_str("?immutable=1");
    uri
}

/// Let SQLite walk every page, never writing to the main database file.
///
/// A plain read-only open of a WAL database failed on the macOS system
/// libsqlite3 (3.54.0) once `-wal` and `-shm` were gone; the bundled SQLite
/// opens it, but the check does not depend on that build difference. A WAL
/// without content is skipped with `immutable=1`: the main file then holds
/// everything, and SQLite's warning about immutable files changing does not
/// apply because only this daemon writes, under the lock file, and never at
/// the same time as this check. A WAL with content holds saved state, so it
/// has to be read the normal way.
fn read_only(path: &Path) -> rusqlite::Result<Connection> {
    let wal_has_content = std::fs::metadata(side_file(path, "-wal")).is_ok_and(|wal| wal.len() > 0);
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = if wal_has_content {
        Connection::open_with_flags(path, flags)?
    } else {
        Connection::open_with_flags(immutable_uri(path), flags | OpenFlags::SQLITE_OPEN_URI)?
    };
    conn.busy_timeout(BUSY_TIMEOUT)?;
    Ok(conn)
}

fn verify(path: &Path) -> rusqlite::Result<bool> {
    let conn = read_only(path)?;
    let result: String = conn.query_row("PRAGMA quick_check(1)", [], |row| row.get(0))?;
    Ok(result == "ok")
}

/// The schema version, read without writing anything.
fn stored_version(path: &Path) -> rusqlite::Result<i64> {
    read_only(path)?.query_row("PRAGMA user_version", [], |row| row.get(0))
}

impl Store {
    /// Open the database, creating it when absent. Errors are the cases the
    /// daemon must exit on: another process holds the lock, the schema is
    /// newer than this program, or a plain I/O failure.
    pub fn open(path: &Path) -> anyhow::Result<OpenOutcome> {
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(FILE_MODE)
            .open(path)
        {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e).context("cannot create the database file"),
        }
        restrict(path).context("cannot set the database file mode")?;

        let empty = std::fs::metadata(path)
            .context("cannot read the database file")?
            .len()
            == 0;
        if !empty {
            match verify(path) {
                Ok(true) => {}
                Ok(false) => return Ok(OpenOutcome::Unreadable),
                Err(e) if is_corruption(&e) => return Ok(OpenOutcome::Unreadable),
                Err(e) => return Err(e).context("cannot read the database"),
            }
        }

        if !empty {
            // DESIGN.md, "Saved state": a 0.1 database is not carried over,
            // and is left exactly as it is until `reset` moves it aside.
            let version = stored_version(path).context("cannot read the database")?;
            anyhow::ensure!(
                version <= SCHEMA_VERSION,
                "the database has schema version {version}, newer than {SCHEMA_VERSION}"
            );
            if (1..=LAST_V01_VERSION).contains(&version) {
                crate::logging::error(format_args!(
                    "the database has the 0.1 schema (version {version}); it is not read"
                ));
                return Ok(OpenOutcome::Unreadable);
            }
        }

        match Self::open_verified(path) {
            Ok(opened) => Ok(opened),
            Err(e) => match e.downcast_ref::<rusqlite::Error>() {
                Some(sqlite) if is_corruption(sqlite) => Ok(OpenOutcome::Unreadable),
                _ => Err(e),
            },
        }
    }

    fn open_verified(path: &Path) -> anyhow::Result<OpenOutcome> {
        let mut conn = Connection::open(path)?;
        conn.busy_timeout(BUSY_TIMEOUT)?;
        conn.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;

        // Taking the write lock now turns a lock held elsewhere into a startup
        // error instead of a failure on the first save.
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let version: i64 = tx.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        anyhow::ensure!(
            version <= SCHEMA_VERSION,
            "the database has schema version {version}, newer than {SCHEMA_VERSION}"
        );
        if (1..=LAST_V01_VERSION).contains(&version) {
            // DESIGN.md, "Saved state": a 0.1 database is not carried over.
            drop(tx);
            crate::logging::error(format_args!(
                "the database has the 0.1 schema (version {version}); it is not read"
            ));
            return Ok(OpenOutcome::Unreadable);
        }
        if version == 0 {
            tx.execute_batch(SCHEMA_V6)?;
            tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        }
        let migrating = MOVED_VERSIONS.contains(&version);
        if migrating {
            // DESIGN.md, "Updating from 0.3 and 0.2": a failed move rolls
            // back and leaves the database as it was, in the unreadable
            // state.
            if let Err(e) = migrate_to_v6(&tx) {
                drop(tx);
                crate::logging::error(format_args!(
                    "cannot move the database of schema version {version} to {SCHEMA_VERSION}: {e}"
                ));
                return Ok(OpenOutcome::Unreadable);
            }
        }
        // The moved state is read back inside the move's transaction: a
        // failure rolls everything back, so the database stays at its old
        // version and every start shows the unreadable state, never an exit.
        let moved = if migrating {
            match load(&tx) {
                Ok(data) => Some(data),
                Err(e) => {
                    drop(tx);
                    crate::logging::error(format_args!(
                        "cannot read the database moved to schema version {SCHEMA_VERSION}: {e:#}"
                    ));
                    return Ok(OpenOutcome::Unreadable);
                }
            }
        } else {
            None
        };
        // DESIGN.md, "When the database cannot be read": a move that cannot
        // be committed (SQLite rolls it back) leaves the unreadable state,
        // not an exit.
        if let Err(e) = tx.commit() {
            if !migrating {
                return Err(e.into());
            }
            crate::logging::error(format_args!(
                "cannot commit the move to schema version {SCHEMA_VERSION}: {e}"
            ));
            return Ok(OpenOutcome::Unreadable);
        }
        if migrating {
            crate::logging::info(format_args!(
                "moved the database of schema version {version} to {SCHEMA_VERSION}; only the accounts were kept"
            ));
        }

        restrict_side_files(path).context("cannot set the database side file mode")?;
        let data = match moved {
            Some(data) => data,
            None => load(&conn)?,
        }
        .map(Box::new);
        let store = Self {
            conn,
            path: path.to_path_buf(),
        };
        store.checkpoint();
        Ok(OpenOutcome::Ready(store, data))
    }

    /// Whether the file on disk is damaged. A busy database is not damage, and
    /// a file that cannot be opened any more is.
    pub fn check(&self) -> bool {
        match verify(&self.path) {
            Ok(healthy) => healthy,
            Err(e) => !(is_corruption(&e) || e.sqlite_error_code() == Some(ErrorCode::CannotOpen)),
        }
    }

    /// Let go of a damaged file without trying to write to it.
    pub fn abandon(self) {
        let _ = self
            .conn
            .set_db_config(DbConfig::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, true);
    }

    /// Save what changed in one transaction.
    pub fn save(&mut self, data: &Data, dirty: &Dirty) -> Result<(), SaveError> {
        let result = self.save_tx(data, dirty);
        match result {
            Ok(()) => {
                self.checkpoint();
                Ok(())
            }
            Err(e) if is_corruption(&e) => Err(SaveError::Corrupt),
            Err(e) => Err(SaveError::Other(e)),
        }
    }

    fn save_tx(&mut self, data: &Data, dirty: &Dirty) -> rusqlite::Result<()> {
        let tx = self
            .conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        if dirty.meta {
            for (key, value) in [
                ("seq", data.seq.to_string()),
                ("restore_accounts", data.restore_accounts.to_string()),
            ] {
                tx.execute(
                    "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
                    params![key, value],
                )?;
            }
        }
        if dirty.config {
            for key in crate::engine::CONFIG_KEYS {
                if let Some(value) = crate::engine::read_config(&data.config, key) {
                    tx.execute(
                        "INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)",
                        params![key, value.to_string()],
                    )?;
                }
            }
        }
        for id in &dirty.accounts {
            tx.execute("DELETE FROM mutes WHERE account = ?1", params![id])?;
            match data.accounts.get(id) {
                Some(account) => save_account(&tx, account)?,
                None => {
                    tx.execute("DELETE FROM accounts WHERE id = ?1", params![id])?;
                }
            }
        }
        for id in &dirty.owners {
            tx.execute("DELETE FROM owner_events WHERE owner = ?1", params![id])?;
            match data.owners.get(id) {
                Some(owner) => save_owner(&tx, owner)?,
                None => {
                    tx.execute("DELETE FROM owners WHERE id = ?1", params![id])?;
                }
            }
        }
        for key in &dirty.prs {
            match data.prs.get(key) {
                Some(pr) => save_pr(&tx, pr)?,
                None => {
                    tx.execute("DELETE FROM prs WHERE key = ?1", params![key])?;
                }
            }
        }
        for id in &dirty.rows {
            match data.rows.get(id) {
                Some(row) => save_row(&tx, row)?,
                None => {
                    tx.execute("DELETE FROM pr_rows WHERE id = ?1", params![id])?;
                }
            }
        }
        for id in &dirty.deleted_rows {
            match data.deleted_rows.get(id) {
                Some(pr) => {
                    tx.execute(
                        "INSERT OR REPLACE INTO deleted_rows (id, pr) VALUES (?1, ?2)",
                        params![id, pr],
                    )?;
                }
                None => {
                    tx.execute("DELETE FROM deleted_rows WHERE id = ?1", params![id])?;
                }
            }
        }
        for key in &dirty.records {
            match data.records.get(key) {
                Some(r) => {
                    tx.execute(
                        "INSERT OR REPLACE INTO dismiss_records (key, account, pr_id, owner, updated_at)
                         VALUES (?1, ?2, ?3, ?4, ?5)",
                        params![r.key, r.account, r.pr_id, r.owner, r.updated_at],
                    )?;
                }
                None => {
                    tx.execute("DELETE FROM dismiss_records WHERE key = ?1", params![key])?;
                }
            }
        }
        for key in &dirty.baselines {
            match data.baselines.get(key) {
                Some(baseline) => {
                    tx.execute(
                        "INSERT OR REPLACE INTO reaction_baselines (key, pr, counts)
                         VALUES (?1, ?2, ?3)",
                        params![baseline.key, baseline.pr, counts_text(&baseline.counts)],
                    )?;
                }
                None => {
                    tx.execute(
                        "DELETE FROM reaction_baselines WHERE key = ?1",
                        params![key],
                    )?;
                }
            }
        }
        tx.commit()
    }

    fn checkpoint(&self) {
        let result = self
            .conn
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
        if let Err(e) = result {
            crate::logging::debug(format_args!("checkpoint skipped: {e}"));
        }
    }
}

/// Move a damaged database and its side files aside. The files are kept. An
/// existing name is never overwritten: the next free second is taken instead.
pub fn retire(path: &Path, now: i64) -> std::io::Result<()> {
    let mut stamp = now;
    let retired = loop {
        let candidate = side_file(path, &format!(".corrupt-{stamp}"));
        let taken = candidate.exists()
            || SIDE_FILES
                .iter()
                .any(|suffix| side_file(&candidate, suffix).exists());
        if !taken {
            break candidate;
        }
        stamp += 1;
    };
    if path.exists() {
        std::fs::rename(path, &retired)?;
        restrict(&retired)?;
    }
    for suffix in SIDE_FILES {
        let side = side_file(path, suffix);
        if side.exists() {
            let target = side_file(&retired, suffix);
            std::fs::rename(side, &target)?;
            restrict(&target)?;
        }
    }
    Ok(())
}

fn counts_text(counts: &BTreeMap<String, u32>) -> String {
    serde_json::to_value(counts).map_or_else(|_| "{}".into(), |v| v.to_string())
}

fn json_err(e: serde_json::Error) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
}

fn to_json<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".into())
}

fn from_json<T: serde::de::DeserializeOwned>(text: &str) -> rusqlite::Result<T> {
    serde_json::from_str(text).map_err(json_err)
}

fn stored<T>(column: usize, text: &str, parse: fn(&str) -> Option<T>) -> rusqlite::Result<T> {
    parse(text).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            column,
            rusqlite::types::Type::Text,
            format!("unknown stored value: {text}").into(),
        )
    })
}

fn save_account(tx: &Transaction<'_>, a: &AccountRec) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT OR REPLACE INTO accounts
         (id, login, color, seq, token, updated_at, dot, teams, graphql_limit, rest_limit,
          stopped_until, fetch)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            a.id,
            a.login,
            a.color.as_str(),
            a.seq as i64,
            to_json(&a.token),
            a.updated_at,
            a.dot,
            to_json(&a.teams),
            a.graphql.as_ref().map(to_json),
            a.rest.as_ref().map(to_json),
            a.stopped_until,
            to_json(&a.fetch),
        ],
    )?;
    for (kind, list) in [
        ("repo", &a.mutes.repos),
        ("user", &a.mutes.users),
        ("pr", &a.mutes.prs),
    ] {
        for (position, name) in list.iter().enumerate() {
            tx.execute(
                "INSERT INTO mutes (account, kind, position, name) VALUES (?1, ?2, ?3, ?4)",
                params![a.id, kind, position as i64, name],
            )?;
        }
    }
    Ok(())
}

fn save_owner(tx: &Transaction<'_>, o: &OwnerRec) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT OR REPLACE INTO owners
         (id, account, name, kind, github_id, seq, enabled, notify, skip_drafts,
          watch_started_at, fetched_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            o.id,
            o.account,
            o.name,
            o.kind.as_str(),
            o.github_id,
            o.seq as i64,
            o.enabled,
            o.notify,
            o.skip_drafts,
            o.watch_started_at,
            o.fetched_at,
        ],
    )?;
    for (kind, cell) in &o.events.0 {
        tx.execute(
            "INSERT INTO owner_events (owner, event, list, notify)
             VALUES (?1, ?2, ?3, ?4)",
            params![o.id, kind.as_str(), cell.list, cell.notify],
        )?;
    }
    Ok(())
}

fn save_pr(tx: &Transaction<'_>, pr: &PrRec) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT OR REPLACE INTO prs
         (key, account, id, owner, repo, number, url, title, author, author_avatar_url, base,
          head, head_oid, state, is_draft, review, checks, base_status, mergeable, failed_check,
          changes_requested_by, updated_at, created_at, my_review_at, last_request_at,
          is_private, requested_me, requested_team, assignees, link_review, link_checks,
          link_base, unreadable, added_at, prev_review, prev_checks, prev_base_status,
          prev_mergeable, settled, settled_head, watch_reset, place_tab, place_section,
          place_rank, closed_at, done_at, keep_after_close, dismissed_at, restored,
          seen_closed, quiet_from, quiet_until, merged_event_at, collected)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17,
                 ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31, ?32,
                 ?33, ?34, ?35, ?36, ?37, ?38, ?39, ?40, ?41, ?42, ?43, ?44, ?45, ?46, ?47,
                 ?48, ?49, ?50, ?51, ?52, ?53, ?54)",
        rusqlite::params_from_iter(pr_params(pr)),
    )?;
    Ok(())
}

fn pr_params(pr: &PrRec) -> Vec<rusqlite::types::Value> {
    use rusqlite::types::Value as V;
    let text = |t: &str| V::Text(t.to_string());
    let opt_text = |t: Option<&str>| t.map_or(V::Null, |t| V::Text(t.to_string()));
    let int = |n: i64| V::Integer(n);
    let opt_int = |n: Option<i64>| n.map_or(V::Null, V::Integer);
    let flag = |b: bool| V::Integer(i64::from(b));
    vec![
        text(&pr.key),
        text(&pr.account),
        text(&pr.id),
        text(&pr.owner),
        text(&pr.repo),
        int(pr.number as i64),
        text(&pr.url),
        text(&pr.title),
        text(&pr.author),
        opt_text(pr.author_avatar_url.as_deref()),
        text(&pr.base),
        text(&pr.head),
        opt_text(pr.head_oid.as_deref()),
        text(pr.state.as_str()),
        flag(pr.is_draft),
        text(pr.review.as_str()),
        text(pr.checks.as_str()),
        text(pr.base_status.as_str()),
        flag(pr.mergeable),
        opt_text(pr.failed_check.as_deref()),
        opt_text(pr.changes_requested_by.as_deref()),
        int(pr.updated_at),
        opt_int(pr.created_at),
        opt_int(pr.my_review_at),
        opt_int(pr.last_request_at),
        flag(pr.is_private),
        flag(pr.requested_me),
        flag(pr.requested_team),
        text(&to_json(&pr.assignees)),
        text(&pr.link_review),
        text(&pr.link_checks),
        text(&pr.link_base),
        flag(pr.unreadable),
        opt_int(pr.added_at),
        opt_text(pr.prev.map(|p| p.review.as_str())),
        opt_text(pr.prev.map(|p| p.checks.as_str())),
        opt_text(pr.prev.map(|p| p.base_status.as_str())),
        pr.prev.map_or(V::Null, |p| flag(p.mergeable)),
        opt_text(pr.settled.map(Checks::as_str)),
        opt_text(pr.settled_head.as_deref()),
        flag(pr.watch_reset),
        opt_text(pr.place.map(|p| p.tab.as_str())),
        opt_text(pr.place.map(|p| p.section.as_str())),
        opt_int(pr.place.map(|p| p.rank)),
        opt_int(pr.closed_at),
        opt_int(pr.done_at),
        flag(pr.keep_after_close),
        opt_int(pr.dismissed_at),
        flag(pr.restored),
        flag(pr.seen_closed),
        opt_int(pr.quiet_from),
        opt_int(pr.quiet_until),
        opt_int(pr.merged_event_at),
        flag(pr.collected),
    ]
}

fn save_row(tx: &Transaction<'_>, row: &RowRec) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT OR REPLACE INTO pr_rows
         (id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id, unread,
          listed, made_at, notify)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        params![
            row.id,
            row.account,
            row.pr,
            row.kind.as_str(),
            row.text,
            row.counts.as_ref().map(counts_text),
            row.actor,
            row.url,
            row.occurred_at,
            row.comment_id,
            row.unread,
            row.listed,
            row.made_at,
            row.notify.as_str(),
        ],
    )?;
    Ok(())
}

fn meta(conn: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    Ok(conn
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| {
            row.get(0)
        })
        .optional()?)
}

fn load(conn: &Connection) -> anyhow::Result<Option<Data>> {
    let Some(seq) = meta(conn, "seq")? else {
        return Ok(None);
    };
    let mut data = Data {
        seq: seq.parse().context("stored seq is not a number")?,
        restore_accounts: meta(conn, "restore_accounts")?.as_deref() == Some("true"),
        ..Data::default()
    };

    let mut statement = conn.prepare("SELECT key, value FROM config")?;
    let pairs = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for pair in pairs {
        let (key, text) = pair?;
        let value: serde_json::Value =
            serde_json::from_str(&text).context("stored setting is not JSON")?;
        crate::engine::write_config(&mut data.config, &key, &value)
            .map_err(anyhow::Error::msg)
            .context("stored setting is not valid")?;
    }

    let mut statement = conn.prepare(
        "SELECT id, login, color, seq, token, updated_at, dot, teams, graphql_limit,
                rest_limit, stopped_until, fetch
         FROM accounts",
    )?;
    let accounts = statement.query_map([], |row| {
        let graphql: Option<String> = row.get(8)?;
        let rest: Option<String> = row.get(9)?;
        Ok(AccountRec {
            id: row.get(0)?,
            login: row.get(1)?,
            color: stored(2, &row.get::<_, String>(2)?, AccountColor::parse)?,
            seq: row.get::<_, i64>(3)? as u64,
            token: from_json(&row.get::<_, String>(4)?)?,
            updated_at: row.get(5)?,
            dot: row.get(6)?,
            teams: from_json(&row.get::<_, String>(7)?)?,
            graphql: graphql.as_deref().map(from_json).transpose()?,
            rest: rest.as_deref().map(from_json).transpose()?,
            stopped_until: row.get(10)?,
            fetch: from_json(&row.get::<_, String>(11)?)?,
            mutes: MuteRec::default(),
        })
    })?;
    for account in accounts {
        let account = account?;
        data.accounts.insert(account.id.clone(), account);
    }
    let mut statement =
        conn.prepare("SELECT account, kind, name FROM mutes ORDER BY account, kind, position")?;
    let mutes = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    for mute in mutes {
        let (account, kind, name) = mute?;
        if let Some(account) = data.accounts.get_mut(&account) {
            match kind.as_str() {
                "repo" => account.mutes.repos.push(name),
                "user" => account.mutes.users.push(name),
                "pr" => account.mutes.prs.push(name),
                other => anyhow::bail!("unknown stored mute kind: {other}"),
            }
        }
    }

    let mut statement = conn.prepare(
        "SELECT id, account, name, kind, github_id, seq, enabled, notify, skip_drafts,
                watch_started_at, fetched_at
         FROM owners",
    )?;
    let owners = statement.query_map([], |row| {
        Ok(OwnerRec {
            id: row.get(0)?,
            account: row.get(1)?,
            name: row.get(2)?,
            kind: stored(3, &row.get::<_, String>(3)?, OwnerKind::parse)?,
            github_id: row.get(4)?,
            seq: row.get::<_, i64>(5)? as u64,
            enabled: row.get(6)?,
            notify: row.get(7)?,
            skip_drafts: row.get(8)?,
            watch_started_at: row.get(9)?,
            fetched_at: row.get(10)?,
            events: EventTable::default(),
        })
    })?;
    for owner in owners {
        let owner = owner?;
        data.owners.insert(owner.id.clone(), owner);
    }
    let mut statement = conn.prepare("SELECT owner, event, list, notify FROM owner_events")?;
    let cells = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            stored(1, &row.get::<_, String>(1)?, EventKind::parse)?,
            Cell {
                list: row.get(2)?,
                notify: row.get(3)?,
            },
        ))
    })?;
    for cell in cells {
        let (owner, kind, cell) = cell?;
        if let Some(owner) = data.owners.get_mut(&owner) {
            owner.events.0.insert(kind, cell);
        }
    }

    let mut statement = conn.prepare(
        "SELECT key, account, id, owner, repo, number, url, title, author, author_avatar_url,
                base, head, head_oid, state, is_draft, review, checks, base_status, mergeable,
                failed_check, changes_requested_by, updated_at, created_at, my_review_at,
                last_request_at, is_private, requested_me, requested_team, assignees,
                link_review, link_checks, link_base, unreadable, added_at, prev_review,
                prev_checks, prev_base_status, prev_mergeable, settled, settled_head,
                watch_reset, place_tab, place_section, place_rank, closed_at, done_at,
                keep_after_close, dismissed_at, restored, seen_closed, quiet_from,
                quiet_until, merged_event_at, collected
         FROM prs",
    )?;
    let prs = statement.query_map([], |row| {
        let prev_review: Option<String> = row.get(34)?;
        let prev_checks: Option<String> = row.get(35)?;
        let prev_base: Option<String> = row.get(36)?;
        let prev_mergeable: Option<bool> = row.get(37)?;
        let prev = match (prev_review, prev_checks, prev_base, prev_mergeable) {
            (Some(review), Some(checks), Some(base), Some(mergeable)) => Some(PrevValues {
                review: stored(34, &review, Review::parse)?,
                checks: stored(35, &checks, Checks::parse)?,
                base_status: stored(36, &base, BaseStatus::parse)?,
                mergeable,
            }),
            _ => None,
        };
        let settled: Option<String> = row.get(38)?;
        let place_tab: Option<String> = row.get(41)?;
        let place_section: Option<String> = row.get(42)?;
        let place_rank: Option<i64> = row.get(43)?;
        let place = match (place_tab, place_section, place_rank) {
            (Some(tab), Some(section), Some(rank)) => Some(PlaceRec {
                tab: stored(41, &tab, PlacedTab::parse)?,
                section: stored(42, &section, Section::parse)?,
                rank,
            }),
            _ => None,
        };
        Ok(PrRec {
            key: row.get(0)?,
            account: row.get(1)?,
            id: row.get(2)?,
            owner: row.get(3)?,
            repo: row.get(4)?,
            number: row.get::<_, i64>(5)? as u64,
            url: row.get(6)?,
            title: row.get(7)?,
            author: row.get(8)?,
            author_avatar_url: row.get(9)?,
            base: row.get(10)?,
            head: row.get(11)?,
            head_oid: row.get(12)?,
            state: stored(13, &row.get::<_, String>(13)?, PrState::parse)?,
            is_draft: row.get(14)?,
            review: stored(15, &row.get::<_, String>(15)?, Review::parse)?,
            checks: stored(16, &row.get::<_, String>(16)?, Checks::parse)?,
            base_status: stored(17, &row.get::<_, String>(17)?, BaseStatus::parse)?,
            mergeable: row.get(18)?,
            failed_check: row.get(19)?,
            changes_requested_by: row.get(20)?,
            updated_at: row.get(21)?,
            created_at: row.get(22)?,
            my_review_at: row.get(23)?,
            last_request_at: row.get(24)?,
            is_private: row.get(25)?,
            requested_me: row.get(26)?,
            requested_team: row.get(27)?,
            assignees: from_json(&row.get::<_, String>(28)?)?,
            link_review: row.get(29)?,
            link_checks: row.get(30)?,
            link_base: row.get(31)?,
            unreadable: row.get(32)?,
            added_at: row.get(33)?,
            prev,
            settled: settled
                .as_deref()
                .map(|s| stored(38, s, Checks::parse))
                .transpose()?,
            settled_head: row.get(39)?,
            watch_reset: row.get(40)?,
            place,
            closed_at: row.get(44)?,
            done_at: row.get(45)?,
            keep_after_close: row.get(46)?,
            dismissed_at: row.get(47)?,
            restored: row.get(48)?,
            seen_closed: row.get(49)?,
            quiet_from: row.get(50)?,
            quiet_until: row.get(51)?,
            merged_event_at: row.get(52)?,
            collected: row.get(53)?,
        })
    })?;
    for pr in prs {
        let pr = pr?;
        data.prs.insert(pr.key.clone(), pr);
    }

    let mut statement = conn.prepare(
        "SELECT id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id, unread,
                listed, made_at, notify
         FROM pr_rows",
    )?;
    let rows = statement.query_map([], |row| {
        let counts: Option<String> = row.get(5)?;
        Ok(RowRec {
            id: row.get(0)?,
            account: row.get(1)?,
            pr: row.get(2)?,
            kind: stored(3, &row.get::<_, String>(3)?, RowKind::parse)?,
            text: row.get(4)?,
            counts: counts.as_deref().map(from_json).transpose()?,
            actor: row.get(6)?,
            url: row.get(7)?,
            occurred_at: row.get(8)?,
            comment_id: row.get(9)?,
            unread: row.get(10)?,
            listed: row.get(11)?,
            made_at: row.get(12)?,
            notify: stored(13, &row.get::<_, String>(13)?, NotifyState::parse)?,
        })
    })?;
    for row in rows {
        let row = row?;
        data.rows.insert(row.id.clone(), row);
    }

    let mut statement = conn.prepare("SELECT id, pr FROM deleted_rows")?;
    let deleted = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for item in deleted {
        let (id, pr) = item?;
        data.deleted_rows.insert(id, pr);
    }

    let mut statement =
        conn.prepare("SELECT key, account, pr_id, owner, updated_at FROM dismiss_records")?;
    let records = statement.query_map([], |row| {
        Ok(DismissRecord {
            key: row.get(0)?,
            account: row.get(1)?,
            pr_id: row.get(2)?,
            owner: row.get(3)?,
            updated_at: row.get(4)?,
        })
    })?;
    for record in records {
        let record = record?;
        data.records.insert(record.key.clone(), record);
    }

    let mut statement = conn.prepare("SELECT key, pr, counts FROM reaction_baselines")?;
    let baselines = statement.query_map([], |row| {
        Ok(Baseline {
            key: row.get(0)?,
            pr: row.get(1)?,
            counts: from_json(&row.get::<_, String>(2)?)?,
        })
    })?;
    for baseline in baselines {
        let baseline = baseline?;
        data.baselines.insert(baseline.key.clone(), baseline);
    }
    Ok(Some(data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_special_characters_stay_part_of_the_path() {
        assert_eq!(
            immutable_uri(Path::new("/a b/c?d#e%f/state.db")),
            "file:///a%20b/c%3Fd%23e%25f/state.db?immutable=1"
        );
        assert_eq!(
            immutable_uri(Path::new("rel/state.db")),
            "file:rel/state.db?immutable=1"
        );
    }
}
