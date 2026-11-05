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
            XCTAssertEqual(Palette.theme(color).background, RGB(hex: want[color]!), color.rawValue)
        }
        XCTAssertEqual(ScopeColor.allCases.map(\.rawValue), ["gray", "green", "blue", "purple", "pink", "beige"])
        XCTAssertEqual(Palette.color(of: Scope(id: "p", kind: .public)), .beige, "Public without a color")
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
