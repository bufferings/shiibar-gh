//! Wire format shared by the daemon and its clients: NDJSON over a Unix socket.
//!
//! Spec: docs/DESIGN.md, section "Daemon specification / Wire format", and
//! docs/tasks/M6.md, "Wire format and CLI".
//!
//! Enums a client receives go through [`Lenient`] so a newer daemon's values do
//! not break an older client. `Request` and everything inside it stays strict.
//! These types are never used for storage: the daemon keeps its own.

pub mod codec;
pub mod paths;

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::BTreeMap;

/// A received enum value, or the raw text when this build does not know it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Lenient<T> {
    Known(T),
    Unknown(String),
}

impl<T: Serialize> Serialize for Lenient<T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Lenient::Known(value) => value.serialize(serializer),
            Lenient::Unknown(text) => serializer.serialize_str(text),
        }
    }
}

impl<'de, T: serde::de::DeserializeOwned> Deserialize<'de> for Lenient<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        match serde_json::from_value::<T>(value.clone()) {
            Ok(known) => Ok(Lenient::Known(known)),
            Err(_) => Ok(Lenient::Unknown(match value {
                serde_json::Value::String(text) => text,
                other => other.to_string(),
            })),
        }
    }
}

impl<T: Serialize> Lenient<T> {
    /// The wire text of this value.
    pub fn as_text(&self) -> String {
        match self {
            Lenient::Known(value) => match serde_json::to_value(value) {
                Ok(serde_json::Value::String(text)) => text,
                _ => String::new(),
            },
            Lenient::Unknown(text) => text.clone(),
        }
    }
}

impl<T: PartialEq> Lenient<T> {
    pub fn is(&self, value: T) -> bool {
        matches!(self, Lenient::Known(v) if *v == value)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClientKind {
    App,
    Cli,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrState {
    Open,
    Merged,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Review {
    Approved,
    ReviewRequired,
    ChangesRequested,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Checks {
    Passed,
    InProgress,
    Failed,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BaseStatus {
    UpToDate,
    Behind,
    Conflicts,
    None,
}

/// A kind of the event table of an owner (`owner_events_*`), in table order.
/// DESIGN.md, "Row kinds and states".
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    ReviewRequested,
    TeamReviewRequested,
    Mentioned,
    TeamMentioned,
    Comment,
    CommentOther,
    Reply,
    ReplyMentioned,
    Reaction,
    Approved,
    ChangesRequested,
    ChecksFailed,
    ChecksPassed,
    Conflicts,
    Mergeable,
    MergeQueueAdded,
    MergeQueueRemoved,
    MergedClosed,
    Reopened,
}

impl EventKind {
    pub const ALL: [EventKind; 19] = [
        EventKind::ReviewRequested,
        EventKind::TeamReviewRequested,
        EventKind::Mentioned,
        EventKind::TeamMentioned,
        EventKind::Comment,
        EventKind::CommentOther,
        EventKind::Reply,
        EventKind::ReplyMentioned,
        EventKind::Reaction,
        EventKind::Approved,
        EventKind::ChangesRequested,
        EventKind::ChecksFailed,
        EventKind::ChecksPassed,
        EventKind::Conflicts,
        EventKind::Mergeable,
        EventKind::MergeQueueAdded,
        EventKind::MergeQueueRemoved,
        EventKind::MergedClosed,
        EventKind::Reopened,
    ];
}

/// The `kind` of an event handed to the core by the fetcher or `dev_ingest`.
/// The rows the core derives itself (state changes, reactions) have no
/// ingest kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IngestKind {
    ReviewRequested,
    TeamReviewRequested,
    Mentioned,
    TeamMentioned,
    Comment,
    CommentOther,
    Reply,
    ReplyMentioned,
    Approved,
    MergeQueueAdded,
    MergeQueueRemoved,
    Merged,
    Closed,
    Reopened,
}

/// `row.kind`: the event kinds, with `merged_closed` split in two.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RowKind {
    ReviewRequested,
    TeamReviewRequested,
    Mentioned,
    TeamMentioned,
    Comment,
    CommentOther,
    Reply,
    ReplyMentioned,
    Reaction,
    Approved,
    ChangesRequested,
    ChecksFailed,
    ChecksPassed,
    Conflicts,
    Mergeable,
    MergeQueueAdded,
    MergeQueueRemoved,
    Merged,
    Closed,
    Reopened,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StateLabel {
    Open,
    Draft,
    Mergeable,
    Merged,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OwnerKind {
    Org,
    User,
    Public,
}

/// The color of an account. DESIGN.md, "Account colors".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountColor {
    None,
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
}

/// DESIGN.md, "Showing warnings", in the order of that table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WarningKind {
    KeychainUnavailable,
    TokensUnreadable,
    NoToken,
    TokenInvalid,
    TokenExpiring,
    FetchFailed,
    RateLimited,
    GraphqlNearLimit,
    RestNearLimit,
    ScopeMissing,
    SsoRequired,
    EventsFetchFailed,
    StatusFetchFailed,
}

/// What the daemon could make of the Keychain item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KeychainState {
    Ok,
    Unavailable,
    Unreadable,
}

/// The tab of `list`. DESIGN.md, "Tabs".
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tab {
    #[default]
    All,
    Review,
    Mine,
}

/// Which cards of the Dismissed list `list` gives.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DismissedFilter {
    #[default]
    Exclude,
    Only,
    Include,
}

/// The `tab` of `place`: `none` takes the card out of Review or Mine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaceTab {
    Review,
    Mine,
    None,
}

