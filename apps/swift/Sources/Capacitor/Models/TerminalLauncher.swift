import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "TerminalLauncher")

// MARK: - ParentApp Terminal Extensions

extension ParentApp {
    var bundlePath: String? {
        switch self {
        case .ghostty: return "/Applications/Ghostty.app"
        case .iTerm: return "/Applications/iTerm.app"
        case .alacritty: return "/Applications/Alacritty.app"
        case .warp: return "/Applications/Warp.app"
        case .kitty, .terminal: return nil
        default: return nil
        }
    }

    var isInstalled: Bool {
        guard category == .terminal else { return false }
        guard let path = bundlePath else {
            return self == .kitty || self == .terminal
        }
        return FileManager.default.fileExists(atPath: path)
    }

    static let terminalPriorityOrder: [ParentApp] = [
        .ghostty, .iTerm, .alacritty, .kitty, .warp, .terminal
    ]

    var processName: String? {
        switch self {
        case .cursor: return "Cursor"
        case .vsCode: return "Code"
        case .vsCodeInsiders: return "Code - Insiders"
        case .zed: return "Zed"
        default: return nil
        }
    }

    var cliBinary: String? {
        switch self {
        case .cursor: return "cursor"
        case .vsCode: return "code"
        case .vsCodeInsiders: return "code-insiders"
        case .zed: return "zed"
        default: return nil
        }
    }
}

// MARK: - TerminalType Display Name Extension

