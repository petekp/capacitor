import XCTest

final class FooterControlsRegressionTests: XCTestCase {
    func testAddProjectButtonUsesFolderBrowsingIconAndTooltip() throws {
        let source = try loadFooterViewSource()

        XCTAssertTrue(
            source.contains("Image(systemName: \"folder.badge.plus\")"),
            "Footer add-project button should use a folder browsing icon.",
        )
        XCTAssertTrue(
            source.contains(".help(\"Connect a project\")"),
            "Footer add-project button should clearly explain that it opens folder browsing.",
        )
    }

    func testPinButtonTooltipExplainsAlwaysOnTopToggle() throws {
        let source = try loadFooterViewSource()

        XCTAssertTrue(
            source.contains("Unpin from top (⌘⇧P)"),
            "Pin tooltip should clearly communicate the unpin action.",
        )
        XCTAssertTrue(
            source.contains("Pin to top (⌘⇧P)"),
            "Pin tooltip should clearly communicate the pin action.",
        )
    }

    func testLogoReleasePathMatchesAlphaDebugAppearanceDefaults() throws {
        let source = try loadFooterViewSource()

        XCTAssertTrue(
            source.contains("releaseLogoContent(nsImage: nsImage)"),
            "Release logo rendering should use a dedicated parity path instead of the simplified static fallback.",
        )
        XCTAssertTrue(
            source.contains("private let releaseLogoScale: CGFloat = 0.84"),
            "Release logo scale should match alpha debug defaults to avoid oversized branding in production.",
        )
        XCTAssertTrue(
            source.contains("private let releaseLogoOpacity: Double = 0.22"),
            "Release logo opacity should match alpha debug defaults to preserve intended vibrancy.",
        )
        XCTAssertTrue(
            source.contains("private let releaseLogoBlendMode: BlendMode = .overlay"),
            "Release logo blend mode should match alpha debug defaults for color richness.",
        )
        XCTAssertTrue(
            source.contains("material: .menu"),
            "Release logo vibrancy material should match alpha debug defaults.",
        )
    }

    private func loadFooterViewSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/swift
        let fileURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Views/Footer/FooterView.swift")

        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