/// The tab of a card's `placement`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlacedTab {
    Review,
    Mine,
}

/// A section of Review (`doing`, `todo`, `waiting`, `done`) or of Mine
/// (`main`, `done`). DESIGN.md, "Review" and "Mine".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Section {
    Doing,
    Todo,
    Waiting,
    Main,
    Done,
}

/// The `at` of `place`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum At {
    Top,
    Bottom,
}

/// What `mute` and `unmute` name. DESIGN.md, "Mute".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MuteKind {
    Pr,
    Repo,
    User,
}

/// Why a card is muted: the PR, its repository, or its author.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MuteReason {
    Pr,
    Repo,
    Author,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventColumn {
    List,
    Notify,
}

/// The segment of the filter row. DESIGN.md, "What the filters mean".
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrFilter {
    #[default]
    All,
    Authored,
    Assigned,
    ReviewRequested,
}

/// Which item of `token_test` a result is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TestItem {
    Account,
    Scopes,
    Notifications,
    TeamMembership,
    Owner,
}

/// The outcome of one item of `token_test`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TestOutcome {
    /// `✓` (the Account item shows its text without the mark).
    Ok,
    /// `✗`.
    Failed,
    /// `SSO authorization required` with `Authorize…`.
    SsoRequired,
    /// Nothing to check against.
    CantCheck,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationType {
    Single,
    Summary,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    NotFound,
    Invalid,
    Unreachable,
    KeychainUnavailable,
    Internal,
}

/// Where the three status icons of a card link to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Links {
    pub review: String,
    pub checks: String,
    pub base: String,
}

/// What the fetcher hands to the daemon core for one account, and what
/// `dev_ingest` takes. The fetcher owns classification: `kind` is final.
/// PR, event and comment ids are GitHub node ids; the core joins them with
/// the account.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Ingest {
    #[serde(default)]
    pub missing_pr_ids: Vec<String>,
    #[serde(default)]
    pub prs: Vec<IngestPr>,
    #[serde(default)]
    pub events: Vec<IngestEvent>,
    #[serde(default)]
    pub reactions: Vec<IngestReaction>,
    /// Owners (login or `public`) whose search and status fetch finished
    /// without errors: the start of their next event window moves on.
    /// Without it, no owner's window moves on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub succeeded_owners: Option<Vec<String>>,
    /// For an owner of `succeeded_owners` whose success came from running
    /// failed requests again: the start of the first run, which becomes its
    /// success time instead of now (DESIGN.md, "Fetch success and failure").
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub owner_run_started: BTreeMap<String, i64>,
    /// What the owners' searches found, with each PR's `updatedAt` and
    /// state. DESIGN.md, "API usage", the items below the table.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub search: Vec<SearchHit>,
}

