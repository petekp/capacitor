import XCTest

final class AppStateRuntimeStartupRegressionTests: XCTestCase {
    func testRuntimeBootstrapDoesNotUseLaunchdService() throws {
        let source = try loadAppStateSource()

        XCTAssertFalse(
            source.contains("DaemonService.enableForCurrentProcess()"),
            "AppState should not toggle daemon launchd environment flags in direct core mode.",
        )
        XCTAssertFalse(
            source.contains("DaemonService.ensureRunning()"),
            "AppState should not attempt to launch capacitor-daemon in direct core mode.",
        )
    }

    func testLegacyStartupTaskCoordinationIsRemoved() throws {
        let source = try loadAppStateSource()

        XCTAssertFalse(
            source.contains(
                "private var daemonStartupTask: _Concurrency.Task<Void, Never>?",
            ),
            "AppState should not track daemon startup task state after removing launchd daemon startup logic.",
        )
        XCTAssertFalse(
            source.contains("guard daemonStartupTask == nil else {"),
            "ensureRuntimeReady should no longer guard in-flight daemon startup tasks.",
        )
        XCTAssertFalse(
            source.contains("daemonRecoveryDecider.shouldAttemptRecovery"),
            "AppState should not attempt daemon restart recovery in direct core mode.",
        )
    }

    func testRuntimeRefreshPathUsesUnifiedSnapshotWithoutLegacyManagerFallback() throws {
        let source = try loadAppStateSource()

        XCTAssertTrue(
            source.contains("RuntimeClient.shared.fetchRuntimeSnapshot(correlationId: correlationId)"),
            "AppState.refreshSessionStates should use the unified runtime snapshot endpoint as its single read path.",
        )
        XCTAssertFalse(
            source.contains("sessionStateManager.refreshSessionStates(for: currentProjects)"),
            "AppState.refreshSessionStates should not fall back to SessionStateManager-owned daemon fetch orchestration.",
        )
        XCTAssertFalse(
            source.contains("shellStateStore.stopPolling()"),
            "AppState should not rely on ShellStateStore polling control in the unified snapshot refresh architecture.",
        )
    }

    private func loadAppStateSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Models/AppState.swift")

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
