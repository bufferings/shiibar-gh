// The list's lines (ListCells.swift): the 0.5 features as the AppKit cards
// lay them out (row bodies with `more` and `less`, `Show less` under the
// rows, muted cards, line 3 wrapping) and the texts they give assistive
// apps. Geometry only: no window, no daemon.

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import XCTest

@MainActor
final class ListLayoutTests: XCTestCase {
    let long = String(repeating: "could you take a look at the migration plan before Friday? ", count: 6)

    func mention(_ id: String, unread: Bool, text: String) -> Row {
        Row(id: id, kind: .mentioned, text: text, actor: "al", occurredAt: 0, unread: unread)
    }

    func comment(_ id: String) -> Row {
        Row(id: id, kind: .comment, text: "pushed a fix", actor: "al", occurredAt: 0, unread: false)
    }

    func line(_ card: Card, expanded: Bool = false, bodies: Set<String> = [], tag: Bool = false) -> CardLine {
        CardLine(card: card, section: "s", showsTag: tag, expanded: expanded, canDrag: true, expandedBodies: bodies)
    }

    func geometry(_ line: CardLine, width: CGFloat = 460) -> CardGeometry {
        LineLayout.card(line, width: width, k: 1, now: 1_000_000)
    }

    // Compact (DESIGN.md, "Compact"): the heading only; the unread mark at
    // the left of line 1.
    func testCompactShowsTheHeadingOnly() {
        let rows = (0..<5).map { mention("m\($0)", unread: $0 == 0, text: "hello") }
        let card = Card(id: "c", rows: rows)
        let full = geometry(line(card))
        var compact = line(card)
        compact.compact = true
        compact.unread = .blue
        let small = geometry(compact)
        XCTAssertFalse(full.rows.isEmpty)
        XCTAssertFalse(full.feet.isEmpty, "+ N more under the rows")
        XCTAssertTrue(small.rows.isEmpty)
        XCTAssertTrue(small.feet.isEmpty)
        XCTAssertEqual(small.size.height, small.header.height)
        XCTAssertEqual(small.header, full.header)
    }

    func testCompactPutsTheUnreadMarkBeforeTheStateLabel() {
        let card = Card(id: "c", stateLabel: .draft, rows: [mention("m", unread: true, text: "hello")])
        var compact = line(card)
        compact.compact = true
        compact.unread = UnreadMark.ring
        let marked = geometry(compact)
        let dot = try! XCTUnwrap(marked.unreadDot)
        let state = try! XCTUnwrap(marked.stateLabel)
        XCTAssertLessThan(dot.maxX, state.minX)
        XCTAssertEqual(dot.width, 7)
        compact.unread = UnreadMark.none
        let plain = geometry(compact)
        XCTAssertNil(plain.unreadDot, "no unread row: nothing, and no room for it")
        XCTAssertLessThan(plain.stateLabel!.minX, state.minX)
        XCTAssertEqual(CardLineView.accessibilityParts(line(card), geometry(line(card)), now: 0).first?.1.hasPrefix("Draft"), true)
    }

    func testAnUnreadMentionShowsThreeLinesAndMore() {
        let card = Card(id: "c", rows: [mention("m", unread: true, text: long)])
        let row = geometry(line(card)).rows[0]
        XCTAssertEqual(row.bodyLines, 3)
        XCTAssertNotNil(row.toggle, "more: the body is cut short")
    }

    func testMoreShowsUpToFiveLinesWithLess() {
        let card = Card(id: "c", rows: [mention("m", unread: true, text: long)])
        let collapsed = geometry(line(card)).rows[0]
        let expanded = geometry(line(card, bodies: ["m"])).rows[0]
        XCTAssertEqual(expanded.bodyLines, 5)
        XCTAssertNotNil(expanded.toggle, "less")
        XCTAssertGreaterThan(expanded.frame.height, collapsed.frame.height)
    }

    func testAReadMentionShowsOneLine() {
        let card = Card(id: "c", rows: [mention("m", unread: false, text: long)])
        let row = geometry(line(card)).rows[0]
        XCTAssertEqual(row.bodyLines, 1)
        XCTAssertNotNil(row.toggle)
    }

    func testABodyThatFitsHasNoToggle() {
        let card = Card(id: "c", rows: [mention("m", unread: true, text: "short")])
        XCTAssertNil(geometry(line(card)).rows[0].toggle)
    }

    func testShowLessEndsTheExpandedRows() {
        let card = Card(id: "c", rows: (1...5).map { comment("r\($0)") })
        let folded = geometry(line(card))
        XCTAssertEqual(folded.rows.count, Listing.visibleRows(card, expanded: false).count)
        XCTAssertEqual(folded.feet.last?.item, .moreRows(card: "c"))
        let open = geometry(line(card, expanded: true))
        XCTAssertEqual(open.rows.count, 5)
        XCTAssertEqual(open.feet.last?.item, .lessRows(card: "c"))
        XCTAssertEqual(open.feet.last?.text, "Show less")
    }

