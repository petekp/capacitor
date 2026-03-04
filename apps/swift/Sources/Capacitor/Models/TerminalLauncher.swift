import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "TerminalLauncher")

private func telemetry(_ message: String, payload: [String: Any] = [:]) {
    let output = "[TELEMETRY] \(message)\n"
    FileHandle.standardError.write(Data(output.utf8))
    DebugLog.write("[TerminalLauncher] \(message)")
    Telemetry.emit("activation_log", message, payload: payload)
}

private func debugLog(_ message: String) {
    DebugLog.write("[TerminalLauncher] \(message)")
}

// MARK: - Shell Escape Utilities

/// Escapes a string for safe use in single-quoted shell arguments.
/// Handles single quotes by ending the quote, adding an escaped quote, and starting a new quote.
/// Example: "foo'bar" becomes "'foo'\''bar'"
private func shellEscape(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Escapes a string for safe interpolation into a bash double-quoted string.
/// Escapes: backslash, double quote, dollar sign, and backticks.
/// Example: "foo$bar" becomes "foo\$bar"
private func bashDoubleQuoteEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`")
}

// MARK: - Terminal Launcher

struct TerminalActivationResult: Equatable {
    let projectName: String
    let projectPath: String
    let success: Bool
    let usedFallback: Bool
}

//
// Handles "click project → focus terminal" activation. The goal is to bring the user
// to their existing terminal window for a project, not spawn new windows unnecessarily.
//
// ACTIVATION FLOW (Ghostty + tmux):
//
//   1. Resolve tmux client (tmux list-clients) → identifies attached terminal
//   2. Ensure tmux session exists for project → create if needed
//   3. Switch client to project session → focus correct tab via AX
//
// If no client exists: launch new Ghostty tab with tmux attach/new-session.
//

@MainActor
final class TerminalLauncher {
    private enum Constants {
        static let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
    }

    private let activator: any TerminalActivator
    private let fallbackTmuxSessionResolver: ((String) async -> String?)?
    /// Override for the unified activation flow. Tests use this to intercept card-click behavior.
    private let activateProjectSessionOverride: ((String, String) async -> Bool)?
    var onActivationResult: ((TerminalActivationResult) -> Void)?

    private var latestLaunchRequestID: UInt64 = 0
    private var launchTask: _Concurrency.Task<Void, Never>?

    // MARK: - Public API

    init(
        activator: (any TerminalActivator)? = nil,
        fallbackTmuxSessionResolver: ((String) async -> String?)? = nil,
        activateProjectSessionOverride: ((String, String) async -> Bool)? = nil,
    ) {
        self.activator = activator ?? GhosttyActivator()
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
        runScript: (String) async -> (exitCode: Int32, output: String?),
    ) async -> Bool {
        let escaped = shellEscape(sessionName)
        let escapedTty = shellEscape(clientTty)
        let switchCmd = "tmux switch-client -c \(escapedTty) -t \(escaped) 2>&1"

        // Try switching directly (session may already exist).
        let first = await runScript(switchCmd)
        if first.exitCode == 0 { return true }

        // Session doesn't exist — create it, then retry.
        let escapedPath = shellEscape(projectPath)
        let createResult = await runScript("tmux new-session -d -s \(escaped) -c \(escapedPath) 2>&1")
        if createResult.exitCode != 0 { return false }

        let retry = await runScript(switchCmd)
        return retry.exitCode == 0
    }

    /// Unified activation flow:
    /// 1. Resolve client (tmux list-clients → auto-attach / launch)
    /// 2. Ensure session + switch
    /// 3. Focus terminal
    static func performUnifiedActivation(
        sessionName: String,
        projectPath: String,
        resolveAnyClientTty: () async -> String?,
        hasExistingSession: (String) async -> Bool = { _ in false },
        ensureAndSwitch: (String, String, String) async -> Bool,
        launchTerminalWithTmux: (String, String) -> Void,
        attachToExistingSession: ((String) -> Void)? = nil,
        activateTerminal: (String?, String, String?) async -> Bool,
        pollForNewClient: (() async -> String?)? = nil,
    ) async -> Bool {
        // Step 1: Resolve client via tmux list-clients.
        let clientTty = await resolveAnyClientTty()

        guard let clientTty else {
            // No client available. Check if a detached session already exists
            // for this project — if so, auto-attach to it (reuses the current
            // Ghostty tab instead of opening a new one).
            if let attach = attachToExistingSession,
               await hasExistingSession(sessionName)
            {
                debugLog("performUnifiedActivation noClient, auto-attaching to existing session=\(sessionName)")
                attach(sessionName)
            } else {
                debugLog("performUnifiedActivation noClient, launching new terminal session=\(sessionName)")
                launchTerminalWithTmux(sessionName, projectPath)
            }
            // Wait for new client to appear (sync barrier).
            if let poll = pollForNewClient {
                _ = await poll()
            }
            return true
        }

        // Step 2: Ensure session exists + switch client to it.
        let switched = await ensureAndSwitch(sessionName, projectPath, clientTty)
        guard switched else {
            debugLog("performUnifiedActivation ensureAndSwitch failed session=\(sessionName)")
            return false
        }

        // Step 3: Focus terminal.
        let focused = await activateTerminal(clientTty, projectPath, sessionName)
        if !focused {
            // Terminal that owned the TTY is gone — launch a fresh one.
            debugLog("performUnifiedActivation terminal gone for tty=\(clientTty), relaunching")
            launchTerminalWithTmux(sessionName, projectPath)
            if let poll = pollForNewClient {
                _ = await poll()
            }
        }
        return true
    }

    func launchTerminal(for project: Project) {
        latestLaunchRequestID &+= 1
        let requestID = latestLaunchRequestID
        launchTask?.cancel()
        launchTask = _Concurrency.Task { [weak self] in
            await self?.launchTerminalAsync(for: project, requestID: requestID)
        }
    }

    private func launchTerminalAsync(for project: Project, requestID: UInt64) async {
        guard shouldProcessLaunchRequest(requestID) else {
            debugLog("launchTerminalAsync ignored stale request id=\(requestID) path=\(project.path)")
            return
        }

        // Resolve tmux session name: try existing session for this path, else use project slug.
        let sessionName = await resolveSessionName(for: project)

        guard shouldProcessLaunchRequest(requestID) else {
            debugLog("launchTerminalAsync ignored stale request id=\(requestID) path=\(project.path)")
            return
        }

        // Run unified activation flow.
        let success = await activateProjectSession(
            sessionName: sessionName,
            projectPath: project.path,
        )

        // Post-activation stale check: if a newer request arrived while we were activating,
        // suppress result emission so only the latest request reports.
        guard shouldProcessLaunchRequest(requestID) else {
            debugLog("launchTerminalAsync ignored stale request id=\(requestID) path=\(project.path)")
            return
        }

        Telemetry.emit("activation_outcome", "unified_v2", payload: [
            "project": project.name,
            "path": project.path,
            "session": sessionName,
            "success": success,
        ])
        onActivationResult?(TerminalActivationResult(
            projectName: project.name,
            projectPath: project.path,
            success: success,
            usedFallback: false,
        ))
    }

    /// Resolve a tmux session name for a project.
    /// Prefers an existing tmux session matching the project path; falls back to project slug.
    private func resolveSessionName(for project: Project) async -> String {
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

    /// Instance method that wires real dependencies into performUnifiedActivation.
    /// Uses activateProjectSessionOverride when available (for test injection).
    private func activateProjectSession(sessionName: String, projectPath: String) async -> Bool {
        if let activateProjectSessionOverride {
            return await activateProjectSessionOverride(sessionName, projectPath)
        }
        return await Self.performUnifiedActivation(
            sessionName: sessionName,
            projectPath: projectPath,
            resolveAnyClientTty: {
                await Self.resolveAnyTmuxClientTty(
                    targetSession: sessionName,
                    runScript: { await Self.runBashScriptWithResult($0) },
                )
            },
            ensureAndSwitch: { session, path, tty in
                await Self.ensureSessionAndSwitch(
                    sessionName: session,
                    projectPath: path,
                    clientTty: tty,
                    runScript: { await Self.runBashScriptWithResult($0) },
                )
            },
            launchTerminalWithTmux: { [weak self] session, path in
                self?.launchTerminalWithTmuxSession(session, projectPath: path)
            },
            activateTerminal: { [weak self] tty, path, sessionHint in
                guard let self else { return false }
                return await activateTerminalAfterTmuxSwitch(
                    clientTty: tty,
                    projectPath: path,
                    tmuxSessionHint: sessionHint,
                )
            },
            pollForNewClient: {
                // Poll for newly attached tmux client after launch.
                // Window: 20 × 500ms = 10 seconds (Ghostty + shell init + tmux attach).
                for attempt in 0 ..< 20 {
                    guard !_Concurrency.Task.isCancelled else {
                        debugLog("pollForNewClient cancelled at attempt=\(attempt)")
                        return nil
                    }
                    do {
                        try await _Concurrency.Task.sleep(nanoseconds: 500_000_000)
                    } catch {
                        debugLog("pollForNewClient cancelled during sleep at attempt=\(attempt)")
                        return nil
                    }
                    let result = await Self.runBashScriptWithResult("tmux list-clients -F '#{client_tty}' 2>/dev/null")
                    if result.exitCode == 0,
                       let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !output.isEmpty
                    {
                        let tty = output.split(separator: "\n").first.map(String.init)
                        debugLog("pollForNewClient found tty=\(tty ?? "nil") attempt=\(attempt)")
                        return tty
                    }
                }
                debugLog("pollForNewClient timed out after 10s")
                return nil
            },
        )
    }

    private func shouldProcessLaunchRequest(_ requestID: UInt64) -> Bool {
        requestID == latestLaunchRequestID && !_Concurrency.Task.isCancelled
    }

    static func resolveAnyTmuxClientTty(
        targetSession: String? = nil,
        runScript: (String) async -> (exitCode: Int32, output: String?),
    ) async -> String? {
        let result = await runScript("tmux display-message -p '#{client_tty}' 2>/dev/null")
        if result.exitCode == 0,
           let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty
        {
            return output
        }

        // App-triggered activation usually runs outside a tmux client, so
        // `display-message` cannot resolve #{client_tty}. Fall back to
        // attached clients. When targetSession is set, prefer a client
        // already viewing that session (avoids switch-client and the
        // associated AX title propagation race).
        let clients = await runScript("tmux list-clients -F '#{client_tty} #{session_name}' 2>/dev/null")
        guard clients.exitCode == 0,
              let output = clients.output
        else {
            return nil
        }

        // First pass: find a client already on the target session.
        var firstTty: String?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Format: "<tty> <session_name>" — split on first space.
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            let tty = String(parts[0])
            let session = parts.count > 1 ? String(parts[1]) : nil

            if firstTty == nil {
                firstTty = tty
            }

            if let targetSession, let session, session == targetSession {
                return tty
            }
        }

        // Second pass (fallback): return first non-empty TTY.
        return firstTty
    }

    // MARK: - Tmux Helpers

    private func launchTerminalWithTmuxSession(_ session: String, projectPath: String? = nil) {
        let app = activator.appName
        logger.debug("Launching \(app) with tmux session '\(session)' at path '\(projectPath ?? "default")'")
        debugLog("launchTerminalWithTmuxSession app=\(app) session=\(session) path=\(projectPath ?? "default")")
        let escapedSession = shellEscape(session)
        let tmuxCmd: String
        if let path = projectPath {
            let escapedPath = shellEscape(path)
            tmuxCmd = "tmux new-session -A -s \(escapedSession) -c \(escapedPath)"
        } else {
            tmuxCmd = "tmux new-session -A -s \(escapedSession)"
        }

        let isRunning = TerminalActivation.isRunning(bundleId: activator.bundleId)

        if isRunning {
            // Terminal is running: open -a sends an Apple Event to the existing
            // instance, which opens a new tab at the given directory.
            debugLog("launchTerminalWithTmuxSession \(app) running, open -a new tab")
            if let path = projectPath {
                runBashScript("open -a \(app).app \(shellEscape(path))")
            } else {
                runBashScript("open -a \(app).app")
            }
        } else {
            // Terminal not running — launch it.
            debugLog("launchTerminalWithTmuxSession \(app) not running, launching")
            runBashScript("open -a \(app).app")
        }

        // Wait for the tab/window shell to initialize, then type the tmux command.
        // Cold start needs a longer delay for the app to fully initialize.
        let delay = isRunning ? 1.0 : 2.5
        let applescriptSafe = tmuxCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        osascript <<'APPLESCRIPT'
        delay \(delay)
        tell application "System Events"
            tell process "\(app)"
                keystroke "\(applescriptSafe)"
                delay 0.05
                keystroke return
            end tell
        end tell
        APPLESCRIPT
        """
        runBashScript(script)
    }

    private func findTmuxSessionForPath(_ projectPath: String) async -> String? {
        let result = await runBashScriptWithResultAsync("tmux list-windows -a -F '#{session_name}\t#{pane_current_path}' 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return nil }

        return Self.bestTmuxSessionForPath(
            output: output,
            projectPath: projectPath,
            homeDirectory: NSHomeDirectory(),
        )
    }

    nonisolated static func bestTmuxSessionForPath(output: String, projectPath: String, homeDirectory: String) -> String? {
        func normalizePath(_ path: String) -> String {
            if path == "/" { return "/" }
            var normalized = path
            while normalized.hasSuffix("/"), normalized != "/" {
                normalized.removeLast()
            }
            return normalized.lowercased()
        }

        func managedWorktreeRoot(_ path: String) -> String? {
            let marker = "/.capacitor/worktrees/"
            guard let markerRange = path.range(of: marker) else { return nil }
            let worktreeNameStart = markerRange.upperBound
            guard worktreeNameStart < path.endIndex else { return nil }

            let suffix = path[worktreeNameStart...]
            guard let nextSlash = suffix.firstIndex(of: "/") else {
                return path
            }

            return String(path[..<nextSlash])
        }

        func isWithinPath(_ candidate: String, root: String) -> Bool {
            candidate == root || candidate.hasPrefix(root + "/")
        }

        func matchRank(shellPath: String, projectPath: String, homeDir: String) -> Int? {
            if shellPath == projectPath {
                return 2
            }

            let (shorter, longer) = shellPath.count < projectPath.count
                ? (shellPath, projectPath)
                : (projectPath, shellPath)

            if shorter == homeDir {
                return nil
            }

            guard longer.hasPrefix(shorter + "/") else { return nil }
            return shorter == projectPath ? 1 : 0
        }

        let normalizedProjectPath = normalizePath(projectPath)
        let homeDir = normalizePath(homeDirectory)
        let projectManagedRoot = managedWorktreeRoot(normalizedProjectPath)
        var bestMatch: (rank: Int, session: String)?

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let sessionName = String(parts[0])
            let panePath = normalizePath(String(parts[1]))
            let paneManagedRoot = managedWorktreeRoot(panePath)

            if let projectManagedRoot {
                if paneManagedRoot != projectManagedRoot || !isWithinPath(panePath, root: projectManagedRoot) {
                    continue
                }
            } else if paneManagedRoot != nil {
                continue
            }

            guard let rank = matchRank(
                shellPath: panePath,
                projectPath: normalizedProjectPath,
                homeDir: homeDir,
            ) else { continue }

            if bestMatch == nil || rank > bestMatch!.rank {
                bestMatch = (rank, sessionName)
                if rank == 2 {
                    break
                }
            }
        }
        return bestMatch?.session
    }

    // MARK: - Terminal Focus After Tmux Switch

    private func activateTerminalAfterTmuxSwitch(
        clientTty: String?,
        projectPath: String,
        tmuxSessionHint: String?,
    ) async -> Bool {
        // Try per-terminal tab focus via the activator protocol
        if TerminalActivation.isRunning(bundleId: activator.bundleId) {
            let focused = await activator.focusSession(
                sessionName: tmuxSessionHint ?? "",
                projectPath: projectPath,
                tty: clientTty,
            )
            if focused { return true }
        }
        // Last resort: generic app activation (may show wrong tab)
        TerminalActivation.activateApp(bundleId: activator.bundleId)
        return false
    }

    // MARK: - Script Execution

    private func runBashScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Constants.homebrewPaths + ":" + (env["PATH"] ?? "")
        process.environment = env

        try? process.run()
    }

    private func runBashScriptWithResultAsync(_ script: String) async -> (exitCode: Int32, output: String?) {
        await Self.runBashScriptWithResult(script)
    }

    static func runBashScriptWithResult(_ script: String) async -> (exitCode: Int32, output: String?) {
        await withCheckedContinuation { continuation in
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

                var outputData = Data()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    outputData.append(data)
                }

                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let trailingData = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !trailingData.isEmpty {
                        outputData.append(trailingData)
                    }
                    let output = String(data: outputData, encoding: .utf8)
                    continuation.resume(returning: (process.terminationStatus, output))
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, nil))
                }
            }
        }
    }
}

// MARK: - Terminal Launch Scripts

enum TerminalScripts {
    static func launchWithCommand(projectPath: String, command: String, terminalApp: String) -> String {
        let escapedPath = bashDoubleQuoteEscape(projectPath)
        let escapedCommand = bashDoubleQuoteEscape(command)

        return """
        PROJECT_PATH="\(escapedPath)"
        CLAUDE_CMD="\(escapedCommand)"
        APP_NAME="\(terminalApp)"

        # Check standard and Utilities locations
        if [ -d "/Applications/${APP_NAME}.app" ]; then
            APP_PATH="/Applications/${APP_NAME}.app"
        elif [ -d "/Applications/Utilities/${APP_NAME}.app" ]; then
            APP_PATH="/Applications/Utilities/${APP_NAME}.app"
        else
            echo "${APP_NAME} not found in /Applications" >&2
            exit 1
        fi

        open -a "$APP_PATH" --args --working-directory="$PROJECT_PATH" -e bash -c "$CLAUDE_CMD"
        """
    }
}
