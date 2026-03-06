@testable import Capacitor
import XCTest

@MainActor
final class ProjectCreationCoordinatorTests: XCTestCase {
    func testSelectDiscoveredSessionIdChoosesNewestSessionFile() throws {
        let tempDir = try XCTUnwrap(FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let projectPath = "/tmp/projects/capacitor"
        let sessionDir = tempDir.appendingPathComponent("tmp-projects-capacitor", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let baseline = sessionDir.appendingPathComponent("existing.jsonl")
        let olderNew = sessionDir.appendingPathComponent("session-010.jsonl")
        let newestNew = sessionDir.appendingPathComponent("session-100.jsonl")

        try Data("{}".utf8).write(to: baseline)
        try Data("{}".utf8).write(to: olderNew)
        try Data("{}".utf8).write(to: newestNew)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: baseline.path,
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: olderNew.path,
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 300)],
            ofItemAtPath: newestNew.path,
        )

        let coordinator = makeCoordinator(claudeProjectsDirectory: tempDir)

        let selected = coordinator.selectDiscoveredSessionIdForTesting(
            projectPath: projectPath,
            existingSessions: ["existing"],
        )

        XCTAssertEqual(selected, "session-100")
    }

    func testSessionFileURLUsesInjectedClaudeProjectsDirectory() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = makeCoordinator(claudeProjectsDirectory: tempDir)

        let sessionFile = coordinator.sessionFileURLForTesting(
            projectPath: "/tmp/projects/capacitor",
            sessionId: "session-123",
        )

        XCTAssertEqual(
            sessionFile.path,
            tempDir
                .appendingPathComponent("tmp-projects-capacitor", isDirectory: true)
                .appendingPathComponent("session-123.jsonl")
                .path,
        )
    }

    private func makeCoordinator(claudeProjectsDirectory: URL) -> ProjectCreationCoordinator {
        var creations: [ProjectCreation] = []
        return ProjectCreationCoordinator(
            ideaCaptureEnabled: { true },
            readCreations: { creations },
            writeCreations: { creations = $0 },
            engineProvider: { nil },
            dashboardReloader: {},
            claudeProjectsDirectoryProvider: { claudeProjectsDirectory },
        )
    }
}
