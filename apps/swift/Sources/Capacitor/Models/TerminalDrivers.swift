import Foundation

protocol TerminalDriver: AnyObject {
    var app: SupportedTerminalApp { get }
    var lastFailureReason: TerminalActivationFailureReason? { get }

    func focus(
        clientTty: String?,
        projectPath: String,
        tmuxSessionHint: String?,
    ) async -> TerminalActivationCoordinator.TerminalFocusResult

    func launch(command: String, projectPath: String?) async -> Bool
    func launchCommandScript(projectPath: String, command: String) -> String
}

final class GhosttyTerminalDriver: TerminalDriver {
    let app: SupportedTerminalApp = .ghostty
    private let automationClient: GhosttyAutomationClient
    private let isRunning: () -> Bool
    private var terminalIDByClientTTY: [String: String] = [:]

    private(set) var lastFailureReason: TerminalActivationFailureReason?

    init(
        automationClient: GhosttyAutomationClient,
        isRunning: @escaping () -> Bool,
    ) {
        self.automationClient = automationClient
        self.isRunning = isRunning
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

            // When a tmux session hint is present, skip the cached terminal ID.
            // The cache may point to a non-tmux terminal from a prior activation
            // that matched by CWD while using this same tmux client TTY.
            let preferredID = tmuxSessionHint != nil ? nil : cachedTerminalID

            if let route = bestGhosttyRouteMatch(
                snapshot: snapshot,
                projectPath: projectPath,
                tmuxSessionHint: tmuxSessionHint,
                preferredTerminalID: preferredID,
            ) {
                // When clientTty is nil (direct focus), skip CWD matches in the
                // already-selected tab — the CWD may be stale from a prior tmux
                // session, and re-focusing the visible tab is a no-op that would
                // incorrectly short-circuit ensureAndSwitch.
                let isStaleDirectFocusMatch = resolvedTty == nil
                    && route.source == .terminalWorkingDirectory
                    && route.tab?.isSelected == true

                if !isStaleDirectFocusMatch, executeRoute(route, clientTty: resolvedTty) {
                    return .focused
                }

                if preferredID != nil, let resolvedTty {
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

            // No match on initial snapshot. After tmux switch-client, the terminal
            // title may not have propagated yet — re-read the snapshot after a delay.
            if tmuxSessionHint != nil {
                try? await _Concurrency.Task.sleep(nanoseconds: 300_000_000)

                if case let .success(retrySnapshot) = automationClient.readSnapshot(),
                   !retrySnapshot.windows.isEmpty,
                   let route = bestGhosttyRouteMatch(
                       snapshot: retrySnapshot,
                       projectPath: projectPath,
                       tmuxSessionHint: tmuxSessionHint,
                       preferredTerminalID: nil,
                   ),
                   executeRoute(route, clientTty: resolvedTty)
                {
                    return .focused
                }
            }

            if let resolvedTty {
                terminalIDByClientTTY.removeValue(forKey: resolvedTty)
            }

            return .relaunchNeeded
        }
    }

    func launch(command: String, projectPath: String?) async -> Bool {
        lastFailureReason = nil

        switch automationClient.supportStatus() {
        case .supported:
            break
        case let .unsupported(reason):
            lastFailureReason = reason
            return false
        }

        let configuration = ghosttyLaunchConfiguration(
            projectPath: projectPath,
            command: command,
        )

        if isRunning() {
            switch automationClient.readSnapshot() {
            case let .success(snapshot):
                if let targetWindowID = reusableWindowID(from: snapshot) {
                    switch automationClient.createTab(inWindowID: targetWindowID, configuration: configuration) {
                    case .success:
                        return true
                    case let .failure(reason):
                        lastFailureReason = reason
                        return false
                    }
                }
            case .failure:
                break
            }
        }

        switch automationClient.createWindow(configuration: configuration) {
        case .success:
            return true
        case let .failure(reason):
            lastFailureReason = reason
            return false
        }
    }

    func launchCommandScript(projectPath: String, command: String) -> String {
        terminalLaunchCommandScript(
            app: app,
            projectPath: projectPath,
            command: command,
            isRunning: isRunning(),
        )
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
                // Only cache the terminal ID when the match source indicates this
                // terminal actually hosts the tmux client. CWD matches can find
                // non-tmux terminals that happen to share the project path.
                if let clientTty,
                   route.source == .sessionHint || route.source == .cachedTerminalID
                {
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

    private func reusableWindowID(from snapshot: GhosttyAppSnapshot) -> String? {
        snapshot.windows.first(where: \.isFront)?.id ?? snapshot.windows.first?.id
    }
}

final class ITermTerminalDriver: TerminalDriver {
    let app: SupportedTerminalApp = .iTerm
    private let appleScript: AppleScriptClient
    private let isRunning: () -> Bool
    private let runShell: (String) async -> (exitCode: Int32, output: String?)

    private(set) var lastFailureReason: TerminalActivationFailureReason?

    init(
        appleScript: AppleScriptClient,
        isRunning: @escaping () -> Bool,
        runShell: @escaping (String) async -> (exitCode: Int32, output: String?),
    ) {
        self.appleScript = appleScript
        self.isRunning = isRunning
        self.runShell = runShell
    }

    func focus(
        clientTty: String?,
        projectPath _: String,
        tmuxSessionHint _: String?,
    ) async -> TerminalActivationCoordinator.TerminalFocusResult {
        lastFailureReason = nil

        guard let resolvedTTY = clientTty?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else {
            return .relaunchNeeded
        }

        guard isRunning() else {
            DebugLog.write("[ITermTerminalDriver] not running tty=\(resolvedTTY)")
            return .relaunchNeeded
        }

        switch hostFocusResult(
            app: app,
            result: appleScript.runOutput(iTermFocusScript(for: resolvedTTY)),
        ) {
        case .success(true):
            DebugLog.write("[ITermTerminalDriver] tty=\(resolvedTTY) matched=true")
            return .focused
        case .success(false):
            DebugLog.write("[ITermTerminalDriver] tty=\(resolvedTTY) matched=false")
            return .relaunchNeeded
        case let .failure(reason):
            lastFailureReason = reason
            DebugLog.write("[ITermTerminalDriver] tty=\(resolvedTTY) focusFailed reason=\(reason)")
            return .failed(reason)
        }
    }

    func launch(command: String, projectPath: String?) async -> Bool {
        lastFailureReason = nil

        switch await runHostLaunch(
            app: app,
            isRunning: isRunning(),
            command: command,
            projectPath: projectPath,
            runShell: runShell,
        ) {
        case .success:
            return true
        case let .failure(reason):
            lastFailureReason = reason
            return false
        }
    }

    func launchCommandScript(projectPath: String, command: String) -> String {
        iTermLaunchCommandScript(
            projectPath: projectPath,
            command: command,
            isRunning: isRunning(),
        )
    }
}

final class TerminalAppTerminalDriver: TerminalDriver {
    let app: SupportedTerminalApp = .terminal
    private let appleScript: AppleScriptClient
    private let isRunning: () -> Bool
    private let runShell: (String) async -> (exitCode: Int32, output: String?)

    private(set) var lastFailureReason: TerminalActivationFailureReason?

    init(
        appleScript: AppleScriptClient,
        isRunning: @escaping () -> Bool,
        runShell: @escaping (String) async -> (exitCode: Int32, output: String?),
    ) {
        self.appleScript = appleScript
        self.isRunning = isRunning
        self.runShell = runShell
    }

    func focus(
        clientTty: String?,
        projectPath _: String,
        tmuxSessionHint _: String?,
    ) async -> TerminalActivationCoordinator.TerminalFocusResult {
        lastFailureReason = nil

        guard let resolvedTTY = clientTty?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else {
            return .relaunchNeeded
        }

        guard isRunning() else {
            DebugLog.write("[TerminalAppTerminalDriver] not running tty=\(resolvedTTY)")
            return .relaunchNeeded
        }

        switch hostFocusResult(
            app: app,
            result: appleScript.runOutput(terminalAppFocusScript(for: resolvedTTY)),
        ) {
        case .success(true):
            DebugLog.write("[TerminalAppTerminalDriver] tty=\(resolvedTTY) matched=true")
            return .focused
        case .success(false):
            DebugLog.write("[TerminalAppTerminalDriver] tty=\(resolvedTTY) matched=false")
            return .relaunchNeeded
        case let .failure(reason):
            lastFailureReason = reason
            DebugLog.write("[TerminalAppTerminalDriver] tty=\(resolvedTTY) focusFailed reason=\(reason)")
            return .failed(reason)
        }
    }

    func launch(command: String, projectPath: String?) async -> Bool {
        lastFailureReason = nil

        switch await runHostLaunch(
            app: app,
            isRunning: isRunning(),
            command: command,
            projectPath: projectPath,
            runShell: runShell,
        ) {
        case .success:
            return true
        case let .failure(reason):
            lastFailureReason = reason
            return false
        }
    }

    func launchCommandScript(projectPath: String, command: String) -> String {
        terminalAppLaunchCommandScript(
            projectPath: projectPath,
            command: command,
            isRunning: isRunning(),
        )
    }
}

private func hostFocusResult(
    app: SupportedTerminalApp,
    result: AppleScriptExecutionResult,
) -> Result<Bool, TerminalActivationFailureReason> {
    guard result.success else {
        return .failure(.hostOperationFailed(
            app: app,
            operation: .focusByTTY,
            detail: cleanFailureDetail(result.error),
        ))
    }

    guard let output = cleanFailureDetail(result.output)?.lowercased() else {
        return .failure(.hostOperationFailed(
            app: app,
            operation: .focusByTTY,
            detail: "Missing AppleScript boolean result",
        ))
    }

    switch output {
    case "true":
        return .success(true)
    case "false":
        return .success(false)
    default:
        return .failure(.hostOperationFailed(
            app: app,
            operation: .focusByTTY,
            detail: "Unexpected AppleScript boolean result: \(output)",
        ))
    }
}

private func ghosttyLaunchConfiguration(projectPath: String?, command: String) -> GhosttySurfaceConfigurationOptions {
    GhosttySurfaceConfigurationOptions(
        initialWorkingDirectory: projectPath,
        initialInput: command,
    )
}

func terminalLaunchCommandScript(
    app: SupportedTerminalApp,
    projectPath: String,
    command: String,
    isRunning: Bool,
) -> String {
    switch app {
    case .ghostty:
        ghosttyCreateWindowShellScript(configuration: ghosttyLaunchConfiguration(
            projectPath: projectPath,
            command: command,
        ))
    case .iTerm:
        iTermLaunchCommandScript(
            projectPath: projectPath,
            command: command,
            isRunning: isRunning,
        )
    case .terminal:
        terminalAppLaunchCommandScript(
            projectPath: projectPath,
            command: command,
            isRunning: isRunning,
        )
    }
}

private func iTermFocusScript(for tty: String) -> String {
    let escapedTTY = tty
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")

    return """
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if tty of s is "\(escapedTTY)" then
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
}

private func terminalAppFocusScript(for tty: String) -> String {
    let escapedTTY = tty
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")

    return """
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(escapedTTY)" then
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

private func hostTerminalOpenCommand(
    app: SupportedTerminalApp,
    projectPath: String?,
) -> String {
    if let projectPath {
        return "open -b \(app.bundleId) \(shellEscape(projectPath))"
    }
    return "open -b \(app.bundleId)"
}

private func hostTerminalSendCommandScript(
    app: SupportedTerminalApp,
    command: String,
    isRunning: Bool,
) -> String {
    let delay = isRunning ? 1.0 : 2.5
    let escapedCommand = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")

    let applescriptBody = switch app {
    case .ghostty:
        ""
    case .iTerm:
        """
        tell application "iTerm"
            tell current session of current window
                write text "\(escapedCommand)"
            end tell
        end tell
        """
    case .terminal:
        """
        tell application "Terminal"
            do script "\(escapedCommand)" in front window
        end tell
        """
    }

    return """
    osascript <<'APPLESCRIPT'
    delay \(delay)
    \(applescriptBody)
    APPLESCRIPT
    """
}

private func iTermLaunchCommandScript(
    projectPath: String,
    command: String,
    isRunning: Bool,
) -> String {
    hostTerminalLaunchCommandScript(
        app: .iTerm,
        projectPath: projectPath,
        command: command,
        isRunning: isRunning,
    )
}

private func terminalAppLaunchCommandScript(
    projectPath: String,
    command: String,
    isRunning: Bool,
) -> String {
    hostTerminalLaunchCommandScript(
        app: .terminal,
        projectPath: projectPath,
        command: command,
        isRunning: isRunning,
    )
}

private func hostTerminalLaunchCommandScript(
    app: SupportedTerminalApp,
    projectPath: String,
    command: String,
    isRunning: Bool,
) -> String {
    """
    \(hostTerminalOpenCommand(app: app, projectPath: projectPath))

    \(hostTerminalSendCommandScript(app: app, command: command, isRunning: isRunning))
    """
}

private func runHostLaunch(
    app: SupportedTerminalApp,
    isRunning: Bool,
    command: String,
    projectPath: String?,
    runShell: (String) async -> (exitCode: Int32, output: String?),
) async -> Result<Void, TerminalActivationFailureReason> {
    let openResult = await runShell(hostTerminalOpenCommand(app: app, projectPath: projectPath))
    guard openResult.exitCode == 0 else {
        return .failure(.hostOperationFailed(
            app: app,
            operation: .openApplication,
            detail: hostShellFailureDetail(openResult),
        ))
    }

    let sendCommandResult = await runShell(hostTerminalSendCommandScript(
        app: app,
        command: command,
        isRunning: isRunning,
    ))
    guard sendCommandResult.exitCode == 0 else {
        return .failure(.hostOperationFailed(
            app: app,
            operation: .sendCommand,
            detail: hostShellFailureDetail(sendCommandResult),
        ))
    }

    return .success(())
}

private func hostShellFailureDetail(_ result: (exitCode: Int32, output: String?)) -> String? {
    if let output = cleanFailureDetail(result.output) {
        return output
    }
    return "Command exited with status \(result.exitCode)"
}

struct TerminalDriverRegistry {
    private let ghostty: GhosttyTerminalDriver
    private let iTerm: ITermTerminalDriver
    private let terminal: TerminalAppTerminalDriver

    init(
        appleScript: AppleScriptClient,
        ghosttyAutomationClient: GhosttyAutomationClient,
        isTerminalRunning: @escaping (SupportedTerminalApp) -> Bool,
        runShell: @escaping (String) async -> (exitCode: Int32, output: String?),
    ) {
        ghostty = GhosttyTerminalDriver(
            automationClient: ghosttyAutomationClient,
            isRunning: { isTerminalRunning(.ghostty) },
        )
        iTerm = ITermTerminalDriver(
            appleScript: appleScript,
            isRunning: { isTerminalRunning(.iTerm) },
            runShell: runShell,
        )
        terminal = TerminalAppTerminalDriver(
            appleScript: appleScript,
            isRunning: { isTerminalRunning(.terminal) },
            runShell: runShell,
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
