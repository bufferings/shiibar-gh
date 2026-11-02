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

/// What the fetcher hands to the daemon core. The fetcher owns classification:
/// `kind` is final, and this type carries nothing that would let the core
/// decide participation, bots or authorship again.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Ingest {
    pub viewer: String,
    pub missing_pr_ids: Vec<String>,
    pub prs: Vec<IngestPr>,
    pub events: Vec<IngestEvent>,
    pub reactions: Vec<IngestReaction>,
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
    pub requested_me: bool,
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
    Subscribe {
        client: ClientKind,
    },
    Reset,
    Info,
    Shutdown,
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
    pub badge: u32,
    pub dot: bool,
    pub warnings: Vec<String>,
    pub updated_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Card {
    pub id: String,
    pub pr: String,
    pub scope: String,
    pub title: String,
    pub url: String,
    pub author: String,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InfoResponse {
    pub ok: bool,
    pub version: String,
    pub started_at: i64,
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
    }
}
