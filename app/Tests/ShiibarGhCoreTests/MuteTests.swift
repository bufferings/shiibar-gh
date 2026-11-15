// 0.5's Mute in the app (DESIGN.md, "Mute", "Filter", "What a press
// does": "Hidden cards and places"), the menu bar icon with the window open,
// row bodies and the UI state 0.5 adds.

import Foundation
@testable import ShiibarGhCore
import XCTest

final class MutedFilterTests: XCTestCase {
    /// Muted Hide (the default): muted cards are not shown, not counted,
    /// not folded; groups and sections they alone filled are gone
    /// (DESIGN.md, "Mute", "Filter", "Section size").
    func testMutedCardsHideWithMutedHide() {
        let review = layout(.review, filter: mutedHidden)
        let todo = review[1]
        XCTAssertEqual(todo.matching.map(\.id), ["T1", "T2", "T3", "T4", "T5"])
        XCTAssertEqual(todo.detail, "5 PRs", "the muted cards are not counted")
        XCTAssertNil(todo.foldLine, "5 cards do not fold")
        let on = layout(.review, filter: mutedShown)[1]
        XCTAssertEqual(on.detail, "7 PRs")
        XCTAssertEqual(on.foldLine, "+ 2 more PRs")
        // A section whose cards are all muted is an empty section.
        let onlyMuted = sampleCards().filter { ["T6", "T7", "R1"].contains($0.id) }
        XCTAssertEqual(layout(.review, cards: onlyMuted, filter: mutedHidden).map(\.detail), ["1 PR", "0 PRs", "0 PRs", "0 PRs"])
        // A tab whose cards are all muted shows none, and its empty text.
        let mutedOnly = sampleCards().filter { ["T6", "T7"].contains($0.id) }
        XCTAssertEqual(layout(.review, cards: mutedOnly, filter: mutedHidden).map(\.key), [])
        XCTAssertEqual(
            Listing.emptyText(loaded: true, tab: .review, cards: mutedOnly, search: "", visibility: shows(mutedHidden)),
            "No pull requests to review"
        )
        XCTAssertNil(Listing.emptyText(loaded: true, tab: .review, cards: mutedOnly, search: "", visibility: shows(mutedShown)))
        // All: a group of muted cards only is not there.
        let all = layout(.all, cards: mutedOnly + [sampleCards()[1]], filter: mutedHidden)
        XCTAssertEqual(all.map(\.title), ["example-org/api"])
        XCTAssertEqual(all[0].cards.map(\.id), ["T1"])
        XCTAssertEqual(layout(.all, cards: mutedOnly, filter: mutedShown).map(\.title), ["example-org/api", "example-org/web"])
    }
}

final class HiddenPlaceTests: XCTestCase {
    /// Todo: T1, H (muted, hidden), T2, T3, K (hidden by the search).
    func todo() -> [Card] {
        [
            card("T1", placement: review(.todo, 0)),
            card("H", author: "renovate", placement: review(.todo, 1), muted: [.author]),
            card("T2", placement: review(.todo, 2)),
            card("T3", placement: review(.todo, 3)),
            card("K", pr: "other/k#1", placement: review(.todo, 4)),
            card("T4", placement: review(.todo, 5)),
        ]
    }

    func sections(search: String = "") -> [SectionLayout] {
        layout(.review, cards: todo(), search: search, filter: mutedHidden)
    }

    /// DESIGN.md, "Hidden cards and places": one rule for drops and ⌥↑↓
    /// among the reference cards V1, V2, …
    func testDropsLandAmongTheReferenceCards() {
        let s = sections(search: "example-org")
        XCTAssertEqual(s.map(\.key), ["review|todo"])
        XCTAssertEqual(s[0].matching.map(\.id), ["T1", "T2", "T3", "T4"])
        func at(_ id: String, lower: Bool) -> PlacePosition? {
            CardDrop.target(.card(id, lowerHalf: lower), sections: s)?.position
        }
        XCTAssertEqual(at("T1", lower: false), .top, "V1's upper half: above the hidden cards too")
        XCTAssertEqual(at("T2", lower: false), .before("T2"), "H stays above")
        XCTAssertEqual(at("T1", lower: true), .before("T2"))
        XCTAssertEqual(at("T3", lower: true), .before("T4"), "K stays above")
        XCTAssertEqual(at("T4", lower: true), .bottom)
        XCTAssertEqual(CardDrop.target(.header("review|todo"), sections: s)?.position, .top)
        // The places as the daemon will order them.
        let moved = LocalChange.place(PlaceMove(card: "T4", target: .review(.todo), position: .before("T2"), verb: .move)).apply(todo())
        XCTAssertEqual(Listing.ranked(moved.filter { $0.sectionKey == "review|todo" }).map(\.id), ["T1", "H", "T4", "T2", "T3", "K"])
    }

