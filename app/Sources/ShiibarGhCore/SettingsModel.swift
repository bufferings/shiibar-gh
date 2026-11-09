// Settings without a screen (DESIGN.md, "Settings" and "Settings rules";
// Settings.html, SettingsOwner.html, Sheets.html). Every value goes straight
// to the daemon; nothing waits for a Save button except inside the sheets.
// A value the daemon refuses is not kept: the error shows and the saved value
// returns. A pasted token lives in its sheet's field only until Save or
// Cancel hands it to the daemon or drops it.

import Foundation

public enum SettingsTab: String, CaseIterable {
    case general = "General", accounts = "Accounts", watching = "Watching"
}

/// What the Accounts sidebar has selected.
public enum AccountsSelection: Equatable, Hashable {
    case account(String)
    case owner(account: String, owner: String)

    public var account: String {
        switch self {
        case .account(let id), .owner(let id, _): return id
        }
    }
}

/// The three tabs of an owner (a segment), Owner first.
public enum OwnerTab: String, CaseIterable {
    case owner = "Owner", notifications = "Notifications", exclusions = "Exclusions"
}

@MainActor
public final class SettingsModel: ObservableObject {
    public let app: AppModel
    public let launch: LaunchAtLogin?
    @Published public var tab: SettingsTab = .general
    @Published public private(set) var selection: AccountsSelection?
    @Published public var ownerTab: OwnerTab = .owner
    @Published public var config: [String: ConfigValue] = [:]
    @Published public var errors: [String: String] = [:]
    @Published public var launchOn = false
    @Published public var launchStatus: LoginItemStatus = .notRegistered
    /// Event tables and Exclusions by owner id, read when an owner shows.
    @Published public private(set) var events: [String: [String: EventCell]] = [:]
    @Published public private(set) var exclusions: [String: Exclusions] = [:]
    public private(set) var isOpen = false
    /// Bumped by every change the user makes to an owner's table or
    /// Exclusions: a read started before it is dropped, so it cannot undo
    /// the change.
    private var ownerEdits: [String: Int] = [:]

    public static let keys = [
        "launch_at_login", "appearance", "text_size", "status_interval_minutes", "reactions_interval_minutes",
        "snooze_return_time", "keep_watching_days", "drop_after_days",
    ]

    public init(app: AppModel, launch: LaunchAtLogin?) {
        self.app = app
        self.launch = launch
        app.observeConfig { [weak self] key, value in
            self?.config[key] = value
        }
        launch?.onStatusChange = { [weak self] in self?.refreshLaunch() }
    }

    // MARK: - Window

    public func windowOpened() {
        isOpen = true
        reload()
    }

    public func windowClosed() {
        isOpen = false
    }

    /// Where a Settings button goes.
    public func show(_ destination: SettingsDestination) {
        switch destination {
        case .general:
            tab = .general
        case .accounts:
            tab = .accounts
            ensureSelection()
        case .account(let id):
            tab = .accounts
            select(.account(id))
        }
    }

    /// Opening Settings also writes the login item as macOS has it to the
    /// setting, in case it was changed in System Settings.
    public func reload() {
        refreshLaunch()
        ensureSelection()
        let api = app.api
        let launch = self.launch
        Task {
            await launch?.syncConfig()
            for key in Self.keys {
                if let value = try? await api.configGet(key) {
                    config[key] = value
                }
            }
        }
        if case .owner(let account, let owner) = selection {
            loadOwner(account: account, owner: owner)
        }
    }

    // MARK: - Selection

    public func select(_ selection: AccountsSelection) {
        let changed = self.selection != selection
        self.selection = selection
        if case .owner(let account, let owner) = selection {
            if changed { ownerTab = .owner }
            loadOwner(account: account, owner: owner)
        }
    }

    /// The selection, or the first account when it went away.
    public func ensureSelection() {
        let accounts = app.accounts
        if let selection, let account = accounts.first(where: { $0.id == selection.account }) {
            if case .owner(_, let owner) = selection, account.owner(owner) == nil {
                self.selection = .account(account.id)
            }
            return
        }
        selection = accounts.first.map { .account($0.id) }
    }

    public var selectedAccount: Account? {
        selection.flatMap { app.account($0.account) }
    }

    public var selectedOwner: Owner? {
        guard case .owner(let account, let owner) = selection else { return nil }
        return app.account(account)?.owner(owner)
    }

    /// Add account… and an account's Remove… need the Keychain (DESIGN.md,
    /// "When the Keychain cannot be read").
    public var canAddAccount: Bool { app.keychain == .ok }
    public var canRemoveAccount: Bool { app.keychain == .ok }

