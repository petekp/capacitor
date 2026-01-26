import AppKit
import Foundation

// MARK: - Terminal App Definition

enum TerminalApp: CaseIterable {
    case ghostty
    case iTerm
    case alacritty
    case kitty
    case warp
    case terminal

    var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .iTerm: return "iTerm"
        case .alacritty: return "Alacritty"
        case .kitty: return "kitty"
        case .warp: return "Warp"
        case .terminal: return "Terminal"
        }
    }

    var bundlePath: String? {
        switch self {
        case .ghostty: return "/Applications/Ghostty.app"
        case .iTerm: return "/Applications/iTerm.app"
        case .alacritty: return "/Applications/Alacritty.app"
        case .warp: return "/Applications/Warp.app"
        case .kitty, .terminal: return nil
        }
    }

    var isInstalled: Bool {
        guard let path = bundlePath else {
            return self == .kitty || self == .terminal
        }
        return FileManager.default.fileExists(atPath: path)
    }

    static let priorityOrder: [TerminalApp] = [
        .ghostty, .iTerm, .alacritty, .kitty, .warp, .terminal,
    ]
}

// MARK: - Terminal Launcher

@MainActor
final class TerminalLauncher {
    private enum Constants {
        static let activationDelaySeconds: Double = 0.3
    }

    // MARK: - Public API

    func launchTerminal(for project: Project, shellState: ShellCwdState? = nil) {
        if let shell = findExistingShell(for: project, in: shellState) {
            activateExistingTerminal(tty: shell.tty, parentApp: shell.parentApp)
        } else {
            launchNewTerminal(for: project)
        }
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

    private func findExistingShell(for project: Project, in state: ShellCwdState?) -> ShellEntry? {
        guard let shells = state?.shells else { return nil }

        let liveShells = shells.filter { isLiveNonTmuxShell($0) }

        // Prefer exact CWD match
        if let match = liveShells.first(where: { $0.value.cwd == project.path }) {
            return match.value
        }

        // Fall back to subdirectory match
        let prefix = project.path.hasSuffix("/") ? project.path : project.path + "/"
        if let match = liveShells.first(where: { $0.value.cwd.hasPrefix(prefix) }) {
            return match.value
        }

        return nil
    }

    private func isLiveNonTmuxShell(_ entry: (key: String, value: ShellEntry)) -> Bool {
        guard let pid = Int32(entry.key) else { return false }
        let isAlive = kill(pid, 0) == 0
        let isTmux = entry.value.parentApp?.lowercased() == "tmux"
        return isAlive && !isTmux
    }

    // MARK: - Terminal Activation

    private func activateExistingTerminal(tty: String, parentApp: String?) {
        if let app = parentApp?.lowercased() {
            activateKnownTerminal(app: app, tty: tty)
        } else {
            activateDetectedTerminal(tty: tty)
        }
    }

    private func activateKnownTerminal(app: String, tty: String) {
        if app.contains("iterm") {
            activateITermSession(tty: tty)
        } else if app == "terminal" {
            activateTerminalAppSession(tty: tty)
        } else if app.contains("ghostty") {
            activateAppByName("Ghostty")
        } else {
            activateAppByName(app)
        }
    }

    private func activateDetectedTerminal(tty: String) {
        // When parent_app is unknown, try terminals that support TTY-based tab selection
        if findRunningApp(.iTerm) != nil {
            activateITermSession(tty: tty)
        } else if findRunningApp(.terminal) != nil {
            activateTerminalAppSession(tty: tty)
        } else {
            activateFirstRunningTerminal()
        }
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

    private func activateAppByName(_ name: String?) {
        guard let name = name,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.localizedName?.lowercased().contains(name.lowercased()) == true
              })
        else {
            activateFirstRunningTerminal()
            return
        }
        app.activate()
    }

    private func activateFirstRunningTerminal() {
        for terminal in TerminalApp.priorityOrder where terminal.isInstalled {
            if let app = findRunningApp(terminal) {
                app.activate()
                return
            }
        }
    }

    private func findRunningApp(_ terminal: TerminalApp) -> NSRunningApplication? {
        let name = terminal.displayName.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased().contains(name) == true
        }
    }

    private func isTerminalApp(_ app: NSRunningApplication) -> Bool {
        guard let name = app.localizedName else { return false }
        return TerminalApp.priorityOrder.contains { name.contains($0.displayName) }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.activationDelaySeconds) { [weak self] in
            self?.activateTerminalApp()
        }
    }

    // MARK: - Script Execution

    private func runAppleScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
    }

    private func runBashScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        var env = ProcessInfo.processInfo.environment
        let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = homebrewPaths + ":" + (env["PATH"] ?? "")
        process.environment = env

        try? process.run()
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
