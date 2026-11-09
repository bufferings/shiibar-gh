import AppKit
import Foundation
@testable import ShiibarGhCore
import XCTest

final class StoreTests: XCTestCase {
    func testReturnTimeRoundTripsThroughThePicker() {
        let calendar = ReturnTime.calendar
        for text in ["00:00", "09:00", "23:59", "07:05"] {
            XCTAssertEqual(ReturnTime.text(ReturnTime.date(text, calendar: calendar), calendar: calendar), text)
        }
        XCTAssertNil(ReturnTime.parse("9:00"))
        XCTAssertNil(ReturnTime.parse("24:00"))
        XCTAssertNil(ReturnTime.parse("ab:cd"))
        XCTAssertEqual(ReturnTime.text(ReturnTime.date(nil, calendar: calendar), calendar: calendar), "09:00", "the default")
    }

    func testTheUIStateIsKeptPerAccount() {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UIStateStore(defaults: defaults)
        XCTAssertNil(store.windowFrame(account: "1001"))
        XCTAssertEqual(store.options(account: "1001"), ListOptions())
        XCTAssertTrue(store.keepOnTop(account: "1001"), "Keep on top is on by default")
        XCTAssertEqual(store.collapsed(account: "1001"), [:])
        XCTAssertEqual(store.activityOwners(account: "1001"), [])
        store.setWindowFrame("{{10, 20}, {460, 620}}", account: "1001")
        store.setOptions(ListOptions(segment: .authored, groupBy: .status, sort: .recentlyAdded), account: "1001")
        store.setKeepOnTop(false, account: "1001")
        store.setCollapsed(["owner:o2": true], account: "1001")
        store.setActivityOwners(["o2", "o4"], account: "1001")
        let again = UIStateStore(defaults: defaults)
        XCTAssertEqual(again.windowFrame(account: "1001"), "{{10, 20}, {460, 620}}")
        XCTAssertEqual(again.options(account: "1001"), ListOptions(segment: .authored, groupBy: .status, sort: .recentlyAdded))
        XCTAssertFalse(again.keepOnTop(account: "1001"))
        XCTAssertTrue(again.keepOnTop(account: "583231"))
        XCTAssertEqual(again.collapsed(account: "1001"), ["owner:o2": true])
        XCTAssertEqual(again.activityOwners(account: "1001"), ["o2", "o4"])
        XCTAssertNil(again.windowFrame(account: "583231"), "another account has its own")
        XCTAssertEqual(again.options(account: "583231"), ListOptions())
    }

    func testPaletteHasDarkVariants() {
        XCTAssertLessThan(Palette.background.dark.red, Palette.background.light.red)
        XCTAssertEqual(Palette.text.resolve(dark: false), RGB(hex: 0x1D1D1F))
        XCTAssertEqual(Palette.text.resolve(dark: true), RGB(hex: 0xECECEE))
    }
}

