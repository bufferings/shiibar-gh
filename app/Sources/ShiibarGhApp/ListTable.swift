// The scrolling list of a surface: a view-based NSTableView with one column
// and one table row per list line (a heading, a card, an empty section, a
// "+ N more PRs" line, a Dismissed card), each an AppKit line view
// (ListCells.swift) that the table reuses (DESIGN.md, "Speed of operation":
// only the lines in view are made and laid out).
//
// Why a table and not the SwiftUI ScrollView: with a LazyVStack, every
// scroll event made SwiftUI lay the stack out again over all its lines, and
// every data change cost 100 to 450 ms of layout (docs/tasks/M7.md, the
// measurements). The table scrolls by moving its clip view and makes a line
// view only when the line comes into view.
//
// - Data changes are applied as differences: the lines removed and inserted
//   (by their ids), the lines whose values changed configured again (when in
//   view) and their heights given again. A tab switch, which changes most
//   lines, reloads the table (only the lines in view are made). After a
//   change, a row view in view that the table left away from its row is
//   put right by a reload (`rowViewsMisplaced`).
// - Each tab and the Dismissed list keep their scroll position while the
//   surface is open (DESIGN.md, "Scroll position").
// - Heights: a line's geometry (ListCells.swift, `LineLayout`) is worked
//   out once and kept with the values it was worked out for; again only when
//   those values change, or the width or the text size does.
// - Changes are applied once per run loop pass, before the run loop sleeps
//   (and so before Core Animation commits the pass's drawing), by an
//   observer of the main run loop. Its order 0 is below Core Animation's
//   commit observer (order 2000000, as the measurement mode's observer list
//   shows: `SHIIBAR_GH_PERF_OBSERVERS=1`, Perf.swift).
// - The selection, the selected cards and the drag change `ItemState`s
//   (ListPresenter.swift): only the line views of the items concerned draw
//   again; the table does nothing.
//
// AppKit API used, as declared in the SDK headers (NSTableView.h,
// NSResponder.h, NSClipView.h, NSScrollView.h, NSView.h):
// `makeViewWithIdentifier:owner:` "may also return a reused view with the
// same identifier that was no longer available on screen";
// `tableView:heightOfRow:` gives variable heights, which "should always be"
// the same for a row "until -noteHeightOfRowsWithIndexesChanged: is called";
// insert and remove rows inside `beginUpdates`/`endUpdates`, removals with
// the indexes before the change and insertions with those after it;
// `viewAtColumn:row:makeIfNecessary:` with NO returns the view of a row only
// while there is one; `validateProposedFirstResponder:forEvent:` is how
// NSTableView limits first responders to views in selected rows, overridden
// so the controls in a line work as they do outside a table;
// `viewDidEndLiveResize` and `inLiveResize` (the heights are worked out
// again once a live resize ends).

import AppKit
import Combine
import ShiibarGhCore
import SwiftUI

/// Where the list goes in the surface's SwiftUI content: an empty view that
/// tells the surface root (`SurfaceRoot`) its frame, the time and the text
/// scale. The list itself is an AppKit sibling of the SwiftUI content, not
/// inside it: as the table adds and removes the views of its lines, AppKit
/// tells the views around them that their constraints need updating, and
/// inside SwiftUI that reached the hosting view, which laid the whole surface
/// out again about once a frame while the list scrolled (found by tracing who
/// marked the root view as needing layout, `SHIIBAR_GH_PERF_LAYOUTTRACE`).
struct ListSlot: View {
    var content: ListContent
    var now: Int64
    @Environment(\.textScale) var k

    var body: some View {
        SurfaceAnchor(content: content, part: .list)
            .onAppear { content.environment = (now, k) }
            .onChange(of: now) { _, value in content.environment = (value, k) }
            .onChange(of: k) { _, value in content.environment = (now, value) }
            .accessibilityHidden(true)
    }
}

/// An empty AppKit view that SwiftUI places like any view: where the list
/// goes, and (to check that the list stays clear of them) the header and
/// the key hints. Its frame in the surface root is read with AppKit's own
/// conversion (`convert(_:to:)`), so no SwiftUI coordinate space, safe area
/// or popover arrow can shift the list. SwiftUI may move the view by moving
/// its ancestors only: their frame changes are watched too
/// (`NSView.frameDidChangeNotification`, NSView.h: "sent when the frame
/// changes for a view", while `postsFrameChangedNotifications` is YES).
final class FrameAnchor: NSView {
    var onChange: (() -> Void)?
    private var watched: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        onChange?()
    }

    override func setFrameOrigin(_ origin: NSPoint) {
        super.setFrameOrigin(origin)
        onChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in watched { NotificationCenter.default.removeObserver(token) }
        watched = []
        var view = superview
        while let current = view, !(current is SurfaceRoot) {
            current.postsFrameChangedNotifications = true
            watched.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: current, queue: nil
            ) { [weak self] _ in MainActor.assumeIsolated { self?.onChange?() } })
            view = current.superview
        }
        onChange?()
    }

    /// The frame in the surface root, while in a window.
    var frameInRoot: CGRect? {
        guard window != nil, let root = rootView else { return nil }
        return convert(bounds, to: root)
    }

    var rootView: SurfaceRoot? {
        var view = superview
        while let current = view {
            if let root = current as? SurfaceRoot { return root }
            view = current.superview
        }
        return nil
    }
}

struct SurfaceAnchor: NSViewRepresentable {
    enum Part { case list, header, hints, options, bands }
    var content: ListContent
    var part: Part

    func makeNSView(context: Context) -> FrameAnchor {
        let anchor = FrameAnchor()
        switch part {
        case .list:
            content.listAnchor = anchor
            anchor.onChange = { [weak content] in content?.onSlot?() }
        case .header: content.headerAnchor = anchor
        case .hints: content.hintsAnchor = anchor
        case .options: content.optionsAnchor = anchor
        case .bands: content.bandsAnchor = anchor
        }
        return anchor
    }

    func updateNSView(_ anchor: FrameAnchor, context: Context) {}

