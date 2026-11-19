// The list's lines with labels and the search (DESIGN.md, "Review",
// "Card", "GitHub labels"): what `ListContent` lays out while searching,
// a label's colors on a selected heading, and `Show labels` changing the
// cards' heights. No daemon: the cards are handed to the account's model.

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import XCTest

@MainActor
final class ListContentLabelsTests: XCTestCase {
    static var kept: [AnyObject] = []

    final class NoOpener: URLOpening { func open(_ url: URL) {} }
    final class NoNotifier: NotificationPresenting {
        func requestAuthorization() {}
        func present(_ notification: DaemonNotification) {}
    }

    let labels = (0..<8).map { PRLabel(name: "area/component-\($0)", color: $0 % 2 == 0 ? "d73a4a" : "fbca04") }

    func model(_ cards: [Card]) -> (AppModel, SurfaceListModel) {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: NoOpener(),
            notifier: NoNotifier()
        )
        app.handle(.snapshot(accounts: [Account(id: "1001", login: "example-user")], keychain: .known(.ok), dbUnreadable: false))
        let data = app.viewModel("1001")
        data.arrived(cards, number: 1)
        let list = data.list(.popover)
        Self.kept += [app, data, list]
        return (app, list)
    }

    func reviewCards() -> [Card] {
        [
            Card(id: "A", pr: "example-org/api#1", account: "1001", title: "Alpha retry", authoredByMe: false,
                 placement: Placement(tab: .review, section: .inbox, position: 0), labels: labels),
            Card(id: "B", pr: "example-org/api#2", account: "1001", title: "Beta cache", authoredByMe: false,
                 placement: Placement(tab: .review, section: .waiting, position: 0)),
        ]
    }

    /// While searching, a section with no matching card shows its heading
    /// and the dashed frame; a collapsed one its heading only.
    func testSearchingKeepsTheEmptyFramesAndACollapsedHeadingOnly() {
        let (_, list) = model(reviewCards())
        list.openTab(.review)
        list.setSearch("Alpha")
        let content = ListContent(list: list)
        let ids = content.entries.map(\.id)
        for key in ["review|done", "review|waiting", "review|doing"] {
            XCTAssertTrue(ids.contains("section:" + key), key)
            XCTAssertTrue(ids.contains("empty:" + key), "the frame of \(key)")
        }
        XCTAssertTrue(ids.contains("card:A"))
        XCTAssertFalse(ids.contains("card:B"), "hidden by the search")
        list.perform(.toggleSection("review|waiting"))
        let collapsed = ListContent(list: list).entries.map(\.id)
        XCTAssertTrue(collapsed.contains("section:review|waiting"))
        XCTAssertFalse(collapsed.contains("empty:review|waiting"), "collapsed: the heading only")
        list.setSearch("zzz-nothing")
        XCTAssertEqual(ListContent(list: list).entries.map(\.id).filter { $0.hasPrefix("section:") }, [], "no section without a match")
    }

    /// `Show labels` off and on: the card lines `ListContent` gives carry
    /// it, so the entry the list's shape cache is keyed by changes, and the
    /// card with labels lays out shorter and taller again.
    func testShowLabelsChangesTheCardLinesAndTheirHeights() {
        let (app, list) = model(reviewCards())
        list.openTab(.review)
        func cardA() -> CardLine? {
            for entry in ListContent(list: list).entries {
                if case .card(let line) = entry, line.card.id == "A" { return line }
            }
            return nil
        }
        let on = try! XCTUnwrap(cardA())
        XCTAssertTrue(on.showsLabels)
        let tall = LineLayout.card(on, width: 460, k: 1, now: 0).size.height
        app.handle(.configChanged(key: "show_labels", value: .bool(false)))
        let off = try! XCTUnwrap(cardA())
        XCTAssertFalse(off.showsLabels)
        let short = LineLayout.card(off, width: 460, k: 1, now: 0).size.height
        XCTAssertLessThan(short, tall, "no label line")
        XCTAssertNotEqual(on, off)
        XCTAssertNotEqual(
            ListEntry.card(on).withoutSearch, ListEntry.card(off).withoutSearch,
            "the shape cache's key (ShapeInputs.entry) differs, so the shape is worked out again"
        )
        app.handle(.configChanged(key: "show_labels", value: .bool(true)))
        XCTAssertEqual(LineLayout.card(try! XCTUnwrap(cardA()), width: 460, k: 1, now: 0).size.height, tall)
    }

    /// The color at a point of an image, as sRGB bytes.
    func pixel(_ image: CGImage, x: CGFloat, y: CGFloat, scale: CGFloat) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // The image's pixel (x, y from the top) at the context's origin.
        let px = (x * scale).rounded(.down)
        let py = CGFloat(image.height) - (y * scale).rounded(.down) - 1
        context.draw(image, in: CGRect(x: -px, y: -py, width: CGFloat(image.width), height: CGFloat(image.height)))
        return bytes
    }

    /// A label keeps its colors when the heading is selected, in light and
    /// in dark: they are worked out from the ground of a card that is not
    /// selected, and drawn over the selection.
    func testALabelKeepsItsColorsOnASelectedHeading() throws {
        let (_, list) = model(reviewCards())
        let context = CardContext.of(list, avatars: AvatarStore(loader: FileImageLoader(), schemes: ["file"]))
        let card = reviewCards()[0]
        let line = CardLine(card: card, section: "review|inbox", showsTag: false, indented: false, expanded: false, canDrag: true, showsLabels: true)
        let geometry = LineLayout.card(line, width: 460, k: 1, now: 0)
        let frame = try XCTUnwrap(geometry.labels.first?.frame)
        for dark in [false, true] {
            let view = CardLineView(frame: CGRect(origin: .zero, size: geometry.size))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let state = ItemState()
            view.configure(line, geometry: geometry, env: LineEnvironment(k: 1, now: 0, autoDismissDays: 3, context: context), state: state)
            let plain = try XCTUnwrap(view.renderImage())
            state.selected = .header(card: card.id)
            let selected = try XCTUnwrap(view.renderImage())
            // Inside the capsule, left of its text.
            let x = frame.minX + 3, y = frame.midY
            XCTAssertEqual(pixel(plain, x: x, y: y, scale: CGFloat(plain.width) / geometry.size.width),
                           pixel(selected, x: x, y: y, scale: CGFloat(selected.width) / geometry.size.width), "dark \(dark)")
            // The heading itself does change (the selection is drawn).
            let gx = geometry.header.maxX - 4, gy = geometry.header.maxY - 2
            let scale = CGFloat(plain.width) / geometry.size.width
            XCTAssertNotEqual(pixel(plain, x: gx, y: gy, scale: scale), pixel(selected, x: gx, y: gy, scale: scale), "dark \(dark)")
        }
    }

    /// On a muted card only the label capsules are faint (0.6): `+N` is
    /// drawn as on any other card (Main.html).
    func testPlusNKeepsFullOpacityOnAMutedCard() throws {
        let (_, list) = model(reviewCards())
        let context = CardContext.of(list, avatars: AvatarStore(loader: FileImageLoader(), schemes: ["file"]))
        XCTAssertEqual(LabelInk.capsuleOpacity(muted: true), 0.6)
        XCTAssertEqual(LabelInk.capsuleOpacity(muted: false), 1)
        func render(muted: Bool) throws -> (CGImage, CardGeometry) {
            let card = Card(
                id: "M", pr: "example-org/api#3", account: "1001", title: "Muted", authoredByMe: false,
                muted: muted ? [.author] : [], labels: [PRLabel(name: "bug", color: "d73a4a")], labelsMore: 8
            )
            let line = CardLine(card: card, section: "s", showsTag: false, indented: false, expanded: false, canDrag: true, showsLabels: true)
            let geometry = LineLayout.card(line, width: 460, k: 1, now: 0)
            let view = CardLineView(frame: CGRect(origin: .zero, size: geometry.size))
            view.appearance = NSAppearance(named: .aqua)
            view.configure(line, geometry: geometry, env: LineEnvironment(k: 1, now: 0, autoDismissDays: 3, context: context), state: ItemState())
            return (try XCTUnwrap(view.renderImage()), geometry)
        }
        let (normal, g1) = try render(muted: false)
        let (faint, g2) = try render(muted: true)
        let more = try XCTUnwrap(g1.labelsMore)
        XCTAssertEqual(more, g2.labelsMore)
        let scale = CGFloat(normal.width) / g1.size.width
        // The darkest pixel of `+8`: the same on both cards.
        func darkest(_ image: CGImage) -> Int {
            var best = 255 * 3
            var x = more.minX
            while x < more.maxX {
                let p = pixel(image, x: x, y: more.midY, scale: scale)
                best = min(best, Int(p[0]) + Int(p[1]) + Int(p[2]))
                x += 0.5
            }
            return best
        }
        XCTAssertEqual(darkest(normal), darkest(faint), "+N at full opacity")
        // The capsule is faint on the muted card.
        let label = try XCTUnwrap(g1.labels.first?.frame)
        XCTAssertNotEqual(pixel(normal, x: label.minX + 3, y: label.midY, scale: scale), pixel(faint, x: label.minX + 3, y: label.midY, scale: scale))
    }
}
