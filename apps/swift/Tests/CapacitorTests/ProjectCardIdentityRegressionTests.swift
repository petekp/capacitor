import XCTest

final class ProjectCardIdentityRegressionTests: XCTestCase {
    func testProjectsViewActiveCardIdentityDoesNotUseGlobalSessionRevision() throws {
        let source = try loadSourceFile(named: "ProjectsView.swift")

        XCTAssertFalse(
            source.contains(".id(\"\\(project.path)-\\(appState.sessionStateRevision)\")"),
            "Active card identity in ProjectsView should be stable per project path and must not depend on global sessionStateRevision.",
        )
    }

    func testDockLayoutActiveCardIdentityDoesNotUseGlobalSessionRevision() throws {
        let source = try loadSourceFile(named: "DockLayoutView.swift")

        XCTAssertFalse(
            source.contains(".id(\"\\(project.path)-\\(appState.sessionStateRevision)\")"),
            "Active card identity in DockLayoutView should be stable per project path and must not depend on global sessionStateRevision.",
        )
    }

    func testProjectsViewCardIdentityUsesStablePathKey() throws {
        let source = try loadSourceFile(named: "ProjectsView.swift")

        XCTAssertTrue(
            source.contains(".id(ProjectOrdering.cardIdentityKey("),
            "ProjectsView should derive card identity from a stable path key helper, not a state-dependent id expression.",
        )
    }

    func testDockLayoutCardIdentityUsesStablePathKey() throws {
        let source = try loadSourceFile(named: "DockLayoutView.swift")

        XCTAssertTrue(
            source.contains(".id(ProjectOrdering.cardIdentityKey("),
            "DockLayoutView should derive card identity from a stable path key helper, not a state-dependent id expression.",
        )
    }

    func testProjectsViewDoesNotInvalidateWholeCardViaContentStateFingerprint() throws {
        let source = try loadSourceFile(named: "ProjectsView.swift")

        XCTAssertFalse(
            source.contains(".id(ProjectOrdering.cardContentStateFingerprint(sessionState: sessionState))"),
            "ProjectsView should not remount whole card content for state changes. Only effect/status sublayers should animate in place.",
        )
    }

    func testDockLayoutDoesNotInvalidateWholeCardViaContentStateFingerprint() throws {
        let source = try loadSourceFile(named: "DockLayoutView.swift")

        XCTAssertFalse(
            source.contains(".id(ProjectOrdering.cardContentStateFingerprint(sessionState: sessionState))"),
            "DockLayoutView should not remount whole dock card content for state changes. Only effect/status sublayers should animate in place.",
        )
    }

    func testDockLayoutDoesNotApplyScrollTransitionToProjectCards() throws {
        let source = try loadSourceFile(named: "DockLayoutView.swift")

        XCTAssertFalse(
            source.contains(".scrollTransition {"),
            "Dock project cards should not apply scrollTransition scale/opacity effects. State changes must preserve card visibility and avoid perceived remount artifacts.",
        )
    }

    func testProjectsViewUsesUnifiedRowsForEachAndNotSplitGroupedLoops() throws {
        let source = try loadSourceFile(named: "ProjectsView.swift")

        XCTAssertTrue(
            source.contains("let rows = grouped.active + grouped.idle"),
            "ProjectsView should render active+idle cards through one unified rows list to avoid cross-section update stalls.",
        )
        XCTAssertFalse(
            source.contains("ForEach(Array(grouped.active.enumerated())"),
            "ProjectsView should not use a dedicated grouped.active loop for card rows.",
        )
        XCTAssertFalse(
            source.contains("ForEach(Array(grouped.idle.enumerated())"),
            "ProjectsView should not use a dedicated grouped.idle loop for card rows.",
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
