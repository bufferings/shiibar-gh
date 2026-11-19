// The my review mark in the list (DESIGN.md, "Card", "My review mark"):
// the cards lay out again when the account's avatar arrives, the dark
// capsule over the real card ground, no mark on the Dismissed list or the
// drag preview, and the heading's text for assistive apps.

import AppKit
import SwiftUI
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import XCTest

@MainActor
final class MyReviewDrawingTests: XCTestCase {
    static var kept: [AnyObject] = []

    final class NoOpener: URLOpening { func open(_ url: URL) {} }
    final class NoNotifier: NotificationPresenting {
        func requestAuthorization() {}
        func present(_ notification: DaemonNotification) {}
    }

    /// An avatar loader that answers once `release` is called, with a PNG.
    final class HeldLoader: ImageLoading, @unchecked Sendable {
        private var waiting: [CheckedContinuation<Data, Error>] = []
        private let lock = NSLock()
        private(set) var asked: [URL] = []

        static let png: Data = {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            return rep.representation(using: .png, properties: [:])!
        }()

        func load(_ url: URL) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    asked.append(url)
                    waiting.append(continuation)
                }
            }
        }

        func release() {
            let all = lock.withLock { () -> [CheckedContinuation<Data, Error>] in
                defer { waiting = [] }
                return waiting
            }
            for continuation in all { continuation.resume(returning: Self.png) }
        }
    }

    func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    let waitingCard = Card(
        id: "W", pr: "example-org/api#7", account: "1001", title: "Retry the fetch", authoredByMe: false, assignedToMe: true,
        awaitingReview: true, placement: Placement(tab: .review, section: .inbox, position: 0)
    )

    /// The account's avatar arrives after the list is shown: the table's
    /// listener lays the card out again with the avatar in the capsule; the
    /// row keeps its height and the list stays consistent.
    func testTheCardsLayOutAgainWhenTheAccountsAvatarArrives() throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: NoOpener(),
            notifier: NoNotifier()
        )
        app.handle(.snapshot(
            accounts: [Account(id: "1001", login: "example-user", avatarUrl: "https://example.test/me.png")],
            keychain: .known(.ok), dbUnreadable: false
        ))
        let data = app.viewModel("1001")
        data.arrived([waitingCard], number: 1)
        let list = data.list(.popover)
        list.openTab(.review)
        let loader = HeldLoader()
        let context = CardContext.of(list, avatars: AvatarStore(loader: loader))
        let controller = ListTableController(content: context.content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = controller.scrollView
        controller.scrollView.frame = window.contentView!.bounds
        Self.kept += [app, data, list, controller, window]
        controller.update(now: 0, k: 1)
        spin()
        XCTAssertEqual(loader.asked, [URL(string: "https://example.test/me.png")!], "asked for when the account is known")
        let before = try XCTUnwrap(controller.cardViews.first)
        let lineBefore = try XCTUnwrap(before.line)
        XCTAssertNil(lineBefore.myAvatar, "not loaded yet: the sign alone")
        let without = try XCTUnwrap(LineLayout.card(lineBefore, width: before.bounds.width + 24, k: 1, now: 0).myReview)
        let heightBefore = before.frame.height
        loader.release()
        spin(0.6)
        let after = try XCTUnwrap(controller.cardViews.first)
        let lineAfter = try XCTUnwrap(after.line)
        XCTAssertEqual(lineAfter.myAvatar, "https://example.test/me.png")
        let with = try XCTUnwrap(LineLayout.card(lineAfter, width: after.bounds.width + 24, k: 1, now: 0).myReview)
        XCTAssertEqual(with.capsule.width - without.capsule.width, 14 + 3 - 4, accuracy: 0.001, "room for the avatar")
        XCTAssertNotNil(with.avatar)
        XCTAssertEqual(after.frame.height, heightBefore, "line 1 keeps its height")
        XCTAssertEqual(controller.consistencyProblems(), [], "rows, cells and images agree")
    }

    func render(_ view: NSView, dark: Bool) throws -> CGImage {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return try XCTUnwrap((view as? LineView)?.renderImage())
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

    /// Dark: the capsule's ground is the state's color composed over the
    /// real ground of a card in that appearance.
    func testTheDarkCapsuleIsComposedOverTheRealCardGround() throws {
        let context = context()
        for mark in [MyReviewMark.waiting, .approved, .changesRequested] {
            var card = Card(id: "D", authoredByMe: false)
            switch mark {
            case .waiting: card.awaitingReview = true
            case .approved: card.myReview = .known(.approved)
            case .changesRequested: card.myReview = .known(.changesRequested)
            }
            let line = CardLine(card: card, section: "s", showsTag: false, indented: false, expanded: false, canDrag: true, myReview: MyReviewMark.of(card))
            let g = LineLayout.card(line, width: 460, k: 1, now: 0)
            let frame = try XCTUnwrap(g.myReview)
            let view = CardLineView(frame: CGRect(origin: .zero, size: g.size))
            view.configure(line, geometry: g, env: LineEnvironment(k: 1, now: 0, autoDismissDays: 3, context: context), state: ItemState())
            let image = try render(view, dark: true)
            var ground = LabelRGB.white
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { ground = LabelInk.Ground.current().card }
            let expected = mark.colors(dark: true, card: ground).ground
            let got = pixel(image, x: frame.capsule.minX + 3, y: frame.capsule.midY, scale: CGFloat(image.width) / g.size.width)
            XCTAssertEqual(Double(got[0]), expected.r, accuracy: 2, "\(mark)")
            XCTAssertEqual(Double(got[1]), expected.g, accuracy: 2, "\(mark)")
            XCTAssertEqual(Double(got[2]), expected.b, accuracy: 2, "\(mark)")
        }
    }

    /// The Dismissed list's line and the drag preview draw the same with or
    /// without a mark state: neither shows the mark.
    func testNoMarkOnTheDismissedListOrTheDragPreview() throws {
        let context = context()
        var plain = Card(id: "X", authoredByMe: false, dismissedAt: 1, dismissExpiresAt: 86_400 * 3)
        var marked = plain
        marked.awaitingReview = true
        marked.myReview = nil
        func dismissed(_ card: Card) throws -> CGImage {
            let g = LineLayout.dismissed(card, width: 460, k: 1, now: 0)
            let view = DismissedLineView(frame: CGRect(origin: .zero, size: g.size))
            view.configure(card, search: [], geometry: g, env: LineEnvironment(k: 1, now: 0, autoDismissDays: 3, context: context), state: ItemState())
            return try render(view, dark: false)
        }
        XCTAssertNotNil(try dismissed(plain).dataProviderBytes)
        XCTAssertEqual(try dismissed(plain).dataProviderBytes, try dismissed(marked).dataProviderBytes, "waiting")
        marked.awaitingReview = false
        marked.myReview = .known(.approved)
        XCTAssertEqual(try dismissed(plain).dataProviderBytes, try dismissed(marked).dataProviderBytes, "approved")
        func preview(_ card: Card) -> Data? {
            let host = NSHostingView(rootView: CardDragPreview(card: card, count: 1, width: 300, k: 1))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.appearance = NSAppearance(named: .aqua)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.tiffRepresentation
        }
        plain.dismissedAt = nil
        marked.dismissedAt = nil
        XCTAssertNotNil(preview(plain))
        XCTAssertEqual(preview(plain), preview(marked), "the lifted heading has no mark")
    }

    func testTheHeadingsTextForAssistiveApps() {
        let line = CardLine(
            card: waitingCard, section: "review|inbox", showsTag: false, indented: false, expanded: false, canDrag: true,
            myReview: MyReviewMark.of(waitingCard)
        )
        let g = LineLayout.card(line, width: 460, k: 1, now: 0)
        let heading = CardLineView.accessibilityParts(line, g, now: 0)[0].1
        XCTAssertEqual(
            heading,
            "example-org/api #7, Assigned, Review requested, Retry the fetch, main \u{2190} topic, " + CardText.times(waitingCard, now: 0)
        )
    }
}

private extension CGImage {
    /// The pixel bytes, for comparing two images drawn the same way.
    var dataProviderBytes: Data? {
        dataProvider?.data as Data?
    }
}
