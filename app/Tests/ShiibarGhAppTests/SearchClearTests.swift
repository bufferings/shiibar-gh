// The search field's clear button (DESIGN.md, "Screens", "Search field"):
// at the right end inside the field while there is text, no room kept
// when empty, the text stopping before it. Drawn offscreen.

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import SwiftUI
import XCTest

@MainActor
final class SearchClearTests: XCTestCase {
    func testTheButtonShowsWithTextAndTheTextStopsBeforeIt() throws {
        for k in [CGFloat(1), 1.5] {
            let empty = try XCTUnwrap(SearchRowProbe.field(k: k, width: 460 * k))
            let typed = try XCTUnwrap(SearchRowProbe.field(k: k, width: 460 * k, text: "retry"))
            // The text field gives the button its room only while there is
            // text: the button's 12·k and the 6 between.
            XCTAssertEqual(empty.width - typed.width, 12 * k + 6, accuracy: 1, "k \(k)")
        }
        XCTAssertEqual(FilterText.clearSearch, "Clear")
        XCTAssertEqual(FilterText.clearSearchLabel, "Clear search")
        XCTAssertNotEqual(BoardIcons.clearSearch, BoardIcons.search)
    }

    /// The search row with and without text, for a look (`SEARCH_ROW_OUT`).
    func testTheSearchRowImages() throws {
        guard let out = ProcessInfo.processInfo.environment["SEARCH_ROW_OUT"] else { return }
        for k in [CGFloat(1), 1.5] {
            for dark in [false, true] {
                for text in ["", "retry cache"] {
                    let root = SearchRowProbe.Host(k: k, text: text).frame(width: 460 * k).background(Palette.background.color)
                    let host = NSHostingView(rootView: root)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(origin: .zero, size: CGSize(width: 460 * k, height: host.fittingSize.height))
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
                    window.appearance = host.appearance
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let name = "search-row-k\(k)\(dark ? "-dark" : "")\(text.isEmpty ? "-empty" : "-text").png"
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/" + name))
                }
            }
        }
    }
}

/// The header's ⌄ menu (DESIGN.md, "Screens"): About and Quit; the gear
/// button next to it opens Settings. The popover of `No accounts yet`,
/// which has no gear button, keeps `Settings…`.
@MainActor
final class HeaderMenuTests: XCTestCase {
    func testTheMenuItems() {
        var opened: [SettingsDestination] = []
        var actions = SurfaceActions(openWindow: nil, openSettings: { opened.append($0) }, about: {}, quit: {})
        XCTAssertEqual(actions.menuItems.map { $0?.title ?? "-" }, ["About Shiibar GH", "-", "Quit"])
        actions.menuHasSettings = true
        XCTAssertEqual(actions.menuItems.map { $0?.title ?? "-" }, ["About Shiibar GH", "Settings…", "-", "Quit"])
        actions.menuItems[1]?.action()
        XCTAssertEqual(opened, [.general])
    }
}
