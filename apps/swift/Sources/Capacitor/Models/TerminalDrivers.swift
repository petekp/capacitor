import Foundation

protocol TerminalDriver: AnyObject {
    var app: SupportedTerminalApp { get }
    var lastFailureReason: TerminalActivationFailureReason? { get }

    func focus(
        clientTty: String?,
        projectPath: String,
        tmuxSessionHint: String?,
    ) async -> TerminalActivationCoordinator.TerminalFocusResult

    func launch(command: String, projectPath: String?) -> Bool
    func launchCommandScript(projectPath: String, command: String) -> String
}

final class GhosttyTerminalDriver: TerminalDriver {
    let app: SupportedTerminalApp = .ghostty
    private let automationClient: GhosttyAutomationClient
    private let isRunning: () -> Bool
    private let activateApp: () -> Bool
    private let runBashScript: (String) -> Void
    private var terminalIDByClientTTY: [String: String] = [:]

    private(set) var lastFailureReason: TerminalActivationFailureReason?

    init(
        automationClient: GhosttyAutomationClient,
        isRunning: @escaping () -> Bool,
        activateApp: @escaping () -> Bool,
        runBashScript: @escaping (String) -> Void,
    ) {
        self.automationClient = automationClient
        self.isRunning = isRunning
        self.activateApp = activateApp
        self.runBashScript = runBashScript
    }

    func focus(
        clientTty: String?,
        projectPath: String,
        tmuxSessionHint: String?,
    ) async -> TerminalActivationCoordinator.TerminalFocusResult {
        lastFailureReason = nil
        let resolvedTty = clientTty?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        guard isRunning() else {
            DebugLog.write("[GhosttyTerminalDriver] ghostty not running tty=\(resolvedTty ?? "<none>")")
            return .relaunchNeeded
        }

        switch automationClient.readSnapshot() {
        case let .failure(reason):
            lastFailureReason = reason
            return .failed(reason)
        case let .success(snapshot):
            guard !snapshot.windows.isEmpty else {
                return .relaunchNeeded
            }

            let cachedTerminalID = resolvedTty.flatMap { terminalIDByClientTTY[$0] }
            if let route = bestGhosttyRouteMatch(
                snapshot: snapshot,
                projectPath: projectPath,
                tmuxSessionHint: tmuxSessionHint,
                preferredTerminalID: cachedTerminalID,
            ) {
                if executeRoute(route, clientTty: resolvedTty) {
                    return .focused
                }

                if cachedTerminalID != nil, let resolvedTty {
                    terminalIDByClientTTY.removeValue(forKey: resolvedTty)
                    if let fallbackRoute = bestGhosttyRouteMatch(
                        snapshot: snapshot,
                        projectPath: projectPath,
                        tmuxSessionHint: tmuxSessionHint,
                        preferredTerminalID: nil,
                    ), executeRoute(fallbackRoute, clientTty: resolvedTty) {
                        return .focused
                    }
                }
            }

            if let resolvedTty {
                terminalIDByClientTTY.removeValue(forKey: resolvedTty)
            }

            return .relaunchNeeded
        }
    }

    func launch(command: String, projectPath: String?) -> Bool {
        lastFailureReason = nil

        switch automationClient.supportStatus() {
        case .supported:
            break
        case let .unsupported(reason):
            lastFailureReason = reason
            return false
        }

        if isRunning() {
            if let path = projectPath {
                runBashScript("open -a Ghostty.app \(shellEscape(path))")
            } else {
                runBashScript("open -a Ghostty.app")
            }

            let applescriptSafe = command
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
            return true
        }

        let escapedTmuxCmd = bashDoubleQuoteEscape(command)
        runBashScript("open -a Ghostty.app --args -e sh -c \"\(escapedTmuxCmd)\"")
        return true
    }

