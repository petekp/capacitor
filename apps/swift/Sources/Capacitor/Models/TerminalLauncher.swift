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

enum TerminalAutomationEnvironment {
    private static let basePath = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")

    private static let passthroughKeys = [
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "TMPDIR",
        "LANG",
        "SSH_AUTH_SOCK",
    ]

    static func make(
        source: [String: String] = ProcessInfo.processInfo.environment,
    ) -> [String: String] {
        var environment: [String: String] = [
            "PATH": basePath,
        ]

        for key in passthroughKeys {
            guard let value = source[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                continue
            }
            environment[key] = value
        }

        if environment["HOME"] == nil {
            environment["HOME"] = NSHomeDirectory()
        }
        if environment["USER"] == nil {
            environment["USER"] = NSUserName()
        }
        if environment["LOGNAME"] == nil {
            environment["LOGNAME"] = environment["USER"]
        }
        if environment["SHELL"] == nil {
            environment["SHELL"] = "/bin/zsh"
        }

        return environment
    }
}

struct DefaultAppleScriptClient: AppleScriptClient {
    private let environmentProvider: () -> [String: String]

    init(
        environmentProvider: @escaping () -> [String: String] = {
            TerminalAutomationEnvironment.make()
        },
    ) {
        self.environmentProvider = environmentProvider
    }

