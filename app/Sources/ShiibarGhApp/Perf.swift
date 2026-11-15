// The measurement mode of docs/tasks/M7.md ("Speed of operation"). Chosen
// with `SHIIBAR_GH_PERF=1` or the launch argument `--perf`, and only with
// `SHIIBAR_GH_STATE_DIR` set: the app then uses a scratch UserDefaults
// suite, registers no login item, asks for no notification permission,
// starts the daemon given by `SHIIBAR_GH_PERF_DAEMON` (a `dev-ingest`
// build, which has no Keychain and no GitHub), opens the always-on-top
// window of the first account, runs the scenarios below, prints the summary
// and quits. scripts/perf/measure.sh runs the whole procedure.
//
// What is measured, on the main thread (where SwiftUI and AppKit lay out
// and draw):
// - A frame: one busy period of the main run loop, from waking up
//   (`afterWaiting`) to going to sleep again (`beforeWaiting`, observed
//   last, after Core Animation's commit, which runs there). A period over
//   16 ms is a frame later than 60 Hz.
// - An operation: from the call the input handler makes (the same model
//   call a click, key or drop makes) to the end of the busy period that
//   committed its result, and the longest busy period in the second after
//   it (the daemon's answer and the list read again).
// - The scroll: the list's NSScrollView moved by a 60 Hz timer at a fixed
//   speed from the top to the bottom; every busy period of the pass counts.
// Every operation and pass is also an OSSignposter interval (subsystem
// `shiibar.gh.perf`, category PointsOfInterest) for Instruments.

import AppKit
import os
import ShiibarGhCore

extension Array {
    /// `count` elements, going round the array.
    func cycled(_ count: Int) -> [Element] {
        isEmpty ? [] : (0..<count).map { self[$0 % self.count] }
    }
}

/// The title bar's own views (the drag map): those AppKit moves the window
/// from, whatever the window's state.
@MainActor
enum NSThemeFrameProbe {
    static func isTitleBar(_ view: NSView) -> Bool {
        let name = String(describing: type(of: view))
        return name == "NSThemeFrame" || name.hasPrefix("NSTitlebar")
    }
}

/// The measurement and demo modes' UserDefaults: in memory only, so
/// nothing reaches the user's Preferences (UIStateStore reads and writes
/// only through these methods).
final class ScratchDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: PerfMode.suiteName)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func dictionaryRepresentation() -> [String: Any] { values }
    override func removePersistentDomain(forName domainName: String) { values = [:] }
}

/// A plain flipped document view (the scroll comparison).
final class PerfFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A plain table's rows (the scroll comparison): 241 rows of 100 points.
final class PerfTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 241 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 100 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "Row \(row)")
    }
}

/// Whether the measurement mode is on. Read once.
enum PerfMode {
    static let enabled: Bool = {
        ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF"] == "1" || CommandLine.arguments.contains("--perf")
    }()

    /// The state directory the mode requires: never the real one.
    static var stateRoot: String? {
        ProcessInfo.processInfo.environment[StateDirectory.environmentKey]
    }

    static var daemon: URL? {
        ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_DAEMON"].map { URL(fileURLWithPath: $0) }
    }

    /// The name of the scratch defaults, one per mode (a measurement run
    /// and a demo do not share them). The values are kept in memory only
    /// (`ScratchDefaults`): nothing is written to the user's Preferences.
    static var suiteName: String { demo ? "shiibar.gh.demo" : "shiibar.gh.perf" }

    /// Removes the file an earlier version left in the user's Preferences
    /// for the mode's suite (it kept the values in a real suite and
    /// emptied it with `removePersistentDomain(forName:)`, which left a
    /// 42-byte property list; deleting that file at quit did not help:
    /// the preferences daemon wrote it again afterwards). The folder is the
    /// user domain's Library (`FileManager.urls(for:in:)`) plus
    /// `Preferences`, where defaults keep a domain as `<domain>.plist`.
    static func removeLeftoverSuite() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let file = library.appendingPathComponent("Preferences").appendingPathComponent(suiteName + ".plist")
        try? FileManager.default.removeItem(at: file)
    }

    /// The demo mode (scripts/perf/demo.sh, `SHIIBAR_GH_DEMO=1`): the
    /// measurement mode's sandbox (a scratch UserDefaults suite, the given
    /// state directory and `dev-ingest` daemon, no login item, no
    /// notification permission, file avatars) with the app used by hand:
    /// nothing runs by itself.
    static let demo: Bool = ProcessInfo.processInfo.environment["SHIIBAR_GH_DEMO"] == "1"

    /// The measurement or the demo mode: the sandbox either way.
    static var sandboxed: Bool { enabled || demo }
}

/// How many times cards were drawn (`cards`) and configured for a table
/// row (`rows`), in the measurement mode only.
@MainActor
enum PerfCounters {
    static var cards = 0
    static var rows = 0
    /// Table cells made (not reused).
    static var made = 0
    /// Line geometries worked out (not found kept).
    static var shapes = 0

    static func card() {
        if PerfMode.enabled { cards += 1 }
    }

    /// What ran in the current busy period of the main run loop (reset
    /// when the run loop wakes up), for the slow frames of a scroll pass.
    struct FrameWork {
        var made = 0
        var configured = 0
        var images = 0
        var imageMs = 0.0
        var cardImages = 0
        var shapes = 0
        var shapeMs = 0.0
        var textMisses = 0
        var textMs = 0.0
        var applies = 0
        var applyMs = 0.0
        var reloads = 0
        var tracking = 0
        var checks = 0
        /// Lines typeset (CoreText) while drawing: kept ones not counted.
        var typeset = 0

        var description: String {
            String(
                format: "cells made %d, configured %d; images %d (cards %d) %.1f ms; heights %d %.1f ms; "
                    + "text measured %d %.1f ms, typeset %d; list applies %d %.1f ms, reloads %d; hover areas %d; checks %d",
                made, configured, images, cardImages, imageMs, shapes, shapeMs, textMisses, textMs, typeset, applies, applyMs, reloads,
                tracking, checks
            )
        }
    }

    static var frame = FrameWork()

    static func textMeasured(since start: CFTimeInterval) {
        frame.textMisses += 1
        frame.textMs += since(start)
    }

    /// Milliseconds since `start` (CACurrentMediaTime), in the measurement
    /// mode only; 0 otherwise.
    static func since(_ start: CFTimeInterval) -> Double {
        (CACurrentMediaTime() - start) * 1000
    }

    static func row() {
        if PerfMode.enabled { rows += 1 }
    }
}

/// Avatars from files only: the measurement data uses file:// URLs and the
/// mode never reaches the network.
final class FileImageLoader: ImageLoading {
    func load(_ url: URL) async throws -> Data {
        guard url.isFileURL else { throw URLError(.unsupportedURL) }
        let data = try Data(contentsOf: url)
        guard NSImage(data: data) != nil else { throw URLError(.cannotDecodeContentData) }
        return data
    }
}

/// The end of the main run loop's last busy period, for the watchdog
/// thread (a plain value: a torn read only delays a report).
nonisolated(unsafe) private var lastPeriodEnd = CFAbsoluteTimeGetCurrent()

/// The busy periods of the main run loop.
@MainActor
final class MainLoopProbe {
    private var start: CFAbsoluteTime?
    private var startCPU: UInt64 = 0
    private var observers: [CFRunLoopObserver] = []
    /// Called at the end of each busy period with its start and end.
    var onPeriod: ((CFAbsoluteTime, CFAbsoluteTime) -> Void)?
    /// The main thread's CPU time over the last busy period, in ms.
    private(set) var lastCPU = 0.0

    /// Reports on the standard error while the main thread has not gone
    /// to sleep for more than 2 seconds.
    func startWatchdog() {
        let thread = Thread {
            var reported = 0.0
            while true {
                Thread.sleep(forTimeInterval: 1)
                let busy = CFAbsoluteTimeGetCurrent() - lastPeriodEnd
                if busy > 2, busy - reported >= 5 || reported == 0 {
                    reported = busy
                    FileHandle.standardError.write(Data("perf: the main thread has been busy for \(Int(busy)) s\n".utf8))
                } else if busy <= 2 {
                    reported = 0
                }
            }
        }
        thread.start()
    }

    func install() {
        let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.start = CFAbsoluteTimeGetCurrent()
                self?.startCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                PerfCounters.frame = PerfCounters.FrameWork()
            }
        }
        let sleeps = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let end = CFAbsoluteTimeGetCurrent()
                lastPeriodEnd = end
                let begin = self.start ?? end
                self.lastCPU = self.start == nil ? 0 : Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - self.startCPU) / 1e6
                self.start = nil
                self.onPeriod?(begin, end)
            }
        }
        for observer in [woke, sleeps].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }
}

struct PerfStats: Codable {
    var name: String
    var count: Int
    /// Milliseconds.
    var max: Double
    var median: Double
    /// Frames over 16 ms (scroll passes), or operations over 100 ms.
    var over: Int
    /// Operations: the longest busy period in the second after the input.
    var afterMax: Double?
    /// Selection: card and row bodies computed per operation (max).
    var cardBodies: Int?
    var rowBodies: Int?
    /// Scroll passes: the main thread's busy time over the pass, in ms.
    var busyTotal: Double?
    /// Operations: the main thread's CPU time from the input to its frame
    /// (max and median), in ms. Unlike the wall time, it does not depend on
    /// whether the window is on a display that draws.
    var cpuMax: Double?
    var cpuMedian: Double?

