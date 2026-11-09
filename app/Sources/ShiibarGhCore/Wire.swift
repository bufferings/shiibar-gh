// The daemon's NDJSON wire format as the app reads it (docs/DESIGN.md,
// "Wire format"; the authoritative types are crates/shiibar-gh-proto).
// Unknown fields are ignored by `Decodable`, unknown enum values are kept as
// `Lenient.unknown` and unknown events decode as `SubscribeEvent.unknown`, so
// a newer daemon never breaks this client.

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

public enum OwnerKind: String, Equatable { case org, user, `public` }

/// DESIGN.md, "Account colors", in the order of Finder's tags.
public enum AccountColor: String, Equatable, CaseIterable {
    case none, red, orange, yellow, green, blue, purple

    public var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

/// DESIGN.md, "Showing warnings", in the order of that table.
public enum WarningKind: String, Equatable, CaseIterable {
    case keychainUnavailable = "keychain_unavailable"
    case tokensUnreadable = "tokens_unreadable"
    case noToken = "no_token"
    case tokenInvalid = "token_invalid"
    case tokenExpiring = "token_expiring"
    case fetchFailed = "fetch_failed"
    case rateLimited = "rate_limited"
    case graphqlNearLimit = "graphql_near_limit"
    case restNearLimit = "rest_near_limit"
    case scopeMissing = "scope_missing"
    case ssoRequired = "sso_required"
    case eventsFetchFailed = "events_fetch_failed"
}

public enum KeychainState: String, Equatable { case ok, unavailable, unreadable }

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

/// `row.kind`: the event kinds with `merged_closed` split in two.
public enum RowKind: String, Equatable {
    case reviewRequested = "review_requested"
    case teamReviewRequested = "team_review_requested"
    case mentioned
    case teamMentioned = "team_mentioned"
    case comment
    case reply
    case replyMentioned = "reply_mentioned"
    case reaction
    case approved
    case changesRequested = "changes_requested"
    case checksFailed = "checks_failed"
    case conflicts
    case mergeable
    case mergeQueueAdded = "merge_queue_added"
    case mergeQueueRemoved = "merge_queue_removed"
    case merged
    case closed
}

/// A kind of an owner's event table (`owner_events_*`), in table order.
public enum EventKind: String, Equatable, CaseIterable {
    case reviewRequested = "review_requested"
    case teamReviewRequested = "team_review_requested"
    case mentioned
    case teamMentioned = "team_mentioned"
    case comment
    case reply
    case replyMentioned = "reply_mentioned"
    case reaction
    case approved
    case changesRequested = "changes_requested"
    case checksFailed = "checks_failed"
    case conflicts
    case mergeable
    case mergeQueueAdded = "merge_queue_added"
    case mergeQueueRemoved = "merge_queue_removed"
    case mergedClosed = "merged_closed"
}

public enum EventColumn: String, Equatable, CaseIterable { case list, notify }

/// The segment of the filter row (DESIGN.md, "What the filters mean").
public enum PrFilter: String, Equatable, Codable, CaseIterable {
    case all, authored, assigned, reviewRequested = "review_requested"
}

public enum ExclusionKind: String, Equatable { case repo, user }

public enum ExclusionState: String, Equatable, CaseIterable { case hidden, listOnly = "list_only" }

public enum NotificationType: String, Equatable { case single, summary }

public enum TestItem: String, Equatable { case account, scopes, notifications, teamMembership = "team_membership", owner }

public enum TestOutcome: String, Equatable { case ok, failed, ssoRequired = "sso_required", cantCheck = "cant_check" }

public enum ErrorCode: String, Equatable {
    case notFound = "not_found", invalid, unreachable, keychainUnavailable = "keychain_unavailable", `internal`
}

public struct Warning: Equatable, Decodable {
    public var kind: Lenient<WarningKind>
    public var account: String?
    public var owner: String?
    public var message: String
    public var until: Int64?
    public var url: String?

