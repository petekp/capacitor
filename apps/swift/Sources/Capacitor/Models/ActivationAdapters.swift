import Foundation

@MainActor
struct TmuxClientAdapter: TmuxClient {
    let hasAnyClientAttachedHandler: () async -> Bool
    let getCurrentClientTtyHandler: () async -> String?
    let switchClientHandler: (String, String?) async -> Bool

    init(
        hasAnyClientAttached: @escaping () async -> Bool,
        getCurrentClientTty: @escaping () async -> String?,
        switchClient: @escaping (String, String?) async -> Bool,
    ) {
        hasAnyClientAttachedHandler = hasAnyClientAttached
        getCurrentClientTtyHandler = getCurrentClientTty
        switchClientHandler = switchClient
    }

    func hasAnyClientAttached() async -> Bool {
        await hasAnyClientAttachedHandler()
    }

    func getCurrentClientTty() async -> String? {
        await getCurrentClientTtyHandler()
    }

    func switchClient(to sessionName: String, clientTty: String?) async -> Bool {
        await switchClientHandler(sessionName, clientTty)
    }
}

@MainActor
struct TerminalDiscoveryAdapter: TerminalDiscovery {
    let activateTerminalByTTYHandler: (String) async -> Bool
    let activateAppByNameHandler: (String) -> Bool
    let ghosttyWindowStateHandler: () -> GhosttyWindowState
    let activateGhosttyHandler: (String?) async -> Bool

    init(
        activateTerminalByTTY: @escaping (String) async -> Bool,
        activateAppByName: @escaping (String) -> Bool,
        ghosttyWindowState: @escaping () -> GhosttyWindowState,
        activateGhostty: @escaping (String?) async -> Bool,
    ) {
        activateTerminalByTTYHandler = activateTerminalByTTY
        activateAppByNameHandler = activateAppByName
        ghosttyWindowStateHandler = ghosttyWindowState
        activateGhosttyHandler = activateGhostty
    }

    func activateTerminalByTTY(tty: String) async -> Bool {
        await activateTerminalByTTYHandler(tty)
    }

    func activateAppByName(_ appName: String) -> Bool {
        activateAppByNameHandler(appName)
    }

    func ghosttyWindowState() -> GhosttyWindowState {
        ghosttyWindowStateHandler()
    }

    func activateGhostty(projectPath: String?) async -> Bool {
        await activateGhosttyHandler(projectPath)
    }
}

@MainActor
struct TerminalLauncherAdapter: TerminalLauncherClient {
    let launchTerminalWithTmuxHandler: (String) -> Void

    init(launchTerminalWithTmux: @escaping (String) -> Void) {
        launchTerminalWithTmuxHandler = launchTerminalWithTmux
    }

    func launchTerminalWithTmux(sessionName: String) {
        launchTerminalWithTmuxHandler(sessionName)
    }
}
