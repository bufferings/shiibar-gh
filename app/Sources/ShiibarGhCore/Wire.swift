// The daemon's NDJSON wire format as the app reads it (docs/DESIGN.md,
// "Wire format"; docs/tasks/M1.md, "Response fields"). Unknown fields are
// ignored by `Decodable`, unknown enum values are kept as `Lenient.unknown`
// and unknown events decode as `SubscribeEvent.unknown`, so a newer daemon
// never breaks this client.

import Foundation

/// A received enum value, or the raw text when this build does not know it.
public enum Lenient<Value: RawRepresentable & Equatable>: Equatable, Decodable
where Value.RawValue == String {
    case known(Value)
    case unknown(String)

    public init(_ value: Value) {
        self = .known(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = (try? container.decode(String.self)) ?? ""
        if let value = Value(rawValue: text) {
            self = .known(value)
        } else {
            self = .unknown(text)
        }
    }

    public var value: Value? {
        if case .known(let value) = self { return value }
        return nil
    }

    public var rawText: String {
        switch self {
        case .known(let value): return value.rawValue
        case .unknown(let text): return text
        }
    }
}

public enum ScopeKind: String, Equatable { case org, user, `public` }

public enum ScopeColor: String, Equatable, CaseIterable {
    case gray, green, blue, purple, pink, beige
}

public enum WarningKind: String, Equatable {
    case noToken = "no_token"
    case tokenInvalid = "token_invalid"
    case tokenExpiring = "token_expiring"
    case fetchFailed = "fetch_failed"
    case costNearCap = "cost_near_cap"
    case rateLimited = "rate_limited"
    case ssoRequired = "sso_required"
    case permissionMissing = "permission_missing"
    case tokenOwnerMismatch = "token_owner_mismatch"
    case eventsFetchFailed = "events_fetch_failed"
}

public enum TokenRole: String, Equatable { case scope, notifications }

public enum StateLabel: String, Equatable { case open, draft, mergeable, merged, closed }

public enum ReviewStatus: String, Equatable {
    case approved, reviewRequired = "review_required", changesRequested = "changes_requested", none
}

public enum ChecksStatus: String, Equatable {
    case passed, inProgress = "in_progress", failed, none
}

public enum BaseStatus: String, Equatable {
    case upToDate = "up_to_date", behind, conflicts, none
}

public enum RowKind: String, Equatable {
    case reviewRequested = "review_requested"
    case mentioned
    case comment
    case reply
    case addedToMergeQueue = "added_to_merge_queue"
    case removedFromMergeQueue = "removed_from_merge_queue"
    case merged
    case closed
    case botComment = "bot_comment"
    case checksFailed = "checks_failed"
    case conflicts
    case changesRequested = "changes_requested"
    case mergeable
    case reaction
}

public enum RowClass: String, Equatable { case needsAction = "needs_action", event }

public enum NotificationType: String, Equatable { case single, summary }

public enum TestOutcome: String, Equatable { case ok, failed, unverifiable }

public enum ErrorCode: String, Equatable { case notFound = "not_found", invalid, `internal` }

public struct Warning: Equatable, Decodable {
    public var kind: Lenient<WarningKind>
    public var token: Lenient<TokenRole>?
    public var message: String
    public var until: Int64?

    public init(kind: WarningKind, token: TokenRole? = nil, message: String = "", until: Int64? = nil) {
        self.kind = .known(kind)
        self.token = token.map(Lenient.known)
        self.message = message
        self.until = until
    }
}

public struct Scope: Equatable, Decodable, Identifiable {
    public var id: String
    public var name: String
    public var kind: Lenient<ScopeKind>?
    public var enabled: Bool
    public var notify: Bool
    public var color: Lenient<ScopeColor>?
    public var badge: Int
    public var dot: Bool
    public var warnings: [Warning]
    public var updatedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, notify, color, badge, dot, warnings
        case updatedAt = "updated_at"
    }

    public init(
        id: String, name: String? = nil, kind: ScopeKind? = nil, enabled: Bool = true,
        notify: Bool = true, color: ScopeColor? = nil, badge: Int = 0, dot: Bool = false,
        warnings: [Warning] = [], updatedAt: Int64? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.kind = kind.map(Lenient.known)
        self.enabled = enabled
        self.notify = notify
        self.color = color.map(Lenient.known)
        self.badge = badge
        self.dot = dot
        self.warnings = warnings
        self.updatedAt = updatedAt
    }

    /// Public is told by its kind. The id is an opaque identifier that is
    /// never read as an owner login (docs/tasks/M3.md, "Socket client").
    public var isPublic: Bool { kind?.value == .public }
}