    public init(
        kind: WarningKind, account: String? = nil, owner: String? = nil, message: String = "",
        until: Int64? = nil, url: String? = nil
    ) {
        self.kind = .known(kind)
        self.account = account
        self.owner = owner
        self.message = message
        self.until = until
        self.url = url
    }
}

public struct Owner: Equatable, Decodable, Identifiable {
    public var id: String
    public var name: String
    public var kind: Lenient<OwnerKind>
    public var githubId: Int64?
    public var enabled: Bool
    public var notify: Bool
    public var skipDrafts: Bool
    /// The PRs waiting for your review (DESIGN.md, "Awaiting review").
    public var reviewCount: Int
    public var prCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, notify
        case githubId = "github_id"
        case skipDrafts = "skip_drafts"
        case reviewCount = "review_count"
        case prCount = "pr_count"
    }

    public init(
        id: String, name: String, kind: OwnerKind = .org, githubId: Int64? = nil, enabled: Bool = true,
        notify: Bool = true, skipDrafts: Bool = true, reviewCount: Int = 0, prCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kind = .known(kind)
        self.githubId = githubId
        self.enabled = enabled
        self.notify = notify
        self.skipDrafts = skipDrafts
        self.reviewCount = reviewCount
        self.prCount = prCount
    }

    /// Public is told by its kind; the id is opaque.
    public var isPublic: Bool { kind.value == .public }

    /// What Settings and the popover call it.
    public var displayName: String { isPublic ? "Public" : name }

    /// The `owner` argument of a request: the login, or `public`.
    public var argument: String { isPublic ? "public" : name }

    /// Organization, Personal account or Public repositories.
    public var kindTitle: String {
        switch kind.value {
        case .org: return "Organization"
        case .user: return "Personal account"
        case .public: return "Public repositories"
        case nil: return kind.rawText
        }
    }
}

public struct TestResult: Equatable, Decodable {
    public var item: Lenient<TestItem>
    public var label: String
    public var owner: String?
    public var outcome: Lenient<TestOutcome>
    public var text: String
    public var url: String?

