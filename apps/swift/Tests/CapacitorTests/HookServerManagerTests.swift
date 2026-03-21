@testable import Capacitor
import Foundation
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
        let fetchHealthRelease = DispatchSemaphore(value: 0)
        let unexpectedRestart = expectation(description: "late health failure must not relaunch")
        unexpectedRestart.isInverted = true
        var fetchHealthStarted = false

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
                    fetchHealthStarted = true
                    fetchHealthRelease.wait()
                    return nil
                },
            ),
        )

        manager.startIfNeeded()
        for _ in 0 ..< 50 where !fetchHealthStarted {
            await _Concurrency.Task.yield()
        }

        manager.stop()
        XCTAssertEqual(manager.status, HookServerManager.Status.stopped)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(process.terminateCallCount, 1)

        fetchHealthRelease.signal()
        await _Concurrency.Task.yield()
        await fulfillment(of: [unexpectedRestart], timeout: 0.1)

        XCTAssertEqual(manager.status, HookServerManager.Status.stopped)
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
        XCTAssertEqual(manager.status, HookServerManager.Status.starting)
    }

    func testStartIfNeededRemovesStaleDeadPidAndLaunchesFreshProcess() {
        let process = FakeHookServerProcess(pid: 52)
        var removedPidFilePaths: [String] = []
        var launchCount = 0

        let manager = HookServerManager(
            port: 8132,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                readPidFile: { _ in 1001 },
                removePidFile: { removedPidFilePaths.append($0) },
                isProcessAlive: { _ in false },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    return process
                },
            ),
        )

        manager.startIfNeeded()

        XCTAssertEqual(removedPidFilePaths.count, 1)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(manager.status, HookServerManager.Status.starting)
    }

    func testStopTerminatesVerifiedAdoptedPid() {
        var terminatedPids: [Int32] = []
        var waitedForPids: [(Int32, TimeInterval)] = []
        var launchCount = 0

        let manager = HookServerManager(
            port: 8125,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                readPidFile: { _ in 321 },
                isProcessAlive: { _ in true },
                isManagedServerProcess: { _, _ in true },
                terminatePid: { terminatedPids.append($0) },
                waitForProcessExit: { pid, timeout in
                    waitedForPids.append((pid, timeout))
                    return true
                },
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
        XCTAssertEqual(manager.status, HookServerManager.Status.starting)
        XCTAssertEqual(launchCount, 0)

        manager.stop()

        guard let waited = waitedForPids.first else {
            return XCTFail("expected graceful stop wait")
        }
        XCTAssertEqual(manager.status, HookServerManager.Status.stopped)
        XCTAssertEqual(terminatedPids, [321])
        XCTAssertEqual(waitedForPids.count, 1)
        XCTAssertEqual(waited.0, 321)
        XCTAssertEqual(waited.1, 2.0, accuracy: 0.001)
        XCTAssertEqual(launchCount, 0)
    }

    func testStopForceKillsOwnedProcessWhenGracefulExitTimesOut() {
        let process = FakeHookServerProcess(pid: 98, stopsOnTerminate: false)
        var killedPids: [Int32] = []
        var waitedForPids: [(Int32, TimeInterval)] = []

        let manager = HookServerManager(
            port: 8129,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                killPid: { killedPids.append($0) },
                waitForProcessExit: { pid, timeout in
                    waitedForPids.append((pid, timeout))
                    return false
                },
                launchProcess: { _, _, _ in process },
            ),
        )

        manager.startIfNeeded()
        manager.stop()

        guard let waited = waitedForPids.first else {
            return XCTFail("expected graceful stop wait")
        }
        XCTAssertEqual(manager.status, HookServerManager.Status.stopped)
        XCTAssertEqual(process.terminateCallCount, 1)
        XCTAssertEqual(waitedForPids.count, 1)
        XCTAssertEqual(waited.0, 98)
        XCTAssertEqual(waited.1, 2.0, accuracy: 0.001)
        XCTAssertEqual(killedPids, [98])
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
        XCTAssertEqual(manager.status, HookServerManager.Status.starting)
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
                    return Self.makeCompatibleHealth(pid: 91)
                },
            ),
        )

        manager.startIfNeeded()
        manager.checkHealth()

        for _ in 0 ..< 20 where receivedAuthToken == nil {
            await _Concurrency.Task.yield()
        }

        for _ in 0 ..< 20 where manager.status != HookServerManager.Status.running {
            await _Concurrency.Task.yield()
        }

        XCTAssertNotNil(receivedAuthToken)
        XCTAssertEqual(manager.status, HookServerManager.Status.running)
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
                    return Self.makeCompatibleHealth(pid: 654)
                },
            ),
        )

        manager.startIfNeeded()
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(manager.status, HookServerManager.Status.starting)

        manager.checkHealth()
        for _ in 0 ..< 20 where receivedAuthToken == nil || manager.status != HookServerManager.Status.running {
            await _Concurrency.Task.yield()
        }

        XCTAssertEqual(receivedAuthToken, "persisted-token")
        XCTAssertEqual(manager.status, HookServerManager.Status.running)
    }

    func testStartIfNeededAdoptsCompatibleRuntimeWhenPidFileMissing() async {
        var launchCount = 0
        var healthCheckCount = 0

        let manager = HookServerManager(
            port: 8133,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                loadRuntimeServiceConnection: { _ in
                    RuntimeServiceConnection(
                        baseURL: URL(string: "http://127.0.0.1:8133")!,
                        bearerToken: "persisted-token",
                    )
                },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    return FakeHookServerProcess(pid: 96)
                },
                fetchHealth: { _, authToken in
                    healthCheckCount += 1
                    XCTAssertEqual(authToken, "persisted-token")
                    return Self.makeCompatibleHealth(pid: 654)
                },
            ),
            launchReadinessInterval: .zero,
        )

        manager.startIfNeeded()
        manager.checkHealth()
        await waitUntil { manager.status == HookServerManager.Status.running }

        XCTAssertGreaterThanOrEqual(healthCheckCount, 1)
        XCTAssertEqual(launchCount, 0)
    }

    func testStartIfNeededFailsIfLaunchedProcessExitsBeforeReadinessSucceeds() async {
        let process = FakeHookServerProcess(pid: 93)
        var launchCount = 0
        let fetchHealthRelease = DispatchSemaphore(value: 0)
        var fetchHealthStarted = false

        let manager = HookServerManager(
            port: 8130,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                launchProcessWithTermination: { _, _, _, terminationHandler in
                    launchCount += 1
                    process.attachTerminationHandler(terminationHandler)
                    return process
                },
                fetchHealth: { _, _ in
                    fetchHealthStarted = true
                    fetchHealthRelease.wait()
                    return nil
                },
            ),
            launchReadinessAttempts: 3,
            launchReadinessInterval: .zero,
        )

        manager.startIfNeeded()
        for _ in 0 ..< 50 where !fetchHealthStarted {
            await _Concurrency.Task.yield()
        }
        process.simulateExit(status: 48)
        fetchHealthRelease.signal()
        await waitUntil {
            if case .failed = manager.status {
                return true
            }
            return false
        }

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(process.terminateCallCount, 0)
        if case let .failed(message) = manager.status {
            XCTAssertTrue(message.contains("exited during startup"), "message mismatch: \(message)")
        } else {
            XCTFail("expected startup failure, got \(manager.status)")
        }
    }

    func testStartIfNeededFailsReadinessAfterRetryBudgetAndTerminatesProcess() async {
        let process = FakeHookServerProcess(pid: 94)
        var launchCount = 0

        let manager = HookServerManager(
            port: 8131,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                launchProcessWithTermination: { _, _, _, terminationHandler in
                    launchCount += 1
                    process.attachTerminationHandler(terminationHandler)
                    return process
                },
                fetchHealth: { _, _ in nil },
            ),
            launchReadinessAttempts: 2,
            launchReadinessInterval: .zero,
        )

        manager.startIfNeeded()
        await waitUntil {
            if case .failed = manager.status {
                return true
            }
            return false
        }

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(process.terminateCallCount, 1)
        if case let .failed(message) = manager.status {
            XCTAssertTrue(message.contains("readiness"), "message mismatch: \(message)")
        } else {
            XCTFail("expected readiness failure, got \(manager.status)")
        }
    }

    func testManagedServerProcessComparisonResolvesSymlinkedExecutablePaths() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let realBinary = tempDirectory.appendingPathComponent("target/release/hud-hook")
        try FileManager.default.createDirectory(
            at: realBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: realBinary.path, contents: Data()))

        let installedBinary = tempDirectory.appendingPathComponent(".local/bin/hud-hook")
        try FileManager.default.createDirectory(
            at: installedBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createSymbolicLink(
            atPath: installedBinary.path,
            withDestinationPath: realBinary.path,
        )

        XCTAssertTrue(
            HookServerManager.executablePathsMatch(
                runningPath: realBinary.path,
                configuredPath: installedBinary.path,
            ),
        )
    }

    func testStartIfNeededAdoptsSymlinkResolvedManagedProcess() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let realBinary = tempDirectory.appendingPathComponent("target/release/hud-hook")
        try FileManager.default.createDirectory(
            at: realBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: realBinary.path, contents: Data()))

        let installedBinary = tempDirectory.appendingPathComponent(".local/bin/hud-hook")
        try FileManager.default.createDirectory(
            at: installedBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createSymbolicLink(
            atPath: installedBinary.path,
            withDestinationPath: realBinary.path,
        )

        var launchCount = 0
        var receivedAuthToken: String?

        let manager = HookServerManager(
            port: 8134,
            binaryPath: installedBinary.path,
            dependencies: makeDependencies(
                readPidFile: { _ in 777 },
                isProcessAlive: { _ in true },
                isManagedServerProcess: { _, configuredPath in
                    HookServerManager.executablePathsMatch(
                        runningPath: realBinary.path,
                        configuredPath: configuredPath,
                    )
                },
                loadRuntimeServiceConnection: { _ in
                    RuntimeServiceConnection(
                        baseURL: URL(string: "http://127.0.0.1:8134")!,
                        bearerToken: "persisted-token",
                    )
                },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    return FakeHookServerProcess(pid: 97)
                },
                fetchHealth: { _, authToken in
                    receivedAuthToken = authToken
                    return Self.makeCompatibleHealth(pid: 97)
                },
            ),
        )

        manager.startIfNeeded()
        manager.checkHealth()
        await waitUntil { manager.status == HookServerManager.Status.running }

        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(receivedAuthToken, "persisted-token")
    }

    func testBootstrapHealthPayloadRejectsUnexpectedProtocolVersion() {
        let payload = Data(
            """
            {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":99,"auth_mode":"bearer","service_mode":"bootstrap_only"}
            """.utf8,
        )

        XCTAssertFalse(HookServerManager.isCompatibleBootstrapServiceHealth(payload))
    }

    func testBootstrapHealthPayloadRejectsUnexpectedAuthMode() {
        let payload = Data(
            """
            {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":1,"auth_mode":"none","service_mode":"bootstrap_only"}
            """.utf8,
        )

        XCTAssertFalse(HookServerManager.isCompatibleBootstrapServiceHealth(payload))
    }

    func testBootstrapHealthPayloadRejectsUnexpectedServiceMode() {
        let payload = Data(
            """
            {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":1,"auth_mode":"bearer","service_mode":"daemon"}
            """.utf8,
        )

        XCTAssertFalse(HookServerManager.isCompatibleBootstrapServiceHealth(payload))
    }

    private func makeDependencies(
        readPidFile: @escaping (String) -> Int32? = { _ in nil },
        removePidFile: @escaping (String) -> Void = { _ in },
        isProcessAlive: @escaping (Int32) -> Bool = { _ in true },
        isManagedServerProcess: @escaping (Int32, String) -> Bool = { _, _ in true },
        terminatePid: @escaping (Int32) -> Void = { _ in },
        killPid: @escaping (Int32) -> Void = { _ in },
        waitForProcessExit: @escaping (Int32, TimeInterval) -> Bool = { _, _ in true },
        loadRuntimeServiceConnection: @escaping (UInt16) -> RuntimeServiceConnection? = { _ in nil },
        launchProcess: @escaping (String, UInt16, [String: String]) throws -> any HookServerProcessControlling = { _, _, _ in
            FakeHookServerProcess(pid: 11)
        },
        launchProcessWithTermination: ((String, UInt16, [String: String], @escaping @Sendable (Int32) -> Void) throws -> any HookServerProcessControlling)? = nil,
        fetchHealth: @escaping (UInt16, String?) -> RuntimeHealth? = { _, _ in nil },
    ) -> HookServerManagerDependencies {
        HookServerManagerDependencies(
            isExecutableFile: { _ in true },
            readPidFile: readPidFile,
            removePidFile: removePidFile,
            isProcessAlive: isProcessAlive,
            isManagedServerProcess: isManagedServerProcess,
            terminatePid: terminatePid,
            killPid: killPid,
            waitForProcessExit: waitForProcessExit,
            loadRuntimeServiceConnection: loadRuntimeServiceConnection,
            launchProcess: launchProcessWithTermination ?? { binaryPath, port, environment, _ in
                try launchProcess(binaryPath, port, environment)
            },
            fetchHealth: fetchHealth,
        )
    }

    private static func makeCompatibleHealth(pid: Int = 4242) -> RuntimeHealth {
        RuntimeHealth(
            status: "ok",
            pid: pid,
            version: "runtime-service-v1",
            protocolVersion: 1,
            schemaVersion: 2,
            authMode: "bearer",
            serviceMode: "bootstrap_only",
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool,
    ) async {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > .nanoseconds(Int64(timeoutNanoseconds)) {
                XCTFail("condition not met before timeout")
                return
            }
            await _Concurrency.Task.yield()
        }
    }
}

private final class FakeHookServerProcess: HookServerProcessControlling {
    var isRunning = true
    let processIdentifier: Int32
    var terminationStatus: Int32 = 0
    private(set) var terminateCallCount = 0
    private var terminationHandler: (@Sendable (Int32) -> Void)?
    private let stopsOnTerminate: Bool

    init(pid: Int32, stopsOnTerminate: Bool = true) {
        processIdentifier = pid
        self.stopsOnTerminate = stopsOnTerminate
    }

    func terminate() {
        terminateCallCount += 1
        if stopsOnTerminate {
            isRunning = false
        }
    }

    func attachTerminationHandler(_ terminationHandler: @escaping @Sendable (Int32) -> Void) {
        self.terminationHandler = terminationHandler
    }

    func simulateExit(status: Int32) {
        terminationStatus = status
        isRunning = false
        terminationHandler?(status)
    }
}
