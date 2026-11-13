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
    var greeting: [String] = ["{\"event\":\"snapshot\",\"accounts\":[],\"keychain\":\"ok\",\"db_unreadable\":false}"]
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

    /// Cut every subscriber, like the daemon does when the database turns
    /// unreadable.
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

final class FakeCopier: LinkCopying {
    var copied: [String] = []
    func copy(_ text: String) { copied.append(text) }
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
    var config: [String: ConfigValue] = ["launch_at_login": .bool(true)]
    var failNext: DaemonError?
    var refreshWarnings: [Warning] = []
    var testResults: [TestResult] = []
    var added = Account(id: "9919001", login: "new")
    var events: [String: EventCell] = [:]
    /// How long `owner_events_get` takes, in nanoseconds.
    var eventsDelay: UInt64 = 0
    var mutes = Mutes()
    /// Commands that fail, by name (`place`, `dismiss`, ...), every time.
    var refuse: [String: DaemonError] = [:]
    /// How long the operations of DESIGN.md, "Showing what an operation
    /// did" take to answer, in nanoseconds.
    var operationDelay: UInt64 = 0
    /// Owners `owner_add` refuses, with the error.
    var ownerErrors: [String: DaemonError] = [:]

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
    func list(_ query: ListQuery) async throws -> [Card] {
        try record("list \(query.account ?? "") dismissed=\(query.dismissed?.rawValue ?? "-")")
        return cards
    }

    private func operation(_ call: String, _ name: String) async throws {
        try record(call)
        if operationDelay > 0 { try? await Task.sleep(nanoseconds: operationDelay) }
        if let error = refuse[name] { throw error }
    }
    func read(_ rowIds: [String]) async throws { try await operation("read \(rowIds.joined(separator: ","))", "read") }
    func readAll(account: String) async throws { try record("read_all \(account)") }
    /// How long `popover_opened` takes to answer, in nanoseconds.
    var popoverOpenedDelay: UInt64 = 0
    func popoverOpened(_ account: String) async throws {
        try record("popover_opened \(account)")
        if popoverOpenedDelay > 0 { try? await Task.sleep(nanoseconds: popoverOpenedDelay) }
        try record("answered popover_opened")
    }
    func popoverClosed(_ account: String) async throws { try record("popover_closed \(account)") }
    func place(account: String, pr: String, target: PlaceTarget, position: PlacePosition) async throws {
        let to: String
        switch target {
        case .review(let section): to = "review " + section.rawValue
        case .mine: to = "mine"
        case .mineDone: to = "mine done"
        case .none: to = "none"
        }
        let at: String
        switch position {
        case .before(let other): at = " before " + other
        case .top: at = " top"
        case .bottom: at = " bottom"
        case .byDefault: at = ""
        }
        try await operation("place \(account) \(pr) \(to)\(at)", "place")
    }
    func dismiss(account: String, pr: String) async throws { try await operation("dismiss \(account) \(pr)", "dismiss") }
    func restore(account: String, pr: String) async throws { try await operation("restore \(account) \(pr)", "restore") }
    func mute(account: String, kind: MuteKind, name: String) async throws -> Mutes {
        try await operation("mute \(account) \(kind.rawValue) \(name)", "mute")
        return mutes
    }
    func unmute(account: String, kind: MuteKind, name: String) async throws -> Mutes {
        try await operation("unmute \(account) \(kind.rawValue) \(name)", "unmute")
        return mutes
    }
    func mutes(account: String) async throws -> Mutes {
        try record("mutes_get \(account)")
        return mutes
    }
    func refresh(_ account: String?) async throws -> [Warning] { try record("refresh \(account ?? "")"); return refreshWarnings }
    func configGet(_ key: String) async throws -> ConfigValue {
        try record("config_get \(key)")
        return config[key] ?? .bool(false)
    }
    func configSet(_ key: String, _ value: ConfigValue) async throws -> ConfigValue {
        try record("config_set \(key) \(value)")
        config[key] = value
        return value
    }
    func accountList() async throws -> [Account] { try record("account_list"); return [] }
    /// The token is not recorded: tests check it never shows up anywhere.
    func accountAdd(token: String) async throws -> Account { try record("account_add"); return added }
    func accountRemove(_ account: String) async throws { try record("account_remove \(account)") }
    func accountColor(_ account: String, _ color: AccountColor) async throws { try record("account_color \(account) \(color.rawValue)") }
    func ownerAdd(account: String, owner: String) async throws -> Account {
        try record("owner_add \(account) \(owner)")
        if let error = ownerErrors[owner] { throw error }
        return Account(id: "3407303", login: account)
    }
    func ownerRemove(account: String, owner: String) async throws -> Account {
        try record("owner_remove \(account) \(owner)")
        return Account(id: "3407303", login: account)
    }
    func ownerEnabled(account: String, owner: String, on: Bool) async throws { try record("owner_enabled \(account) \(owner) \(on)") }
    func ownerNotify(account: String, owner: String, on: Bool) async throws { try record("owner_notify \(account) \(owner) \(on)") }
    func ownerSkipDrafts(account: String, owner: String, on: Bool) async throws { try record("owner_skip_drafts \(account) \(owner) \(on)") }
    func ownerEvents(account: String, owner: String) async throws -> [String: EventCell] {
        try record("owner_events_get \(account) \(owner)")
        // The table as it is when the request arrives, answered late.
        let table = events
        if eventsDelay > 0 { try? await Task.sleep(nanoseconds: eventsDelay) }
        return table
    }
    func ownerEventsSet(account: String, owner: String, event: EventKind, column: EventColumn, on: Bool) async throws -> [String: EventCell] {
        try record("owner_events_set \(account) \(owner) \(event.rawValue) \(column.rawValue) \(on)")
        return events
    }
    func ownerEventsCopy(account: String, from: String, to: String) async throws -> [String: EventCell] {
        try record("owner_events_copy \(account) \(from) \(to)")
        return events
    }
    func tokenSet(account: String, token: String) async throws { try record("token_set \(account)") }
    func tokenTest(account: String?, token: String?) async throws -> [TestResult] {
        try record("token_test \(account ?? "-") \(token == nil ? "saved" : "pasted")")
        return testResults
    }
    func tokenReset() async throws { try record("token_reset") }
    func reset() async throws { try record("reset") }
    func shutdown() async throws { try record("shutdown") }
}

/// A suite of its own, removed by the test.
func testDefaults() -> (UserDefaults, String) {
    let name = "shiibar.gh.tests." + UUID().uuidString
    return (UserDefaults(suiteName: name)!, name)
}

/// Wait for the tasks the models start.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 50_000_000)
}

let utc = TimeZone(identifier: "UTC")!
let T0: Int64 = 1_800_000_000
