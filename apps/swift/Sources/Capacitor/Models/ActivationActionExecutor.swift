import Foundation

@MainActor
protocol ActivationActionDependencies: AnyObject {
    func activateByTty(tty: String, terminalType: TerminalType, projectPath: String?) async -> Bool
    func activateApp(appName: String) -> Bool
    func activateKittyWindow(shellPid: UInt32) -> Bool
    func activateIdeWindow(ideType: IdeType, projectPath: String) async -> Bool
    func switchTmuxSession(sessionName: String, projectPath: String) async -> Bool
    func ensureTmuxSession(sessionName: String, projectPath: String) async -> Bool
    func ensureTmuxSession(sessionName: String, projectPath: String, preferredClientTty: String?) async -> Bool
    func activateHostThenSwitchTmux(hostTty: String, sessionName: String, projectPath: String) async -> Bool
    func launchTerminalWithTmux(sessionName: String, projectPath: String) -> Bool
    func launchNewTerminal(projectPath: String, projectName: String) -> Bool
    func activatePriorityFallback() -> Bool
}

extension ActivationActionDependencies {
    func ensureTmuxSession(sessionName: String, projectPath: String, preferredClientTty _: String?) async -> Bool {
        await ensureTmuxSession(sessionName: sessionName, projectPath: projectPath)
    }
}

protocol TmuxClient {
    func hasAnyClientAttached() async -> Bool
    func getCurrentClientTty() async -> String?
    func switchClient(to sessionName: String, clientTty: String?) async -> Bool
}

@MainActor
protocol TerminalDiscovery {
    func activateTerminalByTTY(tty: String) async -> Bool
    func activateAppByName(_ appName: String) -> Bool
    func ghosttyWindowState() -> GhosttyWindowState
    func activateGhostty(projectPath: String?) async -> Bool
}

enum GhosttyWindowState: Equatable {
    case notRunning
    case axUnavailable
    case running
}

@MainActor
protocol TerminalLauncherClient {
    func launchTerminalWithTmux(sessionName: String)
}

@MainActor
final class ActivationActionExecutor {
    private weak var dependencies: ActivationActionDependencies?
    private let tmuxClient: TmuxClient
    private let terminalDiscovery: TerminalDiscovery
    private let terminalLauncher: TerminalLauncherClient

    init(
        dependencies: ActivationActionDependencies,
        tmuxClient: TmuxClient,
        terminalDiscovery: TerminalDiscovery,
        terminalLauncher: TerminalLauncherClient,
    ) {
        self.dependencies = dependencies
        self.tmuxClient = tmuxClient
        self.terminalDiscovery = terminalDiscovery
        self.terminalLauncher = terminalLauncher
    }

    func execute(_ action: ActivationAction, projectPath: String, projectName _: String) async -> Bool {
        guard let deps = dependencies else {
            return false
        }

        switch action {
        case let .activateByTty(tty, terminalType):
            return await deps.activateByTty(
                tty: tty,
                terminalType: terminalType,
                projectPath: projectPath,
            )
        case let .activateApp(appName):
            if appName.caseInsensitiveCompare("Ghostty") == .orderedSame {
                return await terminalDiscovery.activateGhostty(projectPath: projectPath)
            }
            return deps.activateApp(appName: appName)
        case let .activateKittyWindow(shellPid):
            return deps.activateKittyWindow(shellPid: shellPid)
        case let .activateIdeWindow(ideType, path):
            return await deps.activateIdeWindow(ideType: ideType, projectPath: path)
        case let .switchTmuxSession(sessionName):
            return await deps.switchTmuxSession(sessionName: sessionName, projectPath: projectPath)
        case let .ensureTmuxSession(sessionName, path):
            return await deps.ensureTmuxSession(sessionName: sessionName, projectPath: path)
        case let .activateHostThenSwitchTmux(hostTty, sessionName):
            return await activateHostThenSwitchTmux(
                hostTty: hostTty,
                sessionName: sessionName,
                projectPath: projectPath,
            )
        case let .launchTerminalWithTmux(sessionName, path):
            return deps.launchTerminalWithTmux(sessionName: sessionName, projectPath: path)
        case let .launchNewTerminal(path, name):
            return deps.launchNewTerminal(projectPath: path, projectName: name)
        case .activatePriorityFallback:
            return deps.activatePriorityFallback()
        case .skip:
            return true
        }
    }

    // MARK: - Host + Tmux Switching

    func activateHostThenSwitchTmux(
        hostTty: String,
        sessionName: String,
        projectPath: String,
    ) async -> Bool {
        guard let deps = dependencies else {
            return false
        }

        let anyClientAttached = await tmuxClient.hasAnyClientAttached()
        if !anyClientAttached {
            switch terminalDiscovery.ghosttyWindowState() {
            case .notRunning:
                terminalLauncher.launchTerminalWithTmux(sessionName: sessionName)
                return true
            case .axUnavailable, .running:
                let activatedGhostty = await terminalDiscovery.activateGhostty(projectPath: projectPath)
                if !activatedGhostty {
                    return await deps.ensureTmuxSession(sessionName: sessionName, projectPath: projectPath)
                }

                let heuristicClientTty = hostTty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : hostTty
                if await tmuxClient.switchClient(to: sessionName, clientTty: heuristicClientTty) {
                    return true
                }

                // Stale host TTY evidence can point to a detached/non-existent client.
                // Recover through ensure semantics so upstream does not fall back to
                // generic launch-new-terminal behavior.
                return await deps.ensureTmuxSession(sessionName: sessionName, projectPath: projectPath)
            }
        }

        let freshTty = await tmuxClient.getCurrentClientTty() ?? hostTty
        let ttyActivated = await terminalDiscovery.activateTerminalByTTY(tty: freshTty)
        if ttyActivated {
            if await tmuxClient.switchClient(to: sessionName, clientTty: freshTty) {
                return true
            }

            // If switch-client fails due to a missing session, recover by
            // ensuring the session exists instead of failing activation.
            return await deps.ensureTmuxSession(
                sessionName: sessionName,
                projectPath: projectPath,
                preferredClientTty: freshTty,
            )
        }

        switch terminalDiscovery.ghosttyWindowState() {
        case .notRunning:
            return await deps.ensureTmuxSession(sessionName: sessionName, projectPath: projectPath)
        case .axUnavailable, .running:
            let activatedGhostty = await terminalDiscovery.activateGhostty(projectPath: projectPath)
            if !activatedGhostty {
                return await deps.ensureTmuxSession(
                    sessionName: sessionName,
                    projectPath: projectPath,
                    preferredClientTty: freshTty,
                )
            }

            if await tmuxClient.switchClient(to: sessionName, clientTty: freshTty) {
                return true
            }
            return await deps.ensureTmuxSession(
                sessionName: sessionName,
                projectPath: projectPath,
                preferredClientTty: freshTty,
            )
        }
    }
}
