import Darwin
import Foundation

private func hookServerProcessIsAlive(pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

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
    var killPid: (Int32) -> Void
    var waitForProcessExit: (Int32, TimeInterval) -> Bool
    var loadRuntimeServiceConnection: (UInt16) -> RuntimeServiceConnection?
    var launchProcess: (String, UInt16, [String: String], @escaping @Sendable (Int32) -> Void) throws -> any HookServerProcessControlling
    var fetchHealth: (UInt16, String?) -> RuntimeHealth?
}

private final class LiveHookServerProcess: HookServerProcessControlling {
    private let process: Process

    init(
        binaryPath: String,
        port: UInt16,
        environment: [String: String],
        terminationHandler: @escaping @Sendable (Int32) -> Void,
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["serve", "--port", String(port)]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            terminationHandler(process.terminationStatus)
        }
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
/// from Claude Code. The Swift app verifies startup readiness before treating
/// the server as healthy, then monitors it via periodic health checks.
final class HookServerManager {
    // MARK: - Configuration

    nonisolated static let defaultPort: UInt16 = 7474
    private nonisolated static let healthPath = "/health"
    private static let maxConsecutiveFailures = 3
    private static let gracefulStopTimeout: TimeInterval = 2.0
    private nonisolated static let defaultLaunchReadinessAttempts = 10
    private nonisolated static let defaultLaunchReadinessInterval = Duration.milliseconds(500)
    private static let healthCheckInterval: Duration = .seconds(3)
    private static let initialBackoffSeconds: TimeInterval = 1
    private static let maxBackoffSeconds: TimeInterval = 60
    private static let crashBudgetLimit = 5
    private static let crashBudgetWindow: TimeInterval = 600 // 10 minutes

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
    private var healthCheckLoopTask: _Concurrency.Task<Void, Never>?
    private var launchReadinessTask: _Concurrency.Task<Void, Never>?
    private var healthCheckToken: UUID?
    private var lifecycleGeneration: UInt64 = 0
    private var stopRequested = false
    private var healthAuthorizationToken: String?
    private let port: UInt16
    private let binaryPath: String
    private let launchReadinessAttempts: Int
    private let launchReadinessInterval: Duration
    private let dependencies: HookServerManagerDependencies
    private var lifecycleState = HookServerLifecycleState()
    /// Current backoff delay in seconds before the next restart attempt. Doubles after each
    /// restart, resets on successful health check. Exposed as internal for testability.
    var restartBackoffSeconds: TimeInterval = HookServerManager.initialBackoffSeconds
    /// Timestamps of recent restart attempts within the crash budget window.
    /// Exposed as internal for testability (pre-seeding in unit tests).
    var restartTimestamps: [Date] = []

    // MARK: - Init

    init(
        port: UInt16 = HookServerManager.defaultPort,
        binaryPath: String? = nil,
        dependencies: HookServerManagerDependencies = .live,
        launchReadinessAttempts: Int = HookServerManager.defaultLaunchReadinessAttempts,
        launchReadinessInterval: Duration = HookServerManager.defaultLaunchReadinessInterval,
    ) {
        self.port = port
        self.dependencies = dependencies
        self.launchReadinessAttempts = max(1, launchReadinessAttempts)
        self.launchReadinessInterval = launchReadinessInterval
        self.binaryPath = binaryPath ?? Self.defaultBinaryPath
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

        if let connection = dependencies.loadRuntimeServiceConnection(port),
           let health = dependencies.fetchHealth(port, connection.bearerToken),
           health.isCompatibleBootstrapService
        {
            beginLifecycleObservation(
                adoptedPid: Int32(health.pid),
                healthAuthorizationToken: connection.bearerToken,
            )
            DebugLog.write("HookServerManager: adopting live runtime service pid \(health.pid) on port \(port)")
            return
        }

        start()
    }

    /// Checks server liveness via GET /health.
    /// Restarts the server after `maxConsecutiveFailures` consecutive failures.
    func checkHealth() {
        guard status == .running || status == .starting else { return }
        guard healthCheckTask == nil, launchReadinessTask == nil else { return }

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
            let healthy = dependencies.fetchHealth(port, authToken)?.isCompatibleBootstrapService ?? false
            await MainActor.run {
                self.finishHealthCheck(healthy: healthy, token: token, generation: generation)
            }
        }
    }

