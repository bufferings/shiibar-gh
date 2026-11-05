import Darwin
import Foundation
@testable import ShiibarGhCore
import XCTest

final class SurfaceRuleTests: XCTestCase {
    func testWhatAPopoverShows() {
        let plain = Scope(id: "o", kind: .org)
        let noToken = Scope(id: "o", kind: .org, warnings: [Warning(kind: .noToken, token: .notifications)])
        XCTAssertEqual(SurfaceRules.content(scope: plain, dbUnreadable: false), .list)
        XCTAssertEqual(SurfaceRules.content(scope: noToken, dbUnreadable: false), .noToken)
        XCTAssertEqual(SurfaceRules.content(scope: noToken, dbUnreadable: true), .unreadable)
        XCTAssertEqual(SurfaceRules.noScopeContent(dbUnreadable: false), .noScopes)
        XCTAssertEqual(SurfaceRules.noScopeContent(dbUnreadable: true), .unreadable, "Reset, not No scopes yet")
    }

    func testTheAppIconShowsWhenNoScopeIconDoes() {
        XCTAssertTrue(SurfaceRules.showsAppIcon([]))
        XCTAssertTrue(SurfaceRules.showsAppIcon([Scope(id: "a", enabled: false), Scope(id: "b", enabled: false)]))
        XCTAssertFalse(SurfaceRules.showsAppIcon([Scope(id: "a", enabled: false), Scope(id: "b")]))
    }

    func testEmptyStateWording() {
        XCTAssertEqual(EmptyState.noScopesTitle, "No scopes yet")
        XCTAssertEqual(EmptyState.noScopesDetail, "Add a scope in Settings")
        XCTAssertEqual(EmptyState.noToken, "Add a token in Settings")
        XCTAssertEqual(EmptyState.unreadable, "Couldn't read saved state")
        XCTAssertEqual(EmptyState.activity, "No activity")
    }

    func testSettingsButtonsGoWhereTheSpecSays() {
        XCTAssertEqual(SurfaceRules.bannerSettings, .scopes)
        XCTAssertEqual(SurfaceRules.noTokenSettings, .scopes)
        XCTAssertEqual(SurfaceRules.noScopesSettings, .scopes)
        XCTAssertEqual(SurfaceRules.headerSettings, .general)
    }

    func testSnoozedUntilUsesTheNextReturnTimeFromTheCard() {
        // 2027-01-18 09:00 in Tokyo is a Monday.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let at = Int64(calendar.date(from: DateComponents(year: 2027, month: 1, day: 18, hour: 9))!.timeIntervalSince1970)
        XCTAssertEqual(SurfaceRules.snoozedUntil(at, timeZone: tokyo), "Snoozed until Mon 09:00")
    }
}

final class SettingsTextTests: XCTestCase {
    func testFullTestResultLines() {
        XCTAssertEqual(TokenState.resultLine(TestResult(item: "Checks", outcome: .ok)), "OK · Checks")
        XCTAssertEqual(TokenState.resultLine(TestResult(item: "Checks", outcome: .failed, missing: "Actions")), "Failed (Actions) · Checks")
        XCTAssertEqual(TokenState.resultLine(TestResult(item: "Merge queue", outcome: .unverifiable)), "Can't check · Merge queue")
    }

    func testNotificationsTokenWarningsNameTheNotificationsToken() {
        let scope = Scope(id: "o", name: "example-org", kind: .org, warnings: [
            Warning(kind: .tokenExpiring, token: .notifications, until: T0 + 5 * 86_400),
            Warning(kind: .tokenOwnerMismatch, token: .notifications),
            Warning(kind: .tokenOwnerMismatch, token: .scope),
        ])
        XCTAssertEqual(Warnings.banner(scope, now: T0).map(\.text), [
            "Notifications token expires in 5 days",
            "Notifications token belongs to another account · Replace it in Settings",
            "example-org token belongs to another account · Replace it in Settings",
        ])
    }

