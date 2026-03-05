@testable import Capacitor
import XCTest

@MainActor
final class TerminalLauncherTests: XCTestCase {
    private actor LogCollector {
        private var lines: [String] = []

        func append(_ line: String) {
            lines.append(line)
        }

        func contains(_ predicate: (String) -> Bool) -> Bool {
            lines.contains(where: predicate)
        }
    }

    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen {
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
        }
    }

    private final class StubAppleScriptClient: AppleScriptClient {
        let shouldSucceed: Bool
        private(set) var checkedScripts: [String] = []
        private(set) var booleanScripts: [String] = []
        var booleanResult: Bool?

        init(shouldSucceed: Bool) {
            self.shouldSucceed = shouldSucceed
        }

        func run(_: String) {}
        func runChecked(_ script: String) -> Bool {
            checkedScripts.append(script)
            return shouldSucceed
        }

        func runBoolean(_ script: String) -> Bool? {
            booleanScripts.append(script)
            return booleanResult
        }
    }

    @MainActor
    private final class StubGhosttyWindowReader: GhosttyWindowReader {
        var readResult: GhosttyWindowReadResult = .windows([])
        private(set) var raisedWindowCount = 0
        private(set) var focusedTabs: [GhosttyTabSnapshot] = []
        var raiseWindowResult = true
        var focusTabResult = true

        func readWindows() -> GhosttyWindowReadResult {
            readResult
        }

        func raiseWindow(_: AXUIElement) -> Bool {
            raisedWindowCount += 1
            return raiseWindowResult
        }

        func focusTab(_ tab: GhosttyTabSnapshot, in _: AXUIElement) -> Bool {
            focusedTabs.append(tab)
            return focusTabResult
        }
    }

    func testResolveGhosttyAXRoutingPrefersTabPressWhenProjectMatchExists() {
        let reader = StubGhosttyWindowReader()
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "/Users/pete/Code/other", index: 0),
                makeGhosttyTab(title: "/Users/pete/Code/capacitor", index: 1, isSelected: true),
            ]),
        ]

        let outcome = TerminalLauncher.resolveGhosttyAXRouting(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            ghosttyWindowReader: reader,
        )

        XCTAssertEqual(outcome, .tabPress)
        XCTAssertEqual(reader.focusedTabs.count, 1)
        XCTAssertEqual(reader.focusedTabs.first?.index, 1)
        XCTAssertEqual(reader.raisedWindowCount, 0)
    }

    func testResolveGhosttyAXRoutingFallsBackToWindowRaiseWhenTabPressFails() {
        let reader = StubGhosttyWindowReader()
        reader.focusTabResult = false
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "/Users/pete/Code/capacitor", index: 0, isSelected: true),
            ]),
        ]

        let outcome = TerminalLauncher.resolveGhosttyAXRouting(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            ghosttyWindowReader: reader,
        )

        XCTAssertEqual(outcome, .windowRaise)
        XCTAssertEqual(reader.focusedTabs.count, 1)
        XCTAssertEqual(reader.raisedWindowCount, 1)
    }

    func testResolveGhosttyAXRoutingRaisesMainWindowWhenNoDeterministicTabMatch() {
        let reader = StubGhosttyWindowReader()
        let windows = [
            makeGhosttyWindow(index: 2, isMain: false, tabs: [
                makeGhosttyTab(title: "/Users/pete/Code/other", index: 0),
            ]),
            makeGhosttyWindow(index: 1, isMain: true, tabs: [
                makeGhosttyTab(title: "/Users/pete/Code/unrelated", index: 0),
            ]),
        ]

        let outcome = TerminalLauncher.resolveGhosttyAXRouting(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            ghosttyWindowReader: reader,
        )

        XCTAssertEqual(outcome, .windowRaise)
        XCTAssertEqual(reader.focusedTabs.count, 0)
        XCTAssertEqual(reader.raisedWindowCount, 1)
    }

    func testResolveGhosttyAXRoutingReturnsNilWhenNothingCanBeRaised() {
        let reader = StubGhosttyWindowReader()
        reader.raiseWindowResult = false
        let windows = [
            makeGhosttyWindow(index: 0, isMain: false, tabs: []),
        ]

        let outcome = TerminalLauncher.resolveGhosttyAXRouting(
            windows: windows,
            projectPath: nil,
            ghosttyWindowReader: reader,
        )

        XCTAssertNil(outcome)
        XCTAssertEqual(reader.focusedTabs.count, 0)
        XCTAssertEqual(reader.raisedWindowCount, 1)
    }

    /// Reproduces the AX routing race: after `tmux switch-client -t new-session`,
    /// the tab title still shows the OLD session name because Ghostty hasn't
    /// processed the title escape sequence yet. The routing falls to window_raise
    /// instead of tab_press, leaving the wrong tab visible.
    func testResolveGhosttyAXRoutingFallsToWindowRaiseWhenTitleShowsStaleSession() {
        let reader = StubGhosttyWindowReader()
        // Tab 0: tmux tab still showing OLD session title (stale after switch-client)
        // Tab 1: non-tmux tab (e.g., running pnpm dev)
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "capacitor: ~/Code/capacitor", index: 0, isSelected: false),
                makeGhosttyTab(title: "pnpm dev", index: 1, isSelected: true),
            ]),
        ]

        // We just switched to "agentic-canvas-v2" but the title hasn't propagated yet
        let outcome = TerminalLauncher.resolveGhosttyAXRouting(
            windows: windows,
            projectPath: "/Users/pete/Code/agentic-canvas-v2",
            tmuxSessionHint: "agentic-canvas-v2",
            ghosttyWindowReader: reader,
        )

        // BUG: Without a title match, routing falls to window_raise instead of
        // focusing the tmux tab (index 0). The user sees the wrong tab.
        XCTAssertEqual(outcome, .windowRaise, "Stale title causes window_raise instead of tab_press")
        XCTAssertEqual(reader.focusedTabs.count, 0, "No tab was focused because the title didn't match")
        XCTAssertEqual(reader.raisedWindowCount, 1)
    }

    /// After `tmux switch-client`, once the title propagates, the hint match works.
    func testResolveGhosttyAXRoutingMatchesAfterTitlePropagates() {
        let reader = StubGhosttyWindowReader()
        // Tab 0: tmux tab has now updated its title to the NEW session
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "agentic-canvas-v2: ~/Code/agentic-canvas-v2", index: 0, isSelected: false),
                makeGhosttyTab(title: "pnpm dev", index: 1, isSelected: true),
            ]),
        ]

        let outcome = TerminalLauncher.resolveGhosttyAXRouting(
            windows: windows,
            projectPath: "/Users/pete/Code/agentic-canvas-v2",
            tmuxSessionHint: "agentic-canvas-v2",
            ghosttyWindowReader: reader,
        )

        XCTAssertEqual(outcome, .tabPress, "Once title propagates, hint match correctly focuses the tmux tab")
        XCTAssertEqual(reader.focusedTabs.count, 1)
        XCTAssertEqual(reader.focusedTabs.first?.index, 0)
    }

    func testResolveGhosttyAXRoutingUsesTmuxSessionHintWhenProjectSlugDiffers() {
        let reader = StubGhosttyWindowReader()
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "mcp-app-studio:1:2.1.50 - \"✳ Fullscreen Transition Performance\"", index: 0, isSelected: false),
                makeGhosttyTab(title: "pnpm dev", index: 1, isSelected: true),
            ]),
        ]

        let outcome = TerminalLauncher.resolveGhosttyAXRouting(
            windows: windows,
            projectPath: "/Users/pete/Code/aui/mcp-app-studio-starter",
            tmuxSessionHint: "mcp-app-studio",
            ghosttyWindowReader: reader,
        )

        XCTAssertEqual(outcome, .tabPress)
        XCTAssertEqual(reader.focusedTabs.count, 1)
        XCTAssertEqual(reader.focusedTabs.first?.index, 0)
    }

    func testBestTmuxSessionForPathDoesNotMatchParentRepoForWorktreePath() {
        let output = "agentic-canvas\t/Users/pete/Code/agentic-canvas\n"
        let projectPath = "/Users/pete/Code/agentic-canvas/.capacitor/worktrees/workstream-1"

        let session = TerminalLauncher.bestTmuxSessionForPath(
            output: output,
            projectPath: projectPath,
            homeDirectory: "/Users/pete",
        )

        XCTAssertNil(session)
    }

    func testBestTmuxSessionForPathDoesNotMatchManagedWorktreeForRepoRootPath() {
        let output = """
        mcp-app-studio-tool-metadata-workstream-1\t/Users/pete/Code/codex/.capacitor/worktrees/mcp-app-studio-tool-metadata-workstream-1
        """
        let projectPath = "/Users/pete/Code/codex"

        let session = TerminalLauncher.bestTmuxSessionForPath(
            output: output,
            projectPath: projectPath,
            homeDirectory: "/Users/pete",
        )

        XCTAssertNil(session)
    }

    func testRunBashScriptWithResultHandlesLargeOutputWithoutDeadlock() {
        let exp = expectation(description: "runBashScriptWithResult completes")
        _Concurrency.Task {
            let result = await TerminalLauncher.runBashScriptWithResult("yes x | head -n 200000")
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertNotNil(result.output)
            XCTAssertGreaterThan(result.output?.count ?? 0, 100_000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    func testRunBashScriptWithResultCancellationTerminatesProcessPromptly() async {
        let exp = expectation(description: "cancelled runBashScriptWithResult returns promptly")

        let task = _Concurrency.Task {
            _ = await TerminalLauncher.runBashScriptWithResult("sleep 5; echo done")
            exp.fulfill()
        }

        try? await _Concurrency.Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        await fulfillment(of: [exp], timeout: 1.5)
    }

    func testLaunchTerminalRequestArbitrationScenarios() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")

        // Scenario 1: cross-project overlap
        await withLogCollector { collector in
            var executedPaths: [String] = []
            var resultPaths: [String] = []
            let actionGateEntered = expectation(description: "cross_project_overlap-action-gate-entered")
            let releaseGate = AsyncGate()

            let launcher = TerminalLauncher(
                appleScript: StubAppleScriptClient(shouldSucceed: true),
                fallbackTmuxSessionResolver: { path in
                    URL(fileURLWithPath: path).lastPathComponent
                },
                activateProjectSessionOverride: { _, projectPath in
                    executedPaths.append(projectPath)
                    if projectPath == projectA.path {
                        actionGateEntered.fulfill()
                        await releaseGate.wait()
                    }
                    return true
                },
            )

            launcher.onActivationResult = { result in
                resultPaths.append(result.projectPath)
            }

            launcher.launchTerminal(for: projectA)
            await fulfillment(of: [actionGateEntered], timeout: 1.0)
            launcher.launchTerminal(for: projectB)
            await releaseGate.open()

            _ = await assertEventually(
                timeout: 1.5,
                context: "cross_project_overlap: Expected arbitration to complete.",
            ) {
                executedPaths.count == 2 && resultPaths.count == 1
            }
            XCTAssertEqual(executedPaths, [projectA.path, projectB.path])
            XCTAssertEqual(resultPaths, [projectB.path])
            let foundMarker = await waitForStaleSuppressionMarker(
                collector: collector,
                projectPath: projectA.path,
                timeout: 1.0,
            )
            XCTAssertTrue(foundMarker, "Expected stale suppression marker for superseded request.")
        }

        // Scenario 2: same-project rapid repeat
        await withLogCollector { collector in
            var executedPaths: [String] = []
            var resultPaths: [String] = []
            let actionGateEntered = expectation(description: "same_project_rapid_repeat-action-gate-entered")
            let releaseGate = AsyncGate()

            let launcher = TerminalLauncher(
                appleScript: StubAppleScriptClient(shouldSucceed: true),
                fallbackTmuxSessionResolver: { path in
                    URL(fileURLWithPath: path).lastPathComponent
                },
                activateProjectSessionOverride: { _, projectPath in
                    executedPaths.append(projectPath)
                    if executedPaths.count == 1 {
                        actionGateEntered.fulfill()
                        await releaseGate.wait()
                    }
                    return true
                },
            )

            launcher.onActivationResult = { result in
                resultPaths.append(result.projectPath)
            }

            launcher.launchTerminal(for: projectA)
            await fulfillment(of: [actionGateEntered], timeout: 1.0)
            launcher.launchTerminal(for: projectA)
            launcher.launchTerminal(for: projectA)
            await releaseGate.open()

            _ = await assertEventually(
                timeout: 1.5,
                context: "same_project_rapid_repeat: Expected arbitration to complete.",
            ) {
                executedPaths.count == 2 && resultPaths.count == 1
            }
            XCTAssertEqual(executedPaths, [projectA.path, projectA.path])
            XCTAssertEqual(resultPaths, [projectA.path])
            let foundMarker = await waitForStaleSuppressionMarker(
                collector: collector,
                projectPath: projectA.path,
                timeout: 1.0,
            )
            XCTAssertTrue(foundMarker, "Expected stale suppression marker for superseded request.")
        }

        // Scenario 3: sequential requests execute in order
        await withLogCollector { _ in
            var executedPaths: [String] = []
            var resultPaths: [String] = []

            let launcher = TerminalLauncher(
                appleScript: StubAppleScriptClient(shouldSucceed: true),
                fallbackTmuxSessionResolver: { path in
                    URL(fileURLWithPath: path).lastPathComponent
                },
                activateProjectSessionOverride: { _, projectPath in
                    executedPaths.append(projectPath)
                    return true
                },
            )

            launcher.onActivationResult = { result in
                resultPaths.append(result.projectPath)
            }

            launcher.launchTerminal(for: projectA)
            _ = await assertEventually(
                timeout: 1.0,
                context: "sequential: Expected first request to complete before next.",
            ) {
                executedPaths.count == 1 && resultPaths.count == 1
            }
            launcher.launchTerminal(for: projectB)

            _ = await assertEventually(
                timeout: 1.5,
                context: "sequential: Expected both requests to complete.",
            ) {
                executedPaths.count == 2 && resultPaths.count == 2
            }
            XCTAssertEqual(executedPaths, [projectA.path, projectB.path])
            XCTAssertEqual(resultPaths, [projectA.path, projectB.path])
        }
    }

    /// Unified flow: activation success/failure reported correctly
    func testLaunchTerminalUnifiedFlowReportsResults() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fallbackTmuxSessionResolver: { path in
                URL(fileURLWithPath: path).lastPathComponent
            },
            activateProjectSessionOverride: { _, _ in true },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: projectA)
        _ = await assertEventually(timeout: 1.0, context: "Expected result") {
            results.count == 1
        }

        XCTAssertEqual(results.first?.projectPath, projectA.path)
        XCTAssertEqual(results.first?.success, true)
    }

    /// Unified flow: activation failure propagates correctly
    func testLaunchTerminalUnifiedFlowReportsFailure() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            fallbackTmuxSessionResolver: { path in
                URL(fileURLWithPath: path).lastPathComponent
            },
            activateProjectSessionOverride: { _, _ in false },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: projectA)
        _ = await assertEventually(timeout: 1.0, context: "Expected result") {
            results.count == 1
        }

        XCTAssertEqual(results.first?.projectPath, projectA.path)
        XCTAssertEqual(results.first?.success, false)
    }

    // MARK: - Unified Activation Tests

    // S3: Session exists → just switch
    func testEnsureAndSwitchExistingSessionJustSwitches() async {
        var commands: [String] = []
        let ok = await TerminalLauncher.ensureSessionAndSwitch(
            sessionName: "my-project",
            projectPath: "/path/to/project",
            clientTty: "/dev/ttys001",
            runScript: { cmd in
                commands.append(cmd)
                return (0, nil)
            },
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(commands.count, 1, "Should only run switch, not create")
        XCTAssertTrue(commands[0].contains("switch-client"))
        XCTAssertTrue(commands[0].contains("my-project"))
    }

    // S4: Session doesn't exist → create then switch
    func testEnsureAndSwitchCreatesSessionWhenMissing() async {
        var commands: [String] = []
        let ok = await TerminalLauncher.ensureSessionAndSwitch(
            sessionName: "new-project",
            projectPath: "/path/to/new",
            clientTty: "/dev/ttys001",
            runScript: { cmd in
                commands.append(cmd)
                // First switch fails (session not found), create succeeds, retry succeeds
                if cmd.contains("switch-client"), commands.count(where: { $0.contains("switch-client") }) == 1 {
                    return (1, "session not found")
                }
                return (0, nil)
            },
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(commands.count, 3, "switch → create → switch")
        XCTAssertTrue(commands[1].contains("new-session"))
        XCTAssertTrue(commands[1].contains("new-project"))
    }

    /// No clients at all → launch terminal
    func testUnifiedActivationLaunchesWhenNoClients() async {
        var launched = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "my-project",
            projectPath: "/path/to/project",
            resolveAnyClientTty: { nil },
            ensureAndSwitch: { _, _, _ in XCTFail("should not be called"); return false },
            launchTerminalWithTmux: { session, path in
                XCTAssertEqual(session, "my-project")
                XCTAssertEqual(path, "/path/to/project")
                launched = true
            },
            activateTerminal: { _, _, _ in XCTFail("should not be called"); return false },
            pollForNewClient: { "/dev/ttys050" },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(launched)
    }

    /// Client exists → switch + focus
    func testUnifiedActivationSwitchesWhenClientExists() async {
        var switchedSession: String?
        var terminalActivated = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "other-project",
            projectPath: "/other",
            resolveAnyClientTty: { "/dev/ttys001" },
            ensureAndSwitch: { session, _, tty in
                switchedSession = session
                XCTAssertEqual(tty, "/dev/ttys001")
                return true
            },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch") },
            activateTerminal: { _, _, _ in terminalActivated = true; return true },
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(switchedSession, "other-project")
        XCTAssertTrue(terminalActivated)
    }

    /// Session doesn't exist → ensureAndSwitch creates + switches
    func testUnifiedActivationCreatesSessionWhenMissing() async {
        var ensureCalled = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "new-proj",
            projectPath: "/new",
            resolveAnyClientTty: { "/dev/ttys001" },
            ensureAndSwitch: { session, path, _ in
                ensureCalled = true
                XCTAssertEqual(session, "new-proj")
                XCTAssertEqual(path, "/new")
                return true
            },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch") },
            activateTerminal: { _, _, _ in true },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(ensureCalled)
    }

    /// Switch fails → returns false
    func testUnifiedActivationReturnsFalseWhenSwitchFails() async {
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "broken",
            projectPath: "/broken",
            resolveAnyClientTty: { "/dev/ttys001" },
            ensureAndSwitch: { _, _, _ in false },
            launchTerminalWithTmux: { _, _ in },
            activateTerminal: { _, _, _ in true },
        )
        XCTAssertFalse(ok)
    }

    /// When a tmux client exists but the terminal that owns the TTY is gone
    /// (activateTerminal returns false), the flow should launch a fresh terminal.
    func testUnifiedActivationLaunchesWhenTerminalGone() async {
        var launched = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "my-project",
            projectPath: "/path/to/project",
            resolveAnyClientTty: { "/dev/ttys001" },
            ensureAndSwitch: { _, _, _ in true },
            launchTerminalWithTmux: { _, _ in launched = true },
            activateTerminal: { _, _, _ in false }, // Terminal focus FAILS (tab gone)
        )
        XCTAssertTrue(ok, "Should succeed via fresh launch")
        XCTAssertTrue(launched, "Should launch new terminal when focus fails")
    }

    // MARK: - Auto-Attach (Detached Session Reuse)

    /// When no tmux client exists but a session is already running (detached),
    /// the flow should attach to the existing session instead of launching
    /// a brand-new terminal tab.
    func testUnifiedActivationAutoAttachesWhenSessionExists() async {
        var attached = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "capacitor",
            projectPath: "/path/to/capacitor",
            resolveAnyClientTty: { nil },
            hasExistingSession: { name in name == "capacitor" },
            ensureAndSwitch: { _, _, _ in XCTFail("should not be called"); return false },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch new — should auto-attach") },
            attachToExistingSession: { session in
                XCTAssertEqual(session, "capacitor")
                attached = true
            },
            activateTerminal: { _, _, _ in XCTFail("should not be called"); return false },
            pollForNewClient: { "/dev/ttys060" },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(attached, "Should auto-attach to existing detached session")
    }

    /// When no tmux client exists and no session exists for the project,
    /// the flow should launch a new terminal (not try to attach).
    func testUnifiedActivationLaunchesNewWhenNoSessionExists() async {
        var launched = false
        var attachCalled = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "brand-new",
            projectPath: "/path/to/brand-new",
            resolveAnyClientTty: { nil },
            hasExistingSession: { _ in false },
            ensureAndSwitch: { _, _, _ in XCTFail("should not be called"); return false },
            launchTerminalWithTmux: { session, path in
                XCTAssertEqual(session, "brand-new")
                XCTAssertEqual(path, "/path/to/brand-new")
                launched = true
            },
            attachToExistingSession: { _ in attachCalled = true },
            activateTerminal: { _, _, _ in XCTFail("should not be called"); return false },
            pollForNewClient: { "/dev/ttys070" },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(launched, "Should launch new terminal when no session exists")
        XCTAssertFalse(attachCalled, "Should NOT auto-attach when session doesn't exist")
    }

    /// When a tmux client already exists, auto-attach logic is skipped entirely —
    /// the normal switch-client flow handles it.
    func testUnifiedActivationSkipsAutoAttachWhenClientExists() async {
        var switched = false
        var attachCalled = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "proj",
            projectPath: "/proj",
            resolveAnyClientTty: { "/dev/ttys001" },
            hasExistingSession: { _ in XCTFail("should not check session when client exists"); return true },
            ensureAndSwitch: { _, _, _ in switched = true; return true },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch") },
            attachToExistingSession: { _ in attachCalled = true },
            activateTerminal: { _, _, _ in true },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(switched, "Should use normal switch-client flow")
        XCTAssertFalse(attachCalled, "Should NOT auto-attach when client exists")
    }

    /// Create fails → return false
    func testEnsureAndSwitchReturnsFalseWhenCreateFails() async {
        let ok = await TerminalLauncher.ensureSessionAndSwitch(
            sessionName: "broken",
            projectPath: "/path/to/broken",
            clientTty: "/dev/ttys001",
            runScript: { _ in (1, "error") },
        )
        XCTAssertFalse(ok)
    }

    // MARK: - Session-Aware Client Resolution

    /// When multiple clients are attached and one is already on the target session,
    /// resolveAnyTmuxClientTty should return that client's TTY (avoids switch-client).
    func testResolveClientTtyPrefersTargetSession() async {
        let tty = await TerminalLauncher.resolveAnyTmuxClientTty(
            targetSession: "capacitor",
            runScript: { cmd in
                if cmd.contains("display-message") {
                    return (1, nil) // Not inside a tmux client
                }
                // Two clients: ttys001 on "other-project", ttys002 on "capacitor"
                return (0, "/dev/ttys001 other-project\n/dev/ttys002 capacitor\n")
            },
        )
        XCTAssertEqual(tty, "/dev/ttys002", "Should prefer client already on target session")
    }

    /// When no client is on the target session, fall back to the first available TTY.
    func testResolveClientTtyFallsBackWhenNoSessionMatch() async {
        let tty = await TerminalLauncher.resolveAnyTmuxClientTty(
            targetSession: "nonexistent-session",
            runScript: { cmd in
                if cmd.contains("display-message") {
                    return (1, nil)
                }
                return (0, "/dev/ttys001 alpha\n/dev/ttys002 beta\n")
            },
        )
        XCTAssertEqual(tty, "/dev/ttys001", "Should fall back to first client when no session matches")
    }

    func testResolvePreferredTerminalAppPrefersClientTtyMatch() {
        let shellState = ShellCwdState(
            version: 1,
            shells: [
                "100": ShellEntry(
                    cwd: "/Users/pete/Code/capacitor",
                    tty: "/dev/ttys010",
                    parentApp: "Ghostty",
                    tmuxSession: "caps",
                    tmuxClientTty: "/dev/ttys001",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                ),
                "101": ShellEntry(
                    cwd: "/Users/pete/Code/capacitor",
                    tty: "/dev/ttys020",
                    parentApp: "iTerm2",
                    tmuxSession: "caps",
                    tmuxClientTty: "/dev/ttys002",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                ),
            ],
        )

        let app = TerminalLauncher.resolvePreferredTerminalApp(
            clientTty: "/dev/ttys002",
            projectPath: "/Users/pete/Code/capacitor",
            sessionName: "caps",
            shellState: shellState,
        )

        XCTAssertEqual(app, .iTerm)
    }

    func testResolvePreferredTerminalAppFallsBackToSessionMatch() {
        let shellState = ShellCwdState(
            version: 1,
            shells: [
                "200": ShellEntry(
                    cwd: "/Users/pete/Code/capacitor",
                    tty: "/dev/ttys030",
                    parentApp: "Terminal",
                    tmuxSession: "caps",
                    tmuxClientTty: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
                ),
            ],
        )

        let app = TerminalLauncher.resolvePreferredTerminalApp(
            clientTty: nil,
            projectPath: "/Users/pete/Code/capacitor",
            sessionName: "caps",
            shellState: shellState,
        )

        XCTAssertEqual(app, .terminal)
    }

    func testLaunchWithCommandSupportsITerm() {
        let script = TerminalScripts.launchWithCommand(
            projectPath: "/Users/pete/Code/capacitor",
            command: "claude --resume",
            preferredApp: .iTerm,
        )

        XCTAssertTrue(script.contains("open -b com.googlecode.iterm2"))
        XCTAssertTrue(script.contains("tell process \"iTerm2\""))
        XCTAssertTrue(script.contains("claude --resume"))
    }

    func testLaunchWithCommandSupportsTerminalApp() {
        let script = TerminalScripts.launchWithCommand(
            projectPath: "/Users/pete/Code/capacitor",
            command: "claude --resume",
            preferredApp: .terminal,
        )

        XCTAssertTrue(script.contains("open -b com.apple.Terminal"))
        XCTAssertTrue(script.contains("tell process \"Terminal\""))
        XCTAssertTrue(script.contains("claude --resume"))
    }

    // MARK: - Helpers

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    private func withLogCollector(
        _ body: (LogCollector) async -> Void,
    ) async {
        let collector = LogCollector()
        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }
        await body(collector)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () async -> Bool,
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            await _Concurrency.Task.yield()
        }
        return await condition()
    }

    private func assertEventually(
        timeout: TimeInterval,
        context: String,
        condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async -> Bool {
        let satisfied = await waitUntil(timeout: timeout, condition: condition)
        XCTAssertTrue(satisfied, context, file: file, line: line)
        return satisfied
    }

    private func waitForStaleSuppressionMarker(
        collector: LogCollector,
        projectPath: String,
        timeout: TimeInterval,
    ) async -> Bool {
        await waitUntil(timeout: timeout) {
            await collector.contains {
                ($0.contains("[TerminalLauncher] ARE snapshot request canceled/stale") ||
                    $0.contains("[TerminalLauncher] ARE snapshot ignored for stale request") ||
                    $0.contains("[TerminalLauncher] launchTerminalAsync ignored stale request")) &&
                    $0.contains(projectPath)
            }
        }
    }

    private func makeGhosttyTab(title: String?, index: Int, isSelected: Bool = false) -> GhosttyTabSnapshot {
        GhosttyTabSnapshot(
            element: AXUIElementCreateSystemWide(),
            title: title,
            index: index,
            isSelected: isSelected,
        )
    }

    private func makeGhosttyWindow(index: Int, isMain: Bool, tabs: [GhosttyTabSnapshot]) -> GhosttyWindowSnapshot {
        GhosttyWindowSnapshot(
            element: AXUIElementCreateSystemWide(),
            index: index,
            tabs: tabs,
            isMain: isMain,
        )
    }
}
