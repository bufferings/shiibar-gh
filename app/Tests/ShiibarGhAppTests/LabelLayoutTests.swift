// The label line of a card and line 3 of a Dismissed card as the AppKit
// lines lay them out (DESIGN.md, "Card", "GitHub labels", "Compact",
// "Dismissed list", "Constants"). Geometry only: no window, no daemon.

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import XCTest

@MainActor
final class LabelLayoutTests: XCTestCase {
    let now: Int64 = 1_000_000

    func labels(_ names: [String]) -> [PRLabel] {
        names.map { PRLabel(name: $0, color: "0075ca") }
    }

    func line(_ card: Card, shows: Bool = true, compact: Bool = false) -> CardLine {
        CardLine(
            card: card, section: "s", showsTag: false, indented: false, expanded: false, canDrag: true, compact: compact,
            showsLabels: shows
        )
    }

    func geometry(_ line: CardLine, width: CGFloat = 460, k: CGFloat = 1) -> CardGeometry {
        LineLayout.card(line, width: width, k: k, now: now)
    }

    func testTheLabelLineEndsTheHeading() {
        let plain = Card(id: "c")
        let labelled = Card(id: "c", labels: labels(["bug", "good first issue"]))
        let without = geometry(line(plain))
        let with = geometry(line(labelled))
        XCTAssertEqual(with.labels.map(\.index), [0, 1])
        let first = with.labels[0].frame
        XCTAssertEqual(first.height, 16, "16 points at text size 12")
        XCTAssertEqual(first.minX, 12, "from the left of line 3")
        XCTAssertEqual(first.minY, without.header.maxY - 6 + 5, accuracy: 0.001, "5 points under line 3")
        XCTAssertEqual(with.header.maxY, first.maxY + 6, accuracy: 0.001, "the heading ends 6 points under the label line")
        XCTAssertEqual(with.labels[1].frame.minX, first.maxX + 4, accuracy: 0.001, "4 points between labels")
        XCTAssertEqual(with.labels[0].text.minX - first.minX, 7, accuracy: 0.001, "7 points each side")
        XCTAssertEqual(first.width, (Ink.width("bug", LineLayout.labelFont(k: 1)) + 14).rounded(.up))
        XCTAssertNil(with.labelsMore)
    }

    func testACardWithoutLabelsKeepsNoRoom() {
        let plain = geometry(line(Card(id: "c")))
        XCTAssertTrue(plain.labels.isEmpty)
        let off = geometry(line(Card(id: "c", labels: labels(["bug"])), shows: false))
        XCTAssertTrue(off.labels.isEmpty, "Show labels off: no label line")
        XCTAssertEqual(off.header, plain.header)
        XCTAssertEqual(off.size, plain.size)
    }