@MainActor
final class SettingsModelTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var app: AppModel!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        app = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), clock: { T0 })
        app.handle(.snapshot(accounts: [sampleAccount(), Account(id: "583231", login: "bufferings")], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAnInvalidValueShowsTheErrorAndKeepsTheSavedValue() async {
        let settings = SettingsModel(app: app, launch: nil)
        api.config["status_interval_minutes"] = .int(1)
        api.failNext = DaemonError(code: .invalid, message: "status_interval_minutes must be 1 or more")
        settings.set("status_interval_minutes", .int(0))
        await settle()
        XCTAssertEqual(settings.errors["status_interval_minutes"], "status_interval_minutes must be 1 or more")
        XCTAssertEqual(settings.config["status_interval_minutes"], .int(1), "the saved value returns")
        XCTAssertEqual(api.config["status_interval_minutes"], .int(1))
        settings.set("status_interval_minutes", .int(2))
        await settle()
        XCTAssertNil(settings.errors["status_interval_minutes"])
        XCTAssertEqual(settings.config["status_interval_minutes"], .int(2))
    }

    func testDestinationsAndSelection() async {
        let settings = SettingsModel(app: app, launch: nil)
        settings.show(.account("583231"))
        XCTAssertEqual(settings.tab, .accounts)
        XCTAssertEqual(settings.selection, .account("583231"))
        settings.show(.general)
        XCTAssertEqual(settings.tab, .general)
        settings.select(.owner(account: "3407303", owner: "o2"))
        settings.ownerTab = .exclusions
        settings.select(.owner(account: "3407303", owner: "o2"))
        XCTAssertEqual(settings.ownerTab, .exclusions, "the same owner keeps its tab")
        settings.select(.owner(account: "3407303", owner: "o3"))
        XCTAssertEqual(settings.ownerTab, .owner, "another owner opens on Owner")
        XCTAssertEqual(settings.selectedOwner?.name, "acme-corp")
        await settle()
        XCTAssertTrue(api.calls.contains("owner_events_get bufferings-work acme-corp"))
        XCTAssertTrue(api.calls.contains("owner_exclusions_get bufferings-work acme-corp"))
        app.handle(.accountRemoved("3407303"))
        settings.ensureSelection()
        XCTAssertEqual(settings.selection, .account("583231"), "a removed account moves the selection")
        settings.select(.owner(account: "583231", owner: "gone"))
        settings.ensureSelection()
        XCTAssertEqual(settings.selection, .account("583231"))
    }

    func testOwnerControlsSendTheLoginAndPublic() async {
        let settings = SettingsModel(app: app, launch: nil)
        let account = sampleAccount()
        let org = account.owners[0]
        let pub = account.owners[2]
        settings.setColor(account, .blue)
        settings.setOwnerEnabled(pub, of: account, false)
        settings.setOwnerNotify(org, of: account, false)
        settings.setSkipDrafts(org, of: account, true)
        settings.setEvent(org, of: account, .teamReviewRequested, .list, false)
        settings.setExclusion(org, of: account, .repo, " example-org/legacy ", .hidden)
        settings.setExclusion(org, of: account, .user, "  ", .hidden)
        settings.removeExclusion(org, of: account, .user, "renovate")
        settings.removeOwner(pub, of: account)
        settings.removeAccount(account)
        await settle()
        for call in [
            "account_color bufferings-work blue", "owner_enabled bufferings-work public false",
            "owner_notify bufferings-work example-org false", "owner_skip_drafts bufferings-work example-org true",
            "owner_events_set bufferings-work example-org team_review_requested list false",
            "owner_exclusions_set bufferings-work example-org repo example-org/legacy hidden",
            "owner_exclusions_remove bufferings-work example-org user renovate",
            "owner_remove bufferings-work public", "account_remove bufferings-work",
        ] {
            XCTAssertTrue(api.calls.contains(call), call)
        }
        XCTAssertFalse(api.calls.contains { $0.contains("user  ") }, "an empty name is not sent")
        XCTAssertEqual(settings.selection, .account("3407303"), "removing an owner selects its account")
    }

    func testAReadStartedBeforeAChangeDoesNotUndoIt() async {
        let settings = SettingsModel(app: app, launch: nil)
        let account = sampleAccount()
        let org = account.owners[0]
        api.events = ["mentioned": EventCell(list: true, notify: true)]
        api.eventsDelay = 200_000_000
        settings.select(.owner(account: "3407303", owner: "o2"))
        await settle()
        // The user unticks Notify while the read is still on its way.
        api.events = ["mentioned": EventCell(list: true, notify: false)]
        settings.setEvent(org, of: account, .mentioned, .notify, false)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await settle()
        XCTAssertEqual(settings.cell("o2", .mentioned), EventCell(list: true, notify: false), "the late read is dropped")
        // A read started after the change is kept.
        api.eventsDelay = 0
        api.events = ["mentioned": EventCell(list: false, notify: false)]
        settings.loadOwner(account: "3407303", owner: "o2")
        await settle()
        XCTAssertEqual(settings.cell("o2", .mentioned), EventCell(list: false, notify: false))
    }

    func testAFailedEditReadsTheTableAgain() async {
        let settings = SettingsModel(app: app, launch: nil)
        let account = sampleAccount()
        let org = account.owners[0]
        let saved = ["mentioned": EventCell(list: true, notify: true)]
        api.events = saved
        api.eventsDelay = 200_000_000
        settings.select(.owner(account: "3407303", owner: "o2"))
        await settle()
        // The edit is refused while the first read is still on its way.
        api.failNext = DaemonError(code: .invalid, message: "invalid: refused")
        settings.setEvent(org, of: account, .mentioned, .notify, false)
        api.eventsDelay = 0
        try? await Task.sleep(nanoseconds: 400_000_000)
        await settle()
        XCTAssertEqual(settings.errors["events:o2"], "invalid: refused")
        XCTAssertEqual(settings.cell("o2", .mentioned), saved["mentioned"], "the daemon's table is read again")
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("owner_events_get") }.count, 2)
        api.clearCalls()
        api.failNext = DaemonError(code: .invalid, message: "invalid: owner/repo")
        settings.setExclusion(org, of: account, .repo, "bad", .hidden)
        await settle()
        XCTAssertTrue(api.calls.contains("owner_exclusions_get bufferings-work example-org"), "Exclusions are read again too")
    }

    func testAddAccountAndRemoveNeedTheKeychain() {
        let settings = SettingsModel(app: app, launch: nil)
        XCTAssertTrue(settings.canAddAccount)
        XCTAssertTrue(settings.canRemoveAccount)
        for state in [KeychainState.unavailable, .unreadable] {
            app.handle(.keychainChanged(.known(state)))
            XCTAssertFalse(settings.canAddAccount, "\(state)")
            XCTAssertFalse(settings.canRemoveAccount, "\(state)")
        }
        app.handle(.keychainChanged(.known(.ok)))
        XCTAssertTrue(settings.canAddAccount)
    }

    /// DESIGN.md, "Settings": Text size takes 9 to 18 only.
    func testTextSizeFieldAndStepper() async {
        let settings = SettingsModel(app: app, launch: nil)
        XCTAssertTrue(SettingsModel.keys.contains("text_size"))
        settings.config["text_size"] = .int(12)
        settings.setTextSize("19")
        XCTAssertEqual(settings.errors["text_size"], "Enter a number from 9 to 18")
        settings.setTextSize("1.5")
        XCTAssertEqual(settings.errors["text_size"], "Enter a whole number")
        settings.setTextSize("12")
        await settle()
        XCTAssertNil(settings.errors["text_size"])
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("config_set") }, "the same value is not sent")
        settings.setTextSize("14")
        await settle()
        XCTAssertTrue(api.calls.contains("config_set text_size int(14)"))
        settings.config["text_size"] = .int(18)
        api.clearCalls()
        settings.stepTextSize(.larger)
        settings.config["text_size"] = .int(9)
        settings.stepTextSize(.smaller)
        await settle()
        XCTAssertEqual(api.calls, [], "the stepper stops at 9 and 18")
        settings.stepTextSize(.larger)
        await settle()
        XCTAssertEqual(api.calls, ["config_set text_size int(10)"])
    }

    func testNotifyFollowsList() {
        XCTAssertEqual(EventColumn.allCases, [.list, .notify], "two columns")
        XCTAssertTrue(SettingsModel.cellEnabled(EventCell(list: false, notify: false), .list))
        XCTAssertFalse(SettingsModel.cellEnabled(EventCell(list: false, notify: false), .notify))
        XCTAssertTrue(SettingsModel.cellEnabled(EventCell(list: true, notify: false), .notify))
    }

    func testCopyReplacesTheTargetTable() async {
        let settings = SettingsModel(app: app, launch: nil)
        let account = sampleAccount()
        api.events = ["mentioned": EventCell(list: true, notify: false)]
        XCTAssertEqual(settings.otherOwners(of: "o2", in: account).map(\.id), ["o3", "o4"])
        var copied: Bool?
        settings.copyTable(from: account.owners[1], to: account.owners[0], of: account) { copied = $0 }
        await settle()
        XCTAssertEqual(copied, true)
        XCTAssertTrue(api.calls.contains("owner_events_copy bufferings-work acme-corp example-org"))
        XCTAssertEqual(settings.cell("o2", .mentioned), EventCell(list: true, notify: false))
    }
}

