@testable import Capacitor
import XCTest

@MainActor
final class ActivationActionExecutorTests: XCTestCase {
    private struct ExpectedDependencyRoute {
        let action: String
        let tty: String?
        let terminalType: TerminalType?
        let sessionName: String?
        let projectPath: String?
        let projectName: String?
    }

    private struct ExpectedEnsureRoute {
        let sessionName: String
        let projectPath: String
        let preferredClientTty: String?
        let assertPreferredClientTty: Bool
    }

    private struct HostSwitchFallbackExpectation {
        let ensureRoute: ExpectedEnsureRoute?
        let shouldSpawnNewWindow: Bool
    }

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

    func testExecuteRoutesDependencyBackedActions() async {
        struct Scenario {
            let name: String
            let configure: (StubDependencies) -> Void
            let action: ActivationAction
            let requestProjectPath: String
            let requestProjectName: String
            let expectedResult: Bool
            let expectedRoute: ExpectedDependencyRoute
        }

        let scenarios = [
            Scenario(
                name: "activate_by_tty",
                configure: { $0.activateByTtyResult = false },
                action: .activateByTty(tty: "/dev/ttys001", terminalType: .iTerm),
                requestProjectPath: "/Users/pete/Code/project",
                requestProjectName: "project",
                expectedResult: false,
                expectedRoute: ExpectedDependencyRoute(
                    action: "activateByTty",
                    tty: "/dev/ttys001",
                    terminalType: .iTerm,
                    sessionName: nil,
                    projectPath: "/Users/pete/Code/project",
                    projectName: nil,
                ),
            ),
            Scenario(
                name: "switch_tmux_session",
                configure: { $0.switchTmuxResult = false },
                action: .switchTmuxSession(sessionName: "cap"),
                requestProjectPath: "/Users/pete/Code/cap",
                requestProjectName: "cap",
                expectedResult: false,
                expectedRoute: ExpectedDependencyRoute(
                    action: "switchTmuxSession",
                    tty: nil,
                    terminalType: nil,
                    sessionName: "cap",
                    projectPath: "/Users/pete/Code/cap",
                    projectName: nil,
                ),
            ),
            Scenario(
                name: "ensure_tmux_session",
                configure: { $0.ensureTmuxResult = false },
                action: .ensureTmuxSession(sessionName: "cap", projectPath: "/Users/pete/Code/cap"),
                requestProjectPath: "/Users/pete/Code/other",
                requestProjectName: "cap",
                expectedResult: false,
                expectedRoute: ExpectedDependencyRoute(
                    action: "ensureTmuxSession",
                    tty: nil,
                    terminalType: nil,
                    sessionName: "cap",
                    projectPath: "/Users/pete/Code/cap",
                    projectName: nil,
                ),
            ),
            Scenario(
                name: "launch_new_terminal",
                configure: { _ in },
                action: .launchNewTerminal(projectPath: "/Users/pete/Code/app", projectName: "app"),
                requestProjectPath: "/Users/pete/Code/app",
                requestProjectName: "app",
                expectedResult: true,
                expectedRoute: ExpectedDependencyRoute(
                    action: "launchNewTerminal",
                    tty: nil,
                    terminalType: nil,
                    sessionName: nil,
                    projectPath: "/Users/pete/Code/app",
                    projectName: "app",
                ),
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.name)
            let deps = StubDependencies()
            scenario.configure(deps)
            let executor = ActivationActionExecutor(
                dependencies: deps,
                tmuxClient: StubTmuxClient(),
                terminalDiscovery: StubTerminalDiscovery(),
                terminalLauncher: StubTerminalLauncherClient(),
            )

            let result = await executor.execute(
                scenario.action,
                projectPath: scenario.requestProjectPath,
                projectName: scenario.requestProjectName,
            )

            XCTAssertEqual(result, scenario.expectedResult, "\(context) unexpected execution result")
            assertExpectedDependencyRoute(
                deps,
                expected: scenario.expectedRoute,
                context: "\(context)",
            )
        }
    }

