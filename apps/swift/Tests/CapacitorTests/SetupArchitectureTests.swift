import XCTest

final class SetupArchitectureTests: XCTestCase, ArchitectureAssertions {
    func testProjectViewsDoNotCallSetupMutationThroughAppState() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift",
            omits: [
                "appState.fixHooks()",
                "appState.testHooks()",
                "appState.checkHookDiagnostic()",
            ],
        )
    }
}
