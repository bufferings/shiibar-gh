// The my review mark and the My review rows (DESIGN.md, "Card", "My
// review mark", "My review rows", "Applying the table", "Row labels",
// "Constants"): the wire, the states, the one eye, the colors and the
// event table.

import Foundation
@testable import ShiibarGhCore
import XCTest

final class MyReviewTests: XCTestCase {
    func cardJSON(_ extra: String) -> String {
        #"{"id":"C","pr":"o/r#1","account":"1","owner":"o1","title":"T","url":"u","author":"alice","authored_by_me":false,"#
            + #""state_label":"open","review":"none","checks":"none","base_status":"none","base":"main","head":"t","updated_at":0,"#
            + #""links":{"review":"r","checks":"c","base":"b"},"rows":[]"# + extra + "}"
    }

    func testTheWireCarriesMyReviewAndTheAccountsAvatar() throws {
        let decode = { (extra: String) in try JSONDecoder().decode(Card.self, from: Data(self.cardJSON(extra).utf8)) }
        XCTAssertEqual(try decode(#","my_review":"approved""#).myReview, .known(.approved))
        XCTAssertEqual(try decode(#","my_review":"changes_requested""#).myReview, .known(.changesRequested))
        XCTAssertNil(try decode(#","my_review":null"#).myReview)
        XCTAssertNil(try decode("").myReview, "no key: no verdict")
        XCTAssertEqual(try decode(#","my_review":"later_value""#).myReview, .unknown("later_value"))
        let account = #"{"id":"1","login":"example-user","color":"none","token":{"registered":true},"unread":false,"warnings":[],"owners":[]"#
        XCTAssertEqual(
            try JSONDecoder().decode(Account.self, from: Data((account + #","avatar_url":"https://example.test/a.png"}"#).utf8)).avatarUrl,
            "https://example.test/a.png"
        )
        XCTAssertNil(try JSONDecoder().decode(Account.self, from: Data((account + "}").utf8)).avatarUrl)
        let row = #"{"id":"r","pr":"o/r#1","pr_title":"T","account":"1","owner":"o1","kind":"my_review_changes_requested","text":null,"actor":"example-user","url":"https://github.com/o/r/pull/1#pullrequestreview-1","occurred_at":5,"unread":false}"#
        XCTAssertEqual(try JSONDecoder().decode(Row.self, from: Data(row.utf8)).kind, .known(.myReviewChangesRequested))
    }

    func testTheThreeStatesAndWaitingFirst() {
        var card = Card(id: "C", authoredByMe: false)
        XCTAssertNil(MyReviewMark.of(card), "no state: no mark")
        card.myReview = .known(.approved)
        XCTAssertEqual(MyReviewMark.of(card), .approved)
        card.myReview = .known(.changesRequested)
        XCTAssertEqual(MyReviewMark.of(card), .changesRequested)
        card.awaitingReview = true
        XCTAssertEqual(MyReviewMark.of(card), .waiting, "waiting for your review outranks a verdict")
        card.myReview = nil
        XCTAssertEqual(MyReviewMark.of(card), .waiting)
        var own = card
        own.authoredByMe = true
        XCTAssertNil(MyReviewMark.of(own), "not on your own PR")
        for state in [StateLabel.merged, .closed] {
            var done = Card(id: "D", authoredByMe: false, awaitingReview: true, stateLabel: state, myReview: .approved)
            XCTAssertNil(MyReviewMark.of(done), "\(state)")
            done.awaitingReview = false
            XCTAssertNil(MyReviewMark.of(done), "\(state)")
        }
        XCTAssertEqual(MyReviewMark.waiting.toolTip, "Review requested")
        XCTAssertEqual(MyReviewMark.approved.toolTip, "My review: Approved")
        XCTAssertEqual(MyReviewMark.changesRequested.toolTip, "My review: Changes requested")
    }

    /// One eye in the app: the rows Review requested, Review requested to
    /// my team and Ready for review, and the waiting mark, the mark with its
    /// own line width only.
    func testTheMarkAndTheRowsShareOneEye() {
        XCTAssertEqual(BoardIcons.row(.known(.reviewRequested)), BoardIcons.eye)
        XCTAssertEqual(BoardIcons.row(.known(.teamReviewRequested)), BoardIcons.eye)
        XCTAssertEqual(BoardIcons.row(.known(.readyForReview)), BoardIcons.eye)
        let mark = MyReviewMark.waiting.sign
        XCTAssertEqual(mark.elements, BoardIcons.eye.elements)
        XCTAssertEqual(mark.fills, BoardIcons.eye.fills)
        XCTAssertEqual(mark.withLineWidth(BoardIcons.eye.lineWidth), BoardIcons.eye)
        XCTAssertEqual(mark.lineWidth, 1.63)
        XCTAssertEqual(BoardIcons.eye.lineWidth, 1.4)
        XCTAssertEqual(BoardIcons.eye.fills, [.circle(cx: 8, cy: 8, r: 2, dash: nil)], "the pupil is filled")
        XCTAssertEqual(BoardIcons.eye.elements, [.path("M1 8C2.6 4.9 5 2.75 8 2.75S13.4 4.9 15 8C13.4 11.1 11 13.25 8 13.25S2.6 11.1 1 8z")])
        XCTAssertEqual(MyReviewMark.waiting.signSize, 12)
        XCTAssertEqual(MyReviewMark.approved.signSize, 10)
        XCTAssertEqual(MyReviewMark.approved.signGrid, 10)
        XCTAssertEqual(BoardIcons.row(.known(.convertedToDraft)), BoardIcons.kindConvertedToDraft)
    }

    func testTheMyReviewRows() {
        XCTAssertEqual(RowText.label(.known(.myReviewApproved)), "Approved")
        XCTAssertEqual(RowText.label(.known(.myReviewChangesRequested)), "Changes requested")
        XCTAssertEqual(BoardIcons.row(.known(.myReviewApproved)), BoardIcons.row(.known(.approved)), "the icon of Approved")
        XCTAssertEqual(BoardIcons.row(.known(.myReviewChangesRequested)), BoardIcons.row(.known(.changesRequested)))
        let p = RowPresentation(Row(id: "r", kind: .myReviewApproved, actor: "example-user", unread: false), now: 0)
        XCTAssertEqual(p.actor, "example-user", "the account itself")
        XCTAssertNil(p.body)
        XCTAssertEqual(p.mark, .none, "read")
    }

    func testTheEventTableHasMyReviewWithoutNotify() {
        XCTAssertEqual(SettingsText.eventGroups.first?.1, [.reviewRequested, .teamReviewRequested, .assigned, .myReview, .mentioned, .teamMentioned])
        XCTAssertEqual(SettingsText.eventTitle(.myReview), "My review")
        XCTAssertFalse(SettingsModel.hasColumn(.myReview, .notify))
        XCTAssertTrue(SettingsModel.hasColumn(.myReview, .list))
        XCTAssertTrue(SettingsModel.hasColumn(.reviewRequested, .notify))
        XCTAssertEqual(SettingsModel.noNotifyHelp, "Your own reviews never notify")
    }

    /// The colors of "Constants": light as given; dark over the card's
    /// ground. Over the board's dark card (#323232) the sign reaches the
    /// contrasts the spec records.
    func testTheColors() {
        let white = LabelRGB.white
        XCTAssertEqual(MyReviewMark.waiting.colors(dark: false, card: white).ground, LabelRGB(hex: 0xFBE3D6))
        XCTAssertEqual(MyReviewMark.waiting.colors(dark: false, card: white).sign, LabelRGB(hex: 0xA0390A))
        XCTAssertEqual(MyReviewMark.approved.colors(dark: false, card: white).ground, LabelRGB(hex: 0xDDF4E4))
        XCTAssertEqual(MyReviewMark.approved.colors(dark: false, card: white).sign, LabelRGB(hex: 0x136C2E))
        XCTAssertEqual(MyReviewMark.changesRequested.colors(dark: false, card: white).ground, LabelRGB(hex: 0xFBE0E0))
        XCTAssertEqual(MyReviewMark.changesRequested.colors(dark: false, card: white).sign, LabelRGB(hex: 0xA1161F))
        let board = LabelRGB(hex: 0x323232)
        let waiting = MyReviewMark.waiting.colors(dark: true, card: board)
        XCTAssertEqual(waiting.ground, board.under(LabelRGB(hex: 0xC7420D), alpha: 0.30))
        XCTAssertEqual(waiting.sign, LabelRGB(hex: 0xFFA77E))
        let expected: [(MyReviewMark, Double, Double)] = [(.waiting, 5.4, 5.5), (.approved, 5.3, 5.6), (.changesRequested, 5.9, 6.4)]
        for (mark, dark, light) in expected {
            let d = mark.colors(dark: true, card: board)
            let l = mark.colors(dark: false, card: white)
            XCTAssertEqual(d.sign.contrast(d.ground), dark, accuracy: 0.06, "\(mark) dark")
            XCTAssertEqual(l.sign.contrast(l.ground), light, accuracy: 0.06, "\(mark) light")
        }
    }
}
