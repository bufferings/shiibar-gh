// The list's lines (ListCells.swift): the 0.5 features as the AppKit cards
// lay them out (row bodies with `more` and `less`, `Show less` under the
// rows, muted cards, line 3 wrapping) and the texts they give assistive
// apps. Geometry only: no window, no daemon.

import AppKit
@testable import ShiibarGhApp
import ShiibarGhCore
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
        CardLine(card: card, section: "s", showsTag: tag, indented: false, expanded: expanded, canDrag: true, expandedBodies: bodies)
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
