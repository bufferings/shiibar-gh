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
        case .fetchFailed, .rateLimited, .graphqlNearLimit, .restNearLimit, .eventsFetchFailed: return nil
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
        message: "If macOS asked whether shiibar-gh may use the Keychain, allow it, then retry.", action: "Retry"
    )
    public static let unreadable = KeychainDialog(
        state: .unreadable, title: "Saved tokens are unreadable",
        message: "Reset deletes the Keychain item. You enter every token again. PRs, snoozes and settings stay.",
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

    /// The label of a row. Main.html shows a team's review request as
    /// "Review requested" with "for frontend team" under it; the other kinds
    /// use the names of the event table, Merged / Closed split in two.
    public static func label(_ kind: Lenient<RowKind>) -> String {
        guard let kind = kind.value else {
            return kind.rawText.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
        switch kind {
        case .reviewRequested, .teamReviewRequested: return "Review requested"
        case .mentioned: return "Mentioned"
        case .teamMentioned: return "My team mentioned"
        case .comment: return "Comment"
        case .reply, .replyMentioned: return "Reply"
        case .reaction: return "Reaction"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .checksFailed: return "Checks failed"
        case .conflicts: return "Conflicts"
        case .mergeable: return "Mergeable"
        case .mergeQueueAdded: return "Added to merge queue"
        case .mergeQueueRemoved: return "Removed from merge queue"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

public struct RowPresentation: Equatable {
    public var label: String
    /// Reaction counts next to the label, such as "👍3".
    public var counts: String?
    /// "alice · 9 min ago" or "5 min ago".
    public var meta: String
    /// The body under the label line, already normalized.
    public var body: String?
    public var bodyLines: Int
    /// Read rows show faded (DESIGN.md, "Row kinds and states").
    public var dimmed: Bool
    public var unreadDot: Bool

    public init(_ row: Row, now: Int64) {
        let kind = row.kind.value
        label = RowText.label(row.kind)
        let time = RelativeTime.ago(now - row.occurredAt)
        let actor = row.actor.flatMap { $0.isEmpty ? nil : $0 }
        let text = row.text.map(RowText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case .merged, .closed, .mergeQueueAdded, .approved:
            meta = time
            body = text ?? actor.map { "by \($0)" }
        case .reviewRequested, .teamReviewRequested, .checksFailed, .changesRequested, .conflicts, .mergeable:
            meta = time
            body = text
        case .reaction:
            meta = time
            body = text.map { "\u{201C}\($0)\u{201D}" }
        default:
            meta = actor.map { "\($0) · \(time)" } ?? time
            body = text
        }
        counts = kind == .reaction ? row.counts.map(RowText.counts).flatMap { $0.isEmpty ? nil : $0 } : nil
        unreadDot = row.unread
        dimmed = !row.unread
        bodyLines = ((kind == .mentioned || kind == .teamMentioned) && row.unread) ? 3 : 1
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

    public static let reviewRequestedMark = "Review requested"
}

// MARK: - API usage

/// `API 25%` in the header (DESIGN.md, "Rate limits"): the higher of the
/// GraphQL and REST usage as a whole percentage (rounded, as Main.html shows
/// 1,240 / 5,000 as 25%), the warning color from 80.0% of the unrounded
/// usage, both counts on hover, `API –` before any value.
public struct ApiUsage: Equatable {
    public var text: String
    public var percent: Int?
    public var warn: Bool
    public var tooltip: String?

    public init(_ rateLimit: RateLimit?) {
        let limits = [rateLimit?.graphql, rateLimit?.rest].compactMap { $0 }.filter { $0.limit > 0 }
        guard !limits.isEmpty else {
            text = "API \u{2013}"
            percent = nil
            warn = false
            tooltip = nil
            return
        }
        let exact = limits.map { Double($0.used) / Double($0.limit) * 100 }.max() ?? 0
        let whole = Int(min(max(exact.rounded(), 0), 999))
        percent = whole
        text = "API \(whole)%"
        // The color follows the usage itself, as the daemon's 80% warnings
        // do: 79.5% shows as 80% without it.
        warn = exact >= 80
        func pair(_ limit: Limit?) -> String {
            guard let limit, limit.limit > 0 else { return "\u{2013} / \u{2013}" }
            return Self.number(limit.used) + " / " + Self.number(limit.limit)
        }
        tooltip = "GraphQL API " + pair(rateLimit?.graphql) + " · REST API " + pair(rateLimit?.rest)
    }

    static func number(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "Updated 1 min ago · API 25%".
    public static func headerLine(updated: String, usage: ApiUsage) -> String {
        updated + " · " + usage.text
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

// MARK: - Snooze

public enum SnoozeTime {
    public static let configKey = "snooze_return_time"

    /// The next Return time after `now` in the time zone of the Mac: today's
    /// if it is still ahead, else tomorrow's (the daemon's
    /// `next_return_at`). A time skipped by a daylight saving change comes
    /// after the gap.
    public static func next(_ returnTime: String?, now: Int64, timeZone: TimeZone = .current) -> Int64 {
        let (hour, minute) = ReturnTime.parse(returnTime) ?? (9, 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: TimeInterval(now))
        for offset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
                  let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            else { continue }
            let seconds = Int64(at.timeIntervalSince1970)
            if seconds > now { return seconds }
        }
        return now + 86_400
    }
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
    public static let colorDetail = "Tints this account's icon and the dot next to its name."
    public static let removeAccountDetail =
        "Deletes this account and its owners from shiibar-gh: token, PRs, snoozes and settings. Nothing changes on GitHub."
    public static let removeOwnerDetail =
        "Deletes this owner from shiibar-gh: its PRs, snoozes and settings. Nothing changes on GitHub."
    public static let enabledDetail = "Off hides this owner's section and stops fetching."
    public static let notifyDetail = "Off keeps the table below but sends no notifications for this owner."
    public static let skipDraftsDetail = "Events on draft PRs stay in the list but never notify."
    public static let copyDetail = "Replaces the table above with that owner's."
    public static let reposDetail = "Hidden: not in the list. List only: in the list, but no notifications."
    public static let usersDetail = "Same for a user. Bots are users too."
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
        "Replaces \(owner)'s table. The switches and Exclusions stay as they are."
    }

    /// The event table's rows, grouped as DESIGN.md, "Row kinds and states".
    public static let eventGroups: [(String, [EventKind])] = [
        ("Reviews and mentions", [.reviewRequested, .teamReviewRequested, .mentioned, .teamMentioned]),
        ("Comments", [.comment, .reply, .replyMentioned, .reaction]),
        ("My pull requests", [.approved, .changesRequested, .checksFailed, .conflicts, .mergeable]),
        ("Any pull request", [.mergeQueueAdded, .mergeQueueRemoved, .mergedClosed]),
    ]

    public static func eventTitle(_ kind: EventKind) -> String {
        switch kind {
        case .reviewRequested: return "Review requested"
        case .teamReviewRequested: return "Review requested to my team"
        case .mentioned: return "Mentioned"
        case .teamMentioned: return "My team mentioned"
        case .comment: return "Comment on my PR"
        case .reply: return "Reply in a thread I commented in"
        case .replyMentioned: return "Reply in a thread I was mentioned in"
        case .reaction: return "Reaction to my comment"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .checksFailed: return "Checks failed"
        case .conflicts: return "Conflicts"
        case .mergeable: return "Mergeable"
        case .mergeQueueAdded: return "Added to merge queue"
        case .mergeQueueRemoved: return "Removed from merge queue"
        case .mergedClosed: return "Merged / Closed"
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

/// Return time: the daemon's `HH:MM` and the hour and minute a time picker
/// edits.
public enum ReturnTime {
    public static func parse(_ text: String?) -> (hour: Int, minute: Int)? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    public static func format(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    public static func date(_ text: String?, calendar: Calendar) -> Date {
        let (hour, minute) = parse(text) ?? (9, 0)
        let components = DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)
        return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    public static func text(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return format(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    /// The calendar both sides use: Gregorian in UTC.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

// MARK: - Empty states

public enum EmptyState {
    public static func cards(filtered: Bool) -> String {
        filtered ? "Nothing matches" : "Nothing needs you"
    }

    public static let activity = "No activity"
    public static let unreadable = "Couldn't read saved state"
    public static let noAccountsTitle = "No accounts yet"
    public static let noAccountsDetail = "Add an account in Settings"
    public static let noOwnersTitle = "No owners yet"
    public static let noOwnersDetail = "Add an owner in Settings"
}
