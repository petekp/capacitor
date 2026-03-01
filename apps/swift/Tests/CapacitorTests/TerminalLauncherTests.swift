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

    func testSwitchTmuxSessionActivatesTerminalOnSuccess() async {
        var activateCalls = 0
        var scripts: [String] = []

        let result = await TerminalLauncher.performSwitchTmuxSession(
            sessionName: "writing",
            projectPath: "/Users/pete/Code/writing",
            runScript: { script in
                scripts.append(script)
                if script.contains("display-message") {
                    return (0, "/dev/ttys010\n")
                }
                return (0, nil)
            },
            activateTerminal: { _, _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
        assertScriptsContainAll(
            scripts,
            required: [
                "display-message -p '#{client_tty}'",
                "tmux switch-client -c '/dev/ttys010' -t 'writing'",
            ],
            context: "Switch flow should resolve client tty and target session.",
        )
    }

    func testEnsureTmuxSessionCreatesThenActivates() async {
        var activateCalls = 0
        var callCount = 0

        let result = await TerminalLauncher.performEnsureTmuxSession(
            sessionName: "newproj",
            projectPath: "/Users/pete/Code/newproj",
            runScript: { script in
                defer { callCount += 1 }
                if script.contains("display-message") {
                    return (0, "/dev/ttys022\n")
                }
                switch callCount {
                case 0: return (1, "switch failed")
                case 1: return (0, "created")
                default: return (0, "switched")
                }
            },
            activateTerminal: { _, _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
    }

    func testEnsureTmuxSessionFallsBackToListClientsWhenDisplayMessageUnavailable() async {
        var activateCalls = 0
        var scripts: [String] = []

        let result = await TerminalLauncher.performEnsureTmuxSession(
            sessionName: "agent-skills",
            projectPath: "/Users/pete/Code/agent-skills",
            runScript: { script in
                scripts.append(script)
                if script.contains("display-message -p '#{client_tty}'") {
                    // App process is not running inside tmux; this fails in real usage.
                    return (1, nil)
                }
                if script.contains("list-clients -F '#{client_tty}'") {
                    return (0, "/dev/ttys015\n")
                }
                if script.contains("tmux switch-client -c '/dev/ttys015' -t 'agent-skills'") {
                    return (0, nil)
                }
                if script.contains("tmux switch-client -t 'agent-skills'") {
                    return (1, "no current client")
                }
                if script.contains("tmux new-session -d -s 'agent-skills'") {
                    return (1, "duplicate session")
                }
                return (1, nil)
            },
            activateTerminal: { _, _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
        assertScriptsContainAll(
            scripts,
            required: ["list-clients -F '#{client_tty}'"],
            context: "Expected list-clients fallback lookup",
        )
        assertScriptsContainNone(
            scripts,
            forbidden: ["tmux new-session -d -s 'agent-skills'"],
            context: "Expected no session creation when existing session can be switched",
        )
    }

    func testEnsureTmuxSessionUsesPreferredClientTTYWithoutAutoResolvingAnotherClient() async {
        var activateCalls = 0
        var scripts: [String] = []

        let result = await TerminalLauncher.performEnsureTmuxSession(
            sessionName: "openclaw",
            projectPath: "/Users/pete/Code/openclaw",
            runScript: { script in
                scripts.append(script)
                if script.contains("display-message -p '#{client_tty}'") {
                    XCTFail("Should not resolve client tty when preferred client tty is provided.")
                    return (1, nil)
                }
                if script.contains("list-clients -F '#{client_tty}'") {
                    XCTFail("Should not list tmux clients when preferred client tty is provided.")
                    return (1, nil)
                }
                if script.contains("tmux switch-client -c '/dev/ttys042' -t 'openclaw'") {
                    return (0, nil)
                }
                return (1, nil)
            },
            activateTerminal: { tty, _ in
                activateCalls += 1
                return tty == "/dev/ttys042"
            },
            preferredClientTty: "/dev/ttys042",
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
        assertScriptsContainAll(
            scripts,
            required: ["tmux switch-client -c '/dev/ttys042' -t 'openclaw'"],
            context: "Expected ensure path to target the preferred tmux client tty.",
        )
        assertScriptsContainNone(
            scripts,
            forbidden: [
                "display-message -p '#{client_tty}'",
                "list-clients -F '#{client_tty}'",
            ],
            context: "Preferred tty path should not auto-resolve a different tmux client.",
        )
    }

    func testEnsureTmuxSessionLaunchesWhenNoClientAttachedAfterEnsuringSession() async {
        var activateCalls = 0
        var launched = 0
        var scripts: [String] = []

        let result = await TerminalLauncher.performEnsureTmuxSession(
            sessionName: "cap",
            projectPath: "/Users/pete/Code/cap",
            runScript: { script in
                scripts.append(script)
                if script.contains("display-message -p '#{client_tty}'") {
                    return (1, nil)
                }
                if script.contains("list-clients -F '#{client_tty}'") {
                    return (0, "")
                }
                if script.contains("tmux switch-client -t 'cap'") {
                    return (1, "no current client")
                }
                if script.contains("tmux has-session -t 'cap'") {
                    return (0, nil)
                }
                if script.contains("tmux new-session -d -s 'cap'") {
                    XCTFail("Did not expect session creation when has-session succeeds")
                    return (1, nil)
                }
                return (1, nil)
            },
            activateTerminal: { _, _ in
                activateCalls += 1
                return true
            },
            launchWhenNoClient: {
                launched += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 0, "No tmux client is attached, so terminal activation callback should not run")
        XCTAssertEqual(launched, 1, "Expected a single terminal launch to attach the ensured session")
        assertScriptsContainAll(
            scripts,
            required: ["tmux has-session -t 'cap'"],
            context: "Expected has-session check before deciding whether creation is needed",
        )
    }

    func testSwitchTmuxSessionDoesNotActivateOnFailure() async {
        var activateCalls = 0

        let result = await TerminalLauncher.performSwitchTmuxSession(
            sessionName: "broken",
            projectPath: "/Users/pete/Code/broken",
            runScript: { script in
                if script.contains("display-message") {
                    return (0, "/dev/ttys044\n")
                }
                return (1, "switch failed")
            },
            activateTerminal: { _, _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertFalse(result)
        XCTAssertEqual(activateCalls, 0)
    }

    func testSwitchTmuxSessionUsesExplicitClientTTYWhenAvailable() async {
        var scripts: [String] = []
        var activateCalls = 0

        let result = await TerminalLauncher.performSwitchTmuxSession(
            sessionName: "capacitor",
            projectPath: "/Users/pete/Code/capacitor",
            runScript: { script in
                scripts.append(script)
                if script.contains("display-message") {
                    return (0, "/dev/ttys072\n")
                }
                return (0, nil)
            },
            activateTerminal: { _, _ in
                activateCalls += 1
                return true
            },
        )

        XCTAssertTrue(result)
        XCTAssertEqual(activateCalls, 1)
        assertScriptsContainAll(
            scripts,
            required: [
                "display-message -p '#{client_tty}'",
                "tmux switch-client -c '/dev/ttys072' -t 'capacitor'",
            ],
            context: "Expected explicit tmux client tty lookup and switch target",
        )
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

    func testSwitchTmuxSessionFocusesProjectPaneWhenPresent() async {
        var scripts: [String] = []

        let result = await TerminalLauncher.performSwitchTmuxSession(
            sessionName: "workspace",
            projectPath: "/Users/pete/Code/project-b",
            runScript: { script in
                scripts.append(script)
                if script.contains("display-message -p '#{client_tty}'") {
                    return (0, "/dev/ttys072\n")
                }
                if script.contains("tmux switch-client -c '/dev/ttys072' -t 'workspace'") {
                    return (0, nil)
                }
                if script.contains("tmux list-panes -t 'workspace' -F '#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_path}'") {
                    return (0, "workspace\t0\t0\t/Users/pete/Code/project-a\nworkspace\t0\t1\t/Users/pete/Code/project-b\n")
                }
                if script.contains("tmux switch-client -c '/dev/ttys072' -t 'workspace:0'") {
                    return (0, nil)
                }
                if script.contains("tmux select-pane -t 'workspace:0.1'") {
                    return (0, nil)
                }
                return (1, nil)
            },
            activateTerminal: { _, _ in true },
        )

        XCTAssertTrue(result)
        assertScriptsContainAll(
            scripts,
            required: ["tmux select-pane -t 'workspace:0.1'"],
            context: "Expected switch flow to focus project-specific pane",
        )
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

    func testEnsureTmuxSessionFocusesProjectPaneWhenPresent() async {
        var scripts: [String] = []
        var callCount = 0

        let result = await TerminalLauncher.performEnsureTmuxSession(
            sessionName: "workspace",
            projectPath: "/Users/pete/Code/project-b",
            runScript: { script in
                defer { callCount += 1 }
                scripts.append(script)
                if script.contains("display-message -p '#{client_tty}'") {
                    return (0, "/dev/ttys072\n")
                }
                if script.contains("tmux switch-client -c '/dev/ttys072' -t 'workspace'") {
                    // First switch attempt fails, retry after ensure succeeds.
                    return callCount == 1 ? (1, "can't find session") : (0, nil)
                }
                if script.contains("tmux has-session -t 'workspace'") {
                    return (0, nil)
                }

                if script.contains("tmux list-panes -t 'workspace' -F '#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_path}'") {
                    return (0, "workspace\t1\t0\t/Users/pete/Code/project-a\nworkspace\t1\t1\t/Users/pete/Code/project-b\n")
                }
                if script.contains("tmux switch-client -c '/dev/ttys072' -t 'workspace:1'") {
                    return (0, nil)
                }
                if script.contains("tmux select-pane -t 'workspace:1.1'") {
                    return (0, nil)
                }
                return (1, nil)
            },
            activateTerminal: { _, _ in true },
        )

        XCTAssertTrue(result)
        assertScriptsContainAll(
            scripts,
            required: ["tmux select-pane -t 'workspace:1.1'"],
            context: "Expected ensure flow to focus project-specific pane",
        )
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
                name: "stale_after_primary_action_started",
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
                    executeActivationActionOverride: { _, projectPath, _ in
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

    func testLaunchTerminalPrimaryFailureAndStaleSuppressionScenarios() async throws {
        enum Scenario {
            case primaryEnsureFailsThenFallbackLaunch
            case primaryLaunchFailsWithoutSecondFallback
            case stalePrimaryFailureSuppressedByNewerClick
        }

        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        let scenarios: [(name: String, kind: Scenario)] = [
            ("primary_ensure_fails_then_fallback_launch", .primaryEnsureFailsThenFallbackLaunch),
            ("primary_launch_fails_without_second_fallback", .primaryLaunchFailsWithoutSecondFallback),
            ("stale_primary_failure_suppressed_by_newer_click", .stalePrimaryFailureSuppressedByNewerClick),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.name)
            var actions: [(path: String, action: ActivationAction)] = []
            var results: [TerminalActivationResult] = []
            var stalePrimaryEntered: XCTestExpectation?
            let releaseStalePrimary = AsyncGate()

            let launcher = TerminalLauncher(
                appleScript: StubAppleScriptClient(shouldSucceed: true),
                resolveActivationDecisionOverride: { project in
                    switch scenario.kind {
                    case .primaryEnsureFailsThenFallbackLaunch:
                        return ActivationDecision(
                            primary: .ensureTmuxSession(sessionName: "project-a", projectPath: project.path),
                            fallback: .launchNewTerminal(projectPath: project.path, projectName: project.name),
                            reason: "TMUX_SESSION_DETACHED",
                            trace: nil,
                        )
                    case .primaryLaunchFailsWithoutSecondFallback:
                        return ActivationDecision(
                            primary: .launchNewTerminal(projectPath: project.path, projectName: project.name),
                            fallback: nil,
                            reason: "NO_TRUSTED_EVIDENCE",
                            trace: nil,
                        )
                    case .stalePrimaryFailureSuppressedByNewerClick:
                        if project.path == projectA.path {
                            return ActivationDecision(
                                primary: .ensureTmuxSession(sessionName: "project-a", projectPath: projectA.path),
                                fallback: .launchNewTerminal(projectPath: projectA.path, projectName: projectA.name),
                                reason: "TMUX_SESSION_DETACHED",
                                trace: nil,
                            )
                        }
                        return Self.makeAttachedTerminalAppDecision(
                            projectPath: project.path,
                            projectName: project.name,
                            appName: "Ghostty",
                        )
                    }
                },
                executeActivationActionOverride: { action, projectPath, _ in
                    actions.append((projectPath, action))
                    switch scenario.kind {
                    case .primaryEnsureFailsThenFallbackLaunch:
                        switch action {
                        case .ensureTmuxSession:
                            return false
                        case .launchNewTerminal:
                            return true
                        default:
                            return true
                        }
                    case .primaryLaunchFailsWithoutSecondFallback:
                        if case .launchNewTerminal = action {
                            return false
                        }
                        return true
                    case .stalePrimaryFailureSuppressedByNewerClick:
                        if projectPath == projectA.path {
                            if case .ensureTmuxSession = action {
                                stalePrimaryEntered?.fulfill()
                                await releaseStalePrimary.wait()
                                return false
                            }
                            if case .launchNewTerminal = action {
                                return true
                            }
                        }
                        return true
                    }
                },
            )

            launcher.onActivationResult = { result in
                results.append(result)
            }

            switch scenario.kind {
            case .primaryEnsureFailsThenFallbackLaunch, .primaryLaunchFailsWithoutSecondFallback:
                launcher.launchTerminal(for: projectA)
            case .stalePrimaryFailureSuppressedByNewerClick:
                stalePrimaryEntered = expectation(description: "\(scenario.name)-stale-primary-entered")
                launcher.launchTerminal(for: projectA)
                try await fulfillment(of: [XCTUnwrap(stalePrimaryEntered)], timeout: 1.0)
                launcher.launchTerminal(for: projectB)
                await releaseStalePrimary.open()
            }

            _ = await assertEventually(
                timeout: 1.5,
                context: "\(context) Expected scenario to emit one terminal activation result.",
            ) {
                results.count == 1
            }

            switch scenario.kind {
            case .primaryEnsureFailsThenFallbackLaunch:
                XCTAssertEqual(actions.count, 2, "\(context) Expected one primary and one fallback action.")
                if actions.count == 2 {
                    assertAction(
                        actions[0].action,
                        expected: .ensureTmux(
                            sessionName: "project-a",
                            projectPath: projectA.path,
                        ),
                        context: "\(context) Expected ensureTmuxSession primary action.",
                    )
                    assertAction(
                        actions[1].action,
                        expected: .launch(
                            projectPath: projectA.path,
                            projectName: projectA.name,
                        ),
                        context: "\(context) Expected launchNewTerminal fallback action.",
                    )
                }
                XCTAssertEqual(results.first?.projectPath, projectA.path)
                XCTAssertEqual(results.first?.success, true)
                XCTAssertEqual(results.first?.usedFallback, true)
            case .primaryLaunchFailsWithoutSecondFallback:
                assertSingleAction(
                    actions.map(\.action),
                    expected: .launch(projectPath: projectA.path, projectName: projectA.name),
                    context: "\(context) Expected launchNewTerminal primary action.",
                )
                assertSingleActivationResult(
                    results,
                    expectedPath: projectA.path,
                    expectedSuccess: false,
                    expectedUsedFallback: false,
                    context: "\(context)",
                )
            case .stalePrimaryFailureSuppressedByNewerClick:
                let staleFallbackLaunches = actions.filter { entry in
                    guard entry.path == projectA.path else { return false }
                    if case .launchNewTerminal = entry.action {
                        return true
                    }
                    return false
                }
                XCTAssertTrue(
                    staleFallbackLaunches.isEmpty,
                    "\(context) Stale request must not launch fallback after newer click wins.",
                )
                assertSingleActivationResult(
                    results,
                    expectedPath: projectB.path,
                    expectedSuccess: true,
                    expectedUsedFallback: false,
                    context: "\(context)",
                )
            }
        }
    }

    func testLaunchTerminalSnapshotFetchFailureScenariosFollowFallbackContracts() async {
        struct ExpectedFallbackOutcome {
            let primaryAction: ExpectedActivationAction?
            let launchCount: Int
            let success: Bool
            let resultCount: Int
            let expectDebounceMarker: Bool
            let launchAttemptsAreStaged: Bool
        }

        struct Case {
            let name: String
            let project: Project
            let resolvedSessionName: String?
            let exactSessionExists: Bool
            let launchOutcome: Bool
            let launchAttempts: Int
            let expected: ExpectedFallbackOutcome
        }

        let cases = [
            Case(
                name: "launch_fallback_success",
                project: makeProject(name: "project-a", path: "/Users/pete/Code/project-a"),
                resolvedSessionName: nil,
                exactSessionExists: false,
                launchOutcome: true,
                launchAttempts: 1,
                expected: ExpectedFallbackOutcome(
                    primaryAction: nil,
                    launchCount: 1,
                    success: true,
                    resultCount: 1,
                    expectDebounceMarker: false,
                    launchAttemptsAreStaged: false,
                ),
            ),
            Case(
                name: "launch_fallback_failure",
                project: makeProject(name: "project-a", path: "/Users/pete/Code/project-a"),
                resolvedSessionName: nil,
                exactSessionExists: false,
                launchOutcome: false,
                launchAttempts: 1,
                expected: ExpectedFallbackOutcome(
                    primaryAction: nil,
                    launchCount: 1,
                    success: false,
                    resultCount: 1,
                    expectDebounceMarker: false,
                    launchAttemptsAreStaged: false,
                ),
            ),
            Case(
                name: "recover_via_resolved_tmux_session",
                project: makeProject(name: "project-a", path: "/Users/pete/Code/project-a"),
                resolvedSessionName: "project-a",
                exactSessionExists: false,
                launchOutcome: true,
                launchAttempts: 1,
                expected: ExpectedFallbackOutcome(
                    primaryAction: .ensureTmux(
                        sessionName: "project-a",
                        projectPath: "/Users/pete/Code/project-a",
                    ),
                    launchCount: 0,
                    success: true,
                    resultCount: 1,
                    expectDebounceMarker: false,
                    launchAttemptsAreStaged: false,
                ),
            ),
            Case(
                name: "recover_via_exact_session_name",
                project: makeProject(name: "agent-skills", path: "/Users/pete/Code/agent-skills"),
                resolvedSessionName: nil,
                exactSessionExists: true,
                launchOutcome: true,
                launchAttempts: 1,
                expected: ExpectedFallbackOutcome(
                    primaryAction: .ensureTmux(
                        sessionName: "agent-skills",
                        projectPath: "/Users/pete/Code/agent-skills",
                    ),
                    launchCount: 0,
                    success: true,
                    resultCount: 1,
                    expectDebounceMarker: false,
                    launchAttemptsAreStaged: false,
                ),
            ),
            Case(
                name: "rapid_repeat_snapshot_failure_debounces_fallback_launch",
                project: makeProject(name: "project-a", path: "/Users/pete/Code/project-a"),
                resolvedSessionName: nil,
                exactSessionExists: false,
                launchOutcome: true,
                launchAttempts: 2,
                expected: ExpectedFallbackOutcome(
                    primaryAction: nil,
                    launchCount: 1,
                    success: true,
                    resultCount: 2,
                    expectDebounceMarker: true,
                    launchAttemptsAreStaged: true,
                ),
            ),
        ]

        for testCase in cases {
            let context = scenarioContext(testCase.name)
            await withLogCollector { collector in
                var actions: [ActivationAction] = []
                var launchedFallbacks: [(path: String, name: String)] = []
                var results: [TerminalActivationResult] = []

                let launcher = TerminalLauncher(
                    appleScript: StubAppleScriptClient(shouldSucceed: true),
                    resolveActivationDecisionOverride: { _ in
                        throw SnapshotFetchError.unavailable
                    },
                    fallbackTmuxSessionResolver: { _ in
                        testCase.resolvedSessionName
                    },
                    fallbackTmuxSessionExistsResolver: { sessionName in
                        testCase.exactSessionExists && sessionName == testCase.project.name
                    },
                    executeActivationActionOverride: { action, _, _ in
                        actions.append(action)
                        guard let expectedAction = testCase.expected.primaryAction else {
                            return false
                        }
                        return Self.actionMatches(action, expected: expectedAction)
                    },
                    launchNewTerminalOverride: { path, name in
                        launchedFallbacks.append((path, name))
                        return testCase.launchOutcome
                    },
                )

                launcher.onActivationResult = { result in
                    results.append(result)
                }

                if testCase.expected.launchAttemptsAreStaged {
                    launcher.launchTerminal(for: testCase.project)
                    _ = await assertEventually(
                        timeout: 1.0,
                        context: "\(context) Expected first fallback launch before repeated click.",
                    ) {
                        launchedFallbacks.count == 1 && results.count >= 1
                    }
                    for _ in 1 ..< testCase.launchAttempts {
                        launcher.launchTerminal(for: testCase.project)
                    }
                } else {
                    for _ in 0 ..< testCase.launchAttempts {
                        launcher.launchTerminal(for: testCase.project)
                    }
                }
                _ = await assertEventually(
                    timeout: 1.5,
                    context: "\(context) Expected fallback outcome count.",
                ) {
                    results.count == testCase.expected.resultCount
                }

                if let expectedAction = testCase.expected.primaryAction {
                    assertSingleAction(
                        actions,
                        expected: expectedAction,
                        context: "\(context) Expected exactly one recovery action.",
                    )
                } else {
                    XCTAssertTrue(actions.isEmpty, "\(context) No ensureTmuxSession action expected.")
                }

                XCTAssertEqual(
                    launchedFallbacks.count,
                    testCase.expected.launchCount,
                    "\(context) Unexpected launchNewTerminal count.",
                )
                if testCase.expected.launchCount > 0 {
                    XCTAssertEqual(launchedFallbacks.first?.path, testCase.project.path)
                    XCTAssertEqual(launchedFallbacks.first?.name, testCase.project.name)
                }

                if testCase.expected.resultCount == 1 {
                    assertSingleActivationResult(
                        results,
                        expectedPath: testCase.project.path,
                        expectedSuccess: testCase.expected.success,
                        expectedUsedFallback: true,
                        context: "\(context)",
                    )
                } else {
                    XCTAssertEqual(results.count, testCase.expected.resultCount)
                    XCTAssertTrue(
                        results.allSatisfy { result in
                            result.projectPath == testCase.project.path &&
                                result.success == testCase.expected.success &&
                                result.usedFallback
                        },
                        "\(context) Expected repeated fallback outcomes to preserve path/success/usedFallback contract.",
                    )
                }

                if testCase.expected.expectDebounceMarker {
                    _ = await assertEventually(
                        timeout: 1.0,
                        context: "\(context) Expected debounce marker for repeated snapshot failure fallback.",
                    ) {
                        await collector.contains {
                            $0.contains("[TerminalLauncher] snapshot_unavailable_fallback debounced path=\(testCase.project.path)")
                        }
                    }
                }
            }
        }
    }

    func testLaunchTerminalNoTrustedEvidenceScenariosPreferRecoveryBeforeLaunch() async {
        struct ExpectedNoTrustedEvidenceOutcome {
            let action: ExpectedActivationAction
            let maxElapsed: TimeInterval?
            let expectFallbackLaunchMarker: Bool
        }

        struct Case {
            let name: String
            let project: Project
            let resolvedSessionName: String?
            let expected: ExpectedNoTrustedEvidenceOutcome
        }

        let cases = [
            Case(
                name: "cold_start_launches_without_stall",
                project: makeProject(name: "project-a", path: "/Users/pete/Code/project-a"),
                resolvedSessionName: nil,
                expected: ExpectedNoTrustedEvidenceOutcome(
                    action: .launch(
                        projectPath: "/Users/pete/Code/project-a",
                        projectName: "project-a",
                    ),
                    maxElapsed: 0.5,
                    expectFallbackLaunchMarker: true,
                ),
            ),
            Case(
                name: "recoverable_tmux_session_beats_launch",
                project: makeProject(name: "assistant-ui", path: "/Users/pete/Code/assistant-ui"),
                resolvedSessionName: "assistant-ui",
                expected: ExpectedNoTrustedEvidenceOutcome(
                    action: .ensureTmux(
                        sessionName: "assistant-ui",
                        projectPath: "/Users/pete/Code/assistant-ui",
                    ),
                    maxElapsed: nil,
                    expectFallbackLaunchMarker: false,
                ),
            ),
        ]

        for testCase in cases {
            let context = scenarioContext(testCase.name)
            await withLogCollector { collector in
                var actions: [ActivationAction] = []
                var results: [TerminalActivationResult] = []
                var elapsed: TimeInterval?
                let startedAt = Date()

                let launcher = TerminalLauncher(
                    appleScript: StubAppleScriptClient(shouldSucceed: true),
                    resolveActivationDecisionOverride: { project in
                        ActivationDecision(
                            primary: .launchNewTerminal(projectPath: project.path, projectName: project.name),
                            fallback: nil,
                            reason: "NO_TRUSTED_EVIDENCE",
                            trace: nil,
                        )
                    },
                    fallbackTmuxSessionResolver: { _ in
                        testCase.resolvedSessionName
                    },
                    executeActivationActionOverride: { action, _, _ in
                        actions.append(action)
                        return Self.actionMatches(action, expected: testCase.expected.action)
                    },
                )

                launcher.onActivationResult = { result in
                    results.append(result)
                    elapsed = Date().timeIntervalSince(startedAt)
                }

                launcher.launchTerminal(for: testCase.project)
                _ = await assertEventually(
                    timeout: 1.0,
                    context: "\(context) Expected scenario to complete.",
                ) {
                    actions.count == 1 && results.count == 1
                }

                assertSingleAction(
                    actions,
                    expected: testCase.expected.action,
                    context: "\(context) Expected deterministic primary action.",
                )

                assertSingleActivationResult(
                    results,
                    expectedPath: testCase.project.path,
                    expectedSuccess: true,
                    expectedUsedFallback: false,
                    context: "\(context)",
                )

                if let maxElapsed = testCase.expected.maxElapsed {
                    XCTAssertLessThan(
                        elapsed ?? .infinity,
                        maxElapsed,
                        "\(context) Expected no-trusted-evidence path to resolve without visible stall.",
                    )
                }

                let markerTimeout: TimeInterval = testCase.expected.expectFallbackLaunchMarker ? 1.0 : 0.2
                let foundFallbackMarker = await waitUntil(timeout: markerTimeout) {
                    await collector.contains {
                        $0.contains("[TerminalLauncher] ARE no tmux session for recovery path=\(testCase.project.path)")
                    }
                }
                if testCase.expected.expectFallbackLaunchMarker {
                    XCTAssertTrue(
                        foundFallbackMarker,
                        "\(context) Expected no-trusted-evidence launch marker.",
                    )
                } else {
                    XCTAssertFalse(
                        foundFallbackMarker,
                        "\(context) Did not expect no-trusted-evidence launch marker when tmux recovery wins.",
                    )
                }
            }
        }
    }

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
