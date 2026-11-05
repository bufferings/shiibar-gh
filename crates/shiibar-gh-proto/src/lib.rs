//! Wire format shared by the daemon and its clients: NDJSON over a Unix socket.
//!
//! Spec: docs/DESIGN.md, section "Daemon specification / Wire format", and
//! docs/tasks/M1.md, sections "Injecting events" and "Response fields".
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

/// The `kind` of an ingested event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    ReviewRequested,
    Mentioned,
    Comment,
    Reply,
    AddedToMergeQueue,
    RemovedFromMergeQueue,
    Merged,
    Closed,
    BotComment,
}

/// `row.kind`: every [`EventKind`] plus the rows the daemon derives itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RowKind {
    ReviewRequested,
    Mentioned,
    Comment,
    Reply,
    AddedToMergeQueue,
    RemovedFromMergeQueue,
    Merged,
    Closed,
    BotComment,
    ChecksFailed,
    Conflicts,
    ChangesRequested,
    Mergeable,
    Reaction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RowClass {
    NeedsAction,
    Event,
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
pub enum ScopeKind {
    Org,
    User,
    Public,
}

/// The background color of a scope, one of the six fixed colors of the
/// Settings window. DESIGN.md, "Overview and scope".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScopeColor {
    Gray,
    Green,
    Blue,
    Purple,
    Pink,
    Beige,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WarningKind {
    NoToken,
    TokenInvalid,
    TokenExpiring,
    FetchFailed,
    CostNearCap,
    RateLimited,
    SsoRequired,
    PermissionMissing,
    TokenOwnerMismatch,
    EventsFetchFailed,
}

/// Which token a warning is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenRole {
    Scope,
    Notifications,
}

/// The outcome of one item of `token_test`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TestOutcome {
    /// Answered without a permission error, with or without data.
    Ok,
    /// A permission error. `missing` names the permission.
    Failed,
    /// Nothing to check against, such as an owner without repositories.
    Unverifiable,
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
    Internal,
}

/// Where the three status icons of a card link to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Links {
    pub review: String,
    pub checks: String,
    pub base: String,
}

