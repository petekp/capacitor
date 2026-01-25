import XCTest

final class ProjectCardStateResolutionRegressionTests: XCTestCase {
    func testProjectCardCurrentStateUsesRuntimeSessionState() throws {
        let source = try loadProjectViewSource(named: "ProjectCardView.swift")

        XCTAssertFalse(
            source.contains("switch glassConfig.previewState"),
            "ProjectCardView should resolve card state from runtime session state. A preview-state override can force cards to appear Idle while daemon session state is Working/Ready.",
        )
        XCTAssertTrue(
            source.contains(
                """
                private var currentState: SessionState {
                        sessionState?.state ?? .idle
                    }
                """,
            ),
            "ProjectCardView.currentState should render directly from sessionState with idle as a nil fallback.",
        )
    }

    func testCardLifecycleHandlersDoNotSkipSessionTransitionsWhenPreviewIsSet() throws {
        let source = try loadProjectViewSource(named: "ProjectCardModifiers.swift")

        XCTAssertFalse(
            source.contains("if let preview = glassConfig?.previewState, preview != .none { return }"),
            "Card lifecycle handlers should always react to runtime session transitions. Skipping updates behind previewState can suppress visible state changes.",
        )
    }

    func testStatusIndicatorUsesNumericTextTransitionForStatusLabels() throws {
        let source = try loadProjectViewSource(named: "ProjectCardComponents.swift")

        XCTAssertTrue(
            source.contains(".contentTransition(reduceMotion ? .identity : .numericText())"),
            "StatusIndicator should use the numericText content transition path used in the recent alpha baseline for animated status text changes.",
        )
    }

    func testStatusIndicatorDoesNotUseInterpolatingTransitionForStateText() throws {
        let source = try loadProjectViewSource(named: "ProjectCardComponents.swift")

        XCTAssertFalse(
            source.contains(".contentTransition(reduceMotion ? .identity : .interpolate)"),
            "StatusIndicator should prefer the numericText transition configuration from the recent alpha baseline instead of interpolate.",
        )
    }

    func testStatusIndicatorDoesNotForceIdentityResetOnStateChanges() throws {
        let source = try loadProjectViewSource(named: "ProjectCardComponents.swift")

        XCTAssertFalse(
            source.contains(".id(state)"),
            "StatusIndicator should keep stable identity and animate text/color in place. Forcing identity resets can short-circuit interpolate transitions.",
        )
    }

    private func loadProjectViewSource(named fileName: String) throws -> String {
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