    func runOutput(_ script: String) -> AppleScriptExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.environment = environmentProvider()

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
    var activationIntentResolver: ((String?, String, String?) async -> ActivationPolicyIntent)?
    private let sessionResolutionPolicy: SessionResolutionPolicy
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
            let intent = await resolveActivationIntent(
                clientTty: nil,
                projectPath: project.path,
                sessionName: nil,
            )
            return await sessionResolutionPolicy.chooseSessionName(
                projectPath: project.path,
                routedSessionName: intent.sessionName,
            )
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
        sessionResolutionPolicy: SessionResolutionPolicy = SessionResolutionPolicy(),
        activateProjectSessionOverride: ((String, String) async -> Bool)? = nil,
    ) {
        self.appleScript = appleScript
        self.ghosttyAutomationClient = ghosttyAutomationClient ?? DefaultGhosttyAutomationClient(appleScript: appleScript)
        self.sessionResolutionPolicy = sessionResolutionPolicy
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

    func focusExistingTerminal(projectPath: String, sessionName: String? = nil) async -> Bool {
        pendingActivationFailureReason = nil
        let app = await resolveActivationIntent(
            clientTty: nil,
            projectPath: projectPath,
            sessionName: sessionName,
        ).terminalApp.app
        let driver = driverRegistry.driver(for: app)
        let result = await driver.focus(
            clientTty: nil,
            projectPath: projectPath,
            tmuxSessionHint: sessionName,
        )
        TerminalActivationTrace.log(
            surface: .directFocus,
            route: "focus_existing_terminal",
            projectPath: projectPath,
            sessionName: sessionName,
            evidence: sessionName == nil ? ["working_directory_or_title"] : ["session_hint", "working_directory_or_title"],
            action: "focus_existing",
            outcome: result.traceOutcome,
            reason: result.traceFailureReason,
        )
        if case let .failed(reason) = result {
            pendingActivationFailureReason = reason
        } else {
            pendingActivationFailureReason = driver.lastFailureReason
        }
        return result == .focused || result == .alreadySelected
    }

    /// Instance method that wires real dependencies into the shared coordinator flow.
    /// Uses activateProjectSessionOverride when available (for test injection).
    private func runResolvedActivation(sessionName: String, projectPath: String) async -> Bool {
        pendingActivationFailureReason = nil
        if let activateProjectSessionOverride {
            return await activateProjectSessionOverride(sessionName, projectPath)
        }
        let initialIntent = await resolveActivationIntent(
            clientTty: nil,
            projectPath: projectPath,
            sessionName: sessionName,
        )
        return await TerminalActivationCoordinator.runActivationFlow(
            sessionName: sessionName,
            projectPath: projectPath,
            resolveAnyClientTty: {
                let intent = await resolveActivationIntent(
                    clientTty: nil,
                    projectPath: projectPath,
                    sessionName: sessionName,
                )
                // Clear stale hostTty if the resolved session name differs from the route.
                // The intent's hostTty belongs to the routed session, not necessarily the
                // session we resolved to activate.
                let preferredTty = (intent.sessionName == sessionName) ? intent.hostTty : nil
                return await tmuxRouter.resolveAnyClientTty(
                    preferredHostTty: preferredTty,
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
                guard let self else { return nil }
                let intent = await resolveActivationIntent(
                    clientTty: clientTty,
                    projectPath: projectPath,
                    sessionName: sessionName,
                )
                // Clear stale paneId if the resolved session name differs from the route.
                return (intent.sessionName == sessionName) ? intent.paneId : nil
            },
            pollForNewClient: { [weak self] in
                await self?.tmuxRouter.pollForNewClient()
            },
            switchAlreadySelectedDirectMatchWhenClientExists: Self.shouldSwitchAlreadySelectedDirectMatch(
                intent: initialIntent,
                resolvedSessionName: sessionName,
            ),
        )
    }

    static func shouldSwitchAlreadySelectedDirectMatch(
        intent: ActivationPolicyIntent,
        resolvedSessionName: String,
    ) -> Bool {
        let hasRuntimeRouteEvidence = intent.terminalApp.source == .runtimeRoute
            || intent.hostTty?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || intent.paneId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        guard hasRuntimeRouteEvidence else {
            return false
        }

        guard let routedSession = intent.sessionName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !routedSession.isEmpty
        else {
            return false
        }

        return routedSession == resolvedSessionName
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
        let app = await resolveActivationIntent(
            clientTty: nil,
            projectPath: projectPath ?? "",
            sessionName: session,
        ).terminalApp.app
        debugLog("launchTerminalWithTmuxSession app=\(app.processName) session=\(session) path=\(projectPath ?? "default")")
        let driver = driverRegistry.driver(for: app)
        let tmuxCommand = TmuxRouter.makeAttachCommand(session: session, projectPath: projectPath)
        let launched = await driver.launch(command: tmuxCommand, projectPath: projectPath)
        TerminalActivationTrace.log(
            surface: .activationFlow,
            route: "launch",
            projectPath: projectPath,
            sessionName: session,
            evidence: ["terminal_driver:\(app.processName)", "tmux_attach_command"],
            action: "launch_terminal",
            outcome: launched ? "launched" : "failed",
            reason: driver.lastFailureReason.map { String(describing: $0) },
        )
        if !launched {
            pendingActivationFailureReason = driver.lastFailureReason
        }
        return launched
    }

    // MARK: - Terminal Focus After Tmux Switch

    private func activateTerminalAfterTmuxSwitch(
        clientTty: String?,
        projectPath: String,
        tmuxSessionHint: String?,
    ) async -> TerminalActivationCoordinator.TerminalFocusResult {
        let app = await resolveActivationIntent(
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
    ) async -> ActivationPolicyIntent {
        await activationIntentResolver?(clientTty, projectPath, sessionName) ?? ActivationPolicy().resolveIntent(
            projectPath: projectPath,
            clientTty: clientTty,
            sessionName: sessionName,
            route: nil,
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

                    process.environment = Self.terminalAutomationEnvironment()

                    let pipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = errorPipe

                    let outputLock = NSLock()
                    var outputData = Data()
                    var errorData = Data()

                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        outputLock.lock()
                        outputData.append(data)
                        outputLock.unlock()
                    }

                    errorPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        outputLock.lock()
                        errorData.append(data)
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

                        errorPipe.fileHandleForReading.readabilityHandler = nil
                        let trailingErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        outputLock.lock()
                        if !trailingErrorData.isEmpty {
                            errorData.append(trailingErrorData)
                        }
                        let stderr = String(data: errorData, encoding: .utf8)
                        outputLock.unlock()

                        if process.terminationStatus != 0,
                           let stderr,
                           !stderr.isEmpty
                        {
                            DebugLog.write(
                                "[TerminalLauncher] runBashScriptWithResult failed script=\(String(script.prefix(200))) stderr=\(stderr)",
                            )
                        }
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

    nonisolated static func terminalAutomationEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment,
    ) -> [String: String] {
        // New terminal automation behavior: build a narrow environment for
        // open/osascript/tmux helpers instead of forwarding Capacitor's app
        // process environment. This keeps Codex/app-only flags and secrets out
        // of user-facing terminal launches.
        TerminalAutomationEnvironment.make(source: source)
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
