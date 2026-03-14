import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "TerminalLauncher")

func debugLog(_ message: String) {
    DebugLog.write("[TerminalLauncher] \(message)")
}

protocol AppleScriptClient {
    func runOutput(_ script: String) -> AppleScriptExecutionResult
}

struct AppleScriptExecutionResult: Equatable {
    let success: Bool
    let output: String?
    let error: String?
}

private struct DefaultAppleScriptClient: AppleScriptClient {
    func runOutput(_ script: String) -> AppleScriptExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown"
                logger.warning("AppleScript failed (exit \(process.terminationStatus)): \(errorMsg)")
                debugLog("runAppleScript failed exit=\(process.terminationStatus) error=\(errorMsg)")
                return AppleScriptExecutionResult(success: false, output: nil, error: errorMsg)
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)
            return AppleScriptExecutionResult(success: true, output: output, error: nil)
        } catch {
            logger.error("AppleScript launch failed: \(error.localizedDescription)")
            debugLog("runAppleScript failed error=\(error.localizedDescription)")
            return AppleScriptExecutionResult(success: false, output: nil, error: error.localizedDescription)
        }
    }
}

// MARK: - Shell Escape Utilities

/// Escapes a string for safe use in single-quoted shell arguments.
/// Handles single quotes by ending the quote, adding an escaped quote, and starting a new quote.
/// Example: "foo'bar" becomes "'foo'\''bar'"
func shellEscape(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Terminal Launcher

struct TerminalActivationResult: Equatable {
    let projectName: String
    let projectPath: String
    let success: Bool
    let usedFallback: Bool
    let failureReason: TerminalActivationFailureReason?
}

//
// Handles "click project → focus terminal" activation. The goal is to bring the user
// to their existing terminal window for a project, not spawn new windows unnecessarily.
//
// ACTIVATION FLOW (Ghostty + tmux):
//
//   1. Resolve attached tmux client
//   2. Ensure tmux session exists for project → create if needed
//   3. Switch client to project session → focus the correct Ghostty surface
//
// If no client exists: launch new Ghostty tab with tmux attach/new-session.
//

@MainActor
final class TerminalLauncher {
    private enum Constants {
        static let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
    }

    private let appleScript: AppleScriptClient
    private let ghosttyAutomationClient: GhosttyAutomationClient
    var activationIntentResolver: ((String?, String, String?) -> ActivationPolicyIntent)?
    private let fallbackTmuxSessionResolver: ((String) async -> String?)?
    /// Override for the unified activation flow. Tests use this to intercept card-click behavior.
    private let activateProjectSessionOverride: ((String, String) async -> Bool)?

    private var pendingActivationFailureReason: TerminalActivationFailureReason?
    private lazy var driverRegistry = TerminalDriverRegistry(
        appleScript: appleScript,
        ghosttyAutomationClient: ghosttyAutomationClient,
        isTerminalRunning: { [weak self] app in self?.isTerminalRunning(app) ?? false },
        runShell: { script in
            await Self.runBashScriptWithResult(script)
        },
    )
    private var tmuxRouter: TmuxRouter {
        TmuxRouter(
            runScript: { await Self.runBashScriptWithResult($0) },
            homeDirectoryProvider: { NSHomeDirectory() },
        )
    }

    private lazy var activationCoordinator = TerminalActivationCoordinator(
        resolveSessionName: { [weak self] project in
            guard let self else {
                return URL(fileURLWithPath: project.path).lastPathComponent
            }
            return await resolveSessionName(for: project)
        },
        runResolvedActivation: { [weak self] sessionName, projectPath in
            guard let self else { return false }
            return await runResolvedActivation(sessionName: sessionName, projectPath: projectPath)
        },
        currentFailureReason: { [weak self] in
            self?.pendingActivationFailureReason
        },
    )

    var onActivationResult: ((TerminalActivationResult) -> Void)? {
        get { activationCoordinator.onActivationResult }
        set { activationCoordinator.onActivationResult = newValue }
    }

    // MARK: - Public API

    init(
        appleScript: AppleScriptClient = DefaultAppleScriptClient(),
        ghosttyAutomationClient: GhosttyAutomationClient? = nil,
        fallbackTmuxSessionResolver: ((String) async -> String?)? = nil,
        activateProjectSessionOverride: ((String, String) async -> Bool)? = nil,
    ) {
        self.appleScript = appleScript
        self.ghosttyAutomationClient = ghosttyAutomationClient ?? DefaultGhosttyAutomationClient(appleScript: appleScript)
        self.fallbackTmuxSessionResolver = fallbackTmuxSessionResolver
        self.activateProjectSessionOverride = activateProjectSessionOverride
    }

    // MARK: - Unified Activation Primitives (spec v2)

    /// Check if a TTY device is still alive (file exists at /dev path).
    /// Ensure a tmux session exists and switch the given client to it.
    /// Spec decision tree step 2: try switch → if fail, create session → retry switch.
    static func ensureSessionAndSwitch(
        sessionName: String,
        projectPath: String,
        clientTty: String,
        targetPane: String? = nil,
        runScript: @escaping (String) async -> (exitCode: Int32, output: String?),
    ) async -> Bool {
        await TmuxRouter(runScript: runScript).ensureSessionAndSwitch(
            sessionName: sessionName,
            projectPath: projectPath,
            clientTty: clientTty,
            targetPane: targetPane,
        )
    }

    func launchTerminal(for project: Project) {
        activationCoordinator.launchTerminal(for: project)
    }

    /// Resolve a tmux session name for a project.
    /// Prefers an existing tmux session matching the project path; falls back to project slug.
    private func resolveSessionName(for project: Project) async -> String {
        if let resolved = resolveActivationIntent(
            clientTty: nil,
            projectPath: project.path,
            sessionName: nil,
        ).sessionName {
            return resolved
        }
        if let resolver = fallbackTmuxSessionResolver,
           let resolved = await resolver(project.path),
           !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let existing = await findTmuxSessionForPath(project.path) {
            return existing
        }
        // Default: use project directory name as session name
        return URL(fileURLWithPath: project.path).lastPathComponent
    }

    /// Instance method that wires real dependencies into the shared coordinator flow.
    /// Uses activateProjectSessionOverride when available (for test injection).
    private func runResolvedActivation(sessionName: String, projectPath: String) async -> Bool {
        pendingActivationFailureReason = nil
        if let activateProjectSessionOverride {
            return await activateProjectSessionOverride(sessionName, projectPath)
        }
        return await TerminalActivationCoordinator.runActivationFlow(
            sessionName: sessionName,
            projectPath: projectPath,
            resolveAnyClientTty: {
                await tmuxRouter.resolveAnyClientTty(
                    preferredHostTty: resolveActivationIntent(
                        clientTty: nil,
                        projectPath: projectPath,
                        sessionName: sessionName,
                    ).hostTty,
                    targetSession: sessionName,
                )
            },
            ensureAndSwitch: { session, path, tty, targetPane in
                await tmuxRouter.ensureSessionAndSwitch(
                    sessionName: session,
                    projectPath: path,
                    clientTty: tty,
                    targetPane: targetPane,
                )
            },
            launchTerminalWithTmux: { [weak self] session, path in
                guard let self else { return false }
                return await launchTerminalWithTmuxSession(session, projectPath: path)
            },
            activateTerminal: { [weak self] tty, path, sessionHint in
                guard let self else { return .failed(nil) }
                return await activateTerminalAfterTmuxSwitch(
                    clientTty: tty,
                    projectPath: path,
                    tmuxSessionHint: sessionHint,
                )
            },
            resolveTargetPane: { [weak self] clientTty in
                self?.resolveActivationIntent(
                    clientTty: clientTty,
                    projectPath: projectPath,
                    sessionName: sessionName,
                ).paneId
            },
            pollForNewClient: { [weak self] in
                await self?.tmuxRouter.pollForNewClient()
            },
        )
    }

    static func resolveAnyTmuxClientTty(
        preferredHostTty: String? = nil,
        targetSession: String? = nil,
        runScript: @escaping (String) async -> (exitCode: Int32, output: String?),
    ) async -> String? {
        await TmuxRouter(runScript: runScript).resolveAnyClientTty(
            preferredHostTty: preferredHostTty,
            targetSession: targetSession,
        )
    }

    // MARK: - Tmux Helpers

    private func launchTerminalWithTmuxSession(_ session: String, projectPath: String? = nil) async -> Bool {
        let app = resolveActivationIntent(
            clientTty: nil,
            projectPath: projectPath ?? "",
            sessionName: session,
        ).terminalApp.app
        debugLog("launchTerminalWithTmuxSession app=\(app.processName) session=\(session) path=\(projectPath ?? "default")")
        let driver = driverRegistry.driver(for: app)
        let tmuxCommand = TmuxRouter.makeAttachCommand(session: session, projectPath: projectPath)
        let launched = await driver.launch(command: tmuxCommand, projectPath: projectPath)
        if !launched {
            pendingActivationFailureReason = driver.lastFailureReason
        }
        return launched
    }

    private func findTmuxSessionForPath(_ projectPath: String) async -> String? {
        await tmuxRouter.findSessionForPath(projectPath)
    }

    nonisolated static func bestTmuxSessionForPath(output: String, projectPath: String, homeDirectory: String) -> String? {
        TmuxRouter.bestSessionForPath(
            output: output,
            projectPath: projectPath,
            homeDirectory: homeDirectory,
        )
    }

    // MARK: - Terminal Focus After Tmux Switch

    private func activateTerminalAfterTmuxSwitch(
        clientTty: String?,
        projectPath: String,
        tmuxSessionHint: String?,
    ) async -> TerminalActivationCoordinator.TerminalFocusResult {
        let app = resolveActivationIntent(
            clientTty: clientTty,
            projectPath: projectPath,
            sessionName: tmuxSessionHint,
        ).terminalApp.app
        let driver = driverRegistry.driver(for: app)
        let result = await driver.focus(
            clientTty: clientTty,
            projectPath: projectPath,
            tmuxSessionHint: tmuxSessionHint,
        )
        if case let .failed(reason) = result {
            pendingActivationFailureReason = reason
        } else {
            pendingActivationFailureReason = driver.lastFailureReason
        }
        return result
    }

    private func resolveActivationIntent(
        clientTty: String?,
        projectPath: String,
        sessionName: String?,
    ) -> ActivationPolicyIntent {
        activationIntentResolver?(clientTty, projectPath, sessionName) ?? ActivationPolicy().resolveIntent(
            projectPath: projectPath,
            clientTty: clientTty,
            sessionName: sessionName,
            route: nil,
            shellState: nil,
        )
    }

    private func isTerminalRunning(_ app: SupportedTerminalApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app.bundleId
        }
    }

    // MARK: - Script Execution

    static func runBashScriptWithResult(_ script: String) async -> (exitCode: Int32, output: String?) {
        if _Concurrency.Task.isCancelled {
            return (-1, nil)
        }

        final class ProcessHolder: @unchecked Sendable {
            private let lock = NSLock()
            private var process: Process?

            func set(_ process: Process) {
                lock.lock()
                self.process = process
                lock.unlock()
            }

            func terminateIfRunning() {
                lock.lock()
                let process = process
                lock.unlock()
                guard let process, process.isRunning else { return }
                process.terminate()
            }
        }

        final class ContinuationBox: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<(exitCode: Int32, output: String?), Never>?

            init(_ continuation: CheckedContinuation<(exitCode: Int32, output: String?), Never>) {
                self.continuation = continuation
            }

            func resume(_ value: (exitCode: Int32, output: String?)) {
                lock.lock()
                let continuation = continuation
                self.continuation = nil
                lock.unlock()
                continuation?.resume(returning: value)
            }
        }

        let processHolder = ProcessHolder()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let continuationBox = ContinuationBox(continuation)

                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/bash")
                    process.arguments = ["-c", script]

                    var env = ProcessInfo.processInfo.environment
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
                    process.environment = env

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice

                    let outputLock = NSLock()
                    var outputData = Data()

                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        outputLock.lock()
                        outputData.append(data)
                        outputLock.unlock()
                    }

                    processHolder.set(process)

                    let timeoutWork = DispatchWorkItem {
                        processHolder.terminateIfRunning()
                    }

                    process.terminationHandler = { process in
                        timeoutWork.cancel()
                        pipe.fileHandleForReading.readabilityHandler = nil
                        let trailingData = pipe.fileHandleForReading.readDataToEndOfFile()
                        outputLock.lock()
                        if !trailingData.isEmpty {
                            outputData.append(trailingData)
                        }
                        let output = String(data: outputData, encoding: .utf8)
                        outputLock.unlock()
                        continuationBox.resume((process.terminationStatus, output))
                    }

                    do {
                        try process.run()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutWork)
                    } catch {
                        timeoutWork.cancel()
                        continuationBox.resume((-1, nil))
                    }
                }
            }
        } onCancel: {
            processHolder.terminateIfRunning()
        }
    }
}

// MARK: - Terminal Launch Scripts

enum TerminalScripts {
    static func launchWithCommand(
        projectPath: String,
        command: String,
        preferredApp: SupportedTerminalApp? = nil,
    ) -> String {
        let app = preferredApp ?? ActivationPolicyFallback.defaultTerminalApp()
        return terminalLaunchCommandScript(
            app: app,
            projectPath: projectPath,
            command: command,
            isRunning: NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == app.bundleId
            },
        )
    }
}
