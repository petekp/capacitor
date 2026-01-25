import XCTest

final class AppStateFileBrowserRegressionTests: XCTestCase {
    func testFileBrowserAllowsSelectingMultipleDirectories() throws {
        let source = try loadAppStateSource()

        XCTAssertTrue(
            source.contains("panel.allowsMultipleSelection = true"),
            "connectProjectViaFileBrowser should allow selecting multiple directories.",
        )
    }

    func testFileBrowserUsesPanelURLsAndRoutesMultiSelectionToBatchIngestion() throws {
        let source = try loadAppStateSource()

        XCTAssertTrue(
            source.contains("let urls = panel.urls"),
            "connectProjectViaFileBrowser should read all selected directories via panel.urls.",
        )
        XCTAssertTrue(
            source.contains("if urls.count > 1 {"),
            "connectProjectViaFileBrowser should branch to multi-selection behavior.",
        )
        XCTAssertTrue(
            source.contains("addProjectsFromDrop(urls)"),
            "connectProjectViaFileBrowser should route multi-selection to existing batch ingestion.",
        )
        XCTAssertFalse(
            source.contains("panel.runModal() == .OK, let url = panel.url"),
            "connectProjectViaFileBrowser should not gate on single selection via panel.url.",
        )
    }

    func testBatchIngestionSuccessSetsTipFlag() throws {
        let source = try loadAppStateSource()

        XCTAssertTrue(
            source.contains("self.pendingDragDropTip = true"),
            "Batch project ingestion should set pendingDragDropTip when new projects connect.",
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
