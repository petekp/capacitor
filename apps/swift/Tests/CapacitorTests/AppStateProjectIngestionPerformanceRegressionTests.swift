import XCTest

final class AppStateProjectIngestionPerformanceRegressionTests: XCTestCase {
    func testProjectIngestionRefreshUsesFastDashboardReloadWithoutBlockingLoadingState() throws {
        let source = try loadAppStateSource()

        XCTAssertTrue(
            source.contains("self.loadDashboard(hydrateIdeas: false, showLoadingState: false)"),
            "Project ingestion should use a fast dashboard reload that skips eager idea hydration and avoids toggling loading skeleton during transition.",
        )
        XCTAssertTrue(
            source.contains("fastSwapTransaction.disablesAnimations = true"),
            "Project ingestion should disable bulk list transition animations for the initial connect-state -> list-state swap.",
        )
        XCTAssertTrue(
            source.contains("withTransaction(fastSwapTransaction) {"),
            "Project ingestion should perform the dashboard swap inside a no-animation transaction.",
        )
        XCTAssertFalse(
            source.contains("withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {\n                        self.loadDashboard()"),
            "Project ingestion should not run synchronous dashboard reload inside an animation block.",
        )
    }

    func testProjectIngestionSchedulesDeferredIdeaHydration() throws {
        let source = try loadAppStateSource()

        XCTAssertTrue(
            source.contains("self.scheduleDeferredIdeaHydration()"),
            "Project ingestion should defer expensive idea hydration until after the transition.",
        )
    }

    func testProjectIngestionUsesBatchProjectOrderPrepend() throws {
        let source = try loadAppStateSource()

        XCTAssertTrue(
            source.contains("self.prependToProjectOrder(paths: finalAddedPaths)"),
            "Project ingestion should batch prepend project order updates to avoid repeated persistence and telemetry during large imports.",
        )
        XCTAssertFalse(
            source.contains("for path in finalAddedPaths.reversed() {\n                        self.prependToProjectOrder(path)\n                    }"),
            "Project ingestion should avoid per-project order writes in the hot transition path.",
        )
    }

    func testDeferredHydrationUsesIncrementalIdeaLoading() throws {
        let appStateSource = try loadAppStateSource()
        let detailsSource = try loadProjectDetailsManagerSource()

        XCTAssertTrue(
            appStateSource.contains("await projectDetailsManager.loadAllIdeasIncrementally(for: projects)"),
            "Deferred hydration should use incremental loading to reduce frame-time spikes.",
        )
        XCTAssertTrue(
            detailsSource.contains("func loadAllIdeasIncrementally("),
            "ProjectDetailsManager should expose an incremental idea loading API for performance-sensitive flows.",
        )
        XCTAssertTrue(
            detailsSource.contains("await _Concurrency.Task.yield()"),
            "Incremental idea loading should periodically yield to keep the UI responsive.",
        )
    }

    func testLoadDashboardSupportsHydrationAndLoadingFlags() throws {
        let source = try loadAppStateSource()

        XCTAssertTrue(
            source.contains("func loadDashboard(hydrateIdeas: Bool = true, showLoadingState: Bool = true)"),
            "loadDashboard should expose flags so high-frequency transitions can skip expensive work.",
        )
        XCTAssertTrue(
            source.contains("if showLoadingState {"),
            "loadDashboard should only toggle loading UI when explicitly requested.",
        )
        XCTAssertTrue(
            source.contains("if hydrateIdeas, isIdeaCaptureEnabled {"),
            "loadDashboard should support skipping eager idea hydration for performance-sensitive transitions.",
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

    private func loadProjectDetailsManagerSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Models/ProjectDetailsManager.swift")

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
