-- The M1 schema (version 1), for the migration test.
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
