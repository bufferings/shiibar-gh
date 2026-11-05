// The real implementations of the core's service protocols.

import AppKit
import ServiceManagement
import ShiibarGhCore
import UserNotifications

final class WorkspaceOpener: URLOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// `SMAppService.mainApp` (ServiceManagement, macOS 13 and later).
/// `register()` can leave the status at `requiresApproval` until the user
/// allows the app in System Settings › General › Login Items.
final class MainAppLoginItem: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

final class URLSessionImageLoader: ImageLoading {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0)
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    func load(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }
}

/// macOS notifications through UNUserNotificationCenter. The title,
/// subtitle and body are the daemon's; a notification has no buttons
/// (DESIGN.md, "macOS notifications"). A click goes to `onClick`.
final class UserNotificationPresenter: NSObject, NotificationPresenting, UNUserNotificationCenterDelegate {
    var onClick: ((NotificationType?, String, String?) -> Void)?
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func start() {
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("shiibar-gh: notification permission: %@", String(describing: error))
            }
        }
    }

    func present(_ notification: DaemonNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let subtitle = notification.subtitle { content.subtitle = subtitle }
        if let body = notification.body { content.body = body }
        content.sound = .default
        content.userInfo = [
            "type": notification.type.rawText,
            "scope": notification.scope,
            "url": notification.url ?? "",
        ]
        // No trigger: shown right away.
        center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let type = (info["type"] as? String).flatMap(NotificationType.init(rawValue:))
        let scope = info["scope"] as? String ?? ""
        let url = (info["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        DispatchQueue.main.async { [weak self] in
            self?.onClick?(type, scope, url)
        }
        completionHandler()
    }
}

/// Outside an app bundle (a plain `swift run`) there is no notification
/// center to talk to; notifications are dropped.
final class NoNotifications: NotificationPresenting {
    func requestAuthorization() {}
    func present(_ notification: DaemonNotification) {}
}
