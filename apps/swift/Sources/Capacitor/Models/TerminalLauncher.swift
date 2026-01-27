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

// MARK: - Shell Match Result

private struct ShellMatch {
    let pid: String
    let shell: ShellEntry
}

// MARK: - Strategy Execution Context

private struct ActivationContext {
    let shell: ShellEntry
    let pid: String
    let projectPath: String
    let scenario: ShellScenario
    let shellState: ShellCwdState?
}

// MARK: - Terminal Launcher

@MainActor
final class TerminalLauncher {
    private enum Constants {
        static let activationDelaySeconds: Double = 0.3
        static let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
    }

    private let configStore = ActivationConfigStore.shared

    // MARK: - Public API

    func launchTerminal(for project: Project, shellState: ShellCwdState? = nil) {
        Task {
            await launchTerminalAsync(for: project, shellState: shellState)
        }
    }

    private func launchTerminalAsync(for project: Project, shellState: ShellCwdState? = nil) async {
        // First, check if there's a tmux session for this project path.
        // This is more reliable than shell-cwd.json since it queries tmux directly.
        if let tmuxSession = await findTmuxSessionForPath(project.path) {
            await switchToTmuxSessionAndActivate(session: tmuxSession)
            return
        }

        // Fallback to shell-cwd.json based matching
        if let match = findExistingShell(for: project, in: shellState) {
            await activateExistingTerminal(shell: match.shell, pid: match.pid, projectPath: project.path, shellState: shellState)
        } else {
            launchNewTerminal(for: project)
        }
    }

    private func switchToTmuxSessionAndActivate(session: String) async {
        // Check if there's an attached tmux client
        if await hasTmuxClientAttached() {
            // Switch the existing client to the target session
            runBashScript("tmux switch-client -t '\(session)' 2>/dev/null")
            try? await Task.sleep(nanoseconds: 100_000_000)
            activateTerminalApp()
        } else {
            // No client attached - launch a new terminal window that attaches to the session
            launchTerminalWithTmuxSession(session)
        }
    }

