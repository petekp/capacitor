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
                findManagedServerProcessForPort: { _, _ in nil },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    if launchCount > 1 {
                        unexpectedRestart.fulfill()
                    }
                    return process
                },
                fetchHealth: { _ in
                    await withCheckedContinuation { checkedContinuation in
                        continuation = checkedContinuation
                    }
                },
            ),
        )

        manager.startIfNeeded()
        await assertEventually { launchCount == 1 }
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

    func testStartIfNeededRemovesForeignLivePidAndLaunchesFreshProcess() async {
        let process = FakeHookServerProcess(pid: 51)
        var removedPidFilePaths: [String] = []
        var launchCount = 0

        let manager = HookServerManager(
            port: 8124,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                readPidFile: { _ in 999 },
                removePidFile: { removedPidFilePaths.append($0) },
                findManagedServerProcessForPort: { _, _ in nil },
                isProcessAlive: { _ in true },
                isManagedServerProcess: { _, _ in false },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    return process
                },
            ),
        )

        manager.startIfNeeded()
        await assertEventually { launchCount == 1 }

        XCTAssertEqual(removedPidFilePaths.count, 1)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(manager.status, HookServerManager.Status.starting)
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

    func testStartIfNeededAdoptsManagedLiveServerWithoutPidFile() async {
        var launchCount = 0
        var terminatedPids: [Int32] = []
        var continuation: CheckedContinuation<Int32?, Never>?
        var isProcessAliveCalls: [Int32] = []

        let manager = HookServerManager(
            port: 8126,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                readPidFile: { _ in nil },
                findManagedServerProcessForPort: { port, path in
                    XCTAssertEqual(port, 8126)
                    XCTAssertEqual(path, "/tmp/hud-hook")
                    return await withCheckedContinuation { checkedContinuation in
                        continuation = checkedContinuation
                    }
                },
                isProcessAlive: { pid in
                    isProcessAliveCalls.append(pid)
                    XCTAssertEqual(pid, 555)
                    return true
                },
                terminatePid: { terminatedPids.append($0) },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    return FakeHookServerProcess(pid: 88)
                },
            ),
        )

        manager.startIfNeeded()
        XCTAssertEqual(manager.status, .starting)
        XCTAssertEqual(launchCount, 0, "probe should not launch while discovery is pending")

        for _ in 0 ..< 20 where continuation == nil {
            await _Concurrency.Task.yield()
        }
        XCTAssertNotNil(continuation)

        continuation?.resume(returning: 555)
        await assertEventually { isProcessAliveCalls == [555] && launchCount == 0 }

        manager.stop()

        XCTAssertEqual(terminatedPids, [555], "manager should adopt live server instead of launching duplicate")
        XCTAssertEqual(launchCount, 0)
    }

    func testStopPreventsLateLiveServerProbeFromLaunching() async {
        let process = FakeHookServerProcess(pid: 91)
        var launchCount = 0
        var continuation: CheckedContinuation<Int32?, Never>?

        let manager = HookServerManager(
            port: 8127,
            binaryPath: "/tmp/hud-hook",
            dependencies: makeDependencies(
                readPidFile: { _ in nil },
                findManagedServerProcessForPort: { _, _ in
                    await withCheckedContinuation { checkedContinuation in
                        continuation = checkedContinuation
                    }
                },
                launchProcess: { _, _, _ in
                    launchCount += 1
                    return process
                },
            ),
        )

        manager.startIfNeeded()

        for _ in 0 ..< 20 where continuation == nil {
            await _Concurrency.Task.yield()
        }
        XCTAssertNotNil(continuation)

        manager.stop()
        continuation?.resume(returning: nil)
        await _Concurrency.Task.yield()
        await assertEventually { launchCount == 0 }

        XCTAssertEqual(manager.status, .stopped)
        XCTAssertEqual(launchCount, 0, "explicit stop must dominate late live-server probe results")
    }

    func testManagedExecutableComparisonResolvesSymlinkedBinaryPaths() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let realBinary = temp.appendingPathComponent("hud-hook-real")
        let symlinkBinary = temp.appendingPathComponent("hud-hook-link")

        FileManager.default.createFile(atPath: realBinary.path, contents: Data("binary".utf8))
        try FileManager.default.createSymbolicLink(at: symlinkBinary, withDestinationURL: realBinary)

        XCTAssertTrue(
            HookServerManager.pathsReferToSameExecutable(realBinary.path, symlinkBinary.path),
        )
    }

    private func makeDependencies(
        readPidFile: @escaping (String) -> Int32? = { _ in nil },
        removePidFile: @escaping (String) -> Void = { _ in },
        findManagedServerProcessForPort: @escaping (UInt16, String) async -> Int32? = { _, _ in nil },
        isProcessAlive: @escaping (Int32) -> Bool = { _ in true },
        isManagedServerProcess: @escaping (Int32, String) -> Bool = { _, _ in true },
        terminatePid: @escaping (Int32) -> Void = { _ in },
        launchProcess: @escaping (String, UInt16, [String: String]) throws -> any HookServerProcessControlling = { _, _, _ in
            FakeHookServerProcess(pid: 11)
        },
        fetchHealth: @escaping (UInt16) async -> Bool = { _ in true },
    ) -> HookServerManagerDependencies {
        HookServerManagerDependencies(
            isExecutableFile: { _ in true },
            readPidFile: readPidFile,
            removePidFile: removePidFile,
            findManagedServerProcessForPort: findManagedServerProcessForPort,
            isProcessAlive: isProcessAlive,
            isManagedServerProcess: isManagedServerProcess,
            terminatePid: terminatePid,
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

@MainActor
private func assertEventually(
    timeoutNanoseconds: UInt64 = 200_000_000,
    condition: @escaping @MainActor () -> Bool,
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return
        }
        await _Concurrency.Task.yield()
    }
    XCTAssertTrue(condition())
}
