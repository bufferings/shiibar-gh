// GitHub labels on the cards (DESIGN.md, "Card", "GitHub labels",
// "Constants", "What the filters mean", "Showing what matched"), the
// `show_labels` setting, the Dismissed list's line 3 and the searching
// sections of Review and Mine.

import Foundation
@testable import ShiibarGhCore
import XCTest

final class LabelColorsTests: XCTestCase {
    /// A dark card ground for the dark formulas: the label colors are
    /// worked out over the real ground of the appearance, so the tests fix
    /// one.
    let ground = LabelRGB(52, 52, 54)

    func hex(_ value: UInt32) -> LabelRGB { LabelRGB(hex: value) }

    func testRelativeLuminanceAndContrastAreWCAG2s() {
        XCTAssertEqual(LabelRGB.white.luminance, 1, accuracy: 1e-12)
        XCTAssertEqual(LabelRGB.black.luminance, 0, accuracy: 1e-12)
        XCTAssertEqual(LabelRGB.white.contrast(.black), 21, accuracy: 1e-9)
        XCTAssertEqual(hex(0xD73A4A).luminance, 0.1797, accuracy: 1e-4)
        XCTAssertEqual(LabelRGB.white.contrast(hex(0xD73A4A)), 4.572, accuracy: 1e-3)
        XCTAssertEqual(hex(0xD73A4A).contrast(.white), LabelRGB.white.contrast(hex(0xD73A4A)), "the order does not matter")
    }

    func testLightTextIsWhiteUnlessWhiteMissesTheContrast() {
        // White reaches 4.5 on these grounds.
        for color in ["d73a4a", "0075ca", "7057ff", "000000", "1d2733", "b60205", "0e8a16"] {
            let look = LabelColors.light(color)
            XCTAssertEqual(look.text, .white, color)
            XCTAssertEqual(look.ground, LabelColors.parse(color), "the ground is the label color: \(color)")
            XCTAssertGreaterThanOrEqual(look.text.contrast(look.ground), 4.5, color)
        }
        // Light labels read in black, which reaches 4.6 or more there.
        for color in ["fbca04", "ededed", "a2eeef", "d876e3", "ffffff"] {
            let look = LabelColors.light(color)
            XCTAssertEqual(look.text, .black, color)
            XCTAssertGreaterThanOrEqual(look.text.contrast(look.ground), 4.6, color)
        }
    }

    func testLightOutlineOnlyAboveY06() {
        for color in ["fbca04", "ededed", "a2eeef", "ffffff"] {
            let look = LabelColors.light(color)
            XCTAssertEqual(look.outline, .black, color)
            XCTAssertEqual(look.outlineAlpha, 0.15, color)
        }
        // D876E3 reads in black but is darker than Y 0.6: no outline.
        for color in ["d876e3", "d73a4a", "000000", "6e7781"] {
            XCTAssertNil(LabelColors.light(color).outline, color)
        }
    }

    func testDarkGroundOutlineAndTheLeastWhite() {
        let bug = LabelColors.dark("d73a4a", card: ground)
        XCTAssertEqual(bug.ground.r, 52 * 0.82 + 215 * 0.18, accuracy: 1e-9, "the label color at 0.18 over the card")
        XCTAssertEqual(bug.ground.g, 52 * 0.82 + 58 * 0.18, accuracy: 1e-9)
        XCTAssertEqual(bug.ground.b, 54 * 0.82 + 74 * 0.18, accuracy: 1e-9)
        XCTAssertEqual(bug.outline, hex(0xD73A4A))
        XCTAssertEqual(bug.outlineAlpha, 0.4)
        let t = LabelColors.darkWhite(hex(0xD73A4A), ground: bug.ground)
        XCTAssertEqual(t, 0.45, accuracy: 1e-12)
        XCTAssertEqual(bug.text, hex(0xD73A4A).mixedWithWhite(0.45))
        XCTAssertGreaterThanOrEqual(bug.text.contrast(bug.ground), 4.5)
        XCTAssertLessThan(hex(0xD73A4A).mixedWithWhite(0.4).contrast(bug.ground), 4.5, "0.45 is the least step")
        // A near-black label reads gray: black takes t = 0.6, #999999.
        let black = LabelColors.dark("000000", card: ground)
        XCTAssertEqual(black.text, LabelRGB(153, 153, 153))
        // A bright label needs no white.
        XCTAssertEqual(LabelColors.dark("fbca04", card: ground).text, hex(0xFBCA04))
        XCTAssertEqual(LabelColors.dark("ffffff", card: ground).text, .white)
    }

    /// Every label color reaches 4.5 in both appearances, on light and dark
    /// card grounds alike.
    func testEveryColorReachesTheContrast() {
        let grounds = [LabelRGB(30, 30, 30), LabelRGB(46, 46, 48), ground, LabelRGB(70, 70, 72)]
        var value: UInt32 = 0
        while value <= 0xFFFFFF {
            let color = String(format: "%06x", value)
            let light = LabelColors.light(color)
            XCTAssertGreaterThanOrEqual(light.text.contrast(light.ground), 4.5, color)
            for card in grounds {
                let dark = LabelColors.dark(color, card: card)
                XCTAssertGreaterThanOrEqual(dark.text.contrast(dark.ground), 4.5, color)
            }
            value += 0x0F0D0B
        }
    }

