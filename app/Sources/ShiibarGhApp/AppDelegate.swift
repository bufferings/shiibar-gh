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
        if bundled {
            launch = LaunchAtLogin(service: MainAppLoginItem(), api: api, store: store)
        }
        settings = SettingsModel(app: model, launch: launch)
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
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: settings, app: model))
            window.setContentSize(NSSize(width: 720, height: 640))
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        settings.windowOpened()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if (notification.object as? NSWindow) === settingsWindow {
                settings.windowClosed()
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