    func testOptionArrowsPassOneReferenceCard() {
        let refs = sections(search: "example-org")[0].matching
        func move(_ id: String, up: Bool) -> PlacePosition? {
            CardDrop.reorder(todo().first { $0.id == id }!, up: up, refs: refs)?.position
        }
        XCTAssertEqual(move("T2", up: true), .top, "past V1: the top")
        XCTAssertEqual(move("T3", up: true), .before("T2"))
        XCTAssertNil(move("T1", up: true))
        XCTAssertEqual(move("T1", up: false), .before("T3"), "past T2, before T3")
        XCTAssertEqual(move("T2", up: false), .before("T4"), "past T3; K stays above")
        XCTAssertEqual(move("T3", up: false), .bottom)
        XCTAssertNil(move("T4", up: false))
    }

    /// Folded and collapsed cards are reference cards, not hidden ones.
    func testFoldedCardsAreReferenceCards() {
        let cards = (0..<7).map { card("F\($0)", placement: review(.todo, $0)) }
        let s = layout(.review, cards: cards, filter: mutedHidden)
        XCTAssertEqual(s[1].cards.count, 5)
        XCTAssertEqual(CardDrop.target(.card("F4", lowerHalf: true), sections: s)?.position, .before("F5"),
                       "the last shown card's lower half: before the first folded one")
        XCTAssertEqual(CardDrop.target(.more("review|todo"), sections: s)?.position, .before("F5"),
                       "+ N more PRs: right after the last card shown")
        let collapsed = layout(.review, cards: cards, collapsed: ["review|todo"], filter: mutedHidden)
        XCTAssertEqual(CardDrop.target(.header("review|todo"), sections: collapsed)?.position, .top)
    }

    /// Several cards dropped on one of them: the nearest reference card
    /// that stays decides; nothing is sent when nothing changes.
    func testSeveralCardsDroppedOnOneOfThem() {
        let all = todo()
        let s = sections()
        let checked = { (ids: [String]) in all.filter { ids.contains($0.id) } }
        XCTAssertEqual(MultiRules.drop(checked(["T2", "T3"]), at: DropTarget(section: "review|todo", position: .before("T3")), sections: s, all: all), [])
        let top = MultiRules.drop(checked(["T1", "T2", "T4"]), at: DropTarget(section: "review|todo", position: .before("T2")), sections: s, all: all)
        XCTAssertEqual(top.map(\.position), [.top, .top, .top], "no reference card before it stays: the top")
        XCTAssertEqual(top.map(\.card), ["T4", "T2", "T1"])
        let next = MultiRules.drop(checked(["T2", "T4"]), at: DropTarget(section: "review|todo", position: .before("T2")), sections: s, all: all)
        XCTAssertEqual(next.map(\.position), [.before("T3"), .before("T3")])
    }
}

final class MuteRuleTests: XCTestCase {
    func base(own: Bool = false, prMute: PrMute = .none) -> Card {
        card(
            "P", pr: "example-org/api#9", author: own ? "me" : "renovate", authored: own, prMute: prMute,
            rows: [
                row("c", pr: "example-org/api#9", text: "bump", actor: "renovate"),
                row("m", pr: "example-org/api#9", kind: .mentioned, actor: "renovate", unread: true),
                row("t", pr: "example-org/api#9", kind: .teamMentioned, actor: "renovate", unread: true),
                row("x", pr: "example-org/api#9", kind: .checksFailed, actor: "renovate"),
                row("o", pr: "example-org/api#9", text: "lgtm", actor: "al"),
            ]
        )
    }

