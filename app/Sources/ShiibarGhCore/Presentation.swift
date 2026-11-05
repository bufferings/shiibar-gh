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

    /// The header line under the scope name.
    public static func updated(_ updatedAt: Int64?, now: Int64) -> String {
        guard let updatedAt else { return "Not updated yet" }
        return "Updated " + ago(now - updatedAt)
    }

    /// Whole minutes until `until`, rounded up, at least 1 (docs/tasks/M3.md,
    /// "Menu bar and popover").
    public static func minutesUntil(_ until: Int64, now: Int64) -> Int64 {
        max(1, (until - now + 59) / 60)
    }

    /// Whole days until `until`, rounded up, at least 1 (DESIGN.md, "Adding a
    /// scope and registering a token in Settings": under a day is 1 day).
    public static func daysUntil(_ until: Int64, now: Int64) -> Int64 {
        max(1, (until - now + 86_399) / 86_400)
    }

    static func days(_ count: Int64) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    /// "14:05" in the given time zone.
    public static func clock(_ at: Int64, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(at)))
    }

    /// "Mon 09:00", for "Snoozed until Mon 09:00".
    public static func weekdayClock(_ at: Int64, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(at)))
    }

    /// "2027-01-20", for token expiry dates in Settings.
    public static func date(_ at: Int64, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(at)))
    }
}

// MARK: - Warnings

public struct BannerLine: Equatable {
    public var kind: WarningKind
    public var text: String
}

public enum Warnings {
    /// The banner order of DESIGN.md, "Showing warnings": top row first.
    public static let bannerOrder: [WarningKind] = [
        .tokenExpiring, .fetchFailed, .tokenInvalid, .tokenOwnerMismatch, .rateLimited,
        .costNearCap, .ssoRequired, .permissionMissing, .eventsFetchFailed,
    ]

    /// The kinds that put the triangle on the menu bar icon: fetching has
    /// stopped or is about to.
    public static let triangleKinds: Set<WarningKind> = [
        .tokenExpiring, .fetchFailed, .tokenInvalid, .tokenOwnerMismatch, .rateLimited,
    ]

    public static func hasTriangle(_ scope: Scope) -> Bool {
        scope.warnings.contains { $0.kind.value.map(triangleKinds.contains) ?? false }
    }

    public static func needsToken(_ scope: Scope) -> Bool {
        scope.warnings.contains { $0.kind.value == .noToken }
    }

    /// Every warning as one banner line, in the order of the table.
    /// `no_token` is not a banner: the popover shows its own state for it.
    public static func banner(_ scope: Scope, now: Int64, timeZone: TimeZone = .current) -> [BannerLine] {
        var lines: [BannerLine] = []
        for kind in bannerOrder {
            for warning in scope.warnings where warning.kind.value == kind {
                lines.append(BannerLine(kind: kind, text: text(warning, kind: kind, scope: scope, now: now, timeZone: timeZone)))
            }
        }
        return lines
    }

    static func text(_ warning: Warning, kind: WarningKind, scope: Scope, now: Int64, timeZone: TimeZone) -> String {
        let token = warning.token?.value == .notifications ? "Notifications token" : "\(scope.name) token"
        switch kind {
        case .tokenExpiring:
            let days = warning.until.map { RelativeTime.daysUntil($0, now: now) } ?? 1
            return "\(token) expires in \(RelativeTime.days(days))"
        case .fetchFailed:
            let minutes = warning.until.map { RelativeTime.minutesUntil($0, now: now) } ?? 1
            return "Couldn't reach GitHub · retrying in \(minutes) min"
        case .tokenInvalid:
            return "\(token) is invalid · Replace it in Settings"
        case .tokenOwnerMismatch:
            return "\(token) belongs to another account · Replace it in Settings"
        case .rateLimited:
            guard let until = warning.until else { return "Polling paused · API limit reached" }
            return "Polling paused until \(RelativeTime.clock(until, timeZone: timeZone)) · API limit reached"
        case .costNearCap:
            return "GraphQL usage is over 80% of the cost cap"
        case .ssoRequired:
            return "SSO authorization required · Authorize in Settings"
        case .permissionMissing:
            return "\(token) is missing a permission · Check it in Settings"
        case .eventsFetchFailed:
            return "Couldn't fetch events for \(prLabel(warning.message)) · retrying"
        case .noToken:
            return "Add a token in Settings"
        }
    }

    /// `owner/repo#123` as `owner/repo #123`, the way cards show it.
    public static func prLabel(_ key: String) -> String {
        guard let hash = key.lastIndex(of: "#") else { return key }
        return key[..<hash] + " " + key[hash...]
    }
}

// MARK: - Rows

