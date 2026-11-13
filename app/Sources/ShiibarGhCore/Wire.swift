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
    case statusFetchFailed = "status_fetch_failed"
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
    case commentOther = "comment_other"
    case reply
    case replyMentioned = "reply_mentioned"
    case reaction
    case approved
    case changesRequested = "changes_requested"
    case checksFailed = "checks_failed"
    case checksPassed = "checks_passed"
    case conflicts
    case mergeable
    case mergeQueueAdded = "merge_queue_added"
    case mergeQueueRemoved = "merge_queue_removed"
    case merged
    case closed
    case reopened
}

/// A kind of an owner's event table (`owner_events_*`), in table order
/// (DESIGN.md, "Row kinds and states").
public enum EventKind: String, Equatable, CaseIterable {
    case reviewRequested = "review_requested"
    case teamReviewRequested = "team_review_requested"
    case mentioned
    case teamMentioned = "team_mentioned"
    case comment
    case commentOther = "comment_other"
    case reply
    case replyMentioned = "reply_mentioned"
    case reaction
    case approved
    case changesRequested = "changes_requested"
    case checksFailed = "checks_failed"
    case checksPassed = "checks_passed"
    case conflicts
    case mergeable
    case mergeQueueAdded = "merge_queue_added"
    case mergeQueueRemoved = "merge_queue_removed"
    case mergedClosed = "merged_closed"
    case reopened
}

public enum EventColumn: String, Equatable, CaseIterable { case list, notify }

/// `list`'s `filter`, kept for the CLI (DESIGN.md, "What the filters
/// mean"); the app sends none.
public enum PrFilter: String, Equatable, Codable, CaseIterable {
    case all, authored, assigned, reviewRequested = "review_requested"
}

/// `placement.tab` and the `tab` of `place` (`none` only in `place`).
public enum PlacementTab: String, Equatable, Codable, CaseIterable { case review, mine }

/// `placement.section`: Review's four, Mine's `main` and `done`.
public enum PlacementSection: String, Equatable, Codable, CaseIterable {
    case doing, todo, waiting, done, main
}

/// What a card is muted for (`card.muted`).
public enum MuteReason: String, Equatable { case pr, repo, author }

/// The `kind` of `mute` and `unmute`.
public enum MuteKind: String, Equatable, CaseIterable { case pr, repo, user }