@MainActor
final class SheetTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var app: AppModel!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        app = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), clock: { T0 })
        var me = sampleAccount()
        me.token = TokenInfo(registered: true, lastTest: LastTest(at: 100, results: []))
        app.handle(.snapshot(accounts: [me], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Sheets.html: the result list is there before Test, names only, so
    /// the sheet keeps its height.
    func testTheResultListIsReservedBeforeTheTest() async {
        let add = TokenSheetModel(mode: .add, app: app)
        XCTAssertEqual(add.resultRows, ["Account", "Scopes", "Notifications", "Team membership"].map(ResultRow.placeholder))
        let edit = TokenSheetModel(mode: .edit("3407303"), app: app)
        XCTAssertEqual(edit.resultRows, ["Account", "Scopes", "Notifications", "Team membership", "example-org", "acme-corp"].map(ResultRow.placeholder), "Public has none")
        let result = TestResult(item: .scopes, label: "Scopes", outcome: .ok, text: "OK")
        let org = TestResult(item: .owner, label: "example-org", owner: "o2", outcome: .ok, text: "OK")
        let publicRow = TestResult(item: .owner, label: "Public", owner: "o4", outcome: .failed, text: "Failed")
        api.testResults = [result, org, publicRow]
        edit.test()
        await settle()
        XCTAssertEqual(edit.resultRows, [.result(TestResultLine(result)), .result(TestResultLine(org))], "the daemon's Public row is left out")
        XCTAssertFalse(edit.showsSaveLater, "Public's failure does not count either")
        let unknownId = TestResult(item: .owner, label: "public", owner: "gone", outcome: .ok, text: "OK")
        XCTAssertTrue(edit.isPublicRow(unknownId), "by its label when the id is unknown")
    }

    func testAddAccountTestsWithoutAnAccountAndSavesWithAccountAdd() async {
        let sheet = TokenSheetModel(mode: .add, app: app)
        XCTAssertEqual(sheet.title, "Add account")
        XCTAssertEqual(sheet.placeholder, "")
        XCTAssertFalse(sheet.canTest, "nothing pasted")
        XCTAssertFalse(sheet.canSave)
        sheet.token = "  ghp_secret\n"
        XCTAssertTrue(sheet.canSave, "Save without a test is allowed")
        api.testResults = [
            TestResult(item: .account, label: "Account", outcome: .ok, text: "bufferings"),
            TestResult(item: .scopes, label: "Scopes", outcome: .failed, text: "Missing (read:org)"),
        ]
        sheet.test()
        await settle()
        XCTAssertEqual(api.calls.last, "token_test - pasted")
        XCTAssertTrue(sheet.showsSaveLater)
        XCTAssertTrue(sheet.canSave)
        var saved: Bool?
        sheet.save { saved = $0 }
        XCTAssertEqual(sheet.token, "", "the field is cleared as the token goes")
        await settle()
        XCTAssertEqual(saved, true)
        XCTAssertEqual(api.calls.last, "account_add")
        XCTAssertTrue(app.isChecking("9919001"), "Checking… until the daemon's test arrives")
        app.handle(.accountChanged(Account(id: "9919001", login: "new", token: TokenInfo(lastTest: LastTest(at: T0, results: [])))))
        XCTAssertFalse(app.isChecking("9919001"))
    }

    func testAFailedAccountItemBlocksSave() async {
        let sheet = TokenSheetModel(mode: .add, app: app)
        sheet.token = "ghp_x"
        api.testResults = [TestResult(item: .account, label: "Account", outcome: .failed, text: "bufferings-work is already added")]
        sheet.test()
        await settle()
        XCTAssertFalse(sheet.canSave)
        sheet.token = "ghp_y"
        XCTAssertNil(sheet.results, "a new paste drops the old results")
        XCTAssertTrue(sheet.canSave)
        api.failNext = DaemonError(code: .invalid, message: "bufferings-work is already added")
        var saved: Bool?
        sheet.save { saved = $0 }
        await settle()
        XCTAssertEqual(saved, false)
        XCTAssertEqual(sheet.error, "bufferings-work is already added")
    }

    func testEditTestsTheSavedTokenUntilANewOneIsPasted() async {
        let sheet = TokenSheetModel(mode: .edit("3407303"), app: app)
        XCTAssertEqual(sheet.title, "Token for bufferings-work")
        XCTAssertEqual(sheet.placeholder, TokenState.masked)
        XCTAssertTrue(sheet.canTest, "the saved token")
        XCTAssertFalse(sheet.canSave, "only a pasted token saves")
        sheet.test()
        await settle()
        XCTAssertEqual(api.calls.last, "token_test bufferings-work saved")
        sheet.token = "ghp_new"
        sheet.test()
        await settle()
        XCTAssertEqual(api.calls.last, "token_test bufferings-work pasted")
        var saved: Bool?
        sheet.save { saved = $0 }
        await settle()
        XCTAssertEqual(saved, true)
        XCTAssertEqual(api.calls.last, "token_set bufferings-work")
        XCTAssertTrue(app.isChecking("3407303"))
        var same = sampleAccount()
        same.token = TokenInfo(lastTest: nil)
        app.handle(.accountChanged(same))
        XCTAssertTrue(app.isChecking("3407303"), "the save cleared last_test; still checking")
        same.token = TokenInfo(lastTest: LastTest(at: 100, results: []))
        app.handle(.accountChanged(same))
        XCTAssertTrue(app.isChecking("3407303"), "the old test does not end it")
        same.token = TokenInfo(lastTest: LastTest(at: T0, results: []))
        app.handle(.accountChanged(same))
        XCTAssertFalse(app.isChecking("3407303"))
    }

    func testEditOfAnAccountWithoutATokenStartsEmpty() {
        var me = sampleAccount()
        me.token = TokenInfo(registered: false)
        app.handle(.accountChanged(me))
        let sheet = TokenSheetModel(mode: .edit("3407303"), app: app)
        XCTAssertEqual(sheet.placeholder, "")
        XCTAssertFalse(sheet.canTest)
    }

    func testAddOwnerShowsWhyItFailedAndStaysOpen() async {
        api.ownerErrors["nobody"] = DaemonError(code: .notFound, message: "not found: owner nobody")
        api.ownerErrors["offline"] = DaemonError(code: .unreachable, message: "unreachable")
        let sheet = AddOwnerModel(account: "3407303", app: app)
        XCTAssertFalse(sheet.canAdd, "nothing typed")
        XCTAssertTrue(sheet.hasPublic)
        XCTAssertFalse(sheet.canAddPublic, "Public is there already")
        var closed = 0
        sheet.name = "nobody"
        sheet.add { closed += 1 }
        await settle()
        XCTAssertEqual(sheet.error, "Owner not found")
        sheet.name = "offline"
        XCTAssertNil(sheet.error, "typing clears it")
        sheet.add { closed += 1 }
        await settle()
        XCTAssertEqual(sheet.error, "Couldn't reach GitHub")
        sheet.name = " example-org "
        sheet.add { closed += 1 }
        await settle()
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(api.calls.last, "owner_add bufferings-work example-org")
    }

    func testAddPublicAndTheKeychainRule() async {
        app.handle(.accountChanged(Account(id: "3407303", login: "bufferings-work")))
        let sheet = AddOwnerModel(account: "3407303", app: app)
        XCTAssertTrue(sheet.canAddPublic)
        var closed = false
        sheet.addPublic { closed = true }
        await settle()
        XCTAssertTrue(closed)
        XCTAssertEqual(api.calls.last, "owner_add bufferings-work public")
        app.handle(.keychainChanged(.known(.unavailable)))
        sheet.name = "example-org"
        XCTAssertFalse(sheet.canAdd, "Add needs the token, which cannot be read")
    }
}

final class LauncherEnvironmentTests: XCTestCase {
    /// The launched daemon gets the app's environment, so
    /// `SHIIBAR_GH_STATE_DIR` reaches it (docs/tasks/M3.md, "Daemon
    /// lifecycle"). A stand-in script records what it received.
    func testTheStateDirectoryOverrideIsPassedOn() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = (dir as NSString).appendingPathComponent("fake-daemon")
        let out = (dir as NSString).appendingPathComponent("seen")
        try "#!/bin/sh\nprintf '%s %s' \"$SHIIBAR_GH_STATE_DIR\" \"$1\" > \"\(out)\"\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let previous = ProcessInfo.processInfo.environment["SHIIBAR_GH_STATE_DIR"]
        setenv("SHIIBAR_GH_STATE_DIR", dir, 1)
        defer {
            if let previous { setenv("SHIIBAR_GH_STATE_DIR", previous, 1) } else { unsetenv("SHIIBAR_GH_STATE_DIR") }
        }
        let launcher = ProcessDaemonLauncher(executable: URL(fileURLWithPath: script), stateRoot: dir)
        try launcher.launch()
        let deadline = Date().addingTimeInterval(10)
        while (try? String(contentsOfFile: out, encoding: .utf8)) == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "\(dir) --foreground")
        XCTAssertTrue(FileManager.default.fileExists(atPath: StateDirectory.daemonLog(root: dir)))
    }
}