/// What the fetcher hands to the daemon core, and what `dev_ingest` takes.
/// The fetcher owns classification: `kind` is final, and this type carries
/// nothing that would let the core decide participation, bots or authorship
/// again.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Ingest {
    pub viewer: String,
    pub missing_pr_ids: Vec<String>,
    pub prs: Vec<IngestPr>,
    pub events: Vec<IngestEvent>,
    pub reactions: Vec<IngestReaction>,
    /// Scopes whose search and status fetch finished without errors. Their
    /// `updated_at` moves on even without PRs or events. The fetcher always
    /// sends it; without it the M1 rule applies (only scopes with PRs or
    /// events move on). docs/tasks/M2.md, "Fetcher and core".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub succeeded_scopes: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IngestPr {
    pub id: String,
    pub owner: String,
    pub repo: String,
    pub number: u64,
    pub url: String,
    pub title: String,
    pub author: String,
    /// `author.avatarUrl`; `null` when `author` is `null`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_avatar_url: Option<String>,
    pub base: String,
    pub head: String,
    pub state: PrState,
    pub is_draft: bool,
    pub review: Review,
    pub checks: Checks,
    pub base_status: BaseStatus,
    pub mergeable: bool,
    pub failed_check: Option<String>,
    pub changes_requested_by: Option<String>,
    pub updated_at: i64,
    pub is_private: bool,
    /// A review is requested from the viewer directly.
    pub requested_me: bool,
    /// A review is requested from one of the viewer's teams. Include requests
    /// to my teams is applied by the core.
    #[serde(default)]
    pub requested_team: bool,
    pub links: Links,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IngestEvent {
    pub id: String,
    pub pr_id: String,
    pub kind: EventKind,
    pub occurred_at: i64,
    pub url: String,
    pub actor: Option<String>,
    pub text: Option<String>,
    pub comment_id: Option<String>,
    /// A `review_requested` event addressed to one of the viewer's teams.
    #[serde(default)]
    pub team: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IngestReaction {
    pub comment_id: String,
    pub pr_id: String,
    pub url: String,
    pub text: String,
    pub comment_created_at: i64,
    /// Absolute count per `ReactionContent` value, without the viewer's own.
    pub counts: BTreeMap<String, u32>,
    pub watching: bool,
}

/// A request line. Unknown commands and malformed values fail to decode, and
/// the daemon answers those with `invalid`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Request {
    List {
        #[serde(flatten)]
        filter: Filter,
    },
    Activity {
        #[serde(flatten)]
        filter: Filter,
    },
    Status {
        pr: String,
    },
    Seen {
        row_ids: Vec<String>,
    },
    PopoverOpened {
        scope: String,
    },
    PopoverClosed {
        scope: String,
    },
    Done {
        row: String,
    },
    Undone {
        row: String,
    },
    Snooze {
        pr: String,
    },
    Unsnooze {
        pr: String,
    },
    Refresh {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        scope: Option<String>,
    },
    Open {
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
    ScopeList,
    ScopeAdd {
        owner: String,
    },
    ScopeRemove {
        owner: String,
    },
    ScopeEnable {
        scope: String,
    },
    ScopeDisable {
        scope: String,
    },
    ScopeNotify {
        scope: String,
        on: bool,
    },
    ScopeColor {
        scope: String,
        color: ScopeColor,
    },
    /// The type of an owner on GitHub, without registering anything.
    ScopeLookup {
        owner: String,
    },
    Subscribe {
        client: ClientKind,
    },
    Reset,
    Info,
    Shutdown,
    /// Never logged: it carries a token.
    TokenSet {
        target: String,
        token: String,
    },
    /// Never logged: it may carry a token.
    TokenTest {
        target: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        token: Option<String>,
    },
    SettingsStatus,
    #[cfg(feature = "dev-ingest")]
    DevIngest {
        ingest: Ingest,
    },
    #[cfg(feature = "dev-ingest")]
    DevClockSet {
        now: i64,
        tz: String,
    },
}

/// Arguments shared by `list` and `activity`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Filter {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(default)]
    pub needs_action: bool,
    #[serde(default)]
    pub mine: bool,
    #[serde(default)]
    pub others: bool,
    #[serde(default)]
    pub snoozed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Scope {
    pub id: String,
    pub name: String,
    pub kind: Option<Lenient<ScopeKind>>,
    pub enabled: bool,
    pub notify: bool,
    pub color: Lenient<ScopeColor>,
    pub badge: u32,
    pub dot: bool,
    pub warnings: Vec<Warning>,
    pub updated_at: Option<i64>,
}

/// DESIGN.md, "Wire format": an element of a scope's `warnings` and of the
/// `refresh` response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Warning {
    pub kind: Lenient<WarningKind>,
    /// `null` for a warning about no token, such as a rate limit.
    pub token: Option<Lenient<TokenRole>>,
    pub message: String,
    pub until: Option<i64>,
}

