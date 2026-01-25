import XCTest

final class ActivityPanelTerminalRoutingRegressionTests: XCTestCase {
    func testOpenProjectFallbackDoesNotHardLaunchTerminalApp() throws {
        let source = try loadActivityPanelSource()

        XCTAssertFalse(
            source.contains("open -a Terminal"),
            "ActivityPanel should route terminal opens through TerminalLauncher instead of hard-launching Terminal.app.",
        )
    }

    private func loadActivityPanelSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Views/Projects/ActivityPanel.swift")

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
