-- The 0.1 schema (version 3), from tag v0.1.0, crates/shiibar-ghd/src/store.rs:
-- SCHEMA_V1, SCHEMA_V2 and SCHEMA_V3 in order. 0.2 does not read it.
-- SCHEMA_V1
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
-- SCHEMA_V2
ALTER TABLE scopes ADD COLUMN kind TEXT;
ALTER TABLE scopes ADD COLUMN name TEXT;
ALTER TABLE scopes ADD COLUMN fetched_at INTEGER;
ALTER TABLE prs ADD COLUMN requested_team INTEGER NOT NULL DEFAULT 0;
ALTER TABLE prs ADD COLUMN gone_at INTEGER;
ALTER TABLE prs ADD COLUMN collected INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pr_rows ADD COLUMN team INTEGER NOT NULL DEFAULT 0;
CREATE TABLE tokens (
    target TEXT PRIMARY KEY,
    registered INTEGER NOT NULL,
    invalid INTEGER NOT NULL,
    owner TEXT,
    expires_at INTEGER,
    scopes TEXT,
    sso INTEGER NOT NULL,
    sso_urls TEXT NOT NULL,
    last_test TEXT
);
CREATE TABLE pr_ids (key TEXT PRIMARY KEY, pr_id TEXT NOT NULL);
CREATE TABLE own_comments (
    id TEXT PRIMARY KEY,
    pr_id TEXT NOT NULL,
    url TEXT NOT NULL,
    text TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    baseline_done INTEGER NOT NULL
);
CREATE TABLE threads (id TEXT PRIMARY KEY, pr_id TEXT NOT NULL, from_at INTEGER NOT NULL);
CREATE TABLE teams (
    scope TEXT NOT NULL,
    database_id INTEGER NOT NULL,
    slug TEXT NOT NULL,
    PRIMARY KEY (scope, database_id)
);
CREATE TABLE retries (pr_id TEXT PRIMARY KEY, since INTEGER NOT NULL, failures INTEGER NOT NULL);
CREATE TABLE fetch_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
-- SCHEMA_V3
ALTER TABLE scopes ADD COLUMN color TEXT;
ALTER TABLE prs ADD COLUMN author_avatar_url TEXT;
INSERT INTO meta (key, value) VALUES ('last_release_at', '1800000000');
INSERT INTO meta (key, value) VALUES ('color_seq', '0');
PRAGMA user_version = 3;
