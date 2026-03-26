import Foundation

/// Coordinates the lifecycle of method-runner subprocess invocations.
///
/// When a method run is started, this coordinator:
/// 1. Prepares the execution root directory under ~/.capacitor/runs/<runID>/
/// 2. Spawns the `method-runner` binary as a subprocess
/// 3. Monitors process lifecycle (completion, crash)
/// 4. Reports status back through a mutation callback
///
/// The method-runner binary handles its own phase execution, checkpoint bridge
/// integration, and gate management. The coordinator only manages the subprocess.
final class MethodRunCoordinator: @unchecked Sendable {
    private let mutateRun: @Sendable (RuntimeRunMutationRequest) async throws -> Void
    private let capacitorRoot: String

    /// Active processes keyed by runID, for crash detection and cleanup.
    private let lock = NSLock()
    private var activeProcesses: [String: Process] = [:]
    /// Default timeout for method-runner subprocess dispatch, in seconds.
    /// 30 minutes allows real implementation tasks (with full test suites) to complete.
    private static let defaultTimeoutSeconds = 1800

    init(
        mutateRun: @escaping @Sendable (RuntimeRunMutationRequest) async throws -> Void,
        capacitorRoot: String = NSHomeDirectory() + "/.capacitor",
    ) {
        self.mutateRun = mutateRun
        self.capacitorRoot = capacitorRoot
    }

    // MARK: - Public

    /// Launch a method run as a subprocess.
    ///
    /// - Parameters:
    ///   - runID: The run ID (already created via runtime service mutation).
    ///   - methodID: Built-in method template ID (e.g. "execution_only").
    ///   - projectPath: The project path for bridge integration.
    ///   - ideaTitle: Optional title of the idea being executed.
    ///   - ideaDescription: Optional description of the idea being executed.
    func startRun(
        runID: String,
        methodID: String,
        projectPath: String,
        ideaTitle: String? = nil,
        ideaDescription: String? = nil,
    ) async throws {
        let executionRoot = prepareExecutionRoot(runID: runID)

        // Write context.json so the Rust prompt builder can include task context
        writeContextFile(
            executionRoot: executionRoot,
            title: ideaTitle,
            description: ideaDescription,
        )
        let binaryPath = try resolveMethodRunnerBinary()

        DebugLog.write(
            "MethodRunCoordinator.startRun runID=\(runID) method=\(methodID) root=\(executionRoot)",
        )

        let process = Process()
        let errorPipe = Pipe()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.arguments = [
            "run",
            "--method-id", methodID,
            "--root", executionRoot,
            "--real",
            "--timeout", "\(Self.defaultTimeoutSeconds)",
            "--bridge-run-id", runID,
            "--bridge-project-path", projectPath,
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Ensure the binary can find compose-prompt.sh and codex
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        process.environment = env

        lock.lock()
        activeProcesses[runID] = process
        lock.unlock()

        let stderrBuffer = ProcessLineBuffer(limit: 30)

        let drainTask = _Concurrency.Task.detached {
            do {
                for try await line in errorPipe.fileHandleForReading.bytes.lines {
                    await stderrBuffer.append(line)
                }
            } catch {}
        }

        let stdoutDrainTask = _Concurrency.Task.detached {
            do {
                for try await _ in outputPipe.fileHandleForReading.bytes.lines {}
            } catch {}
        }

        do {
            try process.run()
        } catch {
            lock.lock()
            activeProcesses.removeValue(forKey: runID)
            lock.unlock()
            DebugLog.write(
                "MethodRunCoordinator.startRun launch failure runID=\(runID) error=\(error.localizedDescription)",
            )
            throw MethodRunError.launchFailed(underlying: error)
        }

        // Wait for process to complete
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        drainTask.cancel()
        stdoutDrainTask.cancel()

        lock.lock()
        activeProcesses.removeValue(forKey: runID)
        lock.unlock()

        let exitCode = process.terminationStatus
        let stderrTail = await stderrBuffer.lines()

        DebugLog.write(
            "MethodRunCoordinator.startRun completed runID=\(runID) exit=\(exitCode)",
        )

        if exitCode != 0 {
            let errorSummary = stderrTail.suffix(5).joined(separator: "\n")
            DebugLog.write(
                "MethodRunCoordinator.startRun failure runID=\(runID) stderr=\(errorSummary)",
            )

            // Mark run as failed in runtime service
            do {
                try await mutateRun(RuntimeRunMutationRequest(
                    kind: "fail",
                    projectPath: projectPath,
                    runId: runID,
                    checkpointId: nil,
                    methodId: nil,
                    involvement: nil,
                    checkpointKind: nil,
                    checkpointTitle: nil,
                    checkpointSummary: nil,
                    checkpointBriefPath: nil,
                    checkpointManifestPath: nil,
                    checkpointMediaArtifacts: [],
                    checkpointMermaidSources: [],
                    captureUrl: nil,
                    decisionAction: nil,
                    decisionNote: nil,
                    sessionId: nil,
                    delegationWorkerId: nil,
                    statusMessage: nil,
                    captureRequestId: nil,
                    clientId: nil,
                    observedCaptureUrl: nil,
                    captureFailureReason: nil,
                    completedMediaArtifacts: [],
                ))
            } catch {
                DebugLog.write(
                    "MethodRunCoordinator.startRun fail-mutation error runID=\(runID) error=\(error.localizedDescription)",
                )
            }

            throw MethodRunError.processExitedWithError(code: exitCode, stderr: errorSummary)
        }
    }

    /// Cancel a running method run by terminating its process.
    func cancelRun(runID: String) {
        lock.lock()
        let process = activeProcesses[runID]
        lock.unlock()

        if let process, process.isRunning {
            DebugLog.write("MethodRunCoordinator.cancelRun runID=\(runID)")
            process.terminate()
        }
    }

    /// Whether a given run has an active subprocess.
    func isRunActive(runID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeProcesses[runID]?.isRunning ?? false
    }

    // MARK: - Private

    private func writeContextFile(
        executionRoot: String,
        title: String?,
        description: String?,
    ) {
        let context: [String: Any] = [
            "version": 1,
            "title": title ?? "",
            "description": description ?? "",
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: context)
        } catch {
            DebugLog.write(
                "Warning: MethodRunCoordinator.writeContextFile failed to serialize context.json for executionRoot=\(executionRoot): \(error)",
            )
            return
        }
        let contextPath = executionRoot + "/context.json"
        if !FileManager.default.createFile(atPath: contextPath, contents: data) {
            DebugLog.write(
                "Warning: MethodRunCoordinator.writeContextFile failed to create context.json at \(contextPath)",
            )
        }
    }

