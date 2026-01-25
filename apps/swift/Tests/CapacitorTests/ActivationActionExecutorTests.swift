@testable import Capacitor
import XCTest

@MainActor
final class ActivationActionExecutorTests: XCTestCase {
    private final class StubDependencies: ActivationActionDependencies {
        var lastAction: String?
        var lastTty: String?
        var lastTerminalType: TerminalType?
        var lastAppName: String?
        var lastSessionName: String?
        var lastProjectPath: String?
        var lastProjectName: String?
        var lastIdeType: IdeType?
        var lastPreferredClientTty: String?

        var activateByTtyResult = true
        var activateAppResult = true
        var activateKittyResult = true
        var activateIdeResult = true
        var switchTmuxResult = true
        var ensureTmuxResult = true
        var activateHostThenSwitchResult = true
        var launchWithTmuxResult = true
        var launchNewResult = true
        var activateFallbackResult = true

        func activateByTty(tty: String, terminalType: TerminalType, projectPath: String?) async -> Bool {
            lastAction = "activateByTty"
            lastTty = tty
            lastTerminalType = terminalType
            lastProjectPath = projectPath
            return activateByTtyResult
        }

        func activateApp(appName: String) -> Bool {
            lastAction = "activateApp"
            lastAppName = appName
            return activateAppResult
        }

        func activateKittyWindow(shellPid _: UInt32) -> Bool {
            lastAction = "activateKittyWindow"
            return activateKittyResult
        }

        func activateIdeWindow(ideType: IdeType, projectPath: String) async -> Bool {
            lastAction = "activateIdeWindow"
            lastIdeType = ideType
            lastProjectPath = projectPath
            return activateIdeResult
        }

        func switchTmuxSession(sessionName: String, projectPath: String) async -> Bool {
            lastAction = "switchTmuxSession"
            lastSessionName = sessionName
            lastProjectPath = projectPath
            return switchTmuxResult
        }

        func ensureTmuxSession(sessionName: String, projectPath: String) async -> Bool {
            lastAction = "ensureTmuxSession"
            lastSessionName = sessionName
            lastProjectPath = projectPath
            lastPreferredClientTty = nil
            return ensureTmuxResult
        }

        func ensureTmuxSession(
            sessionName: String,
            projectPath: String,
            preferredClientTty: String?,
        ) async -> Bool {
            lastAction = "ensureTmuxSession"
            lastSessionName = sessionName
            lastProjectPath = projectPath
            lastPreferredClientTty = preferredClientTty
            return ensureTmuxResult
        }

        func activateHostThenSwitchTmux(hostTty _: String, sessionName: String, projectPath: String) async -> Bool {
            lastAction = "activateHostThenSwitchTmux"
            lastSessionName = sessionName
            lastProjectPath = projectPath
            return activateHostThenSwitchResult
        }

        func launchTerminalWithTmux(sessionName: String, projectPath: String) -> Bool {
            lastAction = "launchTerminalWithTmux"
            lastSessionName = sessionName
            lastProjectPath = projectPath
            return launchWithTmuxResult
        }

        func launchNewTerminal(projectPath: String, projectName: String) -> Bool {
            lastAction = "launchNewTerminal"
            lastProjectPath = projectPath
            lastProjectName = projectName
            return launchNewResult
        }

        func activatePriorityFallback() -> Bool {
            lastAction = "activatePriorityFallback"
            return activateFallbackResult
        }
    }

    private final class StubTmuxClient: TmuxClient {
        var hasClientAttached = true
        var currentClientTty: String? = "/dev/ttys001"
        var switchResult = true
        var lastSwitchedClientTty: String?

        func hasAnyClientAttached() async -> Bool {
            hasClientAttached
        }

        func getCurrentClientTty() async -> String? {
            currentClientTty
        }

        func switchClient(to _: String, clientTty: String?) async -> Bool {
            lastSwitchedClientTty = clientTty
            return switchResult
        }
    }

    @MainActor
    private final class StubTerminalDiscovery: TerminalDiscovery {
        var activateByTtyResult = true
        var activateAppResult = true
        var lastActivatedApp: String?
        var ghosttyState: GhosttyWindowState = .notRunning
        var activateGhosttyResult = true
        var lastActivatedGhosttyProjectPath: String?
        var activateGhosttyCallCount = 0

        func activateTerminalByTTY(tty _: String) async -> Bool {
            activateByTtyResult
        }

        func activateAppByName(_ appName: String) -> Bool {
            lastActivatedApp = appName
            return activateAppResult
        }

        func ghosttyWindowState() -> GhosttyWindowState {
            ghosttyState
        }

        func activateGhostty(projectPath: String?) async -> Bool {
            activateGhosttyCallCount += 1
            lastActivatedGhosttyProjectPath = projectPath
            lastActivatedApp = "Ghostty"
            return activateGhosttyResult
        }
    }

