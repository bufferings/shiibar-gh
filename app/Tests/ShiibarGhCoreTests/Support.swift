// Test helpers: a temporary state directory, a fake daemon listening on a
// Unix socket inside it, and fakes for every outside service. Nothing here
// touches the real state directory, home, Keychain, network, notification
// center, login items or standard UserDefaults.

import Darwin
import Foundation
@testable import ShiibarGhCore
import XCTest

/// A new directory with a path short enough for a socket address.
func temporaryDirectory() -> String {
    var base = NSTemporaryDirectory()
    if base.utf8.count > 60 { base = "/tmp/" }
    var template = Array((base as NSString).appendingPathComponent("sgh.XXXXXX").utf8CString)
    let made = template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let result = mkdtemp(buffer.baseAddress!) else { return nil }
        return String(cString: result)
    }
    precondition(made != nil, "mkdtemp failed")
    return made!
}

/// A daemon stand-in: answers request lines with `respond`, keeps
/// `subscribe` connections open and pushes lines to them.
final class FakeDaemon: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var subscribers: [Int32] = []
    private var received: [String] = []
    var respond: (String) -> String = { _ in "{\"ok\":true}" }
    /// Lines sent to each new subscriber right after it subscribes.
    var greeting: [String] = ["{\"event\":\"snapshot\",\"scopes\":[],\"db_unreadable\":false}"]
    /// When set, the greeting goes out in pieces of this many bytes.
    var chunk: Int?

    init(path: String) throws {
        self.path = path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw SocketError.connectFailed(errno) }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var commands: [String] {
        requests.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["cmd"] as? String
        }
    }

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers.count
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread { [weak self] in self?.serve(client) }.start()
        }
    }

    private func serve(_ client: Int32) {
        var buffer = LineBuffer()
        var chunkBytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &chunkBytes, chunkBytes.count)
            if count <= 0 {
                drop(client)
                return
            }
            for line in buffer.feed(Data(chunkBytes[0..<count])) {
                let text = String(decoding: line, as: UTF8.self)
                lock.lock()
                received.append(text)
                lock.unlock()
                if text.contains("\"subscribe\"") {
                    lock.lock()
                    subscribers.append(client)
                    lock.unlock()
                    for greeting in self.greeting {
                        send(greeting, to: client)
                    }
                    continue
                }
                send(respond(text), to: client)
                close(client)
                return
            }
        }
    }

    private func drop(_ client: Int32) {
        lock.lock()
        let wasSubscriber = subscribers.contains(client)
        subscribers.removeAll { $0 == client }
        lock.unlock()
        if wasSubscriber { close(client) }
    }

    func send(_ line: String, to client: Int32) {
        let bytes = Array((line + "\n").utf8)
        let size = chunk ?? bytes.count
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + size)
            _ = bytes[offset..<end].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            offset = end
            if chunk != nil { usleep(2_000) }
        }
    }

    func push(_ line: String) {
        lock.lock()
        let targets = subscribers
        lock.unlock()
        for client in targets { send(line, to: client) }
    }

    /// Cut every subscriber, like the daemon does after a scope removal.
    func dropSubscribers() {
        lock.lock()
        let targets = subscribers
        subscribers = []
        lock.unlock()
        for client in targets { shutdown(client, SHUT_RDWR) }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        dropSubscribers()
        unlink(path)
    }
}

