@testable import Capacitor
import AppKit
import XCTest

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testRuntimeBootstrapStartsHookServerBeforeCheckingRuntimeHealth() async {
        let appState = AppState(runtimeClient: RuntimeClient(isEnabledOverride: false))

        for _ in 0 ..< 200 where !appState.runtimeBootstrapTraceForTesting.contains("ensureRuntimeReady") {
            await _Concurrency.Task.yield()
        }

        appState.cancelRuntimeAutomationForTesting()

        let startIndex = appState.runtimeBootstrapTraceForTesting.firstIndex(of: "startHookServer")
        let ensureIndex = appState.runtimeBootstrapTraceForTesting.firstIndex(of: "ensureRuntimeReady")

        XCTAssertNotNil(startIndex)
        XCTAssertNotNil(ensureIndex)
        let unwrappedStartIndex = try? XCTUnwrap(startIndex)
        let unwrappedEnsureIndex = try? XCTUnwrap(ensureIndex)
        XCTAssertLessThan(
            unwrappedStartIndex ?? .max,
            unwrappedEnsureIndex ?? .min,
            "runtime supervision should adopt or launch the runtime before AppState trusts discovery",
        )
    }

    func testApplicationWillTerminateShutsDownAppState() {
        let appState = AppState(runtimeClient: RuntimeClient(isEnabledOverride: false))
        appState.cancelRuntimeAutomationForTesting()

        let delegate = AppDelegate()
        delegate.appState = appState

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertTrue(appState.didShutdownForTesting)
    }

    func testIncompatibleRuntimeHealthRestartsHookServerAndShowsToast() async throws {
        var launchCount = 0
        let runtimeClient = try RuntimeClient(
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:7812")),
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                let json = """
                {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":1,"auth_mode":"bearer","service_mode":"bootstrap_only"}
                """
                return (Data(json.utf8), response)
            },
        )
        let hookServerManager = HookServerManager(
            port: 8140,
            binaryPath: "/tmp/hud-hook",
            dependencies: HookServerManagerDependencies(
                isExecutableFile: { _ in true },
                readPidFile: { _ in nil },
                removePidFile: { _ in },
                isProcessAlive: { _ in true },
                isManagedServerProcess: { _, _ in true },
                terminatePid: { _ in },
                killPid: { _ in },
                waitForProcessExit: { _, _ in true },
                loadRuntimeServiceConnection: { _ in nil },
                launchProcess: { _, _, _, _ in
                    launchCount += 1
                    return AppLifecycleHookServerProcess(pid: 41)
                },
                fetchHealth: { _, _ in nil },
            ),
        )
        let appState = AppState(
            runtimeClient: runtimeClient,
            hookServerManager: hookServerManager,
        )
        appState.cancelRuntimeAutomationForTesting()

        appState.checkRuntimeHealth()

        await waitUntil { appState.toast?.message == "Runtime service restarted for compatibility" }

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(appState.toast?.message, "Runtime service restarted for compatibility")
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

private final class AppLifecycleHookServerProcess: HookServerProcessControlling {
    var isRunning = true
    let processIdentifier: Int32
    var terminationStatus: Int32 = 0

    init(pid: Int32) {
        processIdentifier = pid
    }

    func terminate() {
        isRunning = false
    }
}