    @MainActor
    private final class StubTerminalLauncherClient: TerminalLauncherClient {
        var launchedSession: String?
        var launchCount = 0
        func launchTerminalWithTmux(sessionName: String) {
            launchedSession = sessionName
            launchCount += 1
        }
    }

    func testExecuteRoutesActivateByTty() async {
        let deps = StubDependencies()
        deps.activateByTtyResult = false
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: StubTerminalDiscovery(),
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .activateByTty(tty: "/dev/ttys001", terminalType: .iTerm),
            projectPath: "/Users/pete/Code/project",
            projectName: "project",
        )

        XCTAssertFalse(result)
        XCTAssertEqual(deps.lastAction, "activateByTty")
        XCTAssertEqual(deps.lastTty, "/dev/ttys001")
        XCTAssertEqual(deps.lastTerminalType, .iTerm)
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/project")
    }

    func testExecuteRoutesActivateAppGhosttyThroughProjectAwarePath() async {
        let deps = StubDependencies()
        let terminalDiscovery = StubTerminalDiscovery()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .activateApp(appName: "Ghostty"),
            projectPath: "/Users/pete/Code/capacitor",
            projectName: "capacitor",
        )

        XCTAssertTrue(result)
        XCTAssertNil(deps.lastAction, "Ghostty app activation should bypass generic dependency activation.")
        XCTAssertEqual(terminalDiscovery.activateGhosttyCallCount, 1)
        XCTAssertEqual(terminalDiscovery.lastActivatedGhosttyProjectPath, "/Users/pete/Code/capacitor")
    }

    func testExecuteRoutesActivateAppNonGhosttyThroughDependencies() async {
        let deps = StubDependencies()
        let terminalDiscovery = StubTerminalDiscovery()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .activateApp(appName: "iTerm"),
            projectPath: "/Users/pete/Code/capacitor",
            projectName: "capacitor",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(deps.lastAction, "activateApp")
        XCTAssertEqual(deps.lastAppName, "iTerm")
        XCTAssertEqual(terminalDiscovery.activateGhosttyCallCount, 0)
    }

    func testExecuteRoutesSwitchTmuxSession() async {
        let deps = StubDependencies()
        deps.switchTmuxResult = false
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: StubTerminalDiscovery(),
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .switchTmuxSession(sessionName: "cap"),
            projectPath: "/Users/pete/Code/cap",
            projectName: "cap",
        )

        XCTAssertFalse(result)
        XCTAssertEqual(deps.lastAction, "switchTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
    }

    func testExecuteRoutesEnsureTmuxSession() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = false
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: StubTerminalDiscovery(),
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .ensureTmuxSession(sessionName: "cap", projectPath: "/Users/pete/Code/cap"),
            projectPath: "/Users/pete/Code/other",
            projectName: "cap",
        )

        XCTAssertFalse(result)
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
    }

    func testExecuteRoutesLaunchNewTerminal() async {
        let deps = StubDependencies()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: StubTmuxClient(),
            terminalDiscovery: StubTerminalDiscovery(),
            terminalLauncher: StubTerminalLauncherClient(),
        )

        let result = await executor.execute(
            .launchNewTerminal(projectPath: "/Users/pete/Code/app", projectName: "app"),
            projectPath: "/Users/pete/Code/app",
            projectName: "app",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(deps.lastAction, "launchNewTerminal")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/app")
        XCTAssertEqual(deps.lastProjectName, "app")
    }

    func testActivateHostThenSwitchTmuxLaunchesWhenNoClientAttached() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        let terminalDiscovery = StubTerminalDiscovery()
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(launcher.launchedSession, "cap")
    }

    func testActivateHostThenSwitchTmuxUsesTtyDiscoveryThenSwitches() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.switchResult = true
        tmux.currentClientTty = "/dev/ttys009"
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = true
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(tmux.lastSwitchedClientTty, "/dev/ttys009")
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxGhosttyFallbackActivatesAppWhenGhosttyRunning() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.switchResult = true
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyState = .running
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxGhosttyFallbackActivatesAppWhenGhosttyRunningWithMultipleContexts() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.switchResult = true
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyState = .running
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxNoTtyAndNoGhosttyFallsBackToEnsureSession() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = true
        let tmux = StubTmuxClient()
        tmux.switchResult = true
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyState = .notRunning
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxReturnsFalseWhenSwitchFails() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = false
        let tmux = StubTmuxClient()
        tmux.switchResult = false
        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = true
        let launcher = StubTerminalLauncherClient()

        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertFalse(result, "Should fail only if both switch-client and ensureTmuxSession recovery fail.")
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
        XCTAssertNil(launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxAttachedClientSwitchFailureFallsBackToEnsureSession() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = true

        let tmux = StubTmuxClient()
        tmux.hasClientAttached = true
        tmux.currentClientTty = "/dev/ttys042"
        tmux.switchResult = false

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = true
        terminalDiscovery.ghosttyState = .running

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys042",
            sessionName: "openclaw",
            projectPath: "/Users/pete/Code/openclaw",
        )

        XCTAssertTrue(
            result,
            "Attached-client switch failures should recover by ensuring/creating the tmux session.",
        )
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "openclaw")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/openclaw")
        XCTAssertEqual(deps.lastPreferredClientTty, "/dev/ttys042")
        XCTAssertEqual(launcher.launchCount, 0, "Should not spawn a new terminal window on recoverable switch failure.")
    }

    func testActivateHostThenSwitchTmuxAttachedClientSwitchFailureFallsBackToEnsureSessionWhenNotGhostty() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = true

        let tmux = StubTmuxClient()
        tmux.hasClientAttached = true
        tmux.currentClientTty = "/dev/ttys042"
        tmux.switchResult = false

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = true
        terminalDiscovery.ghosttyState = .notRunning

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys042",
            sessionName: "openclaw",
            projectPath: "/Users/pete/Code/openclaw",
        )

        XCTAssertTrue(
            result,
            "Attached-client switch failures should recover by ensuring/creating the tmux session for all terminals, not just Ghostty.",
        )
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "openclaw")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/openclaw")
        XCTAssertEqual(deps.lastPreferredClientTty, "/dev/ttys042")
        XCTAssertEqual(launcher.launchCount, 0, "Should not spawn a new terminal window on recoverable switch failure.")
    }

    func testActivateHostThenSwitchTmuxAttachedClientGhosttyFallbackSwitchFailureFallsBackToEnsureSession() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = true

        let tmux = StubTmuxClient()
        tmux.hasClientAttached = true
        tmux.currentClientTty = "/dev/ttys042"
        tmux.switchResult = false

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyState = .running

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys042",
            sessionName: "openclaw",
            projectPath: "/Users/pete/Code/openclaw",
        )

        XCTAssertTrue(
            result,
            "Ghostty fallback switch failures with attached clients should recover by ensuring/creating the tmux session.",
        )
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "openclaw")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/openclaw")
        XCTAssertEqual(deps.lastPreferredClientTty, "/dev/ttys042")
        XCTAssertEqual(launcher.launchCount, 0, "Should not spawn a new terminal window on recoverable switch failure.")
    }

    func testActivateHostThenSwitchTmuxNoClientAttachedButGhosttyRunningDoesNotSpawnNewWindow() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = true

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyState = .running

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertEqual(launcher.launchCount, 0, "Expected reuse of existing Ghostty context with no new window")
    }

    func testActivateHostThenSwitchTmuxNoClientAttachedUsesHostTtyHeuristicWhenAvailable() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = true

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.ghosttyState = .running

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertEqual(tmux.lastSwitchedClientTty, "/dev/ttys021")
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testActivateHostThenSwitchTmuxNoClientAttachedSwitchFailureFallsBackToEnsureSession() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = true

        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = false

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.ghosttyState = .running

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys-stale",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result, "Switch failure with no attached clients should recover via ensure path.")
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertEqual(tmux.lastSwitchedClientTty, "/dev/ttys-stale")
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testActivateHostThenSwitchTmuxNoClientAttachedGhosttyActivationFailureFallsBackToEnsureSession() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = true

        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = true

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.ghosttyState = .running
        terminalDiscovery.activateGhosttyResult = false

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys-stale",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result, "Zero-window Ghostty state should recover via ensure path, not dead-click on stale host evidence.")
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession")
        XCTAssertEqual(deps.lastSessionName, "cap")
        XCTAssertEqual(deps.lastProjectPath, "/Users/pete/Code/cap")
        XCTAssertNil(tmux.lastSwitchedClientTty, "Zero-window host should skip no-client switch heuristics.")
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testActivateHostThenSwitchTmuxNoClientAttachedGhosttyAXUnavailableAttemptsSwitch() async {
        let deps = StubDependencies()
        deps.ensureTmuxResult = true

        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = true

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.ghosttyState = .axUnavailable

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let result = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys-ax",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertEqual(tmux.lastSwitchedClientTty, "/dev/ttys-ax")
        XCTAssertNil(deps.lastAction, "AX unavailable should not be treated as zero-window ensure path when switch succeeds.")
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testActivateHostThenSwitchTmuxSequentialRequestsReuseExistingGhosttyContext() async {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        tmux.hasClientAttached = false
        tmux.currentClientTty = nil
        tmux.switchResult = true

        let terminalDiscovery = StubTerminalDiscovery()
        terminalDiscovery.activateByTtyResult = false
        terminalDiscovery.ghosttyState = .running

        let launcher = StubTerminalLauncherClient()
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )

        let first = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "project-a",
            projectPath: "/Users/pete/Code/project-a",
        )
        let second = await executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "project-b",
            projectPath: "/Users/pete/Code/project-b",
        )

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(launcher.launchCount, 0, "Sequential project clicks should switch context without spawning windows")
    }
}
