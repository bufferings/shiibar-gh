// Wires the core to AppKit: the daemon supervisor, the menu bar and its
// popovers and windows, Settings, notifications and Launch at login.
// Quitting (the ⌄ menu's Quit or ⌘Q) shuts the daemon down first
// (docs/tasks/M3.md, "Daemon lifecycle").

import AppKit
import ShiibarGhCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var supervisor: DaemonSupervisor?
    private var model: AppModel!
    private var surfaces: SurfaceController!
    private var settings: SettingsModel!
    private var settingsWindow: NSWindow?
    private var launch: LaunchAtLogin?
    private var presenter: UserNotificationPresenter?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Edit menu's key equivalents make ⌘V and the other text
        // shortcuts work in every text field (see MainMenu).
        NSApp.mainMenu = MainMenu.make(MainMenu.Actions(
            about: { [weak self] in self?.about() },
            settings: { [weak self] in self?.showSettings(.general) }
        ))
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
        let root = StateDirectory.root() ?? NSTemporaryDirectory()
        let socket = StateDirectory.socket(root: root)
        let api = SocketDaemonAPI(socketPath: socket)
        let notifier: NotificationPresenting
        if bundled && Bundle.main.bundleIdentifier != nil {
            let presenter = UserNotificationPresenter()
            presenter.start()
            self.presenter = presenter
            notifier = presenter
        } else {
            notifier = NoNotifications()
        }
        let store = UIStateStore(defaults: .standard)
        model = AppModel(api: api, store: store, opener: WorkspaceOpener(), notifier: notifier)
        let avatars = AvatarStore(loader: URLSessionImageLoader())
        surfaces = SurfaceController(app: model, avatars: avatars) { [weak self] scope in
            SurfaceActions(
                openWindow: scope.map { id in { self?.surfaces.openWindow(scope: id) } },
                openSettings: { destination in self?.showSettings(destination == .scopes ? .scopes : .general) },
                about: { self?.about() },
                quit: { self?.quit() }
            )
        }
        surfaces.onQuit = { [weak self] in self?.quit() }
        surfaces.onWindowOpened = { [weak self] scope in self?.regularWindowOpened("window:" + scope) }
        surfaces.onWindowClosed = { [weak self] scope in self?.regularWindowClosed("window:" + scope) }
        if bundled {
            launch = LaunchAtLogin(service: MainAppLoginItem(), api: api, store: store)
        }
        settings = SettingsModel(app: model, launch: launch)
        // The popover, windows and Settings get their appearance set
        // explicitly from the Appearance setting and the Mac. Left to
        // inherit, the popover would take the appearance of the menu bar
        // button it hangs from, which macOS picks for the wallpaper. The
        // menu bar icons follow the menu bar and are redrawn.
        appearance = AppearanceFollower(app: model) { [weak self] value in
            NSApp.appearance = value == .system ? nil : NSAppearance(named: value == .dark ? .darkAqua : .aqua)
            self?.applySurfaceAppearance()
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            // System and the Mac switched between light and dark.
            DispatchQueue.main.async { self?.applySurfaceAppearance() }
        }
        applySurfaceAppearance()
        if let launch {
            model.observeConfig { key, value in
                Task { await launch.configChanged(key: key, value: value) }
            }
        }
        model.onOpenPopover = { [weak self] scope in self?.surfaces.showPopover(scope: scope) }
        model.onOpenSettings = { [weak self] in self?.showSettings(.scopes) }
        presenter?.onClick = { [weak self] type, scope, url in
            self?.model.notificationClicked(type: type, scope: scope, url: url)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shiibar-ghd")
        let launcher: DaemonLauncher? = bundled && FileManager.default.isExecutableFile(atPath: helpers.path)
            ? ProcessDaemonLauncher(executable: helpers, stateRoot: root)
            : nil
        let supervisor = DaemonSupervisor(socketPath: socket, appVersion: version, launcher: launcher)
        supervisor.onEvent = { [weak self] event in self?.model.handle(event) }
        supervisor.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.model.connectionChanged(connected)
            if connected, let appearance = self.appearance {
                Task { await appearance.load() }
            }
            if connected, let launch = self.launch, !self.didApplyLaunch {
                self.didApplyLaunch = true
                Task { await launch.applyAtLaunch(runningFromBundle: true) }
            }
        }
        self.supervisor = supervisor
        supervisor.start()

        // Asked at the first launch, so the first notification can show.
        notifier.requestAuthorization()
    }

    private var didApplyLaunch = false
    private var appearance: AppearanceFollower?
    private var appearanceObservation: NSKeyValueObservation?
    private var regularWindows = RegularWindows()

    // MARK: - Regular app while a window is open

    /// DESIGN.md, "Switching to a regular app": a Dock icon, ⌘Tab and the
    /// menu bar while a pinned window or Settings exists.
    private func regularWindowOpened(_ id: String) {
        guard regularWindows.opened(id) else { return }
        NSApp.setActivationPolicy(.regular)
        // Measured in shiibar-cc (AppState.switchToRegularApp, macOS 14):
        // an app already active keeps the previous app's menu bar after the
        // switch until activation leaves and comes back, so it bounces
        // through the Dock, which has no menu bar of its own.
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            dock.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func regularWindowClosed(_ id: String) {
        guard regularWindows.closed(id) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// The Dock icon: bring the open windows forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringWindowsToFront()
        return true
    }

    /// ⌘Tab and other activations while regular.
    func applicationDidBecomeActive(_ notification: Notification) {
        if regularWindows.isRegular { bringWindowsToFront() }
    }

    private func bringWindowsToFront() {
        surfaces?.bringWindowsToFront()
        if let window = settingsWindow, window.isVisible { window.orderFront(nil) }
    }

    private func applySurfaceAppearance() {
        let dark = SurfaceAppearance.isDark(
            setting: appearance?.current ?? .system,
            systemDark: NSApp.effectiveAppearance.isDark
        )
        let name = SurfaceAppearance.named(dark: dark)
        surfaces?.applyAppearance(name)
        settingsWindow?.appearance = NSAppearance(named: name)
    }

    func showSettings(_ tab: SettingsTab) {
        surfaces.closePopover()
        settings.tab = tab
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Settings"
            window.appearance = NSAppearance(named: SurfaceAppearance.named(dark: SurfaceAppearance.isDark(
                setting: appearance?.current ?? .system, systemDark: NSApp.effectiveAppearance.isDark
            )))
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: settings, app: model))
            window.setContentSize(NSSize(width: 720, height: 640))
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        settings.windowOpened()
        regularWindowOpened("settings")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if (notification.object as? NSWindow) === settingsWindow {
                settings.windowClosed()
                regularWindowClosed("settings")
            }
        }
    }

    private func about() {
        surfaces.closePopover()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let supervisor, !quitting else { return .terminateNow }
        quitting = true
        supervisor.shutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
