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
        private(set) var outputScripts: [String] = []
        var outputResults: [AppleScriptExecutionResult] = []

        init(shouldSucceed: Bool) {
            self.shouldSucceed = shouldSucceed
        }

        func runOutput(_ script: String) -> AppleScriptExecutionResult {
            outputScripts.append(script)
            if outputResults.isEmpty {
                return AppleScriptExecutionResult(success: shouldSucceed, output: nil, error: nil)
            }
            return outputResults.removeFirst()
        }
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
        let readyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-launcher-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyURL) }

        let task = _Concurrency.Task {
            _ = await TerminalLauncher.runBashScriptWithResult("touch '\(readyURL.path)'; exec tail -f /dev/null")
            exp.fulfill()
        }

        _ = await assertEventually(
            timeout: 1.0,
            context: "cancellation test process started",
        ) {
            FileManager.default.fileExists(atPath: readyURL.path)
        }
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
                sessionResolutionPolicy: SessionResolutionPolicy(discoverFallbackSession: { path in
                    URL(fileURLWithPath: path).lastPathComponent
                }),
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
                sessionResolutionPolicy: SessionResolutionPolicy(discoverFallbackSession: { path in
                    URL(fileURLWithPath: path).lastPathComponent
                }),
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
                sessionResolutionPolicy: SessionResolutionPolicy(discoverFallbackSession: { path in
                    URL(fileURLWithPath: path).lastPathComponent
                }),
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
            sessionResolutionPolicy: SessionResolutionPolicy(discoverFallbackSession: { path in
                URL(fileURLWithPath: path).lastPathComponent
            }),
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
            sessionResolutionPolicy: SessionResolutionPolicy(discoverFallbackSession: { path in
                URL(fileURLWithPath: path).lastPathComponent
            }),
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

    func testLaunchTerminalPrefersActivationIntentSessionOverFallbackResolver() async {
        let project = makeProject(name: "project-a", path: "/Users/pete/Code/project-a")
        let exp = expectation(description: "launch result")
        var resolvedSession: String?

        let launcher = TerminalLauncher(
            appleScript: StubAppleScriptClient(shouldSucceed: true),
            sessionResolutionPolicy: SessionResolutionPolicy(discoverFallbackSession: { _ in "fallback-session" }),
            activateProjectSessionOverride: { sessionName, _ in
                resolvedSession = sessionName
                return true
            },
        )
        launcher.activationIntentResolver = { _, _, _ in
            ActivationPolicyIntent(
                terminalApp: ActivationPolicyTerminalAppDecision(app: .ghostty, source: .runtimeRoute),
                sessionName: "routed-session",
                hostTty: "/dev/ttys001",
                paneId: "%12",
            )
        }
        launcher.onActivationResult = { _ in
            exp.fulfill()
        }

        launcher.launchTerminal(for: project)
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(resolvedSession, "routed-session")
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
        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "my-project",
            projectPath: "/path/to/project",
            resolveAnyClientTty: { nil },
            ensureAndSwitch: { _, _, _, _ in XCTFail("should not be called"); return false },
            launchTerminalWithTmux: { session, path in
                XCTAssertEqual(session, "my-project")
                XCTAssertEqual(path, "/path/to/project")
                launched = true
                return true
            },
            activateTerminal: { _, _, _ in XCTFail("should not be called"); return .failed(nil) },
            pollForNewClient: { "/dev/ttys050" },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(launched)
    }

    func testUnifiedActivationReturnsFalseWhenLaunchFailsWithoutClient() async {
        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "my-project",
            projectPath: "/path/to/project",
            resolveAnyClientTty: { nil },
            ensureAndSwitch: { _, _, _, _ in XCTFail("should not be called"); return false },
            launchTerminalWithTmux: { _, _ in false },
            activateTerminal: { _, _, _ in XCTFail("should not be called"); return .failed(nil) },
        )

        XCTAssertFalse(ok)
    }

    /// Client exists → switch + focus
    func testUnifiedActivationSwitchesWhenClientExists() async {
        var switchedSession: String?
        var switchedPane: String?
        var terminalActivated = false
        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "other-project",
            projectPath: "/other",
            resolveAnyClientTty: { "/dev/ttys001" },
            ensureAndSwitch: { session, _, tty, targetPane in
                switchedSession = session
                switchedPane = targetPane
                XCTAssertEqual(tty, "/dev/ttys001")
                return true
            },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch"); return false },
            activateTerminal: { _, _, _ in terminalActivated = true; return .focused },
            resolveTargetPane: { _ in "%2" },
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(switchedSession, "other-project")
        XCTAssertEqual(switchedPane, "%2")
        XCTAssertTrue(terminalActivated)
    }

    /// Session doesn't exist → ensureAndSwitch creates + switches
    func testUnifiedActivationCreatesSessionWhenMissing() async {
        var ensureCalled = false
        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "new-proj",
            projectPath: "/new",
            resolveAnyClientTty: { "/dev/ttys001" },
            ensureAndSwitch: { session, path, _, _ in
                ensureCalled = true
                XCTAssertEqual(session, "new-proj")
                XCTAssertEqual(path, "/new")
                return true
            },
            launchTerminalWithTmux: { _, _ in XCTFail("should not launch"); return false },
            activateTerminal: { _, _, _ in .focused },
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(ensureCalled)
    }

    /// Switch fails → returns false
    func testUnifiedActivationReturnsFalseWhenSwitchFails() async {
        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "broken",
            projectPath: "/broken",
            resolveAnyClientTty: { "/dev/ttys001" },
            ensureAndSwitch: { _, _, _, _ in false },
            launchTerminalWithTmux: { _, _ in true },
            activateTerminal: { _, _, _ in .focused },
        )
        XCTAssertFalse(ok)
    }

    /// When a tmux client exists but the terminal that owns the TTY is gone
    /// (activateTerminal returns false), the flow should launch a fresh terminal.
    func testUnifiedActivationLaunchesWhenTerminalGone() async {
        var launched = false
        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "my-project",
            projectPath: "/path/to/project",
            resolveAnyClientTty: { "/dev/ttys001" },
            ensureAndSwitch: { _, _, _, _ in true },
            launchTerminalWithTmux: { _, _ in launched = true; return true },
            activateTerminal: { _, _, _ in .relaunchNeeded }, // Terminal focus FAILS (tab gone)
        )
        XCTAssertTrue(ok, "Should succeed via fresh launch")
        XCTAssertTrue(launched, "Should launch new terminal when focus fails")
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

    func testResolveClientTtyPrefersExplicitHostTtyWhenAttached() async {
        let tty = await TerminalLauncher.resolveAnyTmuxClientTty(
            preferredHostTty: "/dev/ttys002",
            targetSession: "capacitor",
            runScript: { cmd in
                if cmd.contains("display-message") {
                    return (1, nil)
                }
                return (0, "/dev/ttys001 other-project\n/dev/ttys002 capacitor\n")
            },
        )

        XCTAssertEqual(tty, "/dev/ttys002")
    }

    func testEnsureAndSwitchSelectsPaneAfterSwitchingSession() async {
        var commands: [String] = []
        let ok = await TerminalLauncher.ensureSessionAndSwitch(
            sessionName: "shared",
            projectPath: "/Users/pete/Code/sanctuary",
            clientTty: "/dev/ttys001",
            targetPane: "%2",
            runScript: { cmd in
                commands.append(cmd)
                return (0, nil)
            },
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(commands.count, 3, "switch-client -> select-window -> select-pane")
        XCTAssertTrue(commands[0].contains("switch-client"))
        XCTAssertTrue(commands[1].contains("select-window"))
        XCTAssertTrue(commands[1].contains("%2"))
        XCTAssertTrue(commands[2].contains("select-pane"))
        XCTAssertTrue(commands[2].contains("%2"))
    }

    func testEnsureAndSwitchFallsBackToSessionWhenPaneSelectionFails() async {
        var commands: [String] = []
        let ok = await TerminalLauncher.ensureSessionAndSwitch(
            sessionName: "shared",
            projectPath: "/Users/pete/Code/sanctuary",
            clientTty: "/dev/ttys001",
            targetPane: "%does-not-exist",
            runScript: { cmd in
                commands.append(cmd)
                if cmd.contains("select-pane") {
                    return (1, "pane not found")
                }
                return (0, nil)
            },
        )

        XCTAssertTrue(ok, "Session activation should still succeed when pane selection is stale")
        XCTAssertEqual(commands.count, 3, "switch-client -> select-window -> select-pane")
        XCTAssertTrue(commands[0].contains("switch-client"))
        XCTAssertTrue(commands[1].contains("select-window"))
        XCTAssertTrue(commands[2].contains("select-pane"))
    }

    func testLaunchWithCommandSupportsITerm() {
        let script = TerminalScripts.launchWithCommand(
            projectPath: "/Users/pete/Code/capacitor",
            command: "claude --resume",
            preferredApp: .iTerm,
        )

        XCTAssertTrue(script.contains("open -b com.googlecode.iterm2"))
        XCTAssertTrue(script.contains("tell application \"iTerm\""))
        XCTAssertTrue(script.contains("write text \"claude --resume\""))
        XCTAssertFalse(script.contains("tell process \"iTerm2\""))
        XCTAssertTrue(script.contains("claude --resume"))
    }

    func testLaunchWithCommandSupportsTerminalApp() {
        let script = TerminalScripts.launchWithCommand(
            projectPath: "/Users/pete/Code/capacitor",
            command: "claude --resume",
            preferredApp: .terminal,
        )

        XCTAssertTrue(script.contains("open -b com.apple.Terminal"))
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
        XCTAssertTrue(script.contains("do script \"claude --resume\" in front window"))
        XCTAssertFalse(script.contains("tell process \"Terminal\""))
        XCTAssertTrue(script.contains("claude --resume"))
    }

    func testMakeAttachCommandReusesExistingSessionWhenLaunchingWithoutClient() {
        let command = TmuxRouter.makeAttachCommand(
            session: "capacitor",
            projectPath: "/Users/pete/Code/capacitor",
        )

        XCTAssertEqual(
            command,
            "tmux new-session -A -s 'capacitor' -c '/Users/pete/Code/capacitor'",
        )
    }

    func testKillSessionTargetsNamedTmuxSession() async {
        var commands: [String] = []

        let killed = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                return (0, nil)
            },
        ).killSession(sessionName: "delegation-54da230f")

        XCTAssertTrue(killed)
        XCTAssertEqual(commands, ["tmux kill-session -t 'delegation-54da230f' 2>&1"])
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
}
