// The tooltip comparison of docs/tasks/M7.md (step 3): how long a tooltip
// takes to show for a standard NSButton (`toolTip`), a SwiftUI button with
// `.help`, and a SwiftUI text with `.help` under the press view of a card,
// in the same app and window. Run with `SHIIBAR_GH_PERF=tooltips` (and
// `SHIIBAR_GH_STATE_DIR`, as every measurement); it moves the pointer
// (`CGWarpMouseCursorPosition`) over each item in turn, sends the app a
// mouse-moved event there, and watches the app's windows for the tooltip
// window, then prints the times and quits.

import AppKit
import ShiibarGhCore
import SwiftUI

@MainActor
final class TooltipProbe {
    private var window: NSWindow?

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["SHIIBAR_GH_PERF"] == "tooltips"
    }

    func start() {
        let host = NSHostingView(rootView: TooltipProbeView())
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 160), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.isReleasedWhenClosed = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        Task { await run() }
    }

    private func log(_ text: String) {
        print(text)
        fflush(stdout)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for sub in view.subviews { if let found = find(id, in: sub) { return found } }
        return nil
    }

    private func toolTipWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).localizedCaseInsensitiveContains("tooltip") }
    }

    private func run() async {
        await pause(1.5)
        guard let window, let content = window.contentView else { return }
        log("tooltip probe: windows before: \(NSApp.windows.map { String(describing: type(of: $0)) })")
        // Points of the three items, by the probe view's layout (rows 40 pt
        // apart from the top).
        let items: [(String, CGFloat)] = [("NSButton toolTip", 30), ("SwiftUI Button .help", 75), ("SwiftUI Text .help under a press view", 120)]
        var lines: [String] = []
        for (name, y) in items {
            for attempt in 1...3 {
                // Away from every item first, then onto the item.
                await moveTo(window: window, point: NSPoint(x: 400, y: content.bounds.height - 150))
                await pause(1.5)
                let point = NSPoint(x: 60, y: content.bounds.height - y)
                let start = CFAbsoluteTimeGetCurrent()
                await moveTo(window: window, point: point)
                var shown: Double?
                while CFAbsoluteTimeGetCurrent() - start < 6 {
                    if !toolTipWindows().isEmpty {
                        shown = (CFAbsoluteTimeGetCurrent() - start) * 1000
                        break
                    }
                    await pause(0.01)
                }
                let text = shown.map { String(format: "%.0f ms", $0) } ?? "no tooltip window within 6 s"
                lines.append("\(name), try \(attempt): \(text)")
                log("tooltip probe: \(name), try \(attempt): \(text)")
            }
        }
        log("tooltip probe: windows after: \(NSApp.windows.map { String(describing: type(of: $0)) })")
        log(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// The pointer onto `point` of the window: the cursor is warped there
    /// and the app gets a mouse-moved event at that place.
    private func moveTo(window: NSWindow, point: NSPoint) async {
        let screenPoint = window.convertPoint(toScreen: point)
        // Quartz display coordinates: the origin is the top left of the main
        // display.
        let height = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: height - screenPoint.y))
        if let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) {
            NSApp.postEvent(event, atStart: false)
        }
        await pause(0.05)
    }
}

struct TooltipProbeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppKitButton()
                .frame(width: 120, height: 24)
            Button("SwiftUI .help") {}
                .help("SwiftUI help")
                .frame(height: 24)
            Text("Text .help, press view over it")
                .help("SwiftUI text help")
                .frame(height: 24)
                .overlay(PassThroughView())
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AppKitButton: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "NSButton", target: nil, action: nil)
        button.toolTip = "AppKit toolTip"
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {}
}

/// Like the press view of a card: takes mouse downs, passes the rest on.
private struct PassThroughView: NSViewRepresentable {
    final class View: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .leftMouseDown ? super.hitTest(point) : nil
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}