/// One PR of a search answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchHit {
    pub id: String,
    /// GraphQL `updatedAt`.
    pub updated_at: i64,
    /// The PR is open (`state` OPEN).
    pub open: bool,
    /// The run fetched the events this PR needed (none when its `updatedAt`
    /// did not move) without an error. Only then does the core move the
    /// `updatedAt` it keeps for a dismissed PR or a Dismiss record on.
    #[serde(default)]
    pub events_fetched: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IngestPr {
    pub id: String,
    /// The repository owner's login. It decides the owner the PR belongs to.
    pub owner: String,
    pub repo: String,
    pub number: u64,
    pub url: String,
    pub title: String,
    pub author: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_avatar_url: Option<String>,
    pub base: String,
    pub head: String,
    /// GraphQL `headRefOid`: the head commit the Checks result is about.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_oid: Option<String>,
    pub state: PrState,
    pub is_draft: bool,
    pub review: Review,
    pub checks: Checks,
    pub base_status: BaseStatus,
    pub mergeable: bool,
    pub failed_check: Option<String>,
    pub changes_requested_by: Option<String>,
    pub updated_at: i64,
    /// GraphQL `createdAt`.
    pub created_at: i64,
    /// The newest review the account submitted, if any (`reviews` of the
    /// PR, author the account). DESIGN.md, "Awaiting review".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub my_review_at: Option<i64>,
    pub is_private: bool,
    /// A review is requested from the account directly.
    pub requested_me: bool,
    /// A review is requested from one of the account's teams.
    #[serde(default)]
    pub requested_team: bool,
    /// Logins of the assignees.
    #[serde(default)]
    pub assignees: Vec<String>,
    pub links: Links,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IngestEvent {
    pub id: String,
    pub pr_id: String,
    pub kind: IngestKind,
    pub occurred_at: i64,
    pub url: String,
    /// Who caused the event; a muted user is compared with it.
    pub actor: Option<String>,
    pub text: Option<String>,
    pub comment_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IngestReaction {
    pub comment_id: String,
    pub pr_id: String,
    pub url: String,
    pub text: String,
    pub comment_created_at: i64,
    /// Absolute count per `ReactionContent` value, without the account's own.
    pub counts: BTreeMap<String, u32>,
    pub watching: bool,
}

/// A request line. Unknown commands and malformed values fail to decode, and
/// the daemon answers those with `invalid`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Request {
    List {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        account: Option<String>,
        #[serde(default)]
        tab: Tab,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        owner: Option<String>,
        #[serde(default)]
        filter: PrFilter,
        /// DESIGN.md, "What the filters mean": every word must match.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        search: Option<String>,
        #[serde(default)]
        dismissed: DismissedFilter,
    },
    Activity {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        account: Option<String>,
        #[serde(default)]
        owners: Vec<String>,
        #[serde(default)]
        filter: PrFilter,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        search: Option<String>,
    },
    Status {
        account: String,
        pr: String,
    },
    Read {
        row_ids: Vec<String>,
    },
    ReadAll {
        account: String,
    },
    PopoverOpened {
        account: String,
    },
    PopoverClosed {
        account: String,
    },
    Place {
        account: String,
        pr: String,
        tab: PlaceTab,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        section: Option<Section>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        at: Option<At>,
    },
    Dismiss {
        account: String,
        pr: String,
    },
    Restore {
        account: String,
        pr: String,
    },
    Mute {
        account: String,
        kind: MuteKind,
        name: String,
    },
    Unmute {
        account: String,
        kind: MuteKind,
        name: String,
    },
    MutesGet {
        account: String,
    },
    Refresh {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        account: Option<String>,
    },
    Open {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        account: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pr: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        row: Option<String>,
    },
    ConfigGet {
        key: String,
    },
    ConfigSet {
        key: String,
        value: serde_json::Value,
    },
    AccountList,
    /// Never logged: it carries a token.
    AccountAdd {
        token: String,
    },
    AccountRemove {
        account: String,
    },
    AccountColor {
        account: String,
        color: AccountColor,
    },
    OwnerLookup {
        account: String,
        owner: String,
    },
    OwnerAdd {
        account: String,
        owner: String,
    },
    OwnerRemove {
        account: String,
        owner: String,
    },
    OwnerEnable {
        account: String,
        owner: String,
    },
    OwnerDisable {
        account: String,
        owner: String,
    },
    OwnerNotify {
        account: String,
        owner: String,
        on: bool,
    },
    OwnerSkipDrafts {
        account: String,
        owner: String,
        on: bool,
    },
    OwnerEventsGet {
        account: String,
        owner: String,
    },
    OwnerEventsSet {
        account: String,
        owner: String,
        event: EventKind,
        column: EventColumn,
        on: bool,
    },
    OwnerEventsCopy {
        account: String,
        from_owner: String,
        to_owner: String,
    },
    /// Never logged: it carries a token.
    TokenSet {
        account: String,
        token: String,
    },
    /// Never logged: it may carry a token.
    TokenTest {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        account: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        token: Option<String>,
    },
    TokenReset,
    Subscribe {
        client: ClientKind,
    },
    Reset,
    Info,
    Shutdown,
    #[cfg(feature = "dev-ingest")]
    DevIngest {
        account: String,
        ingest: Ingest,
    },
    #[cfg(feature = "dev-ingest")]
    DevClockSet {
        now: i64,
        tz: String,
    },
    /// An account without asking GitHub. `token`, when given, is saved to
    /// the Keychain like `token_set`, without the owner check.
    #[cfg(feature = "dev-ingest")]
    DevAccountAdd {
        id: String,
        login: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        token: Option<String>,
    },
    /// An owner without asking GitHub. `kind` `public` adds Public.
    #[cfg(feature = "dev-ingest")]
    DevOwnerAdd {
        account: String,
        owner: String,
        kind: OwnerKind,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        github_id: Option<i64>,
    },
}

/// DESIGN.md, "Wire format": an element of an account's `warnings` and of
/// the `refresh` response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Warning {
    pub kind: Lenient<WarningKind>,
    /// The account id; `null` for the Keychain warnings.
    pub account: Option<String>,
    /// The owner id of `sso_required`, `events_fetch_failed` and
    /// `status_fetch_failed`.
    pub owner: Option<String>,
    pub message: String,
    pub until: Option<i64>,
    pub url: Option<String>,
}