    public init(item: TestItem, label: String, owner: String? = nil, outcome: TestOutcome, text: String, url: String? = nil) {
        self.item = .known(item)
        self.label = label
        self.owner = owner
        self.outcome = .known(outcome)
        self.text = text
        self.url = url
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

public struct TokenInfo: Equatable, Decodable {
    public var registered: Bool
    public var expiresAt: Int64?
    public var lastTest: LastTest?

    enum CodingKeys: String, CodingKey {
        case registered
        case expiresAt = "expires_at"
        case lastTest = "last_test"
    }

    public init(registered: Bool = true, expiresAt: Int64? = nil, lastTest: LastTest? = nil) {
        self.registered = registered
        self.expiresAt = expiresAt
        self.lastTest = lastTest
    }
}

public struct Limit: Equatable, Decodable {
    public var used: Int64
    public var limit: Int64
    public var resetAt: Int64?

    enum CodingKeys: String, CodingKey {
        case used, limit
        case resetAt = "reset_at"
    }

    public init(used: Int64, limit: Int64, resetAt: Int64? = nil) {
        self.used = used
        self.limit = limit
        self.resetAt = resetAt
    }
}

public struct RateLimit: Equatable, Decodable {
    public var graphql: Limit?
    public var rest: Limit?

    public init(graphql: Limit? = nil, rest: Limit? = nil) {
        self.graphql = graphql
        self.rest = rest
    }
}

public struct Account: Equatable, Decodable, Identifiable {
    public var id: String
    public var login: String
    public var color: Lenient<AccountColor>
    public var token: TokenInfo
    public var updatedAt: Int64?
    public var reviewCount: Int
    public var unread: Bool
    public var warnings: [Warning]
    public var rateLimit: RateLimit?
    public var owners: [Owner]

    enum CodingKeys: String, CodingKey {
        case id, login, color, token, unread, warnings, owners
        case updatedAt = "updated_at"
        case reviewCount = "review_count"
        case rateLimit = "rate_limit"
    }

    public init(
        id: String, login: String? = nil, color: AccountColor = .none, token: TokenInfo = TokenInfo(),
        updatedAt: Int64? = nil, reviewCount: Int = 0, unread: Bool = false, warnings: [Warning] = [],
        rateLimit: RateLimit? = nil, owners: [Owner] = []
    ) {
        self.id = id
        self.login = login ?? id
        self.color = .known(color)
        self.token = token
        self.updatedAt = updatedAt
        self.reviewCount = reviewCount
        self.unread = unread
        self.warnings = warnings
        self.rateLimit = rateLimit
        self.owners = owners
    }

    public func owner(_ id: String) -> Owner? {
        owners.first { $0.id == id }
    }
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
    public var account: String
    public var owner: String
    public var kind: Lenient<RowKind>
    public var text: String?
    public var counts: [String: Int]?
    public var actor: String?
    public var url: String
    public var occurredAt: Int64
    public var unread: Bool

    enum CodingKeys: String, CodingKey {
        case id, pr, account, owner, kind, text, counts, actor, url, unread
        case prTitle = "pr_title"
        case occurredAt = "occurred_at"
    }

    public init(
        id: String, pr: String = "o/r#1", prTitle: String = "Title", account: String = "3407303",
        owner: String = "o1", kind: RowKind,
        text: String? = nil, counts: [String: Int]? = nil, actor: String? = nil,
        url: String = "https://github.com/o/r/pull/1", occurredAt: Int64 = 0, unread: Bool = true
    ) {
        self.id = id
        self.pr = pr
        self.prTitle = prTitle
        self.account = account
        self.owner = owner
        self.kind = .known(kind)
        self.text = text
        self.counts = counts
        self.actor = actor
        self.url = url
        self.occurredAt = occurredAt
        self.unread = unread
    }
}

public struct Card: Equatable, Decodable, Identifiable {
    public var id: String
    public var pr: String
    public var account: String
    public var owner: String
    public var title: String
    public var url: String
    public var author: String
    public var authorAvatarUrl: String?
    public var authoredByMe: Bool
    public var assignedToMe: Bool
    /// GitHub's fact: you or your team is asked for a review now. The chip
    /// and the Involvement group use it (DESIGN.md, "What the filters mean").
    public var reviewRequested: Bool
    /// The app's "waiting for your review": the mark and the red counts.
    public var awaitingReview: Bool
    public var stateLabel: Lenient<StateLabel>
    public var review: Lenient<ReviewStatus>
    public var checks: Lenient<ChecksStatus>
    public var baseStatus: Lenient<BaseStatus>
    public var base: String
    public var head: String
    public var snoozed: Bool
    public var snoozedUntil: Int64?
    public var addedAt: Int64?
    /// GraphQL `createdAt`; nil right after the move from 0.2.
    public var createdAt: Int64?
    /// GraphQL `updatedAt`.
    public var updatedAt: Int64
    public var links: Links
    public var rows: [Row]

    enum CodingKeys: String, CodingKey {
        case id, pr, account, owner, title, url, author, review, checks, base, head, snoozed
        case links, rows
        case authorAvatarUrl = "author_avatar_url"
        case authoredByMe = "authored_by_me"
        case assignedToMe = "assigned_to_me"
        case reviewRequested = "review_requested"
        case stateLabel = "state_label"
        case baseStatus = "base_status"
        case snoozedUntil = "snoozed_until"
        case addedAt = "added_at"
        case awaitingReview = "awaiting_review"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String, pr: String = "o/r#1", account: String = "3407303", owner: String = "o1",
        title: String = "Title", url: String = "https://github.com/o/r/pull/1", author: String = "me",
        authorAvatarUrl: String? = nil, authoredByMe: Bool = true, assignedToMe: Bool = false,
        reviewRequested: Bool = false, awaitingReview: Bool = false, stateLabel: StateLabel = .open, review: ReviewStatus = .none,
        checks: ChecksStatus = .none, baseStatus: BaseStatus = .none, base: String = "main",
        head: String = "topic", snoozed: Bool = false, snoozedUntil: Int64? = nil, addedAt: Int64? = nil,
        createdAt: Int64? = nil, updatedAt: Int64 = 0, links: Links = Links(review: "r", checks: "c", base: "b"), rows: [Row] = []
    ) {
        self.id = id
        self.pr = pr
        self.account = account
        self.owner = owner
        self.title = title
        self.url = url
        self.author = author
        self.authorAvatarUrl = authorAvatarUrl
        self.authoredByMe = authoredByMe
        self.assignedToMe = assignedToMe
        self.reviewRequested = reviewRequested
        self.awaitingReview = awaitingReview
        self.stateLabel = .known(stateLabel)
        self.review = .known(review)
        self.checks = .known(checks)
        self.baseStatus = .known(baseStatus)
        self.base = base
        self.head = head
        self.snoozed = snoozed
        self.snoozedUntil = snoozedUntil
        self.addedAt = addedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.links = links
        self.rows = rows
    }

    /// Merged and Closed come after the open PRs (Draft included).
    public var isFinished: Bool {
        stateLabel.value == .merged || stateLabel.value == .closed
    }

    public var hasUnread: Bool { rows.contains(where: \.unread) }
}

public struct DaemonNotification: Equatable, Decodable {
    public var id: String
    public var type: Lenient<NotificationType>
    public var account: String
    public var owner: String
    public var rows: [String]
    public var pr: String?
    public var url: String?
    public var title: String
    public var subtitle: String?
    public var body: String?

    public init(
        id: String, type: NotificationType, account: String, owner: String = "o1", rows: [String] = [],
        pr: String? = nil, url: String? = nil, title: String, subtitle: String? = nil, body: String? = nil
    ) {
        self.id = id
        self.type = .known(type)
        self.account = account
        self.owner = owner
        self.rows = rows
        self.pr = pr
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

public struct EventCell: Equatable, Decodable {
    public var list: Bool
    public var notify: Bool

    public init(list: Bool, notify: Bool) {
        self.list = list
        self.notify = notify
    }

    public func value(_ column: EventColumn) -> Bool {
        switch column {
        case .list: return list
        case .notify: return notify
        }
    }
}

public struct Exclusion: Equatable, Decodable, Hashable {
    public var name: String
    public var state: Lenient<ExclusionState>

    public init(name: String, state: ExclusionState) {
        self.name = name
        self.state = .known(state)
    }

    public static func == (a: Exclusion, b: Exclusion) -> Bool { a.name == b.name && a.state.rawText == b.state.rawText }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

public struct Exclusions: Equatable, Decodable {
    public var repos: [Exclusion]
    public var users: [Exclusion]

    public init(repos: [Exclusion] = [], users: [Exclusion] = []) {
        self.repos = repos
        self.users = users
    }

    public func list(_ kind: ExclusionKind) -> [Exclusion] {
        kind == .repo ? repos : users
    }
}

/// An event on a `subscribe` connection.
public enum SubscribeEvent: Equatable, Decodable {
    case snapshot(accounts: [Account], keychain: Lenient<KeychainState>, dbUnreadable: Bool)
    case accountChanged(Account)
    case accountRemoved(String)
    case keychainChanged(Lenient<KeychainState>)
    case notify(DaemonNotification)
    /// A setting changed through `config_set`, by any client.
    case configChanged(key: String, value: ConfigValue)
    /// An event this build does not know. Clients ignore it.
    case unknown(String)

    enum CodingKeys: String, CodingKey {
        case event, accounts, account, id, keychain, notification, key, value
        case dbUnreadable = "db_unreadable"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let event = try c.decode(String.self, forKey: .event)
        switch event {
        case "snapshot":
            self = .snapshot(
                accounts: try c.decode([Account].self, forKey: .accounts),
                keychain: try c.decodeIfPresent(Lenient<KeychainState>.self, forKey: .keychain) ?? .known(.ok),
                dbUnreadable: try c.decodeIfPresent(Bool.self, forKey: .dbUnreadable) ?? false
            )
        case "account_changed":
            self = .accountChanged(try c.decode(Account.self, forKey: .account))
        case "account_removed":
            self = .accountRemoved(try c.decode(String.self, forKey: .id))
        case "keychain_changed":
            self = .keychainChanged(try c.decode(Lenient<KeychainState>.self, forKey: .keychain))
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
struct AccountsResponse: Decodable { var accounts: [Account] }
struct AccountResponse: Decodable { var account: Account }
struct RefreshResponse: Decodable { var warnings: [Warning] }
struct TokenTestResponse: Decodable { var results: [TestResult] }
struct EventsResponse: Decodable { var events: [String: EventCell] }
struct ExclusionsResponse: Decodable { var exclusions: Exclusions }

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

/// A setting's value: a Boolean, an integer or a string.
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