    /// The account's other owners, for Copy from.
    public func otherOwners(of owner: String, in account: Account) -> [Owner] {
        account.owners.filter { $0.id != owner }
    }

    // MARK: - General and Watching

    public func refreshLaunch() {
        guard let launch else { return }
        launchStatus = launch.status
        launchOn = launch.isOn
    }

    public func setLaunch(_ on: Bool) {
        guard let launch else { return }
        Task {
            do {
                try await launch.set(on)
                errors["launch_at_login"] = nil
            } catch {
                errors["launch_at_login"] = "\(error.localizedDescription)"
            }
            refreshLaunch()
        }
    }

    public func set(_ key: String, _ value: ConfigValue) {
        let api = app.api
        Task {
            do {
                config[key] = try await api.configSet(key, value)
                errors[key] = nil
            } catch {
                errors[key] = "\(error)"
                if let saved = try? await api.configGet(key) { config[key] = saved }
            }
        }
    }

    /// Text size from the field: a whole number from 9 to 18; anything
    /// else shows its message and the saved value stays.
    public func setTextSize(_ text: String) {
        switch TextSize.parse(text) {
        case .success(let size):
            errors[TextSize.configKey] = nil
            if textSize != size { set(TextSize.configKey, .int(Int64(size))) }
        case .failure(let error):
            errors[TextSize.configKey] = error.message
        }
    }

    /// − and + of the stepper; nothing at the ends.
    public func stepTextSize(_ change: TextSize.Change) {
        guard let size = TextSize.next(textSize, change) else { return }
        errors[TextSize.configKey] = nil
        set(TextSize.configKey, .int(Int64(size)))
    }

    public var textSize: Int {
        TextSize.clamp(config[TextSize.configKey]?.intValue)
    }

    // MARK: - Accounts

    private func run(_ errorKey: String, _ request: @escaping (DaemonAPI) async throws -> Void, then: (() -> Void)? = nil) {
        let api = app.api
        Task {
            do {
                try await request(api)
                errors[errorKey] = nil
                then?()
            } catch {
                errors[errorKey] = "\(error)"
            }
        }
    }

    public func setColor(_ account: Account, _ color: AccountColor) {
        let login = account.login
        run("color:" + account.id) { try await $0.accountColor(login, color) }
    }

    public func removeAccount(_ account: Account) {
        let login = account.login
        run("account:" + account.id) { try await $0.accountRemove(login) }
    }

    public func removeOwner(_ owner: Owner, of account: Account) {
        let login = account.login
        let argument = owner.argument
        run("owner:" + owner.id, { _ = try await $0.ownerRemove(account: login, owner: argument) }) { [weak self] in
            self?.select(.account(account.id))
        }
    }

    public func setOwnerEnabled(_ owner: Owner, of account: Account, _ on: Bool) {
        let login = account.login
        let argument = owner.argument
        run("owner:" + owner.id) { try await $0.ownerEnabled(account: login, owner: argument, on: on) }
    }

    public func setOwnerNotify(_ owner: Owner, of account: Account, _ on: Bool) {
        let login = account.login
        let argument = owner.argument
        run("owner:" + owner.id) { try await $0.ownerNotify(account: login, owner: argument, on: on) }
    }

    public func setSkipDrafts(_ owner: Owner, of account: Account, _ on: Bool) {
        let login = account.login
        let argument = owner.argument
        run("owner:" + owner.id) { try await $0.ownerSkipDrafts(account: login, owner: argument, on: on) }
    }

    // MARK: - Owner tables

    public func loadOwner(account id: String, owner ownerId: String) {
        guard let account = app.account(id), let owner = account.owner(ownerId) else { return }
        let api = app.api
        let edits = ownerEdits[owner.id, default: 0]
        Task {
            do {
                let table = try await api.ownerEvents(account: account.login, owner: owner.argument)
                let list = try await api.ownerExclusions(account: account.login, owner: owner.argument)
                // The user changed something meanwhile: the answers to the
                // changes are newer than this read.
                guard ownerEdits[owner.id, default: 0] == edits else { return }
                events[owner.id] = table
                exclusions[owner.id] = list
                errors["owner:" + owner.id] = nil
            } catch {
                errors["owner:" + owner.id] = "\(error)"
            }
        }
    }

    /// The cell of the table, off while the daemon has not answered.
    public func cell(_ owner: String, _ kind: EventKind) -> EventCell {
        events[owner]?[kind.rawValue] ?? EventCell(list: false, notify: false)
    }

