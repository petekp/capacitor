import XCTest

final class ProjectListRoutingVisibilityRegressionTests: XCTestCase {
    func testProjectsViewDoesNotRenderTerminalRoutingStatusRow() throws {
        let source = try loadSourceFile(named: "ProjectsView.swift")

        XCTAssertFalse(
            source.contains("TerminalRoutingStatusRow()"),
            "ProjectsView should not render TerminalRoutingStatusRow in the user-facing project list.",
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