    /// Every combination of the PR's own setting, the repository Mute, the
    /// author Mute and your own PR (DESIGN.md, "Mute", the decision).
    func testTheDecision() {
        for own in [false, true] {
            for prMute in [PrMute.none, .mute, .unmute] {
                for repo in [false, true] {
                    for author in [false, true] {
                        let mutes = Mutes(repos: repo ? ["Example-Org/API"] : [], users: author ? ["RENOVATE", "me"] : [])
                        let card = base(own: own, prMute: prMute)
                        let reasons = MuteRules.reasons(card, prMute: prMute, mutes)
                        var expected: [MuteReason] = []
                        if prMute == .mute { expected.append(.pr) }
                        if prMute != .unmute && !own {
                            if repo { expected.append(.repo) }
                            if author { expected.append(.author) }
                        }
                        XCTAssertEqual(reasons, expected, "own \(own) pr \(prMute) repo \(repo) author \(author)")
                        let cardMuted = !reasons.isEmpty
                        let rows = card.rows.map { MuteRules.rowMuted($0, cardMuted: cardMuted, prMute: prMute, mutes) }
                        // c: by the muted user (renovate); m, t: mentions;
                        // x: a state change; o: by al.
                        let byUser = author && prMute != .unmute
                        XCTAssertEqual(rows, [cardMuted || byUser, false, false, cardMuted, cardMuted],
                                       "rows: own \(own) pr \(prMute) repo \(repo) author \(author)")
                    }
                }
            }
        }
    }

    /// `Unmute this pull request` and the − of Settings (DESIGN.md, "Wire
    /// format", `unmute`): none when nothing else mutes it, else Unmute; a
    /// later Mute of the PR replaces Unmute.
    func testMutingAndUnmutingOnePR() {
        let byRepo = [card("P", pr: "example-org/api#9", author: "zz", muted: [.repo])]
        var mutes = Mutes(repos: ["example-org/api"])
        let unmuted = LocalChange.unmute(.pr, "example-org/api#9").apply(byRepo, mutes: &mutes)
        XCTAssertEqual(unmuted[0].prMute, .known(.unmute))
        XCTAssertEqual(unmuted[0].muted, [])
        mutes = Mutes(prs: ["example-org/api#9"])
        let own = [card("P", pr: "example-org/api#9", author: "zz", muted: [.pr], prMute: .mute)]
        let plain = LocalChange.unmute(.pr, "example-org/api#9").apply(own, mutes: &mutes)
        XCTAssertEqual(plain[0].prMute, .known(.none))
        XCTAssertEqual(mutes.prs, [])
        var again = Mutes(repos: ["example-org/api"])
        let muted = LocalChange.mute(.pr, "example-org/api#9").apply(unmuted, mutes: &again)
        XCTAssertEqual(muted[0].prMute, .known(.mute))
        XCTAssertEqual(muted[0].muted, [.known(.pr), .known(.repo)])
        // A repository Mute later leaves an Unmute PR shown.
        var later = Mutes()
        let kept = LocalChange.mute(.repo, "example-org/api").apply(unmuted, mutes: &later)
        XCTAssertEqual(kept[0].muted, [])
        XCTAssertEqual(kept[0].prMute, .known(.unmute))
    }

    /// Your own PR: a repository or user Mute leaves the card alone, but a
    /// muted user's rows in it stay gray (DESIGN.md, "Mute").
    func testYourOwnPR() {
        let mine = [card("M", pr: "example-org/api#1", author: "me", authored: true, rows: [row("b", pr: "example-org/api#1", actor: "bot")])]
        var mutes = Mutes()
        let repo = LocalChange.mute(.repo, "example-org/api").apply(mine, mutes: &mutes)
        XCTAssertEqual(repo[0].muted, [])
        let user = LocalChange.mute(.user, "bot").apply(repo, mutes: &mutes)
        XCTAssertEqual(user[0].muted, [])
        XCTAssertEqual(user[0].rows[0].muted, true)
        let pr = LocalChange.mute(.pr, "example-org/api#1").apply(user, mutes: &mutes)
        XCTAssertEqual(pr[0].muted, [.known(.pr)], "its own Mute applies")
    }

    /// The menu (DESIGN.md, "Keyboard", the mouse table): Unmute this pull
    /// request on any muted card; the repository and the user by the
    /// account's mutes, which also cover your own PR.
    func testTheMenuOfAMutedCard() {
        func titles(_ card: Card, _ mutes: Mutes, login: String = "x") -> [String] {
            PopoverLogic.muteEntries(card, login: login, mutes: mutes).compactMap { $0?.title }
        }
        let byRepo = card("P", pr: "example-org/api#9", author: "zz", muted: [.repo])
        XCTAssertEqual(titles(byRepo, Mutes(repos: ["example-org/api"])), ["Unmute this pull request", "Unmute example-org/api", "Mute @zz"])
        XCTAssertEqual(PopoverLogic.muteEntries(byRepo, mutes: Mutes(repos: ["example-org/api"]))[0]?.action, .unmute(.pr, "example-org/api#9"))
        let unmute = card("U", pr: "example-org/api#8", author: "zz", prMute: .unmute)
        XCTAssertEqual(titles(unmute, Mutes(repos: ["example-org/api"])), ["Mute this pull request", "Unmute example-org/api", "Mute @zz"])
        let own = card("O", pr: "example-org/api#7", author: "me", authored: true)
        XCTAssertEqual(titles(own, Mutes(repos: ["example-org/api"]), login: "me"), ["Mute this pull request", "Unmute example-org/api"])
        XCTAssertEqual(titles(own, Mutes(users: ["ME"]), login: "me"), ["Mute this pull request", "Mute example-org/api", "Unmute @me"])
    }

