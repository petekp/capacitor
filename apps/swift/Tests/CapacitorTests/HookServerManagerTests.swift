@testable import Capacitor
import XCTest

@MainActor
final class HookServerManagerTests: XCTestCase {
    func testLifecycleStateStartsRunningAfterHealthyStartupCheck() {
        var state = HookServerLifecycleState()
        state.status = .starting

        let directive = state.apply(.healthCheckFinished(healthy: true, maxConsecutiveFailures: 3))

        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.consecutiveHealthFailures, 0)
        XCTAssertEqual(directive, .serverReady)
    }

    func testLifecycleStateRequestsRestartAfterThresholdFailures() {
        var state = HookServerLifecycleState()
        state.status = .running

        XCTAssertEqual(
            state.apply(.healthCheckFinished(healthy: false, maxConsecutiveFailures: 3)),
            .none,
        )
        XCTAssertEqual(state.consecutiveHealthFailures, 1)

        XCTAssertEqual(
            state.apply(.healthCheckFinished(healthy: false, maxConsecutiveFailures: 3)),
            .none,
        )
        XCTAssertEqual(state.consecutiveHealthFailures, 2)

        XCTAssertEqual(
            state.apply(.healthCheckFinished(healthy: false, maxConsecutiveFailures: 3)),
            .restart,
        )
        XCTAssertEqual(state.consecutiveHealthFailures, 0)
        XCTAssertEqual(state.status, .starting)
    }

    func testLifecycleStateStopDominatesLateFailures() {
        var state = HookServerLifecycleState()
        state.status = .running

        XCTAssertEqual(state.apply(.stopRequested), .none)
        XCTAssertEqual(state.status, .stopped)

        XCTAssertEqual(
            state.apply(.healthCheckFinished(healthy: false, maxConsecutiveFailures: 3)),
            .none,
        )
        XCTAssertEqual(state.status, .stopped)
    }

    func testStopPreventsLateFailedHealthCheckFromRestarting() async {
        let process = FakeHookServerProcess(pid: 41)
        var launchCount = 0
        var continuation: CheckedContinuation<Bool, Never>?
        let unexpectedRestart = expectation(description: "late health failure must not relaunch")
        unexpectedRestart.isInverted = true

        let manager = HookServerManager(
            port: 8123,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                launchProcess: { _, _, _ in
                    launchCount += 1
                    if launchCount > 1 {
                        unexpectedRestart.fulfill()
                    }
                    return process
                },
                fetchHealth: { _, _ in
                    await withCheckedContinuation { checkedContinuation in
                        continuation = checkedContinuation
                    }
                },
            ),
        )

        manager.startIfNeeded()
        manager.checkHealth()

        for _ in 0 ..< 20 where continuation == nil {
            await _Concurrency.Task.yield()
        }

        XCTAssertNotNil(continuation)

        manager.stop()
        XCTAssertEqual(manager.status, .stopped)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(process.terminateCallCount, 1)

        continuation?.resume(returning: false)
        await _Concurrency.Task.yield()
        await fulfillment(of: [unexpectedRestart], timeout: 0.1)

        XCTAssertEqual(manager.status, .stopped)
        XCTAssertEqual(launchCount, 1, "explicit stop must dominate late health failures")
    }

    func testStartIfNeededRemovesForeignLivePidAndLaunchesFreshProcess() {
        let process = FakeHookServerProcess(pid: 51)
        var removedPidFilePaths: [String] = []
        var launchCount = 0

        let manager = HookServerManager(
            port: 8124,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                readPidFile: { _ in 999 },
                removePidFile: { removedPidFilePaths.append($0) },
                isProcessAlive: { _ in true },
                isManagedServerProcess: { _, _ in false },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    return process
                },
            ),
        )

        manager.startIfNeeded()

        XCTAssertEqual(removedPidFilePaths.count, 1)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(manager.status, .starting)
    }

    func testStopTerminatesVerifiedAdoptedPid() {
        var terminatedPids: [Int32] = []
        var launchCount = 0

        let manager = HookServerManager(
            port: 8125,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                readPidFile: { _ in 321 },
                isProcessAlive: { _ in true },
                isManagedServerProcess: { _, _ in true },
                terminatePid: { terminatedPids.append($0) },
                loadRuntimeServiceConnection: { _ in
                    RuntimeServiceConnection(
                        baseURL: URL(string: "http://127.0.0.1:8125")!,
                        bearerToken: "persisted-token",
                    )
                },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    return FakeHookServerProcess(pid: 77)
                },
            ),
        )

        manager.startIfNeeded()
        XCTAssertEqual(manager.status, .starting)
        XCTAssertEqual(launchCount, 0)

        manager.stop()

        XCTAssertEqual(manager.status, .stopped)
        XCTAssertEqual(terminatedPids, [321])
        XCTAssertEqual(launchCount, 0)
    }

    func testStartIfNeededLaunchesServiceBootstrap() {
        var launchCount = 0
        var capturedEnvironment: [String: String] = [:]

        let manager = HookServerManager(
            port: 8126,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                launchProcess: { _, _, environment in
                    launchCount += 1
                    capturedEnvironment = environment
                    return FakeHookServerProcess(pid: 88)
                },
            ),
        )

        manager.startIfNeeded()

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(manager.status, .starting)
        XCTAssertEqual(capturedEnvironment["CAPACITOR_RUNTIME_SERVICE_BOOTSTRAP"], "1")
        XCTAssertEqual(capturedEnvironment["CAPACITOR_RUNTIME_SERVICE_PORT"], "8126")
        XCTAssertNotNil(capturedEnvironment["CAPACITOR_RUNTIME_SERVICE_TOKEN"])
        XCTAssertNil(capturedEnvironment["CAPACITOR_RUNTIME_HOST_MODE"])
    }

    func testServiceHealthCheckUsesBootstrapAuthToken() async {
        let process = FakeHookServerProcess(pid: 91)
        var receivedAuthToken: String?

        let manager = HookServerManager(
            port: 8127,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                launchProcess: { _, _, _ in process },
                fetchHealth: { _, authToken in
                    receivedAuthToken = authToken
                    return true
                },
            ),
        )

        manager.startIfNeeded()
        manager.checkHealth()

        for _ in 0 ..< 20 where receivedAuthToken == nil {
            await _Concurrency.Task.yield()
        }

        for _ in 0 ..< 20 where manager.status != .running {
            await _Concurrency.Task.yield()
        }

        XCTAssertNotNil(receivedAuthToken)
        XCTAssertEqual(manager.status, .running)
    }

    func testServiceModeAdoptsExistingRuntimeServiceAndUsesPersistedAuthToken() async {
        var launchCount = 0
        var receivedAuthToken: String?

        let manager = HookServerManager(
            port: 8128,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                readPidFile: { _ in 654 },
                isProcessAlive: { _ in true },
                isManagedServerProcess: { _, _ in true },
                loadRuntimeServiceConnection: { _ in
                    RuntimeServiceConnection(
                        baseURL: URL(string: "http://127.0.0.1:8128")!,
                        bearerToken: "persisted-token",
                    )
                },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    return FakeHookServerProcess(pid: 92)
                },
                fetchHealth: { _, authToken in
                    receivedAuthToken = authToken
                    return true
                },
            ),
        )

        manager.startIfNeeded()
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(manager.status, .starting)

        manager.checkHealth()
        for _ in 0 ..< 20 where receivedAuthToken == nil || manager.status != .running {
            await _Concurrency.Task.yield()
        }

        XCTAssertEqual(receivedAuthToken, "persisted-token")
        XCTAssertEqual(manager.status, .running)
    }

    private func makeDependencies(
        readPidFile: @escaping (String) -> Int32? = { _ in nil },
        removePidFile: @escaping (String) -> Void = { _ in },
        isProcessAlive: @escaping (Int32) -> Bool = { _ in true },
        isManagedServerProcess: @escaping (Int32, String) -> Bool = { _, _ in true },
        terminatePid: @escaping (Int32) -> Void = { _ in },
        loadRuntimeServiceConnection: @escaping (UInt16) -> RuntimeServiceConnection? = { _ in nil },
        launchProcess: @escaping (String, UInt16, [String: String]) throws -> any HookServerProcessControlling = { _, _, _ in
            FakeHookServerProcess(pid: 11)
        },
        fetchHealth: @escaping (UInt16, String?) async -> Bool = { _, _ in true },
    ) -> HookServerManagerDependencies {
        HookServerManagerDependencies(
            isExecutableFile: { _ in true },
            readPidFile: readPidFile,
            removePidFile: removePidFile,
            isProcessAlive: isProcessAlive,
            isManagedServerProcess: isManagedServerProcess,
            terminatePid: terminatePid,
            loadRuntimeServiceConnection: loadRuntimeServiceConnection,
            launchProcess: launchProcess,
            fetchHealth: fetchHealth,
        )
    }
}

private final class FakeHookServerProcess: HookServerProcessControlling {
    var isRunning = true
    let processIdentifier: Int32
    var terminationStatus: Int32 = 0
    private(set) var terminateCallCount = 0

    init(pid: Int32) {
        processIdentifier = pid
    }

    func terminate() {
        terminateCallCount += 1
        isRunning = false
    }
}
