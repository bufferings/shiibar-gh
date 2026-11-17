-- The 0.6 schema (version 8), from tag v0.6.0, crates/shiibar-ghd/src/store.rs:
-- SCHEMA_TABLES. 0.7 moves it to version 9 at startup, keeping everything and
-- adding prs.timeline_updated_at and pr_rows.actor_avatar_url, both without a
-- value (DESIGN.md, "Updating from 0.6").
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
    collected INTEGER NOT NULL,
    done_seq INTEGER NOT NULL DEFAULT 0,
    unmuted INTEGER NOT NULL DEFAULT 0
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
PRAGMA user_version = 8;
