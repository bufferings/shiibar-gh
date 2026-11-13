// Text the mouse can select in cards and rows (DESIGN.md, "What a press
// does"): the title, owner/repo #number and a row's body. A click selects
// the card or row, a double click a word, a drag a range; ⌘C and the menu's
// Copy copy it.
//
// An AppKit text view, not SwiftUI's `.textSelection(.enabled)`: the app
// must know whether text is selected (Copy in the menu, ⌘C) and clear it
// when another item is selected, and SwiftUI's `Text` gives neither (in the
// macOS 27 SDK, `TextSelection` binds only to TextField and TextEditor;
// `Text` has only `textSelection(_:)` with enabled or disabled).

import AppKit
import ShiibarGhCore
import SwiftUI

/// The selectable text views of one surface: which has a selection, and
/// clearing them.
@MainActor
final class TextSelectionCoordinator: TextSelecting {
    private let views = NSHashTable<SelectableTextView>.weakObjects()
    /// Edit › Copy with no text selected: what ⌘C does (the link of the
    /// selected card or row).
    var copyWithoutSelection: (() -> Void)?

    /// The coordinator of the surface, made on first use.
    static func of(_ list: SurfaceListModel) -> TextSelectionCoordinator {
        if let coordinator = list.textSelection as? TextSelectionCoordinator { return coordinator }
        let coordinator = TextSelectionCoordinator()
        coordinator.copyWithoutSelection = { [weak list] in list?.press(.copy) }
        list.textSelection = coordinator
        return coordinator
    }

    func register(_ view: SelectableTextView) {
        views.add(view)
    }

    var selectedText: String? {
        for view in views.allObjects {
            let range = view.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= (view.string as NSString).length else { continue }
            return (view.string as NSString).substring(with: range)
        }
        return nil
    }

    func clearSelection() {
        for view in views.allObjects { view.clearSelection() }
    }

    /// A press in `view` starts a selection there: the others drop theirs,
    /// so one range is selected at a time.
    func began(in view: SelectableTextView) {
        for other in views.allObjects where other !== view { other.clearSelection() }
    }
}

/// A non-editable, selectable NSTextView sized by its text, with TextKit 1
/// for the line limit and the tail truncation of a label.
final class SelectableTextView: NSTextView {
    /// Selects the card or row the text belongs to.
    var press: (() -> Void)?
    weak var coordinator: TextSelectionCoordinator?

    init(lineLimit: Int) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        setLineLimit(lineLimit)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setLineLimit(_ lines: Int) {
        guard let container = textContainer else { return }
        container.maximumNumberOfLines = lines
        container.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    }

    func clearSelection() {
        let range = selectedRange()
        if range.length > 0 { setSelectedRange(NSRange(location: range.location, length: 0)) }
    }

    /// The size the text takes at most `width` wide.
    func fit(width: CGFloat?) -> CGSize {
        guard let container = textContainer, let layout = layoutManager else { return .zero }
        let saved = container.size
        let limit = width.map { max($0, 1) } ?? CGFloat.greatestFiniteMagnitude
        container.size = NSSize(width: limit, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        var used = layout.usedRect(for: container)
        container.size = saved
        if string.isEmpty, let font {
            used.size.height = layout.defaultLineHeight(for: font)
        }
        return CGSize(width: ceil(min(used.width, limit)), height: ceil(used.height))
    }

    /// Edit › Copy reaches this view while it has the focus: the selected
    /// text as NSTextView copies it, or, with nothing selected, what ⌘C
    /// does in the popover (DESIGN.md, "Keyboard").
    override func copy(_ sender: Any?) {
        if selectedRange().length > 0 {
            super.copy(sender)
        } else {
            coordinator?.copyWithoutSelection?()
        }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return true }
        return super.validateMenuItem(item)
    }

    override func mouseDown(with event: NSEvent) {
        // The press selects the item first; selecting another item clears
        // every selection, then this view's tracking selects a word or a
        // range (or nothing, for a plain click).
        press?()
        coordinator?.began(in: self)
        super.mouseDown(with: event)
    }
}

struct SelectableText: NSViewRepresentable {
    var text: String
    var font: NSFont
    var color: NSColor
    /// 0 for no limit.
    var lineLimit: Int
    var coordinator: TextSelectionCoordinator
    var press: () -> Void

    func makeNSView(context: Context) -> SelectableTextView {
        let view = SelectableTextView(lineLimit: lineLimit)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        update(view)
        return view
    }

    func updateNSView(_ view: SelectableTextView, context: Context) {
        update(view)
    }

    private func update(_ view: SelectableTextView) {
        view.press = press
        view.coordinator = coordinator
        coordinator.register(view)
        if view.font != font { view.font = font }
        if view.textColor != color { view.textColor = color }
        if view.textContainer?.maximumNumberOfLines != lineLimit { view.setLineLimit(lineLimit) }
        if view.string != text {
            view.string = text
            view.font = font
            view.textColor = color
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return nsView.fit(width: width)
    }
}

extension NSFont {
    /// The NSFont of `.system(size:weight:)`.
    static func board(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}