    /// Notify follows List: List off turns it off and it cannot
    /// be turned on while it is off (DESIGN.md, "Applying the table").
    public static func cellEnabled(_ cell: EventCell, _ column: EventColumn) -> Bool {
        column == .list || cell.list
    }

    /// A refused edit may have dropped a read that was on its way: read the
    /// owner again so the screen shows what the daemon has.
    private func reloadAfterFailedEdit(_ account: Account, _ owner: String) {
        loadOwner(account: account.id, owner: owner)
    }

    private func edited(_ owner: String) {
        ownerEdits[owner, default: 0] += 1
    }

    public func setEvent(_ owner: Owner, of account: Account, _ kind: EventKind, _ column: EventColumn, _ on: Bool) {
        edited(owner.id)
        let api = app.api
        Task {
            do {
                events[owner.id] = try await api.ownerEventsSet(
                    account: account.login, owner: owner.argument, event: kind, column: column, on: on
                )
                errors["events:" + owner.id] = nil
            } catch {
                errors["events:" + owner.id] = "\(error)"
                reloadAfterFailedEdit(account, owner.id)
            }
        }
    }

    /// The table of another owner for the Copy sheet, read only.
    public func readTable(_ owner: Owner, of account: Account) async -> [String: EventCell]? {
        try? await app.api.ownerEvents(account: account.login, owner: owner.argument)
    }

    public func copyTable(from: Owner, to: Owner, of account: Account, done: @escaping (Bool) -> Void) {
        edited(to.id)
        let api = app.api
        Task {
            do {
                events[to.id] = try await api.ownerEventsCopy(account: account.login, from: from.argument, to: to.argument)
                errors["events:" + to.id] = nil
                done(true)
            } catch {
                errors["events:" + to.id] = "\(error)"
                reloadAfterFailedEdit(account, to.id)
                done(false)
            }
        }
    }

    public func setExclusion(_ owner: Owner, of account: Account, _ kind: ExclusionKind, _ name: String, _ state: ExclusionState) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edited(owner.id)
        let api = app.api
        Task {
            do {
                exclusions[owner.id] = try await api.ownerExclusionsSet(
                    account: account.login, owner: owner.argument, kind: kind, name: trimmed, state: state
                )
                errors["exclusions:\(kind.rawValue):" + owner.id] = nil
            } catch {
                errors["exclusions:\(kind.rawValue):" + owner.id] = "\(error)"
                reloadAfterFailedEdit(account, owner.id)
            }
        }
    }

    public func removeExclusion(_ owner: Owner, of account: Account, _ kind: ExclusionKind, _ name: String) {
        edited(owner.id)
        let api = app.api
        Task {
            do {
                exclusions[owner.id] = try await api.ownerExclusionsRemove(account: account.login, owner: owner.argument, kind: kind, name: name)
                errors["exclusions:\(kind.rawValue):" + owner.id] = nil
            } catch {
                errors["exclusions:\(kind.rawValue):" + owner.id] = "\(error)"
                reloadAfterFailedEdit(account, owner.id)
            }
        }
    }
}

// MARK: - Sheets

/// The Add account… and Edit… sheets (DESIGN.md, "Add account… and Edit…
/// sheets"). `token` is the field; it is cleared on Save and on Cancel.
@MainActor
public final class TokenSheetModel: ObservableObject {
    public enum Mode: Equatable {
        case add
        case edit(String)
    }

    public let mode: Mode
    private let app: AppModel
    @Published public var token = "" {
        didSet { if token != oldValue { results = nil } }
    }
    @Published public private(set) var results: [TestResult]?
    @Published public private(set) var testing = false
    @Published public private(set) var saving = false
    @Published public private(set) var error: String?

    public init(mode: Mode, app: AppModel) {
        self.mode = mode
        self.app = app
    }

    public var account: Account? {
        if case .edit(let id) = mode { return app.account(id) }
        return nil
    }

    public var title: String {
        switch mode {
        case .add: return "Add account"
        case .edit: return SettingsText.tokenSheetTitle(account?.login ?? "")
        }
    }

    /// Edit… of a saved token shows the 12 dots while nothing is pasted.
    public var placeholder: String {
        (account?.token.registered ?? false) ? TokenState.masked : ""
    }

