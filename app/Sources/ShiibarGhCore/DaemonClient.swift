// Request and response over the daemon socket: one connection, one request
// line, one response line (docs/DESIGN.md, "Wire format"). The app never
// keeps a token: `tokenSet` and `tokenTest` pass it straight into the
// request line and nothing here logs a request.

import Foundation

public struct DaemonError: Error, Equatable, CustomStringConvertible {
    public var code: Lenient<ErrorCode>?
    public var message: String

    public init(code: ErrorCode?, message: String) {
        self.code = code.map(Lenient.known)
        self.message = message
    }

    public var description: String { message }

    /// Not an answer from the daemon: it is missing or the socket failed.
    public static func unreachable(_ error: Error) -> DaemonError {
        DaemonError(code: nil, message: "Cannot reach the daemon (\(error))")
    }
}

/// The filter shared by `list` and `activity`.
public struct ListFilter: Equatable {
    public var scope: String?
    public var needsAction = false
    public var mine = false
    public var others = false
    public var snoozed = false

    public init(scope: String? = nil, needsAction: Bool = false, mine: Bool = false, others: Bool = false, snoozed: Bool = false) {
        self.scope = scope
        self.needsAction = needsAction
        self.mine = mine
        self.others = others
        self.snoozed = snoozed
    }

    var fields: [String: Any] {
        var fields: [String: Any] = [
            "needs_action": needsAction, "mine": mine, "others": others, "snoozed": snoozed,
        ]
        if let scope { fields["scope"] = scope }
        return fields
    }
}

/// Everything the app asks of the daemon. A protocol so the view models can
/// run against a fake in tests.
public protocol DaemonAPI: AnyObject, Sendable {
    func info() async throws -> InfoResponse
    func list(_ filter: ListFilter) async throws -> [Card]
    func activity(_ filter: ListFilter) async throws -> [Row]
    func seen(_ rowIds: [String]) async throws
    func popoverOpened(_ scope: String) async throws
    func popoverClosed(_ scope: String) async throws
    func done(_ row: String) async throws
    func undone(_ row: String) async throws
    func snooze(_ pr: String) async throws
    func unsnooze(_ pr: String) async throws
    func refresh(_ scope: String?) async throws -> [Warning]
    func configGet(_ key: String) async throws -> ConfigValue
    func configSet(_ key: String, _ value: ConfigValue) async throws -> ConfigValue
    func scopeList() async throws -> [Scope]
    func scopeAdd(_ owner: String) async throws -> [Scope]
    func scopeRemove(_ owner: String) async throws -> [Scope]
    func scopeEnable(_ scope: String) async throws
    func scopeDisable(_ scope: String) async throws
    func scopeNotify(_ scope: String, on: Bool) async throws
    func scopeColor(_ scope: String, _ color: ScopeColor) async throws
    func scopeLookup(_ owner: String) async throws -> ScopeLookup
    func tokenSet(_ target: String, token: String) async throws
    func tokenTest(_ target: String) async throws -> TokenTestResponse
    func settingsStatus() async throws -> SettingsStatus
    func reset() async throws
    func shutdown() async throws
}

