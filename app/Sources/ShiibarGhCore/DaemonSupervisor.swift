// The daemon's lifecycle, owned by the app (docs/tasks/M3.md, "Daemon
// lifecycle"; DESIGN.md, "Structure": no launchd). At start the app asks
// `info`: the same version is used as it is, another version is shut down
// and replaced by the bundled daemon, and no answer starts the bundled
// daemon. The `subscribe` connection then reconnects with the backoff of
// DESIGN.md, "Constants" (1 second, doubling, at most 30). A daemon that
// went away unexpectedly is started again on the next reconnect attempt
// when it does not answer `info`, so a crash loop retries at most every 30
// seconds. Quitting the app shuts the daemon down.

import Foundation

/// The state directory and the files the app uses in it. Mirrors
/// `shiibar_gh_proto::paths::StateDir`: `SHIIBAR_GH_STATE_DIR`, else
/// `$HOME/.local/state/shiibar-gh`.
public enum StateDirectory {
    public static let environmentKey = "SHIIBAR_GH_STATE_DIR"

    public static func root(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment[environmentKey] {
            return override
        }
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return home + "/.local/state/shiibar-gh"
    }

    public static func socket(root: String) -> String {
        (root as NSString).appendingPathComponent("shiibar-ghd.sock")
    }

    /// Where the app sends the standard error of a daemon it started.
    public static func daemonLog(root: String) -> String {
        (root as NSString).appendingPathComponent("shiibar-ghd.log")
    }

    /// The log of the run before, kept when a new daemon starts so a crash
    /// stays readable after the restart.
    public static func previousDaemonLog(root: String) -> String {
        (root as NSString).appendingPathComponent("shiibar-ghd.previous.log")
    }
}

public enum ReconnectBackoff {
    public static let capSeconds: TimeInterval = 30

    /// The delay before reconnect attempt `attempt` (0 first): 1, 2, 4, 8,
    /// 16, 30, 30, ...
    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 1 }
        return min(pow(2, Double(min(attempt, 30))), capSeconds)
    }
}

public enum StartAction: Equatable {
    /// A daemon of the app's version runs: connect to it.
    case attach
    /// A daemon of another version runs: shut it down, then start ours.
    case replace
    /// Nothing answers: start ours.
    case spawn
}

public enum DaemonLifecycle {
    public static func startAction(running: InfoResponse?, appVersion: String) -> StartAction {
        guard let running else { return .spawn }
        return running.version == appVersion ? .attach : .replace
    }

    /// Before a reconnect attempt: start the bundled daemon again when none
    /// answers and the one this app started is not running.
    public static func shouldRespawn(answers: Bool, canLaunch: Bool, ownProcessRunning: Bool) -> Bool {
        !answers && canLaunch && !ownProcessRunning
    }
}

/// Starts the daemon. A protocol so tests can count launches.
public protocol DaemonLauncher: AnyObject {
    func launch() throws
    var isRunning: Bool { get }
}

/// The bundled `shiibar-ghd`, started with `--foreground`. Its standard
/// error goes to `shiibar-ghd.log` in the state directory; the log of the
/// previous run moves to `shiibar-ghd.previous.log`. The environment,
/// `SHIIBAR_GH_STATE_DIR` included, is passed on unchanged.
public final class ProcessDaemonLauncher: DaemonLauncher {
    public let executable: URL
    public let stateRoot: String
    private let environment: [String: String]
    private var process: Process?

    public init(
        executable: URL, stateRoot: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        self.stateRoot = stateRoot
        self.environment = environment
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Stop the process this launcher started.
    public func terminate() {
        process?.terminate()
        process?.waitUntilExit()
    }

    public func launch() throws {
        let files = FileManager.default
        try? files.createDirectory(
            atPath: stateRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let log = StateDirectory.daemonLog(root: stateRoot)
        let previous = StateDirectory.previousDaemonLog(root: stateRoot)
        if files.fileExists(atPath: log) {
            try? files.removeItem(atPath: previous)
            try? files.moveItem(atPath: log, toPath: previous)
        }
        files.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600])
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--foreground"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle(forWritingAtPath: log) ?? FileHandle.nullDevice
        try process.run()
        self.process = process
    }
}

