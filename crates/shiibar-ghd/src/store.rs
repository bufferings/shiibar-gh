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

pub const SCHEMA_VERSION: i64 = 1;
const BUSY_TIMEOUT: Duration = Duration::from_secs(2);
const FILE_MODE: u32 = 0o600;
const SIDE_FILES: [&str; 2] = ["-wal", "-shm"];

const SCHEMA_V1: &str = "
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE scopes (
    id TEXT PRIMARY KEY,
    removed INTEGER NOT NULL,
    enabled INTEGER NOT NULL,
    notify INTEGER NOT NULL,
    watch_started_at INTEGER NOT NULL,
    updated_at INTEGER,
    dot INTEGER NOT NULL
);
CREATE TABLE prs (
    id TEXT PRIMARY KEY,
    owner TEXT NOT NULL,
    repo TEXT NOT NULL,
    number INTEGER NOT NULL,
    url TEXT NOT NULL,
    title TEXT NOT NULL,
    author TEXT NOT NULL,
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
    link_review TEXT NOT NULL,
    link_checks TEXT NOT NULL,
    link_base TEXT NOT NULL,
    mine INTEGER NOT NULL,
    unreadable INTEGER NOT NULL,
    snoozed INTEGER NOT NULL,
    added_at INTEGER,
    prev_review TEXT,
    prev_checks TEXT,
    prev_base_status TEXT,
    prev_mergeable INTEGER
);
CREATE TABLE pr_rows (
    id TEXT PRIMARY KEY,
    pr_id TEXT NOT NULL,
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
    notify TEXT NOT NULL
);
CREATE TABLE reaction_baselines (
    comment_id TEXT PRIMARY KEY,
    pr_id TEXT NOT NULL,
    counts TEXT NOT NULL
);
";

/// Migrations by the version they produce.
const MIGRATIONS: [(i64, &str); 1] = [(1, SCHEMA_V1)];

