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
        XCTAssertEqual(requests.map(\.kind), ["attach_session", "submit_review", "resume"])
        XCTAssertEqual(requests.first?.sessionId, "session-200")
        XCTAssertEqual(requests.last?.sessionId, "session-200")

        let launches = await launchRecorder.snapshot()
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.resumeSessionID, "session-200")
    }

    func testAcceptReviewDecisionReturnsBeforeLaunchingClaude() async throws {
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
        let gate = AsyncGate()
        let launchStarted = expectation(description: "background launch started")

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
                launchStarted.fulfill()
                await gate.wait()
            },
        )

        let accepted = try await manager.acceptReviewDecision(
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

        XCTAssertEqual(accepted.sessionId, "session-200")
        let launchCountAfterAccept = await launchRecorder.snapshot().count
        XCTAssertEqual(launchCountAfterAccept, 0)

        let requestsAfterAccept = await mutationRecorder.snapshot()
        XCTAssertEqual(requestsAfterAccept.map(\.kind), ["attach_session", "submit_review"])

        await manager.launchResumeInBackground(accepted)
        await fulfillment(of: [launchStarted], timeout: 1.0)

        let requestsBeforeFinish = await mutationRecorder.snapshot()
        XCTAssertEqual(
            requestsBeforeFinish.map(\.kind),
            ["attach_session", "submit_review"],
            "Background launch should not block acceptance by waiting for the resume to finish",
        )

        await gate.open()
        try await waitUntil {
            let requests = await mutationRecorder.snapshot()
            return requests.contains(where: { $0.kind == "resume" })
        }

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

    func testReconcileResumePendingSkipsSubmittedMilestoneAndDetectsNextValidCheckpoint() async throws {
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
            withPendingDecision: true,
            withSentinel: true,
        )
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "02",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "99",
            withBrief: true,
            withManifest: false,
            withSentinel: true,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: "session-200",
                status: "resume_pending",
                submittedMilestoneId: "01",
                currentReview: RuntimeDelegationReview(
                    milestoneId: "01",
                    briefPath: milestonesRoot.appendingPathComponent("01/brief.md").path,
                    manifestPath: milestonesRoot.appendingPathComponent("01/manifest.json").path,
                    requestedAt: "2026-03-19T00:00:00Z",
                ),
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["review_ready"])
        XCTAssertEqual(
            requests.first?.milestoneId,
            "02",
            "resume_pending should ignore the submitted milestone and quarantine invalid future milestones",
        )
    }

    func testReconcileResumePendingPrefersNewestValidMilestoneAboveSubmitted() async throws {
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
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "03",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: "session-200",
                status: "resume_pending",
                submittedMilestoneId: "01",
                currentReview: RuntimeDelegationReview(
                    milestoneId: "01",
                    briefPath: milestonesRoot.appendingPathComponent("01/brief.md").path,
                    manifestPath: milestonesRoot.appendingPathComponent("01/manifest.json").path,
                    requestedAt: "2026-03-19T00:00:00Z",
                ),
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        let reviewReadyRequests = requests.filter { $0.kind == "review_ready" }
        XCTAssertEqual(reviewReadyRequests.compactMap(\.milestoneId), ["03"])
    }

    func testReconcileHigherIncompleteMilestoneDoesNotMaskLowerValidMilestone() async throws {
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
        try FileManager.default.createDirectory(
            at: milestonesRoot.appendingPathComponent("02", isDirectory: true),
            withIntermediateDirectories: true,
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
        let reviewReadyRequests = requests.filter { $0.kind == "review_ready" }
        XCTAssertEqual(reviewReadyRequests.compactMap(\.milestoneId), ["01"])
    }

    func testReconcileResumePendingIgnoresSubmittedMilestoneUntilCompletionAppears() async throws {
        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let milestonesRoot = makeDelegationMilestonesRoot(projectPath: projectPath)
        let workerRoot = CapacitorProjectPaths.projectDataDirectory(for: projectPath)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent("worker-1", isDirectory: true)
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

        let delegation = makeDelegation(
            projectPath: projectPath,
            sessionId: "session-200",
            status: "resume_pending",
            submittedMilestoneId: "01",
            currentReview: RuntimeDelegationReview(
                milestoneId: "01",
                briefPath: milestonesRoot.appendingPathComponent("01/brief.md").path,
                manifestPath: milestonesRoot.appendingPathComponent("01/manifest.json").path,
                requestedAt: "2026-03-19T00:00:00Z",
            ),
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [delegation])

        var requests = await mutationRecorder.snapshot()
        XCTAssertTrue(
            requests.isEmpty,
            "resume_pending should not re-fire review_ready for the submitted milestone",
        )

        try #"{"version":1,"status":"completed"}"#.write(
            to: workerRoot.appendingPathComponent("completion.json"),
            atomically: true,
            encoding: .utf8,
        )

        await manager.reconcile(delegations: [delegation])

        requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["complete"])
    }

    func testReconcileResumePendingStillDetectsCompletion() async throws {
        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let workerRoot = CapacitorProjectPaths.projectDataDirectory(for: projectPath)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent("worker-1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
        }

        try FileManager.default.createDirectory(at: workerRoot, withIntermediateDirectories: true)
        try #"{"version":1,"status":"completed"}"#.write(
            to: workerRoot.appendingPathComponent("completion.json"),
            atomically: true,
            encoding: .utf8,
        )

        let mutationRecorder = MutationRecorder()
        let manager = makeReconcileManager(mutationRecorder: mutationRecorder)

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: "session-200",
                status: "resume_pending",
                submittedMilestoneId: "01",
                currentReview: RuntimeDelegationReview(
                    milestoneId: "01",
                    briefPath: "/tmp/brief.md",
                    manifestPath: "/tmp/manifest.json",
                    requestedAt: "2026-03-19T00:00:00Z",
                ),
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["complete"])
    }

    func testReconcileCompletionCleansUpDelegationResourcesEvenWhenCleanupFails() async throws {
        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let workerRoot = CapacitorProjectPaths.projectDataDirectory(for: projectPath)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent("worker-1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
        }

        try FileManager.default.createDirectory(at: workerRoot, withIntermediateDirectories: true)
        try #"{"version":1,"status":"completed"}"#.write(
            to: workerRoot.appendingPathComponent("completion.json"),
            atomically: true,
            encoding: .utf8,
        )

        let mutationRecorder = MutationRecorder()
        let tmuxSessionRecorder = StringRecorder()
        let gitCommandRecorder = GitCommandRecorder()
        let worktreeService = WorktreeService(fileManager: .default) { arguments, cwd in
            gitCommandRecorder.record(arguments: arguments, cwd: cwd)

            if arguments == ["worktree", "remove", "--force", ".capacitor/worktrees/delegation-54da230f"] {
                return WorktreeService.GitCommandResult(
                    exitCode: 1,
                    stdout: "",
                    stderr: "remove failed",
                )
            }

            return WorktreeService.GitCommandResult(
                exitCode: 0,
                stdout: "",
                stderr: "",
            )
        }
        let manager = DelegationLoopManager(
            mutateDelegation: { request in
                await mutationRecorder.record(request)
            },
            worktreeService: worktreeService,
            sessionDiscovery: DelegationSessionDiscovery(
                fileManager: .default,
                claudeProjectsDirectory: FileManager.default.temporaryDirectory,
            ),
            claudeLauncher: { _, _ in
                XCTFail("reconcile should not launch Claude")
            },
            tmuxSessionKiller: { sessionName in
                await tmuxSessionRecorder.record(sessionName)
                return false
            },
        )

        await manager.reconcile(delegations: [
            makeDelegation(
                projectPath: projectPath,
                sessionId: "session-200",
                status: "working",
                currentReview: nil,
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["complete"])
        let tmuxSessions = await tmuxSessionRecorder.snapshot()
        XCTAssertEqual(tmuxSessions, ["delegation-54da230f"])

        let gitCommands = gitCommandRecorder.snapshot()
        XCTAssertTrue(
            gitCommands.contains(where: {
                $0.cwd == projectPath &&
                    $0.arguments == ["worktree", "remove", "--force", ".capacitor/worktrees/delegation-54da230f"]
            }),
            "Completion cleanup should force-remove the delegation worktree",
        )
        XCTAssertTrue(
            gitCommands.contains(where: {
                $0.cwd == projectPath &&
                    $0.arguments == ["branch", "-D", "pkp/delegation-54da230f"]
            }),
            "Branch deletion should still run even when worktree cleanup fails",
        )
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
        XCTAssertTrue(requests.contains(where: { $0.kind == "submit_review" && $0.reviewDecision == "request_changes" }))
        XCTAssertTrue(requests.contains(where: { $0.kind == "resume" }))

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
        XCTAssertTrue(requests.contains(where: { $0.kind == "submit_review" && $0.reviewDecision == "approve" }))
        XCTAssertTrue(requests.contains(where: { $0.kind == "resume" }))

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

    func testResumeFailureRestoresReviewReadyAndCleansUpDecisionResidue() async throws {
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
            requests.contains(where: { $0.kind == "resume_failed" }),
            "Should mark the delegation as resume_failed before restoring review",
        )
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

        let decisionMarkdownPath = milestonesRoot
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("decision.md")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: decisionMarkdownPath.path),
            "decision.md should be deleted after resume failure",
        )
    }

    func testLaunchResumeInBackgroundFailurePreservesReviewContextAndCleansArtifacts() async throws {
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

        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

        let initialDelegation = makeDelegation(
            projectPath: projectPath,
            sessionId: nil,
            status: "review_needed",
            currentReview: RuntimeDelegationReview(
                milestoneId: "01",
                briefPath: milestonesRoot.appendingPathComponent("01/brief.md").path,
                manifestPath: milestonesRoot.appendingPathComponent("01/manifest.json").path,
                requestedAt: "2026-03-19T00:00:00Z",
            ),
        )
        let mutationProjector = MutationProjector(initialDelegation: initialDelegation)
        let manager = DelegationLoopManager(
            mutateDelegation: { request in
                await mutationProjector.record(request)
            },
            sessionDiscovery: DelegationSessionDiscovery(
                fileManager: .default,
                claudeProjectsDirectory: tempDir,
            ),
            claudeLauncher: { _, _ in
                throw SampleError()
            },
        )

        let accepted = try await manager.acceptReviewDecision(
            project: makeProject(path: projectPath),
            delegation: initialDelegation,
            decision: .requestChanges,
            note: "Fix it",
        )

        await manager.launchResumeInBackground(accepted)

        try await waitUntil {
            let requests = await mutationProjector.snapshot()
            return requests.contains(where: { $0.kind == "review_ready" })
        }

        let requests = await mutationProjector.snapshot()
        XCTAssertTrue(requests.contains(where: { $0.kind == "submit_review" }))
        XCTAssertTrue(requests.contains(where: { $0.kind == "resume_failed" }))
        XCTAssertFalse(requests.contains(where: { $0.kind == "resume" }))

        let projection = await mutationProjector.projectionSnapshot()
        XCTAssertEqual(projection.currentReview?.milestoneId, "01")

        let pendingPath = milestonesRoot
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("decision-pending.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pendingPath.path),
            "decision-pending.json should be deleted after background resume failure",
        )

        let decisionMarkdownPath = milestonesRoot
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("decision.md")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: decisionMarkdownPath.path),
            "decision.md should be deleted after background resume failure",
        )
    }

    func testLaunchResumeInBackgroundFailurePrefersNewerCheckpointOverRestoringOldReview() async throws {
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

        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )
        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "02",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

        let initialDelegation = makeDelegation(
            projectPath: projectPath,
            sessionId: "session-200",
            status: "review_needed",
            currentReview: RuntimeDelegationReview(
                milestoneId: "01",
                briefPath: milestonesRoot.appendingPathComponent("01/brief.md").path,
                manifestPath: milestonesRoot.appendingPathComponent("01/manifest.json").path,
                requestedAt: "2026-03-19T00:00:00Z",
            ),
        )
        let mutationProjector = MutationProjector(initialDelegation: initialDelegation)
        let manager = DelegationLoopManager(
            mutateDelegation: { request in
                await mutationProjector.record(request)
            },
            sessionDiscovery: DelegationSessionDiscovery(
                fileManager: .default,
                claudeProjectsDirectory: tempDir,
            ),
            claudeLauncher: { _, _ in
                throw SampleError()
            },
        )

        let accepted = try await manager.acceptReviewDecision(
            project: makeProject(path: projectPath),
            delegation: initialDelegation,
            decision: .requestChanges,
            note: "Fix it",
        )

        await manager.launchResumeInBackground(accepted)

        try await waitUntil {
            let requests = await mutationProjector.snapshot()
            return requests.contains(where: { $0.kind == "review_ready" && $0.milestoneId == "02" })
        }

        let requests = await mutationProjector.snapshot()
        let reviewReadyRequests = requests.filter { $0.kind == "review_ready" }
        XCTAssertEqual(reviewReadyRequests.last?.milestoneId, "02")
        XCTAssertFalse(reviewReadyRequests.contains(where: { $0.milestoneId == "01" }))

        let projection = await mutationProjector.projectionSnapshot()
        XCTAssertEqual(projection.status, "review_needed")
        XCTAssertEqual(projection.currentReview?.milestoneId, "02")
    }

    func testLaunchResumeRetryReusesAcceptedDecisionWithoutSecondSubmission() async throws {
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

        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "01",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

        let initialDelegation = makeDelegation(
            projectPath: projectPath,
            sessionId: "session-200",
            status: "review_needed",
            currentReview: RuntimeDelegationReview(
                milestoneId: "01",
                briefPath: milestonesRoot.appendingPathComponent("01/brief.md").path,
                manifestPath: milestonesRoot.appendingPathComponent("01/manifest.json").path,
                requestedAt: "2026-03-19T00:00:00Z",
            ),
        )
        let mutationProjector = MutationProjector(initialDelegation: initialDelegation)
        let scriptedLauncher = ScriptedLauncher(failuresRemaining: 1)
        let manager = DelegationLoopManager(
            mutateDelegation: { request in
                await mutationProjector.record(request)
            },
            sessionDiscovery: DelegationSessionDiscovery(
                fileManager: .default,
                claudeProjectsDirectory: tempDir,
            ),
            claudeLauncher: { request, _ in
                try await scriptedLauncher.launch(request)
            },
        )

        let accepted = try await manager.acceptReviewDecision(
            project: makeProject(path: projectPath),
            delegation: initialDelegation,
            decision: .requestChanges,
            note: "Tighten retry handling",
        )

        await manager.launchResumeInBackground(accepted)

        try await waitUntil {
            let requests = await mutationProjector.snapshot()
            return requests.contains(where: { $0.kind == "resume_failed" })
        }

        await manager.launchResumeInBackground(accepted)

        try await waitUntil {
            let requests = await mutationProjector.snapshot()
            return requests.contains(where: { $0.kind == "resume" })
        }

        let requests = await mutationProjector.snapshot()
        XCTAssertEqual(
            requests.count(where: { $0.kind == "submit_review" }),
            1,
            "Retry should reuse the accepted review instead of requiring a second submission",
        )

        let launches = await scriptedLauncher.snapshot()
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(accepted.decision, .requestChanges)
        XCTAssertEqual(accepted.note, "Tighten retry handling")
        XCTAssertTrue(launches.last?.prompt.contains("Tighten retry handling") == true)

        let projection = await mutationProjector.projectionSnapshot()
        XCTAssertEqual(projection.status, "working")
        XCTAssertNil(projection.currentReview)

        let decisionPath = milestonesRoot
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("decision.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: decisionPath.path),
            "Retry should still promote the originally accepted decision after a later success",
        )

        let pendingPath = milestonesRoot
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("decision-pending.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pendingPath.path),
            "Retry should not leave decision-pending.json behind after succeeding",
        )
    }

    func testResumeFailurePrefersNewerCheckpointOverRestoringOldReview() async throws {
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

        try createMilestoneFixture(
            at: milestonesRoot,
            milestoneID: "02",
            withBrief: true,
            withManifest: true,
            withSentinel: true,
        )

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
                    sessionId: "session-200",
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

        let requests = await mutationRecorder.snapshot()
        let reviewReadyRequests = requests.filter { $0.kind == "review_ready" }
        XCTAssertEqual(reviewReadyRequests.last?.milestoneId, "02")
        XCTAssertFalse(
            reviewReadyRequests.contains(where: { $0.milestoneId == "01" }),
            "Failure recovery should prefer the newer valid checkpoint over restoring the submitted milestone",
        )
    }

    func testResumeFailurePrefersCompletionOverRestoringReview() async throws {
        let tempDir = try makeClaudeProjectsDirectoryWithSession(
            workingDirectoryName: "-Users-petepetrash-Code-capacitor--capacitor-worktrees-delegation-54da230f",
            sessionID: "session-200",
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let projectPath = "/tmp/projects/test-\(UUID().uuidString)"
        let workerRoot = CapacitorProjectPaths.projectDataDirectory(for: projectPath)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent("worker-1", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
            )
        }

        try FileManager.default.createDirectory(at: workerRoot, withIntermediateDirectories: true)
        try #"{"version":1,"status":"completed"}"#.write(
            to: workerRoot.appendingPathComponent("completion.json"),
            atomically: true,
            encoding: .utf8,
        )

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
                    sessionId: "session-200",
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
            XCTFail("Should have thrown")
        } catch {}

        let requests = await mutationRecorder.snapshot()
        XCTAssertTrue(requests.contains(where: { $0.kind == "complete" }))
        XCTAssertFalse(
            requests.contains(where: { $0.kind == "review_ready" }),
            "Failure recovery should prefer completion over restoring review_needed",
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
                at: CapacitorProjectPaths.projectDataDirectory(for: projectPath),
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
        submittedMilestoneId: String? = nil,
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
            submittedMilestoneId: submittedMilestoneId,
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

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollNanoseconds: UInt64 = 20_000_000,
        condition: @escaping () async -> Bool,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await _Concurrency.Task.sleep(nanoseconds: pollNanoseconds)
        }
        XCTFail("Timed out waiting for async condition")
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

