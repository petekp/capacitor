import XCTest

final class ProjectCardSessionObservationRegressionTests: XCTestCase {
    func testProjectsViewBodySnapshotsSessionStatesForObservation() throws {
        let source = try loadSourceFile(named: "ProjectsView.swift")

        XCTAssertTrue(
            source.contains("let sessionStates = appState.sessionStateManager.sessionStates"),
            "ProjectsView should snapshot appState.sessionStateManager.sessionStates in body so list rendering re-evaluates when per-project session state changes.",
        )
    }

    func testProjectsViewBodyObservesSessionStateRevision() throws {
        let source = try loadSourceFile(named: "ProjectsView.swift")

        XCTAssertTrue(
            source.contains("let _ = appState.sessionStateRevision"),
            "ProjectsView must observe appState.sessionStateRevision so nested SessionStateManager updates always invalidate card rendering.",
        )
    }

    func testDockLayoutBodySnapshotsSessionStatesForObservation() throws {
        let source = try loadSourceFile(named: "DockLayoutView.swift")

        XCTAssertTrue(
            source.contains("let sessionStates = appState.sessionStateManager.sessionStates"),
            "DockLayoutView should snapshot appState.sessionStateManager.sessionStates in body so dock card grouping and rendering follow live per-project session state.",
        )
    }

    func testDockLayoutBodyObservesSessionStateRevision() throws {
        let source = try loadSourceFile(named: "DockLayoutView.swift")

        XCTAssertTrue(
            source.contains("let _ = appState.sessionStateRevision"),
            "DockLayoutView must observe appState.sessionStateRevision so dock cards refresh when daemon session state changes.",
        )
    }

    private func loadSourceFile(named fileName: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Views/Projects")
            .appendingPathComponent(fileName)

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
