// Wires the core to AppKit: the daemon supervisor, the menu bar and its
// popovers and windows, Settings, notifications and Launch at login.
// Quitting (the ⌄ menu's Quit or ⌘Q) shuts the daemon down first
// (docs/tasks/M3.md, "Daemon lifecycle").

import AppKit
import Combine
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
    private var shortcuts: GlobalShortcutCenter!
    /// The About panel, once shown (`about()`).
    private weak var aboutPanel: NSWindow?
    private var presenter: UserNotificationPresenter?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The tooltip comparison (TooltipProbe.swift): no daemon, no state.
        if TooltipProbe.enabled {
            let probe = TooltipProbe()
            tooltipProbe = probe
            probe.start()
            return
        }
        // The Edit menu's key equivalents make ⌘V and the other text
        // shortcuts work in every text field (see MainMenu).
        NSApp.mainMenu = MainMenu.make(MainMenu.Actions(
            about: { [weak self] in self?.about() },
            settings: { [weak self] in self?.showSettings(.general) }
        ))
        // The measurement mode (Perf.swift) runs only in a sandbox state
        // directory, never the real one.
        // The demo mode (scripts/perf/demo.sh) uses the same sandbox.
        let perf = PerfMode.sandboxed
        if perf && PerfMode.stateRoot == nil {
            FileHandle.standardError.write(Data("shiibar-gh: the measurement and demo modes need SHIIBAR_GH_STATE_DIR\n".utf8))
            exit(2)
        }
        if PerfMode.demo { quitOnSignals() }
        if PerfMode.enabled { failOnSignals() }
        let bundled = Bundle.main.bundleURL.pathExtension == "app" && !perf
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
        if perf { PerfMode.removeLeftoverSuite() }
        let store = UIStateStore(defaults: perf ? ScratchDefaults() : .standard)
        // `SHIIBAR_GH_UNREAD_ONLY_SECONDS` changes the 5 seconds of `Unread
        // only` without a rebuild (docs/tasks/M8.md: a development switch).
        let linger = LingerTiming(duration: LingerTiming.duration(environment: ProcessInfo.processInfo.environment))
        model = AppModel(
            api: api, store: store, opener: WorkspaceOpener(), notifier: notifier, copier: PasteboardCopier(), linger: linger
        )
        model.refreshAnswerDelay = PerfMode.demoRefreshSeconds
        let avatars = perf
            ? AvatarStore(loader: FileImageLoader(), schemes: ["file"])
            : AvatarStore(loader: URLSessionImageLoader())
        surfaces = SurfaceController(app: model, avatars: avatars) { [weak self] account in
            SurfaceActions(
                openWindow: account.map { id in { self?.surfaces.openInWindow(account: id) } },
                openSettings: { destination in self?.showSettings(destination) },
                about: { self?.about() },
                quit: { self?.quit() }
            )
        }
        surfaces.onQuit = { [weak self] in self?.quit() }
        surfaces.onWindowOpened = { [weak self] account in self?.regularWindowOpened("window:" + account) }
        surfaces.onWindowClosed = { [weak self] account in self?.regularWindowClosed("window:" + account) }
        surfaces.onHoldPopover = { [weak self] in self?.regularWindows.holdPopover() }
        surfaces.onPopoverClosed = { [weak self] replaced in
            guard let self, self.regularWindows.popoverClosed(replaced: replaced) else { return }
            NSApp.setActivationPolicy(.accessory)
        }
        surfaces.onPinsChanged = { [weak self] closing in self?.applyAuxiliaryLevels(closing: closing) }
        // The global shortcuts: registered in the demo mode too (its saved
        // values live in memory only), never in the measurement mode.
        shortcuts = GlobalShortcutCenter(store: store, registrar: CarbonHotKeyRegistrar(), enabled: !PerfMode.enabled)
        surfaces.director.attach(shortcuts)
        model.onAccountRemoved = { [weak self] account in self?.shortcuts.accountRemoved(account) }
        // Only the accounts of the list the daemon sent are registered; an
        // unreadable database lists none. Delivered on the main queue, which
        // also runs while a menu tracks or a window resizes (the main run
        // loop's default mode does not). A list delivered after
        // `account_removed` cannot bring a removed account back: its saved
        // shortcut is deleted before then.
        accountWatch = model.$accounts.combineLatest(model.$dbUnreadable)
            .map { accounts, unreadable in unreadable ? [] : accounts.map(\.id) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in self?.shortcuts.accountsListed(ids) }
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
        SystemColors.watch()
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
        model.onShowAccount = { [weak self] account, _ in self?.surfaces.showForNotification(account: account) }
        model.onOpenSettings = { [weak self] destination in self?.showSettings(destination) }
        // Shown from the next turn of the run loop so a dialog never runs
        // inside the event handler that raised it.
        model.onKeychainDialog = { [weak self] dialog in
            DispatchQueue.main.async {
                guard let self else { return }
                self.keychainAlerts.show(dialog) { [weak self] chosen in self?.model.keychainAction(chosen) }
            }
        }
        presenter?.onClick = { [weak self] type, account, url, pr in
            self?.model.notificationClicked(type: type, account: account, url: url, pr: pr)
        }

        let version = DaemonLifecycle.daemonVersion(
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shiibar-ghd")
        var launcher: DaemonLauncher? = bundled && FileManager.default.isExecutableFile(atPath: helpers.path)
            ? ProcessDaemonLauncher(executable: helpers, stateRoot: root)
            : nil
        if perf, let daemon = PerfMode.daemon {
            launcher = ProcessDaemonLauncher(executable: daemon, stateRoot: root)
        }
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

        if PerfMode.demo {
            // Used by hand: no notification permission is asked for and no
            // login item is registered (`launch` is nil without a bundle).
            return
        }
        if perf {
            // No notification permission is asked for and no login item is
            // registered (`launch` is nil without a bundle).
            let runner = PerfRunner(app: model, surfaces: surfaces, steps: PerfSteps.current)
            perfRunner = runner
            runner.start()
            return
        }
        // Asked at launch, before any notification is scheduled (Apple:
        // "Always call this method before scheduling any local
        // notifications"); macOS prompts only the first time.
        notifier.requestAuthorization()
    }

    private var perfRunner: PerfRunner?
    private var tooltipProbe: TooltipProbe?

    private var didApplyLaunch = false
    private let keychainAlerts = KeychainAlerts()
    private var appearance: AppearanceFollower?
    private var appearanceObservation: NSKeyValueObservation?
    private var regularWindows = RegularWindows()
    private var accountWatch: AnyCancellable?
    private var settingsTitle: Any?

    // MARK: - Regular app while a window is open

    /// DESIGN.md, "Switching to a regular app": the app shows in the Dock,
    /// in ⌘Tab and with its menu bar while an account's window or Settings
    /// is open, or the popover `Open in popover` opened shows
    /// (`RegularWindows`), so those windows can be reached like any app's.
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

    /// The Dock icon: bring the open windows forward, minimized ones too.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringWindowsToFront(restoringMinimized: true)
        return true
    }

    /// ⌘Tab and other activations while regular: the windows on screen come
    /// forward; minimized ones stay in the Dock, as macOS does with ⌘Tab.
    func applicationDidBecomeActive(_ notification: Notification) {
        if regularWindows.isRegular { bringWindowsToFront(restoringMinimized: false) }
    }

    private func bringWindowsToFront(restoringMinimized: Bool) {
        var windows = surfaces?.windowsComingForward(restoringMinimized: restoringMinimized) ?? []
        if let window = settingsWindow, window.isVisible { windows.append(window) }
        // Back-most first, so the windows keep their order: the one an icon
        // or a shortcut has just brought forward stays on top.
        let order = SurfaceRules.backToFront(windows.map(\.windowNumber), frontToBack: NSApp.orderedWindows.map(\.windowNumber))
        for number in order {
            windows.first { $0.windowNumber == number }?.orderFront(nil)
        }
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

    func showSettings(_ destination: SettingsDestination) {
        // Settings keeps the app regular before the popover closes (a
        // popover `Open in popover` opened goes without the app becoming an
        // accessory app in between).
        regularWindowOpened("settings")
        surfaces.closePopover()
        settings.show(destination)
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = settings.tab.rawValue
            window.appearance = NSAppearance(named: SurfaceAppearance.named(dark: SurfaceAppearance.isDark(
                setting: appearance?.current ?? .system, systemDark: NSApp.effectiveAppearance.isDark
            )))
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: settings, app: model, shortcuts: shortcuts))
            window.setContentSize(NSSize(width: 720, height: 640))
            // The title is the tab (Settings.html).
            settingsTitle = settings.$tab.sink { [weak window] tab in window?.title = tab.rawValue }
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        settings.windowOpened()
        applyAuxiliaryLevels(closing: nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if (notification.object as? NSWindow) === settingsWindow {
                shortcuts.abandonRecording()
                settings.windowClosed()
                regularWindowClosed("settings")
            }
        }
    }

    /// The standard About panel. The panel is the window the call brings on
    /// screen (or, shown already, the one taken before): its level follows
    /// the pinned windows.
    private func about() {
        surfaces.closePopover()
        NSApp.activate(ignoringOtherApps: true)
        let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(nil)
        if let shown = NSApp.windows.first(where: { $0.isVisible && !visible.contains(ObjectIdentifier($0)) }) {
            aboutPanel = shown
        }
        applyAuxiliaryLevels(closing: nil)
    }

    /// Settings and the About panel float while a window with Keep on top
    /// on is open (`AuxiliaryWindows`); `closing` is a window that is
    /// closing and still on screen.
    private func applyAuxiliaryLevels(closing: String?) {
        auxiliary.settings = settingsWindow
        auxiliary.about = aboutPanel
        auxiliary.apply(pins: surfaces?.windowPins ?? [:], closing: closing)
    }

    private let auxiliary = AuxiliaryWindows()

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts?.unregisterAll()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    /// Edit › Copy (no target) when nothing before the app in the responder
    /// chain takes it: in a popover or window, what ⌘C does there.
    @objc func copy(_ sender: Any?) {
        _ = surfaces?.copyFromMenu()
    }

    /// Edit › Select All (no target) when nothing before the app in the
    /// responder chain takes it: in a popover or window, what ⌘A does there.
    @objc func selectAll(_ sender: Any?) {
        _ = surfaces?.selectAllFromMenu()
    }

    /// The demo mode: Ctrl-C in demo.sh (SIGINT) or SIGTERM quits as the
    /// menu's Quit does, so the daemon stops.
    /// The signals are read from a dispatch source and ignored otherwise
    /// (dispatch_source_create(3), DISPATCH_SOURCE_TYPE_SIGNAL: "a dispatch
    /// source does not install a signal handler or otherwise alter the
    /// behavior of signal delivery. Therefore, applications must ignore or
    /// at least catch any signal that terminates a process").
    private var signalSources: [DispatchSourceSignal] = []

    private func quitOnSignals() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            // Not inside the dispatch block: `terminate` waits for the daemon
            // in a nested run loop, and the reply comes on the main queue,
            // which does not run again while one of its blocks is running.
            source.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }



    /// The measurement mode ends with its summary (`PerfRunner.finish`
    /// exits by itself, without `terminate`). A signal that ends it before
    /// then (a `pkill` of the measurement, a closed terminal) is reported
    /// with the signal and a failing status, not as a run that passed.
    private func failOnSignals() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                FileHandle.standardError.write(Data("perf: ended by signal \(number) before the summary\n".utf8))
                exit(128 + number)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The measurement mode never quits through `terminate` once it has
        // its summary: a quit here (the menu, ⌘Q, an Apple event) ended it
        // early.
        if PerfMode.enabled {
            FileHandle.standardError.write(Data("perf: ended before the summary: the app was asked to quit\n".utf8))
            exit(3)
        }
        guard let supervisor, !quitting else { return .terminateNow }
        quitting = true
        supervisor.shutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Settings and the About panel (DESIGN.md, "Open in window"): floating
/// while a window with Keep on top on is open (minimized ones included), so
/// they open in front of it; normal otherwise. Only the level changes: they
/// stay in front while the app is not active, as the pinned window does.
@MainActor
final class AuxiliaryWindows {
    weak var settings: NSWindow?
    weak var about: NSWindow?

    func apply(pins: [String: Bool], closing: String?) {
        let level: NSWindow.Level = AuxiliaryLevel.level(pins: pins, closing: closing) == .floating ? .floating : .normal
        for window in [settings, about].compactMap({ $0 }) where window.level != level {
            window.level = level
        }
    }
}
