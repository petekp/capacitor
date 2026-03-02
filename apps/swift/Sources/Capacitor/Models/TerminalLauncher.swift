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

protocol AppleScriptClient {
    func run(_ script: String)
    func runChecked(_ script: String) -> Bool
}

private struct DefaultAppleScriptClient: AppleScriptClient {
    func run(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    func runChecked(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown"
                logger.warning("AppleScript failed (exit \(process.terminationStatus)): \(errorMsg)")
                debugLog("runAppleScriptChecked failed exit=\(process.terminationStatus) error=\(errorMsg)")
                return false
            }
            return true
        } catch {
            logger.error("AppleScript launch failed: \(error.localizedDescription)")
            debugLog("runAppleScriptChecked failed error=\(error.localizedDescription)")
            return false
        }
    }
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

    private let appleScript: AppleScriptClient
    private let ghosttyWindowReader: GhosttyWindowReader
    private let fallbackTmuxSessionResolver: ((String) async -> String?)?
    /// Override for the unified activation flow. Tests use this to intercept card-click behavior.
    private let activateProjectSessionOverride: ((String, String) async -> Bool)?
    var onActivationResult: ((TerminalActivationResult) -> Void)?

    private var latestLaunchRequestID: UInt64 = 0
    private var launchTask: _Concurrency.Task<Void, Never>?

    // MARK: - Public API

    init(
        appleScript: AppleScriptClient = DefaultAppleScriptClient(),
        ghosttyWindowReader: GhosttyWindowReader? = nil,
        fallbackTmuxSessionResolver: ((String) async -> String?)? = nil,
        activateProjectSessionOverride: ((String, String) async -> Bool)? = nil,
    ) {
        self.appleScript = appleScript
        self.ghosttyWindowReader = ghosttyWindowReader ?? DefaultGhosttyAXReader()
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
                    runScript: { await Self.runBashScriptWithResult($0) },
                )
            },
            hasExistingSession: { name in
                await Self.hasTmuxSession(
                    name: name,
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
            attachToExistingSession: { [weak self] session in
                self?.attachToExistingTmuxSession(session)
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
        // `display-message` cannot resolve #{client_tty}. Fall back to any
        // attached client to make switch-client deterministic.
        let clients = await runScript("tmux list-clients -F '#{client_tty}' 2>/dev/null")
        guard clients.exitCode == 0,
              let output = clients.output
        else {
            return nil
        }

        for line in output.split(separator: "\n") {
            let tty = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tty.isEmpty {
                return tty
            }
        }

        return nil
    }

    // MARK: - Ghostty AX Routing

    private func activateGhosttyWithAXRouting(
        forTty tty: String?,
        projectPath: String?,
        tmuxSessionHint: String? = nil,
    ) async -> Bool {
        let resolvedTty = (tty?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

        guard isGhosttyRunningInternal() else {
            logger.info("    activateGhosttyWithAXRouting: Ghostty not running")
            debugLog("activateGhosttyWithAXRouting ghostty not running tty=\(resolvedTty ?? "<none>")")
            return false
        }

        // Retry-based title matching. Polls AX windows up to 5 times (200ms apart)
        // waiting for the tab title to propagate after tmux switch-client.
        let maxRetries = 5
        let retryDelayNanoseconds: UInt64 = 200_000_000 // 200ms

        for attempt in 0 ..< maxRetries {
            switch ghosttyWindowReader.readWindows() {
            case .unavailable:
                // Intentional fail-open behavior: when AX cannot be read (permissions/TCC/transient AX errors),
                // fall back to generic app activation so users can still reach Ghostty.
                logger.info("    activateGhosttyWithAXRouting: AX unavailable, falling back to generic activation")
                debugLog("activateGhosttyWithAXRouting ax unavailable tty=\(resolvedTty ?? "<none>") path=\(projectPath ?? "<nil>")")
                return activateAppByName("Ghostty")
            case let .windows(windows):
                if windows.isEmpty {
                    if attempt < maxRetries - 1 {
                        do {
                            try await _Concurrency.Task.sleep(nanoseconds: retryDelayNanoseconds)
                        } catch {
                            return false
                        }
                        continue
                    }
                    logger.info("    activateGhosttyWithAXRouting: no windows → returning false")
                    debugLog("activateGhosttyWithAXRouting windowCount=0 -> return false")
                    return false
                }

                let matchedTab = projectPath.flatMap {
                    bestGhosttyTabMatch(
                        windows: windows,
                        projectPath: $0,
                        tmuxSessionHint: tmuxSessionHint,
                    )
                }

                // If we found a tab match, or we don't have a project path,
                // or we are on the last attempt, we proceed to resolve routing.
                if matchedTab != nil || projectPath == nil || attempt == maxRetries - 1 {
                    let tabCount = windows.reduce(into: 0) { partialResult, window in
                        partialResult += window.tabs.count
                    }
                    let allTabTitles = windows.flatMap { w in
                        w.tabs.map { t in "w\(w.index)t\(t.index)=\(t.title ?? "<nil>")" }
                    }.joined(separator: ", ")
                    let allWindowTitles = windows.map { w in "w\(w.index)=\(w.title ?? "<nil>")" }.joined(separator: ", ")
                    logger.info("    activateGhosttyWithAXRouting: tty=\(resolvedTty ?? "<none>"), windowCount=\(windows.count), tabCount=\(tabCount)")
                    debugLog(
                        "activateGhosttyWithAXRouting tty=\(resolvedTty ?? "<none>") windowCount=\(windows.count) tabCount=\(tabCount) path=\(projectPath ?? "<nil>") sessionHint=\(tmuxSessionHint ?? "<none>") matchedTabIndex=\(matchedTab?.tab.index.description ?? "<none>") matchedTabTitle=\(matchedTab?.tab.title ?? "<none>") tabs=[\(allTabTitles)] windowTitles=[\(allWindowTitles)]",
                    )

                    if let route = Self.resolveGhosttyAXRouting(
                        windows: windows,
                        projectPath: projectPath,
                        tmuxSessionHint: tmuxSessionHint,
                        ghosttyWindowReader: ghosttyWindowReader,
                    ) {
                        logger.info("    activateGhosttyWithAXRouting: resolved route=\(route.rawValue)")
                        debugLog("activateGhosttyWithAXRouting route=\(route.rawValue)")
                        return true
                    }

                    logger.info("    activateGhosttyWithAXRouting: no deterministic tab/window route → generic activation")
                    debugLog("activateGhosttyWithAXRouting route=app_activate_fallback")
                    return activateAppByName("Ghostty")
                }

                // We have a projectPath, but didn't find a matching tab, and we have retries left.
                // Wait for the tab to appear or update its title.
                do {
                    try await _Concurrency.Task.sleep(nanoseconds: retryDelayNanoseconds)
                } catch {
                    return false
                }
            }
        }

        return false
    }

    enum GhosttyAXRoutingResolution: String, Equatable {
        case tabPress = "tab_press"
        case windowRaise = "window_raise"
    }

    static func resolveGhosttyAXRouting(
        windows: [GhosttyWindowSnapshot],
        projectPath: String?,
        tmuxSessionHint: String? = nil,
        ghosttyWindowReader: GhosttyWindowReader,
    ) -> GhosttyAXRoutingResolution? {
        if let projectPath,
           let tabMatch = bestGhosttyTabMatch(
               windows: windows,
               projectPath: projectPath,
               tmuxSessionHint: tmuxSessionHint,
           )
        {
            if ghosttyWindowReader.focusTab(tabMatch.tab, in: tabMatch.window.element) {
                return .tabPress
            }

            if ghosttyWindowReader.raiseWindow(tabMatch.window.element) {
                return .windowRaise
            }
        }

        if let fallbackWindow = bestGhosttyWindowForRaise(windows: windows),
           ghosttyWindowReader.raiseWindow(fallbackWindow.element)
        {
            return .windowRaise
        }

        return nil
    }

    // MARK: - Tmux Helpers

    private func launchTerminalWithTmuxSession(_ session: String, projectPath: String? = nil) {
        logger.debug("Launching terminal with tmux session '\(session)' at path '\(projectPath ?? "default")'")
        debugLog("launchTerminalWithTmuxSession session=\(session) path=\(projectPath ?? "default")")
        let escapedSession = shellEscape(session)
        let tmuxCmd: String
        if let path = projectPath {
            let escapedPath = shellEscape(path)
            tmuxCmd = "tmux new-session -A -s \(escapedSession) -c \(escapedPath)"
        } else {
            tmuxCmd = "tmux new-session -A -s \(escapedSession)"
        }

        if isGhosttyRunningInternal() {
            // Ghostty is running: open -a sends an Apple Event to the existing
            // instance, which opens a new tab at the given directory. No -n flag
            // means no new process and no extra dock icon.
            debugLog("launchTerminalWithTmuxSession ghosttyRunning=true, open -a new tab")
            if let path = projectPath {
                runBashScript("open -a Ghostty.app \(shellEscape(path))")
            } else {
                runBashScript("open -a Ghostty.app")
            }
            // Wait for the new tab's shell to initialize, then type the tmux command.
            let applescriptSafe = tmuxCmd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            osascript <<'APPLESCRIPT'
            delay 1.0
            tell application "System Events"
                tell process "Ghostty"
                    keystroke "\(applescriptSafe)"
                    key code 36
                end tell
            end tell
            APPLESCRIPT
            """
            runBashScript(script)
            return
        }

        // No Ghostty running — launch Ghostty with the tmux command directly.
        let escapedTmuxCmd = bashDoubleQuoteEscape(tmuxCmd)
        runBashScript("open -a Ghostty.app --args -e sh -c \"\(escapedTmuxCmd)\"")
    }

    // MARK: - Shell Helpers

    /// Check whether a named tmux session currently exists (attached or detached).
    /// Uses `tmux has-session` which exits 0 if the session exists, non-zero otherwise.
    static func hasTmuxSession(
        name: String,
        runScript: (String) async -> (exitCode: Int32, output: String?),
    ) async -> Bool {
        let escaped = shellEscape(name)
        let result = await runScript("tmux has-session -t \(escaped) 2>/dev/null")
        return result.exitCode == 0
    }

    /// Attach to an existing (detached) tmux session in the current Ghostty tab.
    /// Instead of opening a new tab (Cmd+T), this types `tmux attach -t <session>`
    /// into whichever tab is currently active — reusing it for the tmux session.
    /// Falls back to launching a new Ghostty window if Ghostty isn't running.
    private func attachToExistingTmuxSession(_ sessionName: String) {
        let escaped = shellEscape(sessionName)
        let tmuxCmd = "tmux attach-session -t \(escaped)"
        debugLog("attachToExistingTmuxSession session=\(sessionName)")

        if isGhosttyRunningInternal() {
            // Ghostty is running — type the attach command into the current active tab.
            // No new tab: reuse the existing idle shell.
            let applescriptSafe = tmuxCmd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            osascript <<'APPLESCRIPT'
            tell application "Ghostty" to activate
            delay 0.2
            tell application "System Events"
                tell process "Ghostty"
                    keystroke "\(applescriptSafe)"
                    key code 36
                end tell
            end tell
            APPLESCRIPT
            """
            runBashScript(script)
            return
        }

        // Ghostty not running — launch with the attach command directly.
        let escapedTmuxCmd = bashDoubleQuoteEscape(tmuxCmd)
        runBashScript("open -a Ghostty.app --args -e sh -c \"\(escapedTmuxCmd)\"")
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

    // MARK: - Ghostty Window Detection

    private func isGhosttyRunningInternal() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }
    }

    // MARK: - Terminal Focus After Tmux Switch

    private func activateTerminalAfterTmuxSwitch(
        clientTty: String?,
        projectPath: String,
        tmuxSessionHint: String?,
    ) async -> Bool {
        // Try Ghostty AX routing (tab focus via accessibility)
        if isGhosttyRunningInternal(),
           await activateGhosttyWithAXRouting(forTty: clientTty, projectPath: projectPath, tmuxSessionHint: tmuxSessionHint)
        {
            return true
        }
        // Last resort: generic Ghostty activation (may show wrong tab)
        activateAppByName("Ghostty")
        return false
    }

    // MARK: - App Activation Helpers

    @discardableResult
    private func activateAppByName(_ name: String?) -> Bool {
        guard let name,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.localizedName?.lowercased().contains(name.lowercased()) == true
              }),
              let appName = app.localizedName
        else {
            debugLog("activateAppByName failed name=\(name ?? "nil") (no running app match)")
            return false
        }
        // Use AppleScript for reliable activation - NSRunningApplication.activate()
        // can silently fail when SwiftUI windows steal focus back.
        logger.debug("Activating '\(appName)' via AppleScript")
        let result = runAppleScriptChecked("tell application \"\(appName)\" to activate")
        debugLog("activateAppByName app=\(appName) result=\(result)")
        return result
    }

    // MARK: - Script Execution

    /// Runs AppleScript and returns success/failure based on exit code.
    /// Use this for critical activation paths where failure should trigger fallback.
    @discardableResult
    private func runAppleScriptChecked(_ script: String) -> Bool {
        appleScript.runChecked(script)
    }

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
    static func launchWithCommand(projectPath: String, command: String) -> String {
        let escapedPath = bashDoubleQuoteEscape(projectPath)
        let escapedCommand = bashDoubleQuoteEscape(command)

        return """
        PROJECT_PATH="\(escapedPath)"
        CLAUDE_CMD="\(escapedCommand)"

        if [ -d "/Applications/Ghostty.app" ]; then
            open -a Ghostty.app --args --working-directory="$PROJECT_PATH" -e bash -c "$CLAUDE_CMD"
        else
            echo "Ghostty not installed at /Applications/Ghostty.app" >&2
        fi
        """
    }
}