/// Wait for a condition, failing the test after `timeout`.
func eventually(_ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met in \(timeout) s", file: file, line: line)
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

/// An `ok` line with the given fields.
func ok(_ fields: [String: Any] = [:]) -> String {
    var object = fields
    object["ok"] = true
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

final class FakeOpener: URLOpening {
    var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

final class FakeNotifier: NotificationPresenting {
    var authorizationRequests = 0
    var shown: [DaemonNotification] = []
    func requestAuthorization() { authorizationRequests += 1 }
    func present(_ notification: DaemonNotification) { shown.append(notification) }
}

final class FakeLoginItem: LoginItemService {
    var status: LoginItemStatus
    var registerResult: LoginItemStatus = .enabled
    var calls: [String] = []

    init(_ status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        calls.append("register")
        status = registerResult
    }

    func unregister() throws {
        calls.append("unregister")
        status = .notRegistered
    }

    func openSystemSettings() {
        calls.append("settings")
    }
}

/// A daemon API that records every call and answers from fixed values.
final class FakeAPI: DaemonAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var cards: [Card] = []
    var rows: [Row] = []
    var config: [String: ConfigValue] = ["launch_at_login": .bool(true)]
    var failNext: DaemonError?

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func clearCalls() {
        lock.lock()
        log = []
        lock.unlock()
    }

    private func record(_ call: String) throws {
        lock.lock()
        log.append(call)
        let failure = failNext
        failNext = nil
        lock.unlock()
        if let failure { throw failure }
    }

    func info() async throws -> InfoResponse { try record("info"); return InfoResponse(version: "0.1.0", startedAt: 0) }
    func list(_ filter: ListFilter) async throws -> [Card] {
        try record("list \(filter.scope ?? "") needs=\(filter.needsAction) mine=\(filter.mine) others=\(filter.others) snoozed=\(filter.snoozed)")
        return cards
    }
    func activity(_ filter: ListFilter) async throws -> [Row] { try record("activity \(filter.scope ?? "")"); return rows }
    func seen(_ rowIds: [String]) async throws { try record("seen \(rowIds.joined(separator: ","))") }
    func popoverOpened(_ scope: String) async throws { try record("popover_opened \(scope)") }
    func popoverClosed(_ scope: String) async throws { try record("popover_closed \(scope)") }
    func done(_ row: String) async throws { try record("done \(row)") }
    func undone(_ row: String) async throws { try record("undone \(row)") }
    func snooze(_ pr: String) async throws { try record("snooze \(pr)") }
    func unsnooze(_ pr: String) async throws { try record("unsnooze \(pr)") }
    func refresh(_ scope: String?) async throws -> [Warning] { try record("refresh \(scope ?? "")"); return [] }
    func configGet(_ key: String) async throws -> ConfigValue {
        try record("config_get \(key)")
        return config[key] ?? .bool(false)
    }
    func configSet(_ key: String, _ value: ConfigValue) async throws -> ConfigValue {
        try record("config_set \(key) \(value)")
        config[key] = value
        return value
    }
    func scopeList() async throws -> [Scope] { try record("scope_list"); return [] }
    func scopeAdd(_ owner: String) async throws -> [Scope] { try record("scope_add \(owner)"); return scopesAfterAdd }
    func scopeRemove(_ owner: String) async throws -> [Scope] { try record("scope_remove \(owner)"); return [] }
    func scopeEnable(_ scope: String) async throws { try record("scope_enable \(scope)") }
    func scopeDisable(_ scope: String) async throws { try record("scope_disable \(scope)") }
    func scopeNotify(_ scope: String, on: Bool) async throws { try record("scope_notify \(scope) \(on)") }
    func scopeColor(_ scope: String, _ color: ScopeColor) async throws { try record("scope_color \(scope) \(color.rawValue)") }
    /// Owners `scope_lookup` finds; others are not found. `lookupFailure`
    /// fails every lookup instead.
    var owners: [String: ScopeKind] = [:]
    var lookupFailure: DaemonError?
    /// What `scope_add` answers.
    var scopesAfterAdd: [Scope] = []
    func scopeLookup(_ owner: String) async throws -> ScopeLookup {
        try record("scope_lookup \(owner)")
        if let lookupFailure { throw lookupFailure }
        guard let (name, kind) = owners.first(where: { $0.key.lowercased() == owner.lowercased() }) else {
            throw DaemonError(code: .notFound, message: "not found: no such owner on GitHub")
        }
        return ScopeLookup(owner: name, kind: kind)
    }
    func tokenSet(_ target: String, token: String) async throws { try record("token_set \(target)") }
    func tokenTest(_ target: String) async throws -> TokenTestResponse { try record("token_test \(target)"); return TokenTestResponse(results: []) }
    func settingsStatus() async throws -> SettingsStatus { try record("settings_status"); return SettingsStatus() }
    func reset() async throws { try record("reset") }
    func shutdown() async throws { try record("shutdown") }
}

/// A suite of its own, removed by the test.
func testDefaults() -> (UserDefaults, String) {
    let name = "shiibar.gh.tests." + UUID().uuidString
    return (UserDefaults(suiteName: name)!, name)
}
