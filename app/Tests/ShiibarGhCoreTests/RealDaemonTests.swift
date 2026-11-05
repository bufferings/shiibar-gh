// The supervisor and the client against the real daemon. The daemon binary
// comes from `SHIIBAR_GH_TEST_DAEMON` (a `dev-ingest` build, which never
// reaches the real Keychain or GitHub); without it these tests are skipped.
// The state directory is a temporary one, passed as `SHIIBAR_GH_STATE_DIR`
// through the launcher's environment.

import Foundation
@testable import ShiibarGhCore
import XCTest

final class RealDaemonTests: XCTestCase {
    var dir = ""
    var binary: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SHIIBAR_GH_TEST_DAEMON"], !path.isEmpty else {
            throw XCTSkip("SHIIBAR_GH_TEST_DAEMON is not set")
        }
        binary = URL(fileURLWithPath: path)
        dir = temporaryDirectory()
    }

    override func tearDown() {
        if !dir.isEmpty {
            let socket = StateDirectory.socket(root: dir)
            let api = SocketDaemonAPI(socketPath: socket, timeout: 1)
            let done = expectation(description: "shutdown")
            Task {
                try? await api.shutdown()
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    private func launcher() -> TestLauncher {
        TestLauncher(executable: binary, stateRoot: dir)
    }

    func testTheAppStartsTheDaemonTalksToItAndStopsIt() async throws {
        let launcher = launcher()
        let supervisor = DaemonSupervisor(
            socketPath: StateDirectory.socket(root: dir), appVersion: "0.1.0", launcher: launcher,
            callbackQueue: .main, backoff: { _ in 0.1 }
        )
        let snapshot = expectation(description: "snapshot")
        let changed = expectation(description: "scope_changed")
        supervisor.onEvent = { event in
            switch event {
            case .snapshot(let scopes, let unreadable):
                if scopes.isEmpty && !unreadable { snapshot.fulfill() }
            case .scopeChanged(let scope):
                if scope.id == "public" && scope.color == .known(.beige) { changed.fulfill() }
            default:
                break
            }
        }
        supervisor.start()
        await fulfillment(of: [snapshot], timeout: 20)
        XCTAssertEqual(launcher.launches, 1)

        let api = SocketDaemonAPI(socketPath: StateDirectory.socket(root: dir))
        let info = try await api.info()
        XCTAssertFalse(info.version.isEmpty)
        let scopes = try await api.scopeAdd("public")
        XCTAssertEqual(scopes.map(\.id), ["public"])
        await fulfillment(of: [changed], timeout: 20)
        try await api.scopeColor("public", .pink)
        try await api.popoverOpened("public")
        try await api.popoverClosed("public")
        let returnTime = try await api.configGet("snooze_return_time")
        XCTAssertEqual(returnTime, .string("09:00"))
        let interval = try await api.configGet("status_interval_minutes")
        XCTAssertEqual(interval, .int(1))
        do {
            _ = try await api.configSet("status_interval_minutes", .int(0))
            XCTFail("expected invalid")
        } catch let error as DaemonError {
            XCTAssertEqual(error.code, .known(.invalid))
        }
        let status = try await api.settingsStatus()
        XCTAssertEqual(status.tokens.map(\.target), ["notifications", "public"])
        let cards = try await api.list(ListFilter(scope: "public"))
        XCTAssertEqual(cards, [])

        let stopped = expectation(description: "stopped")
        supervisor.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
        let gone = Date().addingTimeInterval(10)
        while launcher.isRunning && Date() < gone {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(launcher.isRunning, "Quit stops the daemon")
        XCTAssertTrue(FileManager.default.fileExists(atPath: StateDirectory.daemonLog(root: dir)))
    }

    func testADaemonThatDiesIsStartedAgain() async throws {
        let launcher = launcher()
        let supervisor = DaemonSupervisor(
            socketPath: StateDirectory.socket(root: dir), appVersion: "0.1.0", launcher: launcher,
            callbackQueue: .main, backoff: { _ in 0.1 }
        )
        var snapshots = 0
        supervisor.onEvent = { if case .snapshot = $0 { snapshots += 1 } }
        supervisor.start()
        let deadline = Date().addingTimeInterval(20)
        while snapshots < 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(snapshots, 1)
        launcher.kill()
        let again = Date().addingTimeInterval(30)
        while snapshots < 2 && Date() < again {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(launcher.launches, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: StateDirectory.previousDaemonLog(root: dir)),
            "the log of the run that died is kept"
        )
        let stopped = expectation(description: "stopped")
        supervisor.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
    }
}

/// The real launcher with the test's state directory in the environment.
final class TestLauncher: DaemonLauncher {
    private let inner: ProcessDaemonLauncher
    private(set) var launches = 0

    init(executable: URL, stateRoot: String) {
        inner = ProcessDaemonLauncher(
            executable: executable, stateRoot: stateRoot,
            environment: [
                "SHIIBAR_GH_STATE_DIR": stateRoot,
                "SHIIBAR_GH_LOG": "info",
                "PATH": "/usr/bin:/bin",
            ]
        )
    }

    var isRunning: Bool { inner.isRunning }

    func launch() throws {
        launches += 1
        try inner.launch()
    }

    func kill() {
        inner.terminate()
    }
}
