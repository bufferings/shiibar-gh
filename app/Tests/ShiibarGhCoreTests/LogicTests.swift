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

    func testADevelopmentBuildComparesTheDaemonWithoutItsSuffix() {
        XCTAssertEqual(DaemonLifecycle.daemonVersion(bundleVersion: "0.9.0-dev"), "0.9.0")
        XCTAssertEqual(DaemonLifecycle.daemonVersion(bundleVersion: "0.9.0"), "0.9.0")
        XCTAssertEqual(
            DaemonLifecycle.startAction(
                running: InfoResponse(version: "0.9.0", startedAt: 1),
                appVersion: DaemonLifecycle.daemonVersion(bundleVersion: "0.9.0-dev")),
            .attach)
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
        Account(id: "1000001", login: "example-work", token: token, warnings: warnings)
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
        let none: [WarningKind] = [.graphqlNearLimit, .restNearLimit, .scopeMissing, .ssoRequired, .eventsFetchFailed, .statusFetchFailed]
        for kind in triangle {
            XCTAssertTrue(Warnings.hasTriangle(account([Warning(kind: kind)])), "\(kind)")
        }
        for kind in none {
            XCTAssertFalse(Warnings.hasTriangle(account([Warning(kind: kind)])), "\(kind)")
        }
        XCTAssertEqual(WarningKind.allCases.count, triangle.count + none.count)
    }

    func testMenuBarMarksHaveNoNumber() {
        let marks = MenuBarMarks(Account(id: "a", unread: true, warnings: [Warning(kind: .tokenExpiring)]))
        XCTAssertEqual(marks, MenuBarMarks(dot: true, triangle: true))
        XCTAssertEqual(MenuBarMarks(Account(id: "a", warnings: [Warning(kind: .statusFetchFailed)])), MenuBarMarks(dot: false, triangle: false))
        XCTAssertEqual(BoardIcons.account, BoardIcons.app, "one glyph for every account")
    }

    /// DESIGN.md, "Screens" and MenuBarIcon.html.
    func testTheMenuBarIconsAccessibilityText() {
        XCTAssertEqual(MenuBarMarks.accessibilityLabel(Account(id: "a", login: "example-work", unread: true, warnings: [Warning(kind: .fetchFailed)])),
                       "Shiibar GH, example-work, unread, needs attention")
        XCTAssertEqual(MenuBarMarks.accessibilityLabel(Account(id: "a", login: "example-user", unread: true)), "Shiibar GH, example-user, unread")
        XCTAssertEqual(MenuBarMarks.accessibilityLabel(Account(id: "a", login: "me", warnings: [Warning(kind: .noToken)])), "Shiibar GH, me, needs attention")
        XCTAssertEqual(MenuBarMarks.accessibilityLabel(Account(id: "a", login: "me")), "Shiibar GH, me")
        XCTAssertEqual(MenuBarMarks.noAccountsLabel, "Shiibar GH, no accounts")
        XCTAssertEqual(MenuBarMarks.noAccountsToolTip, "Shiibar GH")
    }

    /// The fix of the 0.3.0 CPU loop (DESIGN.md, "UI"): the same
    /// appearance, color, dot and triangle set no image; a label or a
    /// tooltip is set only when it changes.
    func testTheStatusItemSetsOnlyWhatChanged() {
        func look(dark: Bool = false, color: AccountColor = .red, dot: Bool = false, triangle: Bool = false, label: String = "l", tip: String = "t") -> StatusItemLook {
            StatusItemLook(dark: dark, color: color, marks: MenuBarMarks(dot: dot, triangle: triangle), accessibilityLabel: label, toolTip: tip)
        }
        let first = StatusItemUpdate(from: nil, to: look())
        XCTAssertTrue(first.image && first.accessibilityLabel && first.toolTip, "the first time sets all")
        XCTAssertTrue(StatusItemUpdate(from: look(), to: look()).isEmpty, "an appearance notification with nothing new sets nothing")
        XCTAssertEqual(StatusItemUpdate(from: look(), to: look(dark: true)), StatusItemUpdate(from: nil, to: look()).with(label: false, tip: false))
        for changed in [look(color: .blue), look(dot: true), look(triangle: true)] {
            let update = StatusItemUpdate(from: look(), to: changed)
            XCTAssertTrue(update.image)
            XCTAssertFalse(update.accessibilityLabel)
            XCTAssertFalse(update.toolTip)
        }
        let label = StatusItemUpdate(from: look(), to: look(label: "m"))
        XCTAssertFalse(label.image)
        XCTAssertTrue(label.accessibilityLabel)
        XCTAssertFalse(label.toolTip)
        let tip = StatusItemUpdate(from: look(), to: look(tip: "u"))
        XCTAssertEqual([tip.image, tip.accessibilityLabel, tip.toolTip], [false, false, true])
    }

    /// The dot is drawn in the accent color, so the image depends on it:
    /// repeated notifications with the same color set nothing, and a new
    /// accent color sets the image once (the 0.3.0 loop came from setting it
    /// on every notification).
    func testTheMenuBarImageIsSetOnceForANewAccentColor() {
        let blue: [CGFloat] = [0, 0.48, 1, 1]
        let purple: [CGFloat] = [0.58, 0.24, 0.59, 1]
        func look(dot: Bool = true, accent: [CGFloat]) -> StatusItemLook {
            StatusItemLook(dark: false, color: .none, marks: MenuBarMarks(dot: dot, triangle: false), accent: accent, accessibilityLabel: "l", toolTip: "t")
        }
        var looks = StatusItemLooks()
        let id = ObjectIdentifier(NSObject())
        var images = 0
        func show(_ look: StatusItemLook) {
            if looks.update(id, to: look).image { images += 1 }
        }
        show(look(accent: blue))
        XCTAssertEqual(images, 1, "the first look sets the image")
        for _ in 0..<5 { show(look(accent: blue)) }
        XCTAssertEqual(images, 1, "notifications with the same color set nothing")
        show(look(accent: purple))
        for _ in 0..<5 { show(look(accent: purple)) }
        XCTAssertEqual(images, 2, "a new accent color sets the image exactly once")
        show(look(dot: false, accent: purple))
        show(look(dot: false, accent: blue))
        XCTAssertEqual(images, 3, "without the dot the accent color does not change the image")
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
            /// The name on line 1: every row a person caused, not the state
            /// changes or Reaction (DESIGN.md, "How rows look").
            var actor: String?
            var body: String?
            var lines: Int
        }
        // Every row is a record: the accent-colored dot while unread; a read row only
        // loses the dot (DESIGN.md, "How rows look").
        let cases = [
            Case(row: Row(id: "1", kind: .mentioned, text: "hi\nthere", actor: "alice", occurredAt: at),
                 label: "Mentioned", actor: "alice", body: "hi there", lines: 3),
            Case(row: Row(id: "2", kind: .mentioned, text: "x", actor: "alice", occurredAt: at, unread: false),
                 label: "Mentioned", actor: "alice", body: "x", lines: 1),
            Case(row: Row(id: "4", kind: .comment, text: "Coverage", actor: "codecov", occurredAt: at),
                 label: "Comment", actor: "codecov", body: "Coverage", lines: 1),
            Case(row: Row(id: "5", kind: .merged, actor: "carol", occurredAt: at),
                 label: "Merged", actor: "carol", body: nil, lines: 1),
            Case(row: Row(id: "6", kind: .teamReviewRequested, text: "for frontend team", actor: "dave", occurredAt: at),
                 label: "Review requested", actor: "dave", body: "for frontend team", lines: 1),
            Case(row: Row(id: "7", kind: .reviewRequested, text: "for you", actor: "dave", occurredAt: at, unread: false),
                 label: "Review requested", actor: "dave", body: "for you", lines: 1),
            Case(row: Row(id: "8", kind: .reaction, text: "Merged", counts: ["HOORAY": 2], occurredAt: at, unread: false),
                 label: "Reaction", actor: nil, body: "\u{201C}Merged\u{201D}", lines: 1),
            Case(row: Row(id: "9", kind: .conflicts, occurredAt: at),
                 label: "Conflicts", actor: nil, body: nil, lines: 1),
            Case(row: Row(id: "10", kind: .mergeQueueRemoved, text: "Checks failed · added by alice", actor: "github-merge-queue", occurredAt: at),
                 label: "Removed from merge queue", actor: "github-merge-queue", body: "Checks failed · added by alice", lines: 1),
            Case(row: Row(id: "10b", kind: .mergeQueueAdded, actor: "mk", occurredAt: at),
                 label: "Added to merge queue", actor: "mk", body: nil, lines: 1),
            Case(row: Row(id: "10c", kind: .readyForReview, actor: "sam", occurredAt: at),
                 label: "Ready for review", actor: "sam", body: nil, lines: 1),
            Case(row: Row(id: "10d", kind: .convertedToDraft, actor: "sam", occurredAt: at, unread: false),
                 label: "Converted to draft", actor: "sam", body: nil, lines: 1),
            // GitHub may give no actor for these events: the row shows no one.
            Case(row: Row(id: "10e", kind: .readyForReview, occurredAt: at),
                 label: "Ready for review", actor: nil, body: nil, lines: 1),
            Case(row: Row(id: "11", kind: .approved, actor: "erin", occurredAt: at),
                 label: "Approved", actor: "erin", body: nil, lines: 1),
            Case(row: Row(id: "12", kind: .replyMentioned, text: "ok", actor: "frank", occurredAt: at),
                 label: "Reply", actor: "frank", body: "ok", lines: 1),
            Case(row: Row(id: "14", kind: .commentOther, text: "lgtm", actor: "hal", occurredAt: at),
                 label: "Comment", actor: "hal", body: "lgtm", lines: 1),
            Case(row: Row(id: "15", kind: .checksPassed, occurredAt: at),
                 label: "Checks passed", actor: nil, body: nil, lines: 1),
            Case(row: Row(id: "16", kind: .reopened, actor: "epage", occurredAt: at),
                 label: "Reopened", actor: "epage", body: nil, lines: 1),
            Case(row: Row(id: "17", kind: .closed, actor: "bw", occurredAt: at),
                 label: "Closed", actor: "bw", body: nil, lines: 1),
            // Who assigned the account; no body (DESIGN.md, "Row text and targets").
            Case(row: Row(id: "18", kind: .assigned, actor: "dana", occurredAt: at),
                 label: "Assigned", actor: "dana", body: nil, lines: 1),
            Case(row: Row(id: "18b", kind: .assigned, occurredAt: at, unread: false),
                 label: "Assigned", actor: nil, body: nil, lines: 1),
            Case(row: Row(id: "13", kind: .teamMentioned, text: "@org/team look", actor: "gus", occurredAt: at),
                 label: "My team mentioned", actor: "gus", body: "@org/team look", lines: 3),
        ]
        for c in cases {
            let p = RowPresentation(c.row, now: T0)
            XCTAssertEqual(p.label, c.label, c.row.id)
            XCTAssertEqual(p.actor, c.actor, c.row.id)
            XCTAssertEqual(p.time, "9 min ago", c.row.id)
            XCTAssertEqual(p.body, c.body, c.row.id)
            XCTAssertFalse(p.gray, c.row.id)
            XCTAssertEqual(p.mark, c.row.unread ? .blue : .none, c.row.id)
            XCTAssertEqual(p.bodyLines, c.lines, c.row.id)
        }
        XCTAssertEqual(RowPresentation(cases.first { $0.row.id == "8" }!.row, now: T0).counts, "🎉2")
        XCTAssertEqual(BoardIcons.row(.known(.reviewRequested)), BoardIcons.eye, "GitHub's eye for a review request")
        XCTAssertEqual(BoardIcons.row(.known(.teamMentioned)), BoardIcons.kindMention)
        XCTAssertEqual(BoardIcons.row(.known(.changesRequested)), BoardIcons.kindChangesRequested)
        XCTAssertEqual(BoardIcons.row(.known(.merged)), BoardIcons.kindMerged)
        XCTAssertEqual(BoardIcons.row(.known(.readyForReview)), BoardIcons.eye, "the same eye")
        XCTAssertEqual(BoardIcons.row(.known(.convertedToDraft)), BoardIcons.kindConvertedToDraft, "the draft pull request of Main.html")
        XCTAssertEqual(BoardIcons.row(.unknown("later")), BoardIcons.kindComment)
        XCTAssertEqual(BoardIcons.row(.known(.approved)), BoardIcons.kindPassed)
        XCTAssertEqual(BoardIcons.row(.known(.checksPassed)), BoardIcons.kindPassed)
        XCTAssertEqual(BoardIcons.row(.known(.closed)), BoardIcons.kindChangesRequested)
        XCTAssertEqual(BoardIcons.row(.known(.reopened)), BoardIcons.kindReopened)
        XCTAssertEqual(BoardIcons.row(.known(.assigned)), BoardIcons.kindAssigned, "the person of Main.html")
    }

    /// The avatar goes with the name: a row that shows no actor shows no
    /// avatar, and an empty URL is none (DESIGN.md, "How rows look").
    func testRowAvatarGoesWithTheName() {
        let url = "https://avatars.example/alice"
        let comment = RowPresentation(Row(id: "1", kind: .comment, text: "x", actor: "alice", actorAvatarUrl: url), now: T0)
        XCTAssertEqual(comment.actor, "alice")
        XCTAssertEqual(comment.actorAvatarUrl, url)
        let noUrl = RowPresentation(Row(id: "2", kind: .merged, actor: "alice", actorAvatarUrl: ""), now: T0)
        XCTAssertEqual(noUrl.actor, "alice")
        XCTAssertNil(noUrl.actorAvatarUrl)
        let checks = RowPresentation(Row(id: "3", kind: .checksFailed, text: "build", actor: "alice", actorAvatarUrl: url), now: T0)
        XCTAssertNil(checks.actor)
        XCTAssertNil(checks.actorAvatarUrl)
        let noActor = RowPresentation(Row(id: "4", kind: .closed, actorAvatarUrl: url), now: T0)
        XCTAssertNil(noActor.actor)
        XCTAssertNil(noActor.actorAvatarUrl)
    }

    /// Muted rows show the gray ring; a muted card's rows are gray except
    /// a mention (DESIGN.md, "How rows look" and "Card").
    func testMutedRowsAreGrayWithTheRing() {
        let muted = RowPresentation(Row(id: "1", kind: .comment, text: "x", actor: "bot", unread: true, muted: true), now: T0)
        XCTAssertEqual(muted.mark, .ring)
        XCTAssertTrue(muted.gray)
        let read = RowPresentation(Row(id: "2", kind: .comment, unread: false, muted: true), now: T0)
        XCTAssertEqual(read.mark, .none)
        let inMutedCard = RowPresentation(Row(id: "3", kind: .comment, unread: false), now: T0, cardMuted: true)
        XCTAssertTrue(inMutedCard.gray)
        let mention = RowPresentation(Row(id: "4", kind: .mentioned, text: "@me", unread: true), now: T0, cardMuted: true)
        XCTAssertEqual(mention.mark, .blue)
        XCTAssertFalse(mention.gray, "a mention keeps the normal color")
        XCTAssertEqual(UnreadMark.of([Row(id: "a", kind: .comment, unread: true, muted: true)]), .ring)
        XCTAssertEqual(UnreadMark.of([Row(id: "a", kind: .comment, unread: true, muted: true), Row(id: "b", kind: .comment, unread: false)]), .ring)
        XCTAssertEqual(UnreadMark.of([Row(id: "a", kind: .mentioned, unread: true, muted: true)]), .blue, "a muted mention still counts")
        XCTAssertEqual(UnreadMark.of([]), .none)
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
            TestResult(item: .account, label: "Account", outcome: .ok, text: "example-work"),
            TestResult(item: .scopes, label: "Scopes", outcome: .failed, text: "Missing (read:org)"),
            TestResult(item: .notifications, label: "Notifications", outcome: .ok, text: "OK"),
            TestResult(item: .owner, label: "example-org", owner: "o2", outcome: .ssoRequired, text: "SSO authorization required", url: "https://sso"),
            TestResult(item: .teamMembership, label: "Team membership", outcome: .cantCheck, text: "Can't check"),
        ]
        let lines = results.map(TestResultLine.init)
        XCTAssertEqual(lines.map(\.text), ["example-work", "✗ Missing (read:org)", "✓ OK", "SSO authorization required", "Can't check"])
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

    /// DESIGN.md, "Rate limits": one bar with the percentage inside for the
    /// API with the higher rate, cut down to a whole percent, the warning
    /// color from 80%; no numbers, no tooltip; `API –` before any value.
    func testApiUsageInTheHeader() {
        let board = ApiUsage(RateLimit(graphql: Limit(used: 1_250, limit: 5_000), rest: Limit(used: 100, limit: 5_000)))
        XCTAssertEqual(board.percent, "25%")
        XCTAssertEqual(board.fraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(board.text, "API 25%")
        XCTAssertFalse(board.warn)
        XCTAssertEqual(ApiUsage(RateLimit(graphql: Limit(used: 1_249, limit: 5_000))).percent, "24%", "24.98% is cut down")
        let high = ApiUsage(RateLimit(graphql: Limit(used: 4_200, limit: 5_000), rest: Limit(used: 100, limit: 5_000)))
        XCTAssertEqual(high.percent, "84%")
        XCTAssertTrue(high.warn)
        let rest = ApiUsage(RateLimit(graphql: Limit(used: 4_000, limit: 10_000), rest: Limit(used: 4_000, limit: 5_000)))
        XCTAssertEqual(rest.percent, "80%", "REST has the higher rate")
        XCTAssertTrue(rest.warn, "80% is in the warning color")
        XCTAssertFalse(ApiUsage(RateLimit(rest: Limit(used: 3_999, limit: 5_000))).warn, "79.98%")
        XCTAssertEqual(ApiUsage(RateLimit(rest: Limit(used: 3_999, limit: 5_000))).percent, "79%")
        XCTAssertEqual(ApiUsage(RateLimit(rest: Limit(used: 6_000, limit: 5_000))).fraction, 1, "the bar stops at its end")
        XCTAssertEqual(ApiUsage(RateLimit(graphql: Limit(used: 50, limit: 5_000))).percent, "1%", "GraphQL alone: REST is null")
        XCTAssertEqual(ApiUsage(RateLimit(rest: Limit(used: 500, limit: 5_000))).percent, "10%", "REST alone: GraphQL is null")
        for none in [ApiUsage(nil), ApiUsage(RateLimit()), ApiUsage(RateLimit(graphql: Limit(used: 0, limit: 0)))] {
            XCTAssertEqual(none.text, "API \u{2013}")
            XCTAssertNil(none.percent)
            XCTAssertNil(none.fraction, "no bar")
            XCTAssertFalse(none.warn)
        }
    }

    /// DESIGN.md, "Settings › Accounts", API usage: GraphQL and REST, each
    /// with its usage and limit (the warning color from 80%) and the local
    /// time of its reset; `–` and no description before a value.
    func testApiUsageInSettings() {
        let utc = TimeZone(identifier: "UTC")!
        // 2026-11-14 14:05 UTC.
        let reset: Int64 = 1_794_665_100
        let lines = ApiUsageLine.lines(
            RateLimit(graphql: Limit(used: 1_240, limit: 5_000, resetAt: reset), rest: Limit(used: 4_000, limit: 5_000, resetAt: reset + 420)),
            timeZone: utc
        )
        XCTAssertEqual(lines.map(\.title), ["GraphQL API", "REST API"])
        XCTAssertEqual(lines[0].value, "1,240 / 5,000")
        XCTAssertEqual(lines[0].detail, "Resets at 14:05")
        XCTAssertFalse(lines[0].warn)
        XCTAssertEqual(lines[1].value, "4,000 / 5,000")
        XCTAssertEqual(lines[1].detail, "Resets at 14:12")
        XCTAssertTrue(lines[1].warn, "REST warns from 80% too")
        let none = ApiUsageLine.lines(RateLimit(graphql: Limit(used: 10, limit: 5_000)), timeZone: utc)
        XCTAssertEqual(none[0].value, "10 / 5,000")
        XCTAssertNil(none[0].detail, "no reset time known")
        XCTAssertEqual(none[1].value, "\u{2013}")
        XCTAssertNil(none[1].detail)
        XCTAssertFalse(none[1].warn)
        XCTAssertEqual(ApiUsageLine.lines(nil).map(\.value), ["\u{2013}", "\u{2013}"])
    }

    func testDismissedDaysLeftAndTheNote() {
        XCTAssertEqual(DismissedText.daysLeft(T0 + 6 * 86_400, now: T0), "6 days left")
        XCTAssertEqual(DismissedText.daysLeft(T0 + 5 * 86_400 + 1, now: T0), "6 days left", "under a day rounds up")
        XCTAssertEqual(DismissedText.daysLeft(T0 + 60, now: T0), "1 day left")
        XCTAssertEqual(DismissedText.daysLeft(T0, now: T0), "0 days left", "past the end while held open")
        XCTAssertEqual(DismissedText.daysLeft(T0 - 600, now: T0), "0 days left")
        XCTAssertEqual(DismissedText.daysLeft(nil, now: T0), "")
        XCTAssertEqual(DismissedText.note(keepDays: 7), "Dismissed pull requests are removed after 7 days.")
        XCTAssertEqual(DismissedText.note(keepDays: 1), "Dismissed pull requests are removed after 1 day.")
    }

    /// `Dismissed in N days` on a card with `auto_dismiss_at` (DESIGN.md,
    /// "Card header"): rounded up like `N days left`, at least 1 day.
    func testDismissedInNDays() {
        XCTAssertEqual(DismissedText.dismissedIn(T0 + 3 * 86_400, now: T0), "Dismissed in 3 days")
        XCTAssertEqual(DismissedText.dismissedIn(T0 + 2 * 86_400 + 1, now: T0), "Dismissed in 3 days", "under a day rounds up")
        XCTAssertEqual(DismissedText.dismissedIn(T0 + 60, now: T0), "Dismissed in 1 day")
        XCTAssertEqual(DismissedText.dismissedIn(T0 - 600, now: T0), "Dismissed in 1 day", "due while held open")
        XCTAssertNil(DismissedText.dismissedIn(nil, now: T0), "nothing scheduled: no text")
        XCTAssertEqual(DismissedText.dismissedInHelp(autoDismissDays: 3, inDone: true),
                       "Automatically dismissed 3 days after it is merged or closed. Move it out of Done to keep it.")
        XCTAssertEqual(DismissedText.dismissedInHelp(autoDismissDays: 1, inDone: true),
                       "Automatically dismissed 1 day after it is merged or closed. Move it out of Done to keep it.")
        XCTAssertEqual(DismissedText.dismissedInHelp(autoDismissDays: 3, inDone: false),
                       "Automatically dismissed 3 days after it is merged or closed.", "an unplaced card")
    }

    func testTheFailureBandText() {
        XCTAssertEqual(OperationFailure.text(.dismiss, DaemonError.unreachable(SocketError.closed)), "Couldn't dismiss: daemon not running")
        XCTAssertEqual(OperationFailure.text(.markAsRead, DaemonError(code: .notFound, message: "Row not found")), "Couldn't mark as read: Row not found")
        let verbs: [OperationVerb] = [.dismiss, .restore, .mute, .unmute, .move, .add, .remove, .markAsRead]
        XCTAssertEqual(verbs.map(\.rawValue), ["dismiss", "restore", "mute", "unmute", "move", "add", "remove", "mark as read"])
        XCTAssertEqual(OperationFailure.duration, 10)
    }

    /// The fields under the Muted lists (DESIGN.md, "Settings › Accounts").
    func testWhatAMutedListTakes() {
        XCTAssertTrue(MuteInput.canAdd(.repo, " example-org/sandbox ", existing: ["example-org/legacy"]))
        XCTAssertFalse(MuteInput.canAdd(.repo, "Example-Org/Legacy", existing: ["example-org/legacy"]), "names compare without case")
        XCTAssertFalse(MuteInput.canAdd(.repo, "", existing: []))
        for bad in ["example-org", "a/b/c", "/repo", "owner/", "a b/c", "a/b#1"] {
            XCTAssertFalse(MuteInput.canAdd(.repo, bad, existing: []), bad)
        }
        XCTAssertTrue(MuteInput.canAdd(.user, "example-bot", existing: []))
        XCTAssertFalse(MuteInput.canAdd(.user, "re novate", existing: []))
        XCTAssertFalse(MuteInput.canAdd(.user, "EXAMPLE-BOT", existing: ["example-bot"]))
        XCTAssertTrue(MuteInput.canAdd(.pr, "example-org/api#402", existing: []))
        for bad in ["example-org/api", "example-org/api#", "example-org/api#x", "example-org/api#0", "api#402", "example-org/api#-1"] {
            XCTAssertFalse(MuteInput.canAdd(.pr, bad, existing: []), bad)
        }
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
        let d = press(2, "d")
        let delete = press(KeyPress.delete, "\u{7F}")
        let cases: [(KeyPress, Bool, Bool, KeyInput, String)] = [
            // In the list.
            (press(KeyPress.upArrow), false, false, .key(.up), "↑"),
            (down, false, false, .key(.down), "↓"),
            (press(KeyPress.returnKey, "\r"), false, false, .key(.open), "⏎"),
            (press(KeyPress.enter), false, false, .key(.open), "keypad Enter"),
            (press(1, "s"), false, false, .pass, "S does nothing now"),
            (d, false, false, .key(.moveTo(.doing)), "D"),
            (press(34, "i"), false, false, .key(.moveTo(.inbox)), "I moves to Inbox"),
            (press(17, "t"), false, false, .pass, "T does nothing, as any other letter"),
            (press(34, "I", [.shift]), false, false, .pass, "⇧I"),
            (press(13, "W", [.shift]), false, false, .pass, "⇧W"),
            (press(13, "w"), false, false, .key(.moveTo(.waiting)), "W"),
            (delete, false, false, .key(.delete), "⌫"),
            (press(KeyPress.upArrow, "", [.option]), false, false, .key(.reorder(up: true)), "⌥↑"),
            (press(KeyPress.downArrow, "", [.option]), false, false, .key(.reorder(up: false)), "⌥↓"),
            (press(18, "1", [.command]), false, false, .key(.tab(.all)), "⌘1"),
            (press(19, "2", [.command]), false, false, .key(.tab(.review)), "⌘2"),
            (press(20, "3", [.command]), false, false, .key(.tab(.mine)), "⌘3"),
            (press(8, "c", [.command]), false, false, .key(.copy), "⌘C"),
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
            (d, true, true, .pass, "D is typed"),
            (press(34, "i"), true, false, .pass, "I is typed in the search field"),
            (delete, true, true, .pass, "⌫ edits the text"),
            (press(8, "c", [.command]), true, true, .pass, "⌘C copies the field's text"),
            (press(19, "2", [.command]), true, false, .key(.tab(.review)), "⌘2 in the field"),
            (press(KeyPress.returnKey, "\r"), true, true, .pass, "⏎ stays in the field"),
            (press(KeyPress.upArrow), true, true, .pass, "↑ stays in the field"),
            (press(3, "f", [.command]), true, true, .key(.find), "⌘F"),
            (press(24, "=", [.command]), true, true, .textSize(.larger), "⌘= in the field"),
            (press(12, "q", [.command]), true, true, .quit, "⌘Q in the field"),
        ]
        for (key, inSearch, hasText, want, name) in cases {
            XCTAssertEqual(KeyRules.decide(key, inSearch: inSearch, hasSearchText: hasText), want, name)
        }
        XCTAssertEqual(KeyRules.decide(esc, inSearch: false, hasSearchText: false, inDismissed: true), .key(.back), "Esc in the Dismissed list")
        XCTAssertEqual(KeyRules.decide(esc, inSearch: true, hasSearchText: true, inDismissed: true), .leaveSearch(clearing: true))
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
        XCTAssertEqual(EmptyState.nothingMatches, "Nothing matches")
        XCTAssertEqual(EmptyState.noAccountsTitle, "No accounts yet")
        XCTAssertEqual(EmptyState.noAccountsDetail, "Add an account in Settings")
        XCTAssertEqual(EmptyState.noOwnersTitle, "No owners yet")
        XCTAssertEqual(EmptyState.noOwnersDetail, "Add an owner in Settings")
        XCTAssertEqual(SettingsText.eventGroups.flatMap(\.1), EventKind.allCases, "every kind once, in table order")
        XCTAssertEqual(SettingsText.eventGroups.map(\.0), ["Reviews and mentions", "Comments", "My pull requests", "Any pull request"])
        XCTAssertEqual(SettingsText.eventGroups.map(\.1.count), [6, 5, 6, 6], "DESIGN.md, the table's headings")
        XCTAssertEqual(
            SettingsText.eventGroups.first?.1, [.reviewRequested, .teamReviewRequested, .assigned, .myReview, .mentioned, .teamMentioned],
            "Assigned follows Review requested to my team"
        )
        XCTAssertEqual(SettingsText.eventTitle(.assigned), "Assigned")
        XCTAssertEqual(
            SettingsText.eventGroups.last?.1, [.readyForReview, .convertedToDraft, .mergeQueueAdded, .mergeQueueRemoved, .mergedClosed, .reopened],
            "the two draft kinds lead Any pull request"
        )
        XCTAssertEqual(SettingsText.eventTitle(.readyForReview), "Ready for review")
        XCTAssertEqual(SettingsText.eventTitle(.convertedToDraft), "Converted to draft")
        XCTAssertEqual(SettingsText.eventTitle(.mergedClosed), "Merged / Closed")
        XCTAssertEqual(SettingsText.eventTitle(.commentOther), "Comment on other PRs")
        XCTAssertEqual(SettingsText.eventTitle(.checksPassed), "Checks passed")
        XCTAssertEqual(SettingsText.eventTitle(.reopened), "Reopened")
        XCTAssertEqual(SettingsText.removeAccountDetail,
                       "Deletes this account and its owners from Shiibar GH: token, PRs, mutes and settings. Nothing changes on GitHub.")
        XCTAssertEqual(SettingsText.removeOwnerDetail, "Deletes this owner from Shiibar GH: its PRs and settings. Nothing changes on GitHub.")
        XCTAssertEqual(SettingsText.enabledDetail, "Off hides this owner's PRs and stops fetching.")
        XCTAssertEqual(SettingsText.copyNote("example-org"), "Replaces example-org's table. The switches stay as they are.")
        XCTAssertEqual(SettingsText.addOwnerNote("example-org"), "The account's token reads pull requests in example-org's repositories.")
        XCTAssertEqual(SettingsText.mutedReposDetail, "Hidden unless Filter shows muted pull requests. Not applied to your own PRs.")
        XCTAssertEqual(SettingsText.mutedUsersDetail, "Their PRs (not yours) and their events. Bots are users too.")
        XCTAssertEqual(SettingsText.mutedPullRequestsDetail, "Single pull requests you muted.")
        XCTAssertEqual(SettingsText.autoDismissDetail, "Merged and closed PRs move to Dismissed after this many days")
        XCTAssertEqual(SettingsText.keepDismissedDetail, "Dismissed PRs can be restored for this many days")
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
        // The shoulders of Assigned (Main.html, "Row Assigned").
        XCTAssertEqual(SVGPath.parse("M2.75 14c.6-2.9 2.7-4.6 5.25-4.6s4.65 1.7 5.25 4.6"), [
            .move(Point(2.75, 14)),
            .curve(Point(3.35, 11.1), Point(5.45, 9.4), Point(8, 9.4)),
            .curve(Point(10.55, 9.4), Point(12.65, 11.1), Point(13.25, 14)),
        ])
        XCTAssertEqual(
            BoardIcons.kindAssigned.elements.first, .circle(cx: 8, cy: 5.5, r: 2.75, dash: nil), "the head"
        )
        XCTAssertEqual(BoardIcons.kindAssigned.lineWidth, BoardIcons.kindReopened.lineWidth, "the line of the other row icons")
        XCTAssertEqual(SVGPath.parse("M8 11.6v.1M1.5 8h13"), [
            .move(Point(8, 11.6)), .line(Point(8, 11.7)), .move(Point(1.5, 8)), .line(Point(14.5, 8)),
        ])
    }
}
