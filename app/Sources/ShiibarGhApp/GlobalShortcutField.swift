// The Global shortcut field of Settings › Accounts › an account (DESIGN.md,
// "Global shortcut field"; Settings.html `.gsk`). It shows what
// `GlobalShortcutCenter` decides and forwards the input; it decides nothing
// itself. While it records, a local event monitor takes every key press
// before Settings' other shortcuts (⌘W, ⌘, …) and the focused view; a press
// of the mouse outside the field, Settings no longer key, or the field
// leaving its window cancels the recording.

import AppKit
import ShiibarGhCore
import SwiftUI

struct GlobalShortcutField: View {
    @ObservedObject var center: GlobalShortcutCenter
    var account: String

    static let label = "Global shortcut"
    static let clearLabel = "Clear shortcut"
    /// DESIGN.md, "Constants": Settings does not follow the text size.
    static let height: CGFloat = 22
    static let minimumWidth: CGFloat = 120
    static let maximumWidth: CGFloat = 240
    static let radius: CGFloat = 6
    static let side: CGFloat = 8
    static let clearSize: CGFloat = 12

    var body: some View {
        let recording = center.isRecording(account)
        let text = center.fieldText(account)
        let placeholder = recording || center.active[account] == nil
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(placeholder ? Palette.secondary.color : Palette.text.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
            if center.showsClear(account) {
                // Keeps the ×'s room; the live button is above the press
                // view (below).
                clearButton.hidden()
            }
        }
        .padding(.horizontal, Self.side)
        .frame(minWidth: Self.minimumWidth, maxWidth: Self.maximumWidth, minHeight: Self.height, maxHeight: Self.height)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: Self.radius).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(recording ? Palette.accent.color : Palette.border.color, lineWidth: recording ? 2 : 1)
        )
        .overlay(ShortcutFieldInput(center: center, account: account, recording: recording))
        .overlay(alignment: .trailing) {
            if center.showsClear(account) { clearButton.padding(.trailing, Self.side) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.label)
        .accessibilityValue(text)
    }

    private var clearButton: some View {
        Button { center.clear(account) } label: {
            ZStack {
                Circle().fill(Palette.secondary.color)
                IconView(icon: BoardIcons.clearSearch, size: Self.clearSize, color: .white)
            }
            .frame(width: Self.clearSize, height: Self.clearSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .quickHelp(Self.clearLabel)
        .accessibilityLabel(Self.clearLabel)
    }
}

/// The field's input: a press anywhere on it (the × sits above) and, while
/// recording, the event monitors. Its frame is the field's, which tells a
/// press inside from one outside.
private struct ShortcutFieldInput: NSViewRepresentable {
    let center: GlobalShortcutCenter
    let account: String
    let recording: Bool

    func makeNSView(context: Context) -> ShortcutFieldInputView { ShortcutFieldInputView() }

    func updateNSView(_ view: ShortcutFieldInputView, context: Context) {
        view.center = center
        view.account = account
        view.setRecording(recording)
    }

    static func dismantleNSView(_ view: ShortcutFieldInputView, coordinator: ()) {
        view.stop(cancelling: true)
    }
}

final class ShortcutFieldInputView: NSView {
    weak var center: GlobalShortcutCenter?
    var account = ""
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// The first press on Settings out of focus reaches the field too.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        center?.fieldClicked(account)
    }

    func setRecording(_ recording: Bool) {
        if recording { start() } else { stop(cancelling: false) }
    }

    private func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let center = self.center, event.window === self.window else { return event }
            center.keyPressed(
                keyCode: event.keyCode, modifiers: CarbonHotKeyRegistrar.modifiers(of: event.modifierFlags),
                keyName: CarbonHotKeyRegistrar.keyName(of: event)
            )
            return nil
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if !self.contains(event) { self.center?.abandonRecording() }
            return event
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.center?.abandonRecording() }
            }
        }
    }

    func stop(cancelling: Bool) {
        let wasRecording = keyMonitor != nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        mouseMonitor = nil
        resignObserver = nil
        if cancelling && wasRecording, center?.isRecording(account) == true { center?.abandonRecording() }
    }

    private func contains(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stop(cancelling: true) }
    }
}
