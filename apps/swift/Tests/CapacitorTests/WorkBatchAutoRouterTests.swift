@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class WorkBatchAutoRouterTests: XCTestCase {
    func testRoutesNewTaskToNewBatchAndStartsClaudeSession() async throws {
        let harness = try RouterHarness()
        let terminalRecorder = TerminalScriptRecorder()
        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.worktreeService(expectedName: "batch-mobile-prototype-idea-1"),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { "assigned-session-1" },
            runTerminalScript: { script in
                await terminalRecorder.record(script)
            },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            classifier: { request in
                .new(
                    taskID: request.task.id,
                    batchName: "Mobile prototype",
                    confidence: 0.9,
                    rationale: "First mobile prototype task.",
                    summary: "Started Mobile prototype.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-1", title: "Add green border around the mobile prototype"),
            now: harness.now,
        )

        XCTAssertTrue(result.startedNewSession)
        XCTAssertEqual(result.batch.name, "Mobile prototype")
        XCTAssertEqual(result.batch.status, .working)
        XCTAssertEqual(result.task.status, .working)
        XCTAssertEqual(result.binding?.claudeSessionID, "assigned-session-1")

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.count, 1)
        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(state.classifications.count, 1)
        XCTAssertEqual(state.batches[0].cockpitBindingID, state.batches[0].id)

        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--session-id"))
        XCTAssertTrue(scripts[0].contains("assigned-session-1"))
    }

    func testPlaceholderIdeaTitleFallsBackToDescriptionBeforeSensemakingCompletes() async throws {
        let harness = try RouterHarness()
        let terminalRecorder = TerminalScriptRecorder()
        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.acceptingWorktreeService(),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { "assigned-session-1" },
            runTerminalScript: { script in
                await terminalRecorder.record(script)
            },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            classifier: { request in
                XCTAssertEqual(request.task.title, "add a green border around the mobile prototype")
                return .new(
                    taskID: request.task.id,
                    batchName: "Mobile prototype",
                    confidence: 0.9,
                    rationale: "Uses description while title generation is pending.",
                    summary: "Started Mobile prototype.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(
                id: "idea-placeholder",
                title: "...",
                description: "add a green border around the mobile prototype",
            ),
            now: harness.now,
        )

        XCTAssertEqual(result.task.title, "add a green border around the mobile prototype")
        XCTAssertEqual(
            result.batch.currentActivitySummary,
            "Claude Code is starting on add a green border around the mobile prototype.",
        )
    }

    func testRoutesRelatedTaskToExistingBatchAndUpdatesContextWithoutStartingNewSession() async throws {
        let harness = try RouterHarness()
        let existingBatch = WorkBatchRecord(
            id: "batch-mobile",
            name: "Mobile prototype",
            projectPath: harness.project.path,
            status: .working,
            currentActivitySummary: "Tweaking prototype styling.",
            taskIDs: ["idea-old"],
            cockpitBindingID: "batch-mobile",
            createdAt: harness.now,
            updatedAt: harness.now,
        )
        let existingTask = WorkBatchTaskRecord(
            id: "idea-old",
            sourceIdeaID: "idea-old",
            title: "Adjust mobile spacing",
            body: "",
            status: .working,
            batchID: "batch-mobile",
            createdAt: harness.now,
            updatedAt: harness.now,
        )
        try harness.stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [existingBatch],
            tasks: [existingTask],
            classifications: [],
        ))

        let worktreeURL = harness.projectRoot
            .appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
        try harness.fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: harness.project.path,
            worktreeName: "batch-mobile",
            worktreePath: worktreeURL.path,
            host: .claudeCode,
            claudeSessionID: "assigned-session-existing",
            status: .running,
            createdAt: harness.now,
            updatedAt: harness.now,
        )
        try harness.bindingStore.upsert(binding)

        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.worktreeService(expectedName: "should-not-launch"),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { _ in
                XCTFail("existing binding should reuse the batch cockpit, not start a new session")
            },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            classifier: { request in
                .existing(
                    taskID: request.task.id,
                    batchID: "batch-mobile",
                    confidence: 0.88,
                    rationale: "Same mobile prototype area.",
                    summary: "Added to Mobile prototype.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now,
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.claudeSessionID, "assigned-session-existing")

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches[0].taskIDs, ["idea-old", "idea-green"])
        XCTAssertEqual(state.batches[0].currentActivitySummary, "Queued Add green border around the mobile prototype in Mobile prototype.")
        XCTAssertEqual(state.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(state.tasks.map(\.id).sorted(), ["idea-green", "idea-old"])

        let mirror = try String(
            contentsOf: worktreeURL.appendingPathComponent(WorkBatchContextMirror.relativePath),
            encoding: .utf8,
        )
        XCTAssertTrue(mirror.contains("Adjust mobile spacing"))
        XCTAssertTrue(mirror.contains("Add green border around the mobile prototype"))
    }

    func testLowConfidenceNewTypographyClassificationIsKeptInExistingActiveBatch() async throws {
        let harness = try RouterHarness()
        let existingBatch = WorkBatchRecord(
            id: "batch-typography",
            name: "Typography scale adjustment",
            projectPath: harness.project.path,
            status: .working,
            currentActivitySummary: "Claude Code is starting on make all type a bit larger.",
            taskIDs: ["idea-type-scale"],
            cockpitBindingID: "batch-typography",
            createdAt: harness.now,
            updatedAt: harness.now,
        )
        let existingTask = WorkBatchTaskRecord(
            id: "idea-type-scale",
            sourceIdeaID: "idea-type-scale",
            title: "make all type a bit larger",
            body: "make all type a bit larger",
            status: .working,
            batchID: "batch-typography",
            createdAt: harness.now,
            updatedAt: harness.now,
        )
        try harness.stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [existingBatch],
            tasks: [existingTask],
            classifications: [],
        ))

        let worktreeURL = harness.projectRoot
            .appendingPathComponent(".capacitor/worktrees/batch-typography", isDirectory: true)
        try harness.fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        try harness.bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-typography",
            batchID: "batch-typography",
            batchName: "Typography scale adjustment",
            projectPath: harness.project.path,
            worktreeName: "batch-typography",
            worktreePath: worktreeURL.path,
            host: .claudeCode,
            claudeSessionID: "assigned-session-typography",
            status: .running,
            createdAt: harness.now,
            updatedAt: harness.now,
        ))

        let router = WorkBatchAutoRouter(
            classifier: { request in
                .new(
                    taskID: request.task.id,
                    batchName: "Typeface unification from source parable",
                    confidence: 0.78,
                    rationale: "Font selection is distinct from typography sizing.",
                    summary: "Apply the source parable font elsewhere.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: WorkBatchTaskSessionCoordinator(
                worktreeService: harness.worktreeService(expectedName: "should-not-launch"),
                fileManager: harness.fileManager,
                claudePathResolver: { "/opt/homebrew/bin/claude" },
                runTerminalScript: { _ in
                    XCTFail("related typography work should reuse the existing Work Batch cockpit")
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
        )

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(
                id: "idea-font",
                title: "use the font that was being used on the story about the pot of milk",
            ),
            now: harness.now.addingTimeInterval(60),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.batch.id, "batch-typography")
        XCTAssertEqual(result.binding?.claudeSessionID, "assigned-session-typography")
        XCTAssertEqual(result.classification.targetKind, .existing)
        XCTAssertEqual(result.classification.batchID, "batch-typography")
        XCTAssertTrue(result.classification.rationale.contains("low-confidence new-batch classification"))

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.count, 1)
        XCTAssertEqual(state.batches[0].taskIDs, ["idea-type-scale", "idea-font"])
        XCTAssertEqual(state.tasks.first(where: { $0.id == "idea-font" })?.status, .queued)

        let mirror = try String(
            contentsOf: worktreeURL.appendingPathComponent(WorkBatchContextMirror.relativePath),
            encoding: .utf8,
        )
        XCTAssertTrue(mirror.contains("make all type a bit larger"))
        XCTAssertTrue(mirror.contains("use the font that was being used on the story about the pot of milk"))
    }

    func testHighConfidenceUnrelatedNewClassificationStillStartsSeparateBatch() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        let terminalRecorder = TerminalScriptRecorder()
        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.acceptingWorktreeService(),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { "assigned-session-checkout" },
            runTerminalScript: { script in
                await terminalRecorder.record(script)
            },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            classifier: { request in
                .new(
                    taskID: request.task.id,
                    batchName: "Checkout flow",
                    confidence: 0.95,
                    rationale: "Unrelated payment work.",
                    summary: "Start checkout flow.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-checkout", title: "Add Stripe checkout flow"),
            now: harness.now.addingTimeInterval(60),
        )

        XCTAssertTrue(result.startedNewSession)
        XCTAssertEqual(result.batch.name, "Checkout flow")
        XCTAssertEqual(result.classification.targetKind, .new)
        XCTAssertEqual(result.binding?.claudeSessionID, "assigned-session-checkout")
        XCTAssertEqual(try harness.stateStore.load().batches.count, 2)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
    }

    func testClassifierFailureFallsBackToVisibleNewBatchAndStillStartsSession() async throws {
        let harness = try RouterHarness()
        let terminalRecorder = TerminalScriptRecorder()
        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.acceptingWorktreeService(),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { "assigned-session-fallback" },
            runTerminalScript: { script in
                await terminalRecorder.record(script)
            },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "classifier", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-1", title: "Add green border around the mobile prototype"),
            now: harness.now,
        )

        XCTAssertTrue(result.startedNewSession)
        XCTAssertEqual(result.batch.name, "Add green border around the mobile prototype")
        XCTAssertEqual(result.classification.confidence, 0)
        XCTAssertTrue(result.classification.rationale.contains("Fallback after Work Batch classification failed"))
        XCTAssertEqual(result.binding?.claudeSessionID, "assigned-session-fallback")

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.count, 1)
        XCTAssertEqual(state.tasks.first?.status, .working)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
    }

    func testExistingBindingContextMirrorFailureLeavesBatchWaiting() async throws {
        let harness = try RouterHarness()
        let existingBatch = WorkBatchRecord(
            id: "batch-mobile",
            name: "Mobile prototype",
            projectPath: harness.project.path,
            status: .working,
            currentActivitySummary: "Tweaking prototype styling.",
            taskIDs: ["idea-old"],
            cockpitBindingID: "batch-mobile",
            createdAt: harness.now,
            updatedAt: harness.now,
        )
        let existingTask = WorkBatchTaskRecord(
            id: "idea-old",
            sourceIdeaID: "idea-old",
            title: "Adjust mobile spacing",
            body: "",
            status: .working,
            batchID: "batch-mobile",
            createdAt: harness.now,
            updatedAt: harness.now,
        )
        try harness.stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [existingBatch],
            tasks: [existingTask],
            classifications: [],
        ))

        let fileURL = harness.tempDir.appendingPathComponent("not-a-worktree")
        try "file".write(to: fileURL, atomically: true, encoding: .utf8)
        try harness.bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: harness.project.path,
            worktreeName: "batch-mobile",
            worktreePath: fileURL.path,
            host: .claudeCode,
            claudeSessionID: "assigned-session-existing",
            status: .running,
            createdAt: harness.now,
            updatedAt: harness.now,
        ))

        let router = WorkBatchAutoRouter(
            classifier: { request in
                .existing(
                    taskID: request.task.id,
                    batchID: "batch-mobile",
                    confidence: 0.88,
                    rationale: "Same mobile prototype area.",
                    summary: "Added to Mobile prototype.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: WorkBatchTaskSessionCoordinator(
                worktreeService: harness.worktreeService(expectedName: "should-not-launch"),
                fileManager: harness.fileManager,
                claudePathResolver: { "/opt/homebrew/bin/claude" },
                runTerminalScript: { _ in
                    XCTFail("running binding should not launch while mirror write is failing")
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
        )

        do {
            _ = try await router.routeCapturedTask(
                project: harness.project,
                idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
                now: harness.now,
            )
            XCTFail("Expected context mirror write to fail")
        } catch {
            let state = try harness.stateStore.load()
            XCTAssertEqual(state.batches.first?.status, .waiting)
            XCTAssertEqual(state.batches.first?.currentActivitySummary, "Claude Code launch needs attention.")
            XCTAssertEqual(state.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        }
    }

    func testRoutesRelatedTaskToStaleExistingBatchAndResumesCockpit() async throws {
        let harness = try RouterHarness()
        try harness.stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: harness.project.path,
                    status: .waiting,
                    currentActivitySummary: "Claude Code launch needs attention.",
                    taskIDs: ["idea-old"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "idea-old",
                    sourceIdeaID: "idea-old",
                    title: "Adjust mobile spacing",
                    body: "",
                    status: .queued,
                    batchID: "batch-mobile",
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            classifications: [],
        ))

        let worktreeURL = harness.projectRoot
            .appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
        try harness.fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        try harness.bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: harness.project.path,
            worktreeName: "batch-mobile",
            worktreePath: worktreeURL.path,
            host: .claudeCode,
            claudeSessionID: "assigned-session-existing",
            status: .stale,
            createdAt: harness.now,
            updatedAt: harness.now,
        ))

        let terminalRecorder = TerminalScriptRecorder()
        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.worktreeService(expectedName: "should-not-launch"),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { script in
                await terminalRecorder.record(script)
            },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            classifier: { request in
                .existing(
                    taskID: request.task.id,
                    batchID: "batch-mobile",
                    confidence: 0.88,
                    rationale: "Same mobile prototype area.",
                    summary: "Added to Mobile prototype.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now,
        )

        XCTAssertFalse(result.startedNewSession)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--resume"))
        XCTAssertTrue(scripts[0].contains("assigned-session-existing"))
        XCTAssertEqual(result.binding?.status, .launching)
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .launching)
        XCTAssertEqual(
            try harness.stateStore.load().batches[0].currentActivitySummary,
            "Claude Code is reconnecting to Add green border around the mobile prototype.",
        )
    }

    func testFailedNewSessionLaunchLeavesBatchWaitingNotWorking() async throws {
        let harness = try RouterHarness()
        struct LaunchError: Error {}
        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.worktreeService(expectedName: "batch-mobile-prototype-idea-1"),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { _ in throw LaunchError() },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            classifier: { request in
                .new(
                    taskID: request.task.id,
                    batchName: "Mobile prototype",
                    confidence: 0.9,
                    rationale: "First mobile prototype task.",
                    summary: "Started Mobile prototype.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        do {
            _ = try await router.routeCapturedTask(
                project: harness.project,
                idea: harness.idea(id: "idea-1", title: "Add green border around the mobile prototype"),
                now: harness.now,
            )
            XCTFail("Expected launch failure")
        } catch is LaunchError {
            // expected
        }

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.first?.status, .waiting)
        XCTAssertEqual(state.batches.first?.currentActivitySummary, "Claude Code launch needs attention.")
        XCTAssertEqual(state.tasks.first?.status, .queued)
        XCTAssertTrue(try harness.bindingStore.load().isEmpty)
    }

    func testConcurrentCapturedTasksDoNotOverwriteBatchState() async throws {
        let harness = try RouterHarness()
        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.acceptingWorktreeService(),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { UUID().uuidString.lowercased() },
            runTerminalScript: { _ in },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            classifier: { request in
                try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
                return .new(
                    taskID: request.task.id,
                    batchName: "Batch \(request.task.id)",
                    confidence: 0.8,
                    rationale: "Concurrent capture regression test.",
                    summary: "Started batch.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        async let first = router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-one", title: "First concurrent task"),
            now: harness.now,
        )
        async let second = router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-two", title: "Second concurrent task"),
            now: harness.now.addingTimeInterval(1),
        )

        _ = try await (first, second)

        let state = try harness.stateStore.load()
        XCTAssertEqual(Set(state.tasks.map(\.id)), ["idea-one", "idea-two"])
        XCTAssertEqual(state.batches.count, 2)
    }

    func testCompletionIngestDuringClassificationIsNotOverwrittenByRouteSave() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        _ = try WorkBatchCompletionReportStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchCompletionReport(
            taskID: "idea-old",
            status: "done",
            summary: "Adjusted spacing",
            evidence: ["Updated layout"],
            completedAt: harness.now.addingTimeInterval(5),
        ))
        let classifierGate = ClassifierGate()
        let terminalRecorder = TerminalScriptRecorder()
        let router = WorkBatchAutoRouter(
            classifier: { request in
                await classifierGate.markStarted()
                try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
                return .existing(
                    taskID: request.task.id,
                    batchID: "batch-mobile",
                    confidence: 0.88,
                    rationale: "Same mobile prototype area.",
                    summary: "Added to Mobile prototype.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: WorkBatchTaskSessionCoordinator(
                worktreeService: harness.worktreeService(expectedName: "should-not-launch"),
                fileManager: harness.fileManager,
                claudePathResolver: { "/opt/homebrew/bin/claude" },
                runTerminalScript: { script in
                    await terminalRecorder.record(script)
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
        )

        async let routed = router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(10),
        )
        await classifierGate.waitUntilStarted()
        _ = router.ingestCompletionReports(projects: [harness.project], now: harness.now.addingTimeInterval(5))
        _ = try await routed

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.tasks.first(where: { $0.id == "idea-old" })?.status, .done)
        XCTAssertEqual(state.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(state.tasks.map(\.id).sorted(), ["idea-green", "idea-old"])
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--resume"))
        XCTAssertTrue(scripts[0].contains("Read .capacitor/work-batch-context.md again"))
    }

    func testProjectionReadsStoredBatchesAndBindings() throws {
        let harness = try RouterHarness()
        try harness.stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: harness.project.path,
                    status: .working,
                    currentActivitySummary: "Adding green border.",
                    taskIDs: ["idea-green"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "idea-green",
                    sourceIdeaID: "idea-green",
                    title: "Add green border",
                    body: "",
                    status: .working,
                    batchID: "batch-mobile",
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            classifications: [],
        ))
        try harness.bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: harness.project.path,
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/worktree",
            host: .claudeCode,
            claudeSessionID: "session-1",
            status: .running,
            createdAt: harness.now,
            updatedAt: harness.now,
        ))

        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        let projections = router.projections(for: harness.project.path)

        XCTAssertEqual(projections.count, 1)
        XCTAssertEqual(projections[0].name, "Mobile prototype")
        XCTAssertEqual(projections[0].binding?.claudeSessionID, "session-1")
    }

    func testReroutingSameTaskRemovesOldBatchMembership() async throws {
        let harness = try RouterHarness()
        try harness.stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-footer",
                    name: "Footer Fix",
                    projectPath: harness.project.path,
                    status: .working,
                    currentActivitySummary: "Fixed footer responsive breakpoint bug",
                    taskIDs: ["idea-green"],
                    cockpitBindingID: nil,
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: harness.project.path,
                    status: .working,
                    currentActivitySummary: "Tweaking prototype styling.",
                    taskIDs: [],
                    cockpitBindingID: "batch-mobile",
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "idea-green",
                    sourceIdeaID: "idea-green",
                    title: "Add green border",
                    body: "",
                    status: .queued,
                    batchID: "batch-footer",
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            classifications: [],
        ))

        let worktreeURL = harness.projectRoot
            .appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
        try harness.fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        try harness.bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: harness.project.path,
            worktreeName: "batch-mobile",
            worktreePath: worktreeURL.path,
            host: .claudeCode,
            claudeSessionID: "assigned-session-existing",
            status: .running,
            createdAt: harness.now,
            updatedAt: harness.now,
        ))

        let router = WorkBatchAutoRouter(
            classifier: { request in
                .existing(
                    taskID: request.task.id,
                    batchID: "batch-mobile",
                    confidence: 0.88,
                    rationale: "Same mobile prototype area.",
                    summary: "Added to Mobile prototype.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: WorkBatchTaskSessionCoordinator(
                worktreeService: harness.worktreeService(expectedName: "should-not-launch"),
                fileManager: harness.fileManager,
                claudePathResolver: { "/opt/homebrew/bin/claude" },
                runTerminalScript: { _ in
                    XCTFail("running binding should not launch")
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
        )

        _ = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now,
        )

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.first(where: { $0.id == "batch-footer" })?.taskIDs, [])
        XCTAssertEqual(state.batches.first(where: { $0.id == "batch-mobile" })?.taskIDs, ["idea-green"])
        XCTAssertEqual(state.tasks.count(where: { $0.id == "idea-green" }), 1)
        XCTAssertEqual(state.tasks.first(where: { $0.id == "idea-green" })?.batchID, "batch-mobile")
    }

    func testRelatedTaskDoesNotResumeWhenDuplicateBatchCockpitExists() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        let terminalRecorder = TerminalScriptRecorder()
        let router = WorkBatchAutoRouter(
            classifier: { request in
                .existing(
                    taskID: request.task.id,
                    batchID: "batch-mobile",
                    confidence: 0.88,
                    rationale: "Same mobile prototype area.",
                    summary: "Added to Mobile prototype.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: WorkBatchTaskSessionCoordinator(
                worktreeService: harness.worktreeService(expectedName: "should-not-launch"),
                fileManager: harness.fileManager,
                claudePathResolver: { "/opt/homebrew/bin/claude" },
                runTerminalScript: { script in
                    await terminalRecorder.record(script)
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
        )
        router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.runtimeSession(sessionId: "assigned-session-existing", cwd: harness.mobileWorktreePath),
                harness.runtimeSession(sessionId: "manual-duplicate", cwd: "\(harness.mobileWorktreePath)/src"),
            ],
            now: harness.now,
        )

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now,
        )

        XCTAssertFalse(result.startedNewSession)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.first?.status, .waiting)
        XCTAssertEqual(state.batches.first?.currentActivitySummary, "Multiple Claude Code sessions match this Work Batch.")
        XCTAssertEqual(state.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
    }

    func testOpenCockpitThrowsWhenDuplicateBatchCockpitExists() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        let binding = try XCTUnwrap(harness.bindingStore.binding(batchID: "batch-mobile"))
        let terminalRecorder = TerminalScriptRecorder()
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: WorkBatchTaskSessionCoordinator(
                fileManager: harness.fileManager,
                claudePathResolver: { "/opt/homebrew/bin/claude" },
                runTerminalScript: { script in
                    await terminalRecorder.record(script)
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
        )
        router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.runtimeSession(sessionId: "assigned-session-existing", cwd: harness.mobileWorktreePath),
                harness.runtimeSession(sessionId: "manual-duplicate", cwd: "\(harness.mobileWorktreePath)/src"),
            ],
            now: harness.now,
        )

        do {
            _ = try await router.openCockpit(binding: binding)
            XCTFail("Expected duplicate cockpit error")
        } catch let error as WorkBatchAutoRouterError {
            XCTAssertEqual(error, .duplicateCockpit(batchName: "Mobile prototype"))
        }

        let scripts = await terminalRecorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
    }

    func testIngestCompletionReportMarksTaskAndBatchDoneOnce() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        let completedAt = harness.now.addingTimeInterval(10)
        let reportStore = WorkBatchCompletionReportStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        )
        _ = try reportStore.write(WorkBatchCompletionReport(
            taskID: "idea-old",
            status: "done",
            summary: "Adjusted mobile spacing",
            evidence: ["Changed spacing constants", "Ran Swift tests"],
            completedAt: completedAt,
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        let results = router.ingestCompletionReports(projects: [harness.project], now: completedAt)

        XCTAssertEqual(results.map(\.taskID), ["idea-old"])
        XCTAssertEqual(results[0].summary, "Adjusted mobile spacing")
        let state = try harness.stateStore.load()
        XCTAssertEqual(state.tasks.first?.status, .done)
        XCTAssertEqual(state.batches.first?.status, .idle)
        XCTAssertEqual(state.batches.first?.currentActivitySummary, "Done: Adjusted mobile spacing.")
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .done)

        let mirror = try String(
            contentsOf: URL(fileURLWithPath: harness.mobileWorktreePath)
                .appendingPathComponent(WorkBatchContextMirror.relativePath),
            encoding: .utf8,
        )
        XCTAssertTrue(mirror.contains("[done] Adjust mobile spacing (`idea-old`)"))
        XCTAssertTrue(router.ingestCompletionReports(projects: [harness.project], now: completedAt).isEmpty)
    }

    func testIngestCompletionReportKeepsRunningBatchWhenOtherTasksRemainOpen() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        var state = try harness.stateStore.load()
        state.batches[0].taskIDs.append("idea-green")
        state.tasks.append(WorkBatchTaskRecord(
            id: "idea-green",
            sourceIdeaID: "idea-green",
            title: "Add green border",
            body: "",
            status: .queued,
            batchID: "batch-mobile",
            createdAt: harness.now,
            updatedAt: harness.now,
        ))
        try harness.stateStore.save(state)
        let completedAt = harness.now.addingTimeInterval(10)
        _ = try WorkBatchCompletionReportStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchCompletionReport(
            taskID: "idea-old",
            status: "done",
            summary: "Adjusted spacing.",
            evidence: ["Updated layout"],
            completedAt: completedAt,
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        _ = router.ingestCompletionReports(projects: [harness.project], now: completedAt)

        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-old" })?.status, .done)
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.batches.first?.status, .working)
        XCTAssertEqual(updatedState.batches.first?.currentActivitySummary, "Done: Adjusted spacing. 1 Task still open.")
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .running)
    }

    func testUnresolveRequeuesDoneTaskInSameBatchAndRemovesStaleReport() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .idle, bindingStatus: .done)
        var state = try harness.stateStore.load()
        state.tasks[0].status = .done
        try harness.stateStore.save(state)
        let reportStore = WorkBatchCompletionReportStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        )
        let reportURL = try reportStore.write(WorkBatchCompletionReport(
            taskID: "idea-old",
            status: "done",
            summary: "Adjusted spacing",
            evidence: ["Changed layout"],
            completedAt: harness.now,
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        let result = try router.unresolveTask(
            project: harness.project,
            batchID: "batch-mobile",
            taskID: "idea-old",
            now: harness.now.addingTimeInterval(20),
        )

        XCTAssertEqual(result.batch.id, "batch-mobile")
        XCTAssertEqual(result.task.status, .queued)
        XCTAssertFalse(harness.fileManager.fileExists(atPath: reportURL.path))
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .waiting)

        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first?.status, .queued)
        XCTAssertEqual(updatedState.batches.first?.status, .waiting)
        let mirror = try String(
            contentsOf: URL(fileURLWithPath: harness.mobileWorktreePath)
                .appendingPathComponent(WorkBatchContextMirror.relativePath),
            encoding: .utf8,
        )
        XCTAssertTrue(mirror.contains("[queued] Adjust mobile spacing (`idea-old`)"))
    }

    func testIngestCheckpointRequestMarksTaskNeedsYouAndBatchWaitingOnce() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        let requestedAt = harness.now.addingTimeInterval(10)
        _ = try WorkBatchCheckpointRequestStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchCheckpointRequest(
            checkpointID: "checkpoint-green-token",
            taskID: "idea-old",
            question: "Which green token should I use?",
            reason: "The Task did not say whether the border is debug-only or product-facing.",
            recommendedAction: "Use the production token if this is product-facing.",
            requestedAt: requestedAt,
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        let results = router.ingestCheckpointRequests(projects: [harness.project], now: requestedAt)

        XCTAssertEqual(results.map(\.checkpoint.id), ["checkpoint-green-token"])
        XCTAssertEqual(results[0].taskTitle, "Adjust mobile spacing")
        let state = try harness.stateStore.load()
        XCTAssertEqual(state.tasks.first?.status, .needsYou)
        XCTAssertEqual(state.batches.first?.status, .waiting)
        XCTAssertEqual(state.batches.first?.currentActivitySummary, "Checkpoint ready: Which green token should I use?")
        XCTAssertEqual(state.checkpoints.first?.status, .pending)
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .waiting)

        let mirror = try String(
            contentsOf: URL(fileURLWithPath: harness.mobileWorktreePath)
                .appendingPathComponent(WorkBatchContextMirror.relativePath),
            encoding: .utf8,
        )
        XCTAssertTrue(mirror.contains("[needs_you] Adjust mobile spacing (`idea-old`)"))
        XCTAssertTrue(mirror.contains("[pending] Which green token should I use? (`checkpoint-green-token`, Task `idea-old`)"))
        XCTAssertTrue(router.ingestCheckpointRequests(projects: [harness.project], now: requestedAt).isEmpty)
    }

    func testSubmitCheckpointResponseWritesResponseAndRequeuesSameTask() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .waiting)
        var state = try harness.stateStore.load()
        state.tasks[0].status = .needsYou
        state.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "checkpoint-green-token",
                batchID: "batch-mobile",
                taskID: "idea-old",
                question: "Which green token should I use?",
                reason: "The Task did not say whether the border is debug-only or product-facing.",
                recommendedAction: "Use the production token if this is product-facing.",
                status: .pending,
                requestedAt: harness.now,
                respondedAt: nil,
                response: nil,
                updatedAt: harness.now,
            ),
        ]
        try harness.stateStore.save(state)
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        let result = try router.submitCheckpointResponse(
            project: harness.project,
            batchID: "batch-mobile",
            checkpointID: "checkpoint-green-token",
            response: "Use the production green token.",
            now: harness.now.addingTimeInterval(20),
        )

        XCTAssertEqual(result.checkpoint.status, .answered)
        XCTAssertEqual(result.checkpoint.response, "Use the production green token.")
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first?.status, .queued)
        XCTAssertEqual(updatedState.checkpoints.first?.status, .answered)
        XCTAssertEqual(updatedState.checkpoints.first?.response, "Use the production green token.")
        XCTAssertEqual(updatedState.batches.first?.status, .waiting)

        let responseURL = URL(fileURLWithPath: harness.mobileWorktreePath)
            .appendingPathComponent(WorkBatchCheckpointResponseStore.relativeDirectory, isDirectory: true)
            .appendingPathComponent("checkpoint-green-token.json")
        XCTAssertTrue(harness.fileManager.fileExists(atPath: responseURL.path))

        let mirror = try String(
            contentsOf: URL(fileURLWithPath: harness.mobileWorktreePath)
                .appendingPathComponent(WorkBatchContextMirror.relativePath),
            encoding: .utf8,
        )
        XCTAssertTrue(mirror.contains("[queued] Adjust mobile spacing (`idea-old`)"))
        XCTAssertTrue(mirror.contains("[answered] Which green token should I use? (`checkpoint-green-token`, Task `idea-old`)"))
        XCTAssertTrue(mirror.contains("User response: Use the production green token."))
    }

    func testSubmitCheckpointResponseRejectsEmptyResponse() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .waiting)
        var state = try harness.stateStore.load()
        state.tasks[0].status = .needsYou
        state.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "checkpoint-green-token",
                batchID: "batch-mobile",
                taskID: "idea-old",
                question: "Which green token should I use?",
                reason: "The Task did not say whether the border is debug-only or product-facing.",
                recommendedAction: nil,
                status: .pending,
                requestedAt: harness.now,
                respondedAt: nil,
                response: nil,
                updatedAt: harness.now,
            ),
        ]
        try harness.stateStore.save(state)
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        do {
            _ = try router.submitCheckpointResponse(
                project: harness.project,
                batchID: "batch-mobile",
                checkpointID: "checkpoint-green-token",
                response: "   ",
            )
            XCTFail("Expected empty response to throw")
        } catch let error as WorkBatchAutoRouterError {
            XCTAssertEqual(error, .emptyCheckpointResponse)
        }
    }

    func testSubmitCheckpointResponseRejectsAlreadyAnsweredCheckpointWithoutReopeningDoneTask() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .idle, bindingStatus: .done)
        var state = try harness.stateStore.load()
        state.tasks[0].status = .done
        state.batches[0].status = .idle
        state.batches[0].currentActivitySummary = "Done: Added green border."
        state.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "checkpoint-green-token",
                batchID: "batch-mobile",
                taskID: "idea-old",
                question: "Which green token should I use?",
                reason: "The Task did not say whether the border is debug-only or product-facing.",
                recommendedAction: nil,
                status: .answered,
                requestedAt: harness.now,
                respondedAt: harness.now.addingTimeInterval(10),
                response: "Use the production green token.",
                updatedAt: harness.now.addingTimeInterval(10),
            ),
        ]
        let originalState = state
        try harness.stateStore.save(state)
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        do {
            _ = try router.submitCheckpointResponse(
                project: harness.project,
                batchID: "batch-mobile",
                checkpointID: "checkpoint-green-token",
                response: "Use a debug-only green.",
            )
            XCTFail("Expected already answered checkpoint to throw")
        } catch let error as WorkBatchAutoRouterError {
            XCTAssertEqual(error, .checkpointAlreadyAnswered)
        }

        XCTAssertEqual(try harness.stateStore.load(), originalState)
        let responseURL = URL(fileURLWithPath: harness.mobileWorktreePath)
            .appendingPathComponent(WorkBatchCheckpointResponseStore.relativeDirectory, isDirectory: true)
            .appendingPathComponent("checkpoint-green-token.json")
        XCTAssertFalse(harness.fileManager.fileExists(atPath: responseURL.path))
    }

    func testSubmitCheckpointResponseRejectsMissingBindingWithoutMarkingAnswered() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .waiting)
        try harness.bindingStore.save([])
        var state = try harness.stateStore.load()
        state.tasks[0].status = .needsYou
        state.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "checkpoint-green-token",
                batchID: "batch-mobile",
                taskID: "idea-old",
                question: "Which green token should I use?",
                reason: "The Task did not say whether the border is debug-only or product-facing.",
                recommendedAction: nil,
                status: .pending,
                requestedAt: harness.now,
                respondedAt: nil,
                response: nil,
                updatedAt: harness.now,
            ),
        ]
        let originalState = state
        try harness.stateStore.save(state)
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        do {
            _ = try router.submitCheckpointResponse(
                project: harness.project,
                batchID: "batch-mobile",
                checkpointID: "checkpoint-green-token",
                response: "Use the production green token.",
            )
            XCTFail("Expected missing binding to throw")
        } catch let error as WorkBatchAutoRouterError {
            XCTAssertEqual(error, .bindingNotFound)
        }

        XCTAssertEqual(try harness.stateStore.load(), originalState)
        let responseURL = URL(fileURLWithPath: harness.mobileWorktreePath)
            .appendingPathComponent(WorkBatchCheckpointResponseStore.relativeDirectory, isDirectory: true)
            .appendingPathComponent("checkpoint-green-token.json")
        XCTAssertFalse(harness.fileManager.fileExists(atPath: responseURL.path))
    }
}