    static func dismantleNSView(_ anchor: FrameAnchor, coordinator: ()) {
        anchor.onChange?()
        anchor.onChange = nil
    }

    /// Takes the room it is offered (no Auto Layout fitting).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FrameAnchor, context: Context) -> CGSize? {
        switch part {
        case .list: return CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
        case .header, .hints, .options, .bands: return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        }
    }
}

/// The root view of a popover or window of an account: the SwiftUI content
/// (header, tabs, search, key hints), the list over the room
/// `ListSlot` leaves for it, and the Grouping sheet over both.
final class SurfaceRoot: NSView {
    let host: NSHostingView<AnyView>
    private let overlay: NSHostingView<AnyView>
    private let container: ListContainer
    private let controller: ListTableController
    private let content: ListContent
    private var cancellables: Set<AnyCancellable> = []

    init<Content: View, Overlay: View>(content view: Content, overlay over: Overlay, list: ListContent) {
        host = NSHostingView(rootView: AnyView(view))
        overlay = NSHostingView(rootView: AnyView(over))
        content = list
        controller = ListTableController(content: list)
        container = ListContainer(controller.scrollView)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        // The surface's size is the popover's or the window's: the SwiftUI
        // content does not compute minimum or maximum sizes for it
        // (`NSHostingSizingOptions`, SwiftUI; the window's minimum size is
        // set by its owner).
        host.sizingOptions = []
        overlay.sizingOptions = []
        for view in [host, overlay] as [NSView] {
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
        }
        container.isHidden = true
        overlay.isHidden = true
        addSubview(host)
        addSubview(container)
        addSubview(overlay)
        list.onSlot = { [weak self] in self?.placeList() }
        list.onEnvironment = { [weak self] in
            guard let self, let (now, k) = self.content.environment else { return }
            self.controller.update(now: now, k: k)
        }
        list.list.$showsGrouping.combineLatest(list.list.$confirmingDismiss)
            .sink { [weak self] shows, confirming in self?.overlay.isHidden = !shows && confirming == nil }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The list over its anchor (`ListSlot`), hidden while the anchor is
    /// not in this root (another content shows, or the surface closes).
    func placeList() {
        guard let anchor = content.listAnchor, anchor.rootView === self, let frame = anchor.frameInRoot else {
            container.isHidden = true
            return
        }
        // Whole points inside the anchor: never past its edges.
        let inside = CGRect(
            x: frame.minX.rounded(.up), y: frame.minY.rounded(.up),
            width: (frame.maxX.rounded(.down) - frame.minX.rounded(.up)), height: (frame.maxY.rounded(.down) - frame.minY.rounded(.up))
        )
        if container.frame != inside { container.frame = inside }
        if container.isHidden { container.isHidden = false }
        scheduleMinimumHeight()
    }

    /// Told the least height of the surface (`SurfaceHeight`): what is
    /// above the list with the Filter's options open at their full height
    /// and without the warning and failure bands, the list's minimum and the
    /// key hints under it. The same whether the options are open or closed
    /// and whether a band shows, so only the text size changes it (a band
    /// takes its room from the list). Not worked out while the Dismissed
    /// list shows (it has no Filter row). Set by the popover's or the
    /// window's owner.
    var onMinimumHeight: ((CGFloat) -> Void)?
    private var reportedMinimum: CGFloat?
    private var minimumScheduled = false

    /// Worked out once the layout of this pass is over (the anchors are
    /// where the content put them), then given to the owner, which may
    /// resize the surface.
    private func scheduleMinimumHeight() {
        guard onMinimumHeight != nil, !minimumScheduled else { return }
        minimumScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.minimumScheduled = false
            self.reportMinimumHeight()
        }
    }

    private func reportMinimumHeight() {
        guard let onMinimumHeight, let k = content.environment?.1, !content.list.showingDismissed,
              let listTop = content.listAnchor?.frameInRoot?.minY, let hints = content.hintsAnchor?.frameInRoot else { return }
        // The options' area as laid out now (none while closed): taken off
        // the list's top, and their full area added back.
        let shown = content.optionsAnchor.flatMap { $0.rootView === self ? $0.frameInRoot?.height : nil } ?? 0
        let bands = content.bandsAnchor.flatMap { $0.rootView === self ? $0.frameInRoot?.height : nil } ?? 0
        let minimum = FilterOptionsLayout.surfaceMinimum(
            listTop: listTop, shownOptions: shown, bands: bands, below: hints.height, lines: content.list.filterOptions.count, k: k
        )
        if let reportedMinimum, abs(reportedMinimum - minimum) < 0.5 { return }
        reportedMinimum = minimum
        onMinimumHeight(minimum)
    }

    /// The list's frame, its anchor's and the frames of the header and the
    /// key hints, in this root (the measurement mode's frame check).
    var frames: (list: CGRect?, anchor: CGRect?, header: CGRect?, hints: CGRect?) {
        (container.isHidden ? nil : container.frame, content.listAnchor?.frameInRoot, content.headerAnchor?.frameInRoot,
         content.hintsAnchor?.frameInRoot)
    }

    /// The cards in view, in this root, and whether each is indented (the
    /// measurement mode's frame check: the margins left and right).
    var cardFrames: [(CGRect, indented: Bool)] {
        controller.cardViews.map { (self.convert($0.bounds, from: $0), $0.line?.indented ?? false) }
    }

    /// The window's title strip, over the SwiftUI content: a press there
    /// moves the window. The content (with `fullSizeContentView`) reaches
    /// under the title bar, and the hosting view took presses in the strip
    /// (the measurement mode's drag map): the window moved only now and
    /// then. Set by the window's owner; a popover has none.
    var movesWindowByTitleStrip = false {
        didSet {
            if movesWindowByTitleStrip, titleStrip == nil {
                let strip = WindowDragView()
                addSubview(strip, positioned: .below, relativeTo: overlay)
                titleStrip = strip
                needsLayout = true
            }
        }
    }

    private var titleStrip: WindowDragView?