    func testExecuteRoutesActivateAppRoutingScenarios() async {
        struct Scenario {
            let name: String
            let appName: String
            let expectedLastAction: String?
            let expectedLastAppName: String?
            let expectedGhosttyActivations: Int
            let expectedGhosttyProjectPath: String?
        }

        let scenarios = [
            Scenario(
                name: "ghostty_bypasses_dependencies",
                appName: "Ghostty",
                expectedLastAction: nil,
                expectedLastAppName: nil,
                expectedGhosttyActivations: 1,
                expectedGhosttyProjectPath: "/Users/pete/Code/capacitor",
            ),
            Scenario(
                name: "non_ghostty_routes_to_dependencies",
                appName: "iTerm",
                expectedLastAction: "activateApp",
                expectedLastAppName: "iTerm",
                expectedGhosttyActivations: 0,
                expectedGhosttyProjectPath: nil,
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.name)
            let deps = StubDependencies()
            let terminalDiscovery = StubTerminalDiscovery()
            let executor = ActivationActionExecutor(
                dependencies: deps,
                tmuxClient: StubTmuxClient(),
                terminalDiscovery: terminalDiscovery,
                terminalLauncher: StubTerminalLauncherClient(),
            )

            let result = await executor.execute(
                .activateApp(appName: scenario.appName),
                projectPath: "/Users/pete/Code/capacitor",
                projectName: "capacitor",
            )

            assertActivateAppRouteOutcome(
                result: result,
                deps: deps,
                terminalDiscovery: terminalDiscovery,
                expectedLastAction: scenario.expectedLastAction,
                expectedLastAppName: scenario.expectedLastAppName,
                expectedGhosttyActivations: scenario.expectedGhosttyActivations,
                expectedGhosttyProjectPath: scenario.expectedGhosttyProjectPath,
                context: "\(context)",
            )
        }
    }

    func testActivateHostThenSwitchTmuxLaunchesWhenNoClientAttached() async {
        let harness = makeExecutor { _, tmux, _, _ in
            tmux.hasClientAttached = false
        }

        let result = await harness.executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(harness.launcher.launchedSession, "cap")
    }

    func testActivateHostThenSwitchTmuxUsesTtyDiscoveryThenSwitches() async {
        let harness = makeExecutor { _, tmux, terminalDiscovery, _ in
            tmux.switchResult = true
            tmux.currentClientTty = "/dev/ttys009"
            terminalDiscovery.activateByTtyResult = true
        }

        let result = await harness.executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(harness.tmux.lastSwitchedClientTty, "/dev/ttys009")
        XCTAssertNil(harness.launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxGhosttyFallbackActivationAcrossContexts() async {
        let harness = makeExecutor { _, tmux, terminalDiscovery, _ in
            tmux.switchResult = true
            terminalDiscovery.activateByTtyResult = false
            terminalDiscovery.ghosttyState = .running
        }

        let first = await harness.executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys000",
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
        )
        let second = await harness.executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys111",
            sessionName: "cap-2",
            projectPath: "/Users/pete/Code/cap-2",
        )

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(harness.terminalDiscovery.lastActivatedApp, "Ghostty")
        XCTAssertNil(harness.launcher.launchedSession)
    }

    func testActivateHostThenSwitchTmuxEnsureFallbackScenarios() async {
        struct Scenario {
            let name: String
            let switchResult: Bool
            let ensureTmuxResult: Bool
            let activateByTtyResult: Bool
            let ghosttyState: GhosttyWindowState
            let expectedResult: Bool
            let fallbackExpectation: HostSwitchFallbackExpectation
        }

        let scenarios = [
            Scenario(
                name: "no_tty_no_ghostty_falls_back_to_ensure",
                switchResult: true,
                ensureTmuxResult: true,
                activateByTtyResult: false,
                ghosttyState: .notRunning,
                expectedResult: true,
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: ExpectedEnsureRoute(
                        sessionName: "cap",
                        projectPath: "/Users/pete/Code/cap",
                        preferredClientTty: nil,
                        assertPreferredClientTty: false
                    ),
                    shouldSpawnNewWindow: false
                ),
            ),
            Scenario(
                name: "switch_failure_and_failed_ensure_returns_false",
                switchResult: false,
                ensureTmuxResult: false,
                activateByTtyResult: true,
                ghosttyState: .notRunning,
                expectedResult: false,
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: ExpectedEnsureRoute(
                        sessionName: "cap",
                        projectPath: "/Users/pete/Code/cap",
                        preferredClientTty: nil,
                        assertPreferredClientTty: false
                    ),
                    shouldSpawnNewWindow: false
                ),
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.name)
            let deps = StubDependencies()
            deps.ensureTmuxResult = scenario.ensureTmuxResult
            let tmux = StubTmuxClient()
            tmux.switchResult = scenario.switchResult
            let terminalDiscovery = StubTerminalDiscovery()
            terminalDiscovery.activateByTtyResult = scenario.activateByTtyResult
            terminalDiscovery.ghosttyState = scenario.ghosttyState
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

