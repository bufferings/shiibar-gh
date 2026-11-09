import Foundation
@testable import ShiibarGhCore
import XCTest

final class LifecycleTests: XCTestCase {
    func testTheStartDecision() {
        let cases: [(InfoResponse?, StartAction)] = [
            (nil, .spawn),
            (InfoResponse(version: "0.1.0", startedAt: 1), .attach),
            (InfoResponse(version: "0.2.0", startedAt: 1), .replace),
        ]
        for (running, want) in cases {
            XCTAssertEqual(DaemonLifecycle.startAction(running: running, appVersion: "0.1.0"), want, "\(String(describing: running))")
        }
    }

    func testRespawnOnlyWhenNothingAnswersAndOursIsNotRunning() {
        let cases: [(Bool, Bool, Bool, Bool)] = [
            // answers, canLaunch, ownRunning, respawn
            (false, true, false, true),
            (true, true, false, false),
            (false, true, true, false),
            (false, false, false, false),
        ]
        for (answers, canLaunch, running, want) in cases {
            XCTAssertEqual(
                DaemonLifecycle.shouldRespawn(answers: answers, canLaunch: canLaunch, ownProcessRunning: running), want,
                "answers=\(answers) canLaunch=\(canLaunch) running=\(running)"
            )
        }
    }