/// One item of a `token_test` result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TestResult {
    /// The item as the Settings board names it, such as `Checks`.
    pub item: String,
    pub outcome: Lenient<TestOutcome>,
    /// The missing permission when `outcome` is `failed`.
    pub missing: Option<String>,
    /// Why, in a few words, when the outcome is not `ok`.
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LastTest {
    pub at: i64,
    pub results: Vec<TestResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiUsage {
    pub rest_remaining: Option<i64>,
    pub rest_limit: Option<i64>,
    pub graphql_remaining: Option<i64>,
    pub graphql_limit: Option<i64>,
    pub cost_per_poll: Option<i64>,
    pub notifications_poll_interval: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenStatus {
    /// `notifications`, `public` or an owner login.
    pub target: String,
    pub registered: bool,
    pub owner: Option<String>,
    pub expires_at: Option<i64>,
    /// The scopes of the classic PAT; `null` for a fine-grained PAT.
    pub scopes: Option<Vec<String>>,
    pub last_test: Option<LastTest>,
    pub sso_urls: Vec<String>,
    /// The warnings about this token itself: `token_invalid`,
    /// `token_expiring`, `sso_required` and, for a scope's token,
    /// `token_owner_mismatch`. Empty for a token not registered.
    #[serde(default)]
    pub warnings: Vec<Warning>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Card {
    pub id: String,
    pub pr: String,
    pub scope: String,
    pub title: String,
    pub url: String,
    pub author: String,
    /// `author.avatarUrl`; `null` when the author is unknown.
    pub author_avatar_url: Option<String>,
    pub mine: bool,
    pub state_label: Lenient<StateLabel>,
    pub review: Lenient<Review>,
    pub checks: Lenient<Checks>,
    pub base_status: Lenient<BaseStatus>,
    pub base: String,
    pub head: String,
    pub snoozed: bool,
    pub snoozed_until: Option<i64>,
    pub added_at: Option<i64>,
    pub links: Links,
    pub rows: Vec<Row>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub id: String,
    pub pr: String,
    pub pr_title: String,
    pub kind: Lenient<RowKind>,
    pub class: Lenient<RowClass>,
    pub text: Option<String>,
    pub counts: Option<BTreeMap<String, u32>>,
    pub actor: Option<String>,
    pub url: String,
    pub occurred_at: i64,
    pub unread: bool,
    pub done: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notification {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: Lenient<NotificationType>,
    pub scope: String,
    pub rows: Vec<String>,
    pub pr: Option<String>,
    pub url: Option<String>,
    pub title: String,
    pub subtitle: Option<String>,
    pub body: Option<String>,
}

/// An event on a `subscribe` connection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum SubscribeEvent {
    Snapshot {
        scopes: Vec<Scope>,
        db_unreadable: bool,
    },
    ScopeChanged {
        scope: Scope,
    },
    Notify {
        notification: Notification,
    },
    /// A setting changed through `config_set`, by any client. `value` is
    /// what `config_get` now answers.
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
pub struct ScopesResponse {
    pub ok: bool,
    pub scopes: Vec<Scope>,
}

/// `scope_lookup`: the owner's login as GitHub spells it and its type,
/// `org` or `user`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScopeLookupResponse {
    pub ok: bool,
    pub owner: String,
    pub kind: Lenient<ScopeKind>,
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
    /// The login the tested token belongs to, when it could be read.
    pub owner: Option<String>,
    /// The owner differs from the owner of the notifications token.
    pub owner_mismatch: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettingsStatusResponse {
    pub ok: bool,
    pub api_usage: ApiUsage,
    pub tokens: Vec<TokenStatus>,
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
        assert!(serde_json::from_str::<EventKind>("\"nope\"").is_err());
        assert!(
            serde_json::from_str::<Request>(r#"{"cmd":"scope_color","scope":"a","color":"red"}"#)
                .is_err()
        );
    }

    #[test]
    fn list_takes_its_filter_at_the_top_level() {
        let request: Request =
            serde_json::from_str(r#"{"cmd":"list","scope":"public","needs_action":true}"#).unwrap();
        assert_eq!(
            request,
            Request::List {
                filter: Filter {
                    scope: Some("public".into()),
                    needs_action: true,
                    ..Filter::default()
                }
            }
        );
    }

    #[test]
    fn the_sample_ingest_in_the_brief_decodes() {
        let ingest: Ingest = serde_json::from_str(
            r#"{"viewer":"me","missing_pr_ids":[],
            "prs":[{"id":"PR_1","owner":"example-org","repo":"app","number":1,"url":"https://github.example/1","title":"Fix","author":"me","base":"main","head":"fix","state":"open","is_draft":false,"review":"none","checks":"failed","base_status":"up_to_date","mergeable":false,"failed_check":"build","changes_requested_by":null,"updated_at":1800000000,"is_private":false,"requested_me":false,"links":{"review":"https://github.example/1/r","checks":"https://github.example/1/c","base":"https://github.example/1/b"}}],
            "events":[{"id":"E_1","pr_id":"PR_1","kind":"comment","occurred_at":1800000000,"url":"https://github.example/1#c","actor":"alice","text":"Looks good","comment_id":"C_1"}],
            "reactions":[{"comment_id":"C_2","pr_id":"PR_1","url":"https://github.example/1#d","text":"Done","comment_created_at":1800000000,"counts":{"THUMBS_UP":2},"watching":true}]}"#,
        )
        .unwrap();
        assert_eq!(ingest.prs[0].checks, Checks::Failed);
        assert_eq!(ingest.events[0].kind, EventKind::Comment);
        assert_eq!(ingest.reactions[0].counts["THUMBS_UP"], 2);
        assert_eq!(ingest.succeeded_scopes, None);
        assert!(!ingest.prs[0].requested_team);
        assert!(!ingest.events[0].team);
    }

    #[test]
    fn a_warning_has_the_shape_of_the_wire_format() {
        let warning = Warning {
            kind: Lenient::Known(WarningKind::RateLimited),
            token: None,
            message: "GraphQL cost cap reached".into(),
            until: Some(1_800_000_000),
        };
        assert_eq!(
            serde_json::to_value(&warning).unwrap(),
            serde_json::json!({"kind":"rate_limited","token":null,
                "message":"GraphQL cost cap reached","until":1800000000})
        );
    }
}