#[derive(Debug)]
pub enum OpenOutcome {
    /// The saved state, or `None` for a database without any.
    Ready(Store, Option<Box<Data>>),
    /// The file is damaged. Nothing was changed.
    Corrupt,
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
fn verify(path: &Path) -> rusqlite::Result<bool> {
    let wal_has_content = std::fs::metadata(side_file(path, "-wal")).is_ok_and(|wal| wal.len() > 0);
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = if wal_has_content {
        Connection::open_with_flags(path, flags)?
    } else {
        Connection::open_with_flags(immutable_uri(path), flags | OpenFlags::SQLITE_OPEN_URI)?
    };
    conn.busy_timeout(BUSY_TIMEOUT)?;
    let result: String = conn.query_row("PRAGMA quick_check(1)", [], |row| row.get(0))?;
    Ok(result == "ok")
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
                Ok(false) => return Ok(OpenOutcome::Corrupt),
                Err(e) if is_corruption(&e) => return Ok(OpenOutcome::Corrupt),
                Err(e) => return Err(e).context("cannot read the database"),
            }
        }

        match Self::open_verified(path) {
            Ok(opened) => Ok(opened),
            Err(e) => match e.downcast_ref::<rusqlite::Error>() {
                Some(sqlite) if is_corruption(sqlite) => Ok(OpenOutcome::Corrupt),
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
        for (target, sql) in MIGRATIONS {
            if target > version {
                tx.execute_batch(sql)?;
                tx.pragma_update(None, "user_version", target)?;
            }
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
            tx.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_release_at', ?1)",
                params![data.last_release_at.to_string()],
            )?;
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
        for id in &dirty.scopes {
            if let Some(scope) = data.scopes.get(id) {
                save_scope(&tx, scope)?;
            }
        }
        for id in &dirty.prs {
            if let Some(pr) = data.prs.get(id) {
                save_pr(&tx, pr)?;
            }
        }
        for id in &dirty.rows {
            if let Some(row) = data.rows.get(id) {
                save_row(&tx, row)?;
            }
        }
        for id in &dirty.baselines {
            match data.baselines.get(id) {
                Some(baseline) => {
                    tx.execute(
                        "INSERT OR REPLACE INTO reaction_baselines (comment_id, pr_id, counts)
                         VALUES (?1, ?2, ?3)",
                        params![
                            baseline.comment_id,
                            baseline.pr_id,
                            counts_text(&baseline.counts)
                        ],
                    )?;
                }
                None => {
                    tx.execute(
                        "DELETE FROM reaction_baselines WHERE comment_id = ?1",
                        params![id],
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

fn parse_counts(text: &str) -> rusqlite::Result<BTreeMap<String, u32>> {
    serde_json::from_str(text).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
    })
}

fn save_scope(tx: &Transaction<'_>, scope: &ScopeRec) -> rusqlite::Result<usize> {
    tx.execute(
        "INSERT OR REPLACE INTO scopes
         (id, removed, enabled, notify, watch_started_at, updated_at, dot)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            scope.id,
            scope.removed,
            scope.enabled,
            scope.notify,
            scope.watch_started_at,
            scope.updated_at,
            scope.dot
        ],
    )
}

fn save_pr(tx: &Transaction<'_>, pr: &PrRec) -> rusqlite::Result<usize> {
    tx.execute(
        "INSERT OR REPLACE INTO prs
         (id, owner, repo, number, url, title, author, base, head, state, is_draft, review,
          checks, base_status, mergeable, failed_check, changes_requested_by, updated_at,
          is_private, requested_me, link_review, link_checks, link_base, mine, unreadable,
          snoozed, added_at, prev_review, prev_checks, prev_base_status, prev_mergeable)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17,
                 ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31)",
        params![
            pr.id,
            pr.owner,
            pr.repo,
            pr.number as i64,
            pr.url,
            pr.title,
            pr.author,
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
            pr.link_review,
            pr.link_checks,
            pr.link_base,
            pr.mine,
            pr.unreadable,
            pr.snoozed,
            pr.added_at,
            pr.prev.map(|p| p.review.as_str()),
            pr.prev.map(|p| p.checks.as_str()),
            pr.prev.map(|p| p.base_status.as_str()),
            pr.prev.map(|p| p.mergeable),
        ],
    )
}

fn save_row(tx: &Transaction<'_>, row: &RowRec) -> rusqlite::Result<usize> {
    tx.execute(
        "INSERT OR REPLACE INTO pr_rows
         (id, pr_id, kind, text, counts, actor, url, occurred_at, comment_id, unread,
          seen_pending, done, pruned, notify)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        params![
            row.id,
            row.pr_id,
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
        ],
    )
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

fn load(conn: &Connection) -> anyhow::Result<Option<Data>> {
    let last_release_at: Option<String> = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'last_release_at'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let Some(last_release_at) = last_release_at else {
        return Ok(None);
    };
    let mut data = Data {
        last_release_at: last_release_at
            .parse()
            .context("stored last_release_at is not a number")?,
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
        "SELECT id, removed, enabled, notify, watch_started_at, updated_at, dot FROM scopes",
    )?;
    let scopes = statement.query_map([], |row| {
        Ok(ScopeRec {
            id: row.get(0)?,
            removed: row.get(1)?,
            enabled: row.get(2)?,
            notify: row.get(3)?,
            watch_started_at: row.get(4)?,
            updated_at: row.get(5)?,
            dot: row.get(6)?,
        })
    })?;
    for scope in scopes {
        let scope = scope?;
        data.scopes.insert(scope.id.clone(), scope);
    }

    let mut statement = conn.prepare(
        "SELECT id, owner, repo, number, url, title, author, base, head, state, is_draft, review,
                checks, base_status, mergeable, failed_check, changes_requested_by, updated_at,
                is_private, requested_me, link_review, link_checks, link_base, mine, unreadable,
                snoozed, added_at, prev_review, prev_checks, prev_base_status, prev_mergeable
         FROM prs",
    )?;
    let prs = statement.query_map([], |row| {
        let prev_review: Option<String> = row.get(27)?;
        let prev_checks: Option<String> = row.get(28)?;
        let prev_base: Option<String> = row.get(29)?;
        let prev_mergeable: Option<bool> = row.get(30)?;
        let prev = match (prev_review, prev_checks, prev_base, prev_mergeable) {
            (Some(review), Some(checks), Some(base), Some(mergeable)) => Some(PrevValues {
                review: stored(27, &review, Review::parse)?,
                checks: stored(28, &checks, Checks::parse)?,
                base_status: stored(29, &base, BaseStatus::parse)?,
                mergeable,
            }),
            _ => None,
        };
        Ok(PrRec {
            id: row.get(0)?,
            owner: row.get(1)?,
            repo: row.get(2)?,
            number: row.get::<_, i64>(3)? as u64,
            url: row.get(4)?,
            title: row.get(5)?,
            author: row.get(6)?,
            base: row.get(7)?,
            head: row.get(8)?,
            state: stored(9, &row.get::<_, String>(9)?, PrState::parse)?,
            is_draft: row.get(10)?,
            review: stored(11, &row.get::<_, String>(11)?, Review::parse)?,
            checks: stored(12, &row.get::<_, String>(12)?, Checks::parse)?,
            base_status: stored(13, &row.get::<_, String>(13)?, BaseStatus::parse)?,
            mergeable: row.get(14)?,
            failed_check: row.get(15)?,
            changes_requested_by: row.get(16)?,
            updated_at: row.get(17)?,
            is_private: row.get(18)?,
            requested_me: row.get(19)?,
            link_review: row.get(20)?,
            link_checks: row.get(21)?,
            link_base: row.get(22)?,
            mine: row.get(23)?,
            unreadable: row.get(24)?,
            snoozed: row.get(25)?,
            added_at: row.get(26)?,
            prev,
        })
    })?;
    for pr in prs {
        let pr = pr?;
        data.prs.insert(pr.id.clone(), pr);
    }

    let mut statement = conn.prepare(
        "SELECT id, pr_id, kind, text, counts, actor, url, occurred_at, comment_id, unread,
                seen_pending, done, pruned, notify
         FROM pr_rows",
    )?;
    let rows = statement.query_map([], |row| {
        let counts: Option<String> = row.get(4)?;
        Ok(RowRec {
            id: row.get(0)?,
            pr_id: row.get(1)?,
            kind: stored(2, &row.get::<_, String>(2)?, RowKind::parse)?,
            text: row.get(3)?,
            counts: counts.as_deref().map(parse_counts).transpose()?,
            actor: row.get(5)?,
            url: row.get(6)?,
            occurred_at: row.get(7)?,
            comment_id: row.get(8)?,
            unread: row.get(9)?,
            seen_pending: row.get(10)?,
            done: row.get(11)?,
            pruned: row.get(12)?,
            notify: stored(13, &row.get::<_, String>(13)?, NotifyState::parse)?,
        })
    })?;
    for row in rows {
        let row = row?;
        data.rows.insert(row.id.clone(), row);
    }

    let mut statement = conn.prepare("SELECT comment_id, pr_id, counts FROM reaction_baselines")?;
    let baselines = statement.query_map([], |row| {
        Ok(Baseline {
            comment_id: row.get(0)?,
            pr_id: row.get(1)?,
            counts: parse_counts(&row.get::<_, String>(2)?)?,
        })
    })?;
    for baseline in baselines {
        let baseline = baseline?;
        data.baselines.insert(baseline.comment_id.clone(), baseline);
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