extension TerminalType {
    var appName: String {
        switch self {
        case .iTerm: return "iTerm"
        case .terminalApp: return "Terminal"
        case .ghostty: return "Ghostty"
        case .alacritty: return "Alacritty"
        case .kitty: return "kitty"
        case .warp: return "Warp"
        case .unknown: return ""
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
//
// Handles "click project → focus terminal" activation. The goal is to bring the user
// to their existing terminal window for a project, not spawn new windows unnecessarily.
//
// ACTIVATION PRIORITY (ordered by user intent signal strength):
//
//   1. Active shell in shell-cwd.json → User has a terminal window open RIGHT NOW
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
// Ghostty window. The shell-cwd.json check finds the actively-used terminal.

@MainActor
final class TerminalLauncher {
    private enum Constants {
        static let activationDelaySeconds: Double = 0.3
        static let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
        static let ghosttySessionCacheDuration: TimeInterval = 30.0
    }

    private let configStore = ActivationConfigStore.shared

    // Cache: tracks tmux sessions where we recently launched a Ghostty window.
    // Prevents re-launching on rapid clicks when window count > 1.
    private static var recentlyLaunchedGhosttySessions: [String: Date] = [:]

    // MARK: - Public API

    func launchTerminal(for project: Project, shellState: ShellCwdState? = nil) {
        _Concurrency.Task {
            await launchTerminalAsync(for: project, shellState: shellState)
        }
    }

    private func launchTerminalAsync(for project: Project, shellState: ShellCwdState? = nil) async {
        await launchTerminalWithRustResolver(for: project, shellState: shellState)
    }

    // MARK: - Rust Resolver Path

    private func launchTerminalWithRustResolver(for project: Project, shellState: ShellCwdState? = nil) async {
        let ffiShellState = shellState.map { convertToFfi($0) }
        let tmuxContext = await queryTmuxContext(projectPath: project.path)

        guard let engine = try? HudEngine() else {
            logger.warning("Failed to create HudEngine, launching new terminal as fallback")
            launchNewTerminal(for: project)
            return
        }

        let decision = engine.resolveActivation(
            projectPath: project.path,
            shellState: ffiShellState,
            tmuxContext: tmuxContext
        )

        logger.debug("Activation decision: \(decision.reason)")

        let primarySuccess = await executeActivationAction(decision.primary, projectPath: project.path, projectName: project.name)

        if !primarySuccess, let fallback = decision.fallback {
            logger.info("Primary action failed, trying fallback")
            _ = await executeActivationAction(fallback, projectPath: project.path, projectName: project.name)
        }
    }

    // MARK: - Type Conversion to FFI

    private func convertToFfi(_ state: ShellCwdState) -> ShellCwdStateFfi {
        var ffiShells: [String: ShellEntryFfi] = [:]

        for (pid, entry) in state.shells {
            guard isLiveShell((pid, entry)) else { continue }

            let parentApp = ParentApp(fromString: entry.parentApp)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            ffiShells[pid] = ShellEntryFfi(
                cwd: entry.cwd,
                tty: entry.tty,
                parentApp: parentApp,
                tmuxSession: entry.tmuxSession,
                tmuxClientTty: entry.tmuxClientTty,
                updatedAt: formatter.string(from: entry.updatedAt)
            )
        }

        return ShellCwdStateFfi(version: UInt32(state.version), shells: ffiShells)
    }

    private func queryTmuxContext(projectPath: String) async -> TmuxContextFfi {
        async let sessionAtPath = findTmuxSessionForPath(projectPath)
        async let hasAttached = hasTmuxClientAttached()

        return TmuxContextFfi(
            sessionAtPath: await sessionAtPath,
            hasAttachedClient: await hasAttached
        )
    }

    // MARK: - Action Execution

    private func executeActivationAction(_ action: ActivationAction, projectPath: String, projectName: String) async -> Bool {
        logger.debug("Executing activation action: \(String(describing: action))")
        switch action {
        case let .activateByTty(tty, terminalType):
            return await activateByTtyAction(tty: tty, terminalType: terminalType)

        case let .activateApp(appName):
            return activateAppByName(appName)

        case let .activateKittyWindow(shellPid):
            let activated = activateAppByName("kitty")
            if activated {
                runBashScript("kitty @ focus-window --match pid:\(shellPid) 2>/dev/null")
            }
            return activated

        case let .activateIdeWindow(ideType, path):
            return activateIdeWindowAction(ideType: ideType, projectPath: path)

        case let .switchTmuxSession(sessionName):
            let result = await runBashScriptWithResultAsync(
                "tmux switch-client -t \(shellEscape(sessionName)) 2>&1"
            )
            if result.exitCode != 0 {
                logger.warning("tmux switch-client failed (exit \(result.exitCode)): \(result.output ?? "")")
                return false
            }
            return true

        case let .activateHostThenSwitchTmux(hostTty, sessionName):
            // Special handling for Ghostty: it has no API to focus a specific window by TTY.
            // If Ghostty is running, use window-count strategy instead of TTY discovery.
            if isGhosttyRunning() {
                cleanupExpiredGhosttyCache()

                // Check if we recently launched a window for this session.
                // If so, just activate + switch-client instead of launching another.
                if let launchTime = Self.recentlyLaunchedGhosttySessions[sessionName],
                   Date().timeIntervalSince(launchTime) < Constants.ghosttySessionCacheDuration
                {
                    logger.debug("Cache hit: Ghostty window recently launched for '\(sessionName)'")
                    runAppleScript("tell application \"Ghostty\" to activate")
                    let result = await runBashScriptWithResultAsync(
                        "tmux switch-client -t \(shellEscape(sessionName)) 2>&1"
                    )
                    if result.exitCode != 0 {
                        logger.warning("tmux switch-client failed (exit \(result.exitCode)): \(result.output ?? "")")
                        return false
                    }
                    return true
                }

                logger.debug("Cache miss for Ghostty session '\(sessionName)'")

                let windowCount = countGhosttyWindows()
                logger.debug("Ghostty has \(windowCount) window(s) for tmux session '\(sessionName)'")

                if windowCount == 1 {
                    // Single window - safe to activate the app and switch tmux session.
                    // Use AppleScript for reliable activation (NSRunningApplication.activate
                    // can silently fail when SwiftUI windows steal focus back).
                    runAppleScript("tell application \"Ghostty\" to activate")
                    let result = await runBashScriptWithResultAsync(
                        "tmux switch-client -t \(shellEscape(sessionName)) 2>&1"
                    )
                    if result.exitCode != 0 {
                        logger.warning("tmux switch-client failed (exit \(result.exitCode)): \(result.output ?? "")")
                        return false
                    }
                    return true
                } else {
                    // 0 or multiple windows - launch new terminal to attach.
                    // Record this launch so subsequent clicks within 30s just activate + switch.
                    Self.recentlyLaunchedGhosttySessions[sessionName] = Date()
                    logger.info("Ghostty has \(windowCount) windows - launching new terminal for reliable tmux activation")
                    launchTerminalWithTmuxSession(sessionName)
                    return true
                }
            }

            // For other terminals (iTerm, Terminal.app), use TTY discovery
            let ttyActivated = await activateTerminalByTTYDiscovery(tty: hostTty)
            let result = await runBashScriptWithResultAsync(
                "tmux switch-client -t \(shellEscape(sessionName)) 2>&1"
            )
            if result.exitCode != 0 {
                logger.warning("tmux switch-client failed (exit \(result.exitCode)): \(result.output ?? "")")
                return false
            }
            return ttyActivated

        case let .launchTerminalWithTmux(sessionName, _):
            launchTerminalWithTmuxSession(sessionName)
            return true

        case let .launchNewTerminal(path, name):
            launchNewTerminal(forPath: path, name: name)
            return true

        case .activatePriorityFallback:
            activateFirstRunningTerminal()
            return true

        case .skip:
            return true
        }
    }

    private func activateByTtyAction(tty: String, terminalType: TerminalType) async -> Bool {
        switch terminalType {
        case .iTerm:
            activateITermSession(tty: tty)
            return true
        case .terminalApp:
            activateTerminalAppSession(tty: tty)
            return true
        case .ghostty, .alacritty, .warp:
            return activateAppByName(terminalType.appName)
        case .kitty:
            return activateAppByName("kitty")
        case .unknown:
            if let owningTerminal = await discoverTerminalOwningTTY(tty: tty) {
                switch owningTerminal {
                case .iTerm:
                    activateITermSession(tty: tty)
                case .terminal:
                    activateTerminalAppSession(tty: tty)
                default:
                    activateAppByName(owningTerminal.displayName)
                }
                return true
            }
            return false
        }
    }

    private func activateIdeWindowAction(ideType: IdeType, projectPath: String) -> Bool {
        let parentApp: ParentApp
        switch ideType {
        case .cursor: parentApp = .cursor
        case .vsCode: parentApp = .vsCode
        case .vsCodeInsiders: parentApp = .vsCodeInsiders
        case .zed: parentApp = .zed
        }

        guard findRunningIDE(parentApp) != nil else { return false }
        return activateIDEWindowInternal(app: parentApp, projectPath: projectPath)
    }

    // MARK: - Tmux Helpers

    private func hasTmuxClientAttached() async -> Bool {
        let result = await runBashScriptWithResultAsync("tmux list-clients 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func launchTerminalWithTmuxSession(_ session: String) {
        logger.debug("Launching terminal with tmux attach for session '\(session)'")
        let escapedSession = shellEscape(session)
        let tmuxCmd = "tmux attach-session -t \(escapedSession)"

        // Launch terminal with tmux attach command
        let script = """
            if [ -d "/Applications/Ghostty.app" ]; then
                open -na "Ghostty.app" --args -e sh -c "\(tmuxCmd)"
            elif [ -d "/Applications/iTerm.app" ]; then
                osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"\(tmuxCmd)\\""
                osascript -e 'tell application "iTerm" to activate'
            elif [ -d "/Applications/Alacritty.app" ]; then
                open -na "Alacritty.app" --args -e sh -c "\(tmuxCmd)"
            elif command -v kitty &>/dev/null; then
                kitty sh -c "\(tmuxCmd)" &
            elif [ -d "/Applications/Warp.app" ]; then
                open -a "Warp"
            else
                osascript -e "tell application \\"Terminal\\" to do script \\"\(tmuxCmd)\\""
                osascript -e 'tell application "Terminal" to activate'
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
        activateFirstRunningTerminal()
    }

    // MARK: - Shell Helpers

    private func findTmuxSessionForPath(_ projectPath: String) async -> String? {
        let result = await runBashScriptWithResultAsync("tmux list-windows -a -F '#{session_name}\t#{pane_current_path}' 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return nil }

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let sessionName = String(parts[0])
            let panePath = String(parts[1])
            if panePath == projectPath {
                return sessionName
            }
        }
        return nil
    }

    private func isLiveShell(_ entry: (key: String, value: ShellEntry)) -> Bool {
        guard let pid = Int32(entry.key) else { return false }
        return kill(pid, 0) == 0
    }

    // MARK: - IDE Activation

    private func findRunningIDE(_ app: ParentApp) -> NSRunningApplication? {
        guard let processName = app.processName else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName == processName
        }
    }

    private func activateIDEWindowInternal(app: ParentApp, projectPath: String) -> Bool {
        guard let runningApp = findRunningIDE(app),
              let cliBinary = app.cliBinary
        else { return false }

        runningApp.activate()

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
                return false
            }
            return true
        } catch {
            logger.error("Failed to launch IDE CLI '\(cliBinary)': \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Ghostty Window Detection
    //
    // Ghostty has no API for selecting a specific window by TTY (unlike iTerm/Terminal.app).
    // When multiple Ghostty windows exist, we can't focus the correct one - only activate the app.
    // Strategy: If exactly 1 window, activate app. If 0 or multiple, launch new terminal.

    private func countGhosttyWindows() -> Int {
        guard let ghosttyApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }) else {
            return 0
        }

        let appElement = AXUIElementCreateApplication(ghosttyApp.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return 0
        }

        return windows.count
    }

    private func isGhosttyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }
    }

    private func cleanupExpiredGhosttyCache() {
        let now = Date()
        Self.recentlyLaunchedGhosttySessions = Self.recentlyLaunchedGhosttySessions.filter { _, launchTime in
            now.timeIntervalSince(launchTime) < Constants.ghosttySessionCacheDuration
        }
    }

    // MARK: - TTY Discovery

    @discardableResult
    private func activateTerminalByTTYDiscovery(tty: String) async -> Bool {
        if let owningTerminal = await discoverTerminalOwningTTY(tty: tty) {
            logger.debug("TTY discovery found terminal: \(owningTerminal.displayName) for tty: \(tty)")
            switch owningTerminal {
            case .iTerm:
                activateITermSession(tty: tty)
            case .terminal:
                activateTerminalAppSession(tty: tty)
            default:
                activateAppByName(owningTerminal.displayName)
            }
            return true
        } else {
            logger.info("TTY discovery failed for tty: \(tty) - falling back to first running terminal")
            activateFirstRunningTerminal()
            return false
        }
    }

    private func discoverTerminalOwningTTY(tty: String) async -> ParentApp? {
        if findRunningApp(.iTerm) != nil, await queryITermForTTY(tty) {
            return .iTerm
        }
        if findRunningApp(.terminal) != nil, await queryTerminalAppForTTY(tty) {
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

    private func activateITermSession(tty: String) {
        let script = """
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
            """
        runAppleScript(script)
    }

    private func activateTerminalAppSession(tty: String) {
        let script = """
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
            """
        runAppleScript(script)
    }

    // MARK: - App Activation Helpers

    @discardableResult
    private func activateAppByName(_ name: String?) -> Bool {
        guard let name = name,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.localizedName?.lowercased().contains(name.lowercased()) == true
              }),
              let appName = app.localizedName
        else {
            return false
        }
        // Use AppleScript for reliable activation - NSRunningApplication.activate()
        // can silently fail when SwiftUI windows steal focus back.
        logger.debug("Activating '\(appName)' via AppleScript")
        runAppleScript("tell application \"\(appName)\" to activate")
        return true
    }

    private func activateFirstRunningTerminal() {
        for terminal in ParentApp.terminalPriorityOrder where terminal.isInstalled {
            if let app = findRunningApp(terminal) {
                app.activate()
                return
            }
        }
    }

    private func findRunningApp(_ terminal: ParentApp) -> NSRunningApplication? {
        let name = terminal.displayName.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased().contains(name) == true
        }
    }

    private func isTerminalApp(_ app: NSRunningApplication) -> Bool {
        guard let name = app.localizedName else { return false }
        return ParentApp.terminalPriorityOrder.contains { name.contains($0.displayName) }
    }

    // MARK: - New Terminal Launch

    private func launchNewTerminal(for project: Project) {
        launchNewTerminal(forPath: project.path, name: project.name)
    }

    private func launchNewTerminal(forPath path: String, name: String) {
        _Concurrency.Task {
            let claudePath = await getClaudePath()
            runBashScript(TerminalScripts.launch(projectPath: path, projectName: name, claudePath: claudePath))
            scheduleTerminalActivation()
        }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func runAppleScriptAsync(_ script: String) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                try? process.run()
                process.waitUntilExit()
                continuation.resume()
            }
        }
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

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown"
                        logger.warning("AppleScript failed (exit \(process.terminationStatus)): \(errorMsg)")
                    }

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: result)
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

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)
                    continuation.resume(returning: (process.terminationStatus, output))
                } catch {
                    continuation.resume(returning: (-1, nil))
                }
            }
        }
    }
}

// MARK: - Terminal Launch Scripts

private enum TerminalScripts {
    static func launch(projectPath: String, projectName: String, claudePath: String) -> String {
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

        \(tmuxCheckAndFallback)

        \(findOrCreateSession)

        HAS_ATTACHED_CLIENT=$(tmux list-clients 2>/dev/null | head -1)

        if [ -n "$HAS_ATTACHED_CLIENT" ]; then
            \(switchToExistingSession)
            \(activateTerminalApp)
        else
            # Escape session name and path for single-quoted tmux arguments
            SESSION_ESC=$(shell_escape_single "$SESSION")
            PATH_ESC=$(shell_escape_single "$PROJECT_PATH")
            TMUX_CMD="tmux new-session -A -s '$SESSION_ESC' -c '$PATH_ESC'"
            \(launchTerminalWithTmux)
        fi
        """
    }

    private static var tmuxCheckAndFallback: String {
        """
        if ! command -v tmux &> /dev/null; then
            # Escape path for single-quoted arguments in osascript commands
            PATH_ESC=$(shell_escape_single "$PROJECT_PATH")
            if [ -d "/Applications/Ghostty.app" ]; then
                open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH"
            elif [ -d "/Applications/iTerm.app" ]; then
                osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PATH_ESC' && exec \\$SHELL\\""
                osascript -e 'tell application "iTerm" to activate'
            elif [ -d "/Applications/Alacritty.app" ]; then
                open -na "Alacritty.app" --args --working-directory "$PROJECT_PATH"
            elif command -v kitty &>/dev/null; then
                kitty --directory "$PROJECT_PATH" &
            elif [ -d "/Applications/Warp.app" ]; then
                open -a "Warp" "$PROJECT_PATH"
            else
                osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PATH_ESC'\\""
                osascript -e 'tell application "Terminal" to activate'
            fi
            exit 0
        fi
        """
    }

    private static var findOrCreateSession: String {
        """
        EXISTING_SESSION=$(tmux list-windows -a -F '#{session_name}:#{pane_current_path}' 2>/dev/null | \\
            grep ":$PROJECT_PATH$" | cut -d: -f1 | head -1)

        if [ -n "$EXISTING_SESSION" ]; then
            SESSION="$EXISTING_SESSION"
        else
            SESSION="$PROJECT_NAME"
        fi
        """
    }

    private static var switchToExistingSession: String {
        """
        # Escape session and path for tmux arguments
        SESSION_ESC=$(shell_escape_single "$SESSION")
        PATH_ESC=$(shell_escape_single "$PROJECT_PATH")
        if tmux has-session -t "'$SESSION_ESC'" 2>/dev/null; then
            tmux switch-client -t "'$SESSION_ESC'" 2>/dev/null
        else
            tmux new-session -d -s "'$SESSION_ESC'" -c "'$PATH_ESC'"
            tmux switch-client -t "'$SESSION_ESC'" 2>/dev/null
        fi
        """
    }

    private static var activateTerminalApp: String {
        """
        if pgrep -xq "Ghostty"; then
            osascript -e 'tell application "Ghostty" to activate'
        elif pgrep -xq "iTerm2"; then
            osascript -e 'tell application "iTerm" to activate'
        elif pgrep -xq "WarpTerminal"; then
            osascript -e 'tell application "Warp" to activate'
        elif pgrep -xq "Alacritty"; then
            osascript -e 'tell application "Alacritty" to activate'
        elif pgrep -xq "kitty"; then
            osascript -e 'tell application "kitty" to activate'
        elif pgrep -xq "Terminal"; then
            osascript -e 'tell application "Terminal" to activate'
        fi
        """
    }

    private static var launchTerminalWithTmux: String {
        """
        if [ -d "/Applications/Ghostty.app" ]; then
            open -na "Ghostty.app" --args -e sh -c "$TMUX_CMD"
        elif [ -d "/Applications/iTerm.app" ]; then
            osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"$TMUX_CMD\\""
            osascript -e 'tell application "iTerm" to activate'
        elif [ -d "/Applications/Alacritty.app" ]; then
            open -na "Alacritty.app" --args -e sh -c "$TMUX_CMD"
        elif command -v kitty &>/dev/null; then
            kitty sh -c "$TMUX_CMD" &
        elif [ -d "/Applications/Warp.app" ]; then
            open -a "Warp" "$PROJECT_PATH"
        else
            osascript -e "tell application \\"Terminal\\" to do script \\"$TMUX_CMD\\""
            osascript -e 'tell application "Terminal" to activate'
        fi
        """
    }
}