public struct Links: Equatable, Decodable {
    public var review: String
    public var checks: String
    public var base: String

    public init(review: String, checks: String, base: String) {
        self.review = review
        self.checks = checks
        self.base = base
    }
}

public struct Row: Equatable, Decodable, Identifiable {
    public var id: String
    public var pr: String
    public var prTitle: String
    public var kind: Lenient<RowKind>
    public var rowClass: Lenient<RowClass>
    public var text: String?
    public var counts: [String: Int]?
    public var actor: String?
    public var url: String
    public var occurredAt: Int64
    public var unread: Bool
    public var done: Bool

    enum CodingKeys: String, CodingKey {
        case id, pr, kind, text, counts, actor, url, unread, done
        case prTitle = "pr_title"
        case rowClass = "class"
        case occurredAt = "occurred_at"
    }

    public init(
        id: String, pr: String = "o/r#1", prTitle: String = "Title", kind: RowKind,
        rowClass: RowClass, text: String? = nil, counts: [String: Int]? = nil,
        actor: String? = nil, url: String = "https://github.com/o/r/pull/1",
        occurredAt: Int64 = 0, unread: Bool = true, done: Bool = false
    ) {
        self.id = id
        self.pr = pr
        self.prTitle = prTitle
        self.kind = .known(kind)
        self.rowClass = .known(rowClass)
        self.text = text
        self.counts = counts
        self.actor = actor
        self.url = url
        self.occurredAt = occurredAt
        self.unread = unread
        self.done = done
    }

    public var isNeedsAction: Bool { rowClass.value == .needsAction }
}

public struct Card: Equatable, Decodable, Identifiable {
    public var id: String
    public var pr: String
    public var scope: String
    public var title: String
    public var url: String
    public var author: String
    public var authorAvatarUrl: String?
    public var mine: Bool
    public var stateLabel: Lenient<StateLabel>
    public var review: Lenient<ReviewStatus>
    public var checks: Lenient<ChecksStatus>
    public var baseStatus: Lenient<BaseStatus>
    public var base: String
    public var head: String
    public var snoozed: Bool
    public var snoozedUntil: Int64?
    public var addedAt: Int64?
    public var links: Links
    public var rows: [Row]

    enum CodingKeys: String, CodingKey {
        case id, pr, scope, title, url, author, mine, review, checks, base, head, snoozed
        case links, rows
        case authorAvatarUrl = "author_avatar_url"
        case stateLabel = "state_label"
        case baseStatus = "base_status"
        case snoozedUntil = "snoozed_until"
        case addedAt = "added_at"
    }

    public init(
        id: String, pr: String = "o/r#1", scope: String = "o", title: String = "Title",
        url: String = "https://github.com/o/r/pull/1", author: String = "me",
        authorAvatarUrl: String? = nil, mine: Bool = true, stateLabel: StateLabel = .open,
        review: ReviewStatus = .none, checks: ChecksStatus = .none, baseStatus: BaseStatus = .none,
        base: String = "main", head: String = "topic", snoozed: Bool = false,
        snoozedUntil: Int64? = nil, addedAt: Int64? = nil,
        links: Links = Links(review: "r", checks: "c", base: "b"), rows: [Row] = []
    ) {
        self.id = id
        self.pr = pr
        self.scope = scope
        self.title = title
        self.url = url
        self.author = author
        self.authorAvatarUrl = authorAvatarUrl
        self.mine = mine
        self.stateLabel = .known(stateLabel)
        self.review = .known(review)
        self.checks = .known(checks)
        self.baseStatus = .known(baseStatus)
        self.base = base
        self.head = head
        self.snoozed = snoozed
        self.snoozedUntil = snoozedUntil
        self.addedAt = addedAt
        self.links = links
        self.rows = rows
    }
}

