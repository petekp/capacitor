import AppKit
import Foundation

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
        .ghostty, .iTerm, .alacritty, .kitty, .warp, .terminal
    ]
}

@MainActor
final class TerminalIntegration {
    private enum Constants {
        static let pollingIntervalNanos: UInt64 = 500_000_000
        static let trackerPauseSeconds: TimeInterval = 2.0
        static let activationDelaySeconds: Double = 0.3
    }

    private let terminalTracker = TerminalTracker()
    private var trackerUpdateTask: _Concurrency.Task<Void, Never>?

    private(set) var activeProjectPath: String?
    private var ignoreTrackerUpdatesUntil: Date?

    // MARK: - Tracking

    func startTracking(projects: [Project]) async {
        await terminalTracker.startTracking(projects: projects)
        startTrackerPolling()
    }

    func updateProjectMapping(_ projects: [Project]) {
        _Concurrency.Task {
            await terminalTracker.updateProjectMapping(projects)
        }
    }

    private func startTrackerPolling() {
        trackerUpdateTask = _Concurrency.Task { @MainActor [weak self] in
            while !_Concurrency.Task.isCancelled {
                guard let self else { break }

                if let pauseUntil = self.ignoreTrackerUpdatesUntil {
                    if Date() < pauseUntil {
                        try? await _Concurrency.Task.sleep(nanoseconds: Constants.pollingIntervalNanos)
                        continue
                    }
                    self.ignoreTrackerUpdatesUntil = nil
                }

                if let path = await self.terminalTracker.getActiveProjectPath() {
                    self.activeProjectPath = path
                }

                try? await _Concurrency.Task.sleep(nanoseconds: Constants.pollingIntervalNanos)
            }
        }
    }

    private func setActiveProject(_ path: String) {
        activeProjectPath = path
        ignoreTrackerUpdatesUntil = Date().addingTimeInterval(Constants.trackerPauseSeconds)
    }

    // MARK: - Terminal Activation

    func activateTerminalApp() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isTerminalApp(frontmost) {
            frontmost.activate()
            return
        }
        activateTerminalInPriorityOrder()
    }

    private func isTerminalApp(_ app: NSRunningApplication) -> Bool {
        guard let name = app.localizedName else { return false }
        return TerminalApp.priorityOrder.contains { terminal in
            name.contains(terminal.displayName)
        }
    }

    private func activateTerminalInPriorityOrder() {
        for terminal in TerminalApp.priorityOrder {
            guard terminal.isInstalled else { continue }

            if let app = findRunningTerminal(terminal) {
                app.activate()
                return
            }
        }
    }

    private func findRunningTerminal(_ terminal: TerminalApp) -> NSRunningApplication? {
        let targetName = terminal.displayName.lowercased()
        return NSWorkspace.shared.runningApplications.first { app in
            app.localizedName?.lowercased().contains(targetName) == true
        }
    }

    // MARK: - Terminal Launch

    func launchTerminal(for project: Project) {
        setActiveProject(project.path)
        _Concurrency.Task {
            let claudePath = await getClaudePath()
            runBashScript(TerminalScripts.launch(project: project, claudePath: claudePath))
            scheduleTerminalActivation()
        }
    }

    private func getClaudePath() async -> String {
        if let path = await CapacitorConfig.shared.getClaudePath() {
            return path
        }
        return "/opt/homebrew/bin/claude"
    }

    private func runBashScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        // GUI apps don't inherit shell PATH - ensure common install locations are available
        var env = ProcessInfo.processInfo.environment
        let homebrewPaths = "/opt/homebrew/bin:/usr/local/bin"
        if let existingPath = env["PATH"] {
            env["PATH"] = "\(homebrewPaths):\(existingPath)"
        } else {
            env["PATH"] = homebrewPaths
        }
        process.environment = env

        try? process.run()
    }

    private func scheduleTerminalActivation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.activationDelaySeconds) { [weak self] in
            self?.activateTerminalApp()
        }
    }
}

// MARK: - Terminal Scripts

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
