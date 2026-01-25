@testable import Capacitor
import XCTest

@MainActor
final class TerminalLauncherTests: XCTestCase {
    private enum SnapshotFetchError: Error {
        case unavailable
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

    func testTerminalLauncherUsesDecisionOverrideSeamNotRoutingSnapshotSeam() throws {
        let source = try loadTerminalLauncherSource()
        XCTAssertFalse(
            source.contains("RuntimeClient.shared.fetchRoutingSnapshot("),
            "TerminalLauncher should use Rust activation resolver decisions directly, not daemon-shaped routing snapshot client reads.",
        )
        XCTAssertFalse(
            source.contains("fetchCoreRoutingSnapshot"),
            "TerminalLauncher should not expose a routing-snapshot injection seam; tests should inject ActivationDecision directly.",
        )
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

    private func loadTerminalLauncherSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Models/TerminalLauncher.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
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
        XCTAssertTrue(scripts.contains { $0.contains("display-message -p '#{client_tty}'") })
        XCTAssertTrue(scripts.contains { $0.contains("tmux switch-client -c '/dev/ttys010' -t 'writing'") })
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
        XCTAssertTrue(
            scripts.contains { $0.contains("list-clients -F '#{client_tty}'") },
            "Expected list-clients fallback lookup, got scripts: \(scripts)",
        )
        XCTAssertFalse(
            scripts.contains { $0.contains("tmux new-session -d -s 'agent-skills'") },
            "Expected no session creation when existing session can be switched",
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
        XCTAssertTrue(
            scripts.contains { $0.contains("tmux switch-client -c '/dev/ttys042' -t 'openclaw'") },
            "Expected ensure path to target the preferred tmux client tty.",
        )
        XCTAssertFalse(
            scripts.contains { $0.contains("display-message -p '#{client_tty}'") || $0.contains("list-clients -F '#{client_tty}'") },
            "Preferred tty path should not auto-resolve a different tmux client.",
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
        XCTAssertTrue(
            scripts.contains { $0.contains("tmux has-session -t 'cap'") },
            "Expected has-session check before deciding whether creation is needed",
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
        XCTAssertTrue(
            scripts.contains { $0.contains("display-message -p '#{client_tty}'") },
            "Expected tmux client tty lookup before switch, got scripts: \(scripts)",
        )
        XCTAssertTrue(
            scripts.contains { $0.contains("tmux switch-client -c '/dev/ttys072' -t 'capacitor'") },
            "Expected explicit client tty switch target, got scripts: \(scripts)",
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
        XCTAssertTrue(
            scripts.contains { $0.contains("tmux select-pane -t 'workspace:0.1'") },
            "Expected switch flow to focus project-specific pane, got scripts: \(scripts)",
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
        XCTAssertTrue(
            scripts.contains { $0.contains("tmux select-pane -t 'workspace:1.1'") },
            "Expected ensure flow to focus project-specific pane, got scripts: \(scripts)",
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

    func testLaunchWithCommandDoesNotFallbackToTerminal() {
        let script = TerminalScripts.launchWithCommand(
            projectPath: "/Users/pete/Code/myproject",
            command: "/opt/homebrew/bin/claude --resume abc123",
        )

        let terminalLaunchPattern = #"tell application \\"Terminal\\" to do script"#
        XCTAssertNil(
            script.range(of: terminalLaunchPattern, options: .regularExpression),
            "Ideas flow launch must not spawn Terminal.app.",
        )
    }

    func testLaunchWithCommandIncludesGhosttyAndITerm() {
        let script = TerminalScripts.launchWithCommand(
            projectPath: "/Users/pete/Code/myproject",
            command: "/opt/homebrew/bin/claude --resume abc123",
        )

        XCTAssertTrue(script.contains("Ghostty.app"), "Expected Ghostty branch in launchWithCommand script.")
        XCTAssertTrue(script.contains("iTerm"), "Expected iTerm branch in launchWithCommand script.")
    }

    func testLaunchNoTmuxScriptDoesNotReferenceTmux() {
        let script = TerminalScripts.launchNoTmux(
            projectPath: "/Users/pete/Code/myproject",
            projectName: "myproject",
            claudePath: "/opt/homebrew/bin/claude",
        )
        XCTAssertFalse(script.lowercased().contains("tmux"))
    }

    func testLaunchNoTmuxScriptSkipsUnsupportedTerminalsForAlpha() {
        let script = TerminalScripts.launchNoTmux(
            projectPath: "/Users/pete/Code/myproject",
            projectName: "myproject",
            claudePath: "/opt/homebrew/bin/claude",
        )
        let lowercased = script.lowercased()
        XCTAssertFalse(lowercased.contains("alacritty"))
        XCTAssertFalse(lowercased.contains("warp"))
        XCTAssertFalse(lowercased.contains("kitty"))
    }

    func testLaunchNoTmuxScriptDoesNotLaunchTerminalFallback() {
        let script = TerminalScripts.launchNoTmux(
            projectPath: "/Users/pete/Code/myproject",
            projectName: "myproject",
            claudePath: "/opt/homebrew/bin/claude",
        )

        let terminalLaunchPattern = #"tell application \\"Terminal\\" to do script"#
        XCTAssertNil(
            script.range(of: terminalLaunchPattern, options: .regularExpression),
            "Project-card launch fallback must not spawn Terminal.app.",
        )
    }

    func testLaunchNewTerminalScriptDoesNotReferenceTmux() {
        let script = TerminalLauncher.launchNewTerminalScript(
            projectPath: "/Users/pete/Code/myproject",
            projectName: "myproject",
            claudePath: "/opt/homebrew/bin/claude",
        )
        XCTAssertFalse(script.lowercased().contains("tmux"))
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

    func testLaunchTerminalOverlappingRequestsOnlyExecutesLatestClick() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        var executedPaths: [String] = []
        var resultPaths: [String] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { project in
                let projectPath = project.path
                if projectPath == projectA.path {
                    try await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                } else {
                    try await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
                return Self.makeAttachedTerminalAppDecision(projectPath: projectPath, projectName: project.name, appName: "Ghostty")
            },
            executeActivationActionOverride: { _, projectPath, _ in
                executedPaths.append(projectPath)
                return true
            },
        )

        launcher.onActivationResult = { (result: TerminalActivationResult) in
            resultPaths.append(result.projectPath)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 40_000_000)
        launcher.launchTerminal(for: projectB)

        try? await _Concurrency.Task.sleep(nanoseconds: 450_000_000)

        XCTAssertEqual(
            executedPaths,
            [projectB.path],
            "Overlapping clicks should coalesce to the latest request.",
        )
        XCTAssertEqual(
            resultPaths,
            [projectB.path],
            "Only the latest click should emit an activation result.",
        )
    }

    func testLaunchTerminalOverlappingRequestsLogsStaleSnapshotMarker() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        let collector = LogCollector()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { project in
                let projectPath = project.path
                if projectPath == projectA.path {
                    try await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                } else {
                    try await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
                return Self.makeAttachedTerminalAppDecision(projectPath: projectPath, projectName: project.name, appName: "Ghostty")
            },
            executeActivationActionOverride: { _, _, _ in
                true
            },
        )

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 40_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 450_000_000)

        let foundMarker = await collector.contains {
            $0.contains("[TerminalLauncher] ARE snapshot request canceled/stale") &&
                $0.contains(projectA.path)
        }

        XCTAssertTrue(foundMarker, "Expected stale overlap marker for superseded request.")
    }

    func testLaunchTerminalOverlappingRequestsStaleAfterPrimaryEmitsCanonicalStaleMarker() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        let collector = LogCollector()
        var resultPaths: [String] = []

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { project in
                let projectPath = project.path
                return Self.makeAttachedTerminalAppDecision(projectPath: projectPath, projectName: project.name, appName: "Ghostty")
            },
            executeActivationActionOverride: { _, projectPath, _ in
                if projectPath == projectA.path {
                    try? await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                }
                return true
            },
        )

        launcher.onActivationResult = { result in
            resultPaths.append(result.projectPath)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(
            resultPaths,
            [projectB.path],
            "Only the latest request should emit a final outcome after overlap.",
        )
        let foundCanonicalMarker = await collector.contains {
            ($0.contains("[TerminalLauncher] ARE snapshot request canceled/stale") ||
                $0.contains("[TerminalLauncher] ARE snapshot ignored for stale request") ||
                $0.contains("[TerminalLauncher] launchTerminalAsync ignored stale request")) &&
                $0.contains(projectA.path)
        }

        XCTAssertTrue(
            foundCanonicalMarker,
            "Expected canonical stale suppression marker when a request becomes stale during primary action.",
        )
    }

    func testLaunchTerminalSequentialRequestsExecuteInOrder() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        var executedPaths: [String] = []
        var resultPaths: [String] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { project in
                let projectPath = project.path
                try? await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
                return Self.makeAttachedTerminalAppDecision(projectPath: projectPath, projectName: project.name, appName: "Ghostty")
            },
            executeActivationActionOverride: { _, projectPath, _ in
                executedPaths.append(projectPath)
                return true
            },
        )

        launcher.onActivationResult = { (result: TerminalActivationResult) in
            resultPaths.append(result.projectPath)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 120_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(executedPaths, [projectA.path, projectB.path])
        XCTAssertEqual(resultPaths, [projectA.path, projectB.path])
    }

    func testLaunchTerminalPrimaryFailureExecutesSingleFallbackLaunch() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var actions: [ActivationAction] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { project in
                ActivationDecision(
                    primary: .ensureTmuxSession(sessionName: "project-a", projectPath: project.path),
                    fallback: .launchNewTerminal(projectPath: project.path, projectName: project.name),
                    reason: "TMUX_SESSION_DETACHED",
                    trace: nil,
                )
            },
            executeActivationActionOverride: { action, _, _ in
                actions.append(action)
                switch action {
                case .ensureTmuxSession:
                    return false
                case .launchNewTerminal:
                    return true
                default:
                    return true
                }
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(actions.count, 2, "Expected one primary action and one fallback launch action.")
        if actions.count == 2 {
            if case let .ensureTmuxSession(session, path) = actions[0] {
                XCTAssertEqual(session, "project-a")
                XCTAssertEqual(path, project.path)
            } else {
                XCTFail("Expected ensureTmuxSession primary action, got \(String(describing: actions[0]))")
            }
            if case let .launchNewTerminal(path, name) = actions[1] {
                XCTAssertEqual(path, project.path)
                XCTAssertEqual(name, project.name)
            } else {
                XCTFail("Expected launchNewTerminal fallback action, got \(String(describing: actions[1]))")
            }
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.usedFallback, true)
    }

    func testLaunchTerminalPrimaryLaunchFailureDoesNotChainSecondFallback() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var actions: [ActivationAction] = []
        var results: [TerminalActivationResult] = []

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
            executeActivationActionOverride: { action, _, _ in
                actions.append(action)
                if case .launchNewTerminal = action {
                    return false
                }
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(actions.count, 1, "Primary launch failure should not trigger a second launch fallback.")
        if let first = actions.first {
            if case let .launchNewTerminal(path, name) = first {
                XCTAssertEqual(path, project.path)
                XCTAssertEqual(name, project.name)
            } else {
                XCTFail("Expected launchNewTerminal primary action, got \(String(describing: first))")
            }
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.success, false)
        XCTAssertEqual(results.first?.usedFallback, false)
    }

    func testLaunchTerminalSnapshotFetchFailureLaunchesFallbackWithSuccessOutcome() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var launchedFallbacks: [(path: String, name: String)] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
            launchNewTerminalOverride: { path, name in
                launchedFallbacks.append((path, name))
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(launchedFallbacks.count, 1)
        XCTAssertEqual(launchedFallbacks.first?.path, project.path)
        XCTAssertEqual(launchedFallbacks.first?.name, project.name)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.usedFallback, true)
    }

    func testLaunchTerminalSnapshotFetchFailureRecoversViaTmuxSessionBeforeLaunchingNewTerminal() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var actions: [ActivationAction] = []
        var launchedFallbacks: [(path: String, name: String)] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
            fallbackTmuxSessionResolver: { _ in
                "project-a"
            },
            executeActivationActionOverride: { action, _, _ in
                actions.append(action)
                if case let .ensureTmuxSession(sessionName, projectPath) = action {
                    return sessionName == "project-a" && projectPath == project.path
                }
                return false
            },
            launchNewTerminalOverride: { path, name in
                launchedFallbacks.append((path, name))
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(actions.count, 1, "Expected tmux recovery action before considering terminal launch.")
        if let firstAction = actions.first {
            if case let .ensureTmuxSession(sessionName, projectPath) = firstAction {
                XCTAssertEqual(sessionName, "project-a")
                XCTAssertEqual(projectPath, project.path)
            } else {
                XCTFail("Expected ensureTmuxSession recovery action, got \(String(describing: firstAction))")
            }
        }
        XCTAssertTrue(
            launchedFallbacks.isEmpty,
            "Snapshot fetch failure should not spawn a new terminal when tmux recovery succeeds.",
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.usedFallback, true)
    }

    func testLaunchTerminalSnapshotFetchFailureRecoversViaExactSessionNameWhenPathLookupMisses() async {
        let project = makeProject(name: "agent-skills", path: "/Users/pete/Code/agent-skills")
        var actions: [ActivationAction] = []
        var launchedFallbacks: [(path: String, name: String)] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
            fallbackTmuxSessionResolver: { _ in
                nil
            },
            fallbackTmuxSessionExistsResolver: { sessionName in
                sessionName == "agent-skills"
            },
            executeActivationActionOverride: { action, _, _ in
                actions.append(action)
                if case let .ensureTmuxSession(sessionName, projectPath) = action {
                    return sessionName == "agent-skills" && projectPath == project.path
                }
                return false
            },
            launchNewTerminalOverride: { path, name in
                launchedFallbacks.append((path, name))
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(actions.count, 1)
        if let firstAction = actions.first {
            if case let .ensureTmuxSession(sessionName, projectPath) = firstAction {
                XCTAssertEqual(sessionName, "agent-skills")
                XCTAssertEqual(projectPath, project.path)
            } else {
                XCTFail("Expected ensureTmuxSession exact-name recovery action, got \(String(describing: firstAction))")
            }
        }
        XCTAssertTrue(launchedFallbacks.isEmpty, "Exact session-name recovery should prevent new terminal launch.")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.success, true)
    }

    func testLaunchTerminalColdStartNoTrustedEvidenceLogsFallbackMarkerAndLaunchesWithoutStall() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var actions: [ActivationAction] = []
        var results: [TerminalActivationResult] = []
        var elapsed: TimeInterval?
        let collector = LogCollector()
        let startedAt = Date()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

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
            executeActivationActionOverride: { action, _, _ in
                actions.append(action)
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
            elapsed = Date().timeIntervalSince(startedAt)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(actions.count, 1)
        if let firstAction = actions.first {
            if case let .launchNewTerminal(path, name) = firstAction {
                XCTAssertEqual(path, project.path)
                XCTAssertEqual(name, project.name)
            } else {
                XCTFail("Expected launchNewTerminal for cold-start empty evidence, got \(String(describing: firstAction))")
            }
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertLessThan(
            elapsed ?? .infinity,
            0.5,
            "Cold-start empty-evidence fallback should resolve quickly without apparent stall.",
        )

        let foundMarker = await collector.contains {
            $0.contains("[TerminalLauncher] ARE no-trusted-evidence fallback launch path=\(project.path)")
        }
        XCTAssertTrue(foundMarker, "Expected explicit no-trusted-evidence fallback marker for cold-start clarity.")
    }

    func testLaunchTerminalNoTrustedEvidenceReusesRecoverableTmuxSessionBeforeLaunchingNewTerminal() async {
        let project = makeProject(name: "assistant-ui", path: "/Users/pete/Code/assistant-ui")
        var actions: [ActivationAction] = []
        var results: [TerminalActivationResult] = []

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
                "assistant-ui"
            },
            executeActivationActionOverride: { action, _, _ in
                actions.append(action)
                if case let .ensureTmuxSession(sessionName, projectPath) = action {
                    return sessionName == "assistant-ui" && projectPath == project.path
                }
                return false
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(actions.count, 1, "Expected tmux recovery action before launching a new terminal.")
        if let firstAction = actions.first {
            if case let .ensureTmuxSession(sessionName, projectPath) = firstAction {
                XCTAssertEqual(sessionName, "assistant-ui")
                XCTAssertEqual(projectPath, project.path)
            } else {
                XCTFail("Expected ensureTmuxSession recovery action, got \(String(describing: firstAction))")
            }
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.usedFallback, false)
    }

    func testLaunchTerminalSnapshotFailureFallbackIsDebouncedAcrossRapidRepeatedClicks() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var launchedFallbacks: [(path: String, name: String)] = []
        var results: [TerminalActivationResult] = []
        let collector = LogCollector()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
            launchNewTerminalOverride: { path, name in
                launchedFallbacks.append((path, name))
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        let firstFallbackCompleted = await waitUntil(timeout: 1.5) {
            launchedFallbacks.count == 1 && results.count >= 1
        }
        XCTAssertTrue(firstFallbackCompleted, "Expected first snapshot-unavailable fallback launch to complete.")

        launcher.launchTerminal(for: project)
        let secondOutcomeCompleted = await waitUntil(timeout: 1.5) {
            results.count >= 2
        }
        XCTAssertTrue(secondOutcomeCompleted, "Expected debounced repeated click to emit a second activation outcome.")

        XCTAssertEqual(
            launchedFallbacks.count,
            1,
            "Rapid repeated snapshot failures should not spawn repeated fallback launches.",
        )
        XCTAssertGreaterThanOrEqual(results.count, 2)
        guard results.count >= 2 else { return }
        XCTAssertEqual(results[0].projectPath, project.path)
        XCTAssertEqual(results[1].projectPath, project.path)
        XCTAssertTrue(results[0].usedFallback)
        XCTAssertTrue(results[1].usedFallback)

        let foundDebounceMarker = await waitUntil(timeout: 1.0) {
            await collector.contains {
                $0.contains("[TerminalLauncher] snapshot_unavailable_fallback debounced path=\(project.path)")
            }
        }
        XCTAssertTrue(foundDebounceMarker, "Expected debounce marker for repeated snapshot failure fallback.")
    }

    func testLaunchTerminalSnapshotFailureFallbackLaunchFailureReturnsUnsuccessfulResult() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var launchedFallbacks: [(path: String, name: String)] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { _ in
                throw SnapshotFetchError.unavailable
            },
            launchNewTerminalOverride: { path, name in
                launchedFallbacks.append((path, name))
                return false
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(launchedFallbacks.count, 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, project.path)
        XCTAssertEqual(results.first?.usedFallback, true)
        XCTAssertEqual(results.first?.success, false)
    }

    func testLaunchTerminalRepeatedSameCardRapidClicksCoalesceToSingleOutcome() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        var executionCount = 0
        var resultPaths: [String] = []
        let collector = LogCollector()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        var callCount = 0
        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { project in
                callCount += 1
                if callCount < 3 {
                    try await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                } else {
                    try await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
                return Self.makeAttachedTerminalAppDecision(projectPath: project.path, projectName: project.name, appName: "Ghostty")
            },
            executeActivationActionOverride: { _, _, _ in
                executionCount += 1
                return true
            },
        )

        launcher.onActivationResult = { result in
            resultPaths.append(result.projectPath)
        }

        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000)
        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000)
        launcher.launchTerminal(for: project)
        try? await _Concurrency.Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(executionCount, 1, "Repeated in-flight clicks on same card should coalesce to one execution.")
        XCTAssertEqual(resultPaths, [project.path], "Expected one final outcome for repeated same-card overlap.")
        let hasStaleMarker = await collector.contains {
            $0.contains("[TerminalLauncher] ARE snapshot request canceled/stale") &&
                $0.contains(project.path)
        }
        XCTAssertTrue(hasStaleMarker, "Expected stale suppression marker for superseded same-card requests.")
    }