    static func of(_ name: String, _ values: [Double], limit: Double) -> PerfStats {
        let sorted = values.sorted()
        return PerfStats(
            name: name, count: values.count, max: sorted.last ?? 0,
            median: sorted.isEmpty ? 0 : sorted[sorted.count / 2], over: values.filter { $0 > limit }.count
        )
    }
}

/// The scenarios, version-specific steps given by the caller.
@MainActor
final class PerfRunner: NSObject {
    struct Steps {
        /// ⌘-click a card (0.5). nil: not in this version.
        var toggle: ((SurfaceListModel, String) -> Void)?
        /// A drag hovering in the list's bottom band (0.5's automatic
        /// scroll): start, and the end. nil: not in this version.
        var autoScroll: ((SurfaceListModel, NSScrollView) -> Void)?
        var stopAutoScroll: ((SurfaceListModel) -> Void)?
        /// Before measuring: the version's view switches.
        var prepare: ((AccountViewModel) -> Void)?
        /// Whether a card's heading is in view (a click selects only what
        /// is in view). nil: the version cannot tell; the first cards are
        /// used.
        var inView: ((SurfaceListModel, String) -> Bool)?
        /// What the list has laid out, for the profile log.
        var describe: ((SurfaceListModel) -> String)?
    }

    private let app: AppModel
    private let surfaces: SurfaceController
    private let steps: Steps
    private let probe = MainLoopProbe()
    private let signposter = OSSignposter(subsystem: "shiibar.gh.perf", category: .pointsOfInterest)
    private var periods: [(CFAbsoluteTime, CFAbsoluteTime)] = []
    /// The main thread's CPU time at the end of each period, by its end.
    private var periodCPU: [CFAbsoluteTime: UInt64] = [:]
    private var recording = false
    private var results: [PerfStats] = []
    private var notes: [String] = []
    private var tick: (() -> Void)?
    /// During a scroll pass: what ran in each busy period over 12 ms.
    private var attributing = false
    private var slowFrames: [String] = []

    /// Stops the daemon (`shutdown` on its socket) and ends the process,
    /// without the app's own Quit, which waits for a reply to
    /// `applicationShouldTerminate` that never came in this mode.
    var quit: () -> Void = {
        if let root = PerfMode.stateRoot,
           let socket = try? UnixSocket.connect(path: StateDirectory.socket(root: root), timeout: 2) {
            try? socket.write(Data("{\"cmd\":\"shutdown\"}\n".utf8))
            _ = try? socket.readLine()
            socket.close()
        }
        exit(0)
    }

    init(app: AppModel, surfaces: SurfaceController, steps: Steps) {
        self.app = app
        self.surfaces = surfaces
        self.steps = steps
        super.init()
        probe.onPeriod = { [weak self] start, end in
            guard let self, self.recording else { return }
            self.periods.append((start, end))
            self.periodCPU[end] = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let ms = (end - start) * 1000
            if self.attributing, ms > 12 {
                self.slowFrames.append(String(
                    format: "%.1f ms (main thread CPU %.1f ms): %@", ms, self.probe.lastCPU, PerfCounters.frame.description
                ))
            }
        }
    }

    func start() {
        probe.install()
        probe.startWatchdog()
        Task { await run() }
    }

