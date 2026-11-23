// What the popover, the menu bar and Settings show for the daemon's values.
// The wording follows docs/DESIGN.md and the boards in docs/design/.

import Foundation

// MARK: - Times

public enum RelativeTime {
    /// "just now", "5 min ago", "1 hr ago", "3 days ago".
    public static func ago(_ seconds: Int64) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) hr ago" }
        let days = seconds / 86_400
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// The header line under the account name.
    public static func updated(_ updatedAt: Int64?, now: Int64) -> String {
        guard let updatedAt else { return "Not updated yet" }
        return "Updated " + ago(now - updatedAt)
    }

    /// Whole minutes until `until`, rounded up, at least 1.
    public static func minutesUntil(_ until: Int64, now: Int64) -> Int64 {
        max(1, (until - now + 59) / 60)
    }

    /// Whole days until `until`, rounded up, at least 1 (DESIGN.md, "Token
    /// status": under a day is 1 day).
    public static func daysUntil(_ until: Int64, now: Int64) -> Int64 {
        max(1, (until - now + 86_399) / 86_400)
    }

    static func days(_ count: Int64) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    private static func format(_ at: Int64, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(at)))
    }

    /// "14:05".
    public static func clock(_ at: Int64, timeZone: TimeZone = .current) -> String {
        format(at, "HH:mm", timeZone)
    }

    /// "2026-11-10 14:05", for hover texts.
    public static func dateTime(_ at: Int64, timeZone: TimeZone = .current) -> String {
        format(at, "yyyy-MM-dd HH:mm", timeZone)
    }

    /// "Mon 09:00", for "until Mon 09:00".
    public static func weekdayClock(_ at: Int64, timeZone: TimeZone = .current) -> String {
        format(at, "EEE HH:mm", timeZone)
    }

    /// "2027-01-20", for "Expires 2027-01-20".
    public static func date(_ at: Int64, timeZone: TimeZone = .current) -> String {
        format(at, "yyyy-MM-dd", timeZone)
    }
}

// MARK: - Warnings

/// The button at the right of a banner line (DESIGN.md, "Showing warnings").
public enum BannerButton: Equatable {
    /// Settings with the account selected.
    case settings
    /// The Keychain dialog for `keychain_unavailable`.
    case retry
    /// The Keychain dialog for `tokens_unreadable`.
    case resetTokens
    /// Opens the SSO URL, else the token settings page.
    case authorize(String)

    public var title: String {
        switch self {
        case .settings: return "Settings…"
        case .retry: return "Retry…"
        case .resetTokens: return "Reset tokens…"
        case .authorize: return "Authorize…"
        }
    }
}

public struct BannerLine: Equatable {
    public var kind: WarningKind
    public var text: String
    public var button: BannerButton?

    public init(kind: WarningKind, text: String, button: BannerButton?) {
        self.kind = kind
        self.text = text
        self.button = button
    }

    /// The Keychain line of Settings and of the popover without accounts.
    public static func keychain(_ dialog: KeychainDialog) -> BannerLine {
        dialog.state == .unreadable
            ? BannerLine(kind: .tokensUnreadable, text: dialog.title, button: .resetTokens)
            : BannerLine(kind: .keychainUnavailable, text: dialog.title, button: .retry)
    }
}

public enum Warnings {
    /// The kinds that put the triangle on the menu bar icon: fetching has
    /// stopped or is about to.
    public static let triangleKinds: Set<WarningKind> = [
        .keychainUnavailable, .tokensUnreadable, .noToken, .tokenInvalid, .tokenExpiring, .fetchFailed, .rateLimited,
    ]

    public static func hasTriangle(_ account: Account) -> Bool {
        account.warnings.contains { $0.kind.value.map(triangleKinds.contains) ?? false }
    }

    public static func button(_ warning: Warning, kind: WarningKind) -> BannerButton? {
        switch kind {
        case .keychainUnavailable: return .retry
        case .tokensUnreadable: return .resetTokens
        case .noToken, .tokenInvalid, .tokenExpiring, .scopeMissing: return .settings
        case .ssoRequired: return .authorize(warning.url ?? CreateTokenURL.tokenSettings)
        case .fetchFailed, .rateLimited, .graphqlNearLimit, .restNearLimit, .eventsFetchFailed, .statusFetchFailed: return nil
        }
    }

    /// Every warning as one banner line, in the order of the table. Unknown
    /// kinds are left out.
    public static func banner(_ warnings: [Warning], now: Int64) -> [BannerLine] {
        var lines: [BannerLine] = []
        for kind in WarningKind.allCases {
            for warning in warnings where warning.kind.value == kind {
                lines.append(BannerLine(kind: kind, text: text(warning, kind: kind, now: now), button: button(warning, kind: kind)))
            }
        }
        return lines
    }