private actor StringRecorder {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private struct GitCommandInvocation: Equatable {
    let arguments: [String]
    let cwd: String
}

private final class GitCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [GitCommandInvocation] = []

    func record(arguments: [String], cwd: String) {
        lock.lock()
        invocations.append(GitCommandInvocation(arguments: arguments, cwd: cwd))
        lock.unlock()
    }

    func snapshot() -> [GitCommandInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

private struct DelegationProjection {
    var sessionId: String?
    var status: String
    var submittedMilestoneId: String?
    var currentReview: RuntimeDelegationReview?
}

private actor MutationProjector {
    private var requests: [RuntimeDelegationMutationRequest] = []
    private var projection: DelegationProjection

    init(initialDelegation: RuntimeDelegationState) {
        projection = DelegationProjection(
            sessionId: initialDelegation.sessionId,
            status: initialDelegation.status,
            submittedMilestoneId: initialDelegation.submittedMilestoneId,
            currentReview: initialDelegation.currentReview,
        )
    }

    func record(_ request: RuntimeDelegationMutationRequest) {
        requests.append(request)
        apply(request)
    }

    func snapshot() -> [RuntimeDelegationMutationRequest] {
        requests
    }

    func projectionSnapshot() -> DelegationProjection {
        projection
    }

    private func apply(_ request: RuntimeDelegationMutationRequest) {
        switch request.kind {
        case "attach_session":
            projection.sessionId = request.sessionId ?? projection.sessionId

        case "submit_review":
            projection.sessionId = request.sessionId ?? projection.sessionId
            projection.status = "resume_pending"
            projection.submittedMilestoneId = request.milestoneId ?? projection.submittedMilestoneId

        case "resume_failed":
            projection.sessionId = request.sessionId ?? projection.sessionId
            projection.status = "resume_failed"
            projection.submittedMilestoneId = request.milestoneId ?? projection.submittedMilestoneId
            projection.currentReview = review(from: request) ?? projection.currentReview

        case "review_ready":
            projection.sessionId = request.sessionId ?? projection.sessionId
            projection.status = "review_needed"
            projection.currentReview = review(from: request) ?? projection.currentReview

        case "resume":
            projection.sessionId = request.sessionId ?? projection.sessionId
            projection.status = "working"
            projection.currentReview = nil

        case "complete":
            projection.sessionId = request.sessionId ?? projection.sessionId
            projection.status = "complete"
            projection.currentReview = nil

        default:
            break
        }
    }

    private func review(from request: RuntimeDelegationMutationRequest) -> RuntimeDelegationReview? {
        guard let milestoneId = request.milestoneId,
              let briefPath = request.briefPath,
              let manifestPath = request.manifestPath
        else {
            return nil
        }

        return RuntimeDelegationReview(
            milestoneId: milestoneId,
            briefPath: briefPath,
            manifestPath: manifestPath,
            requestedAt: "2026-03-19T00:00:00Z",
        )
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

private actor ScriptedLauncher {
    private var failuresRemaining: Int
    private var requests: [DelegationClaudeLaunchRequest] = []

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func launch(_ request: DelegationClaudeLaunchRequest) throws {
        requests.append(request)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw SampleError()
        }
    }

    func snapshot() -> [DelegationClaudeLaunchRequest] {
        requests
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct SampleError: LocalizedError {
    var errorDescription: String? {
        "sample failure"
    }
}