            XCTAssertEqual(
                result,
                scenario.expectedResult,
                "\(context) unexpected fallback result",
            )
            assertHostSwitchFallbackOutcome(
                deps: deps,
                launcher: launcher,
                expectation: scenario.fallbackExpectation,
                context: context,
            )
        }
    }

    func testActivateHostThenSwitchTmuxAttachedClientSwitchFailureFallbackScenarios() async {
        struct Scenario {
            let name: String
            let activateByTtyResult: Bool
            let ghosttyState: GhosttyWindowState
            let expectGhosttyAppActivation: Bool
            let fallbackExpectation: HostSwitchFallbackExpectation
        }

        let scenarios = [
            Scenario(
                name: "ghostty_running_tty_discovery_succeeds",
                activateByTtyResult: true,
                ghosttyState: .running,
                expectGhosttyAppActivation: false,
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: ExpectedEnsureRoute(
                        sessionName: "openclaw",
                        projectPath: "/Users/pete/Code/openclaw",
                        preferredClientTty: "/dev/ttys042",
                        assertPreferredClientTty: true
                    ),
                    shouldSpawnNewWindow: false
                ),
            ),
            Scenario(
                name: "non_ghostty_terminal_context",
                activateByTtyResult: true,
                ghosttyState: .notRunning,
                expectGhosttyAppActivation: false,
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: ExpectedEnsureRoute(
                        sessionName: "openclaw",
                        projectPath: "/Users/pete/Code/openclaw",
                        preferredClientTty: "/dev/ttys042",
                        assertPreferredClientTty: true
                    ),
                    shouldSpawnNewWindow: false
                ),
            ),
            Scenario(
                name: "ghostty_running_tty_discovery_fails",
                activateByTtyResult: false,
                ghosttyState: .running,
                expectGhosttyAppActivation: true,
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: ExpectedEnsureRoute(
                        sessionName: "openclaw",
                        projectPath: "/Users/pete/Code/openclaw",
                        preferredClientTty: "/dev/ttys042",
                        assertPreferredClientTty: true
                    ),
                    shouldSpawnNewWindow: false
                ),
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.name)
            let deps = StubDependencies()
            deps.ensureTmuxResult = true

            let tmux = StubTmuxClient()
            tmux.hasClientAttached = true
            tmux.currentClientTty = "/dev/ttys042"
            tmux.switchResult = false

            let terminalDiscovery = StubTerminalDiscovery()
            terminalDiscovery.activateByTtyResult = scenario.activateByTtyResult
            terminalDiscovery.ghosttyState = scenario.ghosttyState

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
                "\(context) Attached-client switch failures should recover by ensuring/creating the tmux session.",
            )
            assertHostSwitchFallbackOutcome(
                deps: deps,
                launcher: launcher,
                expectation: scenario.fallbackExpectation,
                context: context,
            )
            XCTAssertEqual(
                terminalDiscovery.lastActivatedApp == "Ghostty",
                scenario.expectGhosttyAppActivation,
                "\(context) Ghostty app activation expectation mismatch.",
            )
        }
    }

    func testActivateHostThenSwitchTmuxNoClientGhosttyFallbackScenarios() async {
        struct Scenario {
            let name: String
            let hostTty: String
            let activateByTtyResult: Bool
            let ghosttyState: GhosttyWindowState
            let activateGhosttyResult: Bool
            let switchResult: Bool
            let expectedSwitchClientTty: String?
            let expectedLastAction: String?
            let fallbackExpectation: HostSwitchFallbackExpectation
        }

        let scenarios = [
            Scenario(
                name: "running_ghostty_reuse_context",
                hostTty: "/dev/ttys021",
                activateByTtyResult: false,
                ghosttyState: .running,
                activateGhosttyResult: true,
                switchResult: true,
                expectedSwitchClientTty: "/dev/ttys021",
                expectedLastAction: nil,
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: nil,
                    shouldSpawnNewWindow: false
                ),
            ),
            Scenario(
                name: "running_ghostty_host_tty_heuristic_switch",
                hostTty: "/dev/ttys021",
                activateByTtyResult: true,
                ghosttyState: .running,
                activateGhosttyResult: true,
                switchResult: true,
                expectedSwitchClientTty: "/dev/ttys021",
                expectedLastAction: nil,
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: nil,
                    shouldSpawnNewWindow: false
                ),
            ),
            Scenario(
                name: "switch_failure_falls_back_to_ensure",
                hostTty: "/dev/ttys-stale",
                activateByTtyResult: true,
                ghosttyState: .running,
                activateGhosttyResult: true,
                switchResult: false,
                expectedSwitchClientTty: "/dev/ttys-stale",
                expectedLastAction: "ensureTmuxSession",
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: ExpectedEnsureRoute(
                        sessionName: "cap",
                        projectPath: "/Users/pete/Code/cap",
                        preferredClientTty: nil,
                        assertPreferredClientTty: false
                    ),
                    shouldSpawnNewWindow: false
                ),
            ),
            Scenario(
                name: "ghostty_activation_failure_falls_back_to_ensure",
                hostTty: "/dev/ttys-stale",
                activateByTtyResult: true,
                ghosttyState: .running,
                activateGhosttyResult: false,
                switchResult: true,
                expectedSwitchClientTty: nil,
                expectedLastAction: "ensureTmuxSession",
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: ExpectedEnsureRoute(
                        sessionName: "cap",
                        projectPath: "/Users/pete/Code/cap",
                        preferredClientTty: nil,
                        assertPreferredClientTty: false
                    ),
                    shouldSpawnNewWindow: false
                ),
            ),
            Scenario(
                name: "ax_unavailable_attempts_switch_without_ensure",
                hostTty: "/dev/ttys-ax",
                activateByTtyResult: true,
                ghosttyState: .axUnavailable,
                activateGhosttyResult: true,
                switchResult: true,
                expectedSwitchClientTty: "/dev/ttys-ax",
                expectedLastAction: nil,
                fallbackExpectation: HostSwitchFallbackExpectation(
                    ensureRoute: nil,
                    shouldSpawnNewWindow: false
                ),
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.name)
            let deps = StubDependencies()
            deps.ensureTmuxResult = true

            let tmux = StubTmuxClient()
            tmux.hasClientAttached = false
            tmux.currentClientTty = nil
            tmux.switchResult = scenario.switchResult

            let terminalDiscovery = StubTerminalDiscovery()
            terminalDiscovery.activateByTtyResult = scenario.activateByTtyResult
            terminalDiscovery.ghosttyState = scenario.ghosttyState
            terminalDiscovery.activateGhosttyResult = scenario.activateGhosttyResult

            let launcher = StubTerminalLauncherClient()
            let executor = ActivationActionExecutor(
                dependencies: deps,
                tmuxClient: tmux,
                terminalDiscovery: terminalDiscovery,
                terminalLauncher: launcher,
            )

            let result = await executor.activateHostThenSwitchTmux(
                hostTty: scenario.hostTty,
                sessionName: "cap",
                projectPath: "/Users/pete/Code/cap",
            )

            XCTAssertTrue(result, "\(context) expected activation to succeed")
            XCTAssertEqual(
                terminalDiscovery.lastActivatedApp,
                "Ghostty",
                "\(context) should always attempt Ghostty app activation in no-client path",
            )
            XCTAssertEqual(
                tmux.lastSwitchedClientTty,
                scenario.expectedSwitchClientTty,
                "\(context) unexpected tmux switch target",
            )
            XCTAssertEqual(
                deps.lastAction,
                scenario.expectedLastAction,
                "\(context) unexpected dependency fallback action",
            )
            assertHostSwitchFallbackOutcome(
                deps: deps,
                launcher: launcher,
                expectation: scenario.fallbackExpectation,
                context: context,
            )
        }
    }

    func testActivateHostThenSwitchTmuxSequentialRequestsReuseExistingGhosttyContext() async {
        let harness = makeExecutor { _, tmux, terminalDiscovery, _ in
            tmux.hasClientAttached = false
            tmux.currentClientTty = nil
            tmux.switchResult = true
            terminalDiscovery.activateByTtyResult = false
            terminalDiscovery.ghosttyState = .running
        }

        let first = await harness.executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "project-a",
            projectPath: "/Users/pete/Code/project-a",
        )
        let second = await harness.executor.activateHostThenSwitchTmux(
            hostTty: "/dev/ttys021",
            sessionName: "project-b",
            projectPath: "/Users/pete/Code/project-b",
        )

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(harness.launcher.launchCount, 0, "Sequential project clicks should switch context without spawning windows")
    }

    private func assertEnsureFallbackRoute(
        _ deps: StubDependencies,
        expectedSessionName: String,
        expectedProjectPath: String,
        expectedPreferredClientTty: String?,
        assertPreferredClientTty: Bool = false,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(deps.lastAction, "ensureTmuxSession", "\(context) action mismatch", file: file, line: line)
        XCTAssertEqual(deps.lastSessionName, expectedSessionName, "\(context) session mismatch", file: file, line: line)
        XCTAssertEqual(deps.lastProjectPath, expectedProjectPath, "\(context) project mismatch", file: file, line: line)
        if assertPreferredClientTty {
            XCTAssertEqual(
                deps.lastPreferredClientTty,
                expectedPreferredClientTty,
                "\(context) preferred client tty mismatch",
                file: file,
                line: line,
            )
        }
    }

    private func assertNoWindowSpawned(
        _ launcher: StubTerminalLauncherClient,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(launcher.launchCount, 0, context, file: file, line: line)
        XCTAssertNil(launcher.launchedSession, context, file: file, line: line)
    }

    private func assertHostSwitchFallbackOutcome(
        deps: StubDependencies,
        launcher: StubTerminalLauncherClient,
        expectation: HostSwitchFallbackExpectation,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        if let ensureRoute = expectation.ensureRoute {
            assertEnsureFallbackRoute(
                deps,
                expectedSessionName: ensureRoute.sessionName,
                expectedProjectPath: ensureRoute.projectPath,
                expectedPreferredClientTty: ensureRoute.preferredClientTty,
                assertPreferredClientTty: ensureRoute.assertPreferredClientTty,
                context: "\(context) ensure fallback route mismatch",
                file: file,
                line: line,
            )
        }

        if !expectation.shouldSpawnNewWindow {
            assertNoWindowSpawned(
                launcher,
                context: "\(context) should not spawn new window",
                file: file,
                line: line,
            )
        }
    }

    private func assertExpectedDependencyRoute(
        _ deps: StubDependencies,
        expected: ExpectedDependencyRoute,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(deps.lastAction, expected.action, "\(context) unexpected routed action", file: file, line: line)
        XCTAssertEqual(deps.lastTty, expected.tty, "\(context) unexpected tty", file: file, line: line)
        XCTAssertEqual(
            deps.lastTerminalType,
            expected.terminalType,
            "\(context) unexpected terminal type",
            file: file,
            line: line,
        )
        XCTAssertEqual(
            deps.lastSessionName,
            expected.sessionName,
            "\(context) unexpected session name",
            file: file,
            line: line,
        )
        XCTAssertEqual(
            deps.lastProjectPath,
            expected.projectPath,
            "\(context) unexpected project path",
            file: file,
            line: line,
        )
        XCTAssertEqual(
            deps.lastProjectName,
            expected.projectName,
            "\(context) unexpected project name",
            file: file,
            line: line,
        )
    }

    private func assertActivateAppRouteOutcome(
        result: Bool,
        deps: StubDependencies,
        terminalDiscovery: StubTerminalDiscovery,
        expectedLastAction: String?,
        expectedLastAppName: String?,
        expectedGhosttyActivations: Int,
        expectedGhosttyProjectPath: String?,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertTrue(result, "\(context) expected activation to succeed", file: file, line: line)
        XCTAssertEqual(
            deps.lastAction,
            expectedLastAction,
            "\(context) unexpected dependency action route",
            file: file,
            line: line,
        )
        XCTAssertEqual(
            deps.lastAppName,
            expectedLastAppName,
            "\(context) unexpected dependency app argument",
            file: file,
            line: line,
        )
        XCTAssertEqual(
            terminalDiscovery.activateGhosttyCallCount,
            expectedGhosttyActivations,
            "\(context) unexpected Ghostty activation count",
            file: file,
            line: line,
        )
        XCTAssertEqual(
            terminalDiscovery.lastActivatedGhosttyProjectPath,
            expectedGhosttyProjectPath,
            "\(context) unexpected Ghostty project path",
            file: file,
            line: line,
        )
    }

    private func scenarioContext(_ name: String) -> String {
        "[\(name)]"
    }

    private func makeExecutor(
        configure: ((StubDependencies, StubTmuxClient, StubTerminalDiscovery, StubTerminalLauncherClient) -> Void)? = nil,
    ) -> (
        executor: ActivationActionExecutor,
        deps: StubDependencies,
        tmux: StubTmuxClient,
        terminalDiscovery: StubTerminalDiscovery,
        launcher: StubTerminalLauncherClient
    ) {
        let deps = StubDependencies()
        let tmux = StubTmuxClient()
        let terminalDiscovery = StubTerminalDiscovery()
        let launcher = StubTerminalLauncherClient()
        configure?(deps, tmux, terminalDiscovery, launcher)
        let executor = ActivationActionExecutor(
            dependencies: deps,
            tmuxClient: tmux,
            terminalDiscovery: terminalDiscovery,
            terminalLauncher: launcher,
        )
        return (executor, deps, tmux, terminalDiscovery, launcher)
    }
}
