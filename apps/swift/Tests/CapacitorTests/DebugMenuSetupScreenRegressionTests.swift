import XCTest

final class DebugMenuSetupScreenRegressionTests: XCTestCase {
    func testDebugMenuContainsReturnToSetupScreenAction() throws {
        let source = try loadAppSource()

        XCTAssertTrue(
            source.contains("Button(\"Return to Setup Screen\")"),
            "Debug menu should expose an explicit action to return to the setup screen for onboarding testing.",
        )
        XCTAssertTrue(
            source.contains("setupComplete = false"),
            "Return to setup action should reset setupComplete state.",
        )
    }

    private func loadAppSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/App.swift")

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