/// Keeps one `subscribe` connection (`client` `app`) to the daemon and the
/// daemon itself alive. Callbacks run on `callbackQueue`.
public final class DaemonSupervisor: @unchecked Sendable {
    public let socketPath: String
    public let appVersion: String
    private let launcher: DaemonLauncher?
    private let backoff: (Int) -> TimeInterval
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label: "shiibar.gh.supervisor")
    private var attempt = 0
    private var stopped = false
    private var started = false
    private var socket: UnixSocket?
    private var generation = 0

    /// Every decoded event, the snapshot first.
    public var onEvent: ((SubscribeEvent) -> Void)?
    /// True once a snapshot arrived on a new connection, false when it ends.
    public var onConnectionChange: ((Bool) -> Void)?

    public init(
        socketPath: String, appVersion: String, launcher: DaemonLauncher?,
        callbackQueue: DispatchQueue = .main,
        backoff: @escaping (Int) -> TimeInterval = ReconnectBackoff.delay(forAttempt:)
    ) {
        self.socketPath = socketPath
        self.appVersion = appVersion
        self.launcher = launcher
        self.callbackQueue = callbackQueue
        self.backoff = backoff
    }

    public func start() {
        queue.async { [self] in
            guard !started, !stopped else { return }
            started = true
            switch DaemonLifecycle.startAction(running: infoNow(), appVersion: appVersion) {
            case .attach:
                break
            case .replace:
                sendShutdownNow()
                waitUntilGone()
                launchNow()
            case .spawn:
                launchNow()
            }
            connectNow()
        }
    }

    /// Stop reconnecting and shut the daemon down. `completion` runs on
    /// `callbackQueue` once the daemon answered or `timeout` passed.
    public func shutdown(timeout: TimeInterval = 2, completion: @escaping () -> Void) {
        queue.async { [self] in
            stopped = true
            socket?.close()
            socket = nil
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { [self] in
                sendShutdownNow(timeout: timeout)
                done.signal()
            }
            _ = done.wait(timeout: .now() + timeout)
            callbackQueue.async(execute: completion)
        }
    }

    // MARK: - On `queue`

    private func infoNow(timeout: TimeInterval = 2) -> InfoResponse? {
        guard let socket = try? UnixSocket.connect(path: socketPath, timeout: timeout) else { return nil }
        defer { socket.close() }
        guard (try? socket.write(Data("{\"cmd\":\"info\"}\n".utf8))) != nil,
              let line = try? socket.readLine(),
              (try? JSONDecoder().decode(OkResponse.self, from: line))?.ok == true
        else { return nil }
        return try? JSONDecoder().decode(InfoResponse.self, from: line)
    }

    private func sendShutdownNow(timeout: TimeInterval = 2) {
        guard let socket = try? UnixSocket.connect(path: socketPath, timeout: timeout) else { return }
        defer { socket.close() }
        try? socket.write(Data("{\"cmd\":\"shutdown\"}\n".utf8))
        _ = try? socket.readLine()
    }

    /// Wait for the old daemon to stop answering, at most five seconds.
    private func waitUntilGone() {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, infoNow(timeout: 0.5) != nil {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func launchNow() {
        guard let launcher else { return }
        do {
            try launcher.launch()
        } catch {
            NSLog("shiibar-gh: cannot start the daemon: %@", String(describing: error))
        }
    }

    private func connectNow() {
        guard !stopped else { return }
        generation += 1
        let current = generation
        let socket: UnixSocket
        do {
            socket = try UnixSocket.connect(path: socketPath, timeout: nil)
            try socket.write(Data("{\"cmd\":\"subscribe\",\"client\":\"app\"}\n".utf8))
        } catch {
            scheduleReconnect()
            return
        }
        self.socket = socket
        let thread = Thread { [weak self] in
            self?.readLoop(socket, generation: current)
        }
        thread.name = "shiibar.gh.subscribe"
        thread.start()
    }

    private func readLoop(_ socket: UnixSocket, generation current: Int) {
        var connected = false
        let decoder = JSONDecoder()
        while true {
            guard let line = try? socket.readLine() else { break }
            guard let event = try? decoder.decode(SubscribeEvent.self, from: line) else { continue }
            if case .unknown = event { continue }
            if !connected, case .snapshot = event {
                connected = true
                queue.async { [self] in attempt = 0 }
            }
            let onEvent = self.onEvent
            let onConnectionChange = self.onConnectionChange
            callbackQueue.async {
                onEvent?(event)
                if case .snapshot = event { onConnectionChange?(true) }
            }
        }
        socket.close()
        let onConnectionChange = self.onConnectionChange
        callbackQueue.async { onConnectionChange?(false) }
        queue.async { [self] in
            guard current == generation, !stopped else { return }
            self.socket = nil
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = backoff(attempt)
        attempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard !stopped else { return }
            let answers = infoNow(timeout: 1) != nil
            if DaemonLifecycle.shouldRespawn(
                answers: answers, canLaunch: launcher != nil, ownProcessRunning: launcher?.isRunning ?? false
            ) {
                launchNow()
            }
            connectNow()
        }
    }
}