/// `list`'s `dismissed`.
public enum DismissedFilter: String, Equatable { case exclude, only, include }

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
    /// The owner's cards that are not dismissed.
    public var prCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, notify
        case githubId = "github_id"
        case skipDrafts = "skip_drafts"
        case prCount = "pr_count"
    }

    public init(
        id: String, name: String, kind: OwnerKind = .org, githubId: Int64? = nil, enabled: Bool = true,
        notify: Bool = true, skipDrafts: Bool = true, prCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kind = .known(kind)
        self.githubId = githubId
        self.enabled = enabled
        self.notify = notify
        self.skipDrafts = skipDrafts
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
    public var unread: Bool
    public var warnings: [Warning]
    public var rateLimit: RateLimit?
    public var owners: [Owner]

    enum CodingKeys: String, CodingKey {
        case id, login, color, token, unread, warnings, owners
        case updatedAt = "updated_at"
        case rateLimit = "rate_limit"
    }

    public init(
        id: String, login: String? = nil, color: AccountColor = .none, token: TokenInfo = TokenInfo(),
        updatedAt: Int64? = nil, unread: Bool = false, warnings: [Warning] = [],
        rateLimit: RateLimit? = nil, owners: [Owner] = []
    ) {
        self.id = id
        self.login = login ?? id
        self.color = .known(color)
        self.token = token
        self.updatedAt = updatedAt
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
    /// The row is muted now: a gray ring instead of the blue dot, and no
    /// notification (DESIGN.md, "Mute").
    public var muted: Bool

    enum CodingKeys: String, CodingKey {
        case id, pr, account, owner, kind, text, counts, actor, url, unread, muted
        case prTitle = "pr_title"
        case occurredAt = "occurred_at"
    }

    public init(
        id: String, pr: String = "o/r#1", prTitle: String = "Title", account: String = "3407303",
        owner: String = "o1", kind: RowKind,
        text: String? = nil, counts: [String: Int]? = nil, actor: String? = nil,
        url: String = "https://github.com/o/r/pull/1", occurredAt: Int64 = 0, unread: Bool = true, muted: Bool = false
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
        self.muted = muted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pr = try c.decode(String.self, forKey: .pr)
        prTitle = try c.decode(String.self, forKey: .prTitle)
        account = try c.decode(String.self, forKey: .account)
        owner = try c.decode(String.self, forKey: .owner)
        kind = try c.decode(Lenient<RowKind>.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts)
        actor = try c.decodeIfPresent(String.self, forKey: .actor)
        url = try c.decode(String.self, forKey: .url)
        occurredAt = try c.decode(Int64.self, forKey: .occurredAt)
        unread = try c.decode(Bool.self, forKey: .unread)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }

    /// An unread row that counts: blue, not gray (DESIGN.md, "How unread
    /// clears": muted rows count only when they are mentions).
    public var isBlueUnread: Bool {
        unread && (!muted || kind.value == .mentioned)
    }

    /// An unread row shown with the gray ring.
    public var isGrayUnread: Bool { unread && !isBlueUnread }
}

/// Where a card is placed: a Review section or Mine, with its rank in the
/// section, muted cards last (DESIGN.md, "Wire format", `placement`).
public struct Placement: Equatable, Decodable {
    public var tab: Lenient<PlacementTab>
    public var section: Lenient<PlacementSection>
    public var position: Int

    public init(tab: PlacementTab, section: PlacementSection, position: Int = 0) {
        self.tab = .known(tab)
        self.section = .known(section)
        self.position = position
    }

    public var isDone: Bool { section.value == .done }
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
    /// GitHub's fact: you or your team is asked for a review now. The
    /// Involvement group uses it (DESIGN.md, "What the filters mean").
    public var reviewRequested: Bool
    /// The app's "waiting for your review": the `Review requested` mark.
    public var awaitingReview: Bool
    public var stateLabel: Lenient<StateLabel>
    public var review: Lenient<ReviewStatus>
    public var checks: Lenient<ChecksStatus>
    public var baseStatus: Lenient<BaseStatus>
    public var base: String
    public var head: String
    public var addedAt: Int64?
    /// GraphQL `createdAt`.
    public var createdAt: Int64?
    /// GraphQL `updatedAt`.
    public var updatedAt: Int64
    public var links: Links
    /// Up to 20 rows, newest first.
    public var rows: [Row]
    /// nil while the card has no placement.
    public var placement: Placement?
    /// Why the card is muted; empty when it is not.
    public var muted: [Lenient<MuteReason>]
    public var dismissedAt: Int64?
    public var dismissExpiresAt: Int64?
    /// When the automatic Dismiss is due; nil when none is scheduled
    /// (DESIGN.md, "Dismiss").
    public var autoDismissAt: Int64?
    /// Rows of this PR were deleted past the 20 kept (DESIGN.md, "Rows in a
    /// card").
    public var olderRows: Bool

    enum CodingKeys: String, CodingKey {
        case id, pr, account, owner, title, url, author, review, checks, base, head
        case links, rows, placement, muted
        case authorAvatarUrl = "author_avatar_url"
        case authoredByMe = "authored_by_me"
        case assignedToMe = "assigned_to_me"
        case reviewRequested = "review_requested"
        case stateLabel = "state_label"
        case baseStatus = "base_status"
        case addedAt = "added_at"
        case awaitingReview = "awaiting_review"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case dismissedAt = "dismissed_at"
        case dismissExpiresAt = "dismiss_expires_at"
        case autoDismissAt = "auto_dismiss_at"
        case olderRows = "older_rows"
    }

    public init(
        id: String, pr: String = "o/r#1", account: String = "3407303", owner: String = "o1",
        title: String = "Title", url: String = "https://github.com/o/r/pull/1", author: String = "me",
        authorAvatarUrl: String? = nil, authoredByMe: Bool = true, assignedToMe: Bool = false,
        reviewRequested: Bool = false, awaitingReview: Bool = false, stateLabel: StateLabel = .open, review: ReviewStatus = .none,
        checks: ChecksStatus = .none, baseStatus: BaseStatus = .none, base: String = "main",
        head: String = "topic", addedAt: Int64? = nil,
        createdAt: Int64? = nil, updatedAt: Int64 = 0, links: Links = Links(review: "r", checks: "c", base: "b"), rows: [Row] = [],
        placement: Placement? = nil, muted: [MuteReason] = [], dismissedAt: Int64? = nil, dismissExpiresAt: Int64? = nil,
        autoDismissAt: Int64? = nil, olderRows: Bool = false
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
        self.addedAt = addedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.links = links
        self.rows = rows
        self.placement = placement
        self.muted = muted.map(Lenient.known)
        self.dismissedAt = dismissedAt
        self.dismissExpiresAt = dismissExpiresAt
        self.autoDismissAt = autoDismissAt
        self.olderRows = olderRows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pr = try c.decode(String.self, forKey: .pr)
        account = try c.decode(String.self, forKey: .account)
        owner = try c.decode(String.self, forKey: .owner)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        author = try c.decode(String.self, forKey: .author)
        authorAvatarUrl = try c.decodeIfPresent(String.self, forKey: .authorAvatarUrl)
        authoredByMe = try c.decode(Bool.self, forKey: .authoredByMe)
        assignedToMe = try c.decodeIfPresent(Bool.self, forKey: .assignedToMe) ?? false
        reviewRequested = try c.decodeIfPresent(Bool.self, forKey: .reviewRequested) ?? false
        awaitingReview = try c.decodeIfPresent(Bool.self, forKey: .awaitingReview) ?? false
        stateLabel = try c.decode(Lenient<StateLabel>.self, forKey: .stateLabel)
        review = try c.decode(Lenient<ReviewStatus>.self, forKey: .review)
        checks = try c.decode(Lenient<ChecksStatus>.self, forKey: .checks)
        baseStatus = try c.decode(Lenient<BaseStatus>.self, forKey: .baseStatus)
        base = try c.decode(String.self, forKey: .base)
        head = try c.decode(String.self, forKey: .head)
        addedAt = try c.decodeIfPresent(Int64.self, forKey: .addedAt)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt)
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
        links = try c.decode(Links.self, forKey: .links)
        rows = try c.decode([Row].self, forKey: .rows)
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement)
        muted = try c.decodeIfPresent([Lenient<MuteReason>].self, forKey: .muted) ?? []
        dismissedAt = try c.decodeIfPresent(Int64.self, forKey: .dismissedAt)
        dismissExpiresAt = try c.decodeIfPresent(Int64.self, forKey: .dismissExpiresAt)
        autoDismissAt = try c.decodeIfPresent(Int64.self, forKey: .autoDismissAt)
        olderRows = try c.decodeIfPresent(Bool.self, forKey: .olderRows) ?? false
    }

    /// Merged and Closed come after the open PRs (Draft included).
    public var isFinished: Bool {
        stateLabel.value == .merged || stateLabel.value == .closed
    }

    public var isMuted: Bool { !muted.isEmpty }

    public var isDismissed: Bool { dismissedAt != nil }

    public func isMuted(for reason: MuteReason) -> Bool {
        muted.contains { $0.value == reason }
    }

    /// A row of the card is blue unread.
    public var hasBlueUnread: Bool { rows.contains(where: \.isBlueUnread) }

    public var hasGrayUnread: Bool { rows.contains(where: \.isGrayUnread) }

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

/// `mutes`: what the account has muted, names as they were given.
public struct Mutes: Equatable, Decodable {
    public var repos: [String]
    public var users: [String]
    public var prs: [String]

    public init(repos: [String] = [], users: [String] = [], prs: [String] = []) {
        self.repos = repos
        self.users = users
        self.prs = prs
    }

    public func list(_ kind: MuteKind) -> [String] {
        switch kind {
        case .repo: return repos
        case .user: return users
        case .pr: return prs
        }
    }

    /// Names compare without case (DESIGN.md, "Mute").
    public func contains(_ kind: MuteKind, _ name: String) -> Bool {
        list(kind).contains { $0.lowercased() == name.lowercased() }
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
struct AccountsResponse: Decodable { var accounts: [Account] }
struct AccountResponse: Decodable { var account: Account }
struct RefreshResponse: Decodable { var warnings: [Warning] }
struct TokenTestResponse: Decodable { var results: [TestResult] }
struct EventsResponse: Decodable { var events: [String: EventCell] }
struct MutesResponse: Decodable { var mutes: Mutes }

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