    /// Progress on the standard error, at once.
    private func log(_ text: String) {
        FileHandle.standardError.write(Data(("perf: " + text + "\n").utf8))
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func waitFor(_ what: String, timeout: Double = 30, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                notes.append("timed out waiting for \(what)")
                log("timed out waiting for \(what)")
                return false
            }
            await pause(0.05)
        }
        return true
    }

    private func run() async {
        guard await waitFor("the account", { !app.accounts.isEmpty }), let account = app.accounts.first else { return finish() }
        // Group by Repository, Then by None, every "+ N more PRs" expanded:
        // the keys come from the daemon's list before the window opens.
        app.store.setOptions(ListOptions(groupBy: .repository, thenBy: .none), account: account.id)
        app.store.setLastTab(.all, account: account.id, surface: .window)
        app.store.setWindowFrame(NSStringFromRect(NSRect(x: 120, y: 80, width: 460, height: 760)), account: account.id)
        if let cards = try? await app.api.list(.app(account.login)) {
            var keys: Set<String> = []
            for tab in ListTab.allCases {
                for section in Listing.sections(
                    tab: tab, cards: cards, account: account, options: ListOptions(), orders: [:],
                    repositories: Listing.knownRepositories([], cards: cards),
                    folding: .init(visibility: Visibility(filter: ListFilter(muted: .show), kept: []))
                ) {
                    keys.insert(section.key)
                }
            }
            app.store.setExpanded(keys, account: account.id)
        }
        let data = app.viewModel(account.id)
        steps.prepare?(data)
        // `SHIIBAR_GH_PERF_MUTED=off` measures with the Filter's Muted at
        // Hide; Show (the condition of DESIGN.md, "Speed of operation": the
        // rest at the defaults, `Filter` closed) otherwise.
        let muted = ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_MUTED"] != "off"
        for tab in ListTab.allCases { data.setFilter(ListFilter(muted: muted ? .show : .hide), tab: tab) }
        data.setFilterOpen(false)
        // `SHIIBAR_GH_PERF_SURFACE=popover` measures the popover instead of
        // the window.
        let popover = ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_SURFACE"] == "popover"
        let surface: Surface = popover ? .popover : .window
        app.store.setLastTab(.all, account: account.id, surface: surface)
        if popover {
            surfaces.showPopoverForMeasurement(account: account.id)
        } else {
            surfaces.openWindow(account: account.id)
        }
        // The surface reads its list when it gets the focus; macOS may keep
        // the focus with the app in front, so the run opens it as focused.
        if !app.isOpen(surface, account: account.id) { app.surfaceOpened(surface, account: account.id) }
        let list = data.list(surface)
        guard await waitFor("the list", timeout: 1800, { data.loaded }) else { return finish() }
        if popover, surfaces.popoverWindow == nil { surfaces.showPopoverForMeasurement(account: account.id) }
        guard let window = popover ? surfaces.popoverWindow : surfaces.window(account: account.id) else {
            notes.append("the \(popover ? "popover" : "window") did not open")
            return finish()
        }
        if ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_HIDDEN"] == "1" {
            // Drawn but not seen (the checks need no one to look).
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        notes.append("surface: \(popover ? "popover" : "window"), Filter Muted \(muted ? "Show" : "Hide")")
        measuredWindow = window
        await pause(1.5)
        log("window open; \(steps.describe?(list) ?? "")")
        if ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_OBSERVERS"] == "1" {
            // The main run loop's observers in the default mode, with their
            // order and callout: where the list applies its changes
            // (ListTable.swift) relative to Core Animation's commit.
            let text = String(describing: CFCopyDescription(CFRunLoopGetMain()))
            let mode = text.components(separatedBy: "CFRunLoopMode").first { $0.contains("kCFRunLoopDefaultMode") } ?? ""
            for line in mode.components(separatedBy: "\n") where line.contains("CFRunLoopObserver") {
                log("observer: " + line.trimmingCharacters(in: .whitespaces).prefix(300))
            }
        }
        notes.append(
            "cards: \(Listing.cards(data.cards, tab: .all).count), window \(Int(window.frame.width))x\(Int(window.frame.height)), "
                + "visible on screen: \(window.occlusionState.contains(.visible))"
        )

        // `SHIIBAR_GH_PERF_FRAMES=1` checks that the list stays between the
        // header and the key hints at several sizes and states, and quits.
        if ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_FRAMES"] == "1" {
            await checkFrames(list: list, window: window, resizable: !popover)
            return finish()
        }
        // `SHIIBAR_GH_PERF_SNAPSHOT=<directory>` draws the window's content
        // into PNG files there (All, Review, a selection, two selected cards), to look
        // at the list without a display, and quits.
        if let directory = ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_SNAPSHOT"] {
            await snapshots(list: list, window: window, directory: directory)
            return finish()
        }
        // `SHIIBAR_GH_PERF_SCROLLCOMPARE=1` feeds the same scroll events to
        // the list and to stock scroll views in the same surface, prints how
        // far each moved, and quits.
        if ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_SCROLLCOMPARE"] == "1" {
            await compareScrolling(list: list, window: window)
            return finish()
        }
        // `SHIIBAR_GH_PERF_CONSISTENCY=<directory>` runs the drops, moves,
        // dismisses and folds of Review with the list's consistency check
        // after each (snapshots before and after go to the directory), and
        // quits.
        if let directory = ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_CONSISTENCY"] {
            await consistencyScenarios(list: list, window: window, directory: directory)
            return finish()
        }
        // `SHIIBAR_GH_PERF_PROFILE=select|toggle|tab|scroll|dismiss` repeats one operation on
        // the cards in view for a profiler (sample(1)) to watch.
        if let only = ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_PROFILE"] {
            list.openTab(.all)
            await pause(3)
            let inView = steps.inView ?? { _, _ in true }
            let cards = shownCards(list).map(\.0).filter { inView(list, $0.id) }.prefix(10)
            log("profile \(only): \(cards.count) cards in view of \(shownCards(list).count); \(steps.describe?(list) ?? "")")
            log("card bodies so far \(PerfCounters.cards); window on screen \(window.occlusionState.contains(.visible))")
            for i in 0..<300 {
                guard !cards.isEmpty else { break }
                let card = Array(cards)[i % cards.count]
                switch only {
                case "toggle": steps.toggle?(list, card.id)
                case "tab": list.openTab(i % 2 == 0 ? .review : .all)
                case "dismiss":
                    if let (next, _) = shownCards(list).first(where: { !$0.0.isDismissed }) { list.perform(.dismiss(card: next.id)) }
                case "scroll":
                    if let scroll = listScrollView(in: window) {
                        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                        scrollTo(scroll, y: CGFloat(i * 50).truncatingRemainder(dividingBy: max(1, maxY)))
                    }
                default: list.select(.header(card: card.id))
                }
                await pause(0.03)
            }
            log("profile done; cards drawn \(PerfCounters.cards), cards configured \(PerfCounters.rows), cells made \(PerfCounters.made)")
            return finish()
        }
        for tab in [ListTab.all, .review] {
            list.openTab(tab)
            await pause(1)
            guard let scroll = listScrollView(in: window) else {
                notes.append("no NSScrollView found for \(tab.title)")
                continue
            }
            notes.append("\(tab.title): scroll view \(type(of: scroll)), document \(Int(scroll.documentView?.frame.height ?? 0)) pt")
            if ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_LAYOUTTRACE"] == "1", tab == .all, let root = window.contentView {
                LayoutTrace.install(root: root)
            }
            // `SHIIBAR_GH_PERF_SKIP=scroll` leaves the passes out (to profile
            // the operations alone).
            if ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_SKIP"] != "scroll" {
                await scrollPass("\(tab.title) scroll (cold)", scroll)
                await scrollPass("\(tab.title) scroll", scroll)
            }
            scrollTo(scroll, y: 0)
            await pause(0.5)
            await operations(tab: tab, list: list, data: data, scroll: scroll)
        }
        await tabSwitches(list)
        await filterOperations(list: list, window: window)
        await compactOperations(list: list, window: window)
        finish()
    }

    // MARK: Frames

    private func checkFrames(list: SurfaceListModel, window: NSWindow, resizable: Bool) async {
        var checked = 0
        var failed = 0
        func check(_ label: String) async {
            await pause(0.6)
            guard let root = window.contentView as? SurfaceRoot else {
                log("frames \(label): no surface root")
                failed += 1
                return
            }
            let (listFrame, anchor, header, hints) = root.frames
            checked += 1
            var problems: [String] = []
            if let listFrame {
                if let header, listFrame.minY < header.maxY - 0.5 { problems.append("over the header") }
                if let hints, listFrame.maxY > hints.minY + 0.5 { problems.append("over the key hints") }
                if !root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(listFrame) { problems.append("outside the surface") }
                // Horizontally: the list's edges are its placeholder's.
                if let anchor, abs(listFrame.minX - anchor.minX) > 1 || abs(listFrame.maxX - anchor.maxX) > 1 {
                    problems.append("left or right edge off its place")
                }
                // The cards' margins left and right are the same (an
                // indented card's left margin is 12 points more).
                for (card, indented) in root.cardFrames {
                    let left = card.minX - listFrame.minX - (indented ? 12 : 0)
                    let right = listFrame.maxX - card.maxX
                    if abs(left - right) > 1 || card.maxX > listFrame.maxX {
                        problems.append(String(format: "card margins %.1f left, %.1f right", left, right))
                        break
                    }
                }
            } else {
                problems.append("no list")
            }
            if problems.isEmpty {
                log("frames \(label): ok, list \(listFrame.map { NSStringFromRect($0) } ?? "-"), hints \(hints.map { NSStringFromRect($0) } ?? "-")")
            } else {
                failed += 1
                log("frames \(label): FAIL \(problems.joined(separator: ", ")); list \(listFrame.map { NSStringFromRect($0) } ?? "-"), "
                    + "header \(header.map { NSStringFromRect($0) } ?? "-"), hints \(hints.map { NSStringFromRect($0) } ?? "-")")
            }
        }
        // The popover: its heights from the smallest to the most the
        // screen allows (dragging its bottom edge), the width fixed.
        let sizes: [NSSize] = resizable
            ? [NSSize(width: 300, height: 300), NSSize(width: 340, height: 520), NSSize(width: 460, height: 760), NSSize(width: 700, height: 900)]
            : [300, 520, 5000].map { NSSize(width: window.frame.width, height: $0) }
        for size in sizes {
            if resizable {
                var frame = window.frame
                frame.origin.y += frame.height - size.height
                frame.size = size
                window.setFrame(frame, display: true)
            } else {
                let height = surfaces.resizePopover(to: size.height)
                log("popover height \(Int(height))")
            }
            let tag = "\(Int(size.width))x\(Int(resizable ? size.height : window.frame.height))"
            for tab in [ListTab.all, .review, .mine] {
                list.openTab(tab)
                await check("\(tag) \(tab.title)")
            }
            list.openTab(.review)
            if let card = shownCards(list).first?.0 {
                list.select(.header(card: card.id))
                await check("\(tag) selected")
                if let other = shownCards(list).dropFirst().first?.0 {
                    steps.toggle?(list, other.id)
                    await check("\(tag) two cards selected")
                }
            }
            list.toggleCompact()
            await check("\(tag) Compact")
            list.toggleCompact()
            list.openDismissedList()
            await check("\(tag) Dismissed")
            list.closeDismissedList()
        }
        if let directory = ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_SNAPSHOT"] {
            list.openTab(.all)
            await pause(0.8)
            snapshot(window, directory + "/frames-\(resizable ? "window" : "popover").png")
        }
        log("frames: \(checked - failed) of \(checked) ok")
        notes.append("frames: \(checked - failed) of \(checked) ok")
        if resizable { await checkDragMap(list: list, window: window) }
        await checkPositions(list: list, window: window, popover: !resizable)
    }

    // MARK: Moving the window

    /// What a press at each point of the window's header does: a map of
    /// the hit views (the window's frame view hit-tested, as AppKit does
    /// for a mouse-down), in several states. `W` is our drag area (moves
    /// the window), `h` the SwiftUI content (its buttons and texts), `t`
    /// the title bar (moves the window), `b` a title bar button, `.`
    /// anything else. Rows are 4 points apart, columns 8.
    private func checkDragMap(list: SurfaceListModel, window: NSWindow) async {
        guard let root = window.contentView as? SurfaceRoot, let frameView = root.superview else { return }
        let drag = CardDragController.of(list)
        func map(_ state: String) async {
            await pause(0.6)
            guard let header = root.frames.header else { return }
            var moves = 0
            var points = 0
            var others: [String: Int] = [:]
            var kinds: [String: Int] = [:]
            var firstMouse = 0
            var rows: [String] = []
            for y in stride(from: CGFloat(1), to: header.maxY, by: 4) {
                var row = ""
                for x in stride(from: CGFloat(4), to: root.bounds.width - 2, by: 8) {
                    // Root coordinates are flipped (y down); the frame view's
                    // hit test takes its superview's coordinates.
                    let inWindow = root.convert(NSPoint(x: x, y: y), to: nil)
                    let point = frameView.superview.map { $0.convert(inWindow, from: nil) } ?? inWindow
                    let hit = frameView.hitTest(point)
                    let movesWindow = hit is WindowDragView || hit?.mouseDownCanMoveWindow == true
                    let control = hit is NSControl || String(describing: type(of: hit as Any)).contains("Button")
                        || hit.map { String(describing: type(of: $0)) }?.contains("Platform") == true
                    points += 1
                    if (hit is WindowDragView && hit?.acceptsFirstMouse(for: nil) == true) || hit.map(NSThemeFrameProbe.isTitleBar) == true {
                        firstMouse += 1
                    }
                    kinds[hit.map { String(describing: type(of: $0)) + ($0.mouseDownCanMoveWindow ? "(moves)" : "") } ?? "nil", default: 0] += 1
                    if hit is WindowDragView {
                        moves += 1
                        row += "W"
                    } else if hit.map({ String(describing: type(of: $0)).hasPrefix("NSHostingView") }) == true {
                        if movesWindow { moves += 1 }
                        row += "h"
                    } else if movesWindow {
                        moves += 1
                        row += "t"
                    } else if control {
                        row += "b"
                    } else {
                        row += "."
                        others[hit.map { String(describing: type(of: $0)) } ?? "nil", default: 0] += 1
                    }
                }
                rows.append(row)
            }
            let titlebar = window.frame.height - window.contentLayoutRect.height
            log("drag map, \(state): key \(window.isKeyWindow), app active \(NSApp.isActive), level \(window.level.rawValue); "
                + "\(firstMouse) points move the window on a first press; title bar \(Int(titlebar)) pt, header \(Int(header.maxY)) pt; \(moves) of \(points) header points move the window; neither: \(others); hit views: \(kinds)")
            for row in rows { log("  " + row) }
            notes.append("drag map \(state): \(moves) of \(points) move the window, \(firstMouse) on a first press; drag monitor left: \(drag.monitorInstalled)")
        }
        list.openTab(.review)
        await map("Review")
        list.openDismissedList()
        await map("Dismissed list")
        list.closeDismissedList()
        list.toggleCompact()
        await map("Compact")
        list.toggleCompact()
        // A card drag that ended, and one that was cancelled.
        if let card = shownCards(list).first(where: { $0.1.accepts && $0.0.canDrag })?.0, let start = drag.beginForMeasurement(card: card.id) {
            drag.endForMeasurement(at: drag.pointForMeasurement(.card(card.id, lowerHalf: false)) ?? start)
            await map("after a drag")
        }
        if let card = shownCards(list).first(where: { $0.1.accepts && $0.0.canDrag })?.0, drag.beginForMeasurement(card: card.id) != nil {
            drag.cancelForMeasurement()
            await map("after a cancelled drag")
        }
        // A tooltip waiting to show.
        QuickTip.schedule("Copy link", owner: QuickTip.Owner(), appearance: nil)
        await map("tooltip pending")
        QuickTip.cancel()
        // The Grouping sheet shown and closed.
        list.showsGrouping = true
        await pause(0.3)
        list.showsGrouping = false
        await map("after the Grouping sheet")
        // Keep on top off and on (the window's level).
        list.data.toggleKeepOnTop()
        await map("Keep on top off")
        list.data.toggleKeepOnTop()
        await map("Keep on top on")
        // Another window of the app has the focus (as Settings takes it).
        let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        await map("another window of the app in front")
        other.close()
        // The popover of the same account opened and closed.
        if let account = app.accounts.first {
            surfaces.showPopoverForMeasurement(account: account.id)
            await pause(0.5)
            surfaces.closePopover()
            window.makeKeyAndOrderFront(nil)
            await map("after the popover")
        }
        // The app not active.
        NSApp.deactivate()
        await map("app not active")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Each tab and the Dismissed list keep their own scroll position while
    /// the surface is open; a tab shown first starts at the top; after the
    /// surface closes, every tab starts at the top (DESIGN.md, "Scroll
    /// position").
    private func checkPositions(list: SurfaceListModel, window: NSWindow, popover: Bool) async {
        var checked = 0
        var failed = 0
        func y(_ window: NSWindow?) -> CGFloat {
            window.flatMap { listScrollView(in: $0) }?.contentView.bounds.origin.y ?? -1
        }
        func expect(_ label: String, _ window: NSWindow?, _ wanted: CGFloat) async {
            await pause(0.5)
            checked += 1
            let got = y(window)
            if abs(got - wanted) > 0.5 {
                failed += 1
                log("positions \(label): FAIL at \(got), expected \(wanted)")
            } else {
                log("positions \(label): ok at \(got)")
            }
        }
        func scroll(_ window: NSWindow, _ y: CGFloat) async {
            if let view = listScrollView(in: window) { scrollTo(view, y: y) }
            await pause(0.3)
        }
        // From a surface just opened: every tab not shown yet.
        guard let account = app.accounts.first else { return }
        list.clearSelection()
        var window = window
        func reopen() async -> NSWindow? {
            if popover {
                surfaces.closePopover()
                await pause(0.8)
                surfaces.showPopoverForMeasurement(account: account.id)
                await pause(1.0)
                return surfaces.popoverWindow
            }
            window.performClose(nil)
            await pause(0.8)
            surfaces.openWindow(account: account.id)
            await pause(1.0)
            return surfaces.window(account: account.id)
        }
        list.openTab(.all)
        guard let fresh = await reopen() else { return }
        window = fresh
        await expect("All after opening", window, 0)
        await scroll(window, 1500)
        list.openTab(.review)
        await expect("Review after All scrolled", window, 0)
        await scroll(window, 600)
        list.openTab(.mine)
        await expect("Mine", window, 0)
        list.openTab(.all)
        await expect("back to All", window, 1500)
        list.openTab(.review)
        await expect("back to Review", window, 600)
        // Enough dismissed cards for the Dismissed list to scroll.
        for (card, _) in shownCards(list).prefix(8) { list.perform(.dismiss(card: card.id)) }
        await pause(1.0)
        list.openDismissedList()
        await expect("Dismissed", window, 0)
        // The Dismissed list may be short: where it could go.
        var target: CGFloat = 0
        if let view = listScrollView(in: window) {
            let maxY = (view.documentView?.frame.height ?? 0) - view.contentView.bounds.height
            target = max(0, min(100, maxY))
            log("positions: the Dismissed list scrolls \(Int(maxY)) points")
        }
        await scroll(window, target)
        let dismissedY = y(window)
        list.closeDismissedList()
        await expect("Review after Dismissed", window, 600)
        list.openDismissedList()
        await expect("Dismissed again (at \(Int(dismissedY)))", window, dismissedY)
        list.closeDismissedList()
        // Closed and opened again: every tab at the top.
        let reopened = await reopen()
        let tab = list.tab
        await expect("\(tab.title) after reopening", reopened, 0)
        list.openTab(tab == .all ? .review : .all)
        await expect("another tab after reopening", reopened, 0)
        log("positions: \(checked - failed) of \(checked) ok")
        notes.append("positions: \(checked - failed) of \(checked) ok")
    }

    // MARK: Scroll distance

    /// The same synthetic scroll events (made with CGEvent, never posted to
    /// the system: `scrollWheel(with:)` is called on the view under the
    /// list's middle, as the window would) given to the list and to two
    /// stock scroll views of the same size in the same surface: one with a
    /// plain tall document view, one with a plain NSTableView. Prints how
    /// far each moved.
    private func compareScrolling(list: SurfaceListModel, window: NSWindow) async {
        list.openTab(.all)
        await pause(1)
        guard let ours = listScrollView(in: window), let root = window.contentView else { return }
        let frame = ours.convert(ours.bounds, to: root)
        let plain = NSScrollView(frame: frame)
        let document = PerfFlippedView(frame: NSRect(x: 0, y: 0, width: frame.width, height: 40000))
        plain.documentView = document
        plain.hasVerticalScroller = true
        let stockTable = NSScrollView(frame: frame)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: frame.width, height: 100))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        table.headerView = nil
        let source = PerfTableSource()
        table.dataSource = source
        table.delegate = source
        stockTable.documentView = table
        stockTable.hasVerticalScroller = true
        let targets: [(String, NSScrollView)] = [("ours", ours), ("stock plain", plain), ("stock table", stockTable)]
        func event(units: CGScrollEventUnit, delta: Int32, continuous: Bool, phase: Int64, momentum: Int64, at view: NSView) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return nil }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            // The view's middle on the screen, in CG's top-left coordinates.
            let inWindow = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let screen = window.convertPoint(toScreen: inWindow)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            cg.location = CGPoint(x: screen.x, y: top - screen.y)
            return NSEvent(cgEvent: cg)
        }
        struct Gesture {
            var name: String
            var events: [(units: CGScrollEventUnit, delta: Int32, continuous: Bool, phase: Int64, momentum: Int64)]
        }
        let wheel = Gesture(name: "mouse wheel, 5 notches", events: Array(repeating: (.line, -1, false, 0, 0), count: 5))
        var precise: [(units: CGScrollEventUnit, delta: Int32, continuous: Bool, phase: Int64, momentum: Int64)] = [(.pixel, -20, true, 1, 0)]
        precise += Array(repeating: (.pixel, -20, true, 2, 0), count: 10)
        precise += [(.pixel, 0, true, 4, 0)]
        let unphased = Gesture(name: "precise without phases, 12 events of 20 pt", events: Array(repeating: (.pixel, -20, true, 0, 0), count: 12))
        var flick = Gesture(name: "trackpad flick, 12 events of 20 pt then momentum", events: precise)
        flick.events += [(.pixel, -30, true, 0, 1)] + Array(repeating: (.pixel, -20, true, 0, 2), count: 15) + [(.pixel, 0, true, 0, 3)]
        // A gesture with phases (began, changed, ended, then momentum) is
        // tracked by AppKit from the real event stream: given this way, only
        // its first event moves any of the three (the same 20 points), the
        // rest are ignored, and a second phased gesture to the same view
        // gives results that change from run to run (0 or 20 points, for
        // the stock table too). So it goes first, once.
        for gesture in [flick, wheel, unphased] {
            var line: [String] = []
            for (name, scroll) in targets {
                if scroll !== ours { root.addSubview(scroll) }
                scrollTo(scroll, y: 2000)
                await pause(0.3)
                let before = scroll.contentView.bounds.origin.y
                let target = scroll.contentView
                let middle = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
                let hit = root.hitTest(root.convert(middle, from: nil)) ?? scroll
                for spec in gesture.events {
                    if let e = event(units: spec.units, delta: spec.delta, continuous: spec.continuous, phase: spec.phase, momentum: spec.momentum, at: scroll) {
                        hit.scrollWheel(with: e)
                    }
                    await pause(1.0 / 60)
                }
                await pause(1.0)
                let moved = scroll.contentView.bounds.origin.y - before
                line.append(String(format: "%@ %.1f pt (event to %@)", name, moved, "\(type(of: hit))"))
                if scroll !== ours { scroll.removeFromSuperview() }
            }
            let text = "scroll \(gesture.name): " + line.joined(separator: "; ")
            log(text)
            notes.append(text)
        }
        let responsive = "responsive scrolling compatible: ListTableView \(ListTableView.isCompatibleWithResponsiveScrolling), "
            + "NSTableView \(NSTableView.isCompatibleWithResponsiveScrolling), NSClipView \(NSClipView.isCompatibleWithResponsiveScrolling), "
            + "NSScrollView \(NSScrollView.isCompatibleWithResponsiveScrolling); line scroll ours \(ours.verticalLineScroll), "
            + "stock \(plain.verticalLineScroll), page ours \(ours.verticalPageScroll), stock \(plain.verticalPageScroll)"
        log(responsive)
        notes.append(responsive)
        withExtendedLifetime(source) {}
    }

    // MARK: Consistency

    /// The list's table of the surface being measured.
    private weak var measuredWindow: NSWindow?
    private var consistencyFailures = 0
    private var consistencyChecks = 0

    private func tableController(_ window: NSWindow?) -> ListTableController? {
        guard let window, let scroll = listScrollView(in: window) else { return nil }
        return (scroll.documentView as? NSTableView)?.dataSource as? ListTableController
    }

    /// The list's consistency check (ListTableController): logs and notes
    /// what is wrong. Returns whether all was well.
    @discardableResult
    private func checkList(_ label: String) -> Bool {
        guard let controller = tableController(measuredWindow) else { return true }
        consistencyChecks += 1
        PerfCounters.frame.checks += 1
        let problems = controller.consistencyProblems()
        guard !problems.isEmpty else { return true }
        consistencyFailures += 1
        log("list check after \(label): FAIL\n  " + problems.prefix(10).joined(separator: "\n  "))
        notes.append("list check after \(label): FAIL \(problems.first ?? "")")
        return false
    }

    private func consistencyScenarios(list: SurfaceListModel, window: NSWindow, directory: String) async {
        var step = 0
        func review(_ section: PlacementSection) -> SectionLayout? {
            list.sections.first { $0.key == SectionKey.placed(.review, section) }
        }
        func cards(_ section: PlacementSection) -> [Card] {
            review(section)?.cards ?? []
        }
        /// Every section folded back to five cards, nothing collapsed.
        func fold() async {
            for section in list.sections where section.showLess { list.perform(.toggleMore(section.key)) }
            for section in list.sections where section.collapsed { list.perform(.toggleSection(section.key)) }
            await pause(0.8)
        }
        func run(_ name: String, _ body: () -> Void) async {
            step += 1
            let tag = String(format: "%02d", step)
            snapshot(window, directory + "/\(tag)-before.png")
            body()
            await pause(1.2)
            let ok = checkList(name)
            snapshot(window, directory + "/\(tag)-after.png")
            log("consistency \(tag) \(name): \(ok ? "ok" : "FAIL")")
        }
        func drag(_ ids: [String], onto zone: DropZone) {
            guard let first = ids.first else { return }
            if ids.count > 1 {
                list.select(.header(card: first))
                for id in ids.dropFirst() { list.click(card: id, extent: .toggle) }
            } else {
                list.select(.header(card: first))
            }
            list.beginDrag(first)
            list.dragOver(zone)
            list.drop(zone)
        }
        let scroll = listScrollView(in: window)
        // Drags as the pointer makes them (CardDragController), moving at
        // 60 Hz: through the views' drop zones, resting on a "+ N more PRs"
        // on the way, the list scrolled near its edges.
        let pointer = CardDragController.of(list)
        func pointerDrag(_ name: String, card: String, via: DropZone?, to target: DropZone) async {
            guard let start = pointer.beginForMeasurement(card: card) else {
                log("consistency \(name): the card is not in view")
                return
            }
            var point = start
            func glide(to end: NSPoint) async {
                let steps = 15
                let from = point
                for i in 1...steps {
                    point = NSPoint(x: from.x + (end.x - from.x) * CGFloat(i) / CGFloat(steps),
                                    y: from.y + (end.y - from.y) * CGFloat(i) / CGFloat(steps))
                    pointer.moveForMeasurement(to: point)
                    await pause(1.0 / 60)
                }
            }
            /// Moves to the zone, holding the pointer in the bottom band
            /// until the list has scrolled it into view.
            func reach(_ zone: DropZone) async -> Bool {
                for _ in 0..<400 {
                    if let target = pointer.pointForMeasurement(zone) {
                        await glide(to: target)
                        if let again = pointer.pointForMeasurement(zone) {
                            point = again
                            pointer.moveForMeasurement(to: again)
                            return true
                        }
                    }
                    guard let visible = pointer.visibleForMeasurement else { return false }
                    // Window coordinates go up: the bottom band is near minY.
                    let band = NSPoint(x: visible.midX, y: visible.minY + 6)
                    if point != band { await glide(to: band) }
                    await pause(1.0 / 60)
                }
                return false
            }
            if let via {
                if await reach(via) { await pause(1.0) }
            }
            let reached = await reach(target)
            if !reached { log("consistency \(name): could not reach the target") }
            pointer.endForMeasurement(at: point)
        }
        do {
            list.openTab(.review)
            await fold()
            if let scroll { scrollTo(scroll, y: 0) }
            await pause(0.4)
            let done = SectionKey.placed(.review, .done)
            let todo = SectionKey.placed(.review, .todo)
            if let card = cards(.doing).first {
                snapshot(window, directory + "/p1-before.png")
                await pointerDrag("Doing → Done", card: card.id, via: .more(todo), to: .header(done))
                await pause(1.2)
                let ok = checkList("pointer drag Doing → Done")
                snapshot(window, directory + "/p1-after.png")
                log("consistency pointer Doing → Done: \(ok ? "ok" : "FAIL")")
            }
            await fold()
            if let scroll { scrollTo(scroll, y: 0) }
            await pause(0.4)
            if let card = cards(.doing).first {
                snapshot(window, directory + "/p2-before.png")
                await pointerDrag("Doing → Done", card: card.id, via: nil, to: .header(done))
                await pause(1.2)
                let ok = checkList("pointer drag Doing → Done, straight")
                snapshot(window, directory + "/p2-after.png")
                log("consistency pointer Doing → Done straight: \(ok ? "ok" : "FAIL")")
            }
            await fold()
            if let scroll { scrollTo(scroll, y: 0) }
            await pause(0.4)
            tableController(window)?.scrollForMeasurement(toLine: "section:" + todo, offset: -20)
            await pause(0.4)
            if let card = cards(.todo).first {
                snapshot(window, directory + "/p3-before.png")
                await pointerDrag("Todo → Done", card: card.id, via: nil, to: .header(done))
                await pause(1.2)
                let ok = checkList("pointer drag Todo → Done")
                snapshot(window, directory + "/p3-after.png")
                log("consistency pointer Todo → Done: \(ok ? "ok" : "FAIL")")
            }
        }
        for pass in ["top", "scrolled", "compact"] {
            if (pass == "compact") != list.compact { list.toggleCompact() }
            list.openTab(.review)
            await fold()
            func place() async {
                guard let scroll else { return }
                scrollTo(scroll, y: 0)
                if pass != "top" {
                    // Todo's heading in the middle of the list.
                    tableController(window)?.scrollForMeasurement(toLine: "section:" + SectionKey.placed(.review, .todo), offset: -120)
                }
                await pause(0.4)
            }
            let done = SectionKey.placed(.review, .done)
            let todo = SectionKey.placed(.review, .todo)
            let waiting = SectionKey.placed(.review, .waiting)
            await place()
            if let card = cards(.doing).first {
                await run("\(pass): Doing → Done heading") { drag([card.id], onto: .header(done)) }
            }
            await place()
            if let card = cards(.doing).first, let over = cards(.done).first {
                await run("\(pass): Doing → Done card") { drag([card.id], onto: .card(over.id, lowerHalf: false)) }
            }
            await place()
            if let card = cards(.todo).first {
                await run("\(pass): Todo → Done heading") { drag([card.id], onto: .header(done)) }
            }
            await place()
            if let card = cards(.done).first, let over = cards(.doing).first {
                await run("\(pass): Done → Doing card") { drag([card.id], onto: .card(over.id, lowerHalf: true)) }
            }
            await place()
            let two = cards(.todo).prefix(2).map(\.id)
            if two.count == 2 {
                await run("\(pass): two Todo cards → Done") { drag(two, onto: .header(done)) }
            }
            await place()
            let pair = cards(.doing).prefix(2).map(\.id)
            if pair.count == 2 {
                await run("\(pass): two Doing cards → Waiting") { drag(pair, onto: .header(waiting)) }
            }
            await place()
            if let card = cards(.doing).first, review(.todo)?.more ?? 0 > 0 {
                await run("\(pass): Doing → Todo's + N more") { drag([card.id], onto: .more(todo)) }
            }
            await fold()
            await place()
            if let card = cards(.waiting).first, review(.done)?.more ?? 0 > 0 {
                await run("\(pass): Waiting → Done's + N more") { drag([card.id], onto: .more(done)) }
            }
            await place()
            if let card = cards(.todo).dropFirst().first {
                await run("\(pass): Dismiss in Todo") {
                    list.select(.header(card: card.id))
                    list.press(.delete)
                }
            }
            await place()
            await run("\(pass): collapse Todo") { list.perform(.toggleSection(todo)) }
            await run("\(pass): expand Todo") { list.perform(.toggleSection(todo)) }
            await run("\(pass): + N more PRs of Todo") { list.perform(.toggleMore(todo)) }
            await run("\(pass): Show less of Todo") { list.perform(.toggleMore(todo)) }
            await run("\(pass): tab All and back") {
                list.openTab(.all)
                list.openTab(.review)
            }
        }
        if list.compact { list.toggleCompact() }
        await filterScenarios(list: list, window: window, run: run)
        // All, grouped by repository: what changes which card a line shows,
        // its size or its look.
        let data = list.data
        func scrollBy(_ dy: CGFloat) {
            guard let scroll else { return }
            scrollTo(scroll, y: max(0, scroll.contentView.bounds.origin.y + dy))
        }
        list.openTab(.all)
        if let scroll { scrollTo(scroll, y: 0) }
        await pause(0.8)
        await run("All: Compact on") { list.toggleCompact() }
        await run("All Compact: scroll down") { scrollBy(1800) }
        await run("All Compact: scroll up") { scrollBy(-900) }
        await run("All: Compact off, scrolled") { list.toggleCompact() }
        await run("All: scroll down") { scrollBy(2500) }
        await run("All: Compact on, scrolled") { list.toggleCompact() }
        await run("All Compact: Group by Owner") { data.setGroupBy(.owner) }
        await run("All Compact: Group by Status") { data.setGroupBy(.status) }
        await run("All Compact: Group by Repository") { data.setGroupBy(.repository) }
        await run("All Compact: sort by added") { data.setSort(.recentlyAdded) }
        await run("All Compact: sort by updated") { data.setSort(.recentlyUpdated) }
        await run("All Compact: Filter Muted Hide") { list.setMuteChoice(.hide) }
        await run("All Compact: Filter Muted Show") { list.setMuteChoice(.show) }
        await run("All Compact: search") { list.setSearch("repo-01") }
        await run("All Compact: search cleared") { list.setSearch("") }
        await run("All Compact: the list read again") { data.reload() }
        if let card = list.shownCards.dropFirst(3).first {
            await run("All Compact: Dismiss") {
                list.select(.header(card: card))
                list.press(.delete)
            }
        }
        await run("All Compact: to Review") { list.openTab(.review) }
        await run("Review Compact: to Mine") { list.openTab(.mine) }
        await run("Mine Compact: to All") { list.openTab(.all) }
        await run("All: Compact off") { list.toggleCompact() }
        await run("All: scroll up to the top") { if let scroll { scrollTo(scroll, y: 0) } }
        await run("All: Group by Owner, Then by Repository") {
            data.setGroupBy(.owner)
            data.setThenBy(.repository)
        }
        await run("All: Group by Repository") {
            data.setThenBy(.none)
            data.setGroupBy(.repository)
        }
        log("consistency: \(consistencyChecks - consistencyFailures) of \(consistencyChecks) ok")
        notes.append("consistency: \(consistencyChecks - consistencyFailures) of \(consistencyChecks) ok")
    }

    /// The Filter (DESIGN.md, "Filter"): its settings changed in Review and
    /// All, its options opened and closed (the line at the top of the list
    /// stays), and a card read under `Unread only` that hides after its
    /// wait (the selected item stays where it is on the screen).
    private func filterScenarios(list: SurfaceListModel, window: NSWindow, run: (String, () -> Void) async -> Void) async {
        let controller = { [weak self] in self?.tableController(window) }
        let scroll = listScrollView(in: window)
        func expectSame(_ label: String, _ before: (String, CGFloat)?, _ after: (String, CGFloat)?) {
            guard let before else { return }
            if let after, after.0 == before.0, abs(after.1 - before.1) < 0.5 {
                log("consistency \(label): the line at the top stays (\(before.0))")
            } else {
                consistencyFailures += 1
                consistencyChecks += 1
                log("consistency \(label): FAIL the top line was \(before.0) at \(before.1), now \(String(describing: after))")
                notes.append("\(label): FAIL the line at the top moved")
            }
        }
        for tab in [ListTab.review, .all] {
            list.openTab(tab)
            if let scroll { scrollTo(scroll, y: 0) }
            await pause(0.6)
            let name = tab.title
            await run("\(name) Filter: Status Merged off") { list.toggleStatus(.merged) }
            await run("\(name) Filter: Status Closed off") { list.toggleStatus(.closed) }
            await run("\(name) Filter: Status Merged and Closed on") {
                list.toggleStatus(.merged)
                list.toggleStatus(.closed)
            }
            await run("\(name) Filter: Muted Only") { list.setMuteChoice(.only) }
            await run("\(name) Filter: Muted Hide") { list.setMuteChoice(.hide) }
            await run("\(name) Filter: Muted Show") { list.setMuteChoice(.show) }
            if let scroll { scrollTo(scroll, y: 900) }
            await pause(0.6)
            for step in ["open", "close"] {
                let before = controller()?.topLineForMeasurement()
                await run("\(name) Filter: \(step), scrolled") { list.toggleFilterOpen() }
                expectSame("\(name) Filter \(step)", before, controller()?.topLineForMeasurement())
            }
            list.toggleFilterOpen()
            await pause(0.6)
            if tab == .all { await checkShortSurface(list: list, window: window) }
            await run("\(name) Filter open: Status Draft off") { list.toggleStatus(.draft) }
            await run("\(name) Filter open: Status Draft on") { list.toggleStatus(.draft) }
            list.toggleFilterOpen()
            await pause(0.6)
        }
        // Unread only in Review: a card read and left hides after its wait.
        // Scrolled, so the list can keep the selected card where it is (at
        // the very top the list cannot scroll up past its start).
        list.openTab(.review)
        if let scroll { scrollTo(scroll, y: 0) }
        await pause(0.6)
        await run("Review Filter: Unread only on") { list.setUnreadOnly(true) }
        if let scroll { scrollTo(scroll, y: 600) }
        await pause(0.6)
        let shown = shownCards(list).map(\.0).filter { card in
            controller()?.offsetForMeasurement(ofLine: "card:" + card.id).map { $0 >= 0 && $0 < 700 } ?? false
        }
        if shown.count >= 3, let row = shown[1].rows.last(where: \.isBlueUnread) {
            let read = shown[1]
            let next = shown[2]
            // Its other blue rows read first (selecting a row reads it; the
            // rows past the newest three by Mark all as read's way is not
            // here: the card's own rows).
            for other in read.rows where other.isBlueUnread && other.id != row.id {
                list.select(.row(id: other.id, card: read.id))
            }
            await run("Review Unread only: its last row read, the card kept") { list.select(.row(id: row.id, card: read.id)) }
            await run("Review Unread only: the next card selected") { list.select(.header(card: next.id)) }
            let before = controller()?.offsetForMeasurement(ofLine: "card:" + next.id)
            snapshot(window, (ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_CONSISTENCY"] ?? "/tmp") + "/unread-kept.png")
            await pause(app.linger.duration - 0.15)
            snapshot(window, (ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_CONSISTENCY"] ?? "/tmp") + "/unread-fading.png")
            await run("Review Unread only: the read card hides after its wait") {}
            let after = controller()?.offsetForMeasurement(ofLine: "card:" + next.id)
            if list.lingering.isEmpty, !list.sections.contains(where: { $0.matching.contains { $0.id == read.id } }),
               let before, let after, abs(before - after) < 0.5 {
                log("consistency Unread only: \(read.pr) hid; the selected card stayed at \(before)")
            } else {
                consistencyFailures += 1
                consistencyChecks += 1
                log("consistency Unread only: FAIL kept \(list.lingering), selected card at \(String(describing: before)) then \(String(describing: after))")
                notes.append("Unread only: FAIL")
            }
            // Scrolled, nothing selected in view: the first line in view stays.
            if let scroll { scrollTo(scroll, y: 300) }
            await pause(0.6)
            let inView = shownCards(list).map(\.0).filter { card in
                controller()?.offsetForMeasurement(ofLine: "card:" + card.id).map { $0 > 40 && $0 < 400 } ?? false
            }
            if let card = inView.first(where: { $0.rows.filter(\.isBlueUnread).count <= Listing.rowsShown }) {
                for row in card.rows where row.isBlueUnread { list.select(.row(id: row.id, card: card.id)) }
                list.clearSelection()
                await pause(0.3)
                let top = controller()?.topLineForMeasurement()
                await pause(app.linger.duration)
                await run("Review Unread only: a card hides above the selection's place") {}
                expectSame("Unread only, nothing selected", top, controller()?.topLineForMeasurement())
            }
        } else {
            log("consistency Unread only: not enough unread cards in view")
        }
        await run("Review Filter: Unread only off") { list.setUnreadOnly(false) }
    }

    /// With the options open in a short window, the list keeps 100 points
    /// (at text size 12) and the options scroll inside (DESIGN.md,
    /// "Filter").
    private func checkShortSurface(list: SurfaceListModel, window: NSWindow) async {
        let frame = window.frame
        defer { window.setFrame(frame, display: true) }
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - 420, width: frame.width, height: 420), display: true)
        await pause(0.8)
        consistencyChecks += 1
        let root = window.contentView.flatMap { view -> SurfaceRoot? in
            var queue = [view]
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if let root = next as? SurfaceRoot { return root }
                queue += next.subviews
            }
            return nil
        }
        let listHeight = root?.frames.list?.height ?? 0
        let listScroll = listScrollView(in: window)
        var options: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll !== listScroll, scroll.documentView.map({ $0.frame.height > 60 }) == true {
                options = scroll
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        let inner = options.map { ($0.documentView?.frame.height ?? 0, $0.contentView.bounds.height) }
        let scrolls = inner.map { $0.0 > $0.1 + 0.5 } ?? false
        if listHeight >= 100 - 0.5, scrolls {
            log(String(format: "consistency short window: the list keeps %.0f pt; the options scroll (%.0f in %.0f)", listHeight, inner?.0 ?? 0, inner?.1 ?? 0))
        } else {
            consistencyFailures += 1
            log("consistency short window: FAIL list \(listHeight) pt, options \(String(describing: inner))")
            notes.append("short window: FAIL list \(listHeight) pt")
        }
    }

    // MARK: Snapshots

    private func snapshot(_ window: NSWindow, _ path: String) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        log("snapshot \(path)")
        // The layers as Core Animation has them (`CALayer.render(in:)`):
        // what layer contents set by the views show.
        guard let layer = view.layer, let rep2 = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep2)?.cgContext else { return }
        context.translateBy(x: 0, y: view.bounds.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        try? rep2.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-layers.png")))
    }

    private func snapshots(list: SurfaceListModel, window: NSWindow, directory: String) async {
        let dark = ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_DARK"] == "1"
        if dark { window.appearance = NSAppearance(named: .darkAqua) }
        let suffix = dark ? "-dark" : ""
        list.openTab(.all)
        await pause(1.5)
        snapshot(window, directory + "/all\(suffix).png")
        if let card = shownCards(list).first?.0, let other = shownCards(list).dropFirst().first?.0 {
            list.select(.header(card: card.id))
            steps.toggle?(list, other.id)
            await pause(0.5)
            snapshot(window, directory + "/all-selected\(suffix).png")
            list.clearSelection()
        }
        if let scroll = listScrollView(in: window) {
            scrollTo(scroll, y: 2000)
            await pause(0.8)
            snapshot(window, directory + "/all-scrolled\(suffix).png")
            scrollTo(scroll, y: 0)
        }
        // A card with a long body, shown by selecting it (the list scrolls
        // to it).
        let long = shownCards(list).lazy.compactMap { card, _ in
            card.rows.first { (RowPresentation($0, now: 0).body?.count ?? 0) > 100 }.map { (card, $0) }
        }.first
        if let (card, row) = long {
            list.select(.row(id: row.id, card: card.id))
            await pause(0.8)
            snapshot(window, directory + "/all-long-body\(suffix).png")
        }
        // A muted card (Filter Muted Show): drawn gray; its menu has Unmute.
        if let (card, _) = shownCards(list).first(where: { $0.0.isMuted }) {
            list.select(.header(card: card.id))
            await pause(0.8)
            snapshot(window, directory + "/all-muted\(suffix).png")
            let menu = list.rightClick(.header(card: card.id)).compactMap { $0?.title }
            log("menu of muted \(card.pr): \(menu.joined(separator: " | "))")
        }
        // The Filter: the summary closed, the options open in All and
        // in Review, the blue dot, Compact on.
        let saved = list.filter
        list.setMuteChoice(.hide)
        list.toggleStatus(.merged)
        list.toggleStatus(.closed)
        list.setUnreadOnly(true)
        await pause(0.8)
        snapshot(window, directory + "/filter-closed\(suffix).png")
        list.toggleFilterOpen()
        await pause(0.8)
        snapshot(window, directory + "/filter-open-all\(suffix).png")
        list.openTab(.review)
        list.setMuteChoice(.show)
        list.setUnreadOnly(true)
        await pause(0.8)
        snapshot(window, directory + "/filter-open-review\(suffix).png")
        list.toggleFilterOpen()
        list.setUnreadOnly(false)
        list.setMuteChoice(.show)
        list.toggleCompact()
        await pause(0.8)
        snapshot(window, directory + "/compact-on\(suffix).png")
        list.toggleCompact()
        list.openTab(.all)
        list.data.setFilter(saved, tab: .all)
        list.openTab(.review)
        await pause(1.5)
        snapshot(window, directory + "/review\(suffix).png")
        // A drag held over the second card: the dragged card faded, the
        // insertion line above the second.
        let movable = shownCards(list).filter { $0.1.accepts && $0.0.canDrag }.map(\.0)
        if movable.count >= 3 {
            list.beginDrag(movable[2].id)
            list.dragOver(.card(movable[1].id, lowerHalf: false))
            await pause(0.8)
            snapshot(window, directory + "/review-drag\(suffix).png")
            list.endDrag()
            await pause(0.3)
        }
        // Mine: over the upper half of its first card (no heading above it).
        list.openTab(.mine)
        await pause(1)
        if let scroll = listScrollView(in: window) { scrollTo(scroll, y: 0) }
        await pause(0.3)
        let mine = shownCards(list).filter { $0.1.accepts && $0.0.canDrag }.map(\.0)
        if mine.count >= 2 {
            list.beginDrag(mine[1].id)
            list.dragOver(.card(mine[0].id, lowerHalf: false))
            await pause(0.8)
            snapshot(window, directory + "/mine-drag-top\(suffix).png")
            list.endDrag()
            await pause(0.3)
        }
        list.openTab(.review)
        await pause(0.5)
        if let (card, _) = shownCards(list).first {
            list.perform(.dismiss(card: card.id))
            await pause(1)
        }
        list.openDismissedList()
        await pause(1)
        snapshot(window, directory + "/dismissed\(suffix).png")
        list.closeDismissedList()
    }

    // MARK: Scroll

    private func listScrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private func scrollTo(_ scroll: NSScrollView, y: CGFloat) {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// Top to bottom at 1,500 points a second, driven by the display.
    private func scrollPass(_ name: String, _ scroll: NSScrollView, speed: CGFloat = 1500) async {
        scrollTo(scroll, y: 0)
        await pause(0.5)
        log("\(name): start")
        let state = signposter.beginInterval("scroll", "\(name)")
        let drawsBefore = PerfCounters.cards
        periods = []
        slowFrames = []
        attributing = true
        recording = true
        let started = CACurrentMediaTime()
        var done = false
        var lastY: CGFloat = -1
        var stuck = 0
        tick = { [weak self] in
            guard let self else { return }
            let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            let y = min(maxY, speed * CGFloat(CACurrentMediaTime() - started))
            self.scrollTo(scroll, y: y)
            // The end: at the bottom and the height no longer growing.
            if y >= maxY { stuck += 1 } else { stuck = 0 }
            if stuck > 30 || y == lastY && y >= maxY && stuck > 5 { done = true }
            lastY = y
        }
        // A 60 Hz timer, not the display's link: the link stops while the
        // display sleeps.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        _ = await waitFor(name, timeout: 1800) { done }
        timer.invalidate()
        tick = nil
        recording = false
        attributing = false
        for frame in slowFrames.prefix(12) { log("\(name) slow frame: \(frame)") }
        signposter.endInterval("scroll", state)
        let frames = periods.map { ($0.1 - $0.0) * 1000 }
        var stats = PerfStats.of(name, frames, limit: 16)
        stats.busyTotal = frames.reduce(0, +)
        results.append(stats)
        notes.append("\(name): \(String(format: "%.1f", CACurrentMediaTime() - started)) s, \(frames.count) frames, \(PerfCounters.cards - drawsBefore) cards drawn")
        checkList(name)
        log("\(name): \(frames.count) frames, max \(String(format: "%.1f", stats.max)) ms, over 16 ms \(stats.over)")
    }

    private func step() {
        tick?()
    }

    // MARK: Operations

    /// Run `body` (the input) and wait for the frame that shows it.
    private func measure(_ name: StaticString, _ label: String, _ body: () -> Void) async -> Sample {
        periods = []
        let cards = PerfCounters.cards
        let rows = PerfCounters.rows
        recording = true
        let state = signposter.beginInterval(name, "\(label)")
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let t0 = CFAbsoluteTimeGetCurrent()
        body()
        // The end of the busy period the input ran in.
        _ = await waitFor("a frame", timeout: 600) { periods.contains { $0.1 >= t0 } }
        signposter.endInterval(name, state)
        let first = periods.first { $0.1 >= t0 }.map { ($0.1 - t0) * 1000 } ?? 0
        var cpu = 0.0
        if let end = periods.first(where: { $0.1 >= t0 })?.1, let cpu1 = periodCPU[end] {
            cpu = Double(cpu1 - cpu0) / 1e6
            log(String(format: "%@ %@: %.1f ms to the frame, %.1f ms of it on the main thread's CPU", "\(name)", label, first, cpu))
        }
        let drawnCards = PerfCounters.cards - cards
        let drawnRows = PerfCounters.rows - rows
        await pause(1)
        recording = false
        checkList("\(name) \(label)")
        let after = periods.filter { $0.0 >= t0 }.map { ($0.1 - $0.0) * 1000 }.max() ?? 0
        return Sample(wall: first, after: after, cards: drawnCards, rows: drawnRows, cpu: cpu)
    }

    struct Sample {
        var wall: Double
        var after: Double
        var cards: Int
        var rows: Int
        var cpu: Double
    }

    private func record(_ name: String, _ samples: [Sample]) {
        log("\(name): \(samples.count) samples")
        guard !samples.isEmpty else { return }
        var stats = PerfStats.of(name, samples.map(\.wall), limit: 100)
        stats.afterMax = samples.map(\.after).max()
        stats.cardBodies = samples.map(\.cards).max()
        stats.rowBodies = samples.map(\.rows).max()
        let cpu = samples.map(\.cpu).sorted()
        stats.cpuMax = cpu.last
        stats.cpuMedian = cpu[cpu.count / 2]
        results.append(stats)
    }

    private func shownCards(_ list: SurfaceListModel) -> [(Card, SectionLayout)] {
        list.sections.filter(\.isLeaf).flatMap { section in section.cards.map { ($0, section) } }
    }

    private func operations(tab: ListTab, list: SurfaceListModel, data: AccountViewModel, scroll: NSScrollView) async {
        let title = tab.title
        // Selection: ten card headers near the top.
        var samples: [Sample] = []
        // Cards in view, as a click selects (a click is always in view).
        let isInView = steps.inView ?? { _, _ in false }
        let inView = shownCards(list).filter { isInView(list, $0.0.id) }
        for (card, _) in (inView.isEmpty ? Array(shownCards(list).prefix(10)) : inView).cycled(10) {
            samples.append(await measure("select", "\(title) \(card.pr)") { list.select(.header(card: card.id)) })
        }
        record("\(title) select", samples)

        if let toggle = steps.toggle {
            samples = []
            for (card, _) in shownCards(list).prefix(10) {
                samples.append(await measure("toggle", "\(title) \(card.pr)") { toggle(list, card.id) })
            }
            record("\(title) ⌘-click", samples)
            list.clearSelection()
            // ⇧-click: the range from the first card shown to each card.
            samples = []
            let range = Array(shownCards(list).prefix(11))
            if let first = range.first {
                list.select(.header(card: first.0.id))
                for (card, _) in range.dropFirst() {
                    samples.append(await measure("toggle", "\(title) range \(card.pr)") { list.click(card: card.id, extent: .range) })
                }
                record("\(title) ⇧-click", samples)
                list.clearSelection()
            }
            await pause(0.5)
        } else {
            notes.append("\(title) ⌘-click: not in this version")
        }

        if tab == .all {
            samples = []
            for _ in 0..<10 {
                guard let (card, _) = shownCards(list).first(where: { !$0.0.isDismissed }) else { break }
                list.select(.header(card: card.id))
                await pause(0.2)
                samples.append(await measure("dismiss", "\(card.pr)") { list.press(.delete) })
            }
            record("All dismiss (⌫)", samples)
            return
        }

        // Review: the moves.
        func reviewCards(_ section: PlacementSection) -> [Card] {
            shownCards(list).filter { $0.1.key == SectionKey.placed(.review, section) }.map(\.0)
        }
        samples = []
        for i in 0..<10 {
            let target: PlacementSection = i % 2 == 0 ? .waiting : .todo
            let from: PlacementSection = target == .waiting ? .todo : .waiting
            guard let card = reviewCards(from).first else { break }
            let move = PlaceMove(card: card.id, target: .review(target), position: .byDefault, verb: .move)
            samples.append(await measure("move", "Move to \(target.title) \(card.pr)") { list.perform(.place(move)) })
        }
        record("Review Move to …", samples)

        samples = []
        for i in 0..<10 {
            let target: PlacementSection = i % 2 == 0 ? .doing : .todo
            let from: PlacementSection = target == .doing ? .todo : .doing
            guard let card = reviewCards(from).first else { break }
            list.select(.header(card: card.id))
            await pause(0.2)
            samples.append(await measure("move", "\(target.title) key \(card.pr)") { list.press(.moveTo(target)) })
        }
        record("Review D/T/W", samples)

        samples = []
        if let card = reviewCards(.todo).dropFirst(2).first {
            list.select(.header(card: card.id))
            await pause(0.2)
            for i in 0..<10 {
                samples.append(await measure("move", "reorder \(card.pr)") { list.press(.reorder(up: i % 2 == 0)) })
            }
        }
        record("Review ⌥↑/⌥↓", samples)

        samples = []
        for i in 0..<10 {
            let todo = reviewCards(.todo)
            guard todo.count >= 3 else { break }
            let card = todo[i % 2 == 0 ? 2 : 0]
            let over = todo[i % 2 == 0 ? 0 : 2]
            list.beginDrag(card.id)
            list.dragOver(.card(over.id, lowerHalf: i % 2 != 0))
            await pause(0.2)
            samples.append(await measure("move", "drop \(card.pr)") { list.drop(.card(over.id, lowerHalf: i % 2 != 0)) })
        }
        record("Review drag and drop", samples)

        if let autoScroll = steps.autoScroll, let stop = steps.stopAutoScroll {
            for name in ["Review auto-scroll (cold)", "Review auto-scroll"] {
                scrollTo(scroll, y: 0)
                await pause(0.5)
                let state = signposter.beginInterval("autoscroll", "\(name)")
                periods = []
                recording = true
                autoScroll(list, scroll)
                await pause(4)
                stop(list)
                recording = false
                signposter.endInterval("autoscroll", state)
                let frames = periods.map { ($0.1 - $0.0) * 1000 }
                var stats = PerfStats.of(name, frames, limit: 16)
                stats.busyTotal = frames.reduce(0, +)
                results.append(stats)
            }
        } else {
            notes.append("Review auto-scroll: not in this version")
        }
    }

    /// Review with Compact on (DESIGN.md, "Compact"): turning it on and
    /// off, the scroll, a selection and a drop.
    private func compactOperations(list: SurfaceListModel, window: NSWindow) async {
        list.openTab(.review)
        await pause(0.5)
        var samples: [Sample] = []
        for _ in 0..<10 {
            samples.append(await measure("compact", "Compact") { list.toggleCompact() })
        }
        record("Review Compact on/off", samples)
        if !list.compact { list.toggleCompact() }
        await pause(0.5)
        if let scroll = listScrollView(in: window), ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_SKIP"] != "scroll" {
            await scrollPass("Review Compact scroll", scroll)
            scrollTo(scroll, y: 0)
            await pause(0.5)
        }
        samples = []
        for (card, _) in shownCards(list).prefix(10) {
            samples.append(await measure("select", "Compact \(card.pr)") { list.select(.header(card: card.id)) })
        }
        record("Review Compact select", samples)
        samples = []
        for i in 0..<10 {
            let todo = shownCards(list).filter { $0.1.key == SectionKey.placed(.review, .todo) }.map(\.0)
            guard todo.count >= 3 else { break }
            let card = todo[i % 2 == 0 ? 2 : 0]
            let over = todo[i % 2 == 0 ? 0 : 2]
            list.beginDrag(card.id)
            list.dragOver(.card(over.id, lowerHalf: i % 2 != 0))
            await pause(0.2)
            samples.append(await measure("move", "Compact drop \(card.pr)") { list.drop(.card(over.id, lowerHalf: i % 2 != 0)) })
        }
        record("Review Compact drag and drop", samples)
        list.toggleCompact()
    }

    /// The Filter (DESIGN.md, "Speed of operation"): a setting changed, and
    /// the options opened and closed, in All and Review. Measured with
    /// `Filter` closed and Muted Show, the rest at the defaults, between
    /// the operations.
    private func filterOperations(list: SurfaceListModel, window: NSWindow) async {
        for tab in [ListTab.all, .review] {
            list.openTab(tab)
            if let scroll = listScrollView(in: window) { scrollTo(scroll, y: 0) }
            await pause(0.5)
            var samples: [Sample] = []
            for i in 0..<10 {
                samples.append(await measure("filter", "\(tab.title) Status Open \(i % 2 == 0 ? "off" : "on")") { list.toggleStatus(.open) })
            }
            record("\(tab.title) Filter change (Status)", samples)
            samples = []
            for i in 0..<10 {
                let choice: MuteChoice = i % 2 == 0 ? .hide : .show
                samples.append(await measure("filter", "\(tab.title) Muted \(choice.title)") { list.setMuteChoice(choice) })
            }
            record("\(tab.title) Filter change (Muted)", samples)
            samples = []
            for i in 0..<10 {
                samples.append(await measure("filter", "\(tab.title) \(i % 2 == 0 ? "open" : "close")") { list.toggleFilterOpen() })
            }
            record("\(tab.title) Filter open/close", samples)
        }
    }

    private func tabSwitches(_ list: SurfaceListModel) async {
        var samples: [Sample] = []
        for i in 0..<10 {
            let next: ListTab = i % 2 == 0 ? .all : .review
            samples.append(await measure("tab", "\(next.title)") { list.openTab(next) })
        }
        record("Tab switch (All ↔ Review)", samples)
    }

    // MARK: Summary

    private func finish() {
        var lines = ["", "shiibar-gh measurement (\(PerfMode.buildLabel))", ""]
        lines.append("name | n | max ms | median ms | over limit | after max ms | card bodies | row bodies | busy total ms | cpu max ms | cpu median ms")
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        for r in results {
            lines.append(String(
                format: "%@ | %d | %.1f | %.1f | %d | %@ | %@ | %@ | %@ | %@ | %@", r.name, r.count, r.max, r.median, r.over, ms(r.afterMax),
                r.cardBodies.map(String.init) ?? "-", r.rowBodies.map(String.init) ?? "-", ms(r.busyTotal), ms(r.cpuMax), ms(r.cpuMedian)
            ))
        }
        if consistencyChecks > 0 {
            notes.append("list checks: \(consistencyChecks - consistencyFailures) of \(consistencyChecks) ok")
        }
        lines.append("")
        lines += notes.map { "note: " + $0 }
        print(lines.joined(separator: "\n"))
        if let out = ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_OUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(results).write(to: URL(fileURLWithPath: out))
        }
        fflush(stdout)
        quit()
    }
}

