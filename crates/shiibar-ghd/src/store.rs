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

/// M4 (0.2). Versions 1 to 3 are the 0.1 schema, which is not migrated: such
/// a database is treated like an unreadable one (DESIGN.md, "Saved state").
pub const SCHEMA_VERSION: i64 = 4;
/// The newest version of the 0.1 schema.
const LAST_V01_VERSION: i64 = 3;
const BUSY_TIMEOUT: Duration = Duration::from_secs(2);
const FILE_MODE: u32 = 0o600;
const SIDE_FILES: [&str; 2] = ["-wal", "-shm"];

const SCHEMA_V4: &str = "
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
    todo INTEGER NOT NULL,
    notify INTEGER NOT NULL,
    PRIMARY KEY (owner, event)
);
CREATE TABLE exclusions (
    owner TEXT NOT NULL,
    kind TEXT NOT NULL,
    position INTEGER NOT NULL,
    name TEXT NOT NULL,
    state TEXT NOT NULL,
    PRIMARY KEY (owner, kind, position)
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
    state TEXT NOT NULL,
    is_draft INTEGER NOT NULL,
    review TEXT NOT NULL,
    checks TEXT NOT NULL,
    base_status TEXT NOT NULL,
    mergeable INTEGER NOT NULL,
    failed_check TEXT,
    changes_requested_by TEXT,
    updated_at INTEGER NOT NULL,
    is_private INTEGER NOT NULL,
    requested_me INTEGER NOT NULL,
    requested_team INTEGER NOT NULL,
    assignees TEXT NOT NULL,
    link_review TEXT NOT NULL,
    link_checks TEXT NOT NULL,
    link_base TEXT NOT NULL,
    unreadable INTEGER NOT NULL,
    snoozed INTEGER NOT NULL,
    added_at INTEGER,
    prev_review TEXT,
    prev_checks TEXT,
    prev_base_status TEXT,
    prev_mergeable INTEGER,
    gone_at INTEGER,
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
    seen_pending INTEGER NOT NULL,
    done INTEGER NOT NULL,
    pruned INTEGER NOT NULL,
    notify TEXT NOT NULL,
    todo_auto INTEGER NOT NULL,
    todo_manual INTEGER
);
CREATE TABLE reaction_baselines (
    key TEXT PRIMARY KEY,
    pr TEXT NOT NULL,
    counts TEXT NOT NULL
);
";

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
            tx.execute_batch(SCHEMA_V4)?;
            tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        }
        tx.commit()?;

        restrict_side_files(path).context("cannot set the database side file mode")?;
        let data = load(&conn)?.map(Box::new);
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
                ("last_release_at", data.last_release_at.to_string()),
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
            match data.accounts.get(id) {
                Some(account) => save_account(&tx, account)?,
                None => {
                    tx.execute("DELETE FROM accounts WHERE id = ?1", params![id])?;
                }
            }
        }
        for id in &dirty.owners {
            tx.execute("DELETE FROM owner_events WHERE owner = ?1", params![id])?;
            tx.execute("DELETE FROM exclusions WHERE owner = ?1", params![id])?;
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
            "INSERT INTO owner_events (owner, event, list, todo, notify)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![o.id, kind.as_str(), cell.list, cell.todo, cell.notify],
        )?;
    }
    for (kind, list) in [("repo", &o.repos), ("user", &o.users)] {
        for (position, item) in list.iter().enumerate() {
            tx.execute(
                "INSERT INTO exclusions (owner, kind, position, name, state)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![o.id, kind, position as i64, item.name, item.state.as_str()],
            )?;
        }
    }
    Ok(())
}

fn save_pr(tx: &Transaction<'_>, pr: &PrRec) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT OR REPLACE INTO prs
         (key, account, id, owner, repo, number, url, title, author, author_avatar_url, base,
          head, state, is_draft, review, checks, base_status, mergeable, failed_check,
          changes_requested_by, updated_at, is_private, requested_me, requested_team,
          assignees, link_review, link_checks, link_base, unreadable, snoozed, added_at,
          prev_review, prev_checks, prev_base_status, prev_mergeable, gone_at, collected)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17,
                 ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31, ?32,
                 ?33, ?34, ?35, ?36, ?37)",
        params![
            pr.key,
            pr.account,
            pr.id,
            pr.owner,
            pr.repo,
            pr.number as i64,
            pr.url,
            pr.title,
            pr.author,
            pr.author_avatar_url,
            pr.base,
            pr.head,
            pr.state.as_str(),
            pr.is_draft,
            pr.review.as_str(),
            pr.checks.as_str(),
            pr.base_status.as_str(),
            pr.mergeable,
            pr.failed_check,
            pr.changes_requested_by,
            pr.updated_at,
            pr.is_private,
            pr.requested_me,
            pr.requested_team,
            to_json(&pr.assignees),
            pr.link_review,
            pr.link_checks,
            pr.link_base,
            pr.unreadable,
            pr.snoozed,
            pr.added_at,
            pr.prev.map(|p| p.review.as_str()),
            pr.prev.map(|p| p.checks.as_str()),
            pr.prev.map(|p| p.base_status.as_str()),
            pr.prev.map(|p| p.mergeable),
            pr.gone_at,
            pr.collected,
        ],
    )?;
    Ok(())
}

