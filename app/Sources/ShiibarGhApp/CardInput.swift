// Presses on cards, rows and headings (DESIGN.md, "What a press does"):
// the view of each card, heading, "+ N more PRs" line and empty section
// (ListCells.swift, a `PressView`) takes the mouse, except over the
// controls inside, which keep their own click.
//
// - A click selects at once (`mouseDown`, click count 1); a click whose
//   count is 2 or more opens only when the series began on the same
//   heading or row (`ClickClassifier` in ShiibarGhCore). `NSEvent.clickCount`
//   is the count of the click series the system tracks (NSEvent.h,
//   "clickCount").
// - A control (a subview) takes the first click of a series; the view takes
//   the later ones over a control (from its `hitTest(_:)`, which reads
//   `NSApp.currentEvent`) and does nothing with them, so a double click on a
//   control acts once and opens nothing.
// - In Review and Mine a card is dragged from anywhere but its controls:
//   past `CardDragController.threshold` points the drag starts. The app
//   follows the pointer itself (a local event monitor for the dragged and
//   up events, NSEvent.h `addLocalMonitorForEvents`), shows the card's
//   heading under the pointer in a borderless child window, and scrolls the
//   list near its top and bottom edges. No AppKit drag session: the card
//   never leaves the app, and the drop places it from the views under the
//   pointer.
// - ⌘-click and ⇧-click change the selected cards; a click on the list's
//   empty part clears the selection (ListTable.swift).
// - A right click or a Control click selects and shows the menu; on one of
//   several selected cards, the menu for all of them.

import AppKit
import ShiibarGhCore
import SwiftUI

/// Where the rows and controls of one card or heading are, in its own
/// coordinates. Written by the line view as it lays itself out; read by the
/// press view.
@MainActor
final class CardRegions {
    var controls: [String: CGRect] = [:]
    var items: [ItemRegion: CGRect] = [:]

    func control(at point: CGPoint) -> String? {
        controls.first { $0.value.contains(point) }?.key
    }

    func item(at point: CGPoint) -> ItemRegion? {
        items.first { $0.value.contains(point) }?.key
    }
}

enum ItemRegion: Hashable {
    case row(String)
    /// "+ N more", `Older activity on GitHub` or `Show less` in a card.
    case footer(SelectionItem)
}

/// What a press view is over.
enum PressKind {
    /// A card; `section` is nil in the Dismissed list.
    case card(Card, section: String?, canDrag: Bool)
    case heading(String)
    /// "+ N more PRs" or `Show less` of a section.
    case fold(String)
    /// The frame of an empty Review or Mine section.
    case empty(String)
}

