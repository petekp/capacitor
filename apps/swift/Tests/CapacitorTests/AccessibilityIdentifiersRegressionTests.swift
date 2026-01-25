import XCTest

final class AccessibilityIdentifiersRegressionTests: XCTestCase {
    func testProjectCardViewIncludesStableCardIdentifier() throws {
        let source = try loadSourceFile(
            directory: "Views/Projects",
            fileName: "ProjectCardView.swift",
        )

        XCTAssertTrue(
            source.contains("AccessibilityIdentifiers.projectCardIdentifier(for: project)"),
            "ProjectCardView should expose stable card accessibility identifiers.",
        )
    }

    func testDockProjectCardIncludesStableCardIdentifier() throws {
        let source = try loadSourceFile(
            directory: "Views/Projects",
            fileName: "DockProjectCard.swift",
        )

        XCTAssertTrue(
            source.contains("AccessibilityIdentifiers.projectCardIdentifier(for: project)"),
            "DockProjectCard should expose stable card accessibility identifiers.",
        )
    }

    func testProjectCardComponentsIncludesStableDemoDetailsIdentifierHook() throws {
        let source = try loadSourceFile(
            directory: "Views/Projects",
            fileName: "ProjectCardComponents.swift",
        )

        XCTAssertTrue(
            source.contains("accessibilityIdentifier"),
            "ProjectCardComponents should expose a deterministic accessibility identifier seam for details navigation.",
        )
    }

    func testProjectDetailViewIncludesStableNavigationIdentifiers() throws {
        let source = try loadSourceFile(
            directory: "Views/Projects",
            fileName: "ProjectDetailView.swift",
        )

        XCTAssertTrue(
            source.contains("AccessibilityIdentifiers.projectDetailsIdentifier(for: project)"),
            "ProjectDetailView should expose stable details container identifiers.",
        )
        XCTAssertTrue(
            source.contains("AccessibilityIdentifiers.backProjectsIdentifier"),
            "ProjectDetailView should expose a stable back-navigation identifier.",
        )
    }

    private func loadSourceFile(directory: String, fileName: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor")
            .appendingPathComponent(directory)
            .appendingPathComponent(fileName)

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