    private var pasted: String? {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Add account tests the pasted token; Edit… the pasted one, or the
    /// saved one while nothing is pasted.
    public var canTest: Bool {
        guard !testing && !saving else { return false }
        switch mode {
        case .add: return pasted != nil
        case .edit: return pasted != nil || (account?.token.registered ?? false)
        }
    }

    /// Save needs a pasted token and an Account item that did not fail.
    public var canSave: Bool {
        !testing && !saving && pasted != nil && !TestResultLine.accountFailed(results ?? [])
    }

    /// The result list, there from the start (Sheets.html): before a test
    /// the four items and, in Edit…, one row per owner other than Public,
    /// names only; after a test the results. Public has no row ("Public has
    /// none"), so the daemon's row for it is left out.
    public var resultRows: [ResultRow] {
        if let results = shownResults { return results.map { ResultRow.result(TestResultLine($0)) } }
        var labels = ["Account", "Scopes", "Notifications", "Team membership"]
        labels += (account?.owners ?? []).filter { !$0.isPublic }.map(\.displayName)
        return labels.map(ResultRow.placeholder)
    }

    /// The results without Public's row.
    var shownResults: [TestResult]? {
        results.map { list in list.filter { !isPublicRow($0) } }
    }

    func isPublicRow(_ result: TestResult) -> Bool {
        guard result.item.value == .owner else { return false }
        if let id = result.owner, let owner = account?.owner(id) { return owner.isPublic }
        return result.label.lowercased() == "public"
    }

    public var showsSaveLater: Bool {
        guard let results = shownResults else { return false }
        return !TestResultLine.allOK(results)
    }

    public func test() {
        guard canTest else { return }
        let token = pasted
        let login: String?
        if case .edit = mode {
            guard let account else { return }
            login = account.login
        } else {
            login = nil
        }
        testing = true
        error = nil
        let api = app.api
        Task {
            do {
                let results = try await api.tokenTest(account: login, token: token)
                self.results = results
            } catch {
                self.error = "\(error)"
            }
            testing = false
        }
    }

    /// `account_add` or `token_set`; the field is cleared as the token goes.
    public func save(done: @escaping (Bool) -> Void) {
        guard canSave, let token = pasted else { return }
        self.token = ""
        saving = true
        error = nil
        let api = app.api
        let app = self.app
        switch mode {
        case .add:
            Task {
                do {
                    let account = try await api.accountAdd(token: token)
                    app.tokenSaved(account, before: nil)
                    saving = false
                    done(true)
                } catch {
                    self.error = "\(error)"
                    saving = false
                    done(false)
                }
            }
        case .edit:
            guard let account else { return }
            let before = account.token.lastTest?.at
            Task {
                do {
                    try await api.tokenSet(account: account.login, token: token)
                    app.tokenSaved(app.account(account.id) ?? account, before: before)
                    saving = false
                    done(true)
                } catch {
                    self.error = "\(error)"
                    saving = false
                    done(false)
                }
            }
        }
    }

    public func cancel() {
        token = ""
        results = nil
    }
}

/// A line of the token sheet's result list.
public enum ResultRow: Equatable {
    /// The label alone, faint, before a test.
    case placeholder(String)
    case result(TestResultLine)
}

/// The Add owner sheet (DESIGN.md, "Add owner… sheet").
@MainActor
public final class AddOwnerModel: ObservableObject {
    private let app: AppModel
    public let accountId: String
    @Published public var name = "" {
        didSet { if name != oldValue { error = nil } }
    }
    @Published public private(set) var error: String?
    @Published public private(set) var busy = false

    public init(account: String, app: AppModel) {
        accountId = account
        self.app = app
    }

    public var account: Account? { app.account(accountId) }

    /// Add asks GitHub through the account's token: not while the Keychain
    /// cannot be read.
    public var canAdd: Bool {
        !busy && app.keychain == .ok && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var hasPublic: Bool { account?.owners.contains(where: \.isPublic) ?? false }

    public var canAddPublic: Bool { !busy && !hasPublic }

    public func add(done: @escaping () -> Void) {
        guard canAdd else { return }
        request(name.trimmingCharacters(in: .whitespaces), done: done)
    }

    public func addPublic(done: @escaping () -> Void) {
        guard canAddPublic else { return }
        request("public", done: done)
    }

    private func request(_ owner: String, done: @escaping () -> Void) {
        guard let login = account?.login else { return }
        busy = true
        error = nil
        let api = app.api
        Task {
            do {
                _ = try await api.ownerAdd(account: login, owner: owner)
                busy = false
                done()
            } catch {
                self.error = SettingsText.addOwnerError(error)
                busy = false
            }
        }
    }
}