public enum RowText {
    /// DESIGN.md, "Row kinds and states": line breaks and runs of white
    /// space become one space.
    public static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// `ReactionContent` values in display order, with their emoji (the same
    /// table as the daemon's notification text).
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
            if let count = counts[key], count > 0 { parts.append("\(key.lowercased())\(count)") }
        }
        return parts.joined(separator: " ")
    }

    public static func label(_ kind: Lenient<RowKind>) -> String {
        guard let kind = kind.value else {
            return kind.rawText.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
        switch kind {
        case .reviewRequested: return "Review requested"
        case .mentioned: return "Mentioned"
        case .comment, .botComment: return "Comment"
        case .reply: return "Reply"
        case .addedToMergeQueue: return "Added to merge queue"
        case .removedFromMergeQueue: return "Removed from merge queue"
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .checksFailed: return "Checks failed"
        case .conflicts: return "Conflicts"
        case .changesRequested: return "Changes requested"
        case .mergeable: return "Mergeable"
        case .reaction: return "Reaction"
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// How a row looks: the board's `.ev`, `.ev-act` and `.ev-dim` classes.
public enum RowStyle: Equatable {
    /// A Needs action row not done yet: orange, with an empty checkbox.
    case toDo
    /// A Needs action row made Done: faded, with a green checkbox.
    case done
    /// An event row, or a Review requested row that is no longer to do.
    case event
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
    public var style: RowStyle
    /// Read rows and Done rows show faded.
    public var dimmed: Bool
    public var unreadDot: Bool
    /// The checkbox shows for Needs action rows only.
    public var hasCheckbox: Bool

    public init(_ row: Row, now: Int64) {
        let kind = row.kind.value
        label = RowText.label(row.kind)
        let time = RelativeTime.ago(now - row.occurredAt)
        let actor = row.actor.flatMap { $0.isEmpty ? nil : $0 }
        let text = row.text.map(RowText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case .merged, .closed, .addedToMergeQueue:
            // The board: "by alice" under the label, the time alone beside it.
            meta = time
            body = text ?? actor.map { "by \($0)" }
        case .reviewRequested, .checksFailed, .changesRequested, .conflicts, .mergeable:
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
        if row.isNeedsAction {
            style = row.done ? .done : .toDo
            hasCheckbox = true
        } else {
            style = .event
            hasCheckbox = false
        }
        unreadDot = row.unread
        dimmed = row.done || !row.unread
        bodyLines = (kind == .mentioned && row.unread) ? 3 : 1
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
    /// The one label beside a token, the first that applies (DESIGN.md,
    /// "Adding a scope and registering a token in Settings"). `warnings`
    /// are the warnings about this token. A test with items that could not
    /// be checked but no Failed counts as Verified.
    public static func label(status: TokenStatus?, warnings: [Warning], now: Int64) -> TokenLabel {
        guard let status, status.registered else { return TokenLabel("No token", .neutral) }
        let kinds = warnings.compactMap { $0.kind.value }
        if kinds.contains(.tokenInvalid) { return TokenLabel("Invalid", .bad) }
        if kinds.contains(.tokenOwnerMismatch) { return TokenLabel("Belongs to another account", .bad) }
        if let until = expiring(status: status, warnings: warnings, now: now) {
            return TokenLabel("Expires in \(RelativeTime.days(RelativeTime.daysUntil(until, now: now)))", .caution)
        }
        guard let test = status.lastTest else { return TokenLabel("Not tested", .neutral) }
        if test.results.contains(where: { $0.outcome.value == .failed }) {
            return TokenLabel("Missing permission", .caution)
        }
        return TokenLabel("Verified", .good)
    }

    /// When the token expires, if that is within the 7 days of DESIGN.md,
    /// "Tokens": from a `token_expiring` warning, else from the token's own
    /// `expires_at`, so the notifications token shows it without any scope.
    static func expiring(status: TokenStatus, warnings: [Warning], now: Int64) -> Int64? {
        if let warning = warnings.first(where: { $0.kind.value == .tokenExpiring }) {
            return warning.until ?? status.expiresAt ?? now
        }
        if let at = status.expiresAt, at > now, at - now <= 7 * 86_400 {
            return at
        }
        return nil
    }

    /// The warnings about the notifications token, from any scope.
    public static func notificationsWarnings(_ scopes: [Scope]) -> [Warning] {
        var seen: [WarningKind] = []
        var result: [Warning] = []
        for warning in scopes.flatMap(\.warnings) where warning.token?.value == .notifications {
            if let kind = warning.kind.value, !seen.contains(kind) {
                seen.append(kind)
                result.append(warning)
            }
        }
        return result
    }

    /// The warnings about a scope's own token.
    public static func scopeWarnings(_ scope: Scope) -> [Warning] {
        scope.warnings.filter { $0.token?.value == .scope }
    }

    /// The `settings_status` entry of a scope's token. The daemon names it
    /// after the scope's display name (`public` for Public); the id is not
    /// read.
    public static func status(of scope: Scope, in tokens: [TokenStatus]) -> TokenStatus? {
        let target = scope.isPublic ? "public" : scope.name
        return tokens.first { $0.target.caseInsensitiveCompare(target) == .orderedSame }
    }

    /// The whole line of one test result: "OK · Checks".
    public static func resultLine(_ result: TestResult) -> String {
        resultText(result).status + " · " + result.item
    }

    /// "OK", "Failed (Actions)" or "Can't check", before " · <item>".
    public static func resultText(_ result: TestResult) -> (status: String, tone: TokenLabelTone) {
        switch result.outcome.value {
        case .ok: return ("OK", .good)
        case .failed: return ("Failed" + (result.missing.map { " (\($0))" } ?? ""), .bad)
        case .unverifiable, .none: return ("Can't check", .neutral)
        }
    }

    /// The masked token: always 12 bullets, never a part of the token.
    public static let masked = String(repeating: "\u{2022}", count: 12)
}

// MARK: - Settings: scopes

public enum ScopeText {
    /// The Remove confirmation (DESIGN.md, "Adding a scope and registering a
    /// token in Settings").
    public static func removeTitle(_ name: String) -> String {
        "Remove \(name)?"
    }

    public static func removeDetail(_ name: String) -> String {
        "Its token is deleted from the Keychain. Add \(name) again to get its Done and Snooze back."
    }
}

/// Return time: the daemon's `HH:MM` and the hour and minute a time picker
/// edits.
public enum ReturnTime {
    /// Hour and minute of `HH:MM`; nil for anything else.
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

    /// A date carrying the time in `calendar`, for a picker that uses the
    /// same calendar: a fixed day, so no daylight saving gap moves it.
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

// MARK: - Settings: Create token

public enum OwnerType: String, Equatable, CaseIterable {
    case organization, personal, `public`

    public var title: String {
        switch self {
        case .organization: return "Organization"
        case .personal: return "Personal account"
        case .public: return "Public"
        }
    }
}

public enum CreateTokenURL {
    public static let classic =
        "https://github.com/settings/tokens/new?scopes=notifications,read:org&description=shiibar-gh"
    public static let tokenSettings = "https://github.com/settings/tokens"
    static let description = "Read-only access for shiibar-gh"

    /// The fine-grained PAT page with what URL parameters can fill in
    /// (docs.github.com, managing-your-personal-access-tokens, "Pre-filling
    /// fine-grained personal access token details using URL parameters":
    /// `name` up to 40 characters, `description`, `target_name`, and one
    /// parameter per permission). No `expires_in`: GitHub's default applies.
    public static func fineGrained(owner: String?, type: OwnerType) -> String {
        var items: [URLQueryItem] = []
        switch type {
        case .public:
            items.append(URLQueryItem(name: "name", value: "shiibar-gh public"))
            items.append(URLQueryItem(name: "description", value: description))
        case .organization, .personal:
            let owner = owner ?? ""
            items.append(URLQueryItem(name: "name", value: String("shiibar-gh \(owner)".prefix(40))))
            items.append(URLQueryItem(name: "description", value: description))
            items.append(URLQueryItem(name: "target_name", value: owner))
            for permission in ["pull_requests", "contents", "statuses", "actions", "metadata"] {
                items.append(URLQueryItem(name: permission, value: "read"))
            }
            if type == .organization {
                items.append(URLQueryItem(name: "members", value: "read"))
            }
        }
        var components = URLComponents(string: "https://github.com/settings/personal-access-tokens/new")!
        components.queryItems = items
        return components.url!.absoluteString
    }

    /// Repository access cannot be set by URL; the token form says which to
    /// pick.
    public static func repositoryAccessHint(_ type: OwnerType) -> String {
        type == .public
            ? "Under Repository access, choose Public repositories"
            : "Under Repository access, choose All repositories"
    }

    /// The type a scope's token is made for when it is replaced.
    public static func ownerType(of scope: Scope) -> OwnerType {
        if scope.isPublic { return .public }
        return scope.kind?.value == .org ? .organization : .personal
    }
}

// MARK: - Empty states

public enum EmptyState {
    public static func cards(filtered: Bool) -> String {
        filtered ? "Nothing matches" : "Nothing needs you"
    }

    public static let activity = "No activity"
    public static let noToken = "Add a token in Settings"
    public static let unreadable = "Couldn't read saved state"
    public static let noScopesTitle = "No scopes yet"
    public static let noScopesDetail = "Add a scope in Settings"
}