    func testTheNotificationsTokenExpiryComesFromItsOwnDateWithoutAnyScope() {
        let soon = TokenStatus(target: "notifications", registered: true, expiresAt: T0 + 3 * 86_400 - 10)
        XCTAssertEqual(TokenState.label(status: soon, warnings: [], now: T0), TokenLabel("Expires in 3 days", .caution))
        let later = TokenStatus(target: "notifications", registered: true, expiresAt: T0 + 8 * 86_400)
        XCTAssertEqual(TokenState.label(status: later, warnings: [], now: T0), TokenLabel("Not tested", .neutral))
        let none = TokenStatus(target: "notifications", registered: true, expiresAt: nil)
        XCTAssertEqual(TokenState.label(status: none, warnings: [], now: T0), TokenLabel("Not tested", .neutral), "no expiry, no label for it")
    }

    func testRemoveConfirmationAndRepositoryAccessGuidance() {
        XCTAssertEqual(ScopeText.removeTitle("example-org"), "Remove example-org?")
        XCTAssertEqual(
            ScopeText.removeDetail("example-org"),
            "Its token is deleted from the Keychain. Add example-org again to get its Done and Snooze back."
        )
        XCTAssertEqual(CreateTokenURL.repositoryAccessHint(.organization), "Under Repository access, choose All repositories")
        XCTAssertEqual(CreateTokenURL.repositoryAccessHint(.personal), "Under Repository access, choose All repositories")
        XCTAssertEqual(CreateTokenURL.repositoryAccessHint(.public), "Under Repository access, choose Public repositories")
    }

    func testColorNamesMapToTheirBackgrounds() {
        let want: [ScopeColor: UInt32] = [
            .gray: 0xF3F4F8, .green: 0xEAF4F0, .blue: 0xEAF0F9, .purple: 0xF1EEF8, .pink: 0xF8EEF0, .beige: 0xF7F1E3,
        ]
        for color in ScopeColor.allCases {
            XCTAssertEqual(Palette.theme(color).background.light, RGB(hex: want[color]!), color.rawValue)
        }
        XCTAssertEqual(ScopeColor.allCases.map(\.rawValue), ["gray", "green", "blue", "purple", "pink", "beige"])
        XCTAssertEqual(Palette.color(of: Scope(id: "p", kind: .public)), .beige, "Public without a color")
        // Six distinct dark backgrounds, darker than their light ones.
        let darks = ScopeColor.allCases.map { Palette.theme($0).background.dark }
        XCTAssertEqual(Set(darks.map { "\($0.red),\($0.green),\($0.blue)" }).count, 6)
        for color in ScopeColor.allCases {
            let theme = Palette.theme(color)
            XCTAssertLessThan(theme.background.dark.red + theme.background.dark.green, theme.background.light.red + theme.background.light.green)
        }
        XCTAssertEqual(Palette.text.resolve(dark: false), RGB(hex: 0x1D1D1F))
        XCTAssertEqual(Palette.text.resolve(dark: true), RGB(hex: 0xECECEE))
    }

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

