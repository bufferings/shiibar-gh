import Foundation
@testable import ShiibarGhCore
import XCTest

let utc = TimeZone(identifier: "UTC")!
let T0: Int64 = 1_800_000_000

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
    func scope(_ warnings: [Warning], name: String = "example-org") -> Scope {
        Scope(id: name, name: name, kind: .org, warnings: warnings)
    }

    func testBannerLinesFollowTheTableOrderAndWording() {
        let s = scope([
            Warning(kind: .eventsFetchFailed, token: .scope, message: "example-org/api#407"),
            Warning(kind: .permissionMissing, token: .scope),
            Warning(kind: .ssoRequired, token: .notifications),
            Warning(kind: .costNearCap),
            Warning(kind: .rateLimited, until: T0 + 3_900),
            Warning(kind: .tokenOwnerMismatch, token: .scope),
            Warning(kind: .tokenInvalid, token: .notifications),
            Warning(kind: .fetchFailed, token: .scope, until: T0 + 61),
            Warning(kind: .tokenExpiring, token: .scope, until: T0 + 4 * 86_400 + 10),
            Warning(kind: .noToken, token: .scope),
        ])
        let lines = Warnings.banner(s, now: T0, timeZone: utc).map(\.text)
        XCTAssertEqual(lines, [
            "example-org token expires in 5 days",
            "Couldn't reach GitHub · retrying in 2 min",
            "Notifications token is invalid · Replace it in Settings",
            "example-org token belongs to another account · Replace it in Settings",
            "Polling paused until 09:05 · API limit reached",
            "GraphQL usage is over 80% of the cost cap",
            "SSO authorization required · Authorize in Settings",
            "example-org token is missing a permission · Check it in Settings",
            "Couldn't fetch events for example-org/api #407 · retrying",
        ])
    }

    func testRetryingMinutesRoundUpToAtLeastOne() {
        let cases: [(Int64, String)] = [
            (0, "1 min"), (1, "1 min"), (60, "1 min"), (61, "2 min"), (-30, "1 min"), (600, "10 min"),
        ]
        for (left, want) in cases {
            let s = scope([Warning(kind: .fetchFailed, token: .scope, until: T0 + left)])
            XCTAssertEqual(Warnings.banner(s, now: T0).first?.text, "Couldn't reach GitHub · retrying in \(want)", "\(left)")
        }
    }

    func testOnlyStoppingKindsGetTheTriangle() {
        let triangle: [WarningKind] = [.tokenExpiring, .fetchFailed, .tokenInvalid, .tokenOwnerMismatch, .rateLimited]
        let none: [WarningKind] = [.costNearCap, .ssoRequired, .permissionMissing, .eventsFetchFailed, .noToken]
        for kind in triangle {
            XCTAssertTrue(Warnings.hasTriangle(scope([Warning(kind: kind)])), "\(kind)")
        }
        for kind in none {
            XCTAssertFalse(Warnings.hasTriangle(scope([Warning(kind: kind)])), "\(kind)")
        }
        XCTAssertTrue(Warnings.needsToken(scope([Warning(kind: .noToken)])))
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

    func testRowPresentationTable() {
        let at = T0 - 9 * 60
        struct Case {
            var row: Row
            var label: String
            var meta: String
            var body: String?
            var style: RowStyle
            var dimmed: Bool
            var lines: Int
        }
        let cases = [
            Case(row: Row(id: "1", kind: .mentioned, rowClass: .needsAction, text: "hi\nthere", actor: "alice", occurredAt: at),
                 label: "Mentioned", meta: "alice · 9 min ago", body: "hi there", style: .toDo, dimmed: false, lines: 3),
            Case(row: Row(id: "2", kind: .mentioned, rowClass: .needsAction, text: "x", actor: "alice", occurredAt: at, unread: false),
                 label: "Mentioned", meta: "alice · 9 min ago", body: "x", style: .toDo, dimmed: true, lines: 1),
            Case(row: Row(id: "3", kind: .comment, rowClass: .needsAction, text: "x", actor: "bob", occurredAt: at, unread: false, done: true),
                 label: "Comment", meta: "bob · 9 min ago", body: "x", style: .done, dimmed: true, lines: 1),
            Case(row: Row(id: "4", kind: .botComment, rowClass: .event, text: "Coverage", actor: "codecov", occurredAt: at),
                 label: "Comment", meta: "codecov · 9 min ago", body: "Coverage", style: .event, dimmed: false, lines: 1),
            Case(row: Row(id: "5", kind: .merged, rowClass: .event, actor: "carol", occurredAt: at),
                 label: "Merged", meta: "9 min ago", body: "by carol", style: .event, dimmed: false, lines: 1),
            Case(row: Row(id: "6", kind: .reviewRequested, rowClass: .needsAction, text: "for backend team", actor: "dave", occurredAt: at),
                 label: "Review requested", meta: "9 min ago", body: "for backend team", style: .toDo, dimmed: false, lines: 1),
            Case(row: Row(id: "7", kind: .reviewRequested, rowClass: .event, text: "for you", actor: "dave", occurredAt: at),
                 label: "Review requested", meta: "9 min ago", body: "for you", style: .event, dimmed: false, lines: 1),
            Case(row: Row(id: "8", kind: .reaction, rowClass: .event, text: "Merged", counts: ["HOORAY": 2], occurredAt: at, unread: false),
                 label: "Reaction", meta: "9 min ago", body: "\u{201C}Merged\u{201D}", style: .event, dimmed: true, lines: 1),
            Case(row: Row(id: "9", kind: .conflicts, rowClass: .event, occurredAt: at),
                 label: "Conflicts", meta: "9 min ago", body: nil, style: .event, dimmed: false, lines: 1),
            Case(row: Row(id: "10", kind: .removedFromMergeQueue, rowClass: .event, text: "Checks failed · added by alice", actor: "github-merge-queue", occurredAt: at),
                 label: "Removed from merge queue", meta: "github-merge-queue · 9 min ago", body: "Checks failed · added by alice", style: .event, dimmed: false, lines: 1),
        ]
        for c in cases {
            let p = RowPresentation(c.row, now: T0)
            XCTAssertEqual(p.label, c.label, c.row.id)
            XCTAssertEqual(p.meta, c.meta, c.row.id)
            XCTAssertEqual(p.body, c.body, c.row.id)
            XCTAssertEqual(p.style, c.style, c.row.id)
            XCTAssertEqual(p.dimmed, c.dimmed, c.row.id)
            XCTAssertEqual(p.bodyLines, c.lines, c.row.id)
            XCTAssertEqual(p.hasCheckbox, c.row.isNeedsAction, c.row.id)
        }
        XCTAssertEqual(RowPresentation(cases[7].row, now: T0).counts, "🎉2")
    }

    func testTheTokenLabelIsTheFirstThatApplies() {
        let ok = LastTest(at: 1, results: [TestResult(item: "Checks", outcome: .ok), TestResult(item: "Merge queue", outcome: .unverifiable)])
        let failed = LastTest(at: 1, results: [TestResult(item: "Checks", outcome: .failed, missing: "Actions")])
        let registered = TokenStatus(target: "org", registered: true, lastTest: ok)
        let cases: [(TokenStatus?, [Warning], TokenLabel)] = [
            (nil, [], TokenLabel("No token", .neutral)),
            (TokenStatus(target: "org", registered: false), [], TokenLabel("No token", .neutral)),
            (registered, [Warning(kind: .tokenExpiring, until: T0 + 10), Warning(kind: .tokenInvalid)], TokenLabel("Invalid", .bad)),
            (registered, [Warning(kind: .tokenOwnerMismatch), Warning(kind: .tokenExpiring, until: T0 + 10)], TokenLabel("Belongs to another account", .bad)),
            (registered, [Warning(kind: .tokenExpiring, until: T0 + 10)], TokenLabel("Expires in 1 day", .caution)),
            (registered, [Warning(kind: .tokenExpiring, until: T0 + 5 * 86_400)], TokenLabel("Expires in 5 days", .caution)),
            (TokenStatus(target: "org", registered: true, lastTest: failed), [], TokenLabel("Missing permission", .caution)),
            (registered, [], TokenLabel("Verified", .good)),
            (TokenStatus(target: "org", registered: true), [], TokenLabel("Not tested", .neutral)),
        ]
        for (status, warnings, want) in cases {
            XCTAssertEqual(TokenState.label(status: status, warnings: warnings, now: T0), want)
        }
    }

    func testTokenWarningsComeFromTheirScopeOrFromAnyScopeForTheNotificationsToken() {
        let scopes = [
            Scope(id: "a", warnings: [Warning(kind: .tokenInvalid, token: .notifications), Warning(kind: .tokenExpiring, token: .scope)]),
            Scope(id: "b", warnings: [Warning(kind: .tokenInvalid, token: .notifications)]),
        ]
        XCTAssertEqual(TokenState.notificationsWarnings(scopes).map(\.kind), [.known(.tokenInvalid)])
        XCTAssertEqual(TokenState.scopeWarnings(scopes[0]).map(\.kind), [.known(.tokenExpiring)])
        // The token entry is found by the display name, never by the id.
        let tokens = [TokenStatus(target: "Example-Org", registered: true), TokenStatus(target: "public", registered: false)]
        let org = Scope(id: "opaque-1", name: "example-org", kind: .org)
        XCTAssertEqual(TokenState.status(of: org, in: tokens)?.target, "Example-Org")
        XCTAssertEqual(TokenState.status(of: Scope(id: "opaque-2", name: "Public", kind: .public), in: tokens)?.target, "public")
        XCTAssertFalse(Scope(id: "public", name: "public").isPublic, "Public is told by its kind, not its id")
        XCTAssertEqual(TokenState.masked, "••••••••••••")
    }

    func testTestResultsRead() {
        XCTAssertEqual(TokenState.resultText(TestResult(item: "Checks", outcome: .ok)).status, "OK")
        XCTAssertEqual(TokenState.resultText(TestResult(item: "Checks", outcome: .failed, missing: "Actions")).status, "Failed (Actions)")
        XCTAssertEqual(TokenState.resultText(TestResult(item: "Merge queue", outcome: .unverifiable)).status, "Can't check")
    }

    func testCreateTokenURLs() {
        XCTAssertEqual(
            CreateTokenURL.classic,
            "https://github.com/settings/tokens/new?scopes=notifications,read:org&description=shiibar-gh"
        )
        let org = URLComponents(string: CreateTokenURL.fineGrained(owner: "example-org", type: .organization))!
        XCTAssertEqual(org.path, "/settings/personal-access-tokens/new")
        let items = Dictionary(uniqueKeysWithValues: org.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["name"], "shiibar-gh example-org")
        XCTAssertEqual(items["target_name"], "example-org")
        for permission in ["pull_requests", "contents", "statuses", "actions", "metadata", "members"] {
            XCTAssertEqual(items[permission], "read", permission)
        }
        XCTAssertNil(items["expires_in"], "GitHub's default expiry")
        let user = URLComponents(string: CreateTokenURL.fineGrained(owner: "someone", type: .personal))!
        XCTAssertFalse(user.queryItems!.contains { $0.name == "members" })
        let long = URLComponents(string: CreateTokenURL.fineGrained(owner: String(repeating: "x", count: 50), type: .personal))!
        XCTAssertEqual(long.queryItems!.first { $0.name == "name" }?.value?.count, 40)
        let pub = URLComponents(string: CreateTokenURL.fineGrained(owner: nil, type: .public))!
        XCTAssertEqual(pub.queryItems!.map(\.name), ["name", "description"])
        XCTAssertEqual(pub.queryItems!.first?.value, "shiibar-gh public")
    }

    func testEmptyStates() {
        XCTAssertEqual(EmptyState.cards(filtered: false), "Nothing needs you")
        XCTAssertEqual(EmptyState.cards(filtered: true), "Nothing matches")
        XCTAssertEqual(Warnings.prLabel("o/r#12"), "o/r #12")
    }

    func testTheMenuBarIconFollowsTheOwnerType() {
        XCTAssertEqual(BoardIcons.scope(Scope(id: "public", kind: .public)), BoardIcons.globe)
        XCTAssertEqual(BoardIcons.scope(Scope(id: "o", kind: .org)), BoardIcons.organization)
        XCTAssertEqual(BoardIcons.scope(Scope(id: "u", kind: .user)), BoardIcons.person)
        XCTAssertEqual(BoardIcons.scope(Scope(id: "x")), BoardIcons.person, "the person before the type is fetched")
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