    /// The daemon's message, with the countdowns worked out again at `now`
    /// (the message was written when the warning was made).
    static func text(_ warning: Warning, kind: WarningKind, now: Int64) -> String {
        switch kind {
        case .fetchFailed:
            let minutes = warning.until.map { RelativeTime.minutesUntil($0, now: now) } ?? 1
            return "Couldn't reach GitHub · retrying in \(minutes) min"
        case .tokenExpiring:
            guard let until = warning.until else { break }
            return "Token expires in " + RelativeTime.days(RelativeTime.daysUntil(until, now: now))
        case .keychainUnavailable where warning.message.isEmpty:
            return KeychainDialog.unavailable.title
        case .tokensUnreadable where warning.message.isEmpty:
            return KeychainDialog.unreadable.title
        default:
            break
        }
        return warning.message
    }

    /// `owner/repo#123` as `owner/repo #123`, the way cards show it.
    public static func prLabel(_ key: String) -> String {
        guard let hash = key.lastIndex(of: "#") else { return key }
        return key[..<hash] + " " + key[hash...]
    }
}

// MARK: - Keychain dialogs

/// DESIGN.md, "When the Keychain cannot be read".
public struct KeychainDialog: Equatable {
    public var state: KeychainState
    public var title: String
    public var message: String
    /// The default button.
    public var action: String
    public var cancel = "Not now"

    public static let unavailable = KeychainDialog(
        state: .unavailable, title: "Couldn't read tokens from Keychain",
        message: "If macOS asked whether \(MainMenu.appName) may use the Keychain, allow it, then retry.", action: "Retry"
    )
    public static let unreadable = KeychainDialog(
        state: .unreadable, title: "Saved tokens are unreadable",
        message: "Reset deletes the Keychain item. You enter every token again. PRs and settings stay.",
        action: "Reset tokens"
    )

    public static func `for`(_ state: KeychainState) -> KeychainDialog? {
        switch state {
        case .ok: return nil
        case .unavailable: return unavailable
        case .unreadable: return unreadable
        }
    }

    /// The state the Keychain warnings in a `refresh` answer tell.
    public static func state(in warnings: [Warning]) -> KeychainState {
        if warnings.contains(where: { $0.kind.value == .tokensUnreadable }) { return .unreadable }
        if warnings.contains(where: { $0.kind.value == .keychainUnavailable }) { return .unavailable }
        return .ok
    }
}

/// When the Keychain dialog shows by itself: once each time `keychain` turns
/// from `ok` (or from the other failure) into a failure, on a snapshot or a
/// `keychain_changed` (docs/tasks/M4.md, "App"). A Retry that fails shows it
/// again; that goes through `again`.
public struct KeychainPrompt: Equatable {
    public private(set) var state: KeychainState = .ok
    private var prompted: KeychainState?

    public init() {}

    /// The dialog to show for a new state, if any.
    public mutating func update(_ new: KeychainState) -> KeychainDialog? {
        state = new
        guard new != .ok else {
            prompted = nil
            return nil
        }
        guard prompted != new else { return nil }
        prompted = new
        return KeychainDialog.for(new)
    }

    /// After a Retry or a Reset: the dialog again while the state is still
    /// a failure.
    public mutating func again(_ new: KeychainState) -> KeychainDialog? {
        state = new
        prompted = new == .ok ? nil : new
        return KeychainDialog.for(new)
    }
}

// MARK: - Rows