    override func layout() {
        super.layout()
        if let titleStrip, let window {
            // The title bar's height: the window's frame less its content
            // layout rect (NSWindow.h, `contentLayoutRect`).
            let height = max(0, window.frame.height - window.contentLayoutRect.height)
            titleStrip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        }
        placeList()
        if let resizer { resizer.frame = CGRect(x: 0, y: bounds.height - BottomEdgeResizer.height, width: bounds.width, height: BottomEdgeResizer.height) }
    }

    /// The popover's bottom edge, dragged to change its height (DESIGN.md,
    /// "Screens"): set by the popover's owner; a window has none (its own
    /// frame resizes it).
    var onBottomEdgeDrag: ((BottomEdgeResizer.Phase, CGFloat) -> Void)? {
        didSet {
            if onBottomEdgeDrag != nil, resizer == nil {
                let resizer = BottomEdgeResizer()
                resizer.onDrag = { [weak self] phase, distance in self?.onBottomEdgeDrag?(phase, distance) }
                addSubview(resizer, positioned: .below, relativeTo: overlay)
                self.resizer = resizer
                needsLayout = true
            }
        }
    }

    private var resizer: BottomEdgeResizer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller.stop() } else { controller.start() }
    }
}

/// A thin strip along the popover's bottom edge: the pointer shows the
/// resize cursor over it, and a drag reports how far down the pointer went
/// since the press (screen points, `NSEvent.mouseLocation`, NSEvent.h).
/// AppKit API used, as declared in the SDK headers: `addCursorRect:cursor:`
/// from `resetCursorRects` (NSView.h); `frameResizeCursorFromPosition:
/// inDirections:` (NSCursor.h, macOS 15) and `resizeUpDownCursor` before it.
final class BottomEdgeResizer: NSView {
    enum Phase { case began, changed, ended }
    static let height: CGFloat = 5
    var onDrag: ((Phase, CGFloat) -> Void)?
    private var start: NSPoint?

    override var isFlipped: Bool { true }

    private var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottom, directions: .all)
        }
        return NSCursor.resizeUpDown
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        onDrag?(.began, 0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onDrag?(.changed, start.y - NSEvent.mouseLocation.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        onDrag?(.ended, start.y - NSEvent.mouseLocation.y)
        self.start = nil
    }
}

/// How much two images differ (the measurement mode's check): the share of
/// pixels whose color differs by more than a small step in any channel,
/// both drawn into the same bitmap format; 1 when their sizes differ.
@MainActor
enum ImageCompare {
    static func difference(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height else { return 1 }
        guard let pa = pixels(a), let pb = pixels(b) else { return nil }
        var differing = 0
        var i = 0
        while i < pa.count {
            if abs(Int(pa[i]) - Int(pb[i])) > 8 || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > 8
                || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 8 || abs(Int(pa[i + 3]) - Int(pb[i + 3])) > 8 {
                differing += 1
            }
            i += 4
        }
        return Double(differing) / Double(max(1, a.width * a.height))
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }
}

/// The view controller of a surface (NSPopover and NSPanel take one).
final class SurfaceViewController: NSViewController {
    private let root: SurfaceRoot

    init(_ root: SurfaceRoot) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = root
    }
}

/// The list's view in the surface root: the scroll view filling it.
final class ListContainer: NSView {
    let scrollView: NSScrollView

    init(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        if scrollView.frame != bounds { scrollView.frame = bounds }
    }
}

/// The table: never the first responder (the keys go to the surface's key
/// monitor, Surfaces.swift), no row selection of its own, and the controls
/// in its lines take their clicks.
final class ListTableView: NSTableView {
    var onEndLiveResize: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }

    /// A press on the list's empty part (between and below the lines):
    /// nothing selected (DESIGN.md, "Selection"). The line views take the
    /// presses on them (CardInput.swift).
    var onEmptyClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onEmptyClick?()
    }

    override func rightMouseDown(with event: NSEvent) {}

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }
}

/// The insertion line of a drag (Main.html `.dropline`), over the gap above
/// or below a card.
final class DropLineView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = Palette.accent.nsColor
        let line = NSRect(x: 4, y: bounds.midY - 1, width: bounds.width - 4, height: 2)
        accent.setFill()
        line.fill()
        let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: bounds.midY - 3, width: 6, height: 6))
        Palette.background.nsColor.setFill()
        circle.fill()
        accent.setStroke()
        circle.lineWidth = 2
        circle.stroke()
    }
}

