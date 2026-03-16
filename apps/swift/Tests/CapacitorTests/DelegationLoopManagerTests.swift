@testable import Capacitor
import XCTest

final class DelegationLoopManagerTests: XCTestCase {
    func testSessionDiscoveryParsesCamelCaseSessionIDFromStreamJSON() {
        let line = #"{"type":"queue-operation","sessionId":"worker-session-123"}"#

        XCTAssertEqual(
            DelegationSessionDiscovery.sessionID(from: line),
            "worker-session-123",
        )
    }

    func testSessionDiscoveryFindsMostRecentSessionIDAcrossDirectoryCaseDifferences() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let sessionDirectory = tempDir
            .appendingPathComponent(
                "-Users-petepetrash-Code-capacitor--capacitor-worktrees-delegation-54da230f",
                isDirectory: true,
            )
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let older = sessionDirectory.appendingPathComponent("session-010.jsonl")
        let newer = sessionDirectory.appendingPathComponent("session-200.jsonl")
        try Data("{}".utf8).write(to: older)
        try Data("{}".utf8).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path,
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path,
        )

        let discovery = DelegationSessionDiscovery(
            fileManager: .default,
            claudeProjectsDirectory: tempDir,
        )

        XCTAssertEqual(
            discovery.mostRecentSessionID(
                for: "/users/petepetrash/code/capacitor/.capacitor/worktrees/delegation-54da230f",
            ),
            "session-200",
        )
    }

    func testReconcileAttachesSessionForReviewNeededDelegationWithoutSessionID() async throws {
        let tempDir = try makeClaudeProjectsDirectoryWithSession(
            workingDirectoryName: "-Users-petepetrash-Code-capacitor--capacitor-worktrees-delegation-54da230f",
            sessionID: "session-200",
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let mutationRecorder = MutationRecorder()
        let manager = DelegationLoopManager(
            mutateDelegation: { request in
                await mutationRecorder.record(request)
            },
            sessionDiscovery: DelegationSessionDiscovery(
                fileManager: .default,
                claudeProjectsDirectory: tempDir,
            ),
            claudeLauncher: { _, _ in
                XCTFail("reconcile should not launch Claude")
            },
        )

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: "/tmp/projects/capacitor",
                sessionId: nil,
                status: "review_needed",
                currentReview: RuntimeDelegationReview(
                    milestoneId: "01",
                    briefPath: "/tmp/brief.md",
                    manifestPath: "/tmp/manifest.json",
                    requestedAt: "2026-03-16T18:41:41Z",
                ),
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["attach_session"])
        XCTAssertEqual(requests.first?.sessionId, "session-200")
    }

    func testSubmitReviewDecisionBackfillsMissingSessionAndResumesSameSession() async throws {
        let tempDir = try makeClaudeProjectsDirectoryWithSession(
            workingDirectoryName: "-Users-petepetrash-Code-capacitor--capacitor-worktrees-delegation-54da230f",
            sessionID: "session-200",
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let projectPath = "/tmp/projects/capacitor-\(UUID().uuidString)"
        let projectDataDirectory = CapacitorProjectPaths.projectDataDirectory(for: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectDataDirectory)
        }

        let mutationRecorder = MutationRecorder()
        let launchRecorder = LaunchRecorder()
        let manager = DelegationLoopManager(
            mutateDelegation: { request in
                await mutationRecorder.record(request)
            },
            sessionDiscovery: DelegationSessionDiscovery(
                fileManager: .default,
                claudeProjectsDirectory: tempDir,
            ),
            claudeLauncher: { request, _ in
                await launchRecorder.record(request)
            },
        )

        try await manager.submitReviewDecision(
            project: makeProject(path: projectPath),
            delegation: makeDelegation(
                projectPath: projectPath,
                sessionId: nil,
                status: "review_needed",
                currentReview: RuntimeDelegationReview(
                    milestoneId: "01",
                    briefPath: "/tmp/brief.md",
                    manifestPath: "/tmp/manifest.json",
                    requestedAt: "2026-03-16T18:41:41Z",
                ),
            ),
            decision: .approve,
            note: "Ship it",
        )

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["attach_session", "resume"])
        XCTAssertEqual(requests.first?.sessionId, "session-200")
        XCTAssertEqual(requests.last?.sessionId, "session-200")

        let launches = await launchRecorder.snapshot()
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.resumeSessionID, "session-200")
    }

    func testClaudeLaunchArgumentsIncludeSingleThreadedWorkerGuardrails() {
        let request = DelegationClaudeLaunchRequest(
            workingDirectory: "/tmp/worktree",
            prompt: "hello world",
            resumeSessionID: "session-123",
        )

        XCTAssertEqual(
            request.arguments,
            [
                "-p",
                "--output-format",
                "stream-json",
                "--permission-mode",
                "bypassPermissions",
                "--disable-slash-commands",
                "--disallowedTools",
                "Agent",
                "--resume",
                "session-123",
            ],
        )
    }

    private func makeClaudeProjectsDirectoryWithSession(
        workingDirectoryName: String,
        sessionID: String,
    ) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sessionDirectory = tempDir.appendingPathComponent(workingDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let sessionFile = sessionDirectory.appendingPathComponent("\(sessionID).jsonl")
        try Data("{}".utf8).write(to: sessionFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: sessionFile.path,
        )
        return tempDir
    }

    private func makeDelegation(
        projectPath: String,
        sessionId: String?,
        status: String,
        currentReview: RuntimeDelegationReview?,
    ) -> RuntimeDelegationState {
        RuntimeDelegationState(
            projectPath: projectPath,
            workerId: "worker-1",
            ideaId: "idea-1",
            worktreeName: "delegation-54da230f",
            worktreePath: "/users/petepetrash/code/capacitor/.capacitor/worktrees/delegation-54da230f",
            sessionId: sessionId,
            status: status,
            startedAt: "2026-03-16T18:37:02Z",
            updatedAt: "2026-03-16T18:41:41Z",
            currentReview: currentReview,
        )
    }

    private func makeProject(path: String) -> Project {
        Project(
            name: "capacitor",
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }
}

private actor MutationRecorder {
    private var requests: [RuntimeDelegationMutationRequest] = []

    func record(_ request: RuntimeDelegationMutationRequest) {
        requests.append(request)
    }

    func snapshot() -> [RuntimeDelegationMutationRequest] {
        requests
    }
}

private actor LaunchRecorder {
    private var requests: [DelegationClaudeLaunchRequest] = []

    func record(_ request: DelegationClaudeLaunchRequest) {
        requests.append(request)
    }

    func snapshot() -> [DelegationClaudeLaunchRequest] {
        requests
    }
}