public enum RowText {
    /// DESIGN.md, "Row kinds and states": line breaks and runs of white
    /// space become one space.
    public static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Every `ReactionContent` value the daemon sends as a `counts` key (the
    /// GraphQL enum; the public schema lists exactly these eight, checked
    /// 2026-11-09), in display order, with its emoji.
    public static let reactions: [(String, String)] = [
        ("THUMBS_UP", "👍"), ("THUMBS_DOWN", "👎"), ("LAUGH", "😄"), ("HOORAY", "🎉"),
        ("CONFUSED", "😕"), ("HEART", "❤️"), ("ROCKET", "🚀"), ("EYES", "👀"),
    ]

    /// "👍3 🎉1".
    public static func counts(_ counts: [String: Int]) -> String {
        var parts: [String] = []
        for (key, emoji) in reactions {
            if let count = counts[key], count > 0 { parts.append("\(emoji)\(count)") }
        }
        for key in counts.keys.sorted() where !reactions.contains(where: { $0.0 == key }) {
            // A value this build does not know: its name, then the count.
            if let count = counts[key], count > 0 {
                parts.append(key.lowercased().replacingOccurrences(of: "_", with: " ") + " \(count)")
            }
        }
        return parts.joined(separator: " ")
    }

    /// The label of a row (DESIGN.md, "Row labels"): a team's review request
    /// reads "Review requested" with "for frontend team" as its text; both
    /// comment kinds read "Comment", both reply kinds "Reply"; the other
    /// kinds use the names of the event table, Merged / Closed split in two.
    public static func label(_ kind: Lenient<RowKind>) -> String {
        guard let kind = kind.value else {
            return kind.rawText.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
        switch kind {
        case .reviewRequested, .teamReviewRequested: return "Review requested"
        case .assigned: return "Assigned"
        // My review reads as the verdict it records (DESIGN.md, "Row labels").
        case .myReviewApproved: return "Approved"
        case .myReviewChangesRequested: return "Changes requested"
        case .mentioned: return "Mentioned"
        case .teamMentioned: return "My team mentioned"
        case .comment, .commentOther: return "Comment"
        case .reply, .replyMentioned: return "Reply"
        case .reaction: return "Reaction"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .checksFailed: return "Checks failed"
        case .checksPassed: return "Checks passed"
        case .conflicts: return "Conflicts"
        case .mergeable: return "Mergeable"
        case .readyForReview: return "Ready for review"
        case .convertedToDraft: return "Converted to draft"
        case .mergeQueueAdded: return "Added to merge queue"
        case .mergeQueueRemoved: return "Removed from merge queue"
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .reopened: return "Reopened"
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// The mark at the start of a row, of "+ N more" and of "+ N more PRs"
/// (DESIGN.md, "How rows look"): a accent-colored dot, a gray ring for muted unread
/// ones, or nothing.
public enum UnreadMark: Equatable {
    case none, blue, ring

    /// Blue if any is colored unread, the ring if only gray ones are unread.
    public static func of(_ rows: [Row]) -> UnreadMark {
        if rows.contains(where: \.isBlueUnread) { return .blue }
        if rows.contains(where: \.isGrayUnread) { return .ring }
        return .none
    }

    public static func of(cards: [Card]) -> UnreadMark {
        of(cards.flatMap(\.rows))
    }
}

public struct RowPresentation: Equatable {
    public var label: String
    /// Reaction counts next to the label, such as "👍3".
    public var counts: String?
    /// The actor's name (login) on line 1, after the label (DESIGN.md, "How
    /// rows look"): for the rows a person (a bot included) caused. nil for
    /// the state change rows and Reaction, and for a row without an actor.
    public var actor: String?
    /// The actor's avatar, shown before the name; nil shows the name alone
    /// without keeping its room.
    public var actorAvatarUrl: String?
    /// "9 min ago": at the right end of line 1, before the chain icon, at
    /// the same place in every row.
    public var time: String
    /// The body under the label line, already normalized.
    public var body: String?
    /// The lines the body shows now.
    public var bodyLines: Int
    /// The lines it shows without `more`: 1, or 3 for an unread mention.
    /// Only a body cut short at these lines shows `more`.
    public var collapsedLines: Int
    /// `more` was pressed: `less` shows in its place.
    public var expanded: Bool

    /// `more` or `less` at the right end of the body, nil for neither:
    /// `less` while expanded, `more` when the body does not fit
    /// `collapsedLines` (`cut`, which the view measures).
    public func toggle(cut: Bool) -> String? {
        if expanded { return "less" }
        return cut ? "more" : nil
    }
    /// Read rows are not dimmed: only the mark goes (DESIGN.md, "How rows
    /// look"). Gray is for muted rows only.
    public var mark: UnreadMark
    /// The text of a muted row is gray.
    public var gray: Bool

    /// The lines of a body: 1, 3 for an unread mention of you or your team,
    /// 5 once `more` was pressed (DESIGN.md, "Row body", "Constants").
    public static let bodyLines = 1
    public static let unreadMentionLines = 3
    public static let expandedLines = 5

    /// The kinds that show who caused them on line 1 (DESIGN.md, "How rows
    /// look"): every row a person caused. The state change rows and
    /// Reaction show no one.
    public static func showsActor(_ kind: RowKind?) -> Bool {
        switch kind {
        case .checksFailed, .checksPassed, .changesRequested, .conflicts, .mergeable, .reaction, nil:
            return false
        default:
            return true
        }
    }

    /// `cardMuted`: the row's card is muted. Its rows are gray except a
    /// mention of you or your team, which keeps the normal color and the
    /// accent-colored dot (DESIGN.md, "Card"). `expanded`: `more` was pressed on the
    /// body; it shows up to 5 wrapped lines and `less`.
    public init(_ row: Row, now: Int64, cardMuted: Bool = false, expanded: Bool = false) {
        let kind = row.kind.value
        label = RowText.label(row.kind)
        time = RelativeTime.ago(now - row.occurredAt)
        let text = row.text.map(RowText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        actor = Self.showsActor(kind) ? row.actor.flatMap { $0.isEmpty ? nil : $0 } : nil
        actorAvatarUrl = actor == nil ? nil : row.actorAvatarUrl.flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case .reaction:
            body = text.map { "\u{201C}\($0)\u{201D}" }
        default:
            body = text
        }
        counts = kind == .reaction ? row.counts.map(RowText.counts).flatMap { $0.isEmpty ? nil : $0 } : nil
        mark = row.isBlueUnread ? .blue : (row.isGrayUnread ? .ring : .none)
        gray = !row.isMention && (row.muted || cardMuted)
        collapsedLines = row.isMention && row.unread ? Self.unreadMentionLines : Self.bodyLines
        self.expanded = expanded
        bodyLines = expanded ? Self.expandedLines : collapsedLines
    }
}

// MARK: - Cards

public enum CardText {
    /// Line 3 on the right: "opened 3 days ago by alice · updated 2 hr ago"
    /// (DESIGN.md, "Card header"). Without `created_at` (right after the
    /// move from 0.2) "opened …" is left out, without an author "by …".
    public static func times(_ card: Card, now: Int64) -> String {
        var first: [String] = []
        if let created = card.createdAt { first.append("opened " + RelativeTime.ago(now - created)) }
        if !card.author.isEmpty { first.append("by " + card.author) }
        let updated = "updated " + RelativeTime.ago(now - card.updatedAt)
        return first.isEmpty ? updated : first.joined(separator: " ") + " · " + updated
    }

    /// The exact times on hover.
    public static func exactTimes(_ card: Card, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let created = card.createdAt { parts.append("Opened " + RelativeTime.dateTime(created, timeZone: timeZone)) }
        parts.append("Updated " + RelativeTime.dateTime(card.updatedAt, timeZone: timeZone))
        return parts.joined(separator: " · ")
    }
}

/// The my review mark at the left of the status icons on line 1
/// (DESIGN.md, "Card", "My review mark"): one mark with three states.
/// Waiting for your review outranks a verdict; none on a merged or closed
/// PR or on your own PR.
public enum MyReviewMark: Equatable {
    case waiting, approved, changesRequested

    public static func of(_ card: Card) -> MyReviewMark? {
        guard !card.isFinished, !card.authoredByMe else { return nil }
        if card.awaitingReview { return .waiting }
        switch card.myReview?.value {
        case .approved?: return .approved
        case .changesRequested?: return .changesRequested
        case nil: return nil
        }
    }

    /// Its tooltip, worded as the status icons' (`Review: Approved`).
    public var toolTip: String {
        switch self {
        case .waiting: return "Review requested"
        case .approved: return "My review: Approved"
        case .changesRequested: return "My review: Changes requested"
        }
    }

    public var sign: BoardIcon {
        switch self {
        case .waiting: return BoardIcons.myReviewWaiting
        case .approved: return BoardIcons.myReviewApproved
        case .changesRequested: return BoardIcons.myReviewChangesRequested
        }
    }

    /// The grid the sign is drawn on and its size at text size 12: the
    /// eye is the rows' 16 by 16 picture at 12 pt, ✓ and × a 10 by 10
    /// picture at 10 pt (DESIGN.md, "Constants").
    public var signGrid: Double { self == .waiting ? 16 : 10 }
    public var signSize: Double { self == .waiting ? 12 : 10 }

    /// Ground and sign in light, and in dark the color laid over the card
    /// at an opacity for the ground (DESIGN.md, "Constants").
    public var lightGround: LabelRGB {
        switch self {
        case .waiting: return LabelRGB(hex: 0xFBE3D6)
        case .approved: return LabelRGB(hex: 0xDDF4E4)
        case .changesRequested: return LabelRGB(hex: 0xFBE0E0)
        }
    }

    public var lightSign: LabelRGB {
        switch self {
        case .waiting: return LabelRGB(hex: 0xA0390A)
        case .approved: return LabelRGB(hex: 0x136C2E)
        case .changesRequested: return LabelRGB(hex: 0xA1161F)
        }
    }

    public var darkOver: (color: LabelRGB, alpha: Double) {
        switch self {
        case .waiting: return (LabelRGB(hex: 0xC7420D), 0.30)
        case .approved: return (LabelRGB(hex: 0x1F8A3E), 0.28)
        case .changesRequested: return (LabelRGB(hex: 0xA1161F), 0.36)
        }
    }

    public var darkSign: LabelRGB {
        switch self {
        case .waiting: return LabelRGB(hex: 0xFFA77E)
        case .approved: return LabelRGB(hex: 0x6CD58C)
        case .changesRequested: return LabelRGB(hex: 0xFF9A9F)
        }
    }

    /// The ground and the sign over `card` (a card that is not selected)
    /// in light or dark.
    public func colors(dark: Bool, card: LabelRGB) -> (ground: LabelRGB, sign: LabelRGB) {
        guard dark else { return (lightGround, lightSign) }
        return (card.under(darkOver.color, alpha: darkOver.alpha), darkSign)
    }
}

// MARK: - API usage

/// The header's API usage (DESIGN.md, "Rate limits"): `API` and one bar
/// with the percentage inside, like a battery. The value is the higher
/// usage rate of GraphQL and REST (the other one while one has no value
/// yet), cut down to a whole percent; 80% or more is the warning color.
/// No numbers and no tooltip. `API –` and no bar before any value.
public struct ApiUsage: Equatable {
    /// The bar's length, 0 to 1; nil before any value.
    public var fraction: Double?
    /// `25%` inside the bar; nil before any value.
    public var percent: String?
    public var warn: Bool

    public init(_ rateLimit: RateLimit?) {
        let rates = [rateLimit?.graphql, rateLimit?.rest].compactMap { $0 }.compactMap(Self.rate)
        guard let top = rates.max() else {
            fraction = nil
            percent = nil
            warn = false
            return
        }
        fraction = min(max(top, 0), 1)
        percent = "\(Self.wholePercent(top))%"
        warn = top >= Self.warnAt
    }

    /// 80% or more warns (DESIGN.md, "Rate limits").
    static let warnAt = 0.8

    /// `used / limit`, nil without a limit.
    static func rate(_ limit: Limit) -> Double? {
        guard limit.limit > 0 else { return nil }
        return Double(limit.used) / Double(limit.limit)
    }

    /// The rate in whole percent, cut down: 24.98% is 24%.
    static func wholePercent(_ rate: Double) -> Int {
        Int((max(rate, 0) * 100).rounded(.down))
    }

    /// `API 25%` or `API –`, for the accessibility text.
    public var text: String {
        "API " + (percent ?? "\u{2013}")
    }

    static func number(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// One line of API usage in Settings › Accounts (DESIGN.md, "Settings ›
/// Accounts"): `GraphQL API` or `REST API`, the description `Resets at
/// 14:05` (the local time of the reset), and the value `1,240 / 5,000`
/// (usage and limit, the warning color at 80% or more). Before any value:
/// `–` and no description. The last values stay after the reset time
/// until the next answer.
public struct ApiUsageLine: Equatable {
    public var title: String
    public var value: String
    public var detail: String?
    public var warn: Bool

    public init(title: String, _ limit: Limit?, timeZone: TimeZone = .current) {
        self.title = title
        guard let limit, limit.limit > 0 else {
            value = "\u{2013}"
            detail = nil
            warn = false
            return
        }
        value = ApiUsage.number(limit.used) + " / " + ApiUsage.number(limit.limit)
        detail = limit.resetAt.map { "Resets at " + RelativeTime.clock($0, timeZone: timeZone) }
        warn = (ApiUsage.rate(limit) ?? 0) >= ApiUsage.warnAt
    }

    /// GraphQL first, then REST.
    public static func lines(_ rateLimit: RateLimit?, timeZone: TimeZone = .current) -> [ApiUsageLine] {
        [
            ApiUsageLine(title: "GraphQL API", rateLimit?.graphql, timeZone: timeZone),
            ApiUsageLine(title: "REST API", rateLimit?.rest, timeZone: timeZone),
        ]
    }

}

// MARK: - Text size

/// `text_size` (DESIGN.md, "Text size"): the body text in points; other
/// text, row heights, avatars and the popover's width follow it in
/// proportion to 12.
public enum TextSize {
    public static let configKey = "text_size"
    public static let base = 12
    public static let range = 9...18
    public static let popoverWidth: Double = 460
    public static let outOfRange = "Enter a number from 9 to 18"
    public static let notWhole = "Enter a whole number"

    public enum Change: Equatable { case larger, smaller, reset }

    /// A value from the daemon, kept inside the range.
    public static func clamp(_ value: Int64?) -> Int {
        guard let value else { return base }
        return Int(min(max(value, Int64(range.lowerBound)), Int64(range.upperBound)))
    }

    public static func ratio(_ size: Int) -> Double {
        Double(size) / Double(base)
    }

    public static func width(_ size: Int) -> Double {
        popoverWidth * ratio(size)
    }

    /// The value ⌘=, ⌘− or ⌘0 asks for, or nil when nothing should go out:
    /// ⌘= at 18, ⌘− at 9 and ⌘0 at 12.
    public static func next(_ current: Int, _ change: Change) -> Int? {
        let wanted: Int
        switch change {
        case .larger: wanted = current + 1
        case .smaller: wanted = current - 1
        case .reset: wanted = base
        }
        return range.contains(wanted) && wanted != current ? wanted : nil
    }

    /// The Settings field: a whole number from 9 to 18, else the message.
    public static func parse(_ text: String) -> Result<Int, TextSizeError> {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { return .failure(TextSizeError(message: notWhole)) }
        guard range.contains(number) else { return .failure(TextSizeError(message: outOfRange)) }
        return .success(number)
    }
}

public struct TextSizeError: Error, Equatable {
    public var message: String
}

// MARK: - Settings: tokens

public enum TokenLabelTone: Equatable { case good, caution, bad, neutral }

public struct TokenLabel: Equatable {
    public var text: String
    public var tone: TokenLabelTone

    public init(_ text: String, _ tone: TokenLabelTone) {
        self.text = text
        self.tone = tone
    }
}

public enum TokenState {
    /// The state text of the Token row: the first that applies (DESIGN.md,
    /// "Token status"), nil when all is well.
    public static func label(account: Account, keychain: KeychainState, checking: Bool, now: Int64) -> TokenLabel? {
        if checking { return TokenLabel("Checking…", .neutral) }
        if keychain != .ok { return TokenLabel("Keychain unavailable", .caution) }
        let kinds = Set(account.warnings.compactMap { $0.kind.value })
        if !account.token.registered || kinds.contains(.noToken) { return TokenLabel("No token", .neutral) }
        if kinds.contains(.tokenInvalid) { return TokenLabel("Invalid", .bad) }
        if let warning = account.warnings.first(where: { $0.kind.value == .tokenExpiring }) {
            let until = warning.until ?? account.token.expiresAt ?? now
            return TokenLabel("Expires in " + RelativeTime.days(RelativeTime.daysUntil(until, now: now)), .caution)
        }
        if kinds.contains(.scopeMissing) { return TokenLabel("Missing scope", .caution) }
        if kinds.contains(.ssoRequired) { return TokenLabel("SSO authorization required", .caution) }
        return nil
    }

    /// The description under Token: "Expires 2027-02-01", none without an
    /// expiry.
    public static func expiry(_ account: Account, timeZone: TimeZone = .current) -> String? {
        account.token.expiresAt.map { "Expires " + RelativeTime.date($0, timeZone: timeZone) }
    }

    /// Edit… shows unless the Keychain cannot be read.
    public static func canEdit(keychain: KeychainState) -> Bool { keychain == .ok }

    /// The masked saved token in Edit…: always 12 bullets.
    public static let masked = String(repeating: "\u{2022}", count: 12)
}

/// How one result of a test reads (Sheets.html).
public struct TestResultLine: Equatable {
    public enum Tone: Equatable { case good, bad, caution, neutral }
    public var label: String
    public var text: String
    public var tone: Tone
    /// `Authorize…` with its URL.
    public var authorize: String?

    public init(_ result: TestResult) {
        label = result.label
        authorize = nil
        switch result.outcome.value {
        case .ok:
            if result.item.value == .account {
                text = result.text
                tone = .neutral
            } else {
                text = "\u{2713} " + result.text
                tone = .good
            }
        case .failed:
            text = "\u{2717} " + result.text
            tone = .bad
        case .ssoRequired:
            text = result.text
            tone = .caution
            authorize = result.url ?? CreateTokenURL.tokenSettings
        case .cantCheck, nil:
            text = result.text
            tone = .neutral
        }
    }

    /// "You can save now and test again later." shows when some item is not
    /// OK.
    public static func allOK(_ results: [TestResult]) -> Bool {
        results.allSatisfy { $0.outcome.value == .ok }
    }

    /// Save is off while the Account item failed.
    public static func accountFailed(_ results: [TestResult]) -> Bool {
        results.contains { $0.item.value == .account && $0.outcome.value == .failed }
    }
}

public enum CreateTokenURL {
    /// DESIGN.md, "Tokens": a classic PAT with repo, notifications and
    /// read:org; no expiry, so GitHub's default applies.
    public static let classic =
        "https://github.com/settings/tokens/new?scopes=repo,notifications,read:org&description=shiibar-gh"
    public static let tokenSettings = "https://github.com/settings/tokens"
}

// MARK: - Settings: texts

public enum SettingsText {
    /// Launch at login's line when the registration failed (DESIGN.md,
    /// "Settings").
    public static let loginItemBlocked = "Allow \(MainMenu.appName) in System Settings › General › Login Items"
    public static let colorDetail = "Tints this account's icon and the square next to its name."
    public static let shortcutDetail = "Opens this account's popover or window from any app."
    public static let removeAccountDetail =
        "Deletes this account and its owners from \(MainMenu.appName): token, PRs, mutes and settings. Nothing changes on GitHub."
    public static let removeOwnerDetail =
        "Deletes this owner from \(MainMenu.appName): its PRs and settings. Nothing changes on GitHub."
    public static let enabledDetail = "Off hides this owner's PRs and stops fetching."
    public static let notifyDetail = "Off keeps the table below but sends no notifications for this owner."
    public static let skipDraftsDetail = "Events on draft PRs stay in the list but never notify."
    public static let copyDetail = "Replaces the table above with that owner's."
    public static let mutedReposDetail = "Hidden unless Filter shows muted pull requests. Not applied to your own PRs."
    public static let mutedUsersDetail = "Their PRs (not yours) and their events. Bots are users too."
    public static let mutedPullRequestsDetail = "Single pull requests you muted."
    public static let autoDismissDetail = "Merged and closed PRs move to Dismissed after this many days"
    public static let keepDismissedDetail = "Dismissed PRs can be restored for this many days"
    public static let confirmDismissTitle = "Confirm before dismissing"
    public static let confirmDismissDetail = "Asks when you press × on a card or Dismiss all"
    public static let ssoNote =
        "If an organization enforces SAML SSO, authorize the token for it after creating it (Configure SSO on the token page)."
    public static let textSizeDetail = "Text in the popover and its window"
    public static let saveLater = "You can save now and test again later."
    public static let ownerNotFound = "Owner not found"
    public static let unreachable = "Couldn't reach GitHub"

    public static func removeAccountTitle(_ login: String) -> String { "Remove \(login)?" }
    public static func removeOwnerTitle(_ name: String) -> String { "Remove \(name)?" }
    public static func notifyTitle(_ owner: String) -> String { "Notify for \(owner)" }
    public static func tokenSheetTitle(_ login: String) -> String { "Token for \(login)" }
    public static func addOwnerTitle(_ login: String) -> String { "Add owner to \(login)" }
    public static func copyTitle(_ owner: String) -> String { "Copy table to \(owner)" }
    public static func copyNote(_ owner: String) -> String {
        "Replaces \(owner)'s table. The switches stay as they are."
    }

    /// The note of the Add owner sheet (Sheets.html).
    public static func addOwnerNote(_ owner: String) -> String {
        "The account's token reads pull requests in \(owner.isEmpty ? "this owner" : owner)'s repositories."
    }

    /// The event table's rows, grouped as DESIGN.md, "Row kinds and states".
    public static let eventGroups: [(String, [EventKind])] = [
        ("Reviews and mentions", [.reviewRequested, .teamReviewRequested, .assigned, .myReview, .mentioned, .teamMentioned]),
        ("Comments", [.comment, .commentOther, .reply, .replyMentioned, .reaction]),
        ("My pull requests", [.approved, .changesRequested, .checksFailed, .checksPassed, .conflicts, .mergeable]),
        ("Any pull request", [.readyForReview, .convertedToDraft, .mergeQueueAdded, .mergeQueueRemoved, .mergedClosed, .reopened]),
    ]

    public static func eventTitle(_ kind: EventKind) -> String {
        switch kind {
        case .reviewRequested: return "Review requested"
        case .teamReviewRequested: return "Review requested to my team"
        case .assigned: return "Assigned"
        case .myReview: return "My review"
        case .mentioned: return "Mentioned"
        case .teamMentioned: return "My team mentioned"
        case .comment: return "Comment on my PR"
        case .commentOther: return "Comment on other PRs"
        case .reply: return "Reply in a thread I commented in"
        case .replyMentioned: return "Reply in a thread I was mentioned in"
        case .reaction: return "Reaction to my comment"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .checksFailed: return "Checks failed"
        case .checksPassed: return "Checks passed"
        case .conflicts: return "Conflicts"
        case .mergeable: return "Mergeable"
        case .readyForReview: return "Ready for review"
        case .convertedToDraft: return "Converted to draft"
        case .mergeQueueAdded: return "Added to merge queue"
        case .mergeQueueRemoved: return "Removed from merge queue"
        case .mergedClosed: return "Merged / Closed"
        case .reopened: return "Reopened"
        }
    }

    /// The message under the owner field of Add owner.
    public static func addOwnerError(_ error: Error) -> String {
        guard let error = error as? DaemonError else { return "\(error)" }
        switch error.code?.value {
        case .notFound: return ownerNotFound
        case .unreachable: return unreachable
        default: return error.message
        }
    }
}

// MARK: - Empty states

public enum EmptyState {
    public static let all = "No pull requests"
    public static let review = "No pull requests to review"
    public static let mine = "No pull requests of yours"
    public static let dismissed = "No dismissed pull requests"
    public static let nothingMatches = "Nothing matches"
    public static let unreadable = "Couldn't read saved state"
    public static let noAccountsTitle = "No accounts yet"
    public static let noAccountsDetail = "Add an account in Settings"
    public static let noOwnersTitle = "No owners yet"
    public static let noOwnersDetail = "Add an owner in Settings"
}

// MARK: - Dismissed

public enum DismissedText {
    /// `6 days left`: whole days to the end, rounded up; `1 day left`;
    /// `0 days left` once the end has passed while the popover holds the
    /// card (DESIGN.md, "Dismissed list").
    public static func daysLeft(_ expiresAt: Int64?, now: Int64) -> String {
        guard let expiresAt else { return "" }
        let days = expiresAt <= now ? 0 : (expiresAt - now + 86_399) / 86_400
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    /// The note under the heading; `days` is `dismissed_keep_days`.
    public static func note(keepDays: Int64) -> String {
        "Dismissed pull requests are removed after " + RelativeTime.days(keepDays) + "."
    }

    /// The confirmation of a card's × (DESIGN.md, "Confirming ×"); `days`
    /// is `dismissed_keep_days`, as in `note(keepDays:)`.
    public static let confirmTitle = "Dismiss this pull request?"

    public static func confirmText(keepDays: Int64) -> String {
        "It moves to the Dismissed list and is removed after " + RelativeTime.days(keepDays) + ". You can restore it from there."
    }

    /// The confirmation of `Dismiss all` (DESIGN.md, "`Dismiss all`"):
    /// `count` is the number of cards it dismisses, two or more (the
    /// button shows for two or more).
    public static func confirmAllTitle(count: Int) -> String {
        "Dismiss \(count) pull requests?"
    }

    public static func confirmAllText(keepDays: Int64) -> String {
        "They move to the Dismissed list and are removed after " + RelativeTime.days(keepDays) + ". You can restore them from there."
    }

    /// The text button at the right of Done's heading.
    public static let dismissAll = "Dismiss all"

    /// `Dismissed in 2 days` on a card whose automatic Dismiss is due
    /// (`auto_dismiss_at`): whole days to it, rounded up as `daysLeft`, at
    /// least 1 day (DESIGN.md, "Card header"). Nil when none is scheduled.
    public static func dismissedIn(_ autoDismissAt: Int64?, now: Int64) -> String? {
        guard let autoDismissAt else { return nil }
        return "Dismissed in " + RelativeTime.days(RelativeTime.daysUntil(autoDismissAt, now: now))
    }

    /// The tooltip of `Dismissed in N days`; `days` is
    /// `auto_dismiss_after_days`. Only a card in Done is told how to keep
    /// it: an unplaced card has no Done to leave (DESIGN.md, "Card header").
    public static func dismissedInHelp(autoDismissDays: Int64, inDone: Bool) -> String {
        let first = "Automatically dismissed " + RelativeTime.days(autoDismissDays) + " after it is merged or closed."
        return inDone ? first + " Move it out of Done to keep it." : first
    }

    /// The checkbox of the confirmation and its setting, `confirm_dismiss`
    /// (DESIGN.md, "Confirming ×").
    public static let confirmSkip = "Don't ask again"
    public static let confirmKey = "confirm_dismiss"
    public static let keepDaysKey = "dismissed_keep_days"
    public static let autoDismissKey = "auto_dismiss_after_days"
    public static let defaultKeepDays: Int64 = 7
    public static let defaultAutoDismissDays: Int64 = 3
}

// MARK: - Operation failures

/// The verbs of the failure band (DESIGN.md, "Showing what an operation
/// did").
public enum OperationVerb: String, Equatable {
    case dismiss
    case restore
    case mute
    case unmute
    case move
    case add
    case remove
    case markAsRead = "mark as read"
}

public enum OperationFailure {
    /// `Couldn't dismiss: daemon not running`: the daemon's `error`, or
    /// `daemon not running` when it did not answer.
    public static func text(_ verb: OperationVerb, _ error: Error) -> String {
        "Couldn't \(verb.rawValue): " + reason(error)
    }

    public static func reason(_ error: Error) -> String {
        if let error = error as? DaemonError {
            return error.isUnreachable ? "daemon not running" : error.message
        }
        return "\(error)"
    }

    /// How long the band stays without another operation.
    public static let duration: TimeInterval = 10
}
