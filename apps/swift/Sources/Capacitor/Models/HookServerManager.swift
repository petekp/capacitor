import Darwin
import Foundation

protocol HookServerProcessControlling: AnyObject {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }
    var terminationStatus: Int32 { get }
    func terminate()
}

struct HookServerLifecycleState: Equatable {
    enum Directive: Equatable {
        case none
        case serverReady
        case restart
    }

    enum Event: Equatable {
        case launchRequested
        case launchFailed(String)
        case adoptedExistingProcess
        case healthCheckFinished(healthy: Bool, maxConsecutiveFailures: Int)
        case stopRequested
    }

    var status: HookServerManager.Status = .stopped
    var consecutiveHealthFailures = 0
    var stopRequested = false

    mutating func apply(_ event: Event) -> Directive {
        switch event {
        case .launchRequested, .adoptedExistingProcess:
            stopRequested = false
            consecutiveHealthFailures = 0
            status = .starting
            return .none

        case let .launchFailed(message):
            status = .failed(message)
            return .none

        case let .healthCheckFinished(healthy, maxConsecutiveFailures):
            guard status == .running || status == .starting else { return .none }
            guard !stopRequested else { return .none }

            if healthy {
                consecutiveHealthFailures = 0
                if status == .starting {
                    status = .running
                    return .serverReady
                }
                return .none
            }

            consecutiveHealthFailures += 1
            if consecutiveHealthFailures >= maxConsecutiveFailures {
                consecutiveHealthFailures = 0
                status = .starting
                return .restart
            }
            return .none

        case .stopRequested:
            stopRequested = true
            consecutiveHealthFailures = 0
            status = .stopped
            return .none
        }
    }
}

struct HookServerManagerDependencies {
    var isExecutableFile: (String) -> Bool
    var readPidFile: (String) -> Int32?
    var removePidFile: (String) -> Void
    var isProcessAlive: (Int32) -> Bool
    var isManagedServerProcess: (Int32, String) -> Bool
    var terminatePid: (Int32) -> Void
    var loadRuntimeServiceConnection: (UInt16) -> RuntimeServiceConnection?
    var launchProcess: (String, UInt16, [String: String]) throws -> any HookServerProcessControlling
    var fetchHealth: (UInt16, String?) async -> Bool
}

private final class LiveHookServerProcess: HookServerProcessControlling {
    private let process: Process