public struct DaemonNotification: Equatable, Decodable {
    public var id: String
    public var type: Lenient<NotificationType>
    public var scope: String
    public var rows: [String]
    public var pr: String?
    public var url: String?
    public var title: String
    public var subtitle: String?
    public var body: String?

    public init(
        id: String, type: NotificationType, scope: String, rows: [String] = [], pr: String? = nil,
        url: String? = nil, title: String, subtitle: String? = nil, body: String? = nil
    ) {
        self.id = id
        self.type = .known(type)
        self.scope = scope
        self.rows = rows
        self.pr = pr
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

public struct TestResult: Equatable, Decodable {
    public var item: String
    public var outcome: Lenient<TestOutcome>
    public var missing: String?
    public var reason: String?

    public init(item: String, outcome: TestOutcome, missing: String? = nil, reason: String? = nil) {
        self.item = item
        self.outcome = .known(outcome)
        self.missing = missing
        self.reason = reason
    }
}

public struct LastTest: Equatable, Decodable {
    public var at: Int64
    public var results: [TestResult]

    public init(at: Int64, results: [TestResult]) {
        self.at = at
        self.results = results
    }
}

public struct ApiUsage: Equatable, Decodable {
    public var restRemaining: Int64?
    public var restLimit: Int64?
    public var graphqlRemaining: Int64?
    public var graphqlLimit: Int64?
    public var costPerPoll: Int64?
    public var notificationsPollInterval: Int64?

    enum CodingKeys: String, CodingKey {
        case restRemaining = "rest_remaining"
        case restLimit = "rest_limit"
        case graphqlRemaining = "graphql_remaining"
        case graphqlLimit = "graphql_limit"
        case costPerPoll = "cost_per_poll"
        case notificationsPollInterval = "notifications_poll_interval"
    }

    public init(
        restRemaining: Int64? = nil, restLimit: Int64? = nil, graphqlRemaining: Int64? = nil,
        graphqlLimit: Int64? = nil, costPerPoll: Int64? = nil, notificationsPollInterval: Int64? = nil
    ) {
        self.restRemaining = restRemaining
        self.restLimit = restLimit
        self.graphqlRemaining = graphqlRemaining
        self.graphqlLimit = graphqlLimit
        self.costPerPoll = costPerPoll
        self.notificationsPollInterval = notificationsPollInterval
    }
}

public struct TokenStatus: Equatable, Decodable {
    public var target: String
    public var registered: Bool
    public var owner: String?
    public var expiresAt: Int64?
    public var scopes: [String]?
    public var lastTest: LastTest?
    public var ssoUrls: [String]
    /// The warnings about this token itself (DESIGN.md, "Wire format").
    public var warnings: [Warning]

    enum CodingKeys: String, CodingKey {
        case target, registered, owner, scopes, warnings
        case expiresAt = "expires_at"
        case lastTest = "last_test"
        case ssoUrls = "sso_urls"
    }

    public init(
        target: String, registered: Bool, owner: String? = nil, expiresAt: Int64? = nil,
        scopes: [String]? = nil, lastTest: LastTest? = nil, ssoUrls: [String] = [],
        warnings: [Warning] = []
    ) {
        self.target = target
        self.registered = registered
        self.owner = owner
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.lastTest = lastTest
        self.ssoUrls = ssoUrls
        self.warnings = warnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        registered = try c.decode(Bool.self, forKey: .registered)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes)
        lastTest = try c.decodeIfPresent(LastTest.self, forKey: .lastTest)
        ssoUrls = try c.decodeIfPresent([String].self, forKey: .ssoUrls) ?? []
        warnings = try c.decodeIfPresent([Warning].self, forKey: .warnings) ?? []
    }
}

/// An event on a `subscribe` connection.
public enum SubscribeEvent: Equatable, Decodable {
    case snapshot(scopes: [Scope], dbUnreadable: Bool)
    case scopeChanged(Scope)
    case notify(DaemonNotification)
    /// A setting changed through `config_set`, by any client.
    case configChanged(key: String, value: ConfigValue)
    /// An event this build does not know. Clients ignore it.
    case unknown(String)