/// A card, heading, "+ N more PRs" line or empty section that takes
/// presses (the line views of ListCells.swift).
class PressView: NSView {
    var kind: PressKind = .empty("")
    var regions = CardRegions()
    var context: CardContext?
    private var pressedAt: NSPoint?
    private var pressedItem: SelectionItem?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { context?.drag.register(self) }
    }

    private var list: SurfaceListModel? { context?.list }

    private var isCard: Bool {
        if case .card = kind { return true }
        return false
    }

    /// The mouse-down events this view takes: everything but the first
    /// click of a series on a control, which goes to the control.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown:
            if event.modifierFlags.contains(.control) { return isCard ? self : nil }
            if let control = regions.control(at: local), event.clickCount <= 1 {
                list?.click(.control(controlId(control)), count: 1)
                return super.hitTest(point)
            }
            if case .empty = kind { return nil }
            return self
        case .rightMouseDown:
            return isCard ? self : nil
        default:
            return super.hitTest(point)
        }
    }

    private func controlId(_ control: String) -> String {
        switch kind {
        case .card(let card, _, _): return card.id + "|" + control
        case .heading(let key), .fold(let key), .empty(let key): return key + "|" + control
        }
    }

    /// The item of the card under `local`: a row, a footer, else the
    /// heading.
    private func item(at local: CGPoint) -> (SelectionItem, footer: Bool)? {
        guard case .card(let card, _, _) = kind else { return nil }
        switch regions.item(at: local) {
        case .row(let id)?: return (.row(id: id, card: card.id), false)
        case .footer(let item)?: return (item, true)
        case nil: return (.header(card: card.id), false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let list else { return }
        if event.modifierFlags.contains(.control) {
            showMenu(event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        let count = event.clickCount
        if let control = regions.control(at: local) {
            // A later click of a series on a control: nothing.
            list.click(.control(controlId(control)), count: count)
            return
        }
        switch kind {
        case .card(let card, let section, let canDrag):
            guard let (item, footer) = item(at: local) else { return }
            if footer {
                // "+ N more" and `Older activity on GitHub` are controls.
                if list.click(.control(card.id + "|" + item.id), count: count) {
                    list.select(item)
                    if let action = PopoverLogic.action(for: .open, selection: item, view: list.view) { list.perform(action) }
                }
                return
            }
            // ⌘-click and ⇧-click (DESIGN.md, "Selection"): the card in or
            // out of the selection, or the range from the anchor.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) || flags.contains(.shift) {
                list.click(card: card.id, extent: flags.contains(.command) ? .toggle : .range)
                return
            }
            // A press on one of several selected cards may start dragging
            // them all: the click selects it alone only on release, if no
            // drag started.
            // What waits for the release is the core's (`CardPress`).
            let draggable = count == 1 && canDrag && list.canDrag(card.id)
            list.pressDown(item, count: count, draggable: draggable)
            // Past the threshold the core decides (`dragStart`): a drag, or
            // in All the hint that it is sorted by itself.
            if count == 1 && section != nil {
                pressedAt = event.locationInWindow
                pressedItem = item
            }
        case .heading(let key):
            if list.click(.control(key + "|heading"), count: count) {
                list.select(.section(key))
                list.perform(.toggleSection(key))
            }
        case .fold(let key):
            if list.click(.control(key + "|fold"), count: count) {
                list.select(.more(key))
                list.perform(.toggleMore(key))
            }
        case .empty:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, case .card(let card, _, _) = kind, let drag = context?.drag else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) >= CardDragController.threshold else { return }
        pressedAt = nil
        guard let list else { return }
        switch list.dragStart(card: card.id) {
        case .drag:
            drag.begin(card: card, from: self, pressedAt: start, at: point)
        case .hint(let text):
            // Near the pointer, as `Copied` is shown beside its icon;
            // hidden by the next press, scroll or key (QuickTip).
            let pointer = NSEvent.mouseLocation
            QuickTip.bubble(text, beside: NSRect(x: pointer.x + 8, y: pointer.y - 8, width: 0, height: 16),
                            seconds: CardDragController.hintSeconds, appearance: effectiveAppearance)
        case .nothing:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        pressedAt = nil
        pressedItem = nil
        list?.pressUp()
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(event)
    }

    private func showMenu(_ event: NSEvent) {
        guard let list, let (item, _) = item(at: convert(event.locationInWindow, from: nil)) else { return }
        let entries = list.rightClick(item)
        guard !entries.isEmpty else { return }
        let items: [IconMenuItem?] = entries.map { entry in
            entry.map { entry in IconMenuItem(entry.title) { [weak list] in list?.perform(entry.action) } }
        }
        // A card `Unread only` kept does not hide under the menu.
        list.menuOpened()
        NSMenu.popUpContextMenu(IconMenu.make(items), with: event, for: self)
        list.menuClosed()
    }

    /// Where `item` is in this view, if it is here.
    func rect(of item: SelectionItem) -> CGRect? {
        switch (kind, item) {
        case (.heading(let key), .section(let other)) where key == other:
            return bounds
        case (.fold(let key), .more(let other)) where key == other:
            return bounds
        case (.card(let card, _, _), _):
            guard item.inCard(card.id) != nil else { return nil }
            switch item {
            case .row(let id, _): return regions.items[.row(id)]
            case .moreRows, .olderActivity, .lessRows: return regions.items[.footer(item)]
            default:
                // The heading: above the first row or footer.
                let top = regions.items.values.map(\.minY).min() ?? bounds.maxY
                return CGRect(x: 0, y: 0, width: bounds.width, height: top)
            }
        default:
            return nil
        }
    }

    /// Where a card dropped at `local` lands.
    func zone(at local: CGPoint) -> DropZone? {
        switch kind {
        case .card(let card, let section, _):
            guard section != nil else { return nil }
            return .card(card.id, lowerHalf: local.y > bounds.height / 2)
        case .heading(let key), .empty(let key):
            return .header(key)
        case .fold(let key):
            return .more(key)
        }
    }
}

/// A card drag of one surface: the pointer, the picture under it, the
/// landing place and the automatic scroll near the list's edges
/// (DESIGN.md, "What a press does" and "Constants").
@MainActor
final class CardDragController: NSObject {
    /// How far the pointer moves with the button down before a drag starts.
    static let threshold: CGFloat = 4
    /// How long the hint of a drag in All shows.
    static let hintSeconds: TimeInterval = 2
    /// The bands at the top and bottom of the list where a drag scrolls:
    /// 40 points at text size 12 (DESIGN.md, "Constants").
    static let band: CGFloat = 40
    /// The scroll speed at the very edge, in points a second; it falls
    /// linearly to a tenth at the inner side of the band.
    static let maxSpeed: CGFloat = 1200

    unowned let list: SurfaceListModel
    weak var scrollView: NSScrollView?
    /// The text scale (text size / 12).
    var scale: CGFloat = 1
    private let zones = NSHashTable<PressView>.weakObjects()
    private var ghost: NSWindow?
    private var grab = CGPoint.zero
    private var lastPoint: NSPoint?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// The measurement mode holds the pointer still in a band.
    private var programmatic = false

    private init(list: SurfaceListModel) {
        self.list = list
    }

    private static var controllers: [ObjectIdentifier: CardDragController] = [:]

    static func of(_ list: SurfaceListModel) -> CardDragController {
        if let controller = controllers[ObjectIdentifier(list)] { return controller }
        let controller = CardDragController(list: list)
        controllers[ObjectIdentifier(list)] = controller
        return controller
    }

    var isActive: Bool { list.dragging != nil }

    /// The event monitor of a drag is installed (the measurement mode's
    /// check: none is left once a drag ends).
    var monitorInstalled: Bool { monitor != nil }

    override var debugDescription: String {
        let views = zones.allObjects.filter { $0.window != nil }
        let controls = views.map(\.regions.controls.count).reduce(0, +)
        let items = views.map(\.regions.items.count).reduce(0, +)
        return "scroll view \(scrollView != nil), press views \(zones.allObjects.count), in a window \(views.count), "
            + "control frames \(controls), row frames \(items)"
    }

    func register(_ view: PressView) {
        zones.add(view)
    }

    /// Whether the item is wholly in the list's visible part (no scroll is
    /// needed to show it).
    func isVisible(_ item: SelectionItem) -> Bool {
        guard let scrollView else { return false }
        let clip = scrollView.contentView
        let visible = clip.convert(clip.bounds, to: nil)
        for view in shownViews {
            guard let rect = view.rect(of: item) else { continue }
            return visible.contains(view.convert(rect, to: nil).insetBy(dx: 1, dy: 1))
        }
        return false
    }

    /// Where `item` is in `view`'s coordinates, while the line that has it
    /// is made.
    func rect(of item: SelectionItem, in view: NSView) -> CGRect? {
        for press in shownViews {
            guard let rect = press.rect(of: item) else { continue }
            return press.convert(rect, to: view)
        }
        return nil
    }

    /// The press views of the lines shown: a table keeps the views of lines
    /// out of view for reuse, hidden or out of the window.
    private var shownViews: [PressView] {
        zones.allObjects.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
    }

    // MARK: The drag

    func begin(card: Card, from view: PressView, pressedAt start: NSPoint, at point: NSPoint) {
        guard let window = view.window else { return }
        // A drag the list ended without us (the list changed under it):
        // its monitor, picture and scroll go first.
        if monitor != nil { finish() }
        self.window = window
        list.beginDrag(card.id)
        let local = view.convert(start, from: nil)
        grab = CGPoint(x: local.x, y: min(local.y, 40 * scale))
        showGhost(card, width: view.bounds.width, over: window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            guard self.isActive else {
                // The list ended the drag: the monitor and the picture go.
                DispatchQueue.main.async { [weak self] in if self?.isActive == false { self?.finish() } }
                return event
            }
            switch event.type {
            case .leftMouseDragged:
                self.move(to: event.locationInWindow)
            case .leftMouseUp:
                self.end(at: event.locationInWindow)
            case .keyDown where event.keyCode == KeyPress.escape:
                self.cancel()
            default:
                return event
            }
            return nil
        }
        startScrolling()
        move(to: point)
    }

    func move(to point: NSPoint) {
        lastPoint = point
        moveGhost(to: point)
        guard let window else { return }
        if !insideList(point) {
            list.dragOver(nil)
            return
        }
        let zone = zone(at: point, in: window)
        if let zone {
            list.dragOver(zone)
        }
        // Over a gap between cards: the line stays where it was.
    }

    func end(at point: NSPoint) {
        let zone = window.flatMap { insideList(point) ? self.zone(at: point, in: $0) ?? lastZone() : nil }
        finish()
        list.drop(zone)
    }

    func cancel() {
        finish()
        list.endDrag()
    }

    private func lastZone() -> DropZone? {
        // Released over a gap: where the line is.
        guard let target = list.dropTarget else { return nil }
        switch target.position {
        case .before(let id): return .card(id, lowerHalf: false)
        case .top, .byDefault: return .header(target.section)
        case .bottom: return .more(target.section)
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stopScrolling()
        if let ghost {
            ghost.parent?.removeChildWindow(ghost)
            ghost.orderOut(nil)
        }
        ghost = nil
        lastPoint = nil
        programmatic = false
    }

    private func insideList(_ point: NSPoint) -> Bool {
        guard let scrollView else { return true }
        return scrollView.convert(scrollView.bounds, to: nil).contains(point)
    }

    private func zone(at point: NSPoint, in window: NSWindow) -> DropZone? {
        for view in shownViews where view.window === window {
            let local = view.convert(point, from: nil)
            if view.bounds.contains(local), let zone = view.zone(at: local) { return zone }
        }
        return nil
    }

    // MARK: The picture under the pointer

    private func showGhost(_ card: Card, width: CGFloat, over window: NSWindow) {
        let preview = CardDragPreview(card: card, count: list.draggingCount, width: max(width, 200), k: scale)
        let host = NSHostingView(rootView: preview)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let ghost = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = true
        ghost.ignoresMouseEvents = true
        ghost.alphaValue = 0.92
        ghost.appearance = window.effectiveAppearance
        ghost.contentView = host
        window.addChildWindow(ghost, ordered: .above)
        self.ghost = ghost
    }

    private func moveGhost(to point: NSPoint) {
        guard let ghost, let window else { return }
        let screen = window.convertPoint(toScreen: point)
        // `grab` is from the card's top left (flipped); the window origin is
        // its bottom left.
        ghost.setFrameOrigin(NSPoint(x: screen.x - grab.x, y: screen.y + grab.y - ghost.frame.height))
    }

    // MARK: Automatic scroll

    private func startScrolling() {
        guard let scrollView, link == nil else { return }
        let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = CACurrentMediaTime()
    }

    private func stopScrolling() {
        link?.invalidate()
        link = nil
    }

    /// The scroll speed for a pointer `distance` points inside an edge, nil
    /// outside the band: faster closer to the edge.
    static func speed(distance: CGFloat, band: CGFloat) -> CGFloat? {
        guard distance >= 0, distance < band else { return nil }
        return maxSpeed * max(0.1, 1 - distance / band)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let elapsed = min(now - lastTick, 0.1)
        lastTick = now
        guard let scrollView, let point = lastPoint else { return }
        let frame = scrollView.convert(scrollView.bounds, to: nil)
        guard frame.minX <= point.x, point.x <= frame.maxX else { return }
        let band = Self.band * scale
        var delta: CGFloat = 0
        if let speed = Self.speed(distance: frame.maxY - point.y, band: band) {
            delta = -speed * CGFloat(elapsed)
        } else if let speed = Self.speed(distance: point.y - frame.minY, band: band) {
            delta = speed * CGFloat(elapsed)
        }
        guard delta != 0, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        // `delta` is down the list; in an unflipped document, down is a
        // smaller y.
        let down = document.isFlipped ? delta : -delta
        let y = min(maxY, max(0, clip.bounds.origin.y + down))
        guard y != clip.bounds.origin.y else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        move(to: point)
    }

    // MARK: The measurement mode

    /// A drag of `card` held still in the list's bottom band (Perf.swift).
    func hoverForMeasurement(card: String) {
        guard let scrollView, let window = scrollView.window else { return }
        self.window = window
        list.beginDrag(card)
        programmatic = true
        let frame = scrollView.convert(scrollView.bounds, to: nil)
        lastPoint = NSPoint(x: frame.midX, y: frame.minY + 8)
        startScrolling()
    }

    func endMeasurement() {
        finish()
        list.endDrag()
    }

    /// The measurement mode: where, in window coordinates, the pointer is
    /// over `zone`, in a view shown and wholly or partly in the list's
    /// visible part.
    func pointForMeasurement(_ zone: DropZone) -> NSPoint? {
        guard let scrollView else { return nil }
        let visible = scrollView.convert(scrollView.bounds, to: nil).insetBy(dx: 0, dy: Self.band * scale + 2)
        for view in shownViews {
            for y in stride(from: CGFloat(6), to: view.bounds.height, by: 12) {
                let local = CGPoint(x: min(60, view.bounds.midX), y: y)
                let point = view.convert(local, to: nil)
                if visible.contains(point), view.zone(at: local) == zone { return point }
            }
        }
        return nil
    }

    /// The measurement mode: a press on the card's heading that moves past
    /// the threshold, as `PressView` starts a drag.
    func beginForMeasurement(card id: String) -> NSPoint? {
        for view in shownViews {
            guard case .card(let card, _, _) = view.kind, card.id == id else { continue }
            let start = view.convert(CGPoint(x: 60, y: 12), to: nil)
            let point = NSPoint(x: start.x, y: start.y - 6)
            begin(card: card, from: view, pressedAt: start, at: point)
            return point
        }
        return nil
    }

    /// The measurement mode: the pointer moved or released.
    func moveForMeasurement(to point: NSPoint) {
        move(to: point)
    }

    func endForMeasurement(at point: NSPoint) {
        end(at: point)
    }

    func cancelForMeasurement() {
        cancel()
    }

    /// The list's visible part, in window coordinates.
    var visibleForMeasurement: NSRect? {
        scrollView.map { $0.convert($0.bounds, to: nil) }
    }
}