    func testAMutedCardHasTheMutedMark() {
        let card = Card(id: "c", authoredByMe: false, muted: [.author])
        XCTAssertTrue(card.isMuted)
        XCTAssertTrue(geometry(line(card)).marks.contains { $0.0 == "Muted" })
        XCTAssertFalse(geometry(line(Card(id: "d"))).marks.contains { $0.0 == "Muted" })
    }

    func testLineThreeWrapsWhenNarrow() {
        let card = Card(id: "c", base: "main", head: "topic/a-rather-long-branch-name-for-the-change", updatedAt: 0)
        let wide = geometry(line(card), width: 900)
        let narrow = geometry(line(card), width: 300)
        XCTAssertGreaterThan(narrow.header.height, wide.header.height)
        XCTAssertFalse(narrow.line3Fits)
        XCTAssertTrue(wide.line3Fits)
        let times = narrow.timeParts(card, k: 1, now: 1_000_000).times
        XCTAssertGreaterThan(times.minY, narrow.baseHead.minY, "the times go to a line of their own")
    }

    func testEachRowIsItsOwnAccessibilityElementWithItsText() {
        let card = Card(id: "c", title: "Fix the retry path", rows: [mention("m", unread: true, text: "please look"), comment("r")])
        let line = line(card)
        let parts = CardLineView.accessibilityParts(line, geometry(line), now: 1_000_000)
        XCTAssertTrue(parts[0].1.contains("Fix the retry path"))
        XCTAssertEqual(parts.count, 1 + 2)
        XCTAssertTrue(parts[1].1.contains("please look"))
        XCTAssertTrue(parts[1].1.contains("Unread"))
        XCTAssertTrue(parts[2].1.contains("pushed a fix"))
    }
}

/// The values a heading line is drawn from (CardViews.swift): `Dismiss all`
/// on Done's heading, the Dismissed list's repositories (DESIGN.md,
/// "Section size", "Dismissed list").
@MainActor
final class HeadingValueTests: XCTestCase {
    func section(_ key: String, done: Bool, cards: [Card], collapsed: Bool = false) -> SectionLayout {
        SectionLayout(
            key: key, title: done ? "Done" : "Inbox", level: 1, isLeaf: true, detail: "\(cards.count) PRs", collapsed: collapsed,
            cards: collapsed ? [] : cards, more: 0, showLess: false, moreMark: .none, matching: cards, accepts: true, isDone: done
        )
    }

    func testDismissAllIsPartOfTheHeadingsValues() {
        let cards = [Card(id: "a"), Card(id: "b")]
        XCTAssertTrue(HeadingLine(section("review|done", done: true, cards: cards)).dismissAll)
        XCTAssertTrue(HeadingLine(section("mine|done", done: true, cards: cards)).dismissAll)
        XCTAssertFalse(HeadingLine(section("review|done", done: true, cards: [])).dismissAll, "no card to dismiss")
        XCTAssertFalse(HeadingLine(section("review|done", done: true, cards: cards, collapsed: true)).dismissAll, "collapsed")
        XCTAssertFalse(HeadingLine(section("review|inbox", done: false, cards: cards)).dismissAll, "not Done")
        // A change of it is a change of the heading (its image is drawn
        // again).
        XCTAssertNotEqual(HeadingLine(section("review|done", done: true, cards: cards)),
                          HeadingLine(section("review|done", done: true, cards: [])))
    }

    func testARepositoryOfTheDismissedListHasNoFold() {
        let group = DismissedGroup(repository: "example-org/api", detail: "3 PRs", cards: [])
        let first = HeadingLine(group, first: true)
        XCTAssertEqual(first.title, "example-org/api")
        XCTAssertEqual(first.detail, "3 PRs")
        XCTAssertFalse(first.folds)
        XCTAssertFalse(first.dismissAll)
        XCTAssertEqual(first.level, 1)
        XCTAssertNotEqual(first.key, SectionKey.placed(.review, .done))
        let next = HeadingLine(group, first: false)
        XCTAssertLessThan(LineLayout.heading(first, width: 460, k: 1).frame.minY, LineLayout.heading(next, width: 460, k: 1).frame.minY,
                          "closer to the note above the list")
        XCTAssertEqual(LineLayout.heading(next, width: 460, k: 1).frame.minY, 8, "as a band of All")
    }
}

/// A repository band of the Dismissed list takes no press (DESIGN.md,
/// "Dismissed list"): a click, a right click or a Control-click on it does
/// nothing and leaves the selection. No daemon: the socket path names
/// nothing, and no request is sent.
@MainActor
final class DismissedBandPressTests: XCTestCase {
    final class NoOpener: URLOpening { func open(_ url: URL) {} }
    final class NoNotifier: NotificationPresenting {
        func requestAuthorization() {}
        func present(_ notification: DaemonNotification) {}
    }
    final class NoImages: ImageLoading, @unchecked Sendable {
        func load(_ url: URL) async throws -> Data { throw URLError(.fileDoesNotExist) }
    }