    func testLaunchTerminalLatestClickEmitsSingleFinalOutcomeSequence() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        var executedPaths: [String] = []
        var results: [TerminalActivationResult] = []
        let collector = LogCollector()

        DebugLog.setTestObserver { line in
            _Concurrency.Task {
                await collector.append(line)
            }
        }
        defer { DebugLog.setTestObserver(nil) }

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { project in
                let projectPath = project.path
                if projectPath == projectA.path {
                    try await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                } else {
                    try await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
                return Self.makeAttachedTerminalAppDecision(projectPath: projectPath, projectName: project.name, appName: "Ghostty")
            },
            executeActivationActionOverride: { _, projectPath, _ in
                executedPaths.append(projectPath)
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 40_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(executedPaths, [projectB.path])
        XCTAssertEqual(results.count, 1, "Latest-click overlap should emit exactly one final outcome.")
        XCTAssertEqual(results.first?.projectPath, projectB.path)
        let sawStaleSuppression = await collector.contains {
            $0.contains("[TerminalLauncher] ARE snapshot request canceled/stale") &&
                $0.contains(projectA.path)
        }
        XCTAssertTrue(sawStaleSuppression, "Expected stale suppression marker for superseded request.")
    }

    func testLaunchTerminalStalePrimaryFailureDoesNotLaunchFallbackAfterNewerClick() async {
        let projectA = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let projectB = makeProject(name: "project-b", path: "/Users/pete/Code/project-b")
        var executedActions: [(path: String, action: ActivationAction)] = []
        var results: [TerminalActivationResult] = []

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            resolveActivationDecisionOverride: { project in
                let projectPath = project.path
                if projectPath == projectA.path {
                    return ActivationDecision(
                        primary: .ensureTmuxSession(sessionName: "project-a", projectPath: projectA.path),
                        fallback: .launchNewTerminal(projectPath: projectA.path, projectName: projectA.name),
                        reason: "TMUX_SESSION_DETACHED",
                        trace: nil,
                    )
                }
                return Self.makeAttachedTerminalAppDecision(projectPath: projectPath, projectName: project.name, appName: "Ghostty")
            },
            executeActivationActionOverride: { action, projectPath, _ in
                executedActions.append((projectPath, action))
                if projectPath == projectA.path {
                    if case .ensureTmuxSession = action {
                        try? await _Concurrency.Task.sleep(nanoseconds: 220_000_000)
                        return false
                    }
                    if case .launchNewTerminal = action {
                        return true
                    }
                }
                return true
            },
        )

        launcher.onActivationResult = { result in
            results.append(result)
        }

        launcher.launchTerminal(for: projectA)
        try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000)
        launcher.launchTerminal(for: projectB)
        try? await _Concurrency.Task.sleep(nanoseconds: 500_000_000)

        let staleFallbackLaunches = executedActions.filter { entry in
            guard entry.path == projectA.path else { return false }
            if case .launchNewTerminal = entry.action {
                return true
            }
            return false
        }

        XCTAssertTrue(
            staleFallbackLaunches.isEmpty,
            "Stale request must not launch fallback after a newer click wins.",
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.projectPath, projectB.path)
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

    private func waitUntil(
        timeout: TimeInterval,
        pollNanoseconds: UInt64 = 10_000_000,
        condition: @escaping () async -> Bool,
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await _Concurrency.Task.sleep(nanoseconds: pollNanoseconds)
        }
        return await condition()
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