/// The real client: a new socket connection per request.
public final class SocketDaemonAPI: DaemonAPI, @unchecked Sendable {
    public let socketPath: String
    /// How long an ordinary answer may take.
    public var timeout: TimeInterval
    /// `refresh` and `token_test` answer after GitHub did; they get longer.
    public var slowTimeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 10, slowTimeout: TimeInterval = 300) {
        self.socketPath = socketPath
        self.timeout = timeout
        self.slowTimeout = slowTimeout
    }

    /// Send one request and return the response object, or throw the
    /// daemon's error.
    func call(_ fields: [String: Any], slow: Bool = false) async throws -> Data {
        let path = socketPath
        let limit = slow ? slowTimeout : timeout
        let line = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let socket = try UnixSocket.connect(path: path, timeout: limit)
                    defer { socket.close() }
                    try socket.write(line + Data("\n".utf8))
                    guard let answer = try socket.readLine() else { throw SocketError.closed }
                    continuation.resume(returning: answer)
                } catch {
                    continuation.resume(throwing: DaemonError.unreachable(error))
                }
            }
        }
        let decoder = JSONDecoder()
        let ok = try? decoder.decode(OkResponse.self, from: response)
        guard let ok, ok.ok else {
            let error = try? decoder.decode(ErrorResponse.self, from: response)
            throw DaemonError(code: error?.code?.value, message: error?.error ?? "The daemon sent an unexpected answer")
        }
        return response
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DaemonError(code: nil, message: "The daemon sent an unexpected answer (\(error))")
        }
    }

    public func info() async throws -> InfoResponse {
        try decode(InfoResponse.self, try await call(["cmd": "info"]))
    }

    public func list(_ filter: ListFilter) async throws -> [Card] {
        var fields = filter.fields
        fields["cmd"] = "list"
        return try decode(ListResponse.self, try await call(fields)).cards
    }

    public func activity(_ filter: ListFilter) async throws -> [Row] {
        var fields = filter.fields
        fields["cmd"] = "activity"
        return try decode(ActivityResponse.self, try await call(fields)).rows
    }

    public func seen(_ rowIds: [String]) async throws {
        _ = try await call(["cmd": "seen", "row_ids": rowIds])
    }

    public func popoverOpened(_ scope: String) async throws {
        _ = try await call(["cmd": "popover_opened", "scope": scope])
    }

    public func popoverClosed(_ scope: String) async throws {
        _ = try await call(["cmd": "popover_closed", "scope": scope])
    }

    public func done(_ row: String) async throws {
        _ = try await call(["cmd": "done", "row": row])
    }

    public func undone(_ row: String) async throws {
        _ = try await call(["cmd": "undone", "row": row])
    }

    public func snooze(_ pr: String) async throws {
        _ = try await call(["cmd": "snooze", "pr": pr])
    }

    public func unsnooze(_ pr: String) async throws {
        _ = try await call(["cmd": "unsnooze", "pr": pr])
    }

    public func refresh(_ scope: String?) async throws -> [Warning] {
        var fields: [String: Any] = ["cmd": "refresh"]
        if let scope { fields["scope"] = scope }
        return try decode(RefreshResponse.self, try await call(fields, slow: true)).warnings
    }

    public func configGet(_ key: String) async throws -> ConfigValue {
        try Self.configValue(try await call(["cmd": "config_get", "key": key]))
    }

    public func configSet(_ key: String, _ value: ConfigValue) async throws -> ConfigValue {
        try Self.configValue(try await call(["cmd": "config_set", "key": key, "value": value.jsonObject]))
    }

    /// `value` read with JSONSerialization, which tells `true` from `1`.
    static func configValue(_ data: Data) throws -> ConfigValue {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch object?["value"] {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return .bool(number.boolValue)
        case let number as NSNumber:
            return .int(number.int64Value)
        case let text as String:
            return .string(text)
        default:
            throw DaemonError(code: nil, message: "The daemon sent an unexpected setting value")
        }
    }

    public func scopeList() async throws -> [Scope] {
        try decode(ScopesResponse.self, try await call(["cmd": "scope_list"])).scopes
    }

    public func scopeAdd(_ owner: String) async throws -> [Scope] {
        try decode(ScopesResponse.self, try await call(["cmd": "scope_add", "owner": owner])).scopes
    }

    public func scopeRemove(_ owner: String) async throws -> [Scope] {
        try decode(ScopesResponse.self, try await call(["cmd": "scope_remove", "owner": owner])).scopes
    }

    public func scopeEnable(_ scope: String) async throws {
        _ = try await call(["cmd": "scope_enable", "scope": scope])
    }

    public func scopeDisable(_ scope: String) async throws {
        _ = try await call(["cmd": "scope_disable", "scope": scope])
    }

    public func scopeNotify(_ scope: String, on: Bool) async throws {
        _ = try await call(["cmd": "scope_notify", "scope": scope, "on": on])
    }

    public func scopeColor(_ scope: String, _ color: ScopeColor) async throws {
        _ = try await call(["cmd": "scope_color", "scope": scope, "color": color.rawValue])
    }

    public func scopeLookup(_ owner: String) async throws -> ScopeLookup {
        try decode(ScopeLookup.self, try await call(["cmd": "scope_lookup", "owner": owner], slow: true))
    }

    public func tokenSet(_ target: String, token: String) async throws {
        _ = try await call(["cmd": "token_set", "target": target, "token": token])
    }

    public func tokenTest(_ target: String) async throws -> TokenTestResponse {
        try decode(TokenTestResponse.self, try await call(["cmd": "token_test", "target": target], slow: true))
    }

    public func settingsStatus() async throws -> SettingsStatus {
        try decode(SettingsStatus.self, try await call(["cmd": "settings_status"]))
    }

    public func reset() async throws {
        _ = try await call(["cmd": "reset"])
    }

    public func shutdown() async throws {
        _ = try await call(["cmd": "shutdown"])
    }
}