    func testUpperAndLowerCaseAreTheSameColor() {
        XCTAssertEqual(LabelColors.parse("D73A4A"), LabelColors.parse("d73a4a"))
        XCTAssertEqual(LabelColors.light("A2EEEF"), LabelColors.light("a2eeef"))
        XCTAssertEqual(LabelColors.dark("FbCa04", card: ground), LabelColors.dark("fbca04", card: ground))
    }

    func testAColorThatIsNotSixHexDigitsIsGray() {
        let gray = LabelRGB(hex: 0x6E7781)
        for color in ["", "zzzzzz", "#d73a4a", "d73a4", "d73a4a0", " d73a4a", "12345g", "+12345", "ｄ73a4a"] {
            XCTAssertEqual(LabelColors.parse(color), gray, color)
            XCTAssertEqual(LabelColors.light(color), LabelColors.light("6e7781"), color)
            XCTAssertEqual(LabelColors.dark(color, card: ground), LabelColors.dark("6E7781", card: ground), color)
        }
    }

    /// The selection does not change a label's colors: they are worked
    /// out from the label color and, in dark, the ground of a card that is
    /// not selected only.
    func testTheColorsDependOnTheLabelAndTheCardGroundOnly() {
        XCTAssertEqual(LabelColors.dark("0e8a16", card: ground), LabelColors.dark("0e8a16", card: ground))
        XCTAssertNotEqual(LabelColors.dark("0e8a16", card: ground).ground, LabelColors.dark("0e8a16", card: LabelRGB(30, 30, 30)).ground)
    }
}

final class LabelSearchTests: XCTestCase {
    let labelled = Card(
        id: "L", pr: "example-org/api#440", title: "Retry the status fetch", author: "sam",
        labels: [PRLabel(name: "area: fetch", color: "0075ca"), PRLabel(name: "good first issue", color: "7057ff")],
        labelsMore: 3
    )

    func testWireLabelsDecodeAndDefaultToNone() throws {
        let base = #"{"id":"L","pr":"o/r#1","account":"1","owner":"o1","title":"T","url":"u","author":"a","authored_by_me":false,"#
            + #""state_label":"open","review":"none","checks":"none","base_status":"none","base":"main","head":"t","updated_at":0,"#
            + #""links":{"review":"r","checks":"c","base":"b"},"rows":[]"#
        let json = base + #","labels":[{"name":"bug","color":"d73a4a"},{"name":"size/M","color":"FBCA04"}],"labels_more":2}"#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        XCTAssertEqual(card.labels, [PRLabel(name: "bug", color: "d73a4a"), PRLabel(name: "size/M", color: "FBCA04")], "kept in the order sent")
        XCTAssertEqual(card.labelsMore, 2)
        let old = try JSONDecoder().decode(Card.self, from: Data((base + "}").utf8))
        XCTAssertEqual(old.labels, [], "no labels without the key")
        XCTAssertEqual(old.labelsMore, 0)
    }

    func testTheNewRowKindsDecode() throws {
        for (text, kind) in [("ready_for_review", RowKind.readyForReview), ("converted_to_draft", .convertedToDraft)] {
            let json = #"{"id":"r","pr":"o/r#1","pr_title":"T","account":"1","owner":"o1","kind":"\#(text)","text":null,"actor":null,"url":"https://github.com/o/r/pull/1#event-9","occurred_at":5,"unread":true}"#
            let row = try JSONDecoder().decode(Row.self, from: Data(json.utf8))
            XCTAssertEqual(row.kind, .known(kind))
            XCTAssertNil(row.actor)
            XCTAssertEqual(row.url, "https://github.com/o/r/pull/1#event-9", "a double-click opens the event")
            XCTAssertEqual(RowText.label(row.kind), kind == .readyForReview ? "Ready for review" : "Converted to draft")
        }
    }

    func testLabelNamesMatchOnlyWithShowLabels() {
        let words = Search.words("fetch first")
        XCTAssertTrue(Search.matches(labelled, words: Search.words("first"), labels: true))
        XCTAssertFalse(Search.matches(labelled, words: Search.words("first"), labels: false), "Show labels off: names are not searched")
        XCTAssertTrue(Search.matches(labelled, words: words, labels: true), "the title and a label")
        XCTAssertFalse(Search.matches(labelled, words: words, labels: false))
        XCTAssertEqual(Listing.search([labelled], "good", labels: true).map(\.id), ["L"])
        XCTAssertEqual(Listing.search([labelled], "good", labels: false).map(\.id), [])
    }

