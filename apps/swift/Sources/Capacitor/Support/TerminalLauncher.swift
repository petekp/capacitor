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
    func runBoolean(_ script: String) -> Bool?
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

    func runBoolean(_ script: String) -> Bool? {
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
                logger.warning("AppleScript boolean eval failed (exit \(process.terminationStatus)): \(errorMsg)")
                debugLog("runAppleScriptBoolean failed exit=\(process.terminationStatus) error=\(errorMsg)")
                return nil
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            switch output {
            case "true":
                return true
            case "false":
                return false
            default:
                debugLog("runAppleScriptBoolean unexpectedOutput=\(output ?? "<nil>")")
                return nil
            }
        } catch {
            logger.error("AppleScript boolean eval launch failed: \(error.localizedDescription)")
            debugLog("runAppleScriptBoolean failed error=\(error.localizedDescription)")
            return nil
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
    enum SupportedTerminalApp: CaseIterable, Equatable {
        case ghostty
        case iTerm
        case terminal

        var processName: String {
            switch self {
            case .ghostty: "Ghostty"
            case .iTerm: "iTerm2"
            case .terminal: "Terminal"
            }
        }

        var bundleId: String {
            switch self {
            case .ghostty: "com.mitchellh.ghostty"
            case .iTerm: "com.googlecode.iterm2"
            case .terminal: "com.apple.Terminal"
            }
        }

        static func from(parentApp: String?) -> SupportedTerminalApp? {
            guard let normalized = parentApp?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !normalized.isEmpty
            else {
                return nil
            }

            switch normalized {
            case "ghostty":
                return .ghostty
            case "iterm", "iterm2":
                return .iTerm
            case "terminal", "terminal.app":
                return .terminal
            default:
                return nil
            }
        }

        static func detectAvailable() -> SupportedTerminalApp {
            let runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
                SupportedTerminalApp.allCases.first(where: { $0.bundleId == app.bundleIdentifier })
            }
            if let running = runningApps.first {
                return running
            }
            if FileManager.default.fileExists(atPath: "/Applications/Ghostty.app") {
                return .ghostty
            }
            if FileManager.default.fileExists(atPath: "/Applications/iTerm.app") {
                return .iTerm
            }
            return .terminal
        }
    }

    private enum Constants {
        static let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
    }

    private let appleScript: AppleScriptClient
    private let ghosttyWindowReader: GhosttyWindowReader
    var preferredTerminalAppResolver: ((String?, String, String?) -> SupportedTerminalApp?)?
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

    func launchTerminal(for project: some ShellProjectReferenceProviding) {
        let projectReference = project.shellProjectReference
        latestLaunchRequestID &+= 1
        let requestID = latestLaunchRequestID
        launchTask?.cancel()
        launchTask = _Concurrency.Task { [weak self] in
            await self?.launchTerminalAsync(for: projectReference, requestID: requestID)
        }
    }

    private func launchTerminalAsync(for project: ShellProjectReference, requestID: UInt64) async {
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
            "project": project.displayName,
            "path": project.path,
            "session": sessionName,
            "success": success,
        ])
        onActivationResult?(TerminalActivationResult(
            projectName: project.displayName,
            projectPath: project.path,
            success: success,
            usedFallback: false,
        ))
    }

    /// Resolve a tmux session name for a project.
    /// Prefers an existing tmux session matching the project path; falls back to project slug.
    private func resolveSessionName(for project: ShellProjectReference) async -> String {
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
                return activateApp(.ghostty)
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

                let tabCount = windows.reduce(into: 0) { partialResult, window in
                    partialResult += window.tabs.count
                }

                // Proceed immediately if we matched a tab, have no project path,
                // have zero tabs (stale TTY — retrying won't help), or exhausted retries.
                if matchedTab != nil || projectPath == nil || tabCount == 0 || attempt == maxRetries - 1 {
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
                        debugLog("activateGhosttyWithAXRouting route=\(route.rawValue) matchedTab=\(matchedTab?.tab.title ?? "<none>")")

                        // If routing only achieved window_raise without matching any tab,
                        // the client TTY is likely stale (terminal tab closed but tmux
                        // client lingers). Return false so the caller falls through to
                        // launching a new tab instead of silently doing nothing.
                        if route == .windowRaise, matchedTab == nil {
                            logger.info("    activateGhosttyWithAXRouting: window_raise with no tab match → stale TTY")
                            debugLog("activateGhosttyWithAXRouting stale: window_raise but no matchedTab, returning false")
                            return false
                        }

                        return true
                    }

                    logger.info("    activateGhosttyWithAXRouting: no deterministic tab/window route → generic activation")
                    debugLog("activateGhosttyWithAXRouting route=app_activate_fallback")
                    return activateApp(.ghostty)
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
        let app = preferredTerminalApp(
            clientTty: nil,
            projectPath: projectPath ?? "",
            sessionName: session,
        )
        logger.debug("Launching \(app.processName) with tmux session '\(session)' at path '\(projectPath ?? "default")'")
        debugLog("launchTerminalWithTmuxSession app=\(app.processName) session=\(session) path=\(projectPath ?? "default")")
        let escapedSession = shellEscape(session)
        let tmuxCmd: String
        if let path = projectPath {
            let escapedPath = shellEscape(path)
            tmuxCmd = "tmux new-session -A -s \(escapedSession) -c \(escapedPath)"
        } else {
            tmuxCmd = "tmux new-session -A -s \(escapedSession)"
        }

        if app == .ghostty, isTerminalRunning(.ghostty) {
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
                    delay 0.05
                    keystroke return
                end tell
            end tell
            APPLESCRIPT
            """
            runBashScript(script)
            return
        }

        if app == .ghostty {
            // No Ghostty running — launch Ghostty with the tmux command directly.
            let escapedTmuxCmd = bashDoubleQuoteEscape(tmuxCmd)
            runBashScript("open -a Ghostty.app --args -e sh -c \"\(escapedTmuxCmd)\"")
            return
        }

        let isRunning = isTerminalRunning(app)
        if let path = projectPath {
            runBashScript("open -b \(app.bundleId) \(shellEscape(path))")
        } else {
            runBashScript("open -b \(app.bundleId)")
        }

        let delay = isRunning ? 1.0 : 2.5
        let applescriptSafe = tmuxCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        osascript <<'APPLESCRIPT'
        delay \(delay)
        tell application "System Events"
            tell process "\(app.processName)"
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

    static func resolvePreferredTerminalApp(
        clientTty: String?,
        projectPath: String,
        sessionName: String?,
        shellState: ShellCwdState,
    ) -> SupportedTerminalApp? {
        let normalizedProjectPath = PathNormalizer.normalize(projectPath)
        let normalizedClientTty: String? = {
            guard let value = clientTty?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return nil
            }
            return value
        }()
        let normalizedSessionName: String? = {
            guard let value = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return nil
            }
            return value
        }()

        var bestMatch: (rank: Int, updatedAt: Date, app: SupportedTerminalApp)?

        for entry in shellState.shells.values {
            guard let app = SupportedTerminalApp.from(parentApp: entry.parentApp) else {
                continue
            }

            let rank: Int? = if let normalizedClientTty, entry.tmuxClientTty == normalizedClientTty {
                4
            } else if let normalizedClientTty, entry.tty == normalizedClientTty {
                3
            } else if let normalizedSessionName, entry.tmuxSession == normalizedSessionName {
                2
            } else if PathNormalizer.normalize(entry.cwd) == normalizedProjectPath {
                1
            } else {
                nil
            }

            guard let rank else { continue }

            if let currentBest = bestMatch {
                if rank < currentBest.rank {
                    continue
                }
                if rank == currentBest.rank, entry.updatedAt <= currentBest.updatedAt {
                    continue
                }
            }

            bestMatch = (rank, entry.updatedAt, app)
        }

        return bestMatch?.app
    }

    // MARK: - Ghostty Window Detection

    private func isGhosttyRunningInternal() -> Bool {
        isTerminalRunning(.ghostty)
    }

    // MARK: - Terminal Focus After Tmux Switch

    private func activateTerminalAfterTmuxSwitch(
        clientTty: String?,
        projectPath: String,
        tmuxSessionHint: String?,
    ) async -> Bool {
        let app = preferredTerminalApp(
            clientTty: clientTty,
            projectPath: projectPath,
            sessionName: tmuxSessionHint,
        )

        switch app {
        case .ghostty:
            if isTerminalRunning(.ghostty),
               await activateGhosttyWithAXRouting(forTty: clientTty, projectPath: projectPath, tmuxSessionHint: tmuxSessionHint)
            {
                return true
            }
        case .iTerm, .terminal:
            if let clientTty, focusTerminalTabByTty(clientTty, app: app) {
                return true
            }
        }

        // Last resort: generic app activation (may show wrong tab and still trigger relaunch).
        activateApp(app)
        return false
    }

    // MARK: - App Activation Helpers

    @discardableResult
    private func activateApp(_ app: SupportedTerminalApp) -> Bool {
        // Use AppleScript for reliable activation - NSRunningApplication.activate()
        // can silently fail when SwiftUI windows steal focus back.
        logger.debug("Activating '\(app.processName)' via AppleScript")
        let result = runAppleScriptChecked("tell application \"\(app.processName)\" to activate")
        debugLog("activateApp app=\(app.processName) result=\(result)")
        return result
    }

    private func preferredTerminalApp(
        clientTty: String?,
        projectPath: String,
        sessionName: String?,
    ) -> SupportedTerminalApp {
        preferredTerminalAppResolver?(clientTty, projectPath, sessionName) ?? SupportedTerminalApp.detectAvailable()
    }

    private func isTerminalRunning(_ app: SupportedTerminalApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app.bundleId
        }
    }

    private func focusTerminalTabByTty(_ tty: String, app: SupportedTerminalApp) -> Bool {
        guard isTerminalRunning(app) else {
            debugLog("focusTerminalTabByTty app=\(app.processName) not running tty=\(tty)")
            return false
        }

        let escapedTty = tty
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        switch app {
        case .ghostty:
            return false
        case .iTerm:
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(escapedTty)" then
                                select t
                                set index of w to 1
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        case .terminal:
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(escapedTty)" then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        }

        let matched = runAppleScriptBoolean(script) == true
        debugLog("focusTerminalTabByTty app=\(app.processName) tty=\(tty) matched=\(matched)")
        return matched
    }

    // MARK: - Script Execution

    /// Runs AppleScript and returns success/failure based on exit code.
    /// Use this for critical activation paths where failure should trigger fallback.
    @discardableResult
    private func runAppleScriptChecked(_ script: String) -> Bool {
        appleScript.runChecked(script)
    }

    private func runAppleScriptBoolean(_ script: String) -> Bool? {
        appleScript.runBoolean(script)
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

                    let outputURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("capacitor-terminal-\(UUID().uuidString)")
                    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                    let outputHandle = try? FileHandle(forWritingTo: outputURL)
                    process.standardOutput = outputHandle ?? FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice

                    processHolder.set(process)

                    let timeoutWork = DispatchWorkItem {
                        processHolder.terminateIfRunning()
                    }

                    process.terminationHandler = { process in
                        timeoutWork.cancel()
                        try? outputHandle?.close()
                        let output = (try? Data(contentsOf: outputURL)).flatMap { String(data: $0, encoding: .utf8) }
                        try? FileManager.default.removeItem(at: outputURL)
                        continuationBox.resume((process.terminationStatus, output))
                    }

                    do {
                        try process.run()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutWork)
                    } catch {
                        timeoutWork.cancel()
                        try? outputHandle?.close()
                        try? FileManager.default.removeItem(at: outputURL)
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
        preferredApp: TerminalLauncher.SupportedTerminalApp? = nil,
    ) -> String {
        let app = preferredApp ?? TerminalLauncher.SupportedTerminalApp.detectAvailable()
        let escapedPath = bashDoubleQuoteEscape(projectPath)
        let escapedCommand = bashDoubleQuoteEscape(command)

        if app == .ghostty {
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

        let delay = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app.bundleId
        } ? "1.0" : "2.5"

        return """
        PROJECT_PATH="\(escapedPath)"
        CLAUDE_CMD="\(escapedCommand)"

        open -b \(app.bundleId) "$PROJECT_PATH"

        osascript <<'APPLESCRIPT'
        delay \(delay)
        tell application "System Events"
            tell process "\(app.processName)"
                keystroke "\(escapedCommand)"
                delay 0.05
                keystroke return
            end tell
        end tell
        APPLESCRIPT
        """
    }
}