fn save_row(tx: &Transaction<'_>, row: &RowRec) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT OR REPLACE INTO pr_rows
         (id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id, unread,
          seen_pending, done, pruned, notify, todo_auto, todo_manual)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)",
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
            row.seen_pending,
            row.done,
            row.pruned,
            row.notify.as_str(),
            row.todo_auto,
            row.todo_manual,
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
    let Some(last_release_at) = meta(conn, "last_release_at")? else {
        return Ok(None);
    };
    let mut data = Data {
        last_release_at: last_release_at
            .parse()
            .context("stored last_release_at is not a number")?,
        seq: meta(conn, "seq")?
            .map(|text| text.parse())
            .transpose()
            .context("stored seq is not a number")?
            .unwrap_or(0),
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
        })
    })?;
    for account in accounts {
        let account = account?;
        data.accounts.insert(account.id.clone(), account);
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
            repos: Vec::new(),
            users: Vec::new(),
        })
    })?;
    for owner in owners {
        let owner = owner?;
        data.owners.insert(owner.id.clone(), owner);
    }
    let mut statement =
        conn.prepare("SELECT owner, event, list, todo, notify FROM owner_events")?;
    let cells = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            stored(1, &row.get::<_, String>(1)?, EventKind::parse)?,
            Cell {
                list: row.get(2)?,
                todo: row.get(3)?,
                notify: row.get(4)?,
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
        "SELECT owner, kind, name, state FROM exclusions ORDER BY owner, kind, position",
    )?;
    let items = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            ExclusionRec {
                name: row.get(2)?,
                state: stored(3, &row.get::<_, String>(3)?, ExclusionState::parse)?,
            },
        ))
    })?;
    for item in items {
        let (owner, kind, item) = item?;
        if let Some(owner) = data.owners.get_mut(&owner) {
            match kind.as_str() {
                "repo" => owner.repos.push(item),
                "user" => owner.users.push(item),
                other => anyhow::bail!("unknown stored exclusion kind: {other}"),
            }
        }
    }

    let mut statement = conn.prepare(
        "SELECT key, account, id, owner, repo, number, url, title, author, author_avatar_url,
                base, head, state, is_draft, review, checks, base_status, mergeable,
                failed_check, changes_requested_by, updated_at, is_private, requested_me,
                requested_team, assignees, link_review, link_checks, link_base, unreadable,
                snoozed, added_at, prev_review, prev_checks, prev_base_status, prev_mergeable,
                gone_at, collected
         FROM prs",
    )?;
    let prs = statement.query_map([], |row| {
        let prev_review: Option<String> = row.get(31)?;
        let prev_checks: Option<String> = row.get(32)?;
        let prev_base: Option<String> = row.get(33)?;
        let prev_mergeable: Option<bool> = row.get(34)?;
        let prev = match (prev_review, prev_checks, prev_base, prev_mergeable) {
            (Some(review), Some(checks), Some(base), Some(mergeable)) => Some(PrevValues {
                review: stored(31, &review, Review::parse)?,
                checks: stored(32, &checks, Checks::parse)?,
                base_status: stored(33, &base, BaseStatus::parse)?,
                mergeable,
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
            state: stored(12, &row.get::<_, String>(12)?, PrState::parse)?,
            is_draft: row.get(13)?,
            review: stored(14, &row.get::<_, String>(14)?, Review::parse)?,
            checks: stored(15, &row.get::<_, String>(15)?, Checks::parse)?,
            base_status: stored(16, &row.get::<_, String>(16)?, BaseStatus::parse)?,
            mergeable: row.get(17)?,
            failed_check: row.get(18)?,
            changes_requested_by: row.get(19)?,
            updated_at: row.get(20)?,
            is_private: row.get(21)?,
            requested_me: row.get(22)?,
            requested_team: row.get(23)?,
            assignees: from_json(&row.get::<_, String>(24)?)?,
            link_review: row.get(25)?,
            link_checks: row.get(26)?,
            link_base: row.get(27)?,
            unreadable: row.get(28)?,
            snoozed: row.get(29)?,
            added_at: row.get(30)?,
            prev,
            gone_at: row.get(35)?,
            collected: row.get(36)?,
        })
    })?;
    for pr in prs {
        let pr = pr?;
        data.prs.insert(pr.key.clone(), pr);
    }

    let mut statement = conn.prepare(
        "SELECT id, account, pr, kind, text, counts, actor, url, occurred_at, comment_id, unread,
                seen_pending, done, pruned, notify, todo_auto, todo_manual
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
            seen_pending: row.get(11)?,
            done: row.get(12)?,
            pruned: row.get(13)?,
            notify: stored(14, &row.get::<_, String>(14)?, NotifyState::parse)?,
            todo_auto: row.get(15)?,
            todo_manual: row.get(16)?,
        })
    })?;
    for row in rows {
        let row = row?;
        data.rows.insert(row.id.clone(), row);
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
