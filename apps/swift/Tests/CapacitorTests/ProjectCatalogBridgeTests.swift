@testable import Capacitor
import XCTest

final class ProjectCatalogBridgeTests: XCTestCase {
    func testShellProjectCatalogEntryConvenienceInitializerPreservesCatalogFields() {
        let entry = ShellProjectCatalogEntry(
            displayName: "Capacitor",
            path: "/tmp/capacitor",
            displayPath: "~/Code/capacitor",
            lastActiveAt: "2026-03-05T00:00:00Z",
            claudeMdPath: "/tmp/capacitor/CLAUDE.md",
            claudeMdPreview: "Preview",
            hasLocalSettings: true,
            taskCount: 7,
            stats: makeShellProjectStats(),
            isMissing: true,
        )

        XCTAssertEqual(entry.id, "/tmp/capacitor")
        XCTAssertEqual(entry.displayName, "Capacitor")
        XCTAssertEqual(entry.path, "/tmp/capacitor")
        XCTAssertEqual(entry.displayPath, "~/Code/capacitor")
        XCTAssertEqual(entry.lastActiveAt, "2026-03-05T00:00:00Z")
        XCTAssertEqual(entry.claudeMdPath, "/tmp/capacitor/CLAUDE.md")
        XCTAssertEqual(entry.claudeMdPreview, "Preview")
        XCTAssertTrue(entry.hasLocalSettings)
        XCTAssertEqual(entry.taskCount, 7)
        XCTAssertEqual(entry.stats, makeShellProjectStats())
        XCTAssertTrue(entry.isMissing)
    }

    func testShellSuggestedProjectCandidateConvenienceInitializerPreservesSuggestionFields() {
        let candidate = ShellSuggestedProjectCandidate(
            displayName: "Intent",
            path: "/tmp/intent",
            displayPath: "~/Code/intent",
            taskCount: 3,
            hasClaudeMd: true,
            hasProjectIndicators: true,
        )

        XCTAssertEqual(candidate.id, "/tmp/intent")
        XCTAssertEqual(candidate.displayName, "Intent")
        XCTAssertEqual(candidate.path, "/tmp/intent")
        XCTAssertEqual(candidate.displayPath, "~/Code/intent")
        XCTAssertEqual(candidate.taskCount, 3)
        XCTAssertTrue(candidate.hasClaudeMd)
        XCTAssertTrue(candidate.hasProjectIndicators)
    }

    private func makeShellProjectStats() -> ShellProjectStats {
        ShellProjectStats(
            totalInputTokens: 10,
            totalOutputTokens: 20,
            totalCacheReadTokens: 30,
            totalCacheCreationTokens: 40,
            opusMessages: 1,
            sonnetMessages: 2,
            haikuMessages: 3,
            sessionCount: 4,
            latestSummary: "Latest",
            firstActivity: "2026-03-01T00:00:00Z",
            lastActivity: "2026-03-05T00:00:00Z",
        )
    }
}
