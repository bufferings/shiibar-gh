// Request and response over the daemon socket: one connection, one request
// line, one response line (docs/DESIGN.md, "Wire format"). The app never
// keeps a token: `accountAdd`, `tokenSet` and `tokenTest` pass it straight
// into the request line, and nothing here logs a request.
//
// The `account` argument of a request is the account's login and `owner`
// the owner's login or `public`; responses refer to both by id.

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

/// `list`: the PRs tab, or its Snoozed section. The app sends neither
/// `filter` nor `search`: it filters by itself (DESIGN.md, "What the
/// filters mean"); they stay for the CLI.
public struct ListQuery: Equatable {
    public var account: String?
    public var owner: String?
    public var filter: PrFilter?
    public var search: String?
    public var snoozed: Bool

    public init(account: String? = nil, owner: String? = nil, filter: PrFilter? = nil, search: String? = nil, snoozed: Bool = false) {
        self.account = account
        self.owner = owner
        self.filter = filter
        self.search = search
        self.snoozed = snoozed
    }

    var fields: [String: Any] {
        var fields: [String: Any] = ["cmd": "list"]
        if snoozed { fields["snoozed"] = true }
        if let account { fields["account"] = account }
        if let owner { fields["owner"] = owner }
        if let filter { fields["filter"] = filter.rawValue }
        if let search { fields["search"] = search }
        return fields
    }
}

/// `activity`: the Activity tab. `owners` are owner arguments (login or
/// `public`); empty is every owner. The app sends only the account.
public struct ActivityQuery: Equatable {
    public var account: String?
    public var owners: [String]
    public var filter: PrFilter?
    public var search: String?

    public init(account: String? = nil, owners: [String] = [], filter: PrFilter? = nil, search: String? = nil) {
        self.account = account
        self.owners = owners
        self.filter = filter
        self.search = search
    }

    var fields: [String: Any] {
        var fields: [String: Any] = ["cmd": "activity"]
        if let account { fields["account"] = account }
        if !owners.isEmpty { fields["owners"] = owners }
        if let filter { fields["filter"] = filter.rawValue }
        if let search { fields["search"] = search }
        return fields
    }
}

/// `owner_lookup`'s answer.
public struct OwnerLookup: Equatable, Decodable {
    public var owner: String
    public var kind: Lenient<OwnerKind>
    public var id: Int64
}

/// Everything the app asks of the daemon. A protocol so the view models can
/// run against a fake in tests.
public protocol DaemonAPI: AnyObject, Sendable {
    func info() async throws -> InfoResponse
    func list(_ query: ListQuery) async throws -> [Card]
    func activity(_ query: ActivityQuery) async throws -> [Row]
    /// Clears the unread mark of these rows; one unknown id refuses all.
    func read(_ rowIds: [String]) async throws
    /// Every row of the account but the snoozed PRs' (the CLI's `read --all`;
    /// the popover's ⇧R sends `read` instead).
    func readAll(account: String) async throws
    func popoverOpened(_ account: String) async throws
    func popoverClosed(_ account: String) async throws
    func snooze(account: String, pr: String) async throws
    func unsnooze(account: String, pr: String) async throws
    func refresh(_ account: String?) async throws -> [Warning]
    func configGet(_ key: String) async throws -> ConfigValue
    func configSet(_ key: String, _ value: ConfigValue) async throws -> ConfigValue
    func accountList() async throws -> [Account]
    func accountAdd(token: String) async throws -> Account
    func accountRemove(_ account: String) async throws
    func accountColor(_ account: String, _ color: AccountColor) async throws
    func ownerAdd(account: String, owner: String) async throws -> Account
    func ownerRemove(account: String, owner: String) async throws -> Account
    func ownerEnabled(account: String, owner: String, on: Bool) async throws
    func ownerNotify(account: String, owner: String, on: Bool) async throws
    func ownerSkipDrafts(account: String, owner: String, on: Bool) async throws
    func ownerEvents(account: String, owner: String) async throws -> [String: EventCell]
    func ownerEventsSet(account: String, owner: String, event: EventKind, column: EventColumn, on: Bool) async throws -> [String: EventCell]
    func ownerEventsCopy(account: String, from: String, to: String) async throws -> [String: EventCell]
    func ownerExclusions(account: String, owner: String) async throws -> Exclusions
    func ownerExclusionsSet(account: String, owner: String, kind: ExclusionKind, name: String, state: ExclusionState) async throws -> Exclusions
    func ownerExclusionsRemove(account: String, owner: String, kind: ExclusionKind, name: String) async throws -> Exclusions
    func tokenSet(account: String, token: String) async throws
    /// Without `account` the token is checked as for a new account; without
    /// `token` the saved one is.
    func tokenTest(account: String?, token: String?) async throws -> [TestResult]
    func tokenReset() async throws
    func reset() async throws
    func shutdown() async throws
}

/// The real client: a new socket connection per request.
public final class SocketDaemonAPI: DaemonAPI, @unchecked Sendable {
    public let socketPath: String
    /// How long an ordinary answer may take.
    public var timeout: TimeInterval
    /// Requests that wait for GitHub get longer.
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

    private func ack(_ fields: [String: Any], slow: Bool = false) async throws {
        _ = try await call(fields, slow: slow)
    }