    private func hasTmuxClientAttached() async -> Bool {
        let result = await runBashScriptWithResultAsync("tmux list-clients 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func launchTerminalWithTmuxSession(_ session: String) {
        let tmuxCmd = "tmux attach-session -t '\(session)'"

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

    // MARK: - Shell Lookup

    private func findExistingShell(for project: Project, in state: ShellCwdState?) -> ShellMatch? {
        guard let shells = state?.shells else { return nil }

        let liveShells = shells.filter { isLiveShell($0) }
        let (nonTmuxShells, tmuxShells) = partitionByTmux(liveShells)

        // Prefer tmux shells over non-tmux shells since tmux session switching is more reliable
        // than TTY-based activation (which often fails for tmux client TTYs)
        // Uses exact path matching only - no child path inheritance.
        return findMatchingShell(in: tmuxShells, projectPath: project.path)
            ?? findMatchingShell(in: nonTmuxShells, projectPath: project.path)
    }

    /// Query tmux directly for a session matching the project path.
    /// Returns the session name if found.
    private func findTmuxSessionForPath(_ projectPath: String) async -> String? {
        let result = await runBashScriptWithResultAsync("tmux list-windows -a -F '#{session_name}\t#{pane_current_path}' 2>/dev/null")
        guard result.exitCode == 0, let output = result.output else { return nil }

        // Parse tab-separated lines: "session_name\tpath"
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

    private func partitionByTmux(_ shells: [String: ShellEntry]) -> (nonTmux: [String: ShellEntry], tmux: [String: ShellEntry]) {
        var nonTmux: [String: ShellEntry] = [:]
        var tmux: [String: ShellEntry] = [:]

        for (pid, shell) in shells {
            if isTmuxShell(shell) {
                tmux[pid] = shell
            } else {
                nonTmux[pid] = shell
            }
        }

        return (nonTmux, tmux)
    }

    private func findMatchingShell(
        in shells: [String: ShellEntry],
        projectPath: String
    ) -> ShellMatch? {
        // Exact match only - no child path inheritance.
        // Monorepo packages should launch their own sessions, not reuse parent's.
        if let match = shells.first(where: { $0.value.cwd == projectPath }) {
            return ShellMatch(pid: match.key, shell: match.value)
        }

        return nil
    }

    private func isLiveShell(_ entry: (key: String, value: ShellEntry)) -> Bool {
        guard let pid = Int32(entry.key) else { return false }
        return kill(pid, 0) == 0
    }

    private func isTmuxShell(_ shell: ShellEntry) -> Bool {
        shell.tmuxSession != nil
    }

    // MARK: - Strategy-Based Activation

    private func activateExistingTerminal(shell: ShellEntry, pid: String, projectPath: String, shellState: ShellCwdState?) async {
        let shellCount = shellState?.shells.count ?? 1
        let scenario = ShellScenario(
            parentApp: ParentApp(fromString: shell.parentApp),
            context: ShellContext(hasTmuxSession: shell.tmuxSession != nil),
            multiplicity: TerminalMultiplicity(shellCount: shellCount)
        )

        let behavior = configStore.behavior(for: scenario)
        let context = ActivationContext(
            shell: shell,
            pid: pid,
            projectPath: projectPath,
            scenario: scenario,
            shellState: shellState
        )

        let primarySuccess = await executeStrategy(behavior.primaryStrategy, context: context)

        if !primarySuccess, let fallback = behavior.fallbackStrategy {
            logger.info("Primary strategy \(String(describing: behavior.primaryStrategy)) failed, trying fallback: \(String(describing: fallback))")
            _ = await executeStrategy(fallback, context: context)
        }
    }

    @discardableResult
    private func executeStrategy(_ strategy: ActivationStrategy, context: ActivationContext) async -> Bool {
        switch strategy {
        case .activateByTTY:
            return await activateByTTY(context: context)
        case .activateByApp:
            return activateByApp(context: context)
        case .activateKittyRemote:
            return activateKittyRemote(context: context)
        case .activateIDEWindow:
            return activateIDEWindow(context: context)
        case .switchTmuxSession:
            return switchTmuxSession(context: context)
        case .activateHostFirst:
            return await activateHostFirst(context: context)
        case .launchNewTerminal:
            launchNewTerminalForContext(context: context)
            return true
        case .priorityFallback:
            return activatePriorityFallback(context: context)
        case .skip:
            return true
        }
    }

    // MARK: - Strategy Implementations

    private func activateByTTY(context: ActivationContext) async -> Bool {
        let tty = context.shell.tty
        let parentApp = ParentApp(fromString: context.shell.parentApp)

        if parentApp.category == .terminal {
            switch parentApp {
            case .iTerm:
                activateITermSession(tty: tty)
                return true
            case .terminal:
                activateTerminalAppSession(tty: tty)
                return true
            default:
                break
            }
        }

        if let owningTerminal = await discoverTerminalOwningTTY(tty: tty) {
            switch owningTerminal {
            case .iTerm:
                activateITermSession(tty: tty)
                return true
            case .terminal:
                activateTerminalAppSession(tty: tty)
                return true
            default:
                activateAppByName(owningTerminal.displayName)
                return true
            }
        }

        return false
    }

    private func activateByApp(context: ActivationContext) -> Bool {
        let parentApp = ParentApp(fromString: context.shell.parentApp)
        guard parentApp != .unknown else { return false }

        if parentApp.category == .ide {
            if let app = findRunningIDE(parentApp) {
                app.activate()
                return true
            }
        }

        if parentApp.category == .terminal {
            if let app = findRunningApp(parentApp) {
                app.activate()
                return true
            }
        }

        if activateAppByName(parentApp.displayName) {
            return true
        }

        return false
    }

    private func activateKittyRemote(context: ActivationContext) -> Bool {
        activateAppByName("kitty")
        runBashScript("kitty @ focus-window --match pid:\(context.pid) 2>/dev/null")
        return true
    }

    private func activateIDEWindow(context: ActivationContext) -> Bool {
        let parentApp = ParentApp(fromString: context.shell.parentApp)
        guard parentApp.category == .ide,
              findRunningIDE(parentApp) != nil
        else { return false }

        activateIDEWindowInternal(app: parentApp, projectPath: context.projectPath)
        return true
    }

    private func switchTmuxSession(context: ActivationContext) -> Bool {
        guard let session = context.shell.tmuxSession else { return false }
        runBashScript("tmux switch-client -t '\(session)' 2>/dev/null")
        return true
    }

    private func activateHostFirst(context: ActivationContext) async -> Bool {
        let hostTTY = context.shell.tmuxClientTty ?? context.shell.tty

        let ttyActivated = await activateTerminalByTTYDiscovery(tty: hostTTY)

        if let session = context.shell.tmuxSession {
            runBashScript("tmux switch-client -t '\(session)' 2>/dev/null")
        }

        return ttyActivated
    }

    private func launchNewTerminalForContext(context: ActivationContext) {
        let projectName = URL(fileURLWithPath: context.projectPath).lastPathComponent
        let project = Project(
            name: projectName,
            path: context.projectPath,
            displayPath: context.projectPath,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false
        )
        launchNewTerminal(for: project)
    }

    private func activatePriorityFallback(context: ActivationContext) -> Bool {
        logger.info("Using priority fallback: activating first running terminal (no specific terminal found for project)")
        activateFirstRunningTerminal()
        return true
    }

    // MARK: - IDE Activation

    private func findRunningIDE(_ app: ParentApp) -> NSRunningApplication? {
        guard let processName = app.processName else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName == processName
        }
    }

    private func activateIDEWindowInternal(app: ParentApp, projectPath: String) {
        guard let runningApp = findRunningIDE(app),
              let cliBinary = app.cliBinary
        else { return }

        runningApp.activate()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [cliBinary, projectPath]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Constants.homebrewPaths + ":" + (env["PATH"] ?? "")
        process.environment = env

        try? process.run()
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
              })
        else {
            return false
        }
        app.activate()
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
        _Concurrency.Task {
            let claudePath = await getClaudePath()
            runBashScript(TerminalScripts.launch(project: project, claudePath: claudePath))
            scheduleTerminalActivation()
        }
    }