extension PerfMode {
    /// What the summary says it measured.
    static var buildLabel: String {
        ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF_LABEL"] ?? "unlabeled build"
    }
}

/// `SHIIBAR_GH_PERF_LAYOUTTRACE=1`: who marks the window's root view as
/// needing layout (the call stacks of the first times), to find what lays
/// the surface out again while the list scrolls.
@MainActor
enum LayoutTrace {
    static var root: NSView?
    static var reported = 0

    static func install(root view: NSView) {
        root = view
        guard let original = class_getInstanceMethod(NSView.self, #selector(setter: NSView.needsLayout)),
              let traced = class_getInstanceMethod(NSView.self, #selector(NSView.perfTracedSetNeedsLayout(_:))) else { return }
        method_exchangeImplementations(original, traced)
    }
}

extension NSView {
    @objc func perfTracedSetNeedsLayout(_ flag: Bool) {
        perfTracedSetNeedsLayout(flag)
        MainActor.assumeIsolated {
            if flag, self === LayoutTrace.root, LayoutTrace.reported < 6 {
                LayoutTrace.reported += 1
                let stack = Thread.callStackSymbols.prefix(28).joined(separator: "\n")
                FileHandle.standardError.write(Data("perf: root needsLayout\n\(stack)\n".utf8))
            }
        }
    }
}