private final class RouterHarness {
    let fileManager = FileManager.default
    let tempDir: URL
    let projectRoot: URL
    let stateStore: WorkBatchStateStore
    let bindingStore: WorkBatchCockpitBindingStore
    let now = Date(timeIntervalSince1970: 1_775_000_000)
    var mobileWorktreePath: String {
        projectRoot.appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true).path
    }

    var project: Project {
        Project(
            name: "Arc Design Studio",
            path: projectRoot.path,
            displayPath: projectRoot.path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        stateStore = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        bindingStore = WorkBatchCockpitBindingStore(
            fileURL: tempDir.appendingPathComponent("bindings.json"),
            fileManager: fileManager,
        )
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
    }

    func idea(id: String, title: String, description: String? = nil) -> Idea {
        Idea(
            id: id,
            title: title,
            description: description ?? title,
            added: "2026-05-24T00:00:00Z",
            effort: "small",
            status: "open",
            triage: "pending",
            related: nil,
        )
    }

    func worktreeService(expectedName: String) -> WorktreeService {
        WorktreeService(fileManager: fileManager) { [projectRoot, fileManager] arguments, cwd in
            guard arguments == [
                "worktree",
                "add",
                ".capacitor/worktrees/\(expectedName)",
                "-b",
                "pkp/\(expectedName)",
            ], cwd == projectRoot.path else {
                return .init(exitCode: 1, stdout: "", stderr: "unexpected git command")
            }
            let url = projectRoot.appendingPathComponent(".capacitor/worktrees/\(expectedName)", isDirectory: true)
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func acceptingWorktreeService() -> WorktreeService {
        WorktreeService(fileManager: fileManager) { [projectRoot, fileManager] arguments, cwd in
            guard arguments.count == 5,
                  arguments[0] == "worktree",
                  arguments[1] == "add",
                  arguments[2].hasPrefix(".capacitor/worktrees/"),
                  arguments[3] == "-b",
                  arguments[4].hasPrefix("pkp/"),
                  cwd == projectRoot.path
            else {
                return .init(exitCode: 1, stdout: "", stderr: "unexpected git command")
            }
            let relativePath = arguments[2]
            let url = projectRoot.appendingPathComponent(relativePath, isDirectory: true)
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func seedMobileBatch(
        status: WorkBatchStatus,
        bindingStatus: WorkBatchCockpitBindingStatus,
    ) throws {
        try stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: project.path,
                    status: status,
                    currentActivitySummary: "Tweaking prototype styling.",
                    taskIDs: ["idea-old"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "idea-old",
                    sourceIdeaID: "idea-old",
                    title: "Adjust mobile spacing",
                    body: "",
                    status: .working,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        ))
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: mobileWorktreePath, isDirectory: true),
            withIntermediateDirectories: true,
        )
        try bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: project.path,
            worktreeName: "batch-mobile",
            worktreePath: mobileWorktreePath,
            host: .claudeCode,
            claudeSessionID: "assigned-session-existing",
            status: bindingStatus,
            createdAt: now,
            updatedAt: now,
        ))
    }

    func runtimeSession(sessionId: String, cwd: String) -> RuntimeSession {
        RuntimeSession(
            sessionId: sessionId,
            pid: 1234,
            state: "working",
            cwd: cwd,
            projectId: nil,
            workspaceId: nil,
            projectPath: cwd,
            updatedAt: "2026-05-25T00:00:00Z",
            stateChangedAt: "2026-05-25T00:00:00Z",
            lastEvent: nil,
            lastActivityAt: nil,
            toolsInFlight: nil,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
            gcReason: nil,
            isAlive: true,
        )
    }
}

private actor TerminalScriptRecorder {
    private var scripts: [String] = []

    func record(_ script: String) {
        scripts.append(script)
    }

    func snapshot() -> [String] {
        scripts
    }
}

private actor ClassifierGate {
    private var started = false

    func markStarted() {
        started = true
    }

    func waitUntilStarted() async {
        while !started {
            await _Concurrency.Task.yield()
        }
    }
}