    public func info() async throws -> InfoResponse {
        try decode(InfoResponse.self, try await call(["cmd": "info"]))
    }

    public func list(_ query: ListQuery) async throws -> [Card] {
        try decode(ListResponse.self, try await call(query.fields)).cards
    }

    public func activity(_ query: ActivityQuery) async throws -> [Row] {
        try decode(ActivityResponse.self, try await call(query.fields)).rows
    }

    public func read(_ rowIds: [String]) async throws {
        try await ack(["cmd": "read", "row_ids": rowIds])
    }

    public func readAll(account: String) async throws {
        try await ack(["cmd": "read_all", "account": account])
    }

    public func popoverOpened(_ account: String) async throws {
        try await ack(["cmd": "popover_opened", "account": account])
    }

    public func popoverClosed(_ account: String) async throws {
        try await ack(["cmd": "popover_closed", "account": account])
    }

    public func snooze(account: String, pr: String) async throws {
        try await ack(["cmd": "snooze", "account": account, "pr": pr])
    }

    public func unsnooze(account: String, pr: String) async throws {
        try await ack(["cmd": "unsnooze", "account": account, "pr": pr])
    }

    public func refresh(_ account: String?) async throws -> [Warning] {
        var fields: [String: Any] = ["cmd": "refresh"]
        if let account { fields["account"] = account }
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

    public func accountList() async throws -> [Account] {
        try decode(AccountsResponse.self, try await call(["cmd": "account_list"])).accounts
    }

    public func accountAdd(token: String) async throws -> Account {
        try decode(AccountResponse.self, try await call(["cmd": "account_add", "token": token], slow: true)).account
    }

    public func accountRemove(_ account: String) async throws {
        try await ack(["cmd": "account_remove", "account": account])
    }

    public func accountColor(_ account: String, _ color: AccountColor) async throws {
        try await ack(["cmd": "account_color", "account": account, "color": color.rawValue])
    }

    public func ownerAdd(account: String, owner: String) async throws -> Account {
        try decode(AccountResponse.self, try await call(["cmd": "owner_add", "account": account, "owner": owner], slow: true)).account
    }

    public func ownerRemove(account: String, owner: String) async throws -> Account {
        try decode(AccountResponse.self, try await call(["cmd": "owner_remove", "account": account, "owner": owner])).account
    }

    public func ownerEnabled(account: String, owner: String, on: Bool) async throws {
        try await ack(["cmd": on ? "owner_enable" : "owner_disable", "account": account, "owner": owner])
    }

    public func ownerNotify(account: String, owner: String, on: Bool) async throws {
        try await ack(["cmd": "owner_notify", "account": account, "owner": owner, "on": on])
    }

    public func ownerSkipDrafts(account: String, owner: String, on: Bool) async throws {
        try await ack(["cmd": "owner_skip_drafts", "account": account, "owner": owner, "on": on])
    }

    public func ownerEvents(account: String, owner: String) async throws -> [String: EventCell] {
        try decode(EventsResponse.self, try await call(["cmd": "owner_events_get", "account": account, "owner": owner])).events
    }

    public func ownerEventsSet(
        account: String, owner: String, event: EventKind, column: EventColumn, on: Bool
    ) async throws -> [String: EventCell] {
        try decode(EventsResponse.self, try await call([
            "cmd": "owner_events_set", "account": account, "owner": owner,
            "event": event.rawValue, "column": column.rawValue, "on": on,
        ])).events
    }

    public func ownerEventsCopy(account: String, from: String, to: String) async throws -> [String: EventCell] {
        try decode(EventsResponse.self, try await call([
            "cmd": "owner_events_copy", "account": account, "from_owner": from, "to_owner": to,
        ])).events
    }

    public func ownerExclusions(account: String, owner: String) async throws -> Exclusions {
        try decode(ExclusionsResponse.self, try await call(["cmd": "owner_exclusions_get", "account": account, "owner": owner])).exclusions
    }

    public func ownerExclusionsSet(
        account: String, owner: String, kind: ExclusionKind, name: String, state: ExclusionState
    ) async throws -> Exclusions {
        try decode(ExclusionsResponse.self, try await call([
            "cmd": "owner_exclusions_set", "account": account, "owner": owner,
            "kind": kind.rawValue, "name": name, "state": state.rawValue,
        ])).exclusions
    }

    public func ownerExclusionsRemove(account: String, owner: String, kind: ExclusionKind, name: String) async throws -> Exclusions {
        try decode(ExclusionsResponse.self, try await call([
            "cmd": "owner_exclusions_remove", "account": account, "owner": owner, "kind": kind.rawValue, "name": name,
        ])).exclusions
    }

    public func tokenSet(account: String, token: String) async throws {
        try await ack(["cmd": "token_set", "account": account, "token": token], slow: true)
    }

    public func tokenTest(account: String?, token: String?) async throws -> [TestResult] {
        var fields: [String: Any] = ["cmd": "token_test"]
        if let account { fields["account"] = account }
        if let token { fields["token"] = token }
        return try decode(TokenTestResponse.self, try await call(fields, slow: true)).results
    }

    public func tokenReset() async throws {
        try await ack(["cmd": "token_reset"])
    }

    public func reset() async throws {
        try await ack(["cmd": "reset"])
    }

    public func shutdown() async throws {
        try await ack(["cmd": "shutdown"])
    }
}
