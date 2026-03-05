import Foundation

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

    private var process: Process?
    private let port: UInt16
    private let binaryPath: String

    // MARK: - Init

    init(port: UInt16 = HookServerManager.defaultPort) {
        self.port = port
        binaryPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/hud-hook").path
    }

    // MARK: - Lifecycle

    /// Starts the server if the binary exists and the server isn't already running.
    ///
    /// On launch, checks for a stale PID file from a previous app session. If the
    /// old process is still alive on our port, we adopt it. If it's dead, we clean
    /// up the PID file and start fresh.
    func startIfNeeded() {
        guard status != .running, status != .starting else { return }

        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            DebugLog.write("HookServerManager: binary not found at \(binaryPath), skipping")
            status = .failed("Binary not found")
            return
        }

        // Check for orphaned server from a previous app session
        if let stalePid = readPidFile() {
            if isProcessAlive(stalePid) {
                DebugLog.write("HookServerManager: adopting existing server pid \(stalePid) on port \(port)")
                status = .starting
                // Don't hold a Process reference — we didn't spawn it, so we
                // monitor it purely via health checks. If it dies, checkHealth()
                // will trigger handleUnexpectedExit() and we'll spawn a new one.
                return
            } else {
                DebugLog.write("HookServerManager: removing stale PID file (pid \(stalePid) dead)")
                removePidFile()
            }
        }

        start()
    }

    /// Checks server liveness via GET /health.
    /// Restarts the server after `maxConsecutiveFailures` consecutive failures.
    func checkHealth() {
        guard status == .running || status == .starting else { return }

        // Check if the process is still alive first
        if let proc = process, !proc.isRunning {
            DebugLog.write("HookServerManager: process exited with code \(proc.terminationStatus)")
            handleUnexpectedExit()
            return
        }

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            let healthy = await fetchHealth()
            await MainActor.run {
                if healthy {
                    self.consecutiveHealthFailures = 0
                    if self.status == .starting {
                        self.status = .running
                        DebugLog.write("HookServerManager: server ready on port \(self.port)")
                        Telemetry.emit("hook_server", "Server started", payload: [
                            "port": self.port,
                        ])
                    }
                } else {
                    self.consecutiveHealthFailures += 1
                    DebugLog.write(
                        "HookServerManager: health check failed (\(self.consecutiveHealthFailures)/\(Self.maxConsecutiveFailures))",
                    )
                    if self.consecutiveHealthFailures >= Self.maxConsecutiveFailures {
                        self.handleUnexpectedExit()
                    }
                }
            }
        }
    }

    /// Gracefully stops the server process.
    func stop() {
        guard let proc = process, proc.isRunning else {
            status = .stopped
            process = nil
            return
        }

        // SIGTERM triggers the AtomicBool shutdown flag in serve.rs
        proc.terminate()
        proc.waitUntilExit()
        process = nil
        status = .stopped
        DebugLog.write("HookServerManager: server stopped")
    }

    // MARK: - Private

    private func start() {
        status = .starting
        consecutiveHealthFailures = 0

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["serve", "--port", String(port)]

        // Inherit the environment so CAPACITOR_CORE_ENABLED and snapshot path are picked up
        var env = ProcessInfo.processInfo.environment
        env["CAPACITOR_CORE_ENABLED"] = "1"
        proc.environment = env

        // Discard stdout/stderr — the server logs via tracing to its own log file
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            process = proc
            DebugLog.write("HookServerManager: launched pid \(proc.processIdentifier) on port \(port)")
        } catch {
            status = .failed(error.localizedDescription)
            DebugLog.write("HookServerManager: failed to launch — \(error)")
            Telemetry.emit("hook_server", "Launch failed", payload: [
                "error": String(describing: error),
            ])
        }
    }

    private func handleUnexpectedExit() {
        let oldPid = process?.processIdentifier
        process = nil
        consecutiveHealthFailures = 0

        DebugLog.write("HookServerManager: restarting (was pid \(oldPid ?? 0))")
        Telemetry.emit("hook_server", "Server restarting", payload: [
            "previous_pid": oldPid ?? 0,
        ])

        start()
    }

    // MARK: - PID File Helpers

    private var pidFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/runtime/hud-hook-serve-\(port).pid").path
    }

    private func readPidFile() -> Int32? {
        guard let contents = try? String(contentsOfFile: pidFilePath, encoding: .utf8) else {
            return nil
        }
        return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(atPath: pidFilePath)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        // kill(pid, 0) checks existence without sending a signal
        kill(pid, 0) == 0
    }

    private nonisolated func fetchHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(Self.healthPath)") else {
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            // Parse {"status":"ok"}
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