/// One item of a `token_test` result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TestResult {
    pub item: Lenient<TestItem>,
    /// The left column: `Account`, `Scopes`, `Notifications`,
    /// `Team membership`, or the owner's name.
    pub label: String,
    /// The owner id of an `owner` item.
    pub owner: Option<String>,
    pub outcome: Lenient<TestOutcome>,
    /// The right column without the mark: `OK`, `Missing (read:org)`,
    /// `Belongs to octocat`, the account login, ...
    pub text: String,
    /// The SSO authorization URL of `sso_required`, when GitHub gave one.
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LastTest {
    pub at: i64,
    pub results: Vec<TestResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenInfo {
    pub registered: bool,
    pub expires_at: Option<i64>,
    pub last_test: Option<LastTest>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Limit {
    pub used: i64,
    pub limit: i64,
    pub reset_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimit {
    pub graphql: Option<Limit>,
    pub rest: Option<Limit>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Owner {
    pub id: String,
    pub name: String,
    pub kind: Lenient<OwnerKind>,
    pub github_id: Option<i64>,
    pub enabled: bool,
    pub notify: bool,
    pub skip_drafts: bool,
    /// The owner's cards that are not dismissed.
    pub pr_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Account {
    pub id: String,
    pub login: String,
    pub color: Lenient<AccountColor>,
    pub token: TokenInfo,
    pub updated_at: Option<i64>,
    /// The blue dot of the menu bar icon.
    pub unread: bool,
    pub warnings: Vec<Warning>,
    pub rate_limit: Option<RateLimit>,
    pub owners: Vec<Owner>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Card {
    /// Unique across accounts.
    pub id: String,
    pub pr: String,
    pub account: String,
    pub owner: String,
    pub title: String,
    pub url: String,
    pub author: String,
    pub author_avatar_url: Option<String>,
    pub authored_by_me: bool,
    pub assigned_to_me: bool,
    /// GitHub asks the account or one of its teams for a review now
    /// (the `Review requested` filter).
    pub review_requested: bool,
    /// The PR awaits the account's review. DESIGN.md, "Awaiting review".
    pub awaiting_review: bool,
    pub state_label: Lenient<StateLabel>,
    pub review: Lenient<Review>,
    pub checks: Lenient<Checks>,
    pub base_status: Lenient<BaseStatus>,
    pub base: String,
    pub head: String,
    pub added_at: Option<i64>,
    /// GraphQL `createdAt`.
    pub created_at: Option<i64>,
    /// GraphQL `updatedAt`.
    pub updated_at: i64,
    /// Review or Mine, with the section and the position the daemon works
    /// out; `null` when the PR is in neither.
    pub placement: Option<Placement>,
    /// Why the card is muted; empty when it is not.
    pub muted: Vec<Lenient<MuteReason>>,
    pub dismissed_at: Option<i64>,
    /// When the card leaves the Dismissed list.
    pub dismiss_expires_at: Option<i64>,
    /// When the automatic Dismiss of the card is due; `null` when none is
    /// scheduled (DESIGN.md, "Dismiss").
    #[serde(default)]
    pub auto_dismiss_at: Option<i64>,
    /// Rows of the PR were deleted (DESIGN.md, "Rows in a card").
    pub older_rows: bool,
    pub links: Links,
    /// Every row kept, newest first, at most 20.
    pub rows: Vec<Row>,
}

/// DESIGN.md, "Wire format": `position` counts from 0 in the section's
/// order, muted cards last.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Placement {
    pub tab: Lenient<PlacedTab>,
    pub section: Lenient<Section>,
    pub position: u32,
}

/// `{"repos":[...],"users":[...],"prs":[...]}`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mutes {
    pub repos: Vec<String>,
    pub users: Vec<String>,
    pub prs: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    /// Unique across accounts.
    pub id: String,
    pub pr: String,
    pub pr_title: String,
    pub account: String,
    pub owner: String,
    pub kind: Lenient<RowKind>,
    pub text: Option<String>,
    pub counts: Option<BTreeMap<String, u32>>,
    pub actor: Option<String>,
    pub url: String,
    pub occurred_at: i64,
    pub unread: bool,
    /// The row is muted: its unread mark is a gray ring.
    pub muted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notification {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: Lenient<NotificationType>,
    pub account: String,
    pub owner: String,
    pub rows: Vec<String>,
    pub pr: Option<String>,
    pub url: Option<String>,
    pub title: String,
    pub subtitle: Option<String>,
    pub body: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventCell {
    pub list: bool,
    pub notify: bool,
}

/// An event on a `subscribe` connection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum SubscribeEvent {
    Snapshot {
        accounts: Vec<Account>,
        keychain: Lenient<KeychainState>,
        db_unreadable: bool,
    },
    AccountChanged {
        account: Account,
    },
    AccountRemoved {
        id: String,
    },
    KeychainChanged {
        keychain: Lenient<KeychainState>,
    },
    Notify {
        notification: Notification,
    },
    ConfigChanged {
        key: String,
        value: serde_json::Value,
    },
    /// An event this build does not know. Clients ignore it.
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AckResponse {
    pub ok: bool,
}

impl AckResponse {
    pub fn new() -> Self {
        Self { ok: true }
    }
}

impl Default for AckResponse {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListResponse {
    pub ok: bool,
    pub cards: Vec<Card>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivityResponse {
    pub ok: bool,
    pub rows: Vec<Row>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusResponse {
    pub ok: bool,
    pub card: Card,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenResponse {
    pub ok: bool,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigResponse {
    pub ok: bool,
    pub value: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountsResponse {
    pub ok: bool,
    pub accounts: Vec<Account>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountResponse {
    pub ok: bool,
    pub account: Account,
}

/// `owner_lookup`: the owner's login as GitHub spells it, `org` or `user`,
/// and the numeric id of `GET /users/{owner}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnerLookupResponse {
    pub ok: bool,
    pub owner: String,
    pub kind: Lenient<OwnerKind>,
    pub id: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventsResponse {
    pub ok: bool,
    pub events: BTreeMap<String, EventCell>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MutesResponse {
    pub ok: bool,
    pub mutes: Mutes,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InfoResponse {
    pub ok: bool,
    pub version: String,
    pub started_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RefreshResponse {
    pub ok: bool,
    pub warnings: Vec<Warning>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenTestResponse {
    pub ok: bool,
    pub results: Vec<TestResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorResponse {
    pub ok: bool,
    pub code: Lenient<ErrorCode>,
    pub error: String,
}

impl ErrorResponse {
    pub fn new(code: ErrorCode, error: impl Into<String>) -> Self {
        Self {
            ok: false,
            code: Lenient::Known(code),
            error: error.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_client_keeps_unknown_enum_values() {
        let review: Lenient<Review> = serde_json::from_str("\"future_value\"").unwrap();
        assert_eq!(review, Lenient::Unknown("future_value".into()));
        assert_eq!(serde_json::to_string(&review).unwrap(), "\"future_value\"");
    }

    #[test]
    fn a_client_ignores_unknown_events() {
        let event: SubscribeEvent = serde_json::from_str(r#"{"event":"later","x":1}"#).unwrap();
        assert_eq!(event, SubscribeEvent::Unknown);
    }

    #[test]
    fn a_request_rejects_unknown_values() {
        assert!(serde_json::from_str::<Request>(r#"{"cmd":"nope"}"#).is_err());
        assert!(serde_json::from_str::<Request>(r#"{"cmd":"subscribe"}"#).is_err());
        assert!(
            serde_json::from_str::<Request>(r#"{"cmd":"subscribe","client":"other"}"#).is_err()
        );
        assert!(serde_json::from_str::<IngestKind>("\"bot_comment\"").is_err());
        assert!(
            serde_json::from_str::<Request>(
                r#"{"cmd":"account_color","account":"a","color":"pink"}"#
            )
            .is_err()
        );
        assert!(serde_json::from_str::<Request>(r#"{"cmd":"list","filter":"mine"}"#).is_err());
        for removed in [
            r#"{"cmd":"seen","row_ids":[]}"#,
            r#"{"cmd":"done","row":"r","on":true}"#,
            r#"{"cmd":"todo","row":"r","on":true}"#,
            r#"{"cmd":"owner_events_set","account":"a","owner":"o","event":"mentioned","column":"todo","on":true}"#,
            r#"{"cmd":"snooze","account":"a","pr":"o/r#1"}"#,
            r#"{"cmd":"unsnooze","account":"a","pr":"o/r#1"}"#,
            r#"{"cmd":"owner_exclusions_get","account":"a","owner":"o"}"#,
            r#"{"cmd":"place","account":"a","pr":"o/r#1","tab":"review","section":"side"}"#,
            r#"{"cmd":"place","account":"a","pr":"o/r#1","tab":"done"}"#,
            r#"{"cmd":"list","dismissed":"some"}"#,
            r#"{"cmd":"mute","account":"a","kind":"team","name":"x"}"#,
        ] {
            assert!(
                serde_json::from_str::<Request>(removed).is_err(),
                "{removed}"
            );
        }
    }

    #[test]
    fn list_takes_its_filter_at_the_top_level() {
        let request: Request = serde_json::from_str(
            r#"{"cmd":"list","account":"me","owner":"public","filter":"review_requested","search":"api #407"}"#,
        )
        .unwrap();
        assert_eq!(
            request,
            Request::List {
                account: Some("me".into()),
                tab: Tab::All,
                owner: Some("public".into()),
                filter: PrFilter::ReviewRequested,
                search: Some("api #407".into()),
                dismissed: DismissedFilter::Exclude,
            }
        );
    }

    #[test]
    fn place_takes_a_section_and_a_position() {
        let request: Request = serde_json::from_str(
            r#"{"cmd":"place","account":"me","pr":"o/r#1","tab":"review","section":"todo","before":"o/r#2"}"#,
        )
        .unwrap();
        assert_eq!(
            request,
            Request::Place {
                account: "me".into(),
                pr: "o/r#1".into(),
                tab: PlaceTab::Review,
                section: Some(Section::Todo),
                before: Some("o/r#2".into()),
                at: None,
            }
        );
        let request: Request =
            serde_json::from_str(r#"{"cmd":"list","tab":"mine","dismissed":"include"}"#).unwrap();
        assert!(matches!(
            request,
            Request::List {
                tab: Tab::Mine,
                dismissed: DismissedFilter::Include,
                ..
            }
        ));
    }

    #[test]
    fn the_event_kinds_are_the_wire_values() {
        let names: Vec<String> = EventKind::ALL
            .iter()
            .map(|k| Lenient::Known(*k).as_text())
            .collect();
        assert_eq!(
            names,
            [
                "review_requested",
                "team_review_requested",
                "mentioned",
                "team_mentioned",
                "comment",
                "comment_other",
                "reply",
                "reply_mentioned",
                "reaction",
                "approved",
                "changes_requested",
                "checks_failed",
                "checks_passed",
                "conflicts",
                "mergeable",
                "merge_queue_added",
                "merge_queue_removed",
                "merged_closed",
                "reopened"
            ]
        );
    }

    #[test]
    fn a_warning_has_the_shape_of_the_wire_format() {
        let warning = Warning {
            kind: Lenient::Known(WarningKind::RateLimited),
            account: Some("2001".into()),
            owner: None,
            message: "Polling paused until 14:05 · GitHub's limit reached".into(),
            until: Some(1_800_000_000),
            url: None,
        };
        assert_eq!(
            serde_json::to_value(&warning).unwrap(),
            serde_json::json!({"kind":"rate_limited","account":"2001","owner":null,
                "message":"Polling paused until 14:05 · GitHub's limit reached",
                "until":1800000000,"url":null})
        );
    }
}
