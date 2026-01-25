import XCTest

final class AppStateTerminalRoutingRegressionTests: XCTestCase {
    func testIdeasFlowDoesNotHardLaunchTerminalApp() throws {
        let source = try loadAppStateSource()

        XCTAssertFalse(
            source.contains(#"\\"Terminal\\" to do script"#),
            "AppState ideas flow must route terminal opens through TerminalScripts instead of spawning Terminal.app.",
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
