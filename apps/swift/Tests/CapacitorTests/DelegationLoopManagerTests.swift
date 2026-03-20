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

    func testStartDelegationDedupesRepeatedStreamSessionIDAttaches() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let mutationRecorder = MutationRecorder()
        let manager = DelegationLoopManager(
            mutateDelegation: { request in
                await mutationRecorder.record(request)
            },
            worktreeService: makeWorktreeService(),
            sessionDiscovery: DelegationSessionDiscovery(
                fileManager: .default,
                claudeProjectsDirectory: tempDir,
            ),
            claudeLauncher: { _, onSessionID in
                try await onSessionID("session-200")
                try await onSessionID("session-200")
            },
        )

        try await manager.startDelegation(
            project: makeProject(path: tempDir.path),
            idea: makeIdea(id: "idea-1"),
        )

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["start", "attach_session"])
        XCTAssertEqual(requests.last?.sessionId, "session-200")
    }

    func testReconcileSkipsAttachWhenDiscoveredSessionMatchesRuntimeSnapshot() async throws {
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
                sessionId: "session-200",
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
        XCTAssertTrue(requests.isEmpty)
    }

    func testReconcileAttachesChangedSessionEvenWhenRuntimeSnapshotAlreadyHasSession() async throws {
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
                sessionId: "session-100",
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

    func testDelegationFailureMappingReturnsExpectedUserFacingCopy() {
        let sampleError = SampleError()

        XCTAssertEqual(
            DelegationUserFacingMessage.startFailure(
                for: DelegationLoopError.startupPreparation(underlying: sampleError),
            ),
            "Couldn't prepare the delegation worktree. Try delegating again.",
        )
        XCTAssertEqual(
            DelegationUserFacingMessage.startFailure(
                for: DelegationLoopError.workerLaunch(underlying: sampleError),
            ),
            "Couldn't launch the Claude worker. Try delegating again.",
        )
        XCTAssertEqual(
            DelegationUserFacingMessage.reviewFailure(
                for: DelegationLoopError.missingReviewSession,
            ),
            "Couldn't continue the review because the worker session is missing. Retry once the worker reconnects.",
        )
        XCTAssertEqual(
            DelegationUserFacingMessage.reviewFailure(
                for: DelegationLoopError.reviewResume(underlying: sampleError),
            ),
            "Couldn't resume the worker. The review stayed pending, your decision wasn't lost, and you can retry.",
        )
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

    // MARK: - Milestone Scanning and Review Iteration Tests

    func testReconcileDetectsFirstMilestoneWithSentinel() async throws {
        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
        }

        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: nil,
                status: "working",
                currentReview: nil,
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["review_ready"])
        XCTAssertEqual(requests.first?.milestoneId, "01")
    }

    func testReconcileSkipsMilestoneWithoutSentinel() async throws {
        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
        }

        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withSentinel: false,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: nil,
                status: "working",
                currentReview: nil,
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertTrue(
            requests.isEmpty,
            "Should not fire review_ready without sentinel file",
        )
    }

    func testReconcileSkipsMilestoneWithInvalidManifest() async throws {
        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
        }

        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withValidManifest: false,
            withSentinel: true,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: nil,
                status: "working",
                currentReview: nil,
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertTrue(
            requests.isEmpty,
            "Should not fire review_ready with invalid manifest JSON",
        )
    }

    func testReconcileDetectsSecondMilestoneAfterFirstDecided() async throws {
        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
        }

        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withDecision: true,
            withSentinel: true,
        )
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "02",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: nil,
                status: "working",
                currentReview: nil,
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["review_ready"])
        XCTAssertEqual(requests.first?.milestoneId, "02")
    }

    func testReconcileReturnsNothingWhenAllMilestonesDecided() async throws {
        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
        }

        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withDecision: true,
            withSentinel: true,
        )
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "02",
            withBrief: true,
            withManifest: true,
            withDecision: true,
            withSentinel: true,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: nil,
                status: "working",
                currentReview: nil,
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertTrue(
            requests.isEmpty,
            "Should not fire review_ready when all milestones are decided",
        )
    }

    func testReconcileIgnoresNonNumericMilestoneDirectories() async throws {
        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
        }

        // Create non-numeric directories that should be ignored
        try FileManager.default.createDirectory(
            at: milestonesRoot.appendingPathComponent("temp", isDirectory: true),
            withIntermediateDirectories: true,
        )
        // Create the real milestone
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: nil,
                status: "working",
                currentReview: nil,
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["review_ready"])
        XCTAssertEqual(requests.first?.milestoneId, "01")
    }

    func testResumePromptForApproveMentionsCompletionMarker() async throws {
        let tempDir = try makeClaudeProjectsDirectoryWithSession(
            workingDirectoryName: "-Users-petepetrash-Code-capacitor--capacitor-worktrees-delegation-54da230f",
            sessionID: "session-200",
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
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
            claudeLauncher: { _, _ in },
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
                    requestedAt: "2026-03-19T00:00:00Z",
                ),
            ),
            decision: .approve,
            note: "Ship it",
        )

        let rootPaths = CapacitorProjectPaths.projectDataDirectory(for: projectPath)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent("worker-1", isDirectory: true)
        let promptPath = rootPaths.appendingPathComponent("resume-prompt.md")
        let promptContent = try String(contentsOf: promptPath, encoding: .utf8)

        XCTAssertTrue(promptContent.contains("completion"), "Approve prompt should mention completion")
        XCTAssertTrue(promptContent.contains("approve"), "Approve prompt should mention approve")
        XCTAssertFalse(
            promptContent.contains("milestones/02"),
            "Approve prompt should not reference next milestone",
        )
    }

    func testResumePromptForRequestChangesReferencesNextMilestone() async throws {
        let tempDir = try makeClaudeProjectsDirectoryWithSession(
            workingDirectoryName: "-Users-petepetrash-Code-capacitor--capacitor-worktrees-delegation-54da230f",
            sessionID: "session-200",
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
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
            claudeLauncher: { _, _ in },
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
                    requestedAt: "2026-03-19T00:00:00Z",
                ),
            ),
            decision: .requestChanges,
            note: "Fix error handling",
        )

        let rootPaths = CapacitorProjectPaths.projectDataDirectory(for: projectPath)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent("worker-1", isDirectory: true)
        let promptPath = rootPaths.appendingPathComponent("resume-prompt.md")
        let promptContent = try String(contentsOf: promptPath, encoding: .utf8)

        XCTAssertTrue(
            promptContent.contains("milestones/02") || promptContent.contains("milestone_id\": \"02"),
            "Request changes prompt should reference next milestone 02",
        )
        XCTAssertTrue(
            promptContent.contains(".review-ready"),
            "Request changes prompt should mention sentinel file",
        )
        XCTAssertFalse(
            promptContent.contains("completion"),
            "Request changes prompt should not mention completion marker",
        )
    }

    func testFullIterationCycle() async throws {
        let tempDir = try makeClaudeProjectsDirectoryWithSession(
            workingDirectoryName: "-Users-petepetrash-Code-capacitor--capacitor-worktrees-delegation-54da230f",
            sessionID: "session-200",
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
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
            claudeLauncher: { _, _ in },
        )

        // Step 1: Worker produces milestone 01
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

        // Step 2: Reconcile detects milestone 01
        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: "session-200",
                status: "working",
                currentReview: nil,
            ),
        ])

        var requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.last?.kind, "review_ready")
        XCTAssertEqual(requests.last?.milestoneId, "01")

        // Step 3: User requests changes on milestone 01
        try await manager.submitReviewDecision(
            project: makeProject(path: projectPath),
            delegation: makeDelegation(
                projectPath: projectPath,
                sessionId: "session-200",
                status: "review_needed",
                currentReview: RuntimeDelegationReview(
                    milestoneId: "01",
                    briefPath: milestonesRoot.appendingPathComponent("01/brief.md").path,
                    manifestPath: milestonesRoot.appendingPathComponent("01/manifest.json").path,
                    requestedAt: "2026-03-19T00:00:00Z",
                ),
            ),
            decision: .requestChanges,
            note: "Fix the error handling",
        )

        requests = await mutationRecorder.snapshot()
        XCTAssertTrue(requests.contains(where: { $0.kind == "resume" && $0.reviewDecision == "request_changes" }))

        // Step 4: Worker produces milestone 02
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "02",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

        // Step 5: Reconcile detects milestone 02
        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: "session-200",
                status: "working",
                currentReview: nil,
            ),
        ])

        requests = await mutationRecorder.snapshot()
        let reviewReadyRequests = requests.filter { $0.kind == "review_ready" }
        XCTAssertEqual(reviewReadyRequests.last?.milestoneId, "02")

        // Step 6: User approves milestone 02
        try await manager.submitReviewDecision(
            project: makeProject(path: projectPath),
            delegation: makeDelegation(
                projectPath: projectPath,
                sessionId: "session-200",
                status: "review_needed",
                currentReview: RuntimeDelegationReview(
                    milestoneId: "02",
                    briefPath: milestonesRoot.appendingPathComponent("02/brief.md").path,
                    manifestPath: milestonesRoot.appendingPathComponent("02/manifest.json").path,
                    requestedAt: "2026-03-19T00:00:01Z",
                ),
            ),
            decision: .approve,
            note: "Looks good",
        )

        requests = await mutationRecorder.snapshot()
        XCTAssertTrue(requests.contains(where: { $0.kind == "resume" && $0.reviewDecision == "approve" }))

        // Verify the approve prompt references completion, not a next milestone
        let rootPaths = CapacitorProjectPaths.projectDataDirectory(for: projectPath)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent("worker-1", isDirectory: true)
        let promptContent = try String(
            contentsOf: rootPaths.appendingPathComponent("resume-prompt.md"),
            encoding: .utf8,
        )
        XCTAssertTrue(promptContent.contains("completion"))
        XCTAssertFalse(promptContent.contains("milestones/03"))
    }

    func testResumeFailureRestoresReviewReadyAndCleansUpPendingDecision() async throws {
        let tempDir = try makeClaudeProjectsDirectoryWithSession(
            workingDirectoryName: "-Users-petepetrash-Code-capacitor--capacitor-worktrees-delegation-54da230f",
            sessionID: "session-200",
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
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
                throw SampleError()
            },
        )

        do {
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
                        requestedAt: "2026-03-19T00:00:00Z",
                    ),
                ),
                decision: .requestChanges,
                note: "Fix it",
            )
            XCTFail("Should have thrown")
        } catch {}

        // Verify review_ready was re-fired
        let requests = await mutationRecorder.snapshot()
        XCTAssertTrue(
            requests.contains(where: { $0.kind == "review_ready" && $0.milestoneId == "01" }),
            "Should restore review_ready after resume failure",
        )

        // Verify decision-pending.json was cleaned up
        let pendingPath = milestonesRoot
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("decision-pending.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pendingPath.path),
            "decision-pending.json should be deleted after resume failure",
        )

        // Verify decision.json does NOT exist (immutability preserved)
        let decisionPath = milestonesRoot
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("decision.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: decisionPath.path),
            "decision.json should not exist after resume failure (immutability preserved)",
        )
    }

    func testSuccessfulResumePromotesDecisionPendingToFinal() async throws {
        let tempDir = try makeClaudeProjectsDirectoryWithSession(
            workingDirectoryName: "-Users-petepetrash-Code-capacitor--capacitor-worktrees-delegation-54da230f",
            sessionID: "session-200",
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
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
            claudeLauncher: { _, _ in },
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
                    requestedAt: "2026-03-19T00:00:00Z",
                ),
            ),
            decision: .approve,
            note: "Ship it",
        )

        // Verify decision.json exists (promoted from pending)
        let decisionPath = milestonesRoot
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("decision.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: decisionPath.path),
            "decision.json should exist after successful resume",
        )

        // Verify decision-pending.json does NOT exist
        let pendingPath = milestonesRoot
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("decision-pending.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pendingPath.path),
            "decision-pending.json should be renamed to decision.json",
        )

        // Verify decision content
        let data = try Data(contentsOf: decisionPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["decision"] as? String, "approve")
    }

    // MARK: - Reconcile Race Condition Tests

    func testReconcileSkipsReviewReadyWhenPendingDecisionExists() async throws {
        let projectPath = "/tmp/projects/test-race"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath)
            )
        }

        // Milestone 01 has sentinel + manifest BUT also a pending decision
        // (simulates the window between submitReviewDecision writing pending
        // and the Claude launch completing)
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withPendingDecision: true,
            withSentinel: true,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: "session-200",
                status: "working",
                currentReview: nil,
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        let reviewReadyRequests = requests.filter { $0.kind == "review_ready" }
        XCTAssertTrue(
            reviewReadyRequests.isEmpty,
            "reconcile must not re-fire review_ready when decision-pending.json exists (race condition)",
        )
    }

    // MARK: - Milestone Fixture Helpers

    private func makeDelegationMilestonesRoot(
        projectPath: String,
        workerID: String = "worker-1",
    ) -> URL {
        CapacitorProjectPaths.projectDataDirectory(for: projectPath)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent(workerID, isDirectory: true)
            .appendingPathComponent("milestones", isDirectory: true)
    }

    private func createMilestoneFixture(
        at milestonesRoot: URL,
        milestoneID: String,
        withBrief: Bool = false,
        withManifest: Bool = false,
        withValidManifest: Bool = true,
        withDecision: Bool = false,
        withPendingDecision: Bool = false,
        withSentinel: Bool = false,
    ) throws {
        let dir = milestonesRoot.appendingPathComponent(milestoneID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if withBrief {
            try "Test brief for milestone \(milestoneID)".write(
                to: dir.appendingPathComponent("brief.md"),
                atomically: true,
                encoding: .utf8,
            )
        }
        if withManifest {
            let content = withValidManifest
                ? """
                {"version":1,"milestone_id":"\(milestoneID)","summary":"test","artifacts":[]}
                """
                : "not valid json {{"
            try content.write(
                to: dir.appendingPathComponent("manifest.json"),
                atomically: true,
                encoding: .utf8,
            )
        }
        if withDecision {
            try """
            {"version":1,"decision":"approve","submitted_at":"2026-03-19T00:00:00Z"}
            """.write(
                to: dir.appendingPathComponent("decision.json"),
                atomically: true,
                encoding: .utf8,
            )
        }
        if withPendingDecision {
            try """
            {"version":1,"decision":"request_changes","submitted_at":"2026-03-19T00:00:00Z"}
            """.write(
                to: dir.appendingPathComponent("decision-pending.json"),
                atomically: true,
                encoding: .utf8,
            )
        }
        if withSentinel {
            try Data().write(to: dir.appendingPathComponent(".review-ready"))
        }
    }

    private func makeReconcileManager(
        mutationRecorder: MutationRecorder,
    ) -> DelegationLoopManager {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return DelegationLoopManager(
            mutateDelegation: { request in
                await mutationRecorder.record(request)
            },
            sessionDiscovery: DelegationSessionDiscovery(
                fileManager: .default,
                claudeProjectsDirectory: emptyDir,
            ),
            claudeLauncher: { _, _ in
                XCTFail("reconcile should not launch Claude")
            },
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

    private func makeIdea(id: String) -> Idea {
        Idea(
            id: id,
            title: "Tight stabilization pass",
            description: "Reproduce the delegation attach dedupe bug",
            added: "2026-03-16T18:37:02Z",
            effort: "small",
            status: "open",
            triage: "validated",
            related: nil,
        )
    }

    private func makeWorktreeService() -> WorktreeService {
        WorktreeService(fileManager: .default) { arguments, cwd in
            if arguments.count >= 3,
               arguments[0] == "worktree",
               arguments[1] == "add"
            {
                let worktreePath = URL(fileURLWithPath: cwd)
                    .appendingPathComponent(arguments[2], isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: worktreePath,
                    withIntermediateDirectories: true,
                )
            }

            return WorktreeService.GitCommandResult(
                exitCode: 0,
                stdout: "",
                stderr: "",
            )
        }
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

private struct SampleError: LocalizedError {
    var errorDescription: String? {
        "sample failure"
    }
}
