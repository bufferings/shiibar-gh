// The open Filter options in their box (DESIGN.md, "Filter", "Constants";
// Main.html `.fopt2`): the cards' ground and border, the cards' side
// inset, square at the top left where the `Filter` tab joins; two rows (the
// Status buttons; the Muted and Unread switches and `Reset`), which wrap
// when the box is narrow; its sizes scale with the text. Drawn offscreen;
// no daemon.

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import SwiftUI
import XCTest

@MainActor
final class FilterBoxTests: XCTestCase {
    typealias Geometry = FilterOptionsGeometry

    /// At text size 12 in the popover (460 points): 6 + 22 + 6 + 22 + 6 =
    /// 62 points, the headings in a 44-point column, the Status buttons and
    /// the Muted switch lined up right of it, `Reset` at the right end.
    func testTheTwoRowsAtTextSize12() {
        let width = FilterOptionsLayout.boxWidth(surface: 460)
        XCTAssertEqual(width, 436, "the cards' side inset")
        let g = Geometry(filter: ListFilter(muted: .show, unreadOnly: true), width: width, k: 1)
        XCTAssertEqual(g.height, 62)
        XCTAssertEqual(g.rows, 2)
        XCTAssertEqual(g.statusLines, 1)
        XCTAssertEqual(g.lines, 2)
        XCTAssertEqual(g.headings.map(\.title), ["Status", "Muted", "Unread"])
        XCTAssertEqual(g.headings[0].frame.minX, 10)
        XCTAssertEqual(g.headings[1].frame.minX, 10)
        XCTAssertEqual(g.chips.map(\.title), ["Open", "Draft", "Merged", "Closed"])
        XCTAssertEqual(g.chips.first?.frame.minX, 54, "right of the 44-point column")
        XCTAssertEqual(g.muted.first?.frame.minX, 54, "lined up with the Status buttons")
        XCTAssertEqual(g.chips.map(\.frame.minY), [6, 6, 6, 6])
        XCTAssertEqual(g.chips.map(\.frame.height), [22, 22, 22, 22])
        for (a, b) in zip(g.chips, g.chips.dropFirst()) { XCTAssertEqual(b.frame.minX - a.frame.maxX, 4, "4 between the buttons") }
        XCTAssertEqual(g.muted.first?.frame.minY, 34)
        XCTAssertEqual(g.muted.map(\.on), [false, true, false])
        XCTAssertEqual(g.unread.map(\.title), ["All", "Only"])
        XCTAssertEqual(g.unread.map(\.on), [false, true], "Only is Unread only")
        XCTAssertEqual(g.headings[2].frame.minX, Geometry.switchFrame(g.muted).maxX + 14)
        XCTAssertEqual(g.unread.first?.frame.minX, g.headings[2].frame.maxX + 6)
        XCTAssertEqual(g.reset.frame.maxX, width - 10, "Reset at the right end")
        XCTAssertEqual(g.reset.frame.minY, 34)
        // A button is as wide on as off: the name and the padding only
        // (DESIGN.md, "Filter": no ✓, the regular weight).
        XCTAssertEqual(Geometry.chipWidth("Open", k: 1), (Ink.width("Open", Ink.font(12)) + 20).rounded(.up))
        let off = Geometry(filter: ListFilter(statuses: [.draft]), width: width, k: 1)
        XCTAssertEqual(off.chips.map(\.frame.width), g.chips.map(\.frame.width), "the same widths on and off")
        XCTAssertEqual(off.chips.map(\.on), [false, true, false, false])
        let all = ListFilter()
        XCTAssertEqual(Geometry(filter: all, width: width, k: 1).unread.map(\.on), [true, false], "All while Unread only is off")
    }