    func testWindowFramesAreKeptPerScope() {
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UIStateStore(defaults: defaults)
        XCTAssertNil(store.windowFrame(scope: "org"))
        store.setWindowFrame("{{10, 20}, {400, 620}}", scope: "org")
        XCTAssertEqual(UIStateStore(defaults: defaults).windowFrame(scope: "org"), "{{10, 20}, {400, 620}}")
        XCTAssertNil(store.windowFrame(scope: "public"))
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
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
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

    func testSettingsStatusIsReadAgainOnScopeChangedWhileOpen() async {
        let settings = SettingsModel(app: app, launch: nil)
        app.handle(.scopeChanged(Scope(id: "org")))
        await settle()
        XCTAssertFalse(api.calls.contains("settings_status"), "closed: nothing")
        settings.windowOpened()
        await settle()
        api.clearCalls()
        app.handle(.scopeChanged(Scope(id: "org", badge: 1)))
        await settle()
        XCTAssertEqual(api.calls.filter { $0 == "settings_status" }.count, 1)
        settings.windowClosed()
        api.clearCalls()
        app.handle(.snapshot(scopes: [], dbUnreadable: false))
        await settle()
        XCTAssertFalse(api.calls.contains("settings_status"))
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


final class MenuBarMarkTests: XCTestCase {
    func testBadgeDotAndTriangleTogether() {
        let cases: [(Int, Bool, Bool, String?, MenuBarMarks.DotPlace?, Bool)] = [
            (0, false, false, nil, nil, true),
            (3, false, false, "3", nil, false),
            (0, true, false, nil, .topRight, false),
            (3, true, false, "3", .bottomRight, false),
            (3, true, true, "3", .bottomRight, false),
            (120, false, true, "99+", nil, false),
        ]
        for (badge, dot, triangle, text, place, plain) in cases {
            let marks = MenuBarMarks(badge: badge, dot: dot, triangle: triangle)
            XCTAssertEqual(marks.badge, text, "\(badge) \(dot)")
            XCTAssertEqual(marks.dot, place, "\(badge) \(dot)")
            XCTAssertEqual(marks.triangle, triangle)
            XCTAssertEqual(marks.plain, plain)
        }
    }
}

final class ConfigEventTests: XCTestCase {
    func testConfigChangedDecodesBooleansNumbersAndStrings() throws {
        let cases: [(String, ConfigValue)] = [
            (#"{"event":"config_changed","key":"launch_at_login","value":false}"#, .bool(false)),
            (#"{"event":"config_changed","key":"drop_after_days","value":20}"#, .int(20)),
            (#"{"event":"config_changed","key":"keep_watching_days","value":0}"#, .int(0)),
            (#"{"event":"config_changed","key":"snooze_return_time","value":"08:30"}"#, .string("08:30")),
        ]
        for (line, value) in cases {
            let event = try JSONDecoder().decode(SubscribeEvent.self, from: Data(line.utf8))
            guard case .configChanged(_, let got) = event else { return XCTFail(line) }
            XCTAssertEqual(got, value, line)
        }
    }

    func testTokenStatusCarriesItsWarnings() throws {
        let line = #"{"target":"notifications","registered":true,"owner":"me","expires_at":null,"scopes":null,"last_test":null,"sso_urls":[],"warnings":[{"kind":"token_invalid","token":"notifications","message":"m","until":null}]}"#
        let status = try JSONDecoder().decode(TokenStatus.self, from: Data(line.utf8))
        XCTAssertEqual(TokenState.label(status: status, warnings: status.warnings, now: T0), TokenLabel("Invalid", .bad))
        let old = #"{"target":"o","registered":false,"owner":null,"expires_at":null,"scopes":null,"last_test":null,"sso_urls":[]}"#
        XCTAssertEqual(try JSONDecoder().decode(TokenStatus.self, from: Data(old.utf8)).warnings, [])
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

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
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
        let quit = menu.items.compactMap(\.submenu).flatMap(\.items).contains { $0.keyEquivalent == "q" }
        XCTAssertFalse(quit, "⌘Q stays with the popover and the focused window")
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

final class ChipLookTests: XCTestCase {
    func testOffChipsAreAllGrayAndOnChipsAreFilledWithACheck() {
        for action in [false, true] {
            let off = ChipLook(on: false, action: action)
            XCTAssertEqual(off.border, Palette.controlBorder, "\(action)")
            XCTAssertEqual(off.text, Palette.strongText, "Needs action is not orange when off")
            XCTAssertEqual(off.fill, Palette.surface)
            XCTAssertEqual(off.label("Needs action"), "Needs action")
        }
        let needs = ChipLook(on: true, action: true)
        XCTAssertEqual(needs.fill, Palette.badge)
        XCTAssertEqual(needs.border, Palette.badge)
        XCTAssertEqual(needs.text, Palette.onColor)
        XCTAssertEqual(needs.label("Needs action"), "✓ Needs action")
        let mine = ChipLook(on: true, action: false)
        XCTAssertEqual(mine.fill, Palette.text)
        XCTAssertEqual(mine.text, Palette.surface)
        XCTAssertEqual(mine.label("My PRs"), "✓ My PRs")
        // In the dark appearance the black chip turns light with dark text.
        XCTAssertEqual(mine.fill.resolve(dark: true), RGB(hex: 0xECECEE))
        XCTAssertEqual(mine.text.resolve(dark: true), RGB(hex: 0x2B2B2F))
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