    private func prepareExecutionRoot(runID: String) -> String {
        let path = "\(capacitorRoot)/runs/\(runID)"
        try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
        )
        return path
    }

    private func resolveMethodRunnerBinary() throws -> String {
        // 1. Check METHOD_RUNNER_PATH env var
        if let envPath = ProcessInfo.processInfo.environment["METHOD_RUNNER_PATH"],
           FileManager.default.isExecutableFile(atPath: envPath)
        {
            return envPath
        }

        // 2. Check cargo release build
        let repoRoot = findRepoRoot()
        if let root = repoRoot {
            let cargoPath = root + "/target/release/method-runner"
            if FileManager.default.isExecutableFile(atPath: cargoPath) {
                return cargoPath
            }
        }

        // 3. Check ~/.local/bin
        let localBin = NSHomeDirectory() + "/.local/bin/method-runner"
        if FileManager.default.isExecutableFile(atPath: localBin) {
            return localBin
        }

        throw MethodRunError.binaryNotFound
    }

    private func findRepoRoot() -> String? {
        // Walk up from the current binary to find the repo root
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        // Verify this is the repo root by checking for Cargo.toml
        if FileManager.default.fileExists(atPath: dir + "/Cargo.toml") {
            return dir
        }
        // Fallback: check from Bundle
        dir = Bundle.main.bundlePath
        for _ in 0 ..< 6 {
            dir = (dir as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: dir + "/Cargo.toml") {
                return dir
            }
        }
        return nil
    }
}

// MARK: - Errors

enum MethodRunError: LocalizedError {
    case binaryNotFound
    case launchFailed(underlying: Error)
    case processExitedWithError(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "method-runner binary not found. Build with `cargo build -p capacitor-core --release` or set METHOD_RUNNER_PATH."
        case let .launchFailed(underlying):
            "Failed to launch method-runner: \(underlying.localizedDescription)"
        case let .processExitedWithError(code, stderr):
            "method-runner exited with code \(code): \(stderr)"
        }
    }
}

// MARK: - Line Buffer

/// Thread-safe line buffer for capturing process stderr.
private actor ProcessLineBuffer {
    private var buffer: [String] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ line: String) {
        buffer.append(line)
        if buffer.count > limit {
            buffer.removeFirst()
        }
    }

    func lines() -> [String] {
        buffer
    }
}
