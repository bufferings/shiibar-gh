// The app entry point: an accessory app (no Dock icon) with menu bar icons
// only. Info.plist sets LSUIElement for the bundle.
//
// `--unregister-login-item` unregisters the login item and exits; the
// uninstall script uses it, because SMAppService.mainApp can only be
// unregistered from inside the bundle.

import AppKit
import ServiceManagement

if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        application.run()
    }
}
