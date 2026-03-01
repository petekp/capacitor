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

enum GhosttyWindowState: Equatable {
    case notRunning
    case axUnavailable
    case running
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

// MARK: - ParentApp Terminal Extensions

extension ParentApp {
    static let alphaSupportedTerminals: [ParentApp] = [
        .ghostty, .iTerm, .terminal,
    ]

    var isAlphaSupportedTerminal: Bool {
        Self.alphaSupportedTerminals.contains(self)
    }

    var bundlePath: String? {
        switch self {
        case .ghostty: "/Applications/Ghostty.app"
        case .iTerm: "/Applications/iTerm.app"
        case .alacritty: "/Applications/Alacritty.app"
        case .warp: "/Applications/Warp.app"
        case .terminal: "/System/Applications/Utilities/Terminal.app"
        case .kitty: nil
        default: nil
        }
    }

    var isInstalled: Bool {
        guard category == .terminal, isAlphaSupportedTerminal else { return false }
        if self == .terminal {
            let candidates = [
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Utilities/Terminal.app",
            ]
            return candidates.contains { FileManager.default.fileExists(atPath: $0) }
        }
        guard let path = bundlePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    static let terminalPriorityOrder: [ParentApp] = [
        .ghostty, .iTerm, .terminal,
    ]

    var runningAppMatchNames: [String] {
        switch self {
        case .terminal: ["Terminal", "Terminal.app"]
        case .iTerm: ["iTerm", "iTerm2", "iTerm.app"]
        case .ghostty: ["Ghostty"]
        case .alacritty: ["Alacritty"]
        case .kitty: ["kitty"]
        case .warp: ["Warp", "WarpTerminal"]
        default: [displayName]
        }
    }

    func matchesRunningAppName(_ localizedName: String) -> Bool {
        let lower = localizedName.lowercased()
        return runningAppMatchNames.contains { lower == $0.lowercased() }
    }

    var processName: String? {
        switch self {
        case .cursor: "Cursor"
        case .vsCode: "Code"
        case .vsCodeInsiders: "Code - Insiders"
        case .zed: "Zed"
        default: nil
        }
    }

    var cliBinary: String? {
        switch self {
        case .cursor: "cursor"
        case .vsCode: "code"
        case .vsCodeInsiders: "code-insiders"
        case .zed: "zed"
        default: nil
        }
    }
}

// MARK: - TerminalType Display Name Extension

extension TerminalType {
    var appName: String {
        switch self {
        case .iTerm: "iTerm"
        case .terminalApp: "Terminal"
        case .ghostty: "Ghostty"
        case .alacritty: "Alacritty"
        case .kitty: "kitty"
        case .warp: "Warp"
        case .unknown: ""
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
// ACTIVATION PRIORITY (ordered by user intent signal strength):
//
//   1. Active shell in Rust resolver input snapshot → User has a terminal window open RIGHT NOW
//      These are verified-live PIDs from recent shell hook activity.
//
//   2. Tmux session at project path → User has a session but may not be attached
//      Queried directly from tmux, may exist even without recent shell activity.
//
//   3. Launch new terminal → No existing terminal for this project
//
// WHY THIS ORDER MATTERS:
// Previously, tmux was checked first. This caused a bug: if a user had a Ghostty
// window open (non-tmux) AND a tmux session existed at the same path, clicking
// the project would open a NEW window in tmux instead of focusing the existing
// Ghostty window. The runtime shell snapshot finds the actively-used terminal.

@MainActor
final class TerminalLauncher {
    enum ResolverError: Error {
        case engineUnavailable
    }

    private enum Constants {
        static let activationDelaySeconds: Double = 0.3
        static let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
    }

    private let appleScript: AppleScriptClient
    private let ghosttyWindowReader: GhosttyWindowReader
    private let resolveActivationDecisionOverride: ((Project) async throws -> ActivationDecision)?
    private let fallbackTmuxSessionResolver: ((String) async -> String?)?
    private let launchNewTerminalOverride: ((String, String) -> Bool)?
    /// Override for the unified activation flow. Tests use this to intercept card-click behavior.
    private let activateProjectSessionOverride: ((String, String) async -> Bool)?
    private let hudEngine: CoreRuntime?
    var onActivationTrace: ((String) -> Void)?
    var onActivationResult: ((TerminalActivationResult) -> Void)?

    private static let activationTraceEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["CAPACITOR_ACTIVATION_TRACE"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
    }()

    private var latestLaunchRequestID: UInt64 = 0
    private var launchTask: _Concurrency.Task<Void, Never>?

    /// The TTY of the tmux client Capacitor is managing. Persists across card clicks.
    /// Cleared when the TTY becomes stale (tab closed). See spec invariant B6.
    private(set) var managedClientTty: String?

    // MARK: - Public API

    init(
        appleScript: AppleScriptClient = DefaultAppleScriptClient(),
        ghosttyWindowReader: GhosttyWindowReader? = nil,
        resolveActivationDecisionOverride: ((Project) async throws -> ActivationDecision)? = nil,
        fallbackTmuxSessionResolver: ((String) async -> String?)? = nil,
        launchNewTerminalOverride: ((String, String) -> Bool)? = nil,
        activateProjectSessionOverride: ((String, String) async -> Bool)? = nil,
        hudEngineFactory: () throws -> CoreRuntime = { try CoreRuntime() },
    ) {
        self.appleScript = appleScript
        self.ghosttyWindowReader = ghosttyWindowReader ?? DefaultGhosttyAXReader()
        self.resolveActivationDecisionOverride = resolveActivationDecisionOverride
        self.fallbackTmuxSessionResolver = fallbackTmuxSessionResolver
        self.launchNewTerminalOverride = launchNewTerminalOverride
        self.activateProjectSessionOverride = activateProjectSessionOverride
        hudEngine = try? hudEngineFactory()
    }

    // MARK: - Unified Activation Primitives (spec v2)

    /// Check if a TTY device is still alive (file exists at /dev path).
    static func isTtyAlive(_ tty: String) -> Bool {
        FileManager.default.fileExists(atPath: tty)
    }

    /// Resolve which tmux client TTY to use for session switching.
    /// Spec decision tree step 1: managed (alive) → any client → nil (must launch).
    static func resolveTmuxClient(
        managedTty: String?,
        isTtyAlive: (String) -> Bool,
        resolveAnyClientTty: () async -> String?,
    ) async -> String? {
        if let managedTty, isTtyAlive(managedTty) {
            return managedTty
        }
        return await resolveAnyClientTty()
    }

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

    /// Unified activation flow per spec v2 decision tree.
    /// 1. Resolve client (managed → any → launch)
    /// 2. Ensure session + switch
    /// 3. Focus terminal
    static func performUnifiedActivation(
        sessionName: String,
        projectPath: String,
        managedTty: String?,
        isTtyAlive: (String) -> Bool,
        resolveAnyClientTty: () async -> String?,
        ensureAndSwitch: (String, String, String) async -> Bool,
        launchTerminalWithTmux: (String, String) -> Void,
        activateTerminal: (String?, String, String?) async -> Bool,
        pollForNewClient: (() async -> String?)? = nil,
        onManagedTtyUpdate: (String?) -> Void,
    ) async -> Bool {
        // Step 1: Resolve client.
        let clientTty = await resolveTmuxClient(
            managedTty: managedTty,
            isTtyAlive: isTtyAlive,
            resolveAnyClientTty: resolveAnyClientTty,
        )

        guard let clientTty else {
            // No client available — launch terminal with tmux (creates client).
            debugLog("performUnifiedActivation noClient, launching terminal session=\(sessionName)")
            launchTerminalWithTmux(sessionName, projectPath)
            // Capture TTY from the newly launched client.
            if let poll = pollForNewClient, let newTty = await poll() {
                onManagedTtyUpdate(newTty)
            }
            return true
        }

        // Update managed TTY if we adopted a new one.
        if clientTty != managedTty {
            debugLog("performUnifiedActivation adoptingTty=\(clientTty)")
            onManagedTtyUpdate(clientTty)
        }

        // Step 2: Ensure session exists + switch client to it.
        let switched = await ensureAndSwitch(sessionName, projectPath, clientTty)
        guard switched else {
            debugLog("performUnifiedActivation ensureAndSwitch failed session=\(sessionName)")
            return false
        }

        // Step 3: Focus terminal.
        _ = await activateTerminal(clientTty, projectPath, sessionName)
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

        // Log the Rust resolver's opinion for telemetry (but don't use its action choice).
        do {
            let decision = try await resolveActivationDecision(for: project)
            if let trace = decision.trace {
                let formatted = formatActivationTrace(trace: trace)
                for line in formatted.split(separator: "\n") {
                    debugLog(String(line))
                }
                onActivationTrace?(formatted)
            } else {
                debugLog("ActivationTrace reason=\(decision.reason)")
                onActivationTrace?(decision.reason)
            }
        } catch {
            if !(error is CancellationError) {
                debugLog("rust_resolver_trace unavailable: \(error.localizedDescription)")
            }
        }

        guard shouldProcessLaunchRequest(requestID) else {
            debugLog("launchTerminalAsync ignored stale request id=\(requestID) path=\(project.path)")
            return
        }

        // Run unified activation flow (spec v2).
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
            managedTty: managedClientTty,
            isTtyAlive: Self.isTtyAlive,
            resolveAnyClientTty: {
                await Self.resolveAnyTmuxClientTty(
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
                // Poll for newly attached tmux client after launch
                for _ in 0 ..< 10 {
                    try? await _Concurrency.Task.sleep(nanoseconds: 200_000_000) // 200ms
                    let result = await Self.runBashScriptWithResult("tmux list-clients -F '#{client_tty}' 2>/dev/null")
                    if result.exitCode == 0,
                       let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !output.isEmpty
                    {
                        return output.split(separator: "\n").first.map(String.init)
                    }
                }
                return nil
            },
            onManagedTtyUpdate: { [weak self] tty in
                self?.managedClientTty = tty
            },
        )
    }

    private func shouldProcessLaunchRequest(_ requestID: UInt64) -> Bool {
        requestID == latestLaunchRequestID && !_Concurrency.Task.isCancelled
    }

    private func resolveActivationDecision(for project: Project) async throws -> ActivationDecision {
        if let resolveActivationDecisionOverride {
            return try await resolveActivationDecisionOverride(project)
        }

        guard let hudEngine else {
            throw ResolverError.engineUnavailable
        }

        let shellState = try? await RuntimeClient.shared.fetchShellState()
        let shellStateFfi = shellState.map(Self.makeShellStateFfi)
        let tmuxContext = await makeTmuxContext(projectPath: project.path)

        return hudEngine.resolveActivationWithTrace(
            projectPath: project.path,
            shellState: shellStateFfi,
            tmuxContext: tmuxContext,
            includeTrace: true,
        )
    }

    private func makeTmuxContext(projectPath: String) async -> TmuxContextFfi {
        let sessionAtPath = await findTmuxSessionForPath(projectPath)
        let hasAttachedClient = await hasAnyClientAttachedInternal()
        return TmuxContextFfi(
            sessionAtPath: sessionAtPath,
            hasAttachedClient: hasAttachedClient,
            homeDir: NSHomeDirectory(),
        )
    }

    private static func makeShellStateFfi(_ shellState: ShellCwdState) -> ShellCwdStateFfi {
        let shells: [String: ShellEntryFfi] = shellState.shells.mapValues { entry in
            ShellEntryFfi(
                cwd: entry.cwd,
                tty: entry.tty,
                parentApp: parentAppFromShellString(entry.parentApp),
                tmuxSession: entry.tmuxSession,
                tmuxClientTty: entry.tmuxClientTty,
                updatedAt: ISO8601DateFormatter.shared.string(from: entry.updatedAt),
                isLive: false,
            )
        }

        return ShellCwdStateFfi(
            version: UInt32(shellState.version),
            shells: shells,
        )
    }

    private static func parentAppFromShellString(_ raw: String?) -> ParentApp {
        guard let raw else { return .unknown }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "ghostty":
            return .ghostty
        case "iterm2", "iterm", "iterm.app":
            return .iTerm
        case "terminal", "terminal.app":
            return .terminal
        case "alacritty":
            return .alacritty
        case "kitty":
            return .kitty
        case "warp", "warpterminal":
            return .warp
        case "cursor":
            return .cursor
        case "code", "vscode", "vs code", "visual studio code":
            return .vsCode
        case "code - insiders", "vscode-insiders", "vs code insiders":
            return .vsCodeInsiders
        case "zed":
            return .zed
        case "tmux":
            return .tmux
        default:
            return .unknown
        }
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

    private nonisolated static func focusTmuxPaneForProjectPathIfAvailable(
        sessionName: String,
        projectPath: String,
        clientTty: String?,
        runScript: (String) async -> (exitCode: Int32, output: String?),
    ) async -> Bool {
        let escapedSession = shellEscape(sessionName)
        let panesResult = await runScript(
            "tmux list-panes -t \(escapedSession) -F '#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_path}' 2>/dev/null",
        )
        guard panesResult.exitCode == 0,
              let output = panesResult.output,
              let paneTarget = bestTmuxPaneTargetForProjectPath(
                  output: output,
                  sessionName: sessionName,
                  projectPath: projectPath,
                  homeDirectory: NSHomeDirectory(),
              )
        else {
            return false
        }

        let windowTarget = "\(sessionName):\(paneTarget.windowIndex)"
        let fullPaneTarget = "\(windowTarget).\(paneTarget.paneIndex)"

        if let clientTty {
            let trimmedClientTty = clientTty.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedClientTty.isEmpty {
                let escapedClientTty = shellEscape(trimmedClientTty)
                let escapedWindowTarget = shellEscape(windowTarget)
                let switchWindowResult = await runScript(
                    "tmux switch-client -c \(escapedClientTty) -t \(escapedWindowTarget) 2>&1",
                )
                if switchWindowResult.exitCode != 0 {
                    return false
                }
            }
        }

        let escapedPaneTarget = shellEscape(fullPaneTarget)
        let selectPaneResult = await runScript("tmux select-pane -t \(escapedPaneTarget) 2>&1")
        return selectPaneResult.exitCode == 0
    }

    nonisolated static func bestTmuxPaneTargetForProjectPath(
        output: String,
        sessionName: String,
        projectPath: String,
        homeDirectory: String,
    ) -> (windowIndex: String, paneIndex: String)? {
        func normalizePath(_ path: String) -> String {
            if path == "/" { return "/" }
            var normalized = path
            while normalized.hasSuffix("/"), normalized != "/" {
                normalized.removeLast()
            }
            return normalized.lowercased()
        }

        func pathComponentCount(_ path: String) -> Int {
            path.split(separator: "/").count
        }

        func matchRankAndDistance(panePath: String, projectPath: String, homeDir: String) -> (rank: Int, distance: Int)? {
            if panePath == projectPath {
                return (2, 0)
            }

            if panePath == homeDir || projectPath == homeDir {
                return nil
            }

            if panePath.hasPrefix(projectPath + "/") {
                return (1, max(0, pathComponentCount(panePath) - pathComponentCount(projectPath)))
            }

            if projectPath.hasPrefix(panePath + "/") {
                return (0, max(0, pathComponentCount(projectPath) - pathComponentCount(panePath)))
            }

            return nil
        }

        let normalizedSession = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSession.isEmpty else { return nil }

        let normalizedProjectPath = normalizePath(projectPath)
        let normalizedHome = normalizePath(homeDirectory)
        var bestMatch: (rank: Int, distance: Int, window: Int, pane: Int, windowIndex: String, paneIndex: String)?

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }

            let lineSession = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard lineSession == normalizedSession else { continue }

            let windowIndex = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let paneIndex = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let windowInt = Int(windowIndex), let paneInt = Int(paneIndex) else { continue }

            let panePath = normalizePath(String(parts[3]))
            guard let (rank, distance) = matchRankAndDistance(
                panePath: panePath,
                projectPath: normalizedProjectPath,
                homeDir: normalizedHome,
            ) else {
                continue
            }

            let candidate = (
                rank: rank,
                distance: distance,
                window: windowInt,
                pane: paneInt,
                windowIndex: windowIndex,
                paneIndex: paneIndex,
            )

            if let best = bestMatch {
                if candidate.rank > best.rank ||
                    (candidate.rank == best.rank && candidate.distance < best.distance) ||
                    (candidate.rank == best.rank && candidate.distance == best.distance && candidate.window < best.window) ||
                    (candidate.rank == best.rank && candidate.distance == best.distance && candidate.window == best.window && candidate.pane < best.pane)
                {
                    bestMatch = candidate
                }
            } else {
                bestMatch = candidate
            }
        }

        guard let bestMatch else { return nil }
        return (bestMatch.windowIndex, bestMatch.paneIndex)
    }

    // MARK: - Action Helpers

    private func activateAppAction(appName: String) -> Bool {
        logger.info("  ▸ activateApp: \(appName)")
        let result = activateAppByName(appName)
        logger.info("  ▸ activateApp result: \(result ? "SUCCESS" : "FAILED")")
        return result
    }

    private func activateKittyWindowAction(shellPid: UInt32) -> Bool {
        logger.info("  ▸ activateKittyWindow: pid=\(shellPid)")
        debugLog("activateKittyWindow pid=\(shellPid)")
        let activated = activateAppByName("kitty")
        if activated {
            runBashScript("kitty @ focus-window --match pid:\(shellPid) 2>/dev/null")
        }
        logger.info("  ▸ activateKittyWindow result: \(activated ? "SUCCESS" : "FAILED")")
        return activated
    }

    private func launchTerminalWithTmuxAction(sessionName: String, projectPath: String) -> Bool {
        logger.info("  ▸ launchTerminalWithTmux: session=\(sessionName), path=\(projectPath)")
        debugLog("launchTerminalWithTmux session=\(sessionName) path=\(projectPath)")
        launchTerminalWithTmuxSession(sessionName, projectPath: projectPath)
        logger.info("  ▸ launchTerminalWithTmux: launched")
        return true
    }

    private func launchNewTerminalAction(projectPath: String, projectName: String) -> Bool {
        logger.info("  ▸ launchNewTerminal: path=\(projectPath), name=\(projectName)")
        debugLog("launchNewTerminal path=\(projectPath) name=\(projectName)")
        let launched = launchNewTerminal(forPath: projectPath, name: projectName)
        logger.info("  ▸ launchNewTerminal result: \(launched ? "SUCCESS" : "FAILED")")
        return launched
    }

    private func activatePriorityFallbackAction() -> Bool {
        logger.warning("  ⚠️ activatePriorityFallback: FALLBACK PATH - activating first running terminal")
        debugLog("activatePriorityFallback (activating first running terminal)")
        if ParentApp.ghostty.isInstalled {
            switch ghosttyWindowStateInternal() {
            case .notRunning:
                logger.warning("  ⚠️ activatePriorityFallback: Ghostty installed but not running; allowing fallback launch")
                debugLog("activatePriorityFallback ghostty not running -> return false")
                return false
            case .axUnavailable, .running:
                break
            }
        }
        let activated = activateFirstRunningTerminal()
        logger.warning("  ⚠️ activatePriorityFallback: completed (may have focused wrong window)")
        return activated
    }

    func activateByTtyAction(tty: String, terminalType: TerminalType, projectPath: String?) async -> Bool {
        logger.info(
            "    activateByTtyAction: tty=\(tty), terminalType=\(String(describing: terminalType)), path=\(projectPath ?? "<nil>")",
        )
        debugLog(
            "activateByTtyAction tty=\(tty) terminalType=\(String(describing: terminalType)) path=\(projectPath ?? "<nil>")",
        )

        switch terminalType {
        case .iTerm:
            return activateITermSession(tty: tty)
        case .terminalApp:
            return activateTerminalAppSession(tty: tty)
        case .ghostty:
            debugLog("activateByTtyAction ghostty AX routing tty=\(tty)")
            return await activateGhosttyWithAXRouting(forTty: tty, projectPath: projectPath)
        case .alacritty, .warp:
            return activateAppByName(terminalType.appName)
        case .kitty:
            return activateAppByName("kitty")
        case .unknown:
            logger.info("    activateByTtyAction: unknown type, attempting TTY discovery")
            debugLog("activateByTtyAction unknown terminalType; starting TTY discovery tty=\(tty)")
            if let owningTerminal = await discoverTerminalOwningTTY(tty: tty) {
                logger.info("    TTY discovery found: \(owningTerminal.displayName) for tty=\(tty)")
                debugLog("activateByTtyAction tty discovery found terminal=\(owningTerminal.displayName) tty=\(tty)")
                switch owningTerminal {
                case .iTerm:
                    return activateITermSession(tty: tty)
                case .terminal:
                    return activateTerminalAppSession(tty: tty)
                case .ghostty:
                    return await activateGhosttyWithAXRouting(forTty: tty, projectPath: projectPath)
                default:
                    return activateAppByName(owningTerminal.displayName)
                }
            }

            logger.info("    TTY discovery failed, checking if Ghostty is running")
            debugLog("activateByTtyAction tty discovery failed tty=\(tty); ghosttyRunning=\(isGhosttyRunningInternal())")
            if isGhosttyRunningInternal() {
                logger.info("    Ghostty is running, trying Ghostty AX routing as fallback")
                return await activateGhosttyWithAXRouting(forTty: tty, projectPath: projectPath)
            }

            logger.info("    No known terminal found for TTY")
            debugLog("activateByTtyAction no known terminal for tty=\(tty)")
            return false
        }
    }

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

        let maxRetries = 5
        let retryDelayNanoseconds: UInt64 = 100_000_000 // 100ms

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
                        try? await _Concurrency.Task.sleep(nanoseconds: retryDelayNanoseconds)
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
                    logger.info("    activateGhosttyWithAXRouting: tty=\(resolvedTty ?? "<none>"), windowCount=\(windows.count), tabCount=\(tabCount)")
                    debugLog(
                        "activateGhosttyWithAXRouting tty=\(resolvedTty ?? "<none>") windowCount=\(windows.count) tabCount=\(tabCount) path=\(projectPath ?? "<nil>") sessionHint=\(tmuxSessionHint ?? "<none>") matchedTabIndex=\(matchedTab?.tab.index.description ?? "<none>") matchedTabTitle=\(matchedTab?.tab.title ?? "<none>")",
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
                try? await _Concurrency.Task.sleep(nanoseconds: retryDelayNanoseconds)
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

    private func activateIdeWindowAction(ideType: IdeType, projectPath: String) async -> Bool {
        let parentApp: ParentApp = switch ideType {
        case .cursor: .cursor
        case .vsCode: .vsCode
        case .vsCodeInsiders: .vsCodeInsiders
        case .zed: .zed
        }

        guard findRunningIDE(parentApp) != nil else { return false }
        return await activateIDEWindowInternal(app: parentApp, projectPath: projectPath)
    }

    // MARK: - Adapter Helpers

    private func hasAnyClientAttachedInternal() async -> Bool {
        let result = await runBashScriptWithResultAsync("tmux list-clients 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func getCurrentClientTtyInternal() async -> String? {
        let result = await runBashScriptWithResultAsync("tmux display-message -p '#{client_tty}' 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return nil }
        let tty = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty ? nil : tty
    }

    private func switchClientInternal(to sessionName: String, clientTty: String?) async -> Bool {
        let escapedSession = shellEscape(sessionName)
        let script: String
        if let clientTty, !clientTty.isEmpty {
            let escapedClient = shellEscape(clientTty)
            script = "tmux switch-client -c \(escapedClient) -t \(escapedSession) 2>&1"
        } else {
            script = "tmux switch-client -t \(escapedSession) 2>&1"
        }

        let result = await runBashScriptWithResultAsync(script)
        if result.exitCode != 0 {
            logger.warning("tmux switch-client failed (exit \(result.exitCode)): \(result.output ?? "")")
            return false
        }
        return true
    }

    // MARK: - Tmux Helpers

    private func launchTerminalWithTmuxSession(_ session: String, projectPath: String? = nil) {
        logger.debug("Launching terminal with tmux session '\(session)' at path '\(projectPath ?? "default")'")
        debugLog("launchTerminalWithTmuxSession session=\(session) path=\(projectPath ?? "default")")
        let escapedSession = shellEscape(session)
        // Use -A flag: attach if session exists, create if it doesn't
        // Use -c to set working directory when creating new session
        let tmuxCmd: String
        if let path = projectPath {
            let escapedPath = shellEscape(path)
            tmuxCmd = "tmux new-session -A -s \(escapedSession) -c \(escapedPath)"
        } else {
            tmuxCmd = "tmux new-session -A -s \(escapedSession)"
        }

        // When Ghostty is already running, open a new tab instead of a new window.
        if isGhosttyRunningInternal() {
            debugLog("launchTerminalWithTmuxSession ghosttyRunning=true, opening new tab")
            let applescriptSafe = tmuxCmd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            osascript -e 'tell application "Ghostty" to activate'
            sleep 0.2
            osascript -e 'tell application "System Events" to tell process "Ghostty" to keystroke "t" using command down'
            sleep 0.3
            osascript -e 'tell application "System Events" to tell process "Ghostty" to keystroke "\(applescriptSafe)"'
            osascript -e 'tell application "System Events" to tell process "Ghostty" to key code 36'
            """
            runBashScript(script)
            return
        }

        let escapedTmuxCmd = bashDoubleQuoteEscape(tmuxCmd)

        // No Ghostty running — launch new window
        let script = """
        if [ -d "/Applications/Ghostty.app" ]; then
            open -na "Ghostty.app" --args -e sh -c "\(escapedTmuxCmd)"
        elif [ -d "/Applications/iTerm.app" ]; then
            osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"\(escapedTmuxCmd)\\""
            osascript -e 'tell application "iTerm" to activate'
        else
            echo "No supported terminal available (Ghostty/iTerm not installed)." >&2
        fi
        """
        runBashScript(script)
    }

    func activateTerminalApp() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isTerminalApp(frontmost)
        {
            frontmost.activate()
            return
        }
        _ = activateFirstRunningTerminal()
    }

    // MARK: - Shell Helpers

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

    // MARK: - IDE Activation

    private func findRunningIDE(_ app: ParentApp) -> NSRunningApplication? {
        guard let processName = app.processName else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName == processName
        }
    }

    private func activateIDEWindowInternal(app: ParentApp, projectPath: String) async -> Bool {
        guard let runningApp = findRunningIDE(app),
              let cliBinary = app.cliBinary
        else { return false }

        runningApp.activate()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [cliBinary, projectPath]

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = Constants.homebrewPaths + ":" + (env["PATH"] ?? "")
                process.environment = env

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        logger.warning("IDE CLI '\(cliBinary)' exited with status \(process.terminationStatus)")
                        continuation.resume(returning: false)
                        return
                    }
                    continuation.resume(returning: true)
                } catch {
                    logger.error("Failed to launch IDE CLI '\(cliBinary)': \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Ghostty Window Detection

    private func isGhosttyRunningInternal() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }
    }

    private func ghosttyWindowStateInternal() -> GhosttyWindowState {
        guard isGhosttyRunningInternal() else {
            return .notRunning
        }

        switch ghosttyWindowReader.readWindows() {
        case .unavailable:
            if Self.activationTraceEnabled {
                debugLog("ghostty window state ax=unavailable")
            }
            return .axUnavailable
        case let .windows(windows):
            if Self.activationTraceEnabled {
                debugLog("ghostty windows count=\(windows.count)")
            }
            return .running
        }
    }

    // MARK: - TTY Discovery

    @discardableResult
    private func activateTerminalByTTYDiscovery(tty: String) async -> Bool {
        if let owningTerminal = await discoverTerminalOwningTTY(tty: tty) {
            logger.debug("    TTY discovery found: \(owningTerminal.displayName) for tty=\(tty)")
            debugLog("activateTerminalByTTYDiscovery found terminal=\(owningTerminal.displayName) tty=\(tty)")
            switch owningTerminal {
            case .iTerm:
                return activateITermSession(tty: tty)
            case .terminal:
                return activateTerminalAppSession(tty: tty)
            default:
                return activateAppByName(owningTerminal.displayName)
            }
        } else {
            logger.debug("    TTY discovery: no terminal found for tty=\(tty)")
            debugLog("activateTerminalByTTYDiscovery no terminal found tty=\(tty)")
            return false
        }
    }

    private func activateTerminalAfterTmuxSwitch(
        clientTty: String?,
        projectPath: String,
        tmuxSessionHint: String?,
    ) async -> Bool {
        await Self.completeTerminalActivationAfterTmuxSwitch(
            clientTty: clientTty,
            projectPath: projectPath,
            activateByTTYDiscovery: { tty in await self.activateTerminalByTTYDiscovery(tty: tty) },
            activateGhosttyByAXRouting: { tty, projectPath, sessionHint in
                await self.activateGhosttyWithAXRouting(
                    forTty: tty,
                    projectPath: projectPath,
                    tmuxSessionHint: sessionHint,
                )
            },
            isGhosttyRunning: { self.isGhosttyRunningInternal() },
            activateTerminalApp: { self.activateTerminalApp() },
            tmuxSessionHint: tmuxSessionHint,
        )
    }

    static func completeTerminalActivationAfterTmuxSwitch(
        clientTty: String?,
        projectPath: String,
        activateByTTYDiscovery: (String) async -> Bool,
        activateGhosttyByAXRouting: @escaping (String?, String?, String?) async -> Bool,
        isGhosttyRunning: () -> Bool,
        activateTerminalApp: () -> Void,
        tmuxSessionHint: String? = nil,
    ) async -> Bool {
        if let clientTty {
            let trimmed = clientTty.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let focused = await activateByTTYDiscovery(trimmed)
                if focused {
                    return true
                }
            }
        }

        if isGhosttyRunning(),
           await activateGhosttyByAXRouting(clientTty, projectPath, tmuxSessionHint)
        {
            return true
        }

        activateTerminalApp()
        return true
    }

    private func discoverTerminalOwningTTY(tty: String) async -> ParentApp? {
        if findRunningApp(.iTerm) != nil, await queryITermForTTY(tty) {
            debugLog("discoverTerminalOwningTTY iTerm owns tty=\(tty)")
            return .iTerm
        }
        if findRunningApp(.terminal) != nil, await queryTerminalAppForTTY(tty) {
            debugLog("discoverTerminalOwningTTY Terminal owns tty=\(tty)")
            return .terminal
        }
        return nil
    }

    private func queryITermForTTY(_ tty: String) async -> Bool {
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not found"
        """
        return await runAppleScriptWithResultAsync(script) == "found"
    }

    private func queryTerminalAppForTTY(_ tty: String) async -> Bool {
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        return "found"
                    end if
                end repeat
            end repeat
        end tell
        return "not found"
        """
        return await runAppleScriptWithResultAsync(script) == "found"
    }

    // MARK: - TTY-Based Tab Selection (AppleScript)

    @discardableResult
    private func activateITermSession(tty: String) -> Bool {
        let script = """
        if application "iTerm" is running then
            tell application "iTerm"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select t
                                select s
                                set index of w to 1
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end if
        """
        return runAppleScriptChecked(script)
    }

    @discardableResult
    private func activateTerminalAppSession(tty: String) -> Bool {
        let script = """
        if application "Terminal" is running then
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected tab of w to t
                            set frontmost of w to true
                            return
                        end if
                    end repeat
                end repeat
            end tell
        end if
        """
        return runAppleScriptChecked(script)
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

    private func activateFirstRunningTerminal() -> Bool {
        logger.debug("    activateFirstRunningTerminal: checking priority order...")
        for terminal in ParentApp.terminalPriorityOrder where terminal.isInstalled {
            logger.debug("    checking \(terminal.displayName)...")
            if let app = findRunningApp(terminal) {
                logger.warning("    ⚠️ FALLBACK: activating \(terminal.displayName) (pid=\(app.processIdentifier)) - NO PROJECT CONTEXT")
                debugLog("activateFirstRunningTerminal activating \(terminal.displayName) pid=\(app.processIdentifier)")
                app.activate()
                return true
            }
        }
        logger.warning("    activateFirstRunningTerminal: no running terminal found")
        debugLog("activateFirstRunningTerminal no running terminal found")
        return false
    }

    private func findRunningApp(_ terminal: ParentApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            guard let localizedName = $0.localizedName else { return false }
            return terminal.matchesRunningAppName(localizedName)
        }
    }

    private func isTerminalApp(_ app: NSRunningApplication) -> Bool {
        guard let name = app.localizedName else { return false }
        return ParentApp.terminalPriorityOrder.contains { $0.matchesRunningAppName(name) }
    }

    // MARK: - New Terminal Launch

    private func launchNewTerminal(for project: Project) -> Bool {
        debugLog("launchNewTerminal project=\(project.name) path=\(project.path)")
        return launchNewTerminal(forPath: project.path, name: project.name)
    }

    static func launchNewTerminalScript(projectPath: String, projectName: String, claudePath: String) -> String {
        TerminalScripts.launchNoTmux(
            projectPath: projectPath,
            projectName: projectName,
            claudePath: claudePath,
        )
    }

    private func launchNewTerminal(forPath path: String, name: String) -> Bool {
        if let launchNewTerminalOverride {
            return launchNewTerminalOverride(path, name)
        }
        _Concurrency.Task {
            let claudePath = await getClaudePath()
            debugLog("launchNewTerminal script path=\(path) name=\(name) claudePath=\(claudePath)")
            let script = Self.launchNewTerminalScript(
                projectPath: path,
                projectName: name,
                claudePath: claudePath,
            )
            runBashScript(script)
            scheduleTerminalActivation()
        }
        return true
    }

    private func getClaudePath() async -> String {
        await CapacitorConfig.shared.getClaudePath() ?? "/opt/homebrew/bin/claude"
    }

    private func scheduleTerminalActivation() {
        _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(Constants.activationDelaySeconds * 1_000_000_000))
            activateTerminalApp()
        }
    }

    // MARK: - Script Execution

    private func runAppleScript(_ script: String) {
        appleScript.run(script)
    }

    /// Runs AppleScript and returns success/failure based on exit code.
    /// Use this for critical activation paths where failure should trigger fallback.
    @discardableResult
    private func runAppleScriptChecked(_ script: String) -> Bool {
        appleScript.runChecked(script)
    }

    private func runAppleScriptWithResultAsync(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe

                process.terminationHandler = { process in
                    if process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown"
                        logger.warning("AppleScript failed (exit \(process.terminationStatus)): \(errorMsg)")
                    }

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: result)
                }

                do {
                    try process.run()
                } catch {
                    logger.error("AppleScript launch failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
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

        # Escape path for single-quoted arguments in osascript commands
        PATH_ESC=$(printf '%s' "$PROJECT_PATH" | sed "s/'/'\\\\''/g")

        if [ -d "/Applications/Ghostty.app" ]; then
            open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH" -e bash -c "$CLAUDE_CMD"
        elif [ -d "/Applications/iTerm.app" ]; then
            osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PATH_ESC' && $CLAUDE_CMD\\""
            osascript -e 'tell application "iTerm" to activate'
        else
            echo "No supported terminal available (Ghostty/iTerm not installed)." >&2
        fi
        """
    }

    static func launchNoTmux(projectPath: String, projectName: String, claudePath: String) -> String {
        // Escape values for safe interpolation into bash double-quoted strings
        let escapedPath = bashDoubleQuoteEscape(projectPath)
        let escapedName = bashDoubleQuoteEscape(projectName)
        let escapedClaude = bashDoubleQuoteEscape(claudePath)

        return """
        PROJECT_PATH="\(escapedPath)"
        PROJECT_NAME="\(escapedName)"
        CLAUDE_PATH="\(escapedClaude)"

        # Helper function to escape strings for single-quoted shell arguments
        shell_escape_single() {
            printf '%s' "$1" | sed "s/'/'\\\\''/g"
        }

        # Escape path for single-quoted arguments in osascript commands
        PATH_ESC=$(shell_escape_single "$PROJECT_PATH")

        if [ -d "/Applications/Ghostty.app" ]; then
            open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH"
        elif [ -d "/Applications/iTerm.app" ]; then
            osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PATH_ESC' && exec \\$SHELL\\""
            osascript -e 'tell application "iTerm" to activate'
        else
            echo "No supported terminal available (Ghostty/iTerm not installed)." >&2
        fi
        """
    }
}