    func testLabelsWrapAndEveryLabelShows() {
        let names = (0..<12).map { "area/component-\($0)" }
        let g = geometry(line(Card(id: "c", labels: labels(names))), width: 360)
        XCTAssertEqual(g.labels.count, 12, "every label shows")
        let tops = Set(g.labels.map(\.frame.minY))
        XCTAssertGreaterThan(tops.count, 1, "wrapped to more lines")
        let sortedTops = tops.sorted()
        XCTAssertEqual(sortedTops[1] - sortedTops[0], 16 + 4, accuracy: 0.001, "4 points between wrapped lines")
        let right = g.header.width - 10
        for label in g.labels {
            XCTAssertLessThanOrEqual(label.frame.maxX, right + 0.001, "inside the line")
        }
        // The order: left to right, line by line.
        let order = g.labels.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }.map(\.index)
        XCTAssertEqual(order, Array(0..<12))
        XCTAssertEqual(g.header.maxY, g.labels.map(\.frame.maxY).max()! + 6, accuracy: 0.001)
    }

    func testASingleLabelWiderThanTheLineIsCut() {
        let long = String(repeating: "very long label name ", count: 10)
        let g = geometry(line(Card(id: "c", labels: labels(["bug", long, "ok"]))), width: 300)
        let room = g.header.width - 10 - 12
        XCTAssertEqual(g.labels[1].frame.width, room, accuracy: 0.001, "takes the whole line")
        XCTAssertEqual(g.labels[1].frame.minX, 12)
        XCTAssertNotNil(Ink.shownEnd(long, LineLayout.labelFont(k: 1), width: g.labels[1].text.width), "its name is cut with …")
        XCTAssertGreaterThan(g.labels[2].frame.minY, g.labels[1].frame.minY, "the next label goes to the next line")
    }

    func testPlusNFollowsTheLastLabel() {
        let names = (0..<20).map { String(format: "l%02d", $0) }
        let card = Card(id: "c", labels: labels(names), labelsMore: 3)
        let g = geometry(line(card))
        let more = try! XCTUnwrap(g.labelsMore)
        let last = g.labels.last!.frame
        if more.minY == last.minY {
            XCTAssertEqual(more.minX, last.maxX + 4, accuracy: 0.001)
        } else {
            XCTAssertEqual(more.minX, 12, "wrapped like a label")
        }
        XCTAssertEqual(LineLayout.labelsMoreText(3), "+3")
        XCTAssertTrue(CardLineView.accessibilityParts(line(card), g, now: now).first!.1.hasSuffix("l19, +3"))
        XCTAssertNil(geometry(line(Card(id: "c", labels: labels(names)))).labelsMore, "only past 20")
    }

    func testCompactKeepsTheLabelLine() {
        let card = Card(id: "c", rows: [Row(id: "r", kind: .merged, actor: "al")], labels: labels(["bug", "size/M"]))
        var compact = line(card, compact: true)
        compact.unread = .none
        let small = geometry(compact)
        let full = geometry(line(card))
        XCTAssertEqual(small.labels, full.labels)
        XCTAssertEqual(small.header, full.header)
        XCTAssertEqual(small.size.height, small.header.height)
    }

    func testTheLabelLineScalesWithTheTextSize() {
        let card = Card(id: "c", labels: labels(["bug", "good first issue", "documentation"]))
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let g = geometry(line(card), width: CGFloat(TextSize.width(size)), k: k)
            XCTAssertEqual(g.labels[0].frame.height, 16 * k, accuracy: 0.001, "text size \(size)")
            XCTAssertEqual(g.labels[0].text.minX - g.labels[0].frame.minX, 7 * k, accuracy: 0.001)
            XCTAssertEqual(g.header.maxY, g.labels.map(\.frame.maxY).max()! + 6 * k, accuracy: 0.001)
        }
    }

    /// The colors drawn: light uses the label color as the ground; dark
    /// works out the ground over the card's real ground. Selected or not,
    /// the label colors are the same (the look depends on the label and
    /// the appearance only).
    func testTheLookFollowsTheAppearanceDrawnIn() {
        var light: LabelLook?
        var dark: LabelLook?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = LabelInk.look("D73A4A") }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = LabelInk.look("d73a4a") }
        XCTAssertEqual(light, LabelColors.light("d73a4a"))
        var ground = LabelRGB.white
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { ground = LabelInk.cardGround() }
        XCTAssertEqual(dark, LabelColors.dark("d73a4a", card: ground))
        XCTAssertGreaterThanOrEqual(dark!.text.contrast(dark!.ground), 4.5)
    }

    func testAMutedCardDrawsItsLabelsFaint() {
        XCTAssertEqual(LabelColors.mutedOpacity, 0.6, "as the avatars of gray rows")
        XCTAssertEqual(CardLineView.avatarOpacity(RowPresentation(Row(id: "r", kind: .comment, muted: true), now: 0)), 0.6)
    }

    // MARK: Dismissed list, line 3

    func dismissed(_ card: Card, width: CGFloat = 460, k: CGFloat = 1) -> DismissedGeometry {
        LineLayout.dismissed(card, width: width, k: k, now: now)
    }

    func testDismissedLineThreeShowsTheBranchesAndTheAuthor() {
        let card = Card(id: "d", author: "alice", base: "main", head: "fix/limit-comments", dismissExpiresAt: now + 86_400)
        let g = dismissed(card)
        let f11 = Ink.font(11)
        XCTAssertEqual(g.branches.minX, 12)
        XCTAssertEqual(g.branches.width, Ink.width("main \u{2190} fix/limit-comments", f11), accuracy: 0.001, "not cut")
        let by = try! XCTUnwrap(g.by)
        XCTAssertEqual(by.minX, g.branches.maxX + 4, accuracy: 0.001)
        XCTAssertEqual(by.width, Ink.width("by alice", f11), accuracy: 0.001)
        XCTAssertLessThanOrEqual(by.maxX, g.daysLeft.minX - 8 + 0.001)
        XCTAssertEqual(g.branches.midY, g.restore.midY, accuracy: 0.5, "on line 3 with Restore")
    }

    func testDismissedBranchesAreCutFirstThenTheLogin() {
        let head = "feature/" + String(repeating: "a-very-long-branch-name-", count: 6)
        let card = Card(id: "d", author: "a-rather-long-login-name-of-someone", base: "main", head: head, dismissExpiresAt: now + 86_400)
        let wide = dismissed(card, width: 460)
        let f11 = Ink.font(11)
        let byWidth = Ink.width("by a-rather-long-login-name-of-someone", f11)
        XCTAssertEqual(wide.by?.width ?? 0, byWidth, accuracy: 0.001, "the login is whole while the branches can shrink")
        XCTAssertLessThan(wide.branches.width, Ink.width("main \u{2190} " + head, f11), "the branches are cut")
        // Narrow: the branches are down to "…", the login is cut.
        let narrow = dismissed(card, width: 300)
        XCTAssertEqual(narrow.branches.width, Ink.width("\u{2026}", f11).rounded(.up), accuracy: 0.001)
        XCTAssertLessThan(narrow.by!.width, byWidth)
        XCTAssertEqual(narrow.by!.maxX, narrow.daysLeft.minX - 8, accuracy: 0.001)
        // The days left and Restore are never cut.
        XCTAssertEqual(narrow.daysLeft.width, Ink.width(DismissedText.daysLeft(card.dismissExpiresAt, now: now), f11), accuracy: 0.001)
        XCTAssertEqual(narrow.restore.size, ListButton.restoreSize(k: 1))
    }

    func testDismissedCardWithoutAnAuthorHasNoBy() {
        let card = Card(id: "d", author: "", base: "main", head: "topic", dismissExpiresAt: now + 86_400)
        let g = dismissed(card)
        XCTAssertNil(g.by)
        XCTAssertEqual(g.branches.width, Ink.width("main \u{2190} topic", Ink.font(11)), accuracy: 0.001)
    }

    /// The height is that of 0.7: line 3 is as high as Restore, whatever it
    /// shows; labels never show here.
    func testDismissedHeightDoesNotChange() {
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let a = dismissed(Card(id: "d", author: "", head: "t"), k: k)
            let b = dismissed(Card(id: "d", author: "someone", head: String(repeating: "x", count: 200), labels: labels(["bug"])), k: k)
            XCTAssertEqual(a.size.height, b.size.height, "text size \(size)")
            let lh12 = Ink.lineHeight(Ink.font(12 * k))
            let line1 = max(Ink.lineHeight(Ink.font(11 * k)), 18 * k)
            let expected = 6 * k + line1 + 3 * k + max(16 * k, lh12) + 5 * k
                + max(Ink.lineHeight(Ink.font(11 * k)), ListButton.restoreSize(k: k).height) + 6 * k
            XCTAssertEqual(a.size.height, expected, accuracy: 0.001)
        }
    }

    /// Very narrow at every text size: once the branches are a lone "…",
    /// neither it nor the login reaches the days left or Restore.
    func testDismissedLineThreeNeverOverlapsTheDaysLeft() {
        let card = Card(
            id: "d", author: "a-rather-long-login-name-of-someone", base: "release/2027-spring",
            head: "someone/rework-the-retry-path", dismissExpiresAt: now + 6 * 86_400
        )
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            for width in stride(from: CGFloat(120), through: 420, by: 20) {
                let g = dismissed(card, width: width, k: k)
                let limit = g.daysLeft.minX - 8 + 0.001
                // Narrower than the days left and Restore themselves: no
                // room for line 3's left part at all.
                guard limit >= 12 else { continue }
                XCTAssertGreaterThanOrEqual(g.branches.width, 0)
                XCTAssertLessThanOrEqual(g.branches.maxX, limit, "size \(size) width \(width)")
                let by = try! XCTUnwrap(g.by)
                XCTAssertGreaterThanOrEqual(by.width, 0)
                XCTAssertLessThanOrEqual(by.maxX, limit, "size \(size) width \(width)")
                XCTAssertLessThanOrEqual(by.minX, limit)
                XCTAssertLessThanOrEqual(g.daysLeft.maxX, g.restore.minX, "the days left whole before Restore")
            }
        }
    }
}