    init(binaryPath: String, port: UInt16, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["serve", "--port", String(port)]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    var isRunning: Bool {
        process.isRunning
    }

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func terminate() {
        process.terminate()
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}

/// Manages the lifecycle of the `hud-hook serve` HTTP server process.
///
/// Keeps a single long-lived HTTP server that receives hook events via POST
/// from Claude Code. The Swift app spawns the server at startup and monitors
/// it via periodic health checks, restarting if the process exits unexpectedly.
@MainActor
final class HookServerManager {
    // MARK: - Configuration

    nonisolated static let defaultPort: UInt16 = 7474
    private nonisolated static let healthPath = "/health"
    private static let maxConsecutiveFailures = 3

    // MARK: - State

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private(set) var consecutiveHealthFailures = 0

    // MARK: - Private

    private var process: (any HookServerProcessControlling)?
    private var adoptedPid: Int32?
    private var healthCheckTask: _Concurrency.Task<Void, Never>?
    private var healthCheckToken: UUID?
    private var lifecycleGeneration: UInt64 = 0
    private var stopRequested = false
    private var healthAuthorizationToken: String?
    private let port: UInt16
    private let binaryPath: String
    private let dependencies: HookServerManagerDependencies
    private var lifecycleState = HookServerLifecycleState()

    // MARK: - Init

    init(
        port: UInt16 = HookServerManager.defaultPort,
        binaryPath: String? = nil,
        dependencies: HookServerManagerDependencies = .live,
    ) {
        self.port = port
        self.dependencies = dependencies
        self.binaryPath = binaryPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/hud-hook").path
    }

    // MARK: - Lifecycle

    /// Starts the server if the binary exists and the server isn't already running.
    ///
    /// On launch, checks for a stale PID file from a previous app session. If the
    /// old process is still alive and still points at the expected hook binary, we
    /// adopt it. If not, we clean up the PID file and start fresh.
    func startIfNeeded() {
        guard status != .running, status != .starting else { return }

        guard dependencies.isExecutableFile(binaryPath) else {
            DebugLog.write("HookServerManager: binary not found at \(binaryPath), skipping")
            _ = applyLifecycle(.launchFailed("Binary not found"))
            return
        }

        if let stalePid = dependencies.readPidFile(pidFilePath) {
            if dependencies.isProcessAlive(stalePid),
               dependencies.isManagedServerProcess(stalePid, binaryPath)
            {
                guard let connection = dependencies.loadRuntimeServiceConnection(port) else {
                    DebugLog.write("HookServerManager: missing runtime service connection for pid \(stalePid), relaunching")
                    dependencies.removePidFile(pidFilePath)
                    start()
                    return
                }
                beginLifecycleObservation(
                    adoptedPid: stalePid,
                    healthAuthorizationToken: connection.bearerToken,
                )
                DebugLog.write("HookServerManager: adopting existing server pid \(stalePid) on port \(port)")
                return
            }

            DebugLog.write("HookServerManager: removing stale PID file (pid \(stalePid) invalid for adoption)")
            dependencies.removePidFile(pidFilePath)
        }

        start()
    }

    /// Checks server liveness via GET /health.
    /// Restarts the server after `maxConsecutiveFailures` consecutive failures.
    func checkHealth() {
        guard status == .running || status == .starting else { return }
        guard healthCheckTask == nil else { return }

        let generation = lifecycleGeneration

        if let proc = process, !proc.isRunning {
            DebugLog.write("HookServerManager: process exited with code \(proc.terminationStatus)")
            handleUnexpectedExit(for: generation)
            return
        }

        if let adoptedPid, !dependencies.isProcessAlive(adoptedPid) {
            DebugLog.write("HookServerManager: adopted pid \(adoptedPid) is no longer alive")
            handleUnexpectedExit(for: generation)
            return
        }

        let token = UUID()
        healthCheckToken = token
        let authToken = healthAuthorizationToken
        healthCheckTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            let healthy = await dependencies.fetchHealth(port, authToken)
            await MainActor.run {
                self.finishHealthCheck(healthy: healthy, token: token, generation: generation)
            }
        }
    }

    /// Gracefully stops the server process without blocking the main actor.
    func stop() {
        lifecycleGeneration &+= 1
        cancelHealthCheck()

        let ownedProcess = process
        let ownedPid = adoptedPid

        process = nil
        adoptedPid = nil
        healthAuthorizationToken = nil
        _ = applyLifecycle(.stopRequested)

        ownedProcess?.terminate()
        if let ownedPid {
            dependencies.terminatePid(ownedPid)
        }

        DebugLog.write("HookServerManager: server stop requested")
    }

    // MARK: - Private

    private func start() {
        lifecycleGeneration &+= 1
        cancelHealthCheck()
        adoptedPid = nil
        _ = applyLifecycle(.launchRequested)

        var environment = ProcessInfo.processInfo.environment
        environment["CAPACITOR_CORE_ENABLED"] = "1"
        let authToken = UUID().uuidString
        environment["CAPACITOR_RUNTIME_SERVICE_BOOTSTRAP"] = "1"
        environment["CAPACITOR_RUNTIME_SERVICE_PORT"] = String(port)
        environment["CAPACITOR_RUNTIME_SERVICE_TOKEN"] = authToken
        healthAuthorizationToken = authToken

        do {
            let launchedProcess = try dependencies.launchProcess(binaryPath, port, environment)
            process = launchedProcess
            DebugLog.write("HookServerManager: launched pid \(launchedProcess.processIdentifier) on port \(port)")
        } catch {
            process = nil
            _ = applyLifecycle(.launchFailed(error.localizedDescription))
            DebugLog.write("HookServerManager: failed to launch - \(error)")
            Telemetry.emit("hook_server", "Launch failed", payload: [
                "error": String(describing: error),
            ])
        }
    }

    private func beginLifecycleObservation(adoptedPid: Int32, healthAuthorizationToken: String?) {
        lifecycleGeneration &+= 1
        cancelHealthCheck()
        process = nil
        self.adoptedPid = adoptedPid
        self.healthAuthorizationToken = healthAuthorizationToken
        _ = applyLifecycle(.adoptedExistingProcess)
    }

    private func finishHealthCheck(healthy: Bool, token: UUID, generation: UInt64) {
        guard healthCheckToken == token else { return }
        healthCheckTask = nil
        healthCheckToken = nil

        guard generation == lifecycleGeneration, !stopRequested else {
            return
        }

        guard status == .running || status == .starting else {
            return
        }

        let previousFailures = consecutiveHealthFailures
        let directive = applyLifecycle(.healthCheckFinished(
            healthy: healthy,
            maxConsecutiveFailures: Self.maxConsecutiveFailures,
        ))

        if !healthy {
            DebugLog.write(
                "HookServerManager: health check failed (\(previousFailures + 1)/\(Self.maxConsecutiveFailures))",
            )
        }

        switch directive {
        case .serverReady:
            DebugLog.write("HookServerManager: server ready on port \(port)")
            Telemetry.emit("hook_server", "Server started", payload: [
                "port": port,
            ])
        case .restart:
            handleUnexpectedExit(for: generation)
        case .none:
            break
        }
    }

    private func cancelHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        healthCheckToken = nil
    }

