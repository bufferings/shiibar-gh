// The open Filter options in their box (DESIGN.md, "Filter"; Main.html
// `.fopts`): the cards' background and border, rounded, the cards' side
// inset; its heights scale with the text. Drawn offscreen; no daemon.

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import SwiftUI
import XCTest

@MainActor
final class FilterBoxTests: XCTestCase {
    func testTheBoxMetricsScaleWithTheText() {
        XCTAssertEqual(FilterOptionsLayout.boxRadius, 8)
        let one = FilterOptionsLayout.scaled(FilterOptionsLayout.boxMargin, 1)
        XCTAssertEqual([one.top, one.leading, one.bottom, one.trailing], [2, 12, 6, 12], "the cards' side inset; 6 under it as under the closed row")
        let padding = FilterOptionsLayout.scaled(FilterOptionsLayout.boxPadding, 1.5)
        XCTAssertEqual([padding.top, padding.leading, padding.bottom, padding.trailing], [7.5, 12, 7.5, 10], "the sides as the cards'")
        let margin = FilterOptionsLayout.scaled(FilterOptionsLayout.boxMargin, 1.5)
        XCTAssertEqual([margin.top, margin.leading, margin.bottom, margin.trailing], [3, 12, 9, 12])
        // Three option lines and Reset (27 + 27 + 27 + 28), the box's
        // padding, border and margins.
        XCTAssertEqual(FilterOptionsLayout.contentHeight(lines: 3, k: 1), 109)
        XCTAssertEqual(FilterOptionsLayout.areaHeight(lines: 3, k: 1), 109 + 10 + 8 + 2)
        XCTAssertEqual(FilterOptionsLayout.areaHeight(lines: 3, k: 1.5), 163.5 + 15 + 12 + 2)
    }

    /// The least height of the surface is the same whether the options are
    /// open or closed and whether a band shows (the list's top moves down
    /// by the options' area or the band's height); at it, with the options
    /// open and no band, the list keeps its minimum; a band takes its room
    /// from the list.
    func testTheMinimumHeightDependsOnTheTextSizeOnly() {
        for k in [CGFloat(0.75), 1, 1.25, 1.5] {
            let fixed = 180 * k, hints = 26 * k, band = 37 * k
            let area = FilterOptionsLayout.areaHeight(lines: 3, k: k)
            func minimum(open: Bool, band shown: CGFloat) -> CGFloat {
                FilterOptionsLayout.surfaceMinimum(
                    listTop: fixed + shown + (open ? area : 0), shownOptions: open ? area : 0, bands: shown, below: hints, lines: 3, k: k
                )
            }
            let composed = SurfaceHeight.minimum(above: fixed + area, below: hints, k: k)
            XCTAssertEqual(minimum(open: false, band: 0), composed, "k \(k): the composition")
            XCTAssertEqual(minimum(open: true, band: 0), composed, "k \(k): open")
            XCTAssertEqual(minimum(open: true, band: band), composed, "k \(k): with a band")
            XCTAssertEqual(minimum(open: false, band: band), composed, "k \(k): closed, with a band")
            let list = composed - (fixed + area) - hints
            XCTAssertGreaterThanOrEqual(list, 100 * k - 1, "the list keeps its minimum, k \(k)")
            XCTAssertEqual(composed - (fixed + band + area) - hints, list - band, accuracy: 0.001, "a band takes its room from the list")
        }
    }

    /// The box as drawn: its height is the area's, its border starts at the
    /// side inset, below it nothing is drawn (no separator line).
    func testTheBoxAsDrawn() throws {
        for k in [CGFloat(1), 1.5] {
            for dark in [false, true] {
                let (rep, height, width) = try render(k: k, dark: dark)
                XCTAssertEqual(height, FilterOptionsLayout.areaHeight(lines: 3, k: k), accuracy: 1, "k \(k)")
                let scale = CGFloat(rep.pixelsWide) / width
                let background = try XCTUnwrap(rep.colorAt(x: 2, y: rep.pixelsHigh / 2))
                // The first column that differs from the surface behind,
                // at mid height: the box's border.
                let row = rep.pixelsHigh / 2
                let first = (0..<rep.pixelsWide).first { x in
                    guard let c = rep.colorAt(x: x, y: row) else { return false }
                    return abs(c.brightnessComponent - background.brightnessComponent) > 0.02
                }
                XCTAssertEqual(CGFloat(try XCTUnwrap(first)) / scale, 12, accuracy: 1, "k \(k) dark \(dark): the cards' inset")
                // The bottom margin is the surface behind: no line under the box.
                let bottom = rep.pixelsHigh - 1
                let line = (0..<rep.pixelsWide).contains { x in
                    guard let c = rep.colorAt(x: x, y: bottom) else { return false }
                    return abs(c.brightnessComponent - background.brightnessComponent) > 0.02
                }
                XCTAssertFalse(line, "k \(k) dark \(dark)")
            }
        }
    }

    static var kept: [AnyObject] = []

    final class NoOpener: URLOpening { func open(_ url: URL) {} }
    final class NoNotifier: NotificationPresenting {
        func requestAuthorization() {}
        func present(_ notification: DaemonNotification) {}
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
        return host
    }

    func render(k: CGFloat, dark: Bool) throws -> (NSBitmapImageRep, CGFloat, CGFloat) {
        let state = FilterOptionsState(shows: true, lines: FilterOption.allCases, filter: ListFilter(muted: .show), canReset: true)
        let width = 460 * k
        let view = host(FilterOptions(list: list(), state: state).environment(\.textScale, k), width: width, dark: dark)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return (rep, view.bounds.height, width)
    }

    /// The popover's top with the options open, for a look
    /// (`FILTER_BOX_OUT=<directory>`): the tab row, the search row, the
    /// Filter row and the box.
    func testTheTopOfThePopoverWithTheOptionsOpen() throws {
        guard let out = ProcessInfo.processInfo.environment["FILTER_BOX_OUT"] else { return }
        for k in [CGFloat(1), 1.5] {
            for dark in [false, true] {
                let list = list()
                let tabs = Derived<TabRowState>([]) {
                    TabRowState(tab: .all, showingDismissed: false, counts: [.all: 6, .review: 4, .mine: 2], compact: false, dismissedCount: 12)
                }
                let search = Derived<SearchRowState>([]) { SearchRowState(search: "", focused: false) }
                let row = Derived<FilterRowState>([]) {
                    FilterRowState(shows: true, open: true, dot: false, summary: "Muted shown", showsGrouping: true)
                }
                let options = FilterOptionsState(shows: true, lines: FilterOption.allCases, filter: ListFilter(muted: .show), canReset: true)
                let top = VStack(spacing: 0) {
                    TabRow(list: list, state: tabs)
                    SearchRow(list: list, state: search)
                    FilterRowSlot(list: list, state: row)
                    FilterOptions(list: list, state: options)
                    // The list's first band, 8 below the list's top.
                    Rectangle().fill(Palette.band.color).frame(height: 24 * k).clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
                }
                .environment(\.textScale, k)
                .foregroundColor(Palette.text.color)
                let view = host(top, width: 460 * k, dark: dark)
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: out + "/filter-box-k\(k)\(dark ? "-dark" : "").png"))
            }
        }
    }
}
