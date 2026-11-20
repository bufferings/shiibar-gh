// The my review mark on line 1 as the AppKit card lays it out and draws it
// (DESIGN.md, "Card", "My review mark", and "Constants"): its place left of
// the status icons, its size with and without the avatar, no text mark on
// line 1, the line at text sizes 9, 12 and 18, Compact, and a muted card.

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import XCTest

@MainActor
final class MyReviewLayoutTests: XCTestCase {
    func line(_ card: Card, avatar: String? = "https://example.test/me.png", compact: Bool = false) -> CardLine {
        CardLine(
            card: card, section: "s", showsTag: false, expanded: false, canDrag: true, compact: compact,
            myReview: MyReviewMark.of(card), myAvatar: avatar
        )
    }

    func waiting() -> Card {
        Card(id: "W", authoredByMe: false, assignedToMe: true, reviewRequested: true, awaitingReview: true)
    }

    func testTheMarkSitsLeftOfTheStatusIconsAtTheCirclesGap() throws {
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let g = LineLayout.card(line(waiting()), width: CGFloat(TextSize.width(size)), k: k, now: 0)
            let mark = try XCTUnwrap(g.myReview)
            let first = try XCTUnwrap(g.status.first)
            let circleLeft = first.midX - 12.25 * k / 2
            XCTAssertEqual(circleLeft - mark.capsule.maxX, 2 + 7.75 * k, accuracy: 0.001, "the circles' gap, size \(size)")
            let second = g.status[1]
            XCTAssertEqual((second.midX - 12.25 * k / 2) - (first.midX + 12.25 * k / 2), 2 + 7.75 * k, accuracy: 0.001)
            XCTAssertEqual(mark.capsule.height, 18 * k, accuracy: 0.001)
            XCTAssertEqual(mark.capsule.midY, first.midY, accuracy: 0.001, "centered on line 1")
            let avatar = try XCTUnwrap(mark.avatar)
            XCTAssertEqual(avatar.width, 14 * k, accuracy: 0.001)
            XCTAssertEqual(avatar.minX - mark.capsule.minX, 2 * k, accuracy: 0.001)
            XCTAssertEqual(mark.sign.minX - avatar.maxX, 3 * k, accuracy: 0.001)
            XCTAssertEqual(mark.capsule.maxX - mark.sign.maxX, 6 * k, accuracy: 0.001)
            XCTAssertEqual(mark.sign.width, 12 * k, accuracy: 0.001, "the eye at 12")
        }
    }

    func testTheSizesOfTheThreeStatesWithAndWithoutTheAvatar() throws {
        var approved = Card(id: "A", authoredByMe: false, myReview: .approved)
        let with = try XCTUnwrap(LineLayout.card(line(approved), width: 460, k: 1, now: 0).myReview)
        XCTAssertEqual(with.mark, .approved)
        XCTAssertEqual(with.capsule.width, 2 + 14 + 3 + 10 + 6, accuracy: 0.001)
        XCTAssertEqual(with.sign.width, 10, accuracy: 0.001)
        let without = try XCTUnwrap(LineLayout.card(line(approved, avatar: nil), width: 460, k: 1, now: 0).myReview)
        XCTAssertNil(without.avatar, "no avatar image: the sign alone, no room for it")
        XCTAssertEqual(without.capsule.width, 6 + 10 + 6, accuracy: 0.001)
        XCTAssertEqual(without.capsule.maxX, with.capsule.maxX, accuracy: 0.001)
        let eye = try XCTUnwrap(LineLayout.card(line(waiting()), width: 460, k: 1, now: 0).myReview)
        XCTAssertEqual(eye.capsule.width - with.capsule.width, 2, accuracy: 0.001, "the eye's capsule is 2 wider")
        approved.myReview = .known(.changesRequested)
        XCTAssertEqual(LineLayout.card(line(approved), width: 460, k: 1, now: 0).myReview?.mark, .changesRequested)
        approved.myReview = nil
        XCTAssertNil(LineLayout.card(line(approved), width: 460, k: 1, now: 0).myReview, "no state: no mark")
    }

    func testNoTextMarkOnLineOne() {
        let g = LineLayout.card(line(waiting()), width: 460, k: 1, now: 0)
        XCTAssertEqual(g.marks.map(\.0), ["Assigned"], "Review requested is the mark now, not a text")
        XCTAssertEqual(
            CardLineView.accessibilityParts(line(waiting()), g, now: 0)[0].1,
            "o/r #1, Assigned, Review requested, Title, main \u{2190} topic, " + CardText.times(waiting(), now: 0),
            "the mark's state after the text marks; no text mark of its own"
        )
    }

    func testNoMarkOnAFinishedCardOrYourOwn() {
        let merged = Card(id: "M", authoredByMe: false, awaitingReview: true, stateLabel: .merged, myReview: .approved)
        XCTAssertNil(LineLayout.card(line(merged), width: 460, k: 1, now: 0).myReview)
        let own = Card(id: "O", authoredByMe: true, myReview: .approved)
        XCTAssertNil(LineLayout.card(line(own), width: 460, k: 1, now: 0).myReview)
    }

    /// A long repository name, Assigned, Muted and the mark at text sizes
    /// 9, 12 and 18: the name is cut; the marks, the mark, the status icons
    /// and × stay whole and apart; line 1 keeps its height.
    func testLineOneOverflowAtEveryTextSize() throws {
        let card = Card(
            id: "L", pr: "example-organization-with-a-long-name/a-repository-with-a-very-long-name#12345",
            authoredByMe: false, assignedToMe: true, awaitingReview: true, muted: [.author]
        )
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let g = LineLayout.card(line(card), width: CGFloat(TextSize.width(size)), k: k, now: 0)
            let mark = try XCTUnwrap(g.myReview)
            XCTAssertEqual(g.marks.map(\.0), ["Assigned", "Muted"], "size \(size)")
            XCTAssertLessThan(g.prLabel.width, Ink.width(Warnings.prLabel(card.pr), Ink.font(11 * k)), "the name is cut")
            let lastMark = try XCTUnwrap(g.marks.last?.1)
            XCTAssertLessThanOrEqual(lastMark.maxX, mark.capsule.minX - 7 + 0.001, "size \(size)")
            XCTAssertEqual(g.marks[0].1.width, Ink.width("Assigned", Ink.font(10 * k, .semibold)) + 10 * k, accuracy: 0.001)
            XCTAssertLessThan(mark.capsule.maxX, g.status[0].minX + 3.875 * k)
            XCTAssertLessThanOrEqual(g.status[2].maxX, g.dismiss.minX)
            let plain = LineLayout.card(line(Card(id: "P", authoredByMe: false)), width: CGFloat(TextSize.width(size)), k: k, now: 0)
            XCTAssertEqual(g.header.minY, plain.header.minY)
            XCTAssertEqual(g.title.minY, plain.title.minY, accuracy: 0.001, "line 1 keeps its height")
        }
    }

    func testCompactShowsTheMarkToo() {
        let compact = LineLayout.card(line(waiting(), compact: true), width: 460, k: 1, now: 0)
        XCTAssertNotNil(compact.myReview)
        XCTAssertEqual(compact.myReview, LineLayout.card(line(waiting()), width: 460, k: 1, now: 0).myReview)
    }

    // MARK: Drawing

    static var kept: [AnyObject] = []

    final class NoOpener: URLOpening { func open(_ url: URL) {} }
    final class NoNotifier: NotificationPresenting {
        func requestAuthorization() {}
        func present(_ notification: DaemonNotification) {}
    }

    func context() -> CardContext {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: NoOpener(),
            notifier: NoNotifier()
        )
        let list = app.viewModel("1001").list(.popover)
        Self.kept += [app, list]
        return CardContext.of(list, avatars: AvatarStore(loader: FileImageLoader(), schemes: ["file"]))
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

    /// A muted card's mark keeps its colors, as the status icons do; the
    /// capsule is drawn in the "Constants" ground in light.
    func testAMutedCardKeepsTheMarksColors() throws {
        let context = context()
        func render(_ card: Card) throws -> (CGImage, CardGeometry) {
            let l = line(card, avatar: nil)
            let g = LineLayout.card(l, width: 460, k: 1, now: 0)
            let view = CardLineView(frame: CGRect(origin: .zero, size: g.size))
            view.appearance = NSAppearance(named: .aqua)
            view.configure(l, geometry: g, env: LineEnvironment(k: 1, now: 0, autoDismissDays: 3, context: context), state: ItemState())
            return (try XCTUnwrap(view.renderImage()), g)
        }
        let (plain, g) = try render(Card(id: "A", authoredByMe: false, myReview: .approved))
        let (muted, _) = try render(Card(id: "A", authoredByMe: false, muted: [.author], myReview: .approved))
        let frame = try XCTUnwrap(g.myReview)
        let scale = CGFloat(plain.width) / g.size.width
        let x = frame.capsule.minX + 3, y = frame.capsule.midY
        XCTAssertEqual(pixel(plain, x: x, y: y, scale: scale), pixel(muted, x: x, y: y, scale: scale))
        let ground = pixel(plain, x: x, y: y, scale: scale)
        XCTAssertEqual(Int(ground[0]), 0xDD, accuracy: 2)
        XCTAssertEqual(Int(ground[1]), 0xF4, accuracy: 2)
        XCTAssertEqual(Int(ground[2]), 0xE4, accuracy: 2)
    }

    func testTheTooltipOfTheMark() throws {
        let context = context()
        let l = line(waiting())
        let g = LineLayout.card(l, width: 460, k: 1, now: 0)
        let view = CardLineView(frame: CGRect(origin: .zero, size: g.size))
        view.configure(l, geometry: g, env: LineEnvironment(k: 1, now: 0, autoDismissDays: 3, context: context), state: ItemState())
        let mark = try XCTUnwrap(g.myReview)
        XCTAssertEqual(view.tip(at: CGPoint(x: mark.capsule.midX, y: mark.capsule.midY)), "Review requested")
        // Not a control: no control's frame covers it, so a press on it is
        // a press on the heading.
        XCTAssertNil(view.regions.controls.values.first { $0.contains(CGPoint(x: mark.capsule.midX, y: mark.capsule.midY)) })
    }
}