    private func handleUnexpectedExit(for generation: UInt64) {
        guard generation == lifecycleGeneration, !stopRequested else {
            return
        }

        let oldPid = process?.processIdentifier ?? adoptedPid
        process = nil
        adoptedPid = nil

        DebugLog.write("HookServerManager: restarting (was pid \(oldPid ?? 0))")
        Telemetry.emit("hook_server", "Server restarting", payload: [
            "previous_pid": oldPid ?? 0,
        ])

        start()
    }

    private func applyLifecycle(_ event: HookServerLifecycleState.Event) -> HookServerLifecycleState.Directive {
        let directive = lifecycleState.apply(event)
        status = lifecycleState.status
        consecutiveHealthFailures = lifecycleState.consecutiveHealthFailures
        stopRequested = lifecycleState.stopRequested
        return directive
    }

    // MARK: - PID File Helpers

    private var pidFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/runtime/runtime-service-\(port).pid").path
    }

    nonisolated static func fetchHealth(port: UInt16, authToken: String?) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(healthPath)") else {
            return false
        }

        do {
            var request = URLRequest(url: url)
            if let authToken {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String
            {
                return status == "ok"
            }
            return false
        } catch {
            return false
        }
    }
}

extension HookServerManagerDependencies {
    static let live = HookServerManagerDependencies(
        isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) },
        readPidFile: { path in
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        },
        removePidFile: { path in
            try? FileManager.default.removeItem(atPath: path)
        },
        isProcessAlive: { pid in
            kill(pid, 0) == 0
        },
        isManagedServerProcess: { pid, expectedBinaryPath in
            LiveHookServerProcess.executablePath(pid: pid) == expectedBinaryPath
        },
        terminatePid: { pid in
            _ = kill(pid, SIGTERM)
        },
        loadRuntimeServiceConnection: { _ in
            RuntimeServiceConnection.current()
        },
        launchProcess: { binaryPath, port, environment in
            try LiveHookServerProcess(binaryPath: binaryPath, port: port, environment: environment)
        },
        fetchHealth: { port, authToken in
            await HookServerManager.fetchHealth(port: port, authToken: authToken)
        },
    )
}