    /// Starts a periodic health check loop that calls `checkHealth()` every 3 seconds.
    ///
    /// Cancels any previously running loop. The loop runs until the manager is stopped
    /// or the task is cancelled.
    func startHealthCheckLoop() {
        healthCheckLoopTask?.cancel()
        healthCheckLoopTask = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                do {
                    try await _Concurrency.Task.sleep(for: Self.healthCheckInterval)
                } catch {
                    return
                }
                guard let self, !_Concurrency.Task.isCancelled else { return }
                checkHealth()
            }
        }
    }

    /// Gracefully stops the server process, escalating to SIGKILL if it does not exit promptly.
    func stop() {
        lifecycleGeneration &+= 1
        cancelHealthCheck()
        cancelHealthCheckLoop()
        cancelLaunchReadiness()

        let ownedProcess = process
        let managedPid = ownedProcess?.processIdentifier ?? adoptedPid

        process = nil
        adoptedPid = nil
        healthAuthorizationToken = nil
        _ = applyLifecycle(.stopRequested)

        if let ownedProcess {
            ownedProcess.terminate()
        } else if let managedPid {
            dependencies.terminatePid(managedPid)
        }

        if let managedPid,
           !dependencies.waitForProcessExit(managedPid, Self.gracefulStopTimeout)
        {
            DebugLog.write("HookServerManager: graceful stop timed out for pid \(managedPid), sending SIGKILL")
            dependencies.killPid(managedPid)
        }

        DebugLog.write("HookServerManager: server stop requested")
    }

    // MARK: - Private

    private func start() {
        lifecycleGeneration &+= 1
        cancelHealthCheck()
        cancelLaunchReadiness()
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
            let launchGeneration = lifecycleGeneration
            let launchedProcess = try dependencies.launchProcess(
                binaryPath,
                port,
                environment,
                { [weak self] terminationStatus in
                    _Concurrency.Task { @MainActor in
                        self?.handleLaunchedProcessTermination(
                            terminationStatus: terminationStatus,
                            generation: launchGeneration,
                        )
                    }
                },
            )
            guard launchGeneration == lifecycleGeneration else {
                launchedProcess.terminate()
                return
            }

            guard status == .starting, !stopRequested else {
                return
            }

            process = launchedProcess
            beginLaunchReadinessObservation(
                generation: launchGeneration,
                authToken: authToken,
            )
            DebugLog.write("HookServerManager: launched pid \(launchedProcess.processIdentifier) on port \(port)")
        } catch {
            process = nil
            healthAuthorizationToken = nil
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
        cancelLaunchReadiness()
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

        if healthy {
            restartBackoffSeconds = Self.initialBackoffSeconds
        } else {
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

    private func cancelHealthCheckLoop() {
        healthCheckLoopTask?.cancel()
        healthCheckLoopTask = nil
    }

    private func cancelLaunchReadiness() {
        launchReadinessTask?.cancel()
        launchReadinessTask = nil
    }

    private func beginLaunchReadinessObservation(generation: UInt64, authToken: String) {
        cancelLaunchReadiness()

        launchReadinessTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            await runLaunchReadinessChecks(generation: generation, authToken: authToken)
        }
    }

    private func runLaunchReadinessChecks(generation: UInt64, authToken: String) async {
        guard status == .starting, generation == lifecycleGeneration, !stopRequested else {
            return
        }

        for attempt in 0 ..< launchReadinessAttempts {
            guard generation == lifecycleGeneration, !stopRequested else {
                return
            }

            if let proc = process, !proc.isRunning {
                handleLaunchedProcessTermination(
                    terminationStatus: proc.terminationStatus,
                    generation: generation,
                )
                return
            }

            let healthy = dependencies.fetchHealth(port, authToken)?.isCompatibleBootstrapService ?? false

            guard generation == lifecycleGeneration, !stopRequested, status == .starting else {
                return
            }

            if healthy {
                completeLaunchReadiness(generation: generation)
                return
            }

            if attempt < launchReadinessAttempts - 1 {
                do {
                    try await _Concurrency.Task.sleep(for: launchReadinessInterval)
                } catch {
                    if _Concurrency.Task.isCancelled {
                        return
                    }
                }
            }
        }

        failLaunchReadiness(
            message: "HookServerManager: launch readiness timed out after \(launchReadinessAttempts) attempts",
            generation: generation,
        )
    }

    private func handleLaunchedProcessTermination(terminationStatus: Int32, generation: UInt64) {
        guard generation == lifecycleGeneration, !stopRequested else {
            return
        }

        if launchReadinessTask != nil || status == .starting {
            failLaunchReadiness(
                message: "HookServerManager: launched process exited during startup with code \(terminationStatus)",
                generation: generation,
            )
            return
        }

        guard status == .running else {
            return
        }

        handleUnexpectedExit(for: generation)
    }

    private func completeLaunchReadiness(generation: UInt64) {
        guard generation == lifecycleGeneration, !stopRequested else {
            return
        }

        launchReadinessTask = nil
        restartBackoffSeconds = Self.initialBackoffSeconds

        let directive = applyLifecycle(.healthCheckFinished(
            healthy: true,
            maxConsecutiveFailures: Self.maxConsecutiveFailures,
        ))

        guard directive == .serverReady else {
            return
        }

        DebugLog.write("HookServerManager: server ready on port \(port)")
        Telemetry.emit("hook_server", "Server started", payload: [
            "port": port,
        ])
    }

    private func failLaunchReadiness(message: String, generation: UInt64) {
        guard generation == lifecycleGeneration, !stopRequested else {
            return
        }

        cancelLaunchReadiness()

        let ownedProcess = process
        let managedPid = ownedProcess?.processIdentifier ?? adoptedPid
        let shouldEscalate = ownedProcess?.isRunning ?? false

        process = nil
        adoptedPid = nil
        healthAuthorizationToken = nil

        if shouldEscalate, let ownedProcess {
            ownedProcess.terminate()
            if ownedProcess.isRunning, let managedPid {
                dependencies.killPid(managedPid)
            }
        } else if let managedPid {
            if dependencies.isProcessAlive(managedPid) {
                dependencies.terminatePid(managedPid)
            }
        }

        _ = applyLifecycle(.launchFailed(message))
        DebugLog.write(message)
        Telemetry.emit("hook_server", "Launch failed", payload: [
            "reason": message,
        ])
    }

    private func handleUnexpectedExit(for generation: UInt64) {
        guard generation == lifecycleGeneration, !stopRequested else {
            return
        }

        cancelLaunchReadiness()

        let oldPid = process?.processIdentifier ?? adoptedPid
        process = nil
        adoptedPid = nil

        // Crash budget: prune old timestamps and check if budget is exhausted
        let now = Date()
        let windowStart = now.addingTimeInterval(-Self.crashBudgetWindow)
        restartTimestamps = restartTimestamps.filter { $0 > windowStart }
        restartTimestamps.append(now)

        if restartTimestamps.count >= Self.crashBudgetLimit {
            let message = "Runtime service exceeded crash budget (\(Self.crashBudgetLimit) restarts in 10 minutes)"
            DebugLog.write("HookServerManager: \(message)")
            Telemetry.emit("hook_server", "Crash budget exhausted", payload: [
                "previous_pid": oldPid ?? 0,
                "restart_count": restartTimestamps.count,
            ])
            cancelHealthCheckLoop()
            _ = applyLifecycle(.launchFailed(message))
            return
        }

        let backoff = restartBackoffSeconds
        restartBackoffSeconds = min(restartBackoffSeconds * 2, Self.maxBackoffSeconds)

        DebugLog.write("HookServerManager: restarting after \(backoff)s backoff (was pid \(oldPid ?? 0))")
        Telemetry.emit("hook_server", "Server restarting", payload: [
            "previous_pid": oldPid ?? 0,
            "backoff_seconds": backoff,
        ])

        let restartGeneration = lifecycleGeneration
        healthCheckTask = _Concurrency.Task { [weak self] in
            do {
                try await _Concurrency.Task.sleep(for: .seconds(backoff))
            } catch {
                return
            }
            guard let self,
                  restartGeneration == lifecycleGeneration,
                  !self.stopRequested
            else { return }
            await MainActor.run {
                guard restartGeneration == self.lifecycleGeneration,
                      !self.stopRequested
                else { return }
                self.healthCheckTask = nil
                self.start()
            }
        }
    }

    private static var defaultBinaryPath: String {
        HookBinaryLocator.preferredLaunchBinaryPath()
    }

    nonisolated static func executablePathsMatch(runningPath: String, configuredPath: String) -> Bool {
        resolveExecutablePath(runningPath) == resolveExecutablePath(configuredPath)
    }

    private nonisolated static func resolveExecutablePath(_ path: String) -> String {
        PathNormalizer.normalize(path)
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

    nonisolated static func fetchHealth(port: UInt16, authToken: String?) -> RuntimeHealth? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(healthPath)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var health: RuntimeHealth?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let decoded = try? JSONDecoder().decode(RuntimeHealth.self, from: data)
            else {
                return
            }
            health = decoded
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            task.cancel()
            return nil
        }
        return health
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
        isProcessAlive: { pid in hookServerProcessIsAlive(pid: pid) },
        isManagedServerProcess: { pid, expectedBinaryPath in
            guard let runningPath = LiveHookServerProcess.executablePath(pid: pid) else {
                return false
            }
            return HookServerManager.executablePathsMatch(
                runningPath: runningPath,
                configuredPath: expectedBinaryPath,
            )
        },
        terminatePid: { pid in
            _ = kill(pid, SIGTERM)
        },
        killPid: { pid in
            _ = kill(pid, SIGKILL)
        },
        waitForProcessExit: { pid, timeout in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if !hookServerProcessIsAlive(pid: pid) {
                    return true
                }
                usleep(10000)
            }
            return !hookServerProcessIsAlive(pid: pid)
        },
        loadRuntimeServiceConnection: { _ in
            RuntimeServiceConnection.current()
        },
        launchProcess: { binaryPath, port, environment, terminationHandler in
            try LiveHookServerProcess(
                binaryPath: binaryPath,
                port: port,
                environment: environment,
                terminationHandler: terminationHandler,
            )
        },
        fetchHealth: { port, authToken in
            HookServerManager.fetchHealth(port: port, authToken: authToken)
        },
    )
}