    func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 40, y: 10), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    // MARK: Line 1 of a row (DESIGN.md, "How rows look")

    /// A PNG of one pixel, the avatar a test loader hands out (no network).
    nonisolated static let pixel = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
    )!

    final class PixelImages: ImageLoading, @unchecked Sendable {
        func load(_ url: URL) async throws -> Data { DismissedBandPressTests.pixel }
    }

    func rowLine(_ card: Card) -> CardLine {
        CardLine(card: card, section: "s", showsTag: false, expanded: false, canDrag: true)
    }

    func rowShape(_ line: CardLine) -> CardGeometry {
        LineLayout.card(line, width: 460, k: 1, now: 1_000_000)
    }

    func rowCard() -> Card {
        Card(id: "c", rows: [
            Row(id: "m", kind: .merged, actor: "al", actorAvatarUrl: "https://avatars.example/al", occurredAt: 0, unread: false),
            Row(id: "n", kind: .comment, text: "pushed a fix", actor: String(repeating: "very-long-login-name-", count: 4), occurredAt: 0),
            Row(id: "k", kind: .checksFailed, text: "build", occurredAt: 0),
        ])
    }

    /// The time and the chain icon at the same place in every row, whether
    /// the row shows an avatar and a name or not, and however long the
    /// name; a long name is cut, never the time.
    func testTheTimeStaysAtTheRightEndOfEveryRow() {
        let shape = rowShape(rowLine(rowCard()))
        XCTAssertEqual(Set(shape.rows.map(\.chain.minX)).count, 1, "one place for the chain icon")
        XCTAssertEqual(Set(shape.rows.map(\.meta.maxX)).count, 1)
        for row in shape.rows {
            XCTAssertEqual(row.chain.minX - row.meta.maxX, 6, accuracy: 0.01, "6 points from the time to the chain icon")
        }
        var times: [CGFloat] = []
        for (frame, row) in zip(shape.rows, rowCard().rows) {
            let p = RowPresentation(row, now: 600)
            for avatar in [false, true] {
                let parts = LineLayout.rowLine(frame.meta, p, avatar: avatar, k: 1)
                XCTAssertEqual(parts.time.maxX, frame.meta.maxX, accuracy: 0.01, row.id)
                XCTAssertEqual(parts.time.width, Ink.width(p.time, Ink.font(11)), accuracy: 0.01, "the whole time: \(row.id)")
                times.append(parts.time.maxX)
                if let name = parts.name {
                    XCTAssertLessThanOrEqual(name.maxX, parts.time.minX - 6 + 0.01, row.id)
                }
            }
        }
        XCTAssertEqual(Set(times).count, 1)
        let long = RowPresentation(rowCard().rows[1], now: 600)
        let cut = LineLayout.rowLine(shape.rows[1].meta, long, avatar: false, k: 1)
        XCTAssertLessThan(cut.name!.width, Ink.width(long.actor!, Ink.font(11)), "the long name is cut")
        XCTAssertNil(LineLayout.rowLine(shape.rows[2].meta, RowPresentation(rowCard().rows[2], now: 600), avatar: true, k: 1).name,
                     "no name on a state change")
    }

    /// Without the image (no URL, or not loaded) the name takes the
    /// avatar's place; with it, the avatar is 14 points and the name follows.
    func testTheAvatarTakesNoRoomWithoutAnImage() {
        let shape = rowShape(rowLine(rowCard()))
        let p = RowPresentation(rowCard().rows[0], now: 600)
        let without = LineLayout.rowLine(shape.rows[0].meta, p, avatar: false, k: 1)
        let with = LineLayout.rowLine(shape.rows[0].meta, p, avatar: true, k: 1)
        XCTAssertNil(without.avatar)
        XCTAssertEqual(without.name?.minX, shape.rows[0].meta.minX)
        XCTAssertEqual(with.avatar?.size, CGSize(width: 14, height: 14))
        XCTAssertEqual(with.avatar?.minX, shape.rows[0].meta.minX)
        XCTAssertEqual(with.name?.minX ?? 0, (with.avatar?.maxX ?? 0) + 4, accuracy: 0.01)
        let large = LineLayout.rowLine(shape.rows[0].meta, p, avatar: true, k: 1.5)
        XCTAssertEqual(large.avatar?.width, 21, "in proportion to the text size")
    }

    /// The avatar is faint exactly when the row's text is gray: a muted
    /// row, and a muted card's rows except a mention of you or your team.
    func testTheAvatarIsFaintWhenTheTextIsGray() {
        let url = "https://avatars.example/example-user"
        let plain = RowPresentation(Row(id: "a", kind: .comment, text: "x", actor: "example-user", actorAvatarUrl: url), now: 0)
        let muted = RowPresentation(Row(id: "b", kind: .comment, text: "x", actor: "example-user", actorAvatarUrl: url, muted: true), now: 0)
        let inMutedCard = RowPresentation(Row(id: "c", kind: .merged, actor: "example-user", actorAvatarUrl: url), now: 0, cardMuted: true)
        let mention = RowPresentation(Row(id: "d", kind: .teamMentioned, text: "x", actor: "example-user", actorAvatarUrl: url), now: 0, cardMuted: true)
        XCTAssertEqual(CardLineView.avatarOpacity(plain), 1)
        XCTAssertEqual(CardLineView.avatarOpacity(muted), 0.6)
        XCTAssertEqual(CardLineView.avatarOpacity(inMutedCard), 0.6)
        XCTAssertEqual(CardLineView.avatarOpacity(mention), 1, "a mention keeps its normal color in a muted card")
        for p in [plain, muted, inMutedCard, mention] {
            XCTAssertEqual(CardLineView.avatarOpacity(p) < 1, p.gray)
        }
    }

    /// A row without a body (Merged, Approved…) is one line; the label line
    /// keeps the avatar's height.
    func testARowWithoutABodyIsOneLine() {
        let shape = rowShape(rowLine(rowCard()))
        let merged = shape.rows[0]
        let comment = shape.rows[1]
        XCTAssertNil(merged.body)
        XCTAssertNotNil(comment.body)
        XCTAssertLessThan(merged.frame.height, comment.frame.height)
        XCTAssertGreaterThanOrEqual(merged.meta.height, 14)
        let parts = CardLineView.accessibilityParts(rowLine(rowCard()), shape, now: 600)
        XCTAssertEqual(parts[1].1, "Merged, al, 10 min ago", "the name on line 1, no `by`")
    }

    /// The unread dot and the kind icon are centered on line 1 with the
    /// label and the time, with an actor's avatar on line 1 or without.
    func testTheDotAndTheIconAreCenteredOnLineOne() {
        let shape = rowShape(rowLine(rowCard()))
        for row in shape.rows {
            XCTAssertEqual(row.icon.midY, row.label.midY, accuracy: 0.01, row.id)
            XCTAssertEqual(row.dot.midY, row.label.midY, accuracy: 0.01, row.id)
            XCTAssertEqual(row.meta.midY, row.label.midY, accuracy: 0.01, row.id)
        }
    }

    /// Line 1 is as high as the chain button (18): a row without a body
    /// is 1 + 5 + 18 + 6 high with line 1 centered below the dividing line,
    /// and a body starts 1 below line 1.
    func testLineOneIsAsHighAsTheChainButton() {
        let shape = rowShape(rowLine(rowCard()))
        let merged = shape.rows[0]
        let comment = shape.rows[1]
        XCTAssertEqual(merged.frame.height, 30, accuracy: 0.01)
        XCTAssertEqual(merged.label.midY, merged.frame.minY + 1 + 5 + 9, accuracy: 0.01)
        XCTAssertEqual(merged.chain.minY, merged.frame.minY + 1 + 5, accuracy: 0.01)
        let body = try! XCTUnwrap(comment.body)
        XCTAssertEqual(body.minY, comment.frame.minY + 1 + 5 + 18 + 1, accuracy: 0.01)
        XCTAssertEqual(comment.frame.maxY, body.maxY + 6, accuracy: 0.01)
    }

    /// The avatar and the name show the login as their tooltip; the image,
    /// once loaded, moves the name and draws the card again.
    func testTheActorsTooltipAndTheLoadedAvatar() async throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: NoOpener(),
            notifier: NoNotifier()
        )
        let data = app.viewModel("1001")
        let list = data.list(.popover)
        let avatars = AvatarStore(loader: PixelImages())
        Self.kept += [app, data, list, avatars]
        let context = CardContext.of(list, avatars: avatars)
        let env = LineEnvironment(k: 1, now: 600, autoDismissDays: 3, context: context)
        let cardLine = rowLine(rowCard())
        let shape = rowShape(cardLine)
        let view = CardLineView(frame: NSRect(origin: .zero, size: shape.size))
        view.configure(cardLine, geometry: shape, env: env, state: ItemState())
        let frame = shape.rows[0]
        let p = RowPresentation(rowCard().rows[0], now: 600)
        let before = LineLayout.rowLine(frame.meta, p, avatar: false, k: 1)
        XCTAssertEqual(view.tip(at: CGPoint(x: before.name!.midX, y: before.name!.midY)), "al")
        let keyBefore = view.currentDrawKey()
        for _ in 0..<50 where avatars.image(for: "https://avatars.example/al") == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(avatars.image(for: "https://avatars.example/al"), "requested when configured")
        XCTAssertNotEqual(view.currentDrawKey(), keyBefore, "the loaded image draws the card again")
        let after = LineLayout.rowLine(frame.meta, p, avatar: true, k: 1)
        XCTAssertEqual(view.tip(at: CGPoint(x: after.avatar!.midX, y: after.avatar!.midY)), "al")
        XCTAssertEqual(view.tip(at: CGPoint(x: after.name!.midX, y: after.name!.midY)), "al")
        XCTAssertNil(view.tip(at: CGPoint(x: after.time.midX, y: after.time.midY)), "not the time")
        let longFrame = shape.rows[1]
        let long = LineLayout.rowLine(longFrame.meta, RowPresentation(rowCard().rows[1], now: 600), avatar: false, k: 1)
        XCTAssertEqual(view.tip(at: CGPoint(x: long.name!.midX, y: long.name!.midY)), rowCard().rows[1].actor, "the whole login")
    }

    /// A collapsed heading draws its unread mark before the name and says
    /// it to assistive apps; the mark is part of the heading's image.
    func testACollapsedHeadingShowsItsMark() {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: NoOpener(),
            notifier: NoNotifier()
        )
        let data = app.viewModel("1001")
        let list = data.list(.popover)
        Self.kept += [app, data, list]
        let env = LineEnvironment(k: 1, now: 0, autoDismissDays: 3, context: CardContext.of(list, avatars: AvatarStore(loader: NoImages())))
        var section = SectionLayout(
            key: "review|done", title: "Done", level: 1, isLeaf: true, detail: "2 PRs", collapsed: true, cards: [], more: 0,
            showLess: false, moreMark: .none, matching: [], accepts: true, isDone: true
        )
        let heading = HeadingLineView(frame: NSRect(x: 0, y: 0, width: 460, height: 31))
        heading.configure(HeadingLine(section), env: env, state: ItemState())
        let plain = heading.currentDrawKey()
        XCTAssertEqual(heading.accessibilityLabel(), "Done, 2 PRs")
        section.foldMark = .blue
        heading.configure(HeadingLine(section), env: env, state: ItemState())
        XCTAssertNotEqual(heading.currentDrawKey(), plain)
        XCTAssertEqual(heading.accessibilityLabel(), "Done, 2 PRs, Unread")
        section.foldMark = .ring
        heading.configure(HeadingLine(section), env: env, state: ItemState())
        XCTAssertEqual(heading.accessibilityLabel(), "Done, 2 PRs, Unread, muted")
    }

    /// The models live as long as the process, as in the app: the list's
    /// views and the context they share hold them unowned, and work they
    /// scheduled may run after the test.
    static var kept: [AnyObject] = []

    func testABandTakesNoPressAndKeepsTheSelection() {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: NoOpener(),
            notifier: NoNotifier()
        )
        let data = app.viewModel("1001")
        let list = data.list(.popover)
        Self.kept += [app, data, list]
        let context = CardContext.of(list, avatars: AvatarStore(loader: NoImages()))
        let env = LineEnvironment(k: 1, now: 0, autoDismissDays: 3, context: context)

        let band = HeadingLineView(frame: NSRect(x: 0, y: 0, width: 460, height: 31))
        let group = DismissedGroup(repository: "example-org/api", detail: "2 PRs", cards: [])
        band.configure(HeadingLine(group, first: false), env: env, state: ItemState())
        guard case .label(let key) = band.kind else { return XCTFail("a band is a label, not a heading that folds") }
        XCTAssertEqual(key, "dismissed|example-org/api")
        XCTAssertNil(band.zone(at: NSPoint(x: 40, y: 10)), "nothing drops on it")
        XCTAssertNil(band.rect(of: .section(key)), "not an item of the selection")

        list.select(.header(card: "c1"))
        let selected = list.selection
        let cards = list.selectedCards
        band.mouseDown(with: event(.leftMouseDown))
        band.mouseUp(with: event(.leftMouseUp))
        band.mouseDown(with: event(.leftMouseDown, flags: .control))
        band.rightMouseDown(with: event(.rightMouseDown))
        XCTAssertEqual(list.selection, selected, "the selection stays")
        XCTAssertEqual(list.selectedCards, cards)
        XCTAssertTrue(list.data.collapsed.isEmpty, "nothing folds")

        // A section heading, by contrast, folds (the selection it takes
        // goes again here: this list has no section to keep it on).
        let heading = HeadingLineView(frame: NSRect(x: 0, y: 0, width: 460, height: 31))
        let section = SectionLayout(
            key: "review|inbox", title: "Inbox", level: 1, isLeaf: true, detail: "0 PRs", collapsed: false, cards: [], more: 0,
            showLess: false, moreMark: .none, matching: [], accepts: true, isDone: false
        )
        heading.configure(HeadingLine(section), env: env, state: ItemState())
        heading.mouseDown(with: event(.leftMouseDown))
        XCTAssertEqual(list.data.collapsed, ["review|inbox"])
    }
}