@MainActor
final class LaunchSyncTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAChangedSettingMovesTheLoginItem() async {
        let item = FakeLoginItem(.enabled)
        let launch = LaunchAtLogin(service: item, api: api, store: UIStateStore(defaults: defaults))
        api.config["launch_at_login"] = .bool(false)
        await launch.configChanged(key: "launch_at_login", value: .bool(false))
        XCTAssertEqual(item.calls, ["unregister"])
        await launch.configChanged(key: "launch_at_login", value: .bool(false))
        XCTAssertEqual(item.calls, ["unregister"], "already off")
        await launch.configChanged(key: "status_interval_minutes", value: .int(2))
        XCTAssertEqual(item.calls, ["unregister"], "another key")
        api.config["launch_at_login"] = .bool(true)
        await launch.configChanged(key: "launch_at_login", value: .bool(true))
        XCTAssertEqual(item.calls, ["unregister", "register"])
        XCTAssertEqual(api.config["launch_at_login"], .bool(true))
    }

    func testARefusedChangeWritesWhatMacOSHasBack() async {
        let item = RefusingLoginItem()
        let launch = LaunchAtLogin(service: item, api: api, store: UIStateStore(defaults: defaults))
        api.config["launch_at_login"] = .bool(true)
        await launch.configChanged(key: "launch_at_login", value: .bool(true))
        XCTAssertEqual(api.config["launch_at_login"], .bool(false))
    }

    func testOpeningSettingsWritesASystemSettingsChangeToTheSetting() async {
        // The user turned the login item off in System Settings.
        let item = FakeLoginItem(.notRegistered)
        let launch = LaunchAtLogin(service: item, api: api, store: UIStateStore(defaults: defaults))
        let app = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), clock: { T0 })
        let settings = SettingsModel(app: app, launch: launch)
        api.config["launch_at_login"] = .bool(true)
        settings.windowOpened()
        await settle()
        settings.windowClosed()
        XCTAssertEqual(api.config["launch_at_login"], .bool(false))
        XCTAssertEqual(settings.config["launch_at_login"], .bool(false))
        XCTAssertFalse(settings.launchOn)
        XCTAssertEqual(item.calls, [], "the setting follows macOS, not the other way")
    }

    func testTheSettingsCheckboxFollowsACLIChangeOnceTheLoginItemMoved() async {
        let item = FakeLoginItem(.enabled)
        let launch = LaunchAtLogin(service: item, api: api, store: UIStateStore(defaults: defaults))
        let app = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), clock: { T0 })
        let settings = SettingsModel(app: app, launch: launch)
        settings.refreshLaunch()
        XCTAssertTrue(settings.launchOn)
        app.observeConfig { key, value in
            Task { await launch.configChanged(key: key, value: value) }
        }
        // `shiibar-gh config set launch_at_login false` elsewhere.
        api.config["launch_at_login"] = .bool(false)
        app.handle(.configChanged(key: "launch_at_login", value: .bool(false)))
        await settle()
        XCTAssertEqual(item.calls, ["unregister"])
        XCTAssertFalse(settings.launchOn, "read after the login item changed")
        XCTAssertEqual(settings.launchStatus, .notRegistered)
    }

    func testSettingsFollowConfigChanged() async {
        let app = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), clock: { T0 })
        let settings = SettingsModel(app: app, launch: nil)
        app.handle(.configChanged(key: "drop_after_days", value: .int(20)))
        XCTAssertEqual(settings.config["drop_after_days"], .int(20))
    }
}