    func launchCommandScript(projectPath: String, command: String) -> String {
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

    private func executeRoute(_ route: GhosttyRouteMatch, clientTty: String?) -> Bool {
        if let terminal = route.terminal,
           let tab = route.tab
        {
            if !tab.isSelected {
                switch automationClient.selectTab(id: tab.id, inWindowID: route.window.id) {
                case .success:
                    break
                case let .failure(reason):
                    lastFailureReason = reason
                    return false
                }
            }

            switch automationClient.focusTerminal(id: terminal.id) {
            case .success:
                if let clientTty {
                    terminalIDByClientTTY[clientTty] = terminal.id
                }
                return true
            case let .failure(reason):
                lastFailureReason = reason
                return false
            }
        }

        switch automationClient.activateWindow(id: route.window.id) {
        case .success:
            return true
        case let .failure(reason):
            lastFailureReason = reason
            return false
        }
    }
}

final class ScriptedTerminalDriver: TerminalDriver {
    let app: SupportedTerminalApp
    private let appleScript: AppleScriptClient
    private let isRunning: () -> Bool
    private let activateApp: () -> Bool
    private let runBashScript: (String) -> Void

    private(set) var lastFailureReason: TerminalActivationFailureReason?

    init(
        app: SupportedTerminalApp,
        appleScript: AppleScriptClient,
        isRunning: @escaping () -> Bool,
        activateApp: @escaping () -> Bool,
        runBashScript: @escaping (String) -> Void,
    ) {
        self.app = app
        self.appleScript = appleScript
        self.isRunning = isRunning
        self.activateApp = activateApp
        self.runBashScript = runBashScript
    }

    func focus(
        clientTty: String?,
        projectPath _: String,
        tmuxSessionHint _: String?,
    ) async -> TerminalActivationCoordinator.TerminalFocusResult {
        lastFailureReason = nil

        if let clientTty, focusTerminalTabByTty(clientTty) {
            return .focused
        }

        _ = activateApp()
        return .relaunchNeeded
    }

    func launch(command: String, projectPath: String?) -> Bool {
        lastFailureReason = nil
        let isRunning = isRunning()
        if let path = projectPath {
            runBashScript("open -b \(app.bundleId) \(shellEscape(path))")
        } else {
            runBashScript("open -b \(app.bundleId)")
        }

        let delay = isRunning ? 1.0 : 2.5
        let applescriptSafe = command
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
        return true
    }

    func launchCommandScript(projectPath: String, command: String) -> String {
        let escapedPath = bashDoubleQuoteEscape(projectPath)
        let escapedCommand = bashDoubleQuoteEscape(command)
        let delay = isRunning() ? "1.0" : "2.5"

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

    private func focusTerminalTabByTty(_ tty: String) -> Bool {
        guard isRunning() else {
            DebugLog.write("[ScriptedTerminalDriver] app=\(app.processName) not running tty=\(tty)")
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

        let matched = appleScript.runBoolean(script) == true
        DebugLog.write("[ScriptedTerminalDriver] app=\(app.processName) tty=\(tty) matched=\(matched)")
        return matched
    }
}

struct TerminalDriverRegistry {
    private let ghostty: GhosttyTerminalDriver
    private let iTerm: ScriptedTerminalDriver
    private let terminal: ScriptedTerminalDriver

    init(
        appleScript: AppleScriptClient,
        ghosttyAutomationClient: GhosttyAutomationClient,
        isTerminalRunning: @escaping (SupportedTerminalApp) -> Bool,
        activateApp: @escaping (SupportedTerminalApp) -> Bool,
        runBashScript: @escaping (String) -> Void,
    ) {
        ghostty = GhosttyTerminalDriver(
            automationClient: ghosttyAutomationClient,
            isRunning: { isTerminalRunning(.ghostty) },
            activateApp: { activateApp(.ghostty) },
            runBashScript: runBashScript,
        )
        iTerm = ScriptedTerminalDriver(
            app: .iTerm,
            appleScript: appleScript,
            isRunning: { isTerminalRunning(.iTerm) },
            activateApp: { activateApp(.iTerm) },
            runBashScript: runBashScript,
        )
        terminal = ScriptedTerminalDriver(
            app: .terminal,
            appleScript: appleScript,
            isRunning: { isTerminalRunning(.terminal) },
            activateApp: { activateApp(.terminal) },
            runBashScript: runBashScript,
        )
    }

    func driver(for app: SupportedTerminalApp) -> TerminalDriver {
        switch app {
        case .ghostty:
            ghostty
        case .iTerm:
            iTerm
        case .terminal:
            terminal
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