/// The section headings (DESIGN.md, "Constants"; Main.html `.band`,
/// `.grp2`): a band across the whole list, 28 points high at text size 12,
/// a line on its top and bottom edges, 8 points above and below it, the
/// first one right at the list's top; its parts where they were in a band
/// inset by the cards' margin. A second-level heading has no indentation:
/// its name where the band's name is, a thin line, the count and the
/// chevron at the right end.
@MainActor
final class HeadingBandTests: XCTestCase {
    static var kept: [AnyObject] = []

    func env(k: CGFloat) -> LineEnvironment {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()),
            opener: DismissedBandPressTests.NoOpener(), notifier: DismissedBandPressTests.NoNotifier()
        )
        let list = app.viewModel("1001").list(.popover)
        Self.kept += [app, list]
        return LineEnvironment(k: k, now: 0, autoDismissDays: 3, context: CardContext.of(list, avatars: AvatarStore(loader: DismissedBandPressTests.NoImages())))
    }

    func section(level: Int, collapsed: Bool = false) -> SectionLayout {
        SectionLayout(
            key: level == 1 ? "all|repo" : "all|repo|merged", title: level == 1 ? "example-org/api" : "Merged", level: level, isLeaf: level == 2,
            detail: "6 PRs", collapsed: collapsed, cards: [], more: 0, showLess: false, moreMark: .none, matching: [], accepts: false,
            isDone: false
        )
    }

    func testTheBandSpansTheListAt28Points() {
        let want: [Int: CGFloat] = [9: 21, 12: 28, 18: 42]
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let heading = HeadingLine(section(level: 1))
            let (frame, height) = LineLayout.heading(heading, width: 460 * k, k: k)
            XCTAssertEqual(frame.minX, 0, "\(size): from the list's left edge")
            XCTAssertEqual(frame.width, 460 * k, "\(size): to its right edge")
            XCTAssertEqual(frame.minY, 8, "\(size): 8 above")
            XCTAssertEqual(height - frame.maxY, 8, "\(size): 8 below")
            XCTAssertEqual(frame.height, want[size], "\(size): 28 points times the text scale")
            // The text line centered in the band.
            let view = HeadingLineView(frame: NSRect(origin: .zero, size: frame.size))
            view.configure(heading, env: env(k: k), state: ItemState())
            let parts = try! XCTUnwrap(view.parts())
            XCTAssertEqual(parts.title.midY, frame.height / 2, accuracy: 0.001, "\(size)")
            XCTAssertEqual(parts.detail.midY, frame.height / 2, accuracy: 0.001, "\(size)")
        }
        // The list's first heading sits at its top.
        var first = HeadingLine(section(level: 1))
        first.gap = 0
        XCTAssertEqual(LineLayout.heading(first, width: 460, k: 1).frame.minY, 0)
    }

    /// The band's parts keep their places relative to the cards (12 points
    /// in): the name 10 points into that, the chevron 8 points from its
    /// right end.
    func testTheBandsPartsKeepTheirPlaces() {
        for k: CGFloat in [1, 1.5] {
            let width = 460 * k
            let (frame, _) = LineLayout.heading(HeadingLine(section(level: 1)), width: width, k: k)
            let view = HeadingLineView(frame: NSRect(origin: .zero, size: frame.size))
            view.configure(HeadingLine(section(level: 1)), env: env(k: k), state: ItemState())
            let parts = try! XCTUnwrap(view.parts())
            XCTAssertEqual(parts.title.minX, 12 + 10, "k \(k)")
            XCTAssertEqual(try! XCTUnwrap(parts.chevron).maxX, width - 12 - 8, accuracy: 0.01, "k \(k)")
        }
    }

    /// Drawn: the band's ground to both edges, square corners, a separator
    /// line on the top and the bottom rows, in light and dark; selected,
    /// the selection fills the whole band.
    func testTheBandAsDrawn() throws {
        for dark in [false, true] {
            let (frame, _) = LineLayout.heading(HeadingLine(section(level: 1)), width: 460, k: 1)
            let view = HeadingLineView(frame: NSRect(origin: .zero, size: frame.size))
            view.configure(HeadingLine(section(level: 1)), env: env(k: 1), state: ItemState())
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let image = try XCTUnwrap(view.renderImage())
            let scale = CGFloat(image.width) / frame.width
            let middle = pixel(image, x: 2, y: frame.height / 2, scale: scale)
            XCTAssertGreaterThan(middle[3], 0, "dark \(dark): the ground at the left edge")
            XCTAssertEqual(pixel(image, x: frame.width - 1, y: frame.height / 2, scale: scale), middle, "dark \(dark): to the right edge")
            let top = pixel(image, x: 0, y: 0, scale: scale)
            let bottom = pixel(image, x: frame.width - 1, y: frame.height - 0.5, scale: scale)
            XCTAssertGreaterThan(top[3], middle[3], "dark \(dark): a line at the top, in the very corner (square)")
            XCTAssertEqual(top, bottom, "dark \(dark): the same line at the bottom")
            XCTAssertEqual(pixel(image, x: 2, y: 1.5, scale: scale), middle, "dark \(dark): 1 point thick")

            let state = ItemState()
            state.selected = .section(HeadingLine(section(level: 1)).key)
            view.configure(HeadingLine(section(level: 1)), env: env(k: 1), state: state)
            let selected = try XCTUnwrap(view.renderImage())
            let left = pixel(selected, x: 2, y: frame.height / 2, scale: scale)
            XCTAssertNotEqual(left, middle, "dark \(dark): the selection at the left end")
            XCTAssertEqual(pixel(selected, x: frame.width - 2, y: frame.height / 2, scale: scale), left, "and at the right end")

            // A drop target: the accent tint over the whole band, an accent
            // frame along its edges, square.
            let over = ItemState()
            over.over = true
            view.configure(HeadingLine(section(level: 1)), env: env(k: 1), state: over)
            let target = try XCTUnwrap(view.renderImage())
            let inside = pixel(target, x: 40, y: frame.height / 2 - 6, scale: scale)
            XCTAssertNotEqual(inside, middle, "dark \(dark): the drop target's tint")
            XCTAssertEqual(pixel(target, x: frame.width / 2 + 60, y: frame.height / 2 - 6, scale: scale), inside, "dark \(dark): across the band")
            let edge = pixel(target, x: 1.5, y: frame.height / 2, scale: scale)
            XCTAssertNotEqual(edge, inside, "dark \(dark): the frame at the left edge")
            XCTAssertEqual(pixel(target, x: frame.width - 1.5, y: frame.height / 2, scale: scale), edge, "dark \(dark): and at the right edge")
            XCTAssertEqual(pixel(target, x: 1.5, y: 1.5, scale: scale), edge, "dark \(dark): square corner")
        }
    }

    /// A second-level heading: 4 points above it and 5 under it at every
    /// text size, its text line in between.
    func testTheRoomAroundASecondLevelHeading() {
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let (frame, height) = LineLayout.heading(HeadingLine(section(level: 2)), width: 460 * k, k: k)
            XCTAssertEqual(frame.minY, 4, "\(size)")
            XCTAssertEqual(height - frame.maxY, 5, "\(size)")
            let line = max(Ink.lineHeight(Ink.font(11 * k, .semibold)), Ink.lineHeight(Ink.font(11 * k)), 14 * k)
            XCTAssertEqual(frame.height, line, "\(size): the text line")
        }
    }

    /// The Dismissed list's first band keeps 2 points under the note;
    /// the others 8.
    func testTheDismissedListsFirstBand() {
        let group = DismissedGroup(repository: "example-org/api", detail: "3 PRs", cards: [])
        XCTAssertEqual(LineLayout.heading(HeadingLine(group, first: true), width: 460, k: 1).frame.minY, 2)
        XCTAssertEqual(LineLayout.heading(HeadingLine(group, first: false), width: 460, k: 1).frame.minY, 8)
        XCTAssertEqual(LineLayout.heading(HeadingLine(group, first: true), width: 460, k: 1.5).frame.minY, 2, "at every text size")
    }

    /// A second-level heading: no indentation, the name where the band's
    /// name is, a thin line from the name to the count, the chevron at the
    /// right end where the band's chevron is.
    func testASecondLevelHeadingIsNotIndented() {
        for k: CGFloat in [1, 1.5] {
            let width = 460 * k
            let (band, _) = LineLayout.heading(HeadingLine(section(level: 1)), width: width, k: k)
            let (frame, _) = LineLayout.heading(HeadingLine(section(level: 2)), width: width, k: k)
            XCTAssertEqual(frame.minX, 12, "k \(k): the cards' left edge")
            XCTAssertEqual(frame.maxX, width - 12, "k \(k): the cards' right edge")
            let bandView = HeadingLineView(frame: NSRect(origin: .zero, size: band.size))
            bandView.configure(HeadingLine(section(level: 1)), env: env(k: k), state: ItemState())
            let view = HeadingLineView(frame: NSRect(origin: .zero, size: frame.size))
            view.configure(HeadingLine(section(level: 2)), env: env(k: k), state: ItemState())
            let bandParts = try! XCTUnwrap(bandView.parts())
            let parts = try! XCTUnwrap(view.parts())
            XCTAssertEqual(parts.title.minX + frame.minX, bandParts.title.minX + band.minX, "k \(k): the names line up")
            XCTAssertEqual(try! XCTUnwrap(parts.chevron).maxX + frame.minX, try! XCTUnwrap(bandParts.chevron).maxX + band.minX, accuracy: 0.01,
                           "k \(k): the chevrons line up")
            XCTAssertLessThan(parts.detail.maxX, try! XCTUnwrap(parts.chevron).minX, "the count before the chevron")
            let rule = try! XCTUnwrap(parts.rule, "k \(k)")
            XCTAssertEqual(rule.height, 1)
            XCTAssertGreaterThan(rule.minX, parts.title.maxX)
            XCTAssertLessThan(rule.maxX, parts.detail.minX)
            XCTAssertEqual(parts.title.width, Ink.width("Merged", Ink.font(11 * k, .semibold)) + 1, accuracy: 0.01, "the name's own width")
        }
        // A long name is cut; the line keeps at least 8 points.
        var long = section(level: 2)
        long.title = String(repeating: "very-long-group-name-", count: 10)
        let (frame, _) = LineLayout.heading(HeadingLine(long), width: 460, k: 1)
        let view = HeadingLineView(frame: NSRect(origin: .zero, size: frame.size))
        view.configure(HeadingLine(long), env: env(k: 1), state: ItemState())
        let parts = try! XCTUnwrap(view.parts())
        let rule = try! XCTUnwrap(parts.rule)
        XCTAssertEqual(rule.width, 8, accuracy: 0.5)
        XCTAssertGreaterThan(rule.minX, parts.title.maxX)
        XCTAssertLessThan(rule.maxX, parts.detail.minX)
        XCTAssertLessThan(parts.title.width, Ink.width(long.title, Ink.font(11, .semibold)), "the name is cut")
    }

    /// DESIGN.md, "Section size", "Constants": a band's parts from the
    /// left are the name, `Show less`, `Dismiss all`, the count and the
    /// chevron; the count sits left of the chevron in every heading; 8
    /// points between the parts, 16 between `Show less` and `Dismiss
    /// all`'s room (its 2 points either side not counted).
    func testDismissAllSitsLeftOfTheCount() {
        func done(less: Bool, dismissAll: Bool) -> SectionLayout {
            let cards = dismissAll ? [Card(id: "a"), Card(id: "b")] : []
            return SectionLayout(
                key: SectionKey.placed(.review, .done), title: "Done", level: 1, isLeaf: true, detail: "12 PRs", collapsed: false,
                cards: cards, more: 0, showLess: less, moreMark: .none, matching: cards, accepts: true, isDone: dismissAll
            )
        }
        for k: CGFloat in [0.75, 1, 1.5] {
            let width = 460 * k
            func parts(_ section: SectionLayout) -> HeadingLineView.Parts {
                let line = HeadingLine(section)
                let (frame, _) = LineLayout.heading(line, width: width, k: k)
                let view = HeadingLineView(frame: NSRect(origin: .zero, size: frame.size))
                view.configure(line, env: env(k: k), state: ItemState())
                return try! XCTUnwrap(view.parts())
            }
            let plain = parts(done(less: false, dismissAll: false))
            let both = parts(done(less: true, dismissAll: true))
            let dismissOnly = parts(done(less: false, dismissAll: true))
            let lessOnly = parts(done(less: true, dismissAll: false))
            for p in [both, dismissOnly, lessOnly] {
                XCTAssertEqual(p.detail, plain.detail, "k \(k): the count at the same place")
                XCTAssertEqual(try! XCTUnwrap(p.chevron).minX - p.detail.maxX, 8, accuracy: 0.01, "k \(k): 8 before the chevron")
            }
            let all = try! XCTUnwrap(both.dismissAll)
            let less = try! XCTUnwrap(both.showLess)
            XCTAssertEqual(both.detail.minX - (all.maxX + 2), 8, accuracy: 0.01, "k \(k): Dismiss all's room, then 8, then the count")
            XCTAssertEqual((all.minX - 2) - less.maxX, 16, accuracy: 0.01, "k \(k): 16 between Show less and Dismiss all")
            XCTAssertEqual(less.minX - both.title.maxX, 8, accuracy: 0.01, "k \(k): 8 after the name")
            XCTAssertEqual(try! XCTUnwrap(dismissOnly.dismissAll), all, "k \(k)")
            XCTAssertEqual(try! XCTUnwrap(lessOnly.showLess).maxX, lessOnly.detail.minX - 8, accuracy: 0.01, "k \(k): without Dismiss all, 8")
            XCTAssertNil(plain.dismissAll)
            XCTAssertLessThan(both.title.maxX, plain.title.maxX, "the name has less room")
        }
    }

    func pixel(_ image: CGImage, x: CGFloat, y: CGFloat, scale: CGFloat) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let px = (x * scale).rounded(.down)
        let py = CGFloat(image.height) - (y * scale).rounded(.down) - 1
        context.draw(image, in: CGRect(x: -px, y: -py, width: CGFloat(image.width), height: CGFloat(image.height)))
        return bytes
    }
}