    /// In the popover, whose width follows the text size, the two rows fit
    /// at text sizes 9, 12 and 18 in every state; the sizes are in
    /// proportion to the text size.
    func testTheRowsFitInThePopoverAtEveryTextSize() {
        let states = [
            ListFilter(), ListFilter(muted: .only, unreadOnly: true), ListFilter(muted: .show, statuses: [.closed], unreadOnly: true),
        ]
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let width = FilterOptionsLayout.boxWidth(surface: CGFloat(TextSize.width(size)))
            for filter in states {
                let g = Geometry(filter: filter, width: width, k: k)
                XCTAssertEqual(g.rows, 2, "\(size) \(filter)")
                XCTAssertEqual(g.statusLines, 1, "\(size) \(filter)")
                XCTAssertEqual(g.height, 62 * k, accuracy: 0.001, "\(size)")
                XCTAssertLessThanOrEqual(g.reset.frame.minX - Geometry.switchFrame(g.unread).maxX, width, "\(size)")
                XCTAssertGreaterThanOrEqual(g.reset.frame.minX - Geometry.switchFrame(g.unread).maxX, 14 * k - 0.001, "\(size)")
                XCTAssertEqual(g.chips.first?.frame.height ?? 0, 22 * k, accuracy: 0.001)
            }
        }
    }

    /// Narrow (a narrow window): the Status buttons wrap within the column
    /// right of the heading, and Unread with `Reset` moves to a third row,
    /// `Unread` in the first column; the box grows with the lines.
    func testANarrowBoxWraps() {
        let k: CGFloat = 1
        let g = Geometry(filter: ListFilter(), width: 240, k: k)
        XCTAssertGreaterThanOrEqual(g.statusLines, 2)
        XCTAssertEqual(g.rows, 3)
        let column: CGFloat = 54
        XCTAssertTrue(g.chips.allSatisfy { $0.frame.minX >= column && $0.frame.maxX <= 240 - 10 }, "\(g.chips.map(\.frame))")
        XCTAssertEqual(Set(g.chips.map(\.frame.minY)).count, g.statusLines)
        XCTAssertEqual(g.headings[2].frame.minX, 10, "Unread in the first column")
        XCTAssertEqual(g.unread.first?.frame.minX, column)
        XCTAssertEqual(g.reset.frame.minY, g.unread.first?.frame.minY, "Reset on Unread's row")
        XCTAssertEqual(g.reset.frame.maxX, 240 - 10)
        XCTAssertEqual(g.lines, g.statusLines + g.rows - 1)
        let lines = CGFloat(g.lines)
        XCTAssertEqual(g.height, 12 + lines * 22 + (lines - 1) * 6)
        XCTAssertEqual(FilterOptionsLayout.areaHeight(box: g.height, k: k), g.height + 6)
    }

    /// The least height of the surface is the same whether the options are
    /// open or closed, whether a band shows and whatever the list starts
    /// with: open, the list's top moves down by the options' area less the
    /// closed row's room under it (6, or none when the list starts with a
    /// band heading); at it, with the options open and no band, the list
    /// keeps its minimum; a band takes its room from the list.
    func testTheMinimumHeightDependsOnTheTextSizeOnly() {
        for k in [CGFloat(0.75), 1, 1.25, 1.5] {
            let row = 180 * k, hints = 26 * k, band = 37 * k
            let area = FilterOptionsLayout.areaHeight(box: 62 * k, k: k)
            XCTAssertEqual(area, 68 * k, accuracy: 0.001, "62 + 6: the tab meets the box")
            let composed = SurfaceHeight.minimum(above: row + area, below: hints, k: k)
            for bandFirst in [false, true] {
                func minimum(open: Bool, band shown: CGFloat) -> CGFloat {
                    let room = FilterOptionsLayout.closedRoom(open: open, bandFirst: bandFirst)
                    let listTop = row + shown + room + (open ? area : 0)
                    return FilterOptionsLayout.surfaceMinimum(
                        listTop: listTop, shownOptions: open ? area : 0, rowRoom: room, bands: shown, below: hints, area: area, k: k
                    )
                }
                XCTAssertEqual(minimum(open: false, band: 0), composed, "k \(k) band first \(bandFirst): closed")
                XCTAssertEqual(minimum(open: true, band: 0), composed, "k \(k) band first \(bandFirst): open")
                XCTAssertEqual(minimum(open: true, band: band), composed, "k \(k) band first \(bandFirst): with a band")
                XCTAssertEqual(minimum(open: false, band: band), composed, "k \(k) band first \(bandFirst): closed, with a band")
                // Opening moves the list's top by the shift.
                let closedTop = row + FilterOptionsLayout.closedRoom(open: false, bandFirst: bandFirst)
                let openTop = row + area
                XCTAssertEqual(openTop - closedTop, FilterOptionsLayout.openShift(area: area, bandFirst: bandFirst), accuracy: 0.001)
            }
            XCTAssertEqual(FilterOptionsLayout.openShift(area: area, bandFirst: false), area - 6, accuracy: 0.001, "6 at every text size")
            XCTAssertEqual(FilterOptionsLayout.openShift(area: area, bandFirst: true), area, accuracy: 0.001)
            let list = composed - (row + area) - hints
            XCTAssertGreaterThanOrEqual(list, 100 * k - 1, "the list keeps its minimum, k \(k)")
        }
    }

    /// At every text size and every width down to the narrowest window
    /// (300 points), whatever is on, no part reaches past the box's inner
    /// width, and no two parts overlap.
    func testNothingPassesTheBoxAtTheNarrowestWindow() {
        let states = [
            ListFilter(), ListFilter(muted: .only, unreadOnly: true), ListFilter(muted: .show, statuses: [.closed], unreadOnly: false),
        ]
        for size in 9...18 {
            let k = CGFloat(TextSize.ratio(size))
            for surface in stride(from: CGFloat(300), through: 700, by: 10) {
                let width = FilterOptionsLayout.boxWidth(surface: surface)
                for filter in states {
                    let g = Geometry(filter: filter, width: width, k: k)
                    let inner = CGRect(x: 10 * k, y: 6 * k, width: width - 20 * k, height: g.height - 12 * k)
                    let frames = g.parts.map(\.frame) + g.headings.map(\.frame)
                    for frame in frames {
                        XCTAssertTrue(inner.insetBy(dx: -0.01, dy: -0.01).contains(frame), "\(size) \(surface): \(frame) in \(inner)")
                    }
                    for (i, a) in frames.enumerated() {
                        for b in frames[(i + 1)...] where a.intersects(b) {
                            XCTFail("\(size) \(surface): \(a) overlaps \(b)")
                        }
                    }
                }
            }
        }
        // At 18 in the narrowest window the Muted switch goes under its
        // heading, and Unread and Reset get lines of their own.
        let k = CGFloat(TextSize.ratio(18))
        let g = Geometry(filter: ListFilter(muted: .only, unreadOnly: true), width: FilterOptionsLayout.boxWidth(surface: 300), k: k)
        XCTAssertEqual(g.muted.first?.frame.minX, 10 * k, "from the left edge")
        XCTAssertGreaterThan(g.muted.first?.frame.minY ?? 0, g.headings[1].frame.minY, "under the heading Muted")
        XCTAssertEqual(g.height, 12 * k + CGFloat(g.lines) * 22 * k + CGFloat(g.lines - 1) * 6 * k, accuracy: 0.001)
    }

    /// Closed, the Filter row keeps 6 points under it (at every text size)
    /// unless the list starts with a band heading, whose top line then sits
    /// right under the row; open, the tab reaches the box either way. A tab's list grouped
    /// into sections starts with a band; Group by None starts with a card,
    /// an empty list with its text.
    func testTheRoomUnderTheClosedRow() {
        for k: CGFloat in [1, 1.5] {
            func height(open: Bool, bandFirst: Bool) -> CGFloat {
                let value = FilterRowState(shows: true, open: open, dot: false, summary: nil, showsGrouping: false, bandFirst: bandFirst)
                return NSHostingView(rootView: FilterRow(value: value, toggle: {}, openGrouping: {}).environment(\.textScale, k)).fittingSize.height
            }
            XCTAssertEqual(height(open: false, bandFirst: true), 26 * k, accuracy: 0.5, "k \(k): band first, no room")
            XCTAssertEqual(height(open: false, bandFirst: false), 26 * k + 6, accuracy: 0.5, "k \(k): card first, 6 under the row")
            XCTAssertEqual(height(open: true, bandFirst: true), 26 * k, accuracy: 0.5)
            XCTAssertEqual(height(open: true, bandFirst: false), 26 * k, accuracy: 0.5)
        }
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: NoOpener(), notifier: NoNotifier()
        )
        app.handle(.snapshot(accounts: [Account(id: "1001", login: "example-user")], keychain: .known(.ok), dbUnreadable: false))
        let data = app.viewModel("1001")
        data.arrived([
            Card(id: "A", pr: "example-org/api#1", account: "1001", title: "Alpha", authoredByMe: false,
                 placement: Placement(tab: .review, section: .inbox, position: 0)),
        ], number: 1)
        let list = data.list(.popover)
        Self.kept += [app, data, list]
        list.openTab(.review)
        XCTAssertTrue(list.startsWithBand, "Review: the Done band first")
        guard case .heading(let first) = ListContent(list: list).entries.first else { return XCTFail("a heading first") }
        XCTAssertEqual(first.level, 1)
        XCTAssertEqual(LineLayout.heading(first, width: 460, k: 1).frame.minY, 0, "its top line at the list's top")
        list.openTab(.all)
        data.setGroupBy(.none)
        XCTAssertFalse(list.startsWithBand, "Group by None: a card first")
        guard case .card = ListContent(list: list).entries.first else { return XCTFail("a card first") }
        list.setSearch("no such words")
        XCTAssertNotNil(list.emptyText)
        XCTAssertFalse(list.startsWithBand, "the text of an empty list first")
    }

    /// The box as drawn: its height is the geometry's, its border starts at
    /// the side inset, its top-left corner is square and its top-right one
    /// round, below it nothing is drawn (no separator line).
    func testTheBoxAsDrawn() throws {
        for k in [CGFloat(1), 1.5] {
            for dark in [false, true] {
                let (rep, height, width) = try render(k: k, dark: dark)
                let box = Geometry(filter: ListFilter(muted: .show), width: FilterOptionsLayout.boxWidth(surface: width), k: k).height
                XCTAssertEqual(height, FilterOptionsLayout.areaHeight(box: box, k: k), accuracy: 1, "k \(k)")
                let scale = CGFloat(rep.pixelsWide) / width
                let background = try XCTUnwrap(rep.colorAt(x: 2, y: rep.pixelsHigh / 2))
                func differs(_ x: Int, _ y: Int) -> Bool {
                    guard let c = rep.colorAt(x: x, y: y) else { return false }
                    return abs(c.brightnessComponent - background.brightnessComponent) > 0.02
                }
                // The first column that differs from the surface behind,
                // at mid height: the box's border.
                let row = rep.pixelsHigh / 2
                let first = (0..<rep.pixelsWide).first { differs($0, row) }
                XCTAssertEqual(CGFloat(try XCTUnwrap(first)) / scale, 12, accuracy: 1, "k \(k) dark \(dark): the cards' inset")
                let top = 0
                XCTAssertTrue(differs(Int(12 * scale), top), "k \(k) dark \(dark): the top-left corner is square")
                XCTAssertFalse(differs(Int((width - 12) * scale) - 1, top), "k \(k) dark \(dark): the top-right corner is round")
                // The bottom margin is the surface behind: no line under the box.
                let bottom = rep.pixelsHigh - 1
                XCTAssertFalse((0..<rep.pixelsWide).contains { differs($0, bottom) }, "k \(k) dark \(dark)")
            }
        }
    }

    /// The `Filter` tab: open, the cards' ground from the row down to the
    /// box, over the box's top border (no line between them), while beside
    /// the tab the border shows; closed, no ground at the same place.
    func testTheFilterTabJoinsTheBox() throws {
        for dark in [false, true] {
            let k: CGFloat = 1
            let width: CGFloat = 460
            let tab = NSHostingView(rootView: FilterButton(open: true, dot: false, toggle: {}).environment(\.textScale, k)).fittingSize
            for open in [true, false] {
                let list = list()
                let row = Derived<FilterRowState>([]) { FilterRowState(shows: true, open: open, dot: false, summary: "Muted shown", showsGrouping: true) }
                let options = FilterOptionsState(shows: true, filter: ListFilter(muted: .show), canReset: true)
                let view = host(VStack(spacing: 0) {
                    FilterRowSlot(list: list, state: row)
                    if open { FilterOptions(list: list, state: options) }
                }.environment(\.textScale, k), width: width, dark: dark)
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / width
                func color(_ x: CGFloat, _ y: CGFloat) -> NSColor { rep.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.sRGB)! }
                func same(_ a: NSColor, _ b: NSColor) -> Bool {
                    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.02
                }
                let ground = color(width - 4, 4)
                // Inside the tab, left of the icon, at mid height.
                let inside = color(12 + 4, 12)
                if open {
                    XCTAssertFalse(same(inside, ground), "dark \(dark): the tab's ground")
                    // The gap under the row and the box's top border, under the tab.
                    XCTAssertTrue(same(color(12 + tab.width / 2, 25), inside), "dark \(dark): the tab down to the box")
                    XCTAssertTrue(same(color(12 + tab.width / 2, 26 + 0.5), inside), "dark \(dark): no line between the tab and the box")
                    // Beside the tab, the box's top border shows.
                    XCTAssertFalse(same(color(12 + tab.width + 20, 26 + 0.5), inside), "dark \(dark): the box's border beside the tab")
                    XCTAssertFalse(same(color(12 + 0.5, 12), inside), "dark \(dark): the tab's left border")
                } else {
                    XCTAssertTrue(same(inside, ground), "dark \(dark): closed, no ground")
                    XCTAssertTrue(same(color(12 + 0.5, 12), ground), "dark \(dark): closed, no border")
                }
            }
        }
    }

    /// A press on a Status button turns that status on or off (the last
    /// one on stays on), a switch segment picks its value (`Only` of Unread
    /// is Unread only), `Reset` goes back to the defaults and does nothing
    /// while there is nothing to reset. Done through the parts an
    /// assistive app presses, which act as a click does.
    func testThePartsChangeTheFilter() throws {
        let list = list()
        let options = Derived<FilterOptionsState>([]) {
            FilterOptionsState(shows: true, filter: list.filter, canReset: list.canResetFilter)
        }
        let hosting = host(FilterOptionsSlot(list: list, state: options).environment(\.textScale, 1), width: 460, dark: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func view() throws -> FilterOptionsView {
            var found: FilterOptionsView?
            Probe.walk(hosting) { if let v = $0 as? FilterOptionsView { found = v } }
            return try XCTUnwrap(found)
        }
        func press(_ target: Geometry.Target) throws {
            let v = try view()
            let part = try XCTUnwrap(v.accessibilityParts.first { $0.target == target })
            XCTAssertTrue(part.accessibilityPerformPress())
            options.update()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(try view().accessibilityParts.map { $0.accessibilityLabel() ?? "" }, [
            "Status: Open, on", "Status: Draft, on", "Status: Merged, on", "Status: Closed, on",
            "Muted: Hide, selected", "Muted: Show", "Muted: Only", "Unread: All, selected", "Unread: Only", "Reset",
        ])
        XCTAssertFalse(try view().accessibilityParts.last!.isAccessibilityEnabled(), "Reset disabled at the defaults")
        try press(.reset)
        XCTAssertEqual(list.filter, ListFilter(), "nothing to reset")
        try press(.status(.closed))
        XCTAssertFalse(list.filter.shows(.closed))
        XCTAssertEqual(try view().accessibilityParts[3].accessibilityLabel(), "Status: Closed, off")
        try press(.muted(.show))
        XCTAssertEqual(list.filter.muted, .show)
        XCTAssertEqual(try view().accessibilityParts[5].accessibilityLabel(), "Muted: Show, selected")
        try press(.unread(true))
        XCTAssertTrue(list.filter.unreadOnly)
        XCTAssertEqual(try view().accessibilityParts[8].accessibilityLabel(), "Unread: Only, selected")
        try press(.unread(false))
        XCTAssertFalse(list.filter.unreadOnly)
        for status in [PRStatus.open, .draft, .merged] { try press(.status(status)) }
        XCTAssertTrue(list.filter.shows(.merged), "the last status on stays on")
        XCTAssertTrue(try view().accessibilityParts.last!.isAccessibilityEnabled())
        try press(.reset)
        XCTAssertEqual(list.filter, ListFilter())
        // A click acts on the part under the pointer.
        let g = try view().geometry
        XCTAssertEqual(g.target(at: CGPoint(x: g.chips[1].frame.midX, y: g.chips[1].frame.midY)), .status(.draft))
        XCTAssertEqual(g.target(at: CGPoint(x: g.unread[1].frame.midX, y: g.unread[1].frame.midY)), .unread(true))
        XCTAssertNil(g.target(at: CGPoint(x: 2, y: 2)))
    }

    static var kept: [AnyObject] = []

    final class NoOpener: URLOpening { func open(_ url: URL) {} }
    final class NoNotifier: NotificationPresenting {
        func requestAuthorization() {}
        func present(_ notification: DaemonNotification) {}
    }

    /// DESIGN.md, "Constants", "Filter option colors": on is the
    /// selection's accent tint with the accent color's text (a Status
    /// button also the accent line); off the slightly darker ground with the
    /// label color's text and the separator. Drawn, an on button has the
    /// ground of the selected segment and an off one that of a segment not
    /// selected.
    func testTheColorsOfOnAndOff() throws {
        XCTAssertEqual(FilterOptionsView.ground(on: true), Palette.selection)
        XCTAssertEqual(FilterOptionsView.ground(on: false), Palette.optionOff)
        XCTAssertEqual(FilterOptionsView.ink(on: true), Palette.accent)
        XCTAssertEqual(FilterOptionsView.ink(on: false), Palette.text)
        XCTAssertEqual(FilterOptionsView.chipBorder(on: true), Palette.accentLine)
        XCTAssertEqual(FilterOptionsView.chipBorder(on: false), Palette.border)
        XCTAssertEqual(Palette.selection.resolved(dark: false).alphaComponent, 0.16, accuracy: 0.001)
        XCTAssertEqual(Palette.accentLine.resolved(dark: false).alphaComponent, 0.5, accuracy: 0.001)
        for dark in [false, true] {
            let filter = ListFilter(muted: .show, statuses: [.open, .draft, .merged])
            let state = FilterOptionsState(shows: true, filter: filter, canReset: true)
            let view = host(FilterOptions(list: list(), state: state).environment(\.textScale, 1), width: 460, dark: dark)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / 460
            let g = Geometry(filter: filter, width: FilterOptionsLayout.boxWidth(surface: 460), k: 1)
            // The box starts at the cards' inset (12), under the tab's room.
            func color(_ frame: CGRect) -> NSColor {
                rep.colorAt(x: Int((12 + frame.minX + 3) * scale), y: Int((frame.minY + 3) * scale))!.usingColorSpace(.sRGB)!
            }
            func same(_ a: NSColor, _ b: NSColor) -> Bool {
                abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.02
            }
            let on = color(g.chips[0].frame), off = color(g.chips[3].frame)
            XCTAssertFalse(same(on, off), "dark \(dark): on and off differ")
            XCTAssertTrue(same(on, color(g.muted[1].frame)), "dark \(dark): an on button as the selected segment")
            XCTAssertTrue(same(off, color(g.muted[0].frame)), "dark \(dark): an off button as a segment not selected")
        }
    }

    func list() -> SurfaceListModel {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: NoOpener(),
            notifier: NoNotifier()
        )
        let data = app.viewModel("1001")
        let list = data.list(.popover)
        Self.kept += [app, data, list]
        return list
    }

    func host<V: View>(_ view: V, width: CGFloat, dark: Bool) -> NSHostingView<some View> {
        let root = view.frame(width: width).background(Palette.background.color)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: CGSize(width: width, height: host.fittingSize.height))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        Self.kept.append(window)
        return host
    }

    func render(k: CGFloat, dark: Bool) throws -> (NSBitmapImageRep, CGFloat, CGFloat) {
        let state = FilterOptionsState(shows: true, filter: ListFilter(muted: .show), canReset: true)
        let width = 460 * k
        let view = host(FilterOptions(list: list(), state: state).environment(\.textScale, k), width: width, dark: dark)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return (rep, view.bounds.height, width)
    }

    /// The popover's top with the options open, for a look
    /// (`FILTER_BOX_OUT=<directory>`): the tab row, the search row, the
    /// Filter row, the box and the list's first band.
    func testTheTopOfThePopoverWithTheOptionsOpen() throws {
        guard let out = ProcessInfo.processInfo.environment["FILTER_BOX_OUT"] else { return }
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            for dark in [false, true] {
                for open in [true, false] {
                    let list = list()
                    let tabs = Derived<TabRowState>([]) {
                        TabRowState(tab: .all, showingDismissed: false, counts: [.all: 6, .review: 4, .mine: 2], compact: false, dismissedCount: 12)
                    }
                    let search = Derived<SearchRowState>([]) { SearchRowState(search: "", focused: false) }
                    let row = Derived<FilterRowState>([]) {
                        FilterRowState(shows: true, open: open, dot: false, summary: "Muted shown", showsGrouping: true)
                    }
                    let options = FilterOptionsState(shows: true, filter: ListFilter(muted: .show, unreadOnly: true), canReset: true)
                    let top = VStack(spacing: 0) {
                        TabRow(list: list, state: tabs)
                        SearchRow(list: list, state: search)
                        FilterRowSlot(list: list, state: row)
                        if open { FilterOptions(list: list, state: options) }
                        // The list's first band, right at the list's top.
                        Rectangle().fill(Palette.band.color).frame(height: LineLayout.bandHeight(k: k))
                            .overlay(alignment: .top) { Rectangle().fill(Palette.border.color).frame(height: 1) }
                            .overlay(alignment: .bottom) { Rectangle().fill(Palette.border.color).frame(height: 1) }
                            .padding(.bottom, 8)
                    }
                    .environment(\.textScale, k)
                    .foregroundColor(Palette.text.color)
                    let view = host(top, width: CGFloat(TextSize.width(size)), dark: dark)
                    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: out + "/filter-\(size)\(open ? "-open" : "-closed")\(dark ? "-dark" : "").png"))
                }
            }
        }
    }
}