    func testTheBackoffDoublesFromOneSecondUpToThirty() {
        XCTAssertEqual((0..<8).map(ReconnectBackoff.delay(forAttempt:)), [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testTheStateDirectoryFollowsTheOverride() {
        XCTAssertEqual(StateDirectory.root(environment: ["SHIIBAR_GH_STATE_DIR": "/x", "HOME": "/h"]), "/x")
        XCTAssertEqual(StateDirectory.root(environment: ["HOME": "/h"]), "/h/.local/state/shiibar-gh")
        XCTAssertNil(StateDirectory.root(environment: [:]))
        XCTAssertEqual(StateDirectory.socket(root: "/x"), "/x/shiibar-ghd.sock")
    }
}

final class PresentationTests: XCTestCase {
    func account(_ warnings: [Warning], token: TokenInfo = TokenInfo()) -> Account {
        Account(id: "3407303", login: "bufferings-work", token: token, warnings: warnings)
    }

    func testBannerLinesFollowTheTableOrderWordingAndButtons() {
        let lines = Warnings.banner([
            Warning(kind: .eventsFetchFailed, owner: "o2", message: "Couldn't fetch events for example-org/api #407 · retrying"),
            Warning(kind: .ssoRequired, owner: "o2", message: "SSO authorization required for example-org", url: "https://github.com/orgs/x/sso"),
            Warning(kind: .ssoRequired, owner: "o3", message: "SSO authorization required for acme-corp", url: nil),
            Warning(kind: .scopeMissing, message: "Token is missing read:org"),
            Warning(kind: .restNearLimit, message: "REST API usage is over 80% of GitHub's limit"),
            Warning(kind: .graphqlNearLimit, message: "GraphQL API usage is over 80% of GitHub's limit"),
            Warning(kind: .rateLimited, message: "Polling paused until 14:05 · GitHub's limit reached", until: T0 + 3_900),
            Warning(kind: .fetchFailed, message: "Couldn't reach GitHub · retrying in 9 min", until: T0 + 61),
            Warning(kind: .tokenExpiring, message: "Token expires in 9 days", until: T0 + 4 * 86_400 + 10),
            Warning(kind: .tokenInvalid, message: "Token is invalid"),
            Warning(kind: .noToken, message: "No token"),
            Warning(kind: .tokensUnreadable, message: "Saved tokens are unreadable"),
            Warning(kind: .keychainUnavailable, message: "Couldn't read tokens from Keychain"),
        ], now: T0)
        XCTAssertEqual(lines.map(\.text), [
            "Couldn't read tokens from Keychain",
            "Saved tokens are unreadable",
            "No token",
            "Token is invalid",
            "Token expires in 5 days",
            "Couldn't reach GitHub · retrying in 2 min",
            "Polling paused until 14:05 · GitHub's limit reached",
            "GraphQL API usage is over 80% of GitHub's limit",
            "REST API usage is over 80% of GitHub's limit",
            "Token is missing read:org",
            "SSO authorization required for example-org",
            "SSO authorization required for acme-corp",
            "Couldn't fetch events for example-org/api #407 · retrying",
        ])
        XCTAssertEqual(lines.map { $0.button?.title ?? "-" }, [
            "Retry…", "Reset tokens…", "Settings…", "Settings…", "Settings…", "-", "-", "-", "-", "Settings…",
            "Authorize…", "Authorize…", "-",
        ])
        XCTAssertEqual(lines[10].button, .authorize("https://github.com/orgs/x/sso"))
        XCTAssertEqual(lines[11].button, .authorize("https://github.com/settings/tokens"), "url null (the organizations= form): the token settings page")
    }

    func testRetryingMinutesRoundUpToAtLeastOne() {
        let cases: [(Int64, String)] = [
            (0, "1 min"), (1, "1 min"), (60, "1 min"), (61, "2 min"), (-30, "1 min"), (600, "10 min"),
        ]
        for (left, want) in cases {
            let line = Warnings.banner([Warning(kind: .fetchFailed, until: T0 + left)], now: T0).first
            XCTAssertEqual(line?.text, "Couldn't reach GitHub · retrying in \(want)", "\(left)")
        }
        XCTAssertEqual(Warnings.banner([Warning(kind: .tokenExpiring, until: T0 + 100)], now: T0).first?.text, "Token expires in 1 day")
        XCTAssertTrue(Warnings.banner([Warning(kind: .noToken), ], now: T0).count == 1)
        XCTAssertEqual(Warnings.banner([Warning(kind: .keychainUnavailable)], now: T0).first?.text, "Couldn't read tokens from Keychain")
    }

    func testOnlyStoppingKindsGetTheTriangle() {
        let triangle: [WarningKind] = [.keychainUnavailable, .tokensUnreadable, .noToken, .tokenInvalid, .tokenExpiring, .fetchFailed, .rateLimited]
        let none: [WarningKind] = [.graphqlNearLimit, .restNearLimit, .scopeMissing, .ssoRequired, .eventsFetchFailed]
        for kind in triangle {
            XCTAssertTrue(Warnings.hasTriangle(account([Warning(kind: kind)])), "\(kind)")
        }
        for kind in none {
            XCTAssertFalse(Warnings.hasTriangle(account([Warning(kind: kind)])), "\(kind)")
        }
        XCTAssertEqual(WarningKind.allCases.count, triangle.count + none.count)
    }

    func testMenuBarMarks() {
        let marks = MenuBarMarks(Account(id: "a", reviewCount: 3, unread: true, warnings: [Warning(kind: .tokenExpiring)]))
        XCTAssertEqual(marks, MenuBarMarks(count: 3, dot: true, triangle: true))
        XCTAssertEqual(marks.number, "3")
        XCTAssertNil(MenuBarMarks(count: 0, dot: false, triangle: false).number)
        XCTAssertEqual(MenuBarMarks(count: 120, dot: false, triangle: false).number, "99+")
        XCTAssertEqual(BoardIcons.account, BoardIcons.app, "one placeholder glyph for every account")
    }

    /// DESIGN.md, "Screens": "N review requests", "1 review request", "No
    /// review requests" in place of 0.2's "N Todo".
    func testTheMenuBarIconSaysHowManyReviewsWait() {
        XCTAssertEqual(MenuBarMarks.accessibilityLabel(Account(id: "a", login: "me", reviewCount: 2, unread: true, warnings: [Warning(kind: .fetchFailed)])),
                       "me, unread, 2 review requests, warning")
        XCTAssertEqual(MenuBarMarks.accessibilityLabel(Account(id: "a", login: "me", reviewCount: 1)), "me, 1 review request")
        XCTAssertEqual(MenuBarMarks.accessibilityLabel(Account(id: "a", login: "me", reviewCount: 0)), "me, No review requests")
    }

    func testRelativeTimes() {
        let cases: [(Int64, String)] = [
            (0, "just now"), (59, "just now"), (60, "1 min ago"), (3_599, "59 min ago"),
            (3_600, "1 hr ago"), (86_399, "23 hr ago"), (86_400, "1 day ago"), (3 * 86_400, "3 days ago"),
        ]
        for (seconds, want) in cases {
            XCTAssertEqual(RelativeTime.ago(seconds), want)
        }
        XCTAssertEqual(RelativeTime.updated(T0 - 60, now: T0), "Updated 1 min ago")
        XCTAssertEqual(RelativeTime.updated(nil, now: T0), "Not updated yet")
        XCTAssertEqual(RelativeTime.weekdayClock(1_800_090_000, timeZone: utc), "Sat 09:00")
    }

    func testBodiesCollapseLineBreaksAndSpaces() {
        XCTAssertEqual(RowText.normalize("  a\n\nb \t c  "), "a b c")
        XCTAssertEqual(RowText.counts(["HOORAY": 1, "THUMBS_UP": 3, "ZERO": 0]), "👍3 🎉1")
    }

    /// The `counts` keys are the GraphQL `ReactionContent` values (the
    /// daemon's IngestReaction); the public schema has these eight.
    func testEveryReactionContentHasItsEmojiAndUnknownOnesStayReadable() {
        let all = ["THUMBS_UP", "THUMBS_DOWN", "LAUGH", "HOORAY", "CONFUSED", "HEART", "ROCKET", "EYES"]
        XCTAssertEqual(Set(RowText.reactions.map(\.0)), Set(all))
        XCTAssertEqual(RowText.counts(Dictionary(uniqueKeysWithValues: all.map { ($0, 1) })), "👍1 👎1 😄1 🎉1 😕1 ❤️1 🚀1 👀1")
        XCTAssertEqual(RowText.counts(["THUMBS_UP": 2, "PARTY_POPPER": 1]), "👍2 party popper 1")
    }

    func testRowPresentationTable() {
        let at = T0 - 9 * 60
        struct Case {
            var row: Row
            var label: String
            var meta: String
            var body: String?
            var dimmed: Bool
            var lines: Int
        }
        // Every row is a record: the blue dot while unread, faded once read
        // (DESIGN.md, "Row kinds and states"). No checkbox, no orange row.
        let cases = [
            Case(row: Row(id: "1", kind: .mentioned, text: "hi\nthere", actor: "alice", occurredAt: at),
                 label: "Mentioned", meta: "alice · 9 min ago", body: "hi there", dimmed: false, lines: 3),
            Case(row: Row(id: "2", kind: .mentioned, text: "x", actor: "alice", occurredAt: at, unread: false),
                 label: "Mentioned", meta: "alice · 9 min ago", body: "x", dimmed: true, lines: 1),
            Case(row: Row(id: "4", kind: .comment, text: "Coverage", actor: "codecov", occurredAt: at),
                 label: "Comment", meta: "codecov · 9 min ago", body: "Coverage", dimmed: false, lines: 1),
            Case(row: Row(id: "5", kind: .merged, actor: "carol", occurredAt: at),
                 label: "Merged", meta: "9 min ago", body: "by carol", dimmed: false, lines: 1),
            Case(row: Row(id: "6", kind: .teamReviewRequested, text: "for frontend team", actor: "dave", occurredAt: at),
                 label: "Review requested", meta: "9 min ago", body: "for frontend team", dimmed: false, lines: 1),
            Case(row: Row(id: "7", kind: .reviewRequested, text: "for you", actor: "dave", occurredAt: at, unread: false),
                 label: "Review requested", meta: "9 min ago", body: "for you", dimmed: true, lines: 1),
            Case(row: Row(id: "8", kind: .reaction, text: "Merged", counts: ["HOORAY": 2], occurredAt: at, unread: false),
                 label: "Reaction", meta: "9 min ago", body: "\u{201C}Merged\u{201D}", dimmed: true, lines: 1),
            Case(row: Row(id: "9", kind: .conflicts, occurredAt: at),
                 label: "Conflicts", meta: "9 min ago", body: nil, dimmed: false, lines: 1),
            Case(row: Row(id: "10", kind: .mergeQueueRemoved, text: "Checks failed · added by alice", actor: "github-merge-queue", occurredAt: at),
                 label: "Removed from merge queue", meta: "github-merge-queue · 9 min ago", body: "Checks failed · added by alice", dimmed: false, lines: 1),
            Case(row: Row(id: "10b", kind: .mergeQueueAdded, actor: "mk", occurredAt: at),
                 label: "Added to merge queue", meta: "9 min ago", body: "by mk", dimmed: false, lines: 1),
            Case(row: Row(id: "11", kind: .approved, actor: "erin", occurredAt: at),
                 label: "Approved", meta: "9 min ago", body: "by erin", dimmed: false, lines: 1),
            Case(row: Row(id: "12", kind: .replyMentioned, text: "ok", actor: "frank", occurredAt: at),
                 label: "Reply", meta: "frank · 9 min ago", body: "ok", dimmed: false, lines: 1),
            Case(row: Row(id: "13", kind: .teamMentioned, text: "@org/team look", actor: "gus", occurredAt: at),
                 label: "My team mentioned", meta: "gus · 9 min ago", body: "@org/team look", dimmed: false, lines: 3),
        ]
        for c in cases {
            let p = RowPresentation(c.row, now: T0)
            XCTAssertEqual(p.label, c.label, c.row.id)
            XCTAssertEqual(p.meta, c.meta, c.row.id)
            XCTAssertEqual(p.body, c.body, c.row.id)
            XCTAssertEqual(p.dimmed, c.dimmed, c.row.id)
            XCTAssertEqual(p.unreadDot, c.row.unread, c.row.id)
            XCTAssertEqual(p.bodyLines, c.lines, c.row.id)
        }
        XCTAssertEqual(RowPresentation(cases.first { $0.row.id == "8" }!.row, now: T0).counts, "🎉2")
        XCTAssertEqual(BoardIcons.row(.known(.reviewRequested)), BoardIcons.kindReviewRequest)
        XCTAssertEqual(BoardIcons.row(.known(.teamMentioned)), BoardIcons.kindMention)
        XCTAssertEqual(BoardIcons.row(.known(.changesRequested)), BoardIcons.kindChangesRequested)
        XCTAssertEqual(BoardIcons.row(.known(.merged)), BoardIcons.kindMerged)
        XCTAssertEqual(BoardIcons.row(.unknown("later")), BoardIcons.kindComment)
    }

    func testTheTokenStateIsTheFirstThatApplies() {
        let cases: [(Account, KeychainState, Bool, TokenLabel?)] = [
            (account([Warning(kind: .tokenInvalid)]), .ok, true, TokenLabel("Checking…", .neutral)),
            (account([Warning(kind: .noToken)]), .unavailable, false, TokenLabel("Keychain unavailable", .caution)),
            (account([], token: TokenInfo(registered: false)), .ok, false, TokenLabel("No token", .neutral)),
            (account([Warning(kind: .noToken)]), .ok, false, TokenLabel("No token", .neutral)),
            (account([Warning(kind: .tokenExpiring, until: T0 + 10), Warning(kind: .tokenInvalid)]), .ok, false, TokenLabel("Invalid", .bad)),
            (account([Warning(kind: .scopeMissing), Warning(kind: .tokenExpiring, until: T0 + 10)]), .ok, false, TokenLabel("Expires in 1 day", .caution)),
            (account([Warning(kind: .tokenExpiring, until: T0 + 5 * 86_400)]), .ok, false, TokenLabel("Expires in 5 days", .caution)),
            (account([Warning(kind: .ssoRequired), Warning(kind: .scopeMissing)]), .ok, false, TokenLabel("Missing scope", .caution)),
            (account([Warning(kind: .ssoRequired)]), .ok, false, TokenLabel("SSO authorization required", .caution)),
            (account([Warning(kind: .fetchFailed)]), .ok, false, nil),
            (account([]), .ok, false, nil),
        ]
        for (index, (account, keychain, checking, want)) in cases.enumerated() {
            XCTAssertEqual(TokenState.label(account: account, keychain: keychain, checking: checking, now: T0), want, "case \(index)")
        }
        XCTAssertTrue(TokenState.canEdit(keychain: .ok))
        XCTAssertFalse(TokenState.canEdit(keychain: .unreadable))
        XCTAssertEqual(TokenState.expiry(account([], token: TokenInfo(expiresAt: 1_801_440_000)), timeZone: utc), "Expires 2027-02-01")
        XCTAssertNil(TokenState.expiry(account([])))
        XCTAssertEqual(TokenState.masked, "••••••••••••")
    }

    func testTestResultsRead() {
        let results = [
            TestResult(item: .account, label: "Account", outcome: .ok, text: "bufferings-work"),
            TestResult(item: .scopes, label: "Scopes", outcome: .failed, text: "Missing (read:org)"),
            TestResult(item: .notifications, label: "Notifications", outcome: .ok, text: "OK"),
            TestResult(item: .owner, label: "example-org", owner: "o2", outcome: .ssoRequired, text: "SSO authorization required", url: "https://sso"),
            TestResult(item: .teamMembership, label: "Team membership", outcome: .cantCheck, text: "Can't check"),
        ]
        let lines = results.map(TestResultLine.init)
        XCTAssertEqual(lines.map(\.text), ["bufferings-work", "✗ Missing (read:org)", "✓ OK", "SSO authorization required", "Can't check"])
        XCTAssertEqual(lines.map(\.tone), [.neutral, .bad, .good, .caution, .neutral])
        XCTAssertEqual(lines[3].authorize, "https://sso")
        XCTAssertEqual(TestResultLine(TestResult(item: .owner, label: "x", outcome: .ssoRequired, text: "SSO authorization required")).authorize, CreateTokenURL.tokenSettings)
        XCTAssertFalse(TestResultLine.allOK(results))
        XCTAssertTrue(TestResultLine.allOK([results[0], results[2]]))
        XCTAssertFalse(TestResultLine.accountFailed(results))
        XCTAssertTrue(TestResultLine.accountFailed([TestResult(item: .account, label: "Account", outcome: .failed, text: "Belongs to octocat")]))
    }

    func testCreateTokenAsksForTheThreeClassicScopes() {
        let url = URLComponents(string: CreateTokenURL.classic)!
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/settings/tokens/new")
        XCTAssertEqual(url.queryItems?.first { $0.name == "scopes" }?.value, "repo,notifications,read:org")
        XCTAssertEqual(url.queryItems?.first { $0.name == "description" }?.value, "shiibar-gh")
        XCTAssertNil(url.queryItems?.first { $0.name == "expires_in" }, "GitHub's default expiry")
    }

    /// DESIGN.md, "Rate limits": the higher of the two as a whole
    /// percentage, the warning color from 80%, both counts on hover.
    func testApiUsageInTheHeader() {
        let board = ApiUsage(RateLimit(graphql: Limit(used: 1_240, limit: 5_000), rest: Limit(used: 100, limit: 5_000)))
        XCTAssertEqual(board.text, "API 25%", "24.8% shows as on Main.html")
        XCTAssertFalse(board.warn)
        XCTAssertEqual(board.tooltip, "GraphQL API 1,240 / 5,000 · REST API 100 / 5,000")
        let high = ApiUsage(RateLimit(graphql: Limit(used: 4_200, limit: 5_000), rest: Limit(used: 100, limit: 5_000)))
        XCTAssertEqual(high.text, "API 84%")
        XCTAssertTrue(high.warn)
        let rest = ApiUsage(RateLimit(graphql: Limit(used: 10, limit: 5_000), rest: Limit(used: 4_000, limit: 5_000)))
        XCTAssertEqual(rest.text, "API 80%", "REST is the higher one")
        XCTAssertTrue(rest.warn, "80% is in the warning color")
        XCTAssertFalse(ApiUsage(RateLimit(rest: Limit(used: 3_950, limit: 5_000))).warn, "79%")
        let almost = ApiUsage(RateLimit(rest: Limit(used: 3_975, limit: 5_000)))
        XCTAssertEqual(almost.text, "API 80%", "79.5% rounds to 80%")
        XCTAssertFalse(almost.warn, "the color follows the unrounded 79.5%")
        XCTAssertTrue(ApiUsage(RateLimit(graphql: Limit(used: 4_000, limit: 5_000))).warn, "80.0%")
        let one = ApiUsage(RateLimit(graphql: Limit(used: 50, limit: 5_000)))
        XCTAssertEqual(one.text, "API 1%")
        XCTAssertEqual(one.tooltip, "GraphQL API 50 / 5,000 · REST API \u{2013} / \u{2013}")
        for none in [ApiUsage(nil), ApiUsage(RateLimit()), ApiUsage(RateLimit(graphql: Limit(used: 0, limit: 0)))] {
            XCTAssertEqual(none.text, "API \u{2013}")
            XCTAssertNil(none.percent)
            XCTAssertFalse(none.warn)
            XCTAssertNil(none.tooltip)
        }
        XCTAssertEqual(ApiUsage.headerLine(updated: "Updated 1 min ago", usage: board), "Updated 1 min ago · API 25%")
    }

    /// DESIGN.md, "Text size": proportion to 12, 9 to 18, ⌘= at 18 and ⌘−
    /// at 9 send nothing.
    func testTextSizeRatiosAndEdges() {
        XCTAssertEqual(TextSize.ratio(12), 1)
        XCTAssertEqual(TextSize.ratio(9), 0.75)
        XCTAssertEqual(TextSize.ratio(18), 1.5)
        XCTAssertEqual(TextSize.width(12), 460)
        XCTAssertEqual(TextSize.width(9), 345)
        XCTAssertEqual(TextSize.width(18), 690)
        XCTAssertEqual(TextSize.next(12, .larger), 13)
        XCTAssertEqual(TextSize.next(17, .larger), 18)
        XCTAssertNil(TextSize.next(18, .larger), "⌘= at 18 does nothing")
        XCTAssertEqual(TextSize.next(10, .smaller), 9)
        XCTAssertNil(TextSize.next(9, .smaller), "⌘− at 9 does nothing")
        XCTAssertEqual(TextSize.next(18, .reset), 12)
        XCTAssertEqual(TextSize.next(9, .reset), 12)
        XCTAssertNil(TextSize.next(12, .reset), "already 12")
        XCTAssertEqual(TextSize.clamp(nil), 12)
        XCTAssertEqual(TextSize.clamp(30), 18)
        XCTAssertEqual(TextSize.clamp(1), 9)
        XCTAssertEqual(try TextSize.parse(" 9 ").get(), 9)
        XCTAssertEqual(try TextSize.parse("18").get(), 18)
        for text in ["8", "19", "0", "-1"] {
            XCTAssertEqual(TextSize.parse(text), .failure(TextSizeError(message: "Enter a number from 9 to 18")), text)
        }
        for text in ["", "12.5", "abc"] {
            XCTAssertEqual(TextSize.parse(text), .failure(TextSizeError(message: "Enter a whole number")), text)
        }
        XCTAssertEqual(SettingsText.textSizeDetail, "Text in the popover and its window")
    }

    /// DESIGN.md, "Keyboard" and "Search field", as a table.
    func testKeyRules() {
        func press(_ code: UInt16 = 0, _ chars: String = "", _ mods: Set<KeyModifier> = []) -> KeyPress {
            KeyPress(keyCode: code, characters: chars, modifiers: mods)
        }
        let esc = press(KeyPress.escape, "\u{1B}")
        let down = press(KeyPress.downArrow)
        let shiftR = press(15, "R", [.shift])
        let s = press(1, "s")
        let cases: [(KeyPress, Bool, Bool, KeyInput, String)] = [
            // In the list.
            (press(KeyPress.upArrow), false, false, .key(.up), "↑"),
            (down, false, false, .key(.down), "↓"),
            (press(KeyPress.returnKey, "\r"), false, false, .key(.open), "⏎"),
            (press(KeyPress.enter), false, false, .key(.open), "keypad Enter"),
            (s, false, false, .key(.snooze), "S"),
            (shiftR, false, false, .key(.markAllRead), "⇧R"),
            (press(15, "r"), false, false, .pass, "r alone does nothing"),
            (esc, false, false, .pass, "Esc in the list: the popover closes as usual"),
            (press(3, "f", [.command]), false, false, .key(.find), "⌘F"),
            (press(24, "=", [.command]), false, false, .textSize(.larger), "⌘="),
            (press(24, "+", [.command, .shift]), false, false, .textSize(.larger), "⌘+"),
            (press(27, "-", [.command]), false, false, .textSize(.smaller), "⌘−"),
            (press(29, "0", [.command]), false, false, .textSize(.reset), "⌘0"),
            (press(12, "q", [.command]), false, false, .quit, "⌘Q"),
            (press(1, "s", [.option]), false, false, .pass, "⌥S"),
            // In the search field.
            (esc, true, true, .leaveSearch(clearing: true), "Esc with text clears it and goes back"),
            (esc, true, false, .leaveSearch(clearing: false), "Esc without text only goes back"),
            (down, true, true, .leaveSearch(clearing: false), "↓ goes back, text kept"),
            (shiftR, true, false, .pass, "⇧R is typed"),
            (s, true, true, .pass, "S is typed"),
            (press(KeyPress.returnKey, "\r"), true, true, .pass, "⏎ stays in the field"),
            (press(KeyPress.upArrow), true, true, .pass, "↑ stays in the field"),
            (press(3, "f", [.command]), true, true, .key(.find), "⌘F"),
            (press(24, "=", [.command]), true, true, .textSize(.larger), "⌘= in the field"),
            (press(12, "q", [.command]), true, true, .quit, "⌘Q in the field"),
        ]
        for (key, inSearch, hasText, want, name) in cases {
            XCTAssertEqual(KeyRules.decide(key, inSearch: inSearch, hasSearchText: hasText), want, name)
        }
    }

    func testTheNextReturnTime() {
        // T0 is 2027-01-15 08:00 UTC, a Friday.
        XCTAssertEqual(RelativeTime.weekdayClock(SnoozeTime.next("09:00", now: T0, timeZone: utc), timeZone: utc), "Fri 09:00")
        XCTAssertEqual(SnoozeTime.next("09:00", now: T0, timeZone: utc), T0 + 3_600)
        XCTAssertEqual(SnoozeTime.next("08:00", now: T0, timeZone: utc), T0 + 86_400, "now is not after now")
        XCTAssertEqual(SnoozeTime.next("07:30", now: T0, timeZone: utc), T0 + 86_400 - 1_800)
        XCTAssertEqual(SnoozeTime.next(nil, now: T0, timeZone: utc), T0 + 3_600, "09:00 by default")
    }

    func testCardTimes() {
        let card = Card(id: "c", author: "alice", createdAt: T0 - 3 * 86_400, updatedAt: T0 - 2 * 3_600)
        XCTAssertEqual(CardText.times(card, now: T0), "opened 3 days ago by alice · updated 2 hr ago")
        var moved = card
        moved.createdAt = nil
        XCTAssertEqual(CardText.times(moved, now: T0), "by alice · updated 2 hr ago", "right after the move from 0.2")
        moved.author = ""
        XCTAssertEqual(CardText.times(moved, now: T0), "updated 2 hr ago")
        var noAuthor = card
        noAuthor.author = ""
        XCTAssertEqual(CardText.times(noAuthor, now: T0), "opened 3 days ago · updated 2 hr ago")
        XCTAssertEqual(CardText.exactTimes(card, timeZone: utc), "Opened 2027-01-12 08:00 · Updated 2027-01-15 06:00")
        XCTAssertEqual(CardText.exactTimes(moved, timeZone: utc), "Updated 2027-01-15 06:00")
    }

    func testEmptyStatesAndSettingsTexts() {
        XCTAssertEqual(EmptyState.cards(filtered: false), "Nothing needs you")
        XCTAssertEqual(EmptyState.cards(filtered: true), "Nothing matches")
        XCTAssertEqual(EmptyState.noAccountsTitle, "No accounts yet")
        XCTAssertEqual(EmptyState.noAccountsDetail, "Add an account in Settings")
        XCTAssertEqual(EmptyState.noOwnersTitle, "No owners yet")
        XCTAssertEqual(EmptyState.noOwnersDetail, "Add an owner in Settings")
        XCTAssertEqual(SettingsText.eventGroups.flatMap(\.1), EventKind.allCases, "every kind once, in table order")
        XCTAssertEqual(SettingsText.eventTitle(.mergedClosed), "Merged / Closed")
        XCTAssertEqual(SettingsText.addOwnerError(DaemonError(code: .notFound, message: "not found")), "Owner not found")
        XCTAssertEqual(SettingsText.addOwnerError(DaemonError(code: .unreachable, message: "x")), "Couldn't reach GitHub")
        XCTAssertEqual(SettingsText.addOwnerError(DaemonError(code: .invalid, message: "invalid: owner a/b")), "invalid: owner a/b")
        XCTAssertEqual(AccountColor.allCases.map(\.title), ["None", "Red", "Orange", "Yellow", "Green", "Blue", "Purple"])
        XCTAssertNil(AccountColor.none.nsColor)
        XCTAssertEqual(AccountColor.red.nsColor, .systemRed)
        XCTAssertEqual(AccountColor.purple.nsColor, .systemPurple)
    }

    func testKeychainDialogs() {
        XCTAssertEqual(KeychainDialog.unavailable.title, "Couldn't read tokens from Keychain")
        XCTAssertEqual(KeychainDialog.unavailable.action, "Retry")
        XCTAssertEqual(KeychainDialog.unreadable.title, "Saved tokens are unreadable")
        XCTAssertEqual(KeychainDialog.unreadable.action, "Reset tokens")
        XCTAssertEqual(KeychainDialog.unreadable.cancel, "Not now")
        XCTAssertNil(KeychainDialog.for(.ok))
        XCTAssertEqual(KeychainDialog.state(in: [Warning(kind: .keychainUnavailable)]), .unavailable)
        XCTAssertEqual(KeychainDialog.state(in: [Warning(kind: .tokensUnreadable)]), .unreadable)
        XCTAssertEqual(KeychainDialog.state(in: [Warning(kind: .noToken)]), .ok)

        var prompt = KeychainPrompt()
        XCTAssertNil(prompt.update(.ok))
        XCTAssertEqual(prompt.update(.unavailable), .unavailable, "shown once")
        XCTAssertNil(prompt.update(.unavailable), "a new snapshot with the same state does not show it again")
        XCTAssertEqual(prompt.update(.unreadable), .unreadable, "another failure shows its dialog")
        XCTAssertNil(prompt.update(.ok))
        XCTAssertEqual(prompt.update(.unavailable), .unavailable, "after ok, again")
        XCTAssertEqual(prompt.again(.unavailable), .unavailable, "a failed Retry shows it again")
        XCTAssertNil(prompt.again(.ok))
    }

    func testTheRefreshArcEndsWhereTheBoardsArcEnds() {
        // `a5.5 5.5 0 1 1-1.6-3.9` from (13.5, 8) ends at (11.9, 4.1).
        guard case .arc(let cx, let cy, let r, _, let end)? = BoardIcons.refresh.elements.first else {
            return XCTFail("no arc")
        }
        let angle = end * .pi / 180
        XCTAssertEqual(cx + r * cos(angle), 11.9, accuracy: 0.05)
        XCTAssertEqual(cy + r * sin(angle), 4.1, accuracy: 0.05)
    }

    func testSVGPaths() {
        XCTAssertEqual(SVGPath.parse("M2.5 13.5V5l5.5-2.5L13.5 5v8.5z"), [
            .move(Point(2.5, 13.5)), .line(Point(2.5, 5)), .line(Point(8, 2.5)), .line(Point(13.5, 5)),
            .line(Point(13.5, 13.5)), .close,
        ])
        XCTAssertEqual(SVGPath.parse("M2.5 14c.8-3 3-4.5 5.5-4.5s4.7 1.5 5.5 4.5"), [
            .move(Point(2.5, 14)),
            .curve(Point(3.3, 11), Point(5.5, 9.5), Point(8, 9.5)),
            .curve(Point(10.5, 9.5), Point(12.7, 11), Point(13.5, 14)),
        ])
        XCTAssertEqual(SVGPath.parse("M8 11.6v.1M1.5 8h13"), [
            .move(Point(8, 11.6)), .line(Point(8, 11.7)), .move(Point(1.5, 8)), .line(Point(14.5, 8)),
        ])
    }
}