final class RefusingLoginItem: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    struct Refused: Error {}
    func register() throws { throw Refused() }
    func unregister() throws { throw Refused() }
    func openSystemSettings() {}
}

@MainActor
final class MainMenuTests: XCTestCase {
    /// ⌘V reaches a text field only through a menu item with that key
    /// equivalent and no target, so the first responder gets `paste:`.
    func testTheEditMenuCarriesTheTextShortcutsForTheFirstResponder() throws {
        let menu = MainMenu.make()
        let edit = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let items = edit.items.filter { !$0.isSeparatorItem }
        let found = items.map { item in
            "\(item.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")⌘\(item.keyEquivalent) \(item.action.map(NSStringFromSelector) ?? "-")"
        }
        XCTAssertEqual(found, ["⌘z undo:", "⇧⌘z redo:", "⌘x cut:", "⌘c copy:", "⌘v paste:", "⌘a selectAll:"])
        XCTAssertTrue(items.allSatisfy { $0.target == nil })
        XCTAssertEqual(menu.items.count, 2, "the app menu and Edit only")
    }

    @MainActor
    func testTheAppMenuHasAboutSettingsCloseWindowAndQuit() throws {
        var ran: [String] = []
        let menu = MainMenu.make(MainMenu.Actions(about: { ran.append("about") }, settings: { ran.append("settings") }))
        let app = try XCTUnwrap(menu.items.first?.submenu)
        let items = app.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.map(\.title), ["About shiibar-gh", "Settings…", "Close Window", "Quit shiibar-gh"])
        XCTAssertEqual(items.map(\.keyEquivalent), ["", ",", "w", "q"])
        XCTAssertEqual(items[2].action, #selector(NSWindow.performClose(_:)))
        XCTAssertNil(items[2].target, "the key window closes; none, and it is disabled")
        XCTAssertEqual(items[3].action, #selector(NSApplication.terminate(_:)), "the same path as the ⌄ Quit")
        app.performActionForItem(at: app.index(of: items[1]))
        app.performActionForItem(at: app.index(of: items[0]))
        XCTAssertEqual(ran, ["settings", "about"])
    }

    func testTheAppIsRegularWhileAWindowOrSettingsIsOpen() {
        var windows = RegularWindows()
        XCTAssertTrue(windows.opened("window:org"), "regular")
        XCTAssertFalse(windows.opened("settings"))
        XCTAssertFalse(windows.opened("window:org"))
        XCTAssertFalse(windows.closed("window:org"), "Settings is still open")
        XCTAssertTrue(windows.isRegular)
        XCTAssertTrue(windows.closed("settings"), "back to the accessory app")
        XCTAssertFalse(windows.closed("settings"))
        XCTAssertFalse(windows.isRegular)
    }

    /// A text field handles the selector the ⌘V item sends.
    @MainActor
    func testATextFieldEditorAnswersTheEditActions() {
        let editor = NSTextView()
        for item in MainMenu.editItems where item.action != "redo:" && item.action != "undo:" {
            XCTAssertTrue(editor.responds(to: NSSelectorFromString(item.action)), item.action)
        }
    }
}

@MainActor
final class AppearanceTests: XCTestCase {
    func testTheAppearanceIsLoadedAndFollowsConfigChanged() async {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = FakeAPI()
        api.config["appearance"] = .string("dark")
        let app = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), clock: { T0 })
        var applied: [AppAppearance] = []
        let follower = AppearanceFollower(app: app) { applied.append($0) }
        await follower.load()
        XCTAssertEqual(applied, [.dark])
        app.handle(.configChanged(key: "appearance", value: .string("light")))
        app.handle(.configChanged(key: "drop_after_days", value: .int(3)))
        app.handle(.configChanged(key: "appearance", value: .string("sepia")))
        XCTAssertEqual(applied, [.dark, .light, .system], "an unknown value follows the Mac")
        XCTAssertEqual(follower.current, .system)
    }

    func testTitlesAndDefault() {
        XCTAssertEqual(AppAppearance.allCases.map(\.title), ["System", "Light", "Dark"])
        XCTAssertEqual(AppAppearance(nil), .system)
        XCTAssertEqual(AppAppearance(.string("dark")), .dark)
    }
}

