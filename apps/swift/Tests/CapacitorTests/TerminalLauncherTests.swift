@testable import Capacitor
import XCTest

@MainActor
final class TerminalLauncherTests: XCTestCase {
    private enum SnapshotFetchError: Error {
        case unavailable
    }

    private enum ExpectedActivationAction {
        case launch(projectPath: String, projectName: String)
        case ensureTmux(sessionName: String, projectPath: String)
    }

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

        init(shouldSucceed: Bool) {
            self.shouldSucceed = shouldSucceed
        }

        func run(_: String) {}
        func runChecked(_ script: String) -> Bool {
            checkedScripts.append(script)
            return shouldSucceed
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

    func testCompleteTerminalActivationAfterTmuxSwitchUsesGhosttyRoutingWhenTTYDiscoveryFails() async {
        var seenTTY: String?
        var seenGhosttyTTY: String?
        var seenGhosttyPath: String?
        var seenGhosttySessionHint: String?
        var activatedTerminalApp = false

        let result = await TerminalLauncher.completeTerminalActivationAfterTmuxSwitch(
            clientTty: "/dev/ttys200",
            projectPath: "/Users/pete/Code/assistant-ui",
            activateByTTYDiscovery: { tty in
                seenTTY = tty
                return false
            },
            activateGhosttyByAXRouting: { tty, projectPath, sessionHint in
                seenGhosttyTTY = tty
                seenGhosttyPath = projectPath
                seenGhosttySessionHint = sessionHint
                return true
            },
            isGhosttyRunning: { true },
            activateTerminalApp: { activatedTerminalApp = true },
            tmuxSessionHint: "assistant-ui",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(seenTTY, "/dev/ttys200")
        XCTAssertEqual(seenGhosttyTTY, "/dev/ttys200")
        XCTAssertEqual(seenGhosttyPath, "/Users/pete/Code/assistant-ui")
        XCTAssertEqual(seenGhosttySessionHint, "assistant-ui")
        XCTAssertFalse(activatedTerminalApp)
    }

    /// When both TTY discovery and AX routing fail (e.g., orphaned tmux client
    /// after tab closure), the terminal app is activated as a best effort but
    /// the method returns false — the caller should clear state and relaunch.
    func testCompleteTerminalActivationReturnsFalseWhenBothDiscoveryAndAXFail() async {
        var activatedTerminalApp = false

        let result = await TerminalLauncher.completeTerminalActivationAfterTmuxSwitch(
            clientTty: "/dev/ttys200",
            projectPath: "/Users/pete/Code/agentic-canvas-v2",
            activateByTTYDiscovery: { _ in false },
            activateGhosttyByAXRouting: { _, _, _ in false }, // AX routing couldn't find tab
            isGhosttyRunning: { true },
            activateTerminalApp: { activatedTerminalApp = true },
            tmuxSessionHint: "agentic-canvas-v2",
        )

        XCTAssertFalse(result, "Should return false when neither TTY discovery nor AX routing can focus the right tab")
        XCTAssertTrue(activatedTerminalApp, "Terminal app still activated as best effort")
    }

    func testBestTmuxPaneTargetForProjectPathPrefersExactMatch() {
        let output = "workspace\t0\t0\t/Users/pete/Code/project-a\nworkspace\t0\t1\t/Users/pete/Code/project-b\n"
        let target = TerminalLauncher.bestTmuxPaneTargetForProjectPath(
            output: output,
            sessionName: "workspace",
            projectPath: "/Users/pete/Code/project-b",
            homeDirectory: "/Users/pete",
        )
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.windowIndex, "0")
        XCTAssertEqual(target?.paneIndex, "1")
    }

    func testActivateByTtyReturnsFalseWhenAppleScriptFails() async {
        let launcher = TerminalLauncher(appleScript: StubAppleScriptClient(shouldSucceed: false))
        let result = await launcher.activateByTtyAction(tty: "/dev/ttys001", terminalType: .iTerm, projectPath: nil)
        XCTAssertFalse(result)
    }

    func testActivateByTtyReturnsFalseWhenTerminalAppAppleScriptFails() async {
        let launcher = TerminalLauncher(appleScript: StubAppleScriptClient(shouldSucceed: false))
        let result = await launcher.activateByTtyAction(tty: "/dev/ttys002", terminalType: .terminalApp, projectPath: nil)
        XCTAssertFalse(result)
    }

    func testActivateByTtyITermScriptGuardsAgainstLaunchingWhenNotRunning() async {
        let appleScript = StubAppleScriptClient(shouldSucceed: true)
        let launcher = TerminalLauncher(appleScript: appleScript)

        _ = await launcher.activateByTtyAction(tty: "/dev/ttys001", terminalType: .iTerm, projectPath: nil)

        XCTAssertTrue(
            appleScript.checkedScripts.contains { $0.contains("if application \"iTerm\" is running then") },
            "TTY activation should never auto-launch iTerm when it is not already running.",
        )
    }

    func testActivateByTtyTerminalScriptGuardsAgainstLaunchingWhenNotRunning() async {
        let appleScript = StubAppleScriptClient(shouldSucceed: true)
        let launcher = TerminalLauncher(appleScript: appleScript)

        _ = await launcher.activateByTtyAction(tty: "/dev/ttys002", terminalType: .terminalApp, projectPath: nil)

        XCTAssertTrue(
            appleScript.checkedScripts.contains { $0.contains("if application \"Terminal\" is running then") },
            "TTY activation should never auto-launch Terminal.app when it is not already running.",
        )
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

    // MARK: - Ghostty Tab Bookmark Tests

    func testTryBookmarkedGhosttyTabFocusesTabAtStoredIndex() {
        let reader = StubGhosttyWindowReader()
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "pnpm dev", index: 0, isSelected: true),
                makeGhosttyTab(title: "capacitor: ~/Code/capacitor", index: 1, isSelected: false),
            ]),
        ]

        // Bookmark says tab 1 in window 0 is the tmux tab.
        // After tmux switch-client, the title may be stale, but the tab is still correct.
        let result = TerminalLauncher.tryBookmarkedGhosttyTab(
            windows: windows,
            bookmarkedTabIndex: (windowIndex: 0, tabIndex: 1),
            ghosttyWindowReader: reader,
        )

        XCTAssertEqual(result, .tabPress)
        XCTAssertEqual(reader.focusedTabs.count, 1)
        XCTAssertEqual(reader.focusedTabs.first?.index, 1)
    }

    func testTryBookmarkedGhosttyTabReturnsNilWhenIndexOutOfRange() {
        let reader = StubGhosttyWindowReader()
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "capacitor: ~/Code/capacitor", index: 0),
            ]),
        ]

        // Bookmark points to tab index 5 which doesn't exist.
        let result = TerminalLauncher.tryBookmarkedGhosttyTab(
            windows: windows,
            bookmarkedTabIndex: (windowIndex: 0, tabIndex: 5),
            ghosttyWindowReader: reader,
        )

        XCTAssertNil(result)
        XCTAssertEqual(reader.focusedTabs.count, 0)
    }

    func testTryBookmarkedGhosttyTabReturnsNilWhenWindowIndexInvalid() {
        let reader = StubGhosttyWindowReader()
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "capacitor: ~/Code/capacitor", index: 0),
            ]),
        ]

        // Bookmark points to window index 3 which doesn't exist.
        let result = TerminalLauncher.tryBookmarkedGhosttyTab(
            windows: windows,
            bookmarkedTabIndex: (windowIndex: 3, tabIndex: 0),
            ghosttyWindowReader: reader,
        )

        XCTAssertNil(result)
        XCTAssertEqual(reader.focusedTabs.count, 0)
    }

    func testTryBookmarkedGhosttyTabReturnsNilWhenFocusFails() {
        let reader = StubGhosttyWindowReader()
        reader.focusTabResult = false
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "capacitor: ~/Code/capacitor", index: 0),
            ]),
        ]

        let result = TerminalLauncher.tryBookmarkedGhosttyTab(
            windows: windows,
            bookmarkedTabIndex: (windowIndex: 0, tabIndex: 0),
            ghosttyWindowReader: reader,
        )

        XCTAssertNil(result, "Bookmark should fail when AX focusTab returns false")
        XCTAssertEqual(reader.focusedTabs.count, 1, "Should have attempted to focus the tab")
    }

    func testTryBookmarkedGhosttyTabReturnsNilWhenStoredTitleDoesNotMatchCurrentTab() {
        let reader = StubGhosttyWindowReader()
        // After user closes the tmux tab (was index 1), the tab that was at index 2
        // shifts down to index 1. The bookmark still points to (w=0, t=1) but
        // the tab there now has a different title.
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "pnpm dev", index: 0, isSelected: true),
                makeGhosttyTab(title: "other-project: ~/Code/other", index: 1, isSelected: false),
            ]),
        ]

        let result = TerminalLauncher.tryBookmarkedGhosttyTab(
            windows: windows,
            bookmarkedTabIndex: (windowIndex: 0, tabIndex: 1),
            bookmarkedTabTitle: "capacitor: ~/Code/capacitor",
            ghosttyWindowReader: reader,
        )

        XCTAssertNil(result, "Bookmark should miss when stored title doesn't match tab at index (tab shifted)")
        XCTAssertEqual(reader.focusedTabs.count, 0, "Should NOT attempt to focus a shifted tab")
    }

    func testTryBookmarkedGhosttyTabSucceedsWhenStoredTitleMatchesCurrentTab() {
        let reader = StubGhosttyWindowReader()
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "pnpm dev", index: 0, isSelected: true),
                makeGhosttyTab(title: "capacitor: ~/Code/capacitor", index: 1, isSelected: false),
            ]),
        ]

        let result = TerminalLauncher.tryBookmarkedGhosttyTab(
            windows: windows,
            bookmarkedTabIndex: (windowIndex: 0, tabIndex: 1),
            bookmarkedTabTitle: "capacitor: ~/Code/capacitor",
            ghosttyWindowReader: reader,
        )

        XCTAssertEqual(result, .tabPress, "Bookmark should succeed when stored title matches")
        XCTAssertEqual(reader.focusedTabs.count, 1)
    }

    func testTryBookmarkedGhosttyTabSucceedsWhenNoStoredTitle() {
        let reader = StubGhosttyWindowReader()
        let windows = [
            makeGhosttyWindow(index: 0, isMain: true, tabs: [
                makeGhosttyTab(title: "capacitor: ~/Code/capacitor", index: 0),
            ]),
        ]

        // No stored title (nil) — first activation before title propagated.
        // Can't validate, so proceed with focus.
        let result = TerminalLauncher.tryBookmarkedGhosttyTab(
            windows: windows,
            bookmarkedTabIndex: (windowIndex: 0, tabIndex: 0),
            bookmarkedTabTitle: nil,
            ghosttyWindowReader: reader,
        )

        XCTAssertEqual(result, .tabPress, "Bookmark should succeed when no stored title (can't validate)")
        XCTAssertEqual(reader.focusedTabs.count, 1)
    }

    func testTerminalLaunchScriptsHonorAlphaTerminalInvariants() {
        struct LaunchScriptInput {
            let script: String
            let expectNoTmux: Bool
            let expectNoUnsupportedTerminals: Bool
        }

        let scenarios: [LabeledExpectationScenario<LaunchScriptInput, Void>] = [
            LabeledExpectationScenario(
                label: "launch_with_command",
                input: LaunchScriptInput(
                    script: TerminalScripts.launchWithCommand(
                        projectPath: "/Users/pete/Code/myproject",
                        command: "/opt/homebrew/bin/claude --resume abc123",
                    ),
                    expectNoTmux: true,
                    expectNoUnsupportedTerminals: false,
                ),
                expected: (),
            ),
            LabeledExpectationScenario(
                label: "launch_no_tmux",
                input: LaunchScriptInput(
                    script: TerminalScripts.launchNoTmux(
                        projectPath: "/Users/pete/Code/myproject",
                        projectName: "myproject",
                        claudePath: "/opt/homebrew/bin/claude",
                    ),
                    expectNoTmux: true,
                    expectNoUnsupportedTerminals: true,
                ),
                expected: (),
            ),
            LabeledExpectationScenario(
                label: "launch_new_terminal_script_wrapper",
                input: LaunchScriptInput(
                    script: TerminalLauncher.launchNewTerminalScript(
                        projectPath: "/Users/pete/Code/myproject",
                        projectName: "myproject",
                        claudePath: "/opt/homebrew/bin/claude",
                    ),
                    expectNoTmux: true,
                    expectNoUnsupportedTerminals: true,
                ),
                expected: (),
            ),
        ]

        let terminalLaunchPattern = #"tell application \\"Terminal\\" to do script"#
        for scenario in scenarios {
            let context = scenarioContext(scenario.label)
            XCTAssertTrue(
                scenario.input.script.contains("Ghostty.app"),
                "\(context) Expected Ghostty branch in launch script.",
            )
            XCTAssertTrue(
                scenario.input.script.contains("iTerm"),
                "\(context) Expected iTerm branch in launch script.",
            )
            XCTAssertNil(
                scenario.input.script.range(of: terminalLaunchPattern, options: .regularExpression),
                "\(context) Launch script must not spawn Terminal.app fallback.",
            )

            let lowercased = scenario.input.script.lowercased()
            if scenario.input.expectNoTmux {
                assertScriptsContainNone(
                    [lowercased],
                    forbidden: ["tmux"],
                    context: "\(context) Launch script must not reference tmux.",
                )
            }
            if scenario.input.expectNoUnsupportedTerminals {
                assertScriptsContainNone(
                    [lowercased],
                    forbidden: ["alacritty", "warp", "kitty"],
                    context: "\(context) Launch script must not include unsupported terminal branches.",
                )
            }
        }
    }

    func testTerminalAppMatchingNames() {
        XCTAssertTrue(ParentApp.terminal.matchesRunningAppName("Terminal"))
        XCTAssertTrue(ParentApp.terminal.matchesRunningAppName("Terminal.app"))
    }

    func testAlphaSupportedTerminalPriorityOrder() {
        XCTAssertEqual(ParentApp.terminalPriorityOrder, [.ghostty, .iTerm, .terminal])
    }

    func testUnsupportedTerminalsAreNotInstalledForAlpha() {
        XCTAssertFalse(ParentApp.alacritty.isInstalled)
        XCTAssertFalse(ParentApp.kitty.isInstalled)
        XCTAssertFalse(ParentApp.warp.isInstalled)
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

    func testLaunchTerminalRequestArbitrationScenarios() async {
        enum ScenarioKind {
            case overlapResolveGate
            case overlapActionGate
            case sequential
        }

        struct Case {
            let name: String
            let kind: ScenarioKind
            let first: Project
            let followups: [Project]
            let expectedExecutedPaths: [String]
            let expectedResultPaths: [String]
            let expectedStalePath: String?
        }

        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        let cases = [
            Case(
                name: "cross_project_overlap",
                kind: .overlapResolveGate,
                first: projectA,
                followups: [projectB],
                expectedExecutedPaths: [projectB.path],
                expectedResultPaths: [projectB.path],
                expectedStalePath: projectA.path,
            ),
            Case(
                name: "same_project_rapid_repeat",
                kind: .overlapResolveGate,
                first: projectA,
                followups: [projectA, projectA],
                expectedExecutedPaths: [projectA.path],
                expectedResultPaths: [projectA.path],
                expectedStalePath: projectA.path,
            ),
            Case(
                name: "stale_after_activation_started",
                kind: .overlapActionGate,
                first: projectA,
                followups: [projectB],
                expectedExecutedPaths: [projectA.path, projectB.path],
                expectedResultPaths: [projectB.path],
                expectedStalePath: projectA.path,
            ),
            Case(
                name: "sequential_requests_execute_in_order",
                kind: .sequential,
                first: projectA,
                followups: [projectB],
                expectedExecutedPaths: [projectA.path, projectB.path],
                expectedResultPaths: [projectA.path, projectB.path],
                expectedStalePath: nil,
            ),
        ]

        for testCase in cases {
            let context = scenarioContext(testCase.name)
            await withLogCollector { collector in
                var executedPaths: [String] = []
                var resultPaths: [String] = []
                let resolveGateEntered = testCase.kind == .overlapResolveGate
                    ? expectation(description: "\(testCase.name)-resolve-gate-entered")
                    : nil
                let actionGateEntered = testCase.kind == .overlapActionGate
                    ? expectation(description: "\(testCase.name)-action-gate-entered")
                    : nil
                let releaseGate = AsyncGate()
                var resolveCallCount = 0

                let launcher = TerminalLauncher(
                    appleScript: StubAppleScriptClient(shouldSucceed: true),
                    resolveActivationDecisionOverride: { project in
                        // Used as a timing gate for overlapResolveGate scenarios.
                        // The resolver trace is called before the stale check + unified activation.
                        if testCase.kind == .overlapResolveGate {
                            resolveCallCount += 1
                            if resolveCallCount == 1 {
                                resolveGateEntered?.fulfill()
                                await releaseGate.wait()
                            }
                        }
                        return Self.makeAttachedTerminalAppDecision(
                            projectPath: project.path,
                            projectName: project.name,
                            appName: "Ghostty",
                        )
                    },
                    fallbackTmuxSessionResolver: { path in
                        // Return project slug as session name for test determinism.
                        URL(fileURLWithPath: path).lastPathComponent
                    },
                    activateProjectSessionOverride: { _, projectPath in
                        executedPaths.append(projectPath)
                        if testCase.kind == .overlapActionGate, projectPath == testCase.first.path {
                            actionGateEntered?.fulfill()
                            await releaseGate.wait()
                        }
                        return true
                    },
                )

                launcher.onActivationResult = { result in
                    resultPaths.append(result.projectPath)
                }

                launcher.launchTerminal(for: testCase.first)
                switch testCase.kind {
                case .overlapResolveGate:
                    await fulfillment(of: [resolveGateEntered!], timeout: 1.0)
                    for project in testCase.followups {
                        launcher.launchTerminal(for: project)
                    }
                    await releaseGate.open()
                case .overlapActionGate:
                    await fulfillment(of: [actionGateEntered!], timeout: 1.0)
                    for project in testCase.followups {
                        launcher.launchTerminal(for: project)
                    }
                    await releaseGate.open()
                case .sequential:
                    _ = await assertEventually(
                        timeout: 1.0,
                        context: "\(context) Expected first sequential request to complete before next.",
                    ) {
                        executedPaths.count == 1 && resultPaths.count == 1
                    }
                    for project in testCase.followups {
                        launcher.launchTerminal(for: project)
                    }
                }

                _ = await assertEventually(
                    timeout: 1.5,
                    context: "\(context) Expected arbitration scenario to complete.",
                ) {
                    executedPaths.count == testCase.expectedExecutedPaths.count &&
                        resultPaths.count == testCase.expectedResultPaths.count
                }
                XCTAssertEqual(
                    executedPaths,
                    testCase.expectedExecutedPaths,
                    "\(context) Unexpected executed path ordering.",
                )
                XCTAssertEqual(
                    resultPaths,
                    testCase.expectedResultPaths,
                    "\(context) Unexpected result path ordering.",
                )
                if let stalePath = testCase.expectedStalePath {
                    let foundMarker = await waitForStaleSuppressionMarker(
                        collector: collector,
                        projectPath: stalePath,
                        timeout: 1.0,
                    )
                    XCTAssertTrue(
                        foundMarker,
                        "\(context) Expected stale suppression marker for superseded request.",
                    )
                }
            }
        }
    }

    /// Unified flow: activation success/failure reported correctly
    func testLaunchTerminalUnifiedFlowReportsResults() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
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
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
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

    // MARK: - Unified Activation Tests (spec v2)

    func testManagedClientTtyStartsNil() {
        let launcher = TerminalLauncher(
            resolveActivationDecisionOverride: { _ in fatalError() },
        )
        XCTAssertNil(launcher.managedClientTty)
    }

    func testIsTtyAliveReturnsFalseForNonexistentTty() {
        XCTAssertFalse(TerminalLauncher.isTtyAlive("/dev/ttys99999"))
    }

    func testIsTtyAliveReturnsTrueForExistingPath() {
        // /dev/null always exists on macOS
        XCTAssertTrue(TerminalLauncher.isTtyAlive("/dev/null"))
    }

    // S3/S5: Managed TTY alive → use it directly (no resolve call)
    func testResolveTmuxClientUsesManagedWhenAliveAndClientConfirmed() async {
        var resolveAnyCalled = false
        let result = await TerminalLauncher.resolveTmuxClient(
            managedTty: "/dev/ttys001",
            isTtyAlive: { _ in true },
            resolveAnyClientTty: {
                resolveAnyCalled = true
                return "/dev/ttys001" // Confirms the managed TTY is an active client
            },
        )
        XCTAssertEqual(result, "/dev/ttys001")
        XCTAssertTrue(resolveAnyCalled, "Should cross-check managed TTY against active tmux clients")
    }

    // S6: Managed TTY died, another client exists → adopt it
    func testResolveTmuxClientFallsBackToAnyClientWhenManagedDead() async {
        var resolvedAnyCalled = false
        let result = await TerminalLauncher.resolveTmuxClient(
            managedTty: "/dev/ttys99999",
            isTtyAlive: { _ in false },
            resolveAnyClientTty: {
                resolvedAnyCalled = true
                return "/dev/ttys042"
            },
        )
        XCTAssertEqual(result, "/dev/ttys042")
        XCTAssertTrue(resolvedAnyCalled)
    }

    // S1/S7: No managed TTY, no clients → nil (caller must launch)
    func testResolveTmuxClientReturnsNilWhenNoClients() async {
        let result = await TerminalLauncher.resolveTmuxClient(
            managedTty: nil,
            isTtyAlive: { _ in false },
            resolveAnyClientTty: { nil },
        )
        XCTAssertNil(result)
    }

    // Bug: managed TTY device file persists after tab closure, but tmux client is gone.
    // resolveTmuxClient should detect this and return nil (trigger new terminal launch).
    func testResolveTmuxClientReturnsNilWhenDeviceFileExistsButNoClientsAttached() async {
        let result = await TerminalLauncher.resolveTmuxClient(
            managedTty: "/dev/ttys000",
            isTtyAlive: { _ in true }, // Device file still exists
            resolveAnyClientTty: { nil }, // But no tmux clients
        )
        XCTAssertNil(result, "Stale TTY device file should not be treated as a live client")
    }

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

    // S1/S7: No clients at all → launch terminal
    func testUnifiedActivationLaunchesWhenNoClients() async {
        var launched = false
        var capturedTty: String?
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "my-project",
            projectPath: "/path/to/project",
            managedTty: nil,
            isTtyAlive: { _ in false },
            resolveAnyClientTty: { nil },
            ensureAndSwitch: { _, _, _ in XCTFail("should not be called"); return false },
            launchTerminalWithTmux: { session, path in
                XCTAssertEqual(session, "my-project")
                XCTAssertEqual(path, "/path/to/project")
                launched = true
            },
            activateTerminal: { _, _, _ in XCTFail("should not be called"); return false },
            pollForNewClient: { "/dev/ttys050" },
            onManagedTtyUpdate: { capturedTty = $0 },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(launched)
        XCTAssertEqual(capturedTty, "/dev/ttys050")
    }

    // S3: Managed TTY alive + confirmed by tmux, session exists → switch + focus
    func testUnifiedActivationSwitchesOnManagedTty() async {
        var switchedSession: String?
        var terminalActivated = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "other-project",
            projectPath: "/other",
            managedTty: "/dev/ttys001",
            isTtyAlive: { _ in true },
            resolveAnyClientTty: { "/dev/ttys001" }, // Confirms client is attached
            ensureAndSwitch: { session, _, tty in
                switchedSession = session
                XCTAssertEqual(tty, "/dev/ttys001")
                return true
            },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch") },
            activateTerminal: { _, _, _ in terminalActivated = true; return true },
            onManagedTtyUpdate: { _ in },
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(switchedSession, "other-project")
        XCTAssertTrue(terminalActivated)
    }

    // S6: Managed TTY dead, other client exists → adopt + switch
    func testUnifiedActivationAdoptsClientWhenManagedDead() async {
        var adoptedTty: String?
        var switchTty: String?
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "proj",
            projectPath: "/proj",
            managedTty: "/dev/ttys99999",
            isTtyAlive: { _ in false },
            resolveAnyClientTty: { "/dev/ttys042" },
            ensureAndSwitch: { _, _, tty in
                switchTty = tty
                return true
            },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch") },
            activateTerminal: { _, _, _ in true },
            onManagedTtyUpdate: { adoptedTty = $0 },
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(adoptedTty, "/dev/ttys042")
        XCTAssertEqual(switchTty, "/dev/ttys042")
    }

    // S4: Session doesn't exist → ensureAndSwitch creates + switches
    func testUnifiedActivationCreatesSessionWhenMissing() async {
        var ensureCalled = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "new-proj",
            projectPath: "/new",
            managedTty: "/dev/ttys001",
            isTtyAlive: { _ in true },
            resolveAnyClientTty: { "/dev/ttys001" }, // Confirms client is attached
            ensureAndSwitch: { session, path, _ in
                ensureCalled = true
                XCTAssertEqual(session, "new-proj")
                XCTAssertEqual(path, "/new")
                return true
            },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch") },
            activateTerminal: { _, _, _ in true },
            onManagedTtyUpdate: { _ in },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(ensureCalled)
    }

    /// Switch fails → returns false
    func testUnifiedActivationReturnsFalseWhenSwitchFails() async {
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "broken",
            projectPath: "/broken",
            managedTty: "/dev/ttys001",
            isTtyAlive: { _ in true },
            resolveAnyClientTty: { "/dev/ttys001" }, // Client confirmed alive
            ensureAndSwitch: { _, _, _ in false },
            launchTerminalWithTmux: { _, _ in },
            activateTerminal: { _, _, _ in true },
            onManagedTtyUpdate: { _ in },
        )
        XCTAssertFalse(ok)
    }

    /// When managed TTY is alive and tmux confirms the client, but the terminal
    /// that owned the TTY is gone (activateTerminal returns false), the flow
    /// should clear the managed TTY and launch a fresh terminal instead of
    /// silently succeeding with nothing visible.
    func testUnifiedActivationLaunchesWhenManagedClientTerminalGone() async {
        var launched = false
        var managedTtyCleared = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "my-project",
            projectPath: "/path/to/project",
            managedTty: "/dev/ttys001",
            isTtyAlive: { _ in true },
            resolveAnyClientTty: { "/dev/ttys001" }, // Client still in tmux list-clients
            ensureAndSwitch: { _, _, _ in true }, // tmux switch succeeds
            launchTerminalWithTmux: { _, _ in launched = true },
            activateTerminal: { _, _, _ in false }, // Terminal focus FAILS (tab gone)
            onManagedTtyUpdate: { tty in
                if tty == nil { managedTtyCleared = true }
            },
        )
        XCTAssertTrue(ok, "Should succeed via fresh launch")
        XCTAssertTrue(launched, "Should launch new terminal when focus fails")
        XCTAssertTrue(managedTtyCleared, "Should clear managed TTY on terminal gone")
    }

    // MARK: - Auto-Attach (Detached Session Reuse)

    /// When no tmux client exists but a session is already running (detached),
    /// the flow should attach to the existing session instead of launching
    /// a brand-new terminal tab.
    func testUnifiedActivationAutoAttachesWhenSessionExists() async {
        var attached = false
        var capturedTty: String?
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "capacitor",
            projectPath: "/path/to/capacitor",
            managedTty: nil,
            isTtyAlive: { _ in false },
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
            onManagedTtyUpdate: { capturedTty = $0 },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(attached, "Should auto-attach to existing detached session")
        XCTAssertEqual(capturedTty, "/dev/ttys060", "Should still poll and capture new client TTY")
    }

    /// When no tmux client exists and no session exists for the project,
    /// the flow should launch a new terminal (not try to attach).
    func testUnifiedActivationLaunchesNewWhenNoSessionExists() async {
        var launched = false
        var attachCalled = false
        let ok = await TerminalLauncher.performUnifiedActivation(
            sessionName: "brand-new",
            projectPath: "/path/to/brand-new",
            managedTty: nil,
            isTtyAlive: { _ in false },
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
            onManagedTtyUpdate: { _ in },
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
            managedTty: "/dev/ttys001",
            isTtyAlive: { _ in true },
            resolveAnyClientTty: { "/dev/ttys001" },
            hasExistingSession: { _ in XCTFail("should not check session when client exists"); return true },
            ensureAndSwitch: { _, _, _ in switched = true; return true },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch") },
            attachToExistingSession: { _ in attachCalled = true },
            activateTerminal: { _, _, _ in true },
            onManagedTtyUpdate: { _ in },
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

    /// When a recent launch's poll timed out (managedClientTty is nil),
    /// the pre-activation poll should capture the client TTY before
    /// the unified flow runs, preventing a duplicate tab launch.
    func testPrePollCapturesClientAfterRecentLaunch() async {
        let projectA = makeProject(name: "proj", path: "/Users/pete/Code/proj")
        var results: [TerminalActivationResult] = []

        // Use a box to capture the launcher reference indirectly, since
        // we can't use [weak launcher] in the initializer closure.
        class Ref { weak var launcher: TerminalLauncher? }
        let ref = Ref()

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
            fallbackTmuxSessionResolver: { path in
                URL(fileURLWithPath: path).lastPathComponent
            },
            activateProjectSessionOverride: { _, _ in true },
        )
        ref.launcher = launcher
        launcher.onActivationResult = { results.append($0) }

        // Simulate: a launch happened 2 seconds ago but poll timed out.
        launcher.lastTerminalLaunchDate = Date().addingTimeInterval(-2)
        XCTAssertNil(launcher.managedClientTty)

        // Pre-activation poll will find the client.
        launcher.preActivationPollOverride = { "/dev/ttys050" }

        launcher.launchTerminal(for: projectA)
        _ = await assertEventually(timeout: 2.0, context: "Expected activation result") {
            results.count == 1
        }

        // The pre-poll should have set managedClientTty BEFORE activation ran.
        XCTAssertEqual(launcher.managedClientTty, "/dev/ttys050",
                       "Pre-poll should capture client TTY before activation runs")
    }

    /// When lastTerminalLaunchDate is nil (no recent launch), the pre-poll
    /// should NOT run — activation proceeds directly.
    func testNoPrePollWhenNoRecentLaunch() async {
        let projectA = makeProject(name: "proj", path: "/Users/pete/Code/proj")
        var prePollCalled = false
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
            fallbackTmuxSessionResolver: { path in
                URL(fileURLWithPath: path).lastPathComponent
            },
            activateProjectSessionOverride: { _, _ in true },
        )
        launcher.onActivationResult = { results.append($0) }

        // No recent launch — pre-poll should not run.
        XCTAssertNil(launcher.lastTerminalLaunchDate)
        launcher.preActivationPollOverride = {
            prePollCalled = true
            return "/dev/ttys050"
        }

        launcher.launchTerminal(for: projectA)
        _ = await assertEventually(timeout: 2.0, context: "Expected activation result") {
            results.count == 1
        }

        XCTAssertFalse(prePollCalled, "Pre-poll should not run when there's no recent launch")
    }

    /// When lastTerminalLaunchDate is old (>15s), the pre-poll should NOT run.
    func testNoPrePollWhenLaunchIsTooOld() async {
        let projectA = makeProject(name: "proj", path: "/Users/pete/Code/proj")
        var prePollCalled = false
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
            fallbackTmuxSessionResolver: { path in
                URL(fileURLWithPath: path).lastPathComponent
            },
            activateProjectSessionOverride: { _, _ in true },
        )
        launcher.onActivationResult = { results.append($0) }

        // Launch happened 30 seconds ago — too old for cooldown.
        launcher.lastTerminalLaunchDate = Date().addingTimeInterval(-30)
        launcher.preActivationPollOverride = {
            prePollCalled = true
            return "/dev/ttys050"
        }

        launcher.launchTerminal(for: projectA)
        _ = await assertEventually(timeout: 2.0, context: "Expected activation result") {
            results.count == 1
        }

        XCTAssertFalse(prePollCalled, "Pre-poll should not run when launch is older than 15s")
    }

    /// No managed TTY but a client exists → adopt it
    func testResolveTmuxClientAdoptsWhenNoManagedTty() async {
        let result = await TerminalLauncher.resolveTmuxClient(
            managedTty: nil,
            isTtyAlive: { _ in false },
            resolveAnyClientTty: { "/dev/ttys010" },
        )
        XCTAssertEqual(result, "/dev/ttys010")
    }

    // MARK: - Helpers

    private static func makeAttachedTerminalAppDecision(
        projectPath: String,
        projectName: String,
        appName: String,
    ) -> ActivationDecision {
        ActivationDecision(
            primary: .activateApp(appName: appName),
            fallback: .launchNewTerminal(projectPath: projectPath, projectName: projectName),
            reason: "SHELL_ACTIVE",
            trace: nil,
        )
    }

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

    private func scriptsContain(_ scripts: [String], _ snippet: String) -> Bool {
        scripts.contains { $0.contains(snippet) }
    }

    private func assertScriptsContainAll(
        _ scripts: [String],
        required: [String],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        for snippet in required {
            XCTAssertTrue(
                scriptsContain(scripts, snippet),
                "\(context): missing snippet '\(snippet)'\nScripts: \(scripts)",
                file: file,
                line: line,
            )
        }
    }

    private func assertScriptsContainNone(
        _ scripts: [String],
        forbidden: [String],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        for snippet in forbidden {
            XCTAssertFalse(
                scriptsContain(scripts, snippet),
                "\(context): unexpected snippet '\(snippet)'\nScripts: \(scripts)",
                file: file,
                line: line,
            )
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

    private func assertAction(
        _ action: ActivationAction,
        expected: ExpectedActivationAction,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertTrue(
            Self.actionMatches(action, expected: expected),
            "\(context) expected \(expected), got \(String(describing: action))",
            file: file,
            line: line,
        )
    }

    private func assertSingleActivationResult(
        _ results: [TerminalActivationResult],
        expectedPath: String,
        expectedSuccess: Bool,
        expectedUsedFallback: Bool,
        context: String,
    ) {
        XCTAssertEqual(results.count, 1, "\(context) Expected exactly one activation result.")
        XCTAssertEqual(results.first?.projectPath, expectedPath)
        XCTAssertEqual(results.first?.success, expectedSuccess)
        XCTAssertEqual(results.first?.usedFallback, expectedUsedFallback)
    }

    private static func actionMatches(
        _ action: ActivationAction,
        expected: ExpectedActivationAction,
    ) -> Bool {
        switch expected {
        case let .launch(projectPath, projectName):
            guard case let .launchNewTerminal(actualProjectPath, actualProjectName) = action else {
                return false
            }
            return actualProjectPath == projectPath && actualProjectName == projectName
        case let .ensureTmux(sessionName, projectPath):
            guard case let .ensureTmuxSession(actualSessionName, actualProjectPath) = action else {
                return false
            }
            return actualSessionName == sessionName && actualProjectPath == projectPath
        }
    }

    private func assertSingleAction(
        _ actions: [ActivationAction],
        expected: ExpectedActivationAction,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(actions.count, 1, "\(context) Expected exactly one action.", file: file, line: line)
        guard let first = actions.first else { return }
        assertAction(first, expected: expected, context: context, file: file, line: line)
    }
}