    enum CodingKeys: String, CodingKey {
        case event, scopes, scope, notification, key, value
        case dbUnreadable = "db_unreadable"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let event = try c.decode(String.self, forKey: .event)
        switch event {
        case "snapshot":
            self = .snapshot(
                scopes: try c.decode([Scope].self, forKey: .scopes),
                dbUnreadable: try c.decodeIfPresent(Bool.self, forKey: .dbUnreadable) ?? false
            )
        case "scope_changed":
            self = .scopeChanged(try c.decode(Scope.self, forKey: .scope))
        case "notify":
            self = .notify(try c.decode(DaemonNotification.self, forKey: .notification))
        case "config_changed":
            self = .configChanged(
                key: try c.decode(String.self, forKey: .key),
                value: try c.decode(ConfigValue.self, forKey: .value)
            )
        default:
            self = .unknown(event)
        }
    }
}

// MARK: - Responses

struct OkResponse: Decodable {
    var ok: Bool
}

struct ErrorResponse: Decodable {
    var ok: Bool
    var code: Lenient<ErrorCode>?
    var error: String?
}

struct ListResponse: Decodable { var cards: [Card] }
struct ActivityResponse: Decodable { var rows: [Row] }
struct ScopesResponse: Decodable { var scopes: [Scope] }
struct RefreshResponse: Decodable { var warnings: [Warning] }
struct OpenResponse: Decodable { var url: String }

public struct InfoResponse: Equatable, Decodable {
    public var version: String
    public var startedAt: Int64

    enum CodingKeys: String, CodingKey {
        case version
        case startedAt = "started_at"
    }

    public init(version: String, startedAt: Int64) {
        self.version = version
        self.startedAt = startedAt
    }
}

public struct TokenTestResponse: Equatable, Decodable {
    public var results: [TestResult]
    public var owner: String?
    public var ownerMismatch: Bool

    enum CodingKeys: String, CodingKey {
        case results, owner
        case ownerMismatch = "owner_mismatch"
    }

    public init(results: [TestResult], owner: String? = nil, ownerMismatch: Bool = false) {
        self.results = results
        self.owner = owner
        self.ownerMismatch = ownerMismatch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decode([TestResult].self, forKey: .results)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        ownerMismatch = try c.decodeIfPresent(Bool.self, forKey: .ownerMismatch) ?? false
    }
}

public struct SettingsStatus: Equatable, Decodable {
    public var apiUsage: ApiUsage
    public var tokens: [TokenStatus]

    enum CodingKeys: String, CodingKey {
        case apiUsage = "api_usage"
        case tokens
    }

    public init(apiUsage: ApiUsage = ApiUsage(), tokens: [TokenStatus] = []) {
        self.apiUsage = apiUsage
        self.tokens = tokens
    }
}

struct ConfigResponse: Decodable {
    var value: ConfigValue
}

/// A setting's value: a Boolean, an integer or a string (DESIGN.md,
/// "Settings"; the keys are in docs/tasks/M1.md, "Setting keys").
public enum ConfigValue: Equatable, Decodable {
    case bool(Bool)
    case int(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    var jsonObject: Any {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i
        case .string(let s): return s
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
