// The app entry point: an accessory app (no Dock icon) with menu bar icons
// only. Info.plist sets LSUIElement for the bundle.

import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        application.run()
    }
}