    private func getClaudePath() async -> String {
        await CapacitorConfig.shared.getClaudePath() ?? "/opt/homebrew/bin/claude"
    }

    private func scheduleTerminalActivation() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Constants.activationDelaySeconds * 1_000_000_000))
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
    static func launch(project: Project, claudePath: String) -> String {
        """
        PROJECT_PATH="\(project.path)"
        PROJECT_NAME="\(project.name)"
        CLAUDE_PATH="\(claudePath)"

        \(tmuxCheckAndFallback)

        \(findOrCreateSession)

        HAS_ATTACHED_CLIENT=$(tmux list-clients 2>/dev/null | head -1)

        if [ -n "$HAS_ATTACHED_CLIENT" ]; then
            \(switchToExistingSession)
            \(activateTerminalApp)
        else
            TMUX_CMD="tmux new-session -A -s '$SESSION' -c '$PROJECT_PATH'"
            \(launchTerminalWithTmux)
        fi
        """
    }

    private static var tmuxCheckAndFallback: String {
        """
        if ! command -v tmux &> /dev/null; then
            if [ -d "/Applications/Ghostty.app" ]; then
                open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH"
            elif [ -d "/Applications/iTerm.app" ]; then
                osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PROJECT_PATH' && exec $SHELL\\""
                osascript -e 'tell application "iTerm" to activate'
            elif [ -d "/Applications/Alacritty.app" ]; then
                open -na "Alacritty.app" --args --working-directory "$PROJECT_PATH"
            elif command -v kitty &>/dev/null; then
                kitty --directory "$PROJECT_PATH" &
            elif [ -d "/Applications/Warp.app" ]; then
                open -a "Warp" "$PROJECT_PATH"
            else
                osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PROJECT_PATH'\\""
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
        if tmux has-session -t "$SESSION" 2>/dev/null; then
            tmux switch-client -t "$SESSION" 2>/dev/null
        else
            tmux new-session -d -s "$SESSION" -c "$PROJECT_PATH"
            tmux switch-client -t "$SESSION" 2>/dev/null
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
