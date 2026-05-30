@testable import Capacitor
import XCTest

@MainActor
final class TerminalActivationCoordinatorTests: XCTestCase {
    private final class ActivationLogCollector {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
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

    func testRapidDoubleLaunchOnlyCompletesLatest() async {
        let project1 = makeProject(name: "project-1", path: "/tmp/project-1")
        let project2 = makeProject(name: "project-2", path: "/tmp/project-2")
        let firstActivationStarted = expectation(description: "first activation started")
        let latestCallback = expectation(description: "latest activation callback")
        let staleCallback = expectation(description: "stale activation callback")
        staleCallback.isInverted = true

        let gate = AsyncGate()
        var activatedPaths: [String] = []
        var results: [TerminalActivationResult] = []

        let coordinator = TerminalActivationCoordinator(
            resolveSessionName: { project in
                "\(project.name)-session"
            },
            runResolvedActivation: { _, projectPath in
                activatedPaths.append(projectPath)
                if projectPath == project1.path {
                    firstActivationStarted.fulfill()
                    await gate.wait()
                }
                return true
            },
            currentFailureReason: { nil },
        )

        coordinator.onActivationResult = { result in
            results.append(result)
            if result.projectPath == project2.path {
                latestCallback.fulfill()
            } else if result.projectPath == project1.path {
                staleCallback.fulfill()
            }
        }

        coordinator.launchTerminal(for: project1)
        await fulfillment(of: [firstActivationStarted], timeout: 1.0)

        coordinator.launchTerminal(for: project2)
        await _Concurrency.Task.yield()
        await gate.open()

        await fulfillment(of: [latestCallback, staleCallback], timeout: 1.0)

        XCTAssertEqual(activatedPaths, [project1.path, project2.path])
        XCTAssertEqual(results.map(\.projectPath), [project2.path])
        XCTAssertEqual(results.map(\.success), [true])
    }

    func testOnActivationResultFiredOnSuccess() async {
        let project = makeProject(name: "success-project", path: "/tmp/success-project")
        let callbackReceived = expectation(description: "activation result callback")
        var callbackResult: TerminalActivationResult?

        let coordinator = TerminalActivationCoordinator(
            resolveSessionName: { _ in "success-session" },
            runResolvedActivation: { sessionName, projectPath in
                XCTAssertEqual(sessionName, "success-session")
                XCTAssertEqual(projectPath, project.path)
                return true
            },
            currentFailureReason: { nil },
        )

        coordinator.onActivationResult = { result in
            callbackResult = result
            callbackReceived.fulfill()
        }

        coordinator.launchTerminal(for: project)
        await fulfillment(of: [callbackReceived], timeout: 1.0)

        XCTAssertEqual(
            callbackResult,
            TerminalActivationResult(
                projectName: project.name,
                projectPath: project.path,
                success: true,
                usedFallback: false,
                failureReason: nil,
            ),
        )
    }

    func testOnActivationResultFiredOnFailure() async {
        let project = makeProject(name: "failure-project", path: "/tmp/failure-project")
        let callbackReceived = expectation(description: "activation failure callback")
        let failureReason = TerminalActivationFailureReason.ghosttyAutomationUnavailable("automation disabled")
        var callbackResult: TerminalActivationResult?

        let coordinator = TerminalActivationCoordinator(
            resolveSessionName: { _ in "failure-session" },
            runResolvedActivation: { sessionName, projectPath in
                XCTAssertEqual(sessionName, "failure-session")
                XCTAssertEqual(projectPath, project.path)
                return false
            },
            currentFailureReason: { failureReason },
        )

        coordinator.onActivationResult = { result in
            callbackResult = result
            callbackReceived.fulfill()
        }

        coordinator.launchTerminal(for: project)
        await fulfillment(of: [callbackReceived], timeout: 1.0)

        XCTAssertEqual(
            callbackResult,
            TerminalActivationResult(
                projectName: project.name,
                projectPath: project.path,
                success: false,
                usedFallback: false,
                failureReason: failureReason,
            ),
        )
    }

    func testActivationFlowRelaunchWhenTerminalGone() async {
        var steps: [String] = []
        var launchedSession: String?
        var launchedPath: String?

        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "coordinator-session",
            projectPath: "/tmp/coordinator-project",
            resolveAnyClientTty: {
                steps.append("resolveAnyClientTty")
                return "/dev/ttys001"
            },
            ensureAndSwitch: { sessionName, projectPath, clientTty, targetPane in
                steps.append("ensureAndSwitch")
                XCTAssertEqual(sessionName, "coordinator-session")
                XCTAssertEqual(projectPath, "/tmp/coordinator-project")
                XCTAssertEqual(clientTty, "/dev/ttys001")
                XCTAssertNil(targetPane)
                return true
            },
            launchTerminalWithTmux: { sessionName, projectPath in
                steps.append("launchTerminalWithTmux")
                launchedSession = sessionName
                launchedPath = projectPath
                return true
            },
            activateTerminal: { clientTty, projectPath, sessionName in
                XCTAssertEqual(projectPath, "/tmp/coordinator-project")
                if clientTty == nil {
                    steps.append("directFocus")
                    XCTAssertNil(sessionName)
                    return .relaunchNeeded
                }

                steps.append("postSwitchFocus")
                XCTAssertEqual(clientTty, "/dev/ttys001")
                XCTAssertEqual(sessionName, "coordinator-session")
                return .relaunchNeeded
            },
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(
            steps,
            ["directFocus", "resolveAnyClientTty", "ensureAndSwitch", "postSwitchFocus", "launchTerminalWithTmux"],
        )
        XCTAssertEqual(launchedSession, "coordinator-session")
        XCTAssertEqual(launchedPath, "/tmp/coordinator-project")
    }