    func testTheDismissedListNeverSearchesLabelNames() {
        var dismissed = labelled
        dismissed.dismissedAt = 10
        dismissed.dismissExpiresAt = 1_000
        XCTAssertEqual(Listing.dismissedGroups([dismissed], search: "good").map(\.repository), [])
        XCTAssertEqual(Listing.dismissedEmptyText(loaded: true, cards: [dismissed], search: "good"), "Nothing matches")
        XCTAssertEqual(Listing.dismissedGroups([dismissed], search: "sam").map(\.repository), ["example-org/api"], "the author still matches")
    }

    func testTheTabsFollowShowLabels() {
        var card = labelled
        card.placement = Placement(tab: .review, section: .inbox)
        let on = layout(.review, cards: [card], search: "first", labels: true)
        XCTAssertEqual(on.map(\.matching.count), [0, 0, 0, 1])
        XCTAssertEqual(layout(.review, cards: [card], search: "first", labels: false), [], "no match: no section")
        let visibility = shows(mutedHidden)
        XCTAssertNil(Listing.emptyText(loaded: true, tab: .review, cards: [card], search: "first", visibility: visibility, labels: true))
        XCTAssertEqual(
            Listing.emptyText(loaded: true, tab: .review, cards: [card], search: "first", visibility: visibility, labels: false), "Nothing matches"
        )
    }

    func testMatchesInLabelsAndTheirCutPart() {
        func marks(_ text: String, labels: Bool = true, compact: Bool = false, cut: Int? = nil) -> Highlight.CardMarks {
            Highlight.card(
                labelled, words: Search.words(text), now: 0, expanded: false, expandedBodies: [], compact: compact, labels: labels
            ) { what, _ in
                if case .label(1) = what { return cut }
                return nil
            }
        }
        let first = marks("first")
        XCTAssertEqual(first.labels[1]?.found, [5..<10])
        XCTAssertNil(first.labels[0], "only labels with a match")
        XCTAssertTrue(first.anyYellow)
        XCTAssertTrue(marks("first", compact: true).anyYellow, "Compact shows the label line")
        XCTAssertTrue(marks("first", labels: false).labels.isEmpty, "no label line, no marks")
        // The name cut after "good f": the match is in the part cut off.
        let cut = marks("issue", cut: 6)
        XCTAssertEqual(cut.labels[1]?.ellipsis, true)
        XCTAssertEqual(cut.labels[1]?.shows, false)
    }
}

final class DismissedLineTests: XCTestCase {
    func testByLoginAndItsMatches() {
        XCTAssertEqual(Highlight.dismissedBy("alice"), "by alice")
        XCTAssertNil(Highlight.dismissedBy(""), "no `by …` without an author")
        XCTAssertEqual(Highlight.dismissedAuthor(Search.words("LIC"), author: "alice"), [4..<7], "the login only, after `by `")
        XCTAssertEqual(Highlight.dismissedAuthor(Search.words("by"), author: "alice"), [], "`by` itself is not the login")
        XCTAssertEqual(Highlight.dismissedAuthor(Search.words("x"), author: ""), [])
    }
}

final class SearchingSectionsTests: XCTestCase {
    /// Review while searching: the four headings stay selectable items
    /// (↑↓ goes through them as without search), the cards are only those
    /// matching, ⌘A selects those, and ⇧R reads the matching cards' rows.
    func testItemsSelectAllAndMarkAllWhileSearching() {
        let cards = sampleCards()
        let shown = view(.review, cards: cards, search: "example-bot")
        let items = PopoverLogic.items(shown)
        let headings = items.filter { if case .section = $0 { return true } else { return false } }
        XCTAssertEqual(headings.count, 4, "every heading, also of a section without a match")
        let cardItems = items.compactMap { item -> String? in if case .header(let id) = item { return id } else { return nil } }
        let matching = layout(.review, cards: cards, search: "example-bot").flatMap(\.matching).map(\.id)
        XCTAssertEqual(Set(cardItems), Set(matching), "only matching cards show")
        let read = Listing.rowsToRead(tab: .review, cards: cards, search: "example-bot", visibility: shows(mutedShown), labels: true)
        let matchingRows = cards.filter { matching.contains($0.id) }.flatMap(\.rows).filter(\.unread).map(\.id)
        XCTAssertEqual(read, matchingRows)
    }

    /// A drop on the frame of a section whose cards the search hides goes
    /// above them (`at: top`).
    func testADropOnTheFrameGoesAboveTheHiddenCards() {
        var cards = sampleCards()
        if let i = cards.firstIndex(where: { $0.id == "T1" }) { cards[i].placement = Placement(tab: .review, section: .waiting) }
        let sections = layout(.review, cards: cards, search: "example-bot")
        let waiting = sections.first { $0.key == "review|waiting" }!
        XCTAssertTrue(waiting.matching.isEmpty)
        XCTAssertEqual(waiting.detail, layout(.review, cards: cards).first { $0.key == "review|waiting" }?.detail, "the count ignores the search")
        XCTAssertEqual(CardDrop.target(.header("review|waiting"), sections: sections)?.position, .top)
    }
}