    func testTheMutesTheCardsTell() {
        let mutes = Mutes.inferred(from: sampleCards())
        XCTAssertEqual(mutes, Mutes(repos: [], users: ["renovate"], prs: ["example-org/api#402"]))
        XCTAssertEqual(Mutes(users: ["a"]).changing(.user, "A", on: false), Mutes())
        XCTAssertEqual(Mutes(users: ["a"]).changing(.user, "A", on: true), Mutes(users: ["A"]))
    }
}

final class SmallRulesTests: XCTestCase {
    /// DESIGN.md, "Screens": the icon of an account brings its open window
    /// to the front instead of the popover.
    func testTheMenuBarIconWithTheWindowOpen() {
        XCTAssertEqual(SurfaceRules.surfaceToShow(windowOpen: true), .window)
        XCTAssertEqual(SurfaceRules.surfaceToShow(windowOpen: false), .popover)
    }

    /// DESIGN.md, "Row body": 1 line, 3 for an unread mention of you or
    /// your team, 5 after `more`; `more` only when cut short, `less` while
    /// expanded. A mention passes the muted card's gray.
    func testRowBodies() {
        let plain = RowPresentation(row("a", pr: "o/r#1", text: "x"), now: T0)
        XCTAssertEqual(plain.bodyLines, 1)
        XCTAssertNil(plain.toggle(cut: false))
        XCTAssertEqual(plain.toggle(cut: true), "more")
        let team = RowPresentation(row("t", pr: "o/r#1", kind: .teamMentioned, text: "x", unread: true), now: T0, cardMuted: true)
        XCTAssertEqual(team.bodyLines, 3)
        XCTAssertFalse(team.gray, "a team mention keeps its color in a muted card")
        XCTAssertEqual(team.mark, .blue)
        let open = RowPresentation(row("t", pr: "o/r#1", kind: .teamMentioned, text: "x", unread: false), now: T0, expanded: true)
        XCTAssertEqual(open.bodyLines, 5, "read: still expanded")
        XCTAssertEqual(open.collapsedLines, 1)
        XCTAssertEqual(open.toggle(cut: false), "less")
        XCTAssertTrue(RowPresentation(row("c", pr: "o/r#1", text: "x"), now: T0, cardMuted: true).gray)
    }

    /// The UI state 0.5 adds starts from its defaults and reads back.
    func testTheNewUIState() {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.expandedRows(account: "1"), [])
        XCTAssertEqual(store.expandedBodies(account: "1"), [])
        store.setExpandedRows(["c"], account: "1")
        store.setExpandedBodies(["r"], account: "1")
        XCTAssertEqual(defaults.stringArray(forKey: "v4.expandedRows.1"), ["c"])
        XCTAssertEqual(defaults.stringArray(forKey: "v4.expandedBodies.1"), ["r"])
    }

    func testPrMuteOnTheWire() throws {
        func decode(_ field: String) throws -> Card {
            let line = """
            {"id":"c","pr":"o/r#1","account":"1","owner":"o","title":"T","url":"u","author":"a","authored_by_me":false,
             "state_label":"open","review":"none","checks":"none","base_status":"none","base":"m","head":"h",
             "updated_at":1,"links":{"review":"r","checks":"c","base":"b"},"rows":[],"muted":[]\(field)}
            """
            return try JSONDecoder().decode(Card.self, from: Data(line.utf8))
        }
        XCTAssertEqual(try decode(#","pr_mute":"unmute""#).prMute, .known(.unmute))
        XCTAssertEqual(try decode(#","pr_mute":"mute""#).prMute, .known(.mute))
        XCTAssertEqual(try decode("").prMute, .known(.none))
        XCTAssertEqual(try decode(#","pr_mute":"later""#).prMute, .unknown("later"))
    }
}