    func testActivationFlowReturnsFalseOnTerminalFocusFailed() async {
        let failureReason = TerminalActivationFailureReason.ghosttyUnsupportedVersion("1.2")
        var launched = false

        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "focus-failure-session",
            projectPath: "/tmp/focus-failure-project",
            resolveAnyClientTty: { "/dev/ttys009" },
            ensureAndSwitch: { sessionName, projectPath, clientTty, targetPane in
                XCTAssertEqual(sessionName, "focus-failure-session")
                XCTAssertEqual(projectPath, "/tmp/focus-failure-project")
                XCTAssertEqual(clientTty, "/dev/ttys009")
                XCTAssertNil(targetPane)
                return true
            },
            launchTerminalWithTmux: { _, _ in
                launched = true
                return true
            },
            activateTerminal: { clientTty, projectPath, sessionName in
                XCTAssertEqual(projectPath, "/tmp/focus-failure-project")
                if clientTty == nil {
                    XCTAssertNil(sessionName)
                    return .relaunchNeeded
                }

                XCTAssertEqual(clientTty, "/dev/ttys009")
                XCTAssertEqual(sessionName, "focus-failure-session")
                return .failed(failureReason)
            },
        )

        XCTAssertFalse(ok)
        XCTAssertFalse(launched)
    }

    func testActivationFlowTreatsAlreadySelectedDirectMatchAsSuccessWhenNoTmuxClientMatches() async {
        var launched = false
        var switched = false

        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "parable-school",
            projectPath: "/Users/pete/Code/parable-school",
            resolveAnyClientTty: { nil },
            ensureAndSwitch: { _, _, _, _ in
                switched = true
                return false
            },
            launchTerminalWithTmux: { _, _ in
                launched = true
                return false
            },
            activateTerminal: { clientTty, _, _ in
                clientTty == nil ? .alreadySelected : .focused
            },
        )

        XCTAssertTrue(ok)
        XCTAssertFalse(switched)
        XCTAssertFalse(launched)
    }

    func testActivationFlowAcceptsAlreadySelectedDirectMatchBeforeFallbackTmuxResolution() async {
        var launched = false
        var switched = false
        var resolvedClient = false

        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "parable-school",
            projectPath: "/Users/pete/Code/parable-school",
            resolveAnyClientTty: {
                resolvedClient = true
                return "/dev/ttys003"
            },
            ensureAndSwitch: { _, _, _, _ in
                switched = true
                return false
            },
            launchTerminalWithTmux: { _, _ in
                launched = true
                return false
            },
            activateTerminal: { clientTty, _, sessionName in
                XCTAssertNil(clientTty)
                XCTAssertNil(sessionName)
                return .alreadySelected
            },
            switchAlreadySelectedDirectMatchWhenClientExists: false,
        )

        XCTAssertTrue(ok)
        XCTAssertFalse(resolvedClient)
        XCTAssertFalse(switched)
        XCTAssertFalse(launched)
    }

    func testActivationFlowLogsDirectFocusTmuxClientAndLaunchDecision() async {
        let collector = ActivationLogCollector()
        DebugLog.setTestObserver { line in
            collector.append(line)
        }
        defer { DebugLog.setTestObserver(nil) }

        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "launch-last-session",
            projectPath: "/tmp/launch-last-project",
            resolveAnyClientTty: { nil },
            ensureAndSwitch: { _, _, _, _ in
                XCTFail("tmux switch should not run without a client")
                return false
            },
            launchTerminalWithTmux: { sessionName, projectPath in
                XCTAssertEqual(sessionName, "launch-last-session")
                XCTAssertEqual(projectPath, "/tmp/launch-last-project")
                return true
            },
            activateTerminal: { clientTty, projectPath, sessionName in
                XCTAssertNil(clientTty)
                XCTAssertEqual(projectPath, "/tmp/launch-last-project")
                XCTAssertNil(sessionName)
                return .relaunchNeeded
            },
        )

        XCTAssertTrue(ok)
        let lines = collector.snapshot()
        XCTAssertTrue(lines.contains { $0.contains("[TerminalActivation]") && $0.contains("route=\"direct_focus\"") && $0.contains("outcome=\"relaunch_needed\"") })
        XCTAssertTrue(lines.contains { $0.contains("[TerminalActivation]") && $0.contains("route=\"tmux_client\"") && $0.contains("outcome=\"none\"") })
        XCTAssertTrue(lines.contains { $0.contains("[TerminalActivation]") && $0.contains("route=\"launch\"") && $0.contains("action=\"launch_tmux_attach\"") && $0.contains("outcome=\"launched\"") })
    }

    func testActivationFlowStillSwitchesWhenAlreadySelectedDirectMatchHasTmuxClient() async {
        var switchedSession: String?
        var launched = false

        let ok = await TerminalActivationCoordinator.runActivationFlow(
            sessionName: "parable-school",
            projectPath: "/Users/pete/Code/parable-school",
            resolveAnyClientTty: { "/dev/ttys003" },
            ensureAndSwitch: { sessionName, _, clientTty, _ in
                switchedSession = sessionName
                XCTAssertEqual(clientTty, "/dev/ttys003")
                return true
            },
            launchTerminalWithTmux: { _, _ in
                launched = true
                return false
            },
            activateTerminal: { clientTty, _, sessionName in
                if clientTty == nil {
                    XCTAssertNil(sessionName)
                    return .alreadySelected
                }
                XCTAssertEqual(sessionName, "parable-school")
                return .focused
            },
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(switchedSession, "parable-school")
        XCTAssertFalse(launched)
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            workspaceId: WorkspaceIdentity.fromPath(path),
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
}