@MainActor
final class ListTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let content: ListContent
    let scrollView = NSScrollView()
    let table = ListTableView()
    /// The animation of a card's height after `more`, `less`, "+ N more"
    /// and `Show less` (DESIGN.md, "Row body"), in seconds.
    static let heightAnimation: TimeInterval = 0.2
    static let heightTiming = CAMediaTimingFunction(name: .easeInEaseOut)
    /// The line whose height animates, while the change is applied.
    private var animating: String?
    private let dropLine = DropLineView()

    private var lines: [ListEntry] = []
    private var heights: [CGFloat] = []
    private var rowOf: [String: Int] = [:]
    /// Cells of the lines in view before a reload, to configure again.
    private var spare: [NSUserInterfaceItemIdentifier: [LineCell]] = [:]
    /// Each line's geometry, with the values it was worked out for.
    /// A few per line (its look in All and in Review differ: the tag, the
    /// indent), so a tab switch back finds them.
    private var shapes: [String: [(inputs: ShapeInputs, shape: LineShape)]] = [:]
    private var shapedWidth: CGFloat = 0
    private var shapedScale: CGFloat = 0

    private var now: Int64 = 0
    private var k: CGFloat = 1
    private var autoDismissDays: Int64 = 0
    private var started = false
    private var dirty = false
    private var redrawAll = false
    private var observer: CFRunLoopObserver?
    private var cancellables: Set<AnyCancellable> = []

    var context: CardContext { content.context }

    init(content: ListContent) {
        self.content = content
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.onEndLiveResize = { [weak self] in self?.widthChanged() }
        table.onEmptyClick = { [weak self] in self?.content.list.clearSelection() }
        dropLine.isHidden = true
        table.addSubview(dropLine)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: scrollView.contentView)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.widthChanged() } }
            .store(in: &cancellables)

        content.objectWillChange.sink { [weak self] _ in self?.setNeedsApply() }.store(in: &cancellables)
        // An avatar arrived: the cards in view draw again.
        context.avatars.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.redrawVisible() }
        }.store(in: &cancellables)
        // The selection's tint follows the keys: the window turning key or
        // not, the search field taking or leaving them; the system colors.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self, (note.object as? NSWindow) === self.table.window else { return }
                        self.lookMayChange()
                    }
                }
                .store(in: &cancellables)
        }
        content.list.$searchFocused.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.lookMayChange() } }
            .store(in: &cancellables)
        SystemColors.changed.sink { [weak self] in MainActor.assumeIsolated { self?.lookMayChange() } }.store(in: &cancellables)
        content.onDropLine = { [weak self] in self?.placeDropLine() }
        content.table = self
        context.drag.scrollView = scrollView

        start()
    }

    /// Applies changes while the list is in a window.
    func start() {
        content.table = self
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyIfNeeded() }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }
        dirty = true
    }

    func stop() {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
        if content.table === self { content.table = nil }
    }

    /// The values from the surface around the list.
    func update(now: Int64, k: CGFloat) {
        context.drag.scale = k
        if !started || now != self.now || k != self.k {
            self.now = now
            self.k = k
            redrawAll = true
            started = true
            setNeedsApply()
        }
    }

    private func setNeedsApply() {
        dirty = true
        // The change may come after this pass's observer ran: the run loop
        // must not sleep before it is applied.
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func applyIfNeeded() {
        guard dirty else { return }
        dirty = false
        guard PerfMode.enabled else { return apply() }
        let start = CACurrentMediaTime()
        let made = PerfCounters.shapes
        apply()
        let ms = (CACurrentMediaTime() - start) * 1000
        PerfCounters.frame.applies += 1
        PerfCounters.frame.applyMs += ms
        if ms > 10 {
            FileHandle.standardError.write(Data(String(
                format: "perf: list apply %.1f ms, %d lines worked out\n", ms, PerfCounters.shapes - made
            ).utf8))
        }
    }

    private var width: CGFloat {
        max(100, scrollView.contentView.bounds.width)
    }

    private func widthChanged() {
        if let restoring { scrollTo(y: restoring) }
        let width = self.width
        if let column = table.tableColumns.first, abs(column.width - width) > 0.5 {
            column.width = width
        }
        guard abs(width - shapedWidth) > 0.5, !table.inLiveResize else { return }
        redrawAll = true
        setNeedsApply()
    }

    private var environment: LineEnvironment {
        LineEnvironment(k: k, now: now, autoDismissDays: autoDismissDays, context: context, look: look)
    }

    /// The colors the lines are drawn with now (`ListLook`).
    private var look = ListLook()

    /// Works out the look again; a change draws every line again.
    private func refreshLook() {
        let window = table.window
        let next = ListLook(
            colors: SystemColors.epoch, accent: SystemColors.accent,
            selectionActive: ((window?.isKeyWindow ?? false) || (window != nil && window === PerfMode.assumedKeyWindow))
                && !content.list.searchFocused
        )
        guard next != look else { return }
        look = next
        redrawAll = true
    }

    private func lookMayChange() {
        let before = look
        refreshLook()
        if look != before { setNeedsApply() }
    }

    // MARK: Applying a change

    // MARK: Scroll positions

    /// The scroll position of each tab and of the Dismissed list while the
    /// surface stays open (DESIGN.md, "Scroll position"): a tab shown for the
    /// first time since the surface opened starts at the top.
    private var positions: [String: CGFloat] = [:]
    /// What the table shows: a tab, or the Dismissed list.
    private var shownView: String?
    /// `SurfaceListModel.openings` when the positions were kept.
    private var openings: Int?

    private var currentView: String {
        content.list.showingDismissed ? "dismissed" : "\(content.list.tab)"
    }

    private func apply() {
        refreshLook()
        let list = content.list
        if openings != list.openings {
            // The surface closed since: every position goes.
            openings = list.openings
            positions = [:]
            shownView = nil
        }
        let view = currentView
        let switching = view != shownView
        if switching, let shownView { positions[shownView] = scrollView.contentView.bounds.origin.y }
        applyLines()
        if let (id, offset) = anchor {
            anchor = nil
            if !switching, let row = rowOf[id], row < table.numberOfRows {
                scrollTo(y: table.rect(ofRow: row).minY - offset)
            }
        }
        if switching {
            shownView = view
            restoring = positions[view] ?? 0
            scrollTo(y: restoring ?? 0)
        }
    }

    /// The position being given back to the view just shown, until the
    /// list has the room for it: the surface lays out its header after the
    /// list is filled (the Dismissed list's heading changes the list's
    /// height), and a position past the end of the list as it was then is
    /// set again once the list has its new size.
    private var restoring: CGFloat?

    /// The scroll position, within the document.
    private func scrollTo(y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        let target = min(maxY, max(0, y))
        if target == y { restoring = nil }
        guard target != clip.bounds.origin.y else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        if rowViewsMisplaced("scroll position") { reload() }
    }

    /// The scroll position of `view` kept now (the measurement mode's
    /// check), nil when none is kept.
    func keptPosition(_ view: String) -> CGFloat? {
        view == shownView ? scrollView.contentView.bounds.origin.y : positions[view]
    }

    private func applyLines() {
        autoDismissDays = content.list.autoDismissDays
        let next = content.entries
        if shapedScale != k || (abs(shapedWidth - width) > 0.5 && !table.inLiveResize) {
            shapes = [:]
            shapedScale = k
            shapedWidth = width
        }
        let nextHeights = next.map { shape($0).height }
        let nextIDs = next.map(\.id)
        let oldIDs = lines.map(\.id)
        let old = lines
        let oldHeights = heights
        let redraw = redrawAll
        redrawAll = false

        let animated = content.list.takeAnimatedCard().map { "card:" + $0 }
        if nextIDs == oldIDs {
            var changedHeights = IndexSet()
            lines = next
            heights = nextHeights
            let change = {
                for i in next.indices where redraw || next[i] != old[i] || nextHeights[i] != oldHeights[i] {
                    if nextHeights[i] != oldHeights[i] { changedHeights.insert(i) }
                    self.redrawRow(i)
                }
                if !changedHeights.isEmpty { self.table.noteHeightOfRows(withIndexesChanged: changedHeights) }
            }
            // `more`, `less`, "+ N more" or `Show less` pressed here
            // (DESIGN.md, "Row body"): the height changes over 0.2 seconds.
            // The rows above and the scroll position stay, so the pressed
            // row's top edge stays where it is on the screen; the lines below
            // slide and the card grows or shrinks with them: the row views
            // and the card take their new frames at once (the consistency
            // checks see those), Core Animation shows the way there.
            // With Reduce motion (NSAccessibility.h,
            // `accessibilityDisplayShouldReduceMotion`) the change shows at
            // once: the table's own animation of a height change is turned
            // off too (a group of duration 0).
            if let animated, let index = next.firstIndex(where: { $0.id == animated }), nextHeights[index] != oldHeights[index] {
                let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                animating = reduce ? nil : animated
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduce ? 0 : Self.heightAnimation
                    context.timingFunction = Self.heightTiming
                    change()
                }
                animating = nil
            } else {
                change()
            }
            if rowViewsMisplaced("heights") { reload() }
            placeDropLine()
            return
        }

        let difference = nextIDs.difference(from: oldIDs)
        // The rows in view before the change (the table still has them).
        let inView = table.rows(in: table.visibleRect)
        lines = next
        heights = nextHeights
        rowOf = Dictionary(nextIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        if difference.count > max(60, next.count / 3) {
            // Most lines changed (a tab switch).
            reload()
            placeDropLine()
            return
        }
        var removed = IndexSet()
        var inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // A kept line whose height changed in the same change as lines
        // inserted or removed is taken out and put back: told by
        // `noteHeightOfRows` after such an update, the table gave the row
        // view its new height but left the cell at the old one (the
        // measurement mode's consistency check: a Dismissed list's band that
        // became the first with the search, a card of Done that lost
        // `Dismissed in N days` as it moved to an empty section).
        do {
            var oldIndex: [String: Int] = [:]
            for (j, id) in oldIDs.enumerated() where !removed.contains(j) { oldIndex[id] = j }
            for i in next.indices where !inserted.contains(i) {
                guard let j = oldIndex[next[i].id], nextHeights[i] != oldHeights[j] else { continue }
                removed.insert(j)
                inserted.insert(i)
            }
        }
        // Lines inserted above or among the lines in view: the table is
        // reloaded (only the lines in view are configured again). Inserted
        // there by `insertRows`, the table left the row views in view at
        // places worked out from estimated heights, about 32 points off,
        // after the change and after the checks below (the measurement
        // mode's check: a Filter setting that brought cards back above the
        // ones in view, with the options open).
        if let first = inserted.first, inView.length > 0, first < inView.location + inView.length {
            reload()
            placeDropLine()
            return
        }
        table.beginUpdates()
        if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
        if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
        table.endUpdates()

        // The lines kept: configured again when their values changed, their
        // heights given again when those did.
        var before: [String: Int] = [:]
        for (i, id) in oldIDs.enumerated() { before[id] = i }
        var changedHeights = IndexSet()
        for i in next.indices where !inserted.contains(i) {
            guard let j = before[next[i].id] else { continue }
            let heightChanged = nextHeights[i] != oldHeights[j]
            if redraw || next[i] != old[j] || heightChanged { redrawRow(i) }
            if heightChanged { changedHeights.insert(i) }
        }
        if !changedHeights.isEmpty { table.noteHeightOfRows(withIndexesChanged: changedHeights) }
        // Inside the update the table places the rows after an inserted one
        // by an estimate of its height, and moves the row views in view
        // there (they were found a fraction of a point off: 6732.06 for
        // 6763, the rows' own rectangles right). Nothing moved them back
        // once it had the real height: a line was drawn over another and a
        // gap was left further down. When a row view in view is not at its
        // row, the table is reloaded, which tiles every row again.
        if rowViewsMisplaced("rows") { reload() }
        placeDropLine()
        // The table may move its row views once more in a later layout of
        // the same change (the measurement mode's check found row views
        // 32.6 points off, and rows in view without a row view, after a
        // Filter setting brought cards back above the ones in view with
        // the options open): looked at again once the pass is over.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.rowViewsMisplaced("rows, later") else { return }
            self.reload()
        }
    }

    /// The lines in view configured again, the others when they come into
    /// view. The cells in view are kept for them (a reload does not hand
    /// them back through `makeViewWithIdentifier:owner:`).
    private func reload() {
        if PerfMode.enabled { PerfCounters.frame.reloads += 1 }
        spare = [:]
        let range = table.rows(in: table.visibleRect)
        if range.length > 0 {
            for row in range.location..<(range.location + range.length) {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LineCell, let id = cell.identifier {
                    spare[id, default: []].append(cell)
                }
            }
        }
        table.reloadData()
    }

    /// Whether a row view in view is not where its row is.
    private func rowViewsMisplaced(_ when: String) -> Bool {
        // The table moves its row views in its layout: what it has not done
        // by then is what is checked.
        table.layoutSubtreeIfNeeded()
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return false }
        for row in range.location..<(range.location + range.length) {
            guard let view = table.rowView(atRow: row, makeIfNecessary: false) else {
                if PerfMode.enabled {
                    FileHandle.standardError.write(Data("perf: \(when): row \(row) in view has no row view: reloaded\n".utf8))
                }
                return true
            }
            if view.frame != table.rect(ofRow: row) {
                if PerfMode.enabled {
                    FileHandle.standardError.write(Data(String(
                        format: "perf: %@: row view %d at y %.2f, its row at %.2f: reloaded\n", when, row, view.frame.minY, table.rect(ofRow: row).minY
                    ).utf8))
                }
                return true
            }
        }
        return false
    }

    private func redrawRow(_ row: Int) {
        guard row < table.numberOfRows, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LineCell else { return }
        configure(cell, row: row)
    }

    /// The card views of the lines in view.
    var cardViews: [CardLineView] {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<(range.location + range.length)).compactMap {
            (table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? LineCell)?.content as? CardLineView
        }
    }

    private func redrawVisible() {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return }
        for row in range.location..<(range.location + range.length) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LineCell)?.content.needsDisplay = true
        }
    }

    // MARK: Geometry

    /// What a line's geometry depends on besides the width and the text
    /// size, which reset all of them.
    struct ShapeInputs: Equatable {
        var entry: ListEntry
        /// Texts that depend on the time: line 3 of a card wraps by them.
        var texts: [String]
    }

    /// A line's geometry and height.
    enum LineShape {
        case card(CardGeometry)
        case dismissed(DismissedGeometry)
        case frame(CGRect, height: CGFloat)
        case height(CGFloat)

        var height: CGFloat {
            switch self {
            case .card(let geometry): return geometry.size.height + 8
            case .dismissed(let geometry): return geometry.size.height + 8
            case .frame(_, let height), .height(let height): return height
            }
        }
    }

    private func inputs(_ entry: ListEntry) -> ShapeInputs {
        switch entry {
        case .card(let line):
            // `now` changes the times and `Dismissed in N days` on line 3:
            // only whether they wrap is part of the geometry (where they are
            // is worked out as the card is drawn).
            let fits = LineLayout.line3Fits(line, width: shapedWidth > 0 ? shapedWidth : width, k: k, now: now)
            return ShapeInputs(entry: entry.withoutSearch, texts: [fits ? "fits" : "wraps"])
        case .dismissed(let card, _):
            return ShapeInputs(entry: entry.withoutSearch, texts: [DismissedText.daysLeft(card.dismissExpiresAt, now: now)])
        default:
            return ShapeInputs(entry: entry, texts: [])
        }
    }

    private func shape(_ entry: ListEntry) -> LineShape {
        let inputs = inputs(entry)
        if let known = shapes[entry.id]?.first(where: { $0.inputs == inputs }) { return known.shape }
        let shape = makeShape(entry)
        var kept = shapes[entry.id] ?? []
        kept.insert((inputs, shape), at: 0)
        if kept.count > 3 { kept.removeLast() }
        shapes[entry.id] = kept
        return shape
    }

    private func makeShape(_ entry: ListEntry) -> LineShape {
        PerfCounters.shapes += 1
        guard PerfMode.enabled else { return makeShapeNow(entry) }
        let start = CACurrentMediaTime()
        defer {
            PerfCounters.frame.shapes += 1
            PerfCounters.frame.shapeMs += PerfCounters.since(start)
        }
        return makeShapeNow(entry)
    }

    private func makeShapeNow(_ entry: ListEntry) -> LineShape {
        let w = shapedWidth > 0 ? shapedWidth : width
        switch entry {
        case .message(let text):
            return .height(LineLayout.message(text, width: w, k: k))
        case .heading(let heading):
            let (frame, height) = LineLayout.heading(heading, width: w, k: k)
            return .frame(frame, height: height)
        case .card(let line):
            return .card(LineLayout.card(line, width: w, k: k, now: now))
        case .empty:
            let (frame, height) = LineLayout.empty(width: w, k: k)
            return .frame(frame, height: height)
        case .fold:
            let (frame, height) = LineLayout.fold(width: w, k: k)
            return .frame(frame, height: height)
        case .dismissed(let card, _):
            return .dismissed(LineLayout.dismissed(card, width: w, k: k, now: now))
        case .end:
            return .height(8)
        }
    }

    // MARK: Cells

    private enum Kind: String {
        case message, heading, card, empty, fold, dismissed, end
        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("line." + rawValue) }
    }

    private func kind(_ entry: ListEntry) -> Kind {
        switch entry {
        case .message: return .message
        case .heading: return .heading
        case .card: return .card
        case .empty: return .empty
        case .fold: return .fold
        case .dismissed: return .dismissed
        case .end: return .end
        }
    }

    private func makeCell(_ kind: Kind) -> LineCell {
        PerfCounters.made += 1
        if PerfMode.enabled { PerfCounters.frame.made += 1 }
        let content: NSView
        switch kind {
        case .message: content = MessageLineView()
        case .heading: content = HeadingLineView()
        case .card: content = CardLineView()
        case .empty: content = EmptyLineView()
        case .fold: content = FoldLineView()
        case .dismissed: content = DismissedLineView()
        case .end: content = NSView()
        }
        return LineCell(content, identifier: kind.identifier)
    }

    private func configure(_ cell: LineCell, row: Int) {
        let entry = lines[row]
        let id = entry.id
        let previous = cell.lineID
        cell.lineID = id
        if PerfMode.enabled { PerfCounters.frame.configured += 1 }
        let env = environment
        let width = shapedWidth > 0 ? shapedWidth : self.width
        switch (entry, shape(entry)) {
        case (.message(let text), _):
            cell.contentFrame = CGRect(x: 0, y: 0, width: width, height: heights[row])
            (cell.content as? MessageLineView)?.text = text
            (cell.content as? MessageLineView)?.k = k
        case (.heading(let heading), .frame(let frame, _)):
            cell.contentFrame = frame
            (cell.content as? HeadingLineView)?.configure(heading, env: env, state: content.state(id))
        case (.card(let line), .card(let geometry)):
            let frame = CGRect(x: line.indented ? 24 : 12, y: 0, width: geometry.size.width, height: geometry.size.height)
            if id == animating, previous == id, cell.content.frame.height > 0 {
                cell.animateContentFrame(to: frame, duration: Self.heightAnimation, timing: Self.heightTiming)
            } else {
                cell.contentFrame = frame
            }
            (cell.content as? CardLineView)?.configure(line, geometry: geometry, env: env, state: content.state(id))
        case (.empty(let key), .frame(let frame, _)):
            cell.contentFrame = frame
            (cell.content as? EmptyLineView)?.configure(key, env: env, state: content.state(id))
        case (.fold(let fold), .frame(let frame, _)):
            cell.contentFrame = frame
            (cell.content as? FoldLineView)?.configure(fold, env: env, state: content.state(id))
        case (.dismissed(let card, let search), .dismissed(let geometry)):
            cell.contentFrame = CGRect(x: 12, y: 0, width: geometry.size.width, height: geometry.size.height)
            (cell.content as? DismissedLineView)?.configure(card, search: search, geometry: geometry, env: env, state: content.state(id))
        default:
            break
        }
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        lines.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < heights.count ? max(1, heights[row]) : 1
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < lines.count else { return nil }
        let kind = kind(lines[row])
        let cell: LineCell
        if let reused = tableView.makeView(withIdentifier: kind.identifier, owner: nil) as? LineCell {
            // The table may hand back a kept cell itself: it is not kept twice.
            spare[kind.identifier]?.removeAll { $0 === reused }
            cell = reused
        } else {
            cell = spare[kind.identifier]?.popLast() ?? makeCell(kind)
        }
        configure(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        // The insertion line stays over the lines.
        if !dropLine.isHidden { table.addSubview(dropLine, positioned: .above, relativeTo: nil) }
    }

    // MARK: Consistency (the measurement mode)

    /// What is wrong with the table as drawn, compared with the model:
    /// every row's height is the line's, the rows add up to the document's
    /// height, every row view in view sits at its row's rectangle, no two
    /// row views overlap, and each row view shows the line the model has at
    /// that index. Empty when all is well.
    func consistencyProblems() -> [String] {
        var problems: [String] = []
        let model = content.entries
        if table.numberOfRows != model.count {
            problems.append("table has \(table.numberOfRows) rows, the model \(model.count) lines")
        }
        let modelHeights = model.map { max(1, shape($0).height) }
        var total: CGFloat = 0
        for row in 0..<min(table.numberOfRows, model.count) {
            let rect = table.rect(ofRow: row)
            if abs(rect.minY - total) > 0.5 || abs(rect.height - modelHeights[row]) > 0.5 {
                problems.append(String(
                    format: "row %d (%@) at y %.1f height %.1f, expected y %.1f height %.1f",
                    row, model[row].id, rect.minY, rect.height, total, modelHeights[row]
                ))
                if problems.count > 8 { return problems }
            }
            total += modelHeights[row]
        }
        // The table fills the clip view when its rows are shorter.
        let document = max(total, scrollView.contentView.bounds.height)
        if abs(table.frame.height - document) > 0.5 {
            problems.append(String(format: "document height %.1f, rows add up to %.1f", table.frame.height, total))
        }
        // The row views on screen.
        let rowViews = table.subviews.compactMap { $0 as? NSTableRowView }.filter { !$0.isHidden }
        let visible = table.visibleRect
        for view in rowViews where view.frame.intersects(visible) {
            let row = table.row(for: view)
            guard row >= 0, row < model.count else {
                problems.append("a row view at \(NSStringFromRect(view.frame)) with no row")
                continue
            }
            if view.frame != table.rect(ofRow: row) {
                problems.append("row view \(row) (\(model[row].id)) at \(NSStringFromRect(view.frame)), its row at \(NSStringFromRect(table.rect(ofRow: row)))")
            }
            if let cell = view.view(atColumn: 0) as? LineCell {
                if cell.lineID != model[row].id {
                    problems.append("row \(row) shows \(cell.lineID ?? "nothing"), the model has \(model[row].id)")
                }
                if cell.isHidden || cell.superview !== view || abs(cell.frame.height - view.frame.height) > 0.5 {
                    problems.append("row \(row) (\(model[row].id)) cell frame \(NSStringFromRect(cell.frame)) in row view \(NSStringFromRect(view.frame))")
                }
            } else {
                problems.append("row view \(row) (\(model[row].id)) has no cell")
            }
        }
        let onScreen = rowViews.filter { $0.frame.intersects(visible) }.sorted { $0.frame.minY < $1.frame.minY }
        for (a, b) in zip(onScreen, onScreen.dropFirst()) where a.frame.maxY > b.frame.minY + 0.5 {
            problems.append("row views overlap: \(NSStringFromRect(a.frame)) and \(NSStringFromRect(b.frame))")
        }
        // What each line in view shows: its layer's image is the one it
        // would draw now (a line drawn for another card, or before a change,
        // differs), and a card sits under the heading of its group.
        for view in rowViews where view.frame.intersects(visible) {
            let row = table.row(for: view)
            guard row >= 0, row < model.count, let cell = view.view(atColumn: 0) as? LineCell,
                  let line = cell.content as? LineView else { continue }
            if let shown = line.layer?.contents, CFGetTypeID(shown as CFTypeRef) == CGImage.typeID,
               let fresh = line.renderImage(), let difference = ImageCompare.difference(shown as! CGImage, fresh), difference > 0.005 {
                problems.append(String(format: "row %d (%@) shows another image than it draws now (%.1f%% of its pixels differ)",
                                       row, model[row].id, difference * 100))
            }
            // A card of the Dismissed list sits under its repository.
            if let card = (line as? DismissedLineView)?.card {
                let heading = model[..<row].last { if case .heading = $0 { return true } else { return false } }
                if case .heading(let values)? = heading, values.title != Listing.repository(card.pr) {
                    problems.append("row \(row): \(Warnings.prLabel(card.pr)) under the repository \(values.title)")
                }
            }
            if let card = (line as? CardLineView)?.line?.card {
                let heading = model[..<row].last { if case .heading = $0 { return true } else { return false } }
                if case .heading(let values)? = heading,
                   let section = content.list.sections.first(where: { $0.key == values.key }), section.isLeaf,
                   !section.matching.contains(where: { $0.id == card.id }) {
                    problems.append("row \(row): \(Warnings.prLabel(card.pr)) under the heading \(values.title), not its group")
                }
            }
        }
        // Every row in view has its row view.
        let range = table.rows(in: visible)
        if range.length > 0 {
            for row in range.location..<(range.location + range.length) where table.rowView(atRow: row, makeIfNecessary: false) == nil {
                problems.append("row \(row) in view has no row view")
            }
        }
        return problems
    }

    /// The measurement mode: the width the lines are laid out in.
    var widthForMeasurement: CGFloat { width }

    /// The measurement mode: the height of the line `id`, nil when it is
    /// not in the list.
    func heightForMeasurement(line id: String) -> CGFloat? {
        applyIfNeeded()
        guard let row = rowOf[id] else { return nil }
        return table.rect(ofRow: row).height
    }

    /// The measurement mode: scrolls so the line `id` is `offset` points
    /// below the top of the list (negative: above).
    func scrollForMeasurement(toLine id: String, offset: CGFloat) {
        applyIfNeeded()
        guard let row = rowOf[id] else { return }
        let y = table.rect(ofRow: row).minY + offset
        let maxY = max(0, table.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, max(0, y))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Cards that hide while in view

    /// The line kept where it is on the screen through the next change, and
    /// its distance from the top of the list.
    private var anchor: (String, CGFloat)?

    /// Cards `Unread only` kept hide now (DESIGN.md, "Filter"): the
    /// selected item stays where it is on the screen if it is in view; else
    /// the first line in view does (the next one, when that is a card
    /// hiding). Called before the change; the next apply scrolls.
    func keepPlace(hiding cards: Set<String>) {
        applyIfNeeded()
        let visible = scrollView.contentView.bounds
        let hiding = Set(cards.map { "card:" + $0 })
        var chosen: Int?
        if let selection = content.list.selection, let row = rowOf[ListEntry.id(of: selection)], row < lines.count,
           table.rect(ofRow: row).intersects(visible), !hiding.contains(lines[row].id) {
            chosen = row
        }
        if chosen == nil {
            let range = table.rows(in: visible)
            if range.length > 0 {
                chosen = (range.location..<(range.location + range.length)).first { !hiding.contains(lines[$0].id) }
            }
        }
        guard let row = chosen else { return }
        anchor = (lines[row].id, table.rect(ofRow: row).minY - visible.minY)
    }

    /// The measurement mode: the first line in view and its distance from
    /// the top of the list (negative: partly above).
    func topLineForMeasurement() -> (String, CGFloat)? {
        applyIfNeeded()
        let visible = scrollView.contentView.bounds
        let range = table.rows(in: visible)
        guard range.length > 0, range.location < lines.count else { return nil }
        return (lines[range.location].id, table.rect(ofRow: range.location).minY - visible.minY)
    }

    /// The measurement mode: where a line is, from the top of the list.
    func offsetForMeasurement(ofLine id: String) -> CGFloat? {
        applyIfNeeded()
        guard let row = rowOf[id], row < table.numberOfRows else { return nil }
        return table.rect(ofRow: row).minY - scrollView.contentView.bounds.minY
    }

    // MARK: The insertion line

    private func placeDropLine() {
        guard let (card, edge) = content.dropLine, let row = rowOf["card:" + card], row < table.numberOfRows,
              case .card(let line) = lines[row] else {
            dropLine.isHidden = true
            return
        }
        // `rect(ofRow:)` is in the table's coordinates, which are flipped
        // (top down): the card is at the top of its line, with 8 points under
        // it. The line is centered on the 8-point gap above or below the
        // card and starts 3 points left of it.
        let rect = table.rect(ofRow: row)
        let left = (line.indented ? 24 : 12) - 3.0
        // Over the first line of the list (a card with no heading above
        // it) the gap above is not in the list: the line goes just inside
        // its top edge, where it can be seen.
        let center = edge == .top ? max(4, rect.minY - 4) : rect.maxY - 4
        dropLine.frame = NSRect(x: left, y: center - 4, width: rect.width - left - 12, height: 8)
        dropLine.isHidden = false
        dropLine.needsDisplay = true
        table.addSubview(dropLine, positioned: .above, relativeTo: nil)
    }

    // MARK: Scrolling to the selection

    /// Scrolls the least that shows `item`: its card (or line), or, when
    /// the card is taller than the list, the item itself.
    func reveal(_ item: SelectionItem) {
        applyIfNeeded()
        guard let row = rowOf[ListEntry.id(of: item)], row < table.numberOfRows else { return }
        var target = table.rect(ofRow: row)
        if case .card = lines[row] { target.size.height -= 8 }
        let clip = scrollView.contentView
        if target.height > clip.bounds.height {
            if let rect = context.drag.rect(of: item, in: table) {
                target = rect
            } else if case .card(let geometry) = shape(lines[row]) {
                target = itemRect(item, in: geometry, row: target)
            }
        }
        scroll(toShow: target)
    }

    /// Where `item` is in a card line at `row` (table coordinates).
    private func itemRect(_ item: SelectionItem, in geometry: CardGeometry, row: CGRect) -> CGRect {
        var local = geometry.header
        switch item {
        case .row(let id, _):
            if let frame = geometry.rows.first(where: { $0.id == id })?.frame { local = frame }
        case .moreRows, .olderActivity, .lessRows:
            if let frame = geometry.feet.first(where: { $0.item == item })?.frame { local = frame }
        default:
            break
        }
        return local.offsetBy(dx: row.minX, dy: row.minY)
    }

    private func scroll(toShow rect: NSRect) {
        let clip = scrollView.contentView
        let visible = clip.bounds
        var y = visible.origin.y
        if rect.height > visible.height || rect.minY < visible.minY {
            y = rect.minY
        } else if rect.maxY > visible.maxY {
            y = rect.maxY - visible.height
        }
        let maxY = max(0, table.frame.height - visible.height)
        y = min(maxY, max(0, y))
        guard y != visible.origin.y else { return }
        clip.scroll(to: NSPoint(x: visible.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        if rowViewsMisplaced("reveal") { reload() }
    }
}

