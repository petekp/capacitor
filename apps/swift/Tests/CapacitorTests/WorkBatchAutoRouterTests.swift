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
        XCTAssertEqual(
            state.deliveryRecord(batchID: state.batches[0].id)?.lastDeliveryGeneration,
            "\(state.batches[0].id):2026-03-31T23:33:20.000Z",
        )

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
        XCTAssertEqual(
            state.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryGeneration,
            "batch-mobile:2026-03-31T23:33:20.000Z",
        )

        let mirror = try String(
            contentsOf: worktreeURL.appendingPathComponent(WorkBatchContextMirror.relativePath),
            encoding: .utf8,
        )
        XCTAssertTrue(mirror.contains("Adjust mobile spacing"))
        XCTAssertTrue(mirror.contains("Add green border around the mobile prototype"))
        XCTAssertTrue(mirror.contains("\"delivery_generation\":\"batch-mobile:2026-03-31T23:33:20.000Z\""))
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

    func testLowConfidenceNewUnrelatedClassificationIsNotOverriddenByProjectScaffoldWords() async throws {
        let harness = try RouterHarness()
        let project = Project(
            name: "capacitor-operator-routing-fixture-20260526",
            path: harness.projectRoot.path,
            displayPath: harness.projectRoot.path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
        try harness.stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-typography-notes",
                    name: "Typography Notes",
                    projectPath: project.path,
                    status: .ready,
                    currentActivitySummary: "Done: Created typography-note.txt with one sentence about checking the headline type scale.",
                    taskIDs: ["idea-type-note"],
                    cockpitBindingID: "batch-typography-notes",
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "idea-type-note",
                    sourceIdeaID: "idea-type-note",
                    title: "In this disposable routing fixture, create typography-note.txt with one sentence",
                    body: "In this disposable routing fixture, create typography-note.txt with one sentence about checking the headline type scale. Keep the change tiny and local.",
                    status: .done,
                    batchID: "batch-typography-notes",
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            classifications: [],
            deliveryRecords: [],
        ))
        let terminalRecorder = TerminalScriptRecorder()
        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.acceptingWorktreeService(),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { "assigned-session-export" },
            runTerminalScript: { script in
                await terminalRecorder.record(script)
            },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            classifier: { request in
                .new(
                    taskID: request.task.id,
                    batchName: "CSV Export Notes",
                    confidence: 0.8,
                    rationale: "Different domain: CSV export field ordering is unrelated to typography notes.",
                    summary: "Start CSV export notes.",
                    createdAt: harness.now,
                )
            },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        let result = try await router.routeCapturedTask(
            project: project,
            idea: harness.idea(
                id: "idea-export-note",
                title: "In this disposable routing fixture, create export-note.txt with one sentence about CSV export",
                description: "In this disposable routing fixture, create export-note.txt with one sentence about checking CSV export field ordering. Keep the change tiny and local.",
            ),
            now: harness.now.addingTimeInterval(60),
        )

        XCTAssertTrue(result.startedNewSession)
        XCTAssertEqual(result.batch.name, "CSV Export Notes")
        XCTAssertEqual(result.classification.targetKind, .new)
        XCTAssertFalse(result.classification.rationale.contains("low-confidence new-batch classification"))
        XCTAssertEqual(result.binding?.claudeSessionID, "assigned-session-export")

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.count, 2)
        XCTAssertEqual(state.batches.first(where: { $0.id == "batch-typography-notes" })?.taskIDs, ["idea-type-note"])
        XCTAssertEqual(state.tasks.first(where: { $0.id == "idea-export-note" })?.batchID, result.batch.id)

        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
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
        XCTAssertTrue(scripts[0].contains("New task queued: Add green border around the mobile prototype."))
        XCTAssertEqual(result.binding?.status, .launching)
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .launching)
        XCTAssertEqual(
            try harness.stateStore.load().batches[0].currentActivitySummary,
            "Claude Code is reconnecting to Add green border around the mobile prototype.",
        )
    }

    func testRoutesRelatedTaskToProcessLiveBindingWithoutUnsafeWake() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale, taskStatus: .queued)
        var state = try harness.stateStore.load()
        state.batches[0].currentActivitySummary = "Claude Code session needs reconnect."
        try harness.stateStore.save(state)

        let terminalRecorder = TerminalScriptRecorder()
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
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
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { binding in
                binding.batchID == "batch-mobile" ? ["assigned-session-existing"] : []
            },
        )
        let issues = router.reconcileBindings(
            projects: [harness.project],
            sessions: [],
            now: harness.now,
        )

        XCTAssertTrue(issues.isEmpty)

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.status, .running)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts, [])
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(wakes, [])
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.batches[0].currentActivitySummary, "Queued Add green border around the mobile prototype in Mobile prototype.")
        XCTAssertNil(updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind)
    }

    func testRoutesRelatedTaskToProcessLiveBindingWakesOnlyAtSafeBoundary() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale, taskStatus: .queued)
        var state = try harness.stateStore.load()
        state.batches[0].currentActivitySummary = "Claude Code session needs reconnect."
        try harness.stateStore.save(state)

        let terminalRecorder = TerminalScriptRecorder()
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
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
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { binding in
                binding.batchID == "batch-mobile" ? ["assigned-session-existing"] : []
            },
            safeWakeBoundaryAllowsInput: { binding in
                binding.batchID == "batch-mobile"
            },
        )
        let issues = router.reconcileBindings(
            projects: [harness.project],
            sessions: [],
            now: harness.now,
        )

        XCTAssertTrue(issues.isEmpty)

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.status, .running)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts, [])
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(wakes[0].projectPath, harness.mobileWorktreePath)
        XCTAssertEqual(wakes[0].sessionName, "Mobile prototype")
        XCTAssertEqual(wakes[0].prompt, "New task queued: Add green border around the mobile prototype.")
        XCTAssertFalse(wakes[0].prompt.contains("Task claim"))
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.batches[0].currentActivitySummary, "Claude Code was nudged to pick up Add green border around the mobile prototype.")
        XCTAssertEqual(
            updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind,
            WorkBatchDeliveryAction.wakeExistingSession.rawValue,
        )
    }

    func testRoutesRelatedTaskToRuntimeReadyExactSessionWakesByDefault() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale, taskStatus: .queued)
        var state = try harness.stateStore.load()
        state.batches[0].currentActivitySummary = "Claude Code session needs reconnect."
        try harness.stateStore.save(state)

        let terminalRecorder = TerminalScriptRecorder()
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
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
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { _ in [] },
        )
        let issues = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.runtimeSession(
                    sessionId: "assigned-session-existing",
                    cwd: harness.mobileWorktreePath,
                    state: "ready",
                    toolsInFlight: 0,
                    isAlive: true,
                ),
            ],
            now: harness.now,
        )

        XCTAssertTrue(issues.isEmpty)

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.status, .running)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts, [])
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(wakes[0].projectPath, harness.mobileWorktreePath)
        XCTAssertEqual(wakes[0].sessionName, "Mobile prototype")
        XCTAssertEqual(wakes[0].prompt, "New task queued: Add green border around the mobile prototype.")
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.batches[0].currentActivitySummary, "Claude Code was nudged to pick up Add green border around the mobile prototype.")
        XCTAssertEqual(
            updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind,
            WorkBatchDeliveryAction.wakeExistingSession.rawValue,
        )
    }

    func testRoutesRelatedTaskToRuntimeReadySignalAbsenceWakesExactAssignedSession() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale, taskStatus: .queued)
        var state = try harness.stateStore.load()
        state.batches[0].currentActivitySummary = "Claude Code session needs reconnect."
        try harness.stateStore.save(state)

        let terminalRecorder = TerminalScriptRecorder()
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
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
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
        )
        let issues = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.runtimeSession(
                    sessionId: "assigned-session-existing",
                    cwd: harness.mobileWorktreePath,
                    state: "ready",
                    toolsInFlight: 0,
                    gcReason: "signal_absence",
                    isAlive: true,
                ),
            ],
            now: harness.now,
        )

        XCTAssertTrue(issues.isEmpty)

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.status, .running)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts, [])
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(wakes[0].projectPath, harness.mobileWorktreePath)
        XCTAssertEqual(wakes[0].sessionName, "Mobile prototype")
        XCTAssertEqual(wakes[0].prompt, "New task queued: Add green border around the mobile prototype.")
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.batches[0].currentActivitySummary, "Claude Code was nudged to pick up Add green border around the mobile prototype.")
        XCTAssertEqual(
            updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind,
            WorkBatchDeliveryAction.wakeExistingSession.rawValue,
        )
    }

    func testRoutesRelatedTaskToProcessBackedSignalAbsenceAwaitingInputWakesExactAssignedSession() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running, taskStatus: .queued)

        let terminalRecorder = TerminalScriptRecorder()
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
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
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { binding in
                binding.claudeSessionID == "assigned-session-existing" ? ["assigned-session-existing"] : []
            },
        )
        let issues = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.runtimeSession(
                    sessionId: "assigned-session-existing",
                    cwd: harness.mobileWorktreePath,
                    state: "idle",
                    toolsInFlight: 0,
                    stateSource: RuntimeStateSource(
                        eventKind: "notification",
                        authority: "meta_awaiting_input",
                        observedAt: "2026-05-25T00:00:00Z",
                    ),
                    gcReason: "signal_absence",
                    isAlive: false,
                ),
            ],
            now: harness.now,
        )

        XCTAssertTrue(issues.isEmpty)

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.status, .running)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts, [])
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(wakes[0].projectPath, harness.mobileWorktreePath)
        XCTAssertEqual(wakes[0].sessionName, "Mobile prototype")
        XCTAssertEqual(wakes[0].prompt, "New task queued: Add green border around the mobile prototype.")
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.batches[0].currentActivitySummary, "Claude Code was nudged to pick up Add green border around the mobile prototype.")
        XCTAssertEqual(
            updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind,
            WorkBatchDeliveryAction.wakeExistingSession.rawValue,
        )
    }

    func testProcessBackedSignalAbsenceWithoutAwaitingInputDefersWake() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running, taskStatus: .queued)

        let terminalRecorder = TerminalScriptRecorder()
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
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
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { binding in
                binding.claudeSessionID == "assigned-session-existing" ? ["assigned-session-existing"] : []
            },
        )
        let issues = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.runtimeSession(
                    sessionId: "assigned-session-existing",
                    cwd: harness.mobileWorktreePath,
                    state: "idle",
                    toolsInFlight: 0,
                    stateSource: nil,
                    gcReason: "signal_absence",
                    isAlive: false,
                ),
            ],
            now: harness.now,
        )

        XCTAssertTrue(issues.isEmpty)

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.status, .running)
        let scripts = await terminalRecorder.snapshot()
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(scripts, [])
        XCTAssertEqual(wakes, [])
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.batches[0].currentActivitySummary, "Queued Add green border around the mobile prototype in Mobile prototype.")
        XCTAssertNil(updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind)
    }

    func testProcessBackedSignalAbsenceWithoutToolCountDefersWake() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running, taskStatus: .queued)

        let terminalRecorder = TerminalScriptRecorder()
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
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
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { binding in
                binding.claudeSessionID == "assigned-session-existing" ? ["assigned-session-existing"] : []
            },
        )
        let issues = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.runtimeSession(
                    sessionId: "assigned-session-existing",
                    cwd: harness.mobileWorktreePath,
                    state: "idle",
                    toolsInFlight: nil,
                    stateSource: RuntimeStateSource(
                        eventKind: "notification",
                        authority: "meta_awaiting_input",
                        observedAt: "2026-05-25T00:00:00Z",
                    ),
                    gcReason: "signal_absence",
                    isAlive: false,
                ),
            ],
            now: harness.now,
        )

        XCTAssertTrue(issues.isEmpty)

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.status, .running)
        let scripts = await terminalRecorder.snapshot()
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(scripts, [])
        XCTAssertEqual(wakes, [])
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.batches[0].currentActivitySummary, "Queued Add green border around the mobile prototype in Mobile prototype.")
        XCTAssertNil(updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind)
    }

    func testRoutesRelatedTaskToRuntimeWorkingExactSessionDefersWake() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale, taskStatus: .queued)
        var state = try harness.stateStore.load()
        state.batches[0].currentActivitySummary = "Claude Code session needs reconnect."
        try harness.stateStore.save(state)

        let terminalRecorder = TerminalScriptRecorder()
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
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
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { _ in [] },
        )
        let issues = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.runtimeSession(
                    sessionId: "assigned-session-existing",
                    cwd: harness.mobileWorktreePath,
                    state: "working",
                    toolsInFlight: 0,
                    isAlive: true,
                ),
            ],
            now: harness.now,
        )

        XCTAssertTrue(issues.isEmpty)

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.status, .running)
        let scripts = await terminalRecorder.snapshot()
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(scripts, [])
        XCTAssertEqual(wakes, [])
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.batches[0].currentActivitySummary, "Queued Add green border around the mobile prototype in Mobile prototype.")
        XCTAssertNil(updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind)
    }

    func testRoutesRelatedTaskToRuntimeReadyExactSessionWithToolInFlightDefersWake() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale, taskStatus: .queued)
        var state = try harness.stateStore.load()
        state.batches[0].currentActivitySummary = "Claude Code session needs reconnect."
        try harness.stateStore.save(state)

        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
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
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { _ in [] },
        )
        _ = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.runtimeSession(
                    sessionId: "assigned-session-existing",
                    cwd: harness.mobileWorktreePath,
                    state: "ready",
                    toolsInFlight: 1,
                    isAlive: true,
                ),
            ],
            now: harness.now,
        )

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )

        XCTAssertFalse(result.startedNewSession)
        XCTAssertEqual(result.binding?.status, .running)
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(wakes, [])
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.batches[0].currentActivitySummary, "Queued Add green border around the mobile prototype in Mobile prototype.")
        XCTAssertNil(updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind)
    }

    func testNoClaimAfterDeliveryAttemptMarksBatchWaitingWithoutRepeatingWake() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(
            status: .working,
            bindingStatus: .running,
            taskStatus: .queued,
            deliveryRecords: [
                WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: harness.now,
                    lastDeliveryGeneration: "batch-mobile:current",
                    lastDeliveryAttemptAt: harness.now,
                    lastDeliveryAttemptKind: WorkBatchDeliveryAction.wakeExistingSession.rawValue,
                    lastClaimAt: nil,
                ),
            ],
        )
        let terminalRecorder = TerminalScriptRecorder()
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: WorkBatchTaskSessionCoordinator(
                worktreeService: harness.worktreeService(expectedName: "should-not-launch"),
                fileManager: harness.fileManager,
                claudePathResolver: { "/opt/homebrew/bin/claude" },
                runTerminalScript: { script in
                    await terminalRecorder.record(script)
                },
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { binding in
                binding.batchID == "batch-mobile" ? ["assigned-session-existing"] : []
            },
        )

        _ = try await router.followThroughWorkBatchDelivery(
            project: harness.project,
            batchID: "batch-mobile",
            preferredTaskID: "idea-old",
            now: harness.now.addingTimeInterval(WorkBatchDeliveryPolicy.pickupClaimTimeout + 1),
        )

        let launchedScripts = await terminalRecorder.snapshot()
        let wakeAttempts = await wakeRecorder.snapshot()
        XCTAssertEqual(launchedScripts, [])
        XCTAssertEqual(wakeAttempts, [])
        let state = try harness.stateStore.load()
        XCTAssertEqual(state.tasks.first?.status, .queued)
        XCTAssertEqual(state.batches.first?.status, .waiting)
        XCTAssertEqual(
            state.batches.first?.currentActivitySummary,
            "Claude Code has not picked up Adjust mobile spacing yet. Click to re-enter.",
        )
        XCTAssertEqual(
            state.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind,
            WorkBatchDeliveryAction.wakeExistingSession.rawValue,
        )

        _ = try await router.followThroughWorkBatchDelivery(
            project: harness.project,
            batchID: "batch-mobile",
            preferredTaskID: "idea-old",
            now: harness.now.addingTimeInterval(WorkBatchDeliveryPolicy.pickupClaimTimeout + 2),
        )
        XCTAssertEqual(try harness.stateStore.load(), state)
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

    func testUnboundWaitingBatchClickRetriesSessionLaunch() async throws {
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
                    taskIDs: ["idea-1"],
                    cockpitBindingID: nil,
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "idea-1",
                    sourceIdeaID: "idea-1",
                    title: "Add green border around the mobile prototype",
                    body: "",
                    status: .queued,
                    batchID: "batch-mobile",
                    createdAt: harness.now,
                    updatedAt: harness.now,
                ),
            ],
            classifications: [],
        ))

        let terminalRecorder = TerminalScriptRecorder()
        let taskSessionCoordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: harness.worktreeService(expectedName: "batch-mobile"),
            fileManager: harness.fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { "assigned-session-retry" },
            runTerminalScript: { script in
                await terminalRecorder.record(script)
            },
            bindingStoreFactory: { _ in harness.bindingStore },
        )
        let router = WorkBatchAutoRouter(
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
            taskSessionCoordinator: taskSessionCoordinator,
        )

        let binding = try await router.startSessionForUnboundBatch(
            project: harness.project,
            batchID: "batch-mobile",
            now: harness.now,
        )

        XCTAssertEqual(binding.claudeSessionID, "assigned-session-retry")
        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.first?.cockpitBindingID, "batch-mobile")
        XCTAssertEqual(state.batches.first?.status, .working)
        XCTAssertEqual(state.tasks.first?.status, .working)

        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--session-id"))
        XCTAssertTrue(scripts[0].contains("assigned-session-retry"))
    }

    func testIngestTaskRequestAddsQueuedTaskToBoundBatchAndRewritesMirror() throws {
        let harness = try RouterHarness()
        let requestedAt = harness.now.addingTimeInterval(30)
        try harness.seedMobileBatch(
            status: .ready,
            bindingStatus: .running,
            taskStatus: .done,
        )
        _ = try WorkBatchTaskRequestStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchTaskRequest(
            taskID: "Task/Empty State Copy",
            title: "Fix empty state copy",
            body: "The user asked for clearer copy in the empty state.",
            source: "manual_user_instruction",
            requestedAt: requestedAt,
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        let results = router.ingestTaskRequests(projects: [harness.project], now: requestedAt)

        XCTAssertEqual(results.map(\.taskID), ["task-empty-state-copy"])
        XCTAssertEqual(results.first?.taskTitle, "Fix empty state copy")

        let state = try harness.stateStore.load()
        let task = try XCTUnwrap(state.tasks.first { $0.id == "task-empty-state-copy" })
        XCTAssertNil(task.sourceIdeaID)
        XCTAssertEqual(task.status, .queued)
        XCTAssertEqual(task.batchID, "batch-mobile")
        XCTAssertEqual(task.createdAt, requestedAt)
        XCTAssertEqual(task.updatedAt, requestedAt)
        XCTAssertEqual(task.title, "Fix empty state copy")
        XCTAssertEqual(task.body, "The user asked for clearer copy in the empty state.")

        let batch = try XCTUnwrap(state.batches.first { $0.id == "batch-mobile" })
        XCTAssertEqual(batch.status, .working)
        XCTAssertEqual(batch.taskIDs, ["idea-old", "task-empty-state-copy"])
        XCTAssertEqual(batch.currentActivitySummary, "Queued Fix empty state copy.")

        let classification = try XCTUnwrap(state.classifications.last)
        XCTAssertEqual(classification.taskID, "task-empty-state-copy")
        XCTAssertEqual(classification.targetKind, .existing)
        XCTAssertEqual(classification.batchID, "batch-mobile")
        XCTAssertEqual(classification.confidence, 1)
        XCTAssertTrue(classification.rationale.contains("Task request artifact"))

        let deliveryRecord = try XCTUnwrap(state.deliveryRecord(batchID: "batch-mobile"))
        XCTAssertNotNil(deliveryRecord.lastContextWrittenAt)
        XCTAssertNotNil(deliveryRecord.lastDeliveryGeneration)
        XCTAssertNotNil(deliveryRecord.lastActionableContextDigest)

        let mirrorURL = URL(fileURLWithPath: harness.mobileWorktreePath, isDirectory: true)
            .appendingPathComponent(WorkBatchContextMirror.relativePath)
        let mirror = try String(contentsOf: mirrorURL, encoding: .utf8)
        XCTAssertTrue(mirror.contains(".capacitor/work-batch-task-requests/<task-id>.json"))
        XCTAssertTrue(mirror.contains("- [queued] Fix empty state copy (`task-empty-state-copy`)"))
        XCTAssertTrue(mirror.contains("The user asked for clearer copy in the empty state."))
    }

    func testIngestTaskRequestIsIdempotentByTaskID() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(
            status: .ready,
            bindingStatus: .running,
            taskStatus: .done,
        )
        _ = try WorkBatchTaskRequestStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchTaskRequest(
            taskID: "task-empty-state-copy",
            title: "Fix empty state copy",
            body: "The user asked for clearer copy in the empty state.",
            source: "manual_user_instruction",
            requestedAt: harness.now.addingTimeInterval(30),
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        XCTAssertEqual(router.ingestTaskRequests(projects: [harness.project], now: harness.now).count, 1)
        XCTAssertTrue(router.ingestTaskRequests(projects: [harness.project], now: harness.now).isEmpty)

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.tasks.count(where: { $0.id == "task-empty-state-copy" }), 1)
        XCTAssertEqual(state.batches.first?.taskIDs.count(where: { $0 == "task-empty-state-copy" }), 1)
    }

    func testIngestTaskRequestIgnoresBlankRequests() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(
            status: .ready,
            bindingStatus: .running,
            taskStatus: .done,
        )
        _ = try WorkBatchTaskRequestStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchTaskRequest(
            taskID: "task-blank",
            title: " ",
            body: "\n",
            source: "manual_user_instruction",
            requestedAt: harness.now.addingTimeInterval(30),
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        XCTAssertTrue(router.ingestTaskRequests(projects: [harness.project], now: harness.now).isEmpty)
        let state = try harness.stateStore.load()
        XCTAssertNil(state.tasks.first { $0.id == "task-blank" })
        XCTAssertEqual(state.batches.first?.taskIDs, ["idea-old"])
    }

    func testIngestTaskRequestCapsFutureAgentTimestampAtIngestTime() throws {
        let harness = try RouterHarness()
        let ingestTime = harness.now.addingTimeInterval(60)
        try harness.seedMobileBatch(
            status: .ready,
            bindingStatus: .running,
            taskStatus: .done,
        )
        _ = try WorkBatchTaskRequestStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchTaskRequest(
            taskID: "task-future-clock",
            title: "Handle future clock",
            body: "The agent clock wrote a future timestamp.",
            source: "manual_user_instruction",
            requestedAt: ingestTime.addingTimeInterval(3600),
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        _ = router.ingestTaskRequests(projects: [harness.project], now: ingestTime)

        let state = try harness.stateStore.load()
        let task = try XCTUnwrap(state.tasks.first { $0.id == "task-future-clock" })
        XCTAssertEqual(task.createdAt, ingestTime)
        XCTAssertEqual(task.updatedAt, ingestTime)
        XCTAssertEqual(state.batches.first?.updatedAt, ingestTime)
    }

    func testIngestTaskClaimMarksQueuedTaskWorking() throws {
        let harness = try RouterHarness()
        let claimTime = harness.now.addingTimeInterval(20)
        try harness.seedMobileBatch(
            status: .working,
            bindingStatus: .running,
            taskStatus: .queued,
            deliveryRecords: [
                WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: harness.now,
                    lastDeliveryGeneration: "batch-mobile:1775000000",
                    lastDeliveryAttemptAt: nil,
                    lastDeliveryAttemptKind: nil,
                    lastClaimAt: nil,
                ),
            ],
        )
        _ = try WorkBatchTaskClaimStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchTaskClaim(
            taskID: "idea-old",
            status: "working",
            summary: "Working on mobile spacing.",
            claimedAt: claimTime,
            contextUpdatedAt: harness.now,
            deliveryGeneration: "batch-mobile:1775000000",
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        let results = router.ingestTaskClaims(projects: [harness.project], now: claimTime)

        XCTAssertEqual(results.map(\.taskID), ["idea-old"])
        let state = try harness.stateStore.load()
        XCTAssertEqual(state.tasks.first?.status, .working)
        XCTAssertEqual(state.tasks.first?.updatedAt, claimTime)
        XCTAssertEqual(state.batches.first?.status, .working)
        XCTAssertEqual(state.batches.first?.currentActivitySummary, "Working on mobile spacing.")
        XCTAssertEqual(state.deliveryRecord(batchID: "batch-mobile")?.lastClaimAt, claimTime)
    }

    func testIngestTaskClaimAcceptsCurrentGenerationWhenClaimTimestampWasCopiedFromMirror() throws {
        let harness = try RouterHarness()
        let originalContextWrite = harness.now
        let taskUpdatedAt = harness.now.addingTimeInterval(120)
        try harness.seedMobileBatch(
            status: .working,
            bindingStatus: .running,
            taskStatus: .queued,
            deliveryRecords: [
                WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: originalContextWrite,
                    lastDeliveryGeneration: "batch-mobile:current",
                    lastDeliveryAttemptAt: taskUpdatedAt,
                    lastDeliveryAttemptKind: WorkBatchDeliveryAction.wakeExistingSession.rawValue,
                    lastClaimAt: nil,
                ),
            ],
        )
        var state = try harness.stateStore.load()
        state.tasks[0].updatedAt = taskUpdatedAt
        state.batches[0].updatedAt = taskUpdatedAt
        try harness.stateStore.save(state)

        _ = try WorkBatchTaskClaimStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchTaskClaim(
            taskID: "idea-old",
            status: "working",
            summary: "Working on mobile spacing after wake.",
            claimedAt: originalContextWrite,
            contextUpdatedAt: originalContextWrite,
            deliveryGeneration: "batch-mobile:current",
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        let results = router.ingestTaskClaims(projects: [harness.project], now: harness.now.addingTimeInterval(180))

        XCTAssertEqual(results.map(\.taskID), ["idea-old"])
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first?.status, .working)
        XCTAssertEqual(updatedState.tasks.first?.updatedAt, taskUpdatedAt)
        XCTAssertEqual(updatedState.batches.first?.currentActivitySummary, "Working on mobile spacing after wake.")
        XCTAssertEqual(updatedState.deliveryRecord(batchID: "batch-mobile")?.lastClaimAt, taskUpdatedAt)
    }

    func testCompletionReportWinsWhenDoneTimestampPrecedesWakeClaimState() throws {
        let harness = try RouterHarness()
        let originalContextWrite = harness.now
        let wakeTime = harness.now.addingTimeInterval(120)
        try harness.seedMobileBatch(
            status: .working,
            bindingStatus: .running,
            taskStatus: .queued,
            deliveryRecords: [
                WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: originalContextWrite,
                    lastDeliveryGeneration: "batch-mobile:current",
                    lastDeliveryAttemptAt: wakeTime,
                    lastDeliveryAttemptKind: WorkBatchDeliveryAction.wakeExistingSession.rawValue,
                    lastClaimAt: nil,
                ),
            ],
        )
        var state = try harness.stateStore.load()
        state.tasks[0].status = .working
        state.tasks[0].updatedAt = wakeTime
        state.batches[0].updatedAt = wakeTime
        try harness.stateStore.save(state)

        _ = try WorkBatchCompletionReportStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchCompletionReport(
            taskID: "idea-old",
            status: "done",
            summary: "Adjusted mobile spacing after wake",
            evidence: ["Changed spacing constants"],
            completedAt: originalContextWrite.addingTimeInterval(30),
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        let results = router.ingestCompletionReports(projects: [harness.project], now: wakeTime.addingTimeInterval(30))

        XCTAssertEqual(results.map(\.taskID), ["idea-old"])
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first?.status, .done)
        XCTAssertEqual(updatedState.tasks.first?.updatedAt, wakeTime)
        XCTAssertEqual(updatedState.batches.first?.status, .idle)
        XCTAssertEqual(updatedState.batches.first?.currentActivitySummary, "Done: Adjusted mobile spacing after wake.")
    }

    func testIngestTaskClaimIgnoresForeignDoneNeedsYouStaleAndWrongGenerationClaims() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(
            status: .working,
            bindingStatus: .running,
            taskStatus: .queued,
            deliveryRecords: [
                WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: harness.now,
                    lastDeliveryGeneration: "batch-mobile:current",
                    lastDeliveryAttemptAt: nil,
                    lastDeliveryAttemptKind: nil,
                    lastClaimAt: nil,
                ),
            ],
        )
        let claimStore = WorkBatchTaskClaimStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        )
        _ = try claimStore.write(WorkBatchTaskClaim(
            taskID: "foreign-task",
            status: "working",
            summary: "Foreign",
            claimedAt: harness.now.addingTimeInterval(10),
            contextUpdatedAt: harness.now,
            deliveryGeneration: "batch-mobile:current",
        ))
        _ = try claimStore.write(WorkBatchTaskClaim(
            taskID: "idea-old",
            status: "working",
            summary: "Stale",
            claimedAt: harness.now.addingTimeInterval(-10),
            contextUpdatedAt: harness.now,
            deliveryGeneration: nil,
        ))
        _ = try claimStore.write(WorkBatchTaskClaim(
            taskID: "idea-old",
            status: "working",
            summary: "Wrong generation",
            claimedAt: harness.now.addingTimeInterval(10),
            contextUpdatedAt: harness.now,
            deliveryGeneration: "batch-mobile:old",
        ))
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in harness.stateStore },
            bindingStoreFactory: { _ in harness.bindingStore },
        )

        XCTAssertTrue(router.ingestTaskClaims(projects: [harness.project], now: harness.now).isEmpty)
        XCTAssertEqual(try harness.stateStore.load().tasks.first?.status, .queued)

        var state = try harness.stateStore.load()
        state.tasks[0].status = .done
        try harness.stateStore.save(state)
        _ = try claimStore.write(WorkBatchTaskClaim(
            taskID: "idea-old",
            status: "working",
            summary: "Done should win",
            claimedAt: harness.now.addingTimeInterval(20),
            contextUpdatedAt: harness.now,
            deliveryGeneration: "batch-mobile:current",
        ))
        XCTAssertTrue(router.ingestTaskClaims(projects: [harness.project], now: harness.now).isEmpty)
        XCTAssertEqual(try harness.stateStore.load().tasks.first?.status, .done)

        state = try harness.stateStore.load()
        state.tasks[0].status = .needsYou
        try harness.stateStore.save(state)
        XCTAssertTrue(router.ingestTaskClaims(projects: [harness.project], now: harness.now).isEmpty)
        XCTAssertEqual(try harness.stateStore.load().tasks.first?.status, .needsYou)
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
        XCTAssertTrue(scripts[0].contains("--append-system-prompt-file"))
        XCTAssertTrue(scripts[0].contains(".capacitor/work-batch-agent-instructions.md"))
        XCTAssertFalse(scripts[0].contains("Task claim"))
        XCTAssertTrue(scripts[0].contains("New task queued: Add green border around the mobile prototype."))
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

    func testDuplicateAssignedSessionProcessKeepsUserFacingSummaryActionable() async throws {
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
            processSessionIDs: { _ in ["assigned-session-existing", "assigned-session-existing"] },
        )
        router.reconcileBindings(
            projects: [harness.project],
            sessions: [],
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
        XCTAssertEqual(state.batches.first?.currentActivitySummary, "Claude Code is already open; click to re-enter.")
        XCTAssertEqual(state.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
    }

    func testPendingCheckpointPreventsResumeAfterNewRelatedTask() async throws {
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
                reason: "There are multiple green tokens.",
                recommendedAction: "Use production if this is product-facing.",
                status: .pending,
                requestedAt: harness.now,
                respondedAt: nil,
                response: nil,
                updatedAt: harness.now,
            ),
        ]
        try harness.stateStore.save(state)
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

        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(20),
        )

        XCTAssertFalse(result.startedNewSession)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.batches.first?.status, .waiting)
        XCTAssertEqual(updatedState.batches.first?.currentActivitySummary, "Checkpoint ready: Which green token should I use?")
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-old" })?.status, .needsYou)
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.checkpoints.first?.status, .pending)
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

    func testOpenDoneCockpitThrowsWhenForeignDuplicateBatchCockpitExists() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .idle, bindingStatus: .done, taskStatus: .done)
        let binding = try XCTUnwrap(harness.bindingStore.binding(batchID: "batch-mobile"))
        let terminalRecorder = TerminalScriptRecorder()
        let focusRecorder = ExistingTerminalFocusRecorder(result: true)
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
                focusExistingTerminal: { projectPath, sessionName in
                    await focusRecorder.record(projectPath: projectPath, sessionName: sessionName)
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
            XCTFail("Expected completed batch with foreign duplicate cockpit to stay ambiguous")
        } catch let error as WorkBatchAutoRouterError {
            XCTAssertEqual(error, .duplicateCockpit(batchName: "Mobile prototype"))
        }

        let focusAttempts = await focusRecorder.snapshot()
        XCTAssertTrue(focusAttempts.isEmpty)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.first?.status, .ready)
        XCTAssertEqual(state.tasks.first?.status, .done)
    }

    func testOpenCockpitFocusesAssignedSessionWhenOnlyDuplicateProcessMatches() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .waiting)
        let binding = try XCTUnwrap(harness.bindingStore.binding(batchID: "batch-mobile"))
        let terminalRecorder = TerminalScriptRecorder()
        let focusRecorder = ExistingTerminalFocusRecorder(result: true)
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
                focusExistingTerminal: { projectPath, sessionName in
                    await focusRecorder.record(projectPath: projectPath, sessionName: sessionName)
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { _ in ["assigned-session-existing", "assigned-session-existing"] },
        )
        router.reconcileBindings(
            projects: [harness.project],
            sessions: [],
            now: harness.now,
        )

        let request = try await router.openCockpit(binding: binding)

        XCTAssertNil(request)
        let focusAttempts = await focusRecorder.snapshot()
        XCTAssertEqual(focusAttempts.count, 1)
        XCTAssertEqual(focusAttempts[0].projectPath, harness.mobileWorktreePath)
        XCTAssertEqual(focusAttempts[0].sessionName, "Mobile prototype")
        let scripts = await terminalRecorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
    }

    func testOpenCockpitDoesNotResumeWhenDuplicateAssignedProcessCannotBeFocused() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .waiting)
        let binding = try XCTUnwrap(harness.bindingStore.binding(batchID: "batch-mobile"))
        let terminalRecorder = TerminalScriptRecorder()
        let focusRecorder = ExistingTerminalFocusRecorder(result: false)
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
                focusExistingTerminal: { projectPath, sessionName in
                    await focusRecorder.record(projectPath: projectPath, sessionName: sessionName)
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { _ in ["assigned-session-existing", "assigned-session-existing"] },
        )
        router.reconcileBindings(
            projects: [harness.project],
            sessions: [],
            now: harness.now,
        )

        do {
            _ = try await router.openCockpit(binding: binding)
            XCTFail("Expected focus failure to stop before spawning another duplicate process")
        } catch let error as WorkBatchTaskSessionError {
            XCTAssertEqual(error, .existingSessionFocusFailed)
        }

        let focusAttempts = await focusRecorder.snapshot()
        XCTAssertEqual(focusAttempts.count, 1)
        XCTAssertEqual(focusAttempts[0].sessionName, "Mobile prototype")
        let scripts = await terminalRecorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
    }

    func testOpenCockpitFocusesVisibleStaleBindingWhenAssignedClaudeProcessExists() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale)
        let binding = try XCTUnwrap(harness.bindingStore.binding(batchID: "batch-mobile"))
        let terminalRecorder = TerminalScriptRecorder()
        let focusRecorder = ExistingTerminalFocusRecorder(result: true)
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
                focusExistingTerminal: { projectPath, sessionName in
                    await focusRecorder.record(projectPath: projectPath, sessionName: sessionName)
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { _ in ["assigned-session-existing"] },
        )

        let request = try await router.openCockpit(binding: binding)

        XCTAssertNil(request)
        let focusAttempts = await focusRecorder.snapshot()
        XCTAssertEqual(focusAttempts.count, 1)
        XCTAssertEqual(focusAttempts[0].projectPath, harness.mobileWorktreePath)
        XCTAssertEqual(focusAttempts[0].sessionName, "Mobile prototype")
        let scripts = await terminalRecorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
    }

    func testOpenCockpitResumesDoneBindingWhenOnlyLeftoverWorktreeShellCanFocus() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .idle, bindingStatus: .done, taskStatus: .done)
        let binding = try XCTUnwrap(harness.bindingStore.binding(batchID: "batch-mobile"))
        let terminalRecorder = TerminalScriptRecorder()
        let focusRecorder = ExistingTerminalFocusRecorder(result: true)
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
                focusExistingTerminal: { projectPath, sessionName in
                    await focusRecorder.record(projectPath: projectPath, sessionName: sessionName)
                },
                bindingStoreFactory: { _ in harness.bindingStore },
            ),
            processSessionIDs: { _ in [] },
        )

        let request = try await router.openCockpit(binding: binding)

        XCTAssertEqual(request?.arguments.first, "--resume")
        XCTAssertEqual(request?.arguments.dropFirst().first, "assigned-session-existing")
        let focusAttempts = await focusRecorder.snapshot()
        XCTAssertTrue(focusAttempts.isEmpty)
        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--resume"))
        XCTAssertTrue(scripts[0].contains("assigned-session-existing"))
        XCTAssertFalse(scripts[0].contains("Assessing updated tasks..."))
        XCTAssertFalse(scripts[0].contains("New task queued:"))
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

    func testDoneIngestWithQueuedTaskRunsDeliveryPolicy() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale)
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
        _ = try WorkBatchCompletionReportStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchCompletionReport(
            taskID: "idea-old",
            status: "done",
            summary: "Adjusted spacing.",
            evidence: ["Updated layout"],
            completedAt: harness.now.addingTimeInterval(10),
        ))
        let terminalRecorder = TerminalScriptRecorder()
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
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

        _ = router.ingestCompletionReports(projects: [harness.project], now: harness.now.addingTimeInterval(10))
        _ = try await router.followThroughWorkBatchDelivery(
            project: harness.project,
            batchID: "batch-mobile",
            preferredTaskID: "idea-green",
            now: harness.now.addingTimeInterval(10),
        )
        _ = try await router.followThroughWorkBatchDelivery(
            project: harness.project,
            batchID: "batch-mobile",
            preferredTaskID: "idea-green",
            now: harness.now.addingTimeInterval(10),
        )

        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--resume"))
        XCTAssertTrue(scripts[0].contains("New task queued: Add green border."))
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .launching)
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-old" })?.status, .done)
        XCTAssertEqual(updatedState.tasks.first(where: { $0.id == "idea-green" })?.status, .queued)
        XCTAssertEqual(updatedState.deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind, WorkBatchDeliveryAction.resumeExistingSession.rawValue)
        XCTAssertEqual(updatedState.batches.first?.currentActivitySummary, "Claude Code is reconnecting to Add green border.")
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

    func testUnresolveFollowThroughRunsDeliveryPolicy() async throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .idle, bindingStatus: .done)
        var state = try harness.stateStore.load()
        state.tasks[0].status = .done
        try harness.stateStore.save(state)
        _ = try WorkBatchCompletionReportStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchCompletionReport(
            taskID: "idea-old",
            status: "done",
            summary: "Adjusted spacing",
            evidence: ["Changed layout"],
            completedAt: harness.now,
        ))
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

        let result = try router.unresolveTask(
            project: harness.project,
            batchID: "batch-mobile",
            taskID: "idea-old",
            now: harness.now.addingTimeInterval(20),
        )
        _ = try await router.followThroughWorkBatchDelivery(
            project: harness.project,
            batchID: "batch-mobile",
            preferredTaskID: result.task.id,
            now: harness.now.addingTimeInterval(20),
        )

        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--resume"))
        XCTAssertTrue(scripts[0].contains("New task queued: Adjust mobile spacing."))
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .launching)
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

    func testSubmitCheckpointResponseForDoneTaskClosesStaleAttentionWithoutReopeningWork() throws {
        let harness = try RouterHarness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .waiting)
        var state = try harness.stateStore.load()
        state.tasks[0].status = .done
        state.batches[0].currentActivitySummary = "Checkpoint ready: Did Capacitor ingest the completion?"
        state.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "checkpoint-ingestion",
                batchID: "batch-mobile",
                taskID: "idea-old",
                question: "Did Capacitor ingest the completion?",
                reason: "The worker already wrote a done report.",
                recommendedAction: "Confirm the task is complete.",
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
            checkpointID: "checkpoint-ingestion",
            response: "Capacitor has ingested it; no more code changes needed.",
            now: harness.now.addingTimeInterval(20),
        )

        XCTAssertEqual(result.task.status, .done)
        XCTAssertEqual(result.checkpoint.status, .answered)
        let updatedState = try harness.stateStore.load()
        XCTAssertEqual(updatedState.tasks.first?.status, .done)
        XCTAssertEqual(updatedState.checkpoints.first?.status, .answered)
        XCTAssertEqual(updatedState.batches.first?.status, .idle)
        XCTAssertEqual(updatedState.batches.first?.currentActivitySummary, "Done: Adjust mobile spacing.")
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .done)

        let mirror = try String(
            contentsOf: URL(fileURLWithPath: harness.mobileWorktreePath)
                .appendingPathComponent(WorkBatchContextMirror.relativePath),
            encoding: .utf8,
        )
        XCTAssertTrue(mirror.contains("[done] Adjust mobile spacing (`idea-old`)"))
        XCTAssertTrue(mirror.contains("[answered] Did Capacitor ingest the completion? (`checkpoint-ingestion`, Task `idea-old`)"))
    }

    func testCheckpointResponseFollowThroughRunsDeliveryPolicy() async throws {
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
                recommendedAction: "Use the production green token.",
                status: .pending,
                requestedAt: harness.now,
                respondedAt: nil,
                response: nil,
                updatedAt: harness.now,
            ),
        ]
        try harness.stateStore.save(state)
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

        let result = try router.submitCheckpointResponse(
            project: harness.project,
            batchID: "batch-mobile",
            checkpointID: "checkpoint-green-token",
            response: "Use the production green token.",
            now: harness.now.addingTimeInterval(20),
        )
        _ = try await router.followThroughWorkBatchDelivery(
            project: harness.project,
            batchID: "batch-mobile",
            preferredTaskID: result.task.id,
            now: harness.now.addingTimeInterval(20),
        )

        let scripts = await terminalRecorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--resume"))
        XCTAssertTrue(scripts[0].contains("New task queued: Adjust mobile spacing."))
        XCTAssertEqual(try harness.bindingStore.binding(batchID: "batch-mobile")?.status, .launching)
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
        taskStatus: WorkBatchTaskStatus = .working,
        deliveryRecords: [WorkBatchDeliveryRecord] = [],
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
                    status: taskStatus,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
            deliveryRecords: deliveryRecords,
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

    func runtimeSession(
        sessionId: String,
        cwd: String,
        state: String = "working",
        toolsInFlight: Int? = nil,
        stateSource: RuntimeStateSource? = nil,
        gcReason: String? = nil,
        isAlive: Bool? = true,
    ) -> RuntimeSession {
        RuntimeSession(
            sessionId: sessionId,
            pid: 1234,
            state: state,
            cwd: cwd,
            projectId: nil,
            workspaceId: nil,
            projectPath: cwd,
            updatedAt: "2026-05-25T00:00:00Z",
            stateChangedAt: "2026-05-25T00:00:00Z",
            lastEvent: nil,
            lastActivityAt: nil,
            toolsInFlight: toolsInFlight,
            stateSource: stateSource,
            lastAuthoritativeEventAt: nil,
            gcReason: gcReason,
            isAlive: isAlive,
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

private actor ExistingTerminalFocusRecorder {
    struct Attempt: Equatable {
        let projectPath: String
        let sessionName: String?
    }

    private let result: Bool
    private var attempts: [Attempt] = []

    init(result: Bool) {
        self.result = result
    }

    func record(projectPath: String, sessionName: String?) -> Bool {
        attempts.append(Attempt(projectPath: projectPath, sessionName: sessionName))
        return result
    }

    func snapshot() -> [Attempt] {
        attempts
    }
}

private actor ExistingTerminalWakeRecorder {
    struct Attempt: Equatable {
        let projectPath: String
        let sessionName: String?
        let prompt: String
    }

    private let result: Bool
    private var attempts: [Attempt] = []

    init(result: Bool) {
        self.result = result
    }

    func record(projectPath: String, sessionName: String?, prompt: String) -> Bool {
        attempts.append(Attempt(projectPath: projectPath, sessionName: sessionName, prompt: prompt))
        return result
    }

    func snapshot() -> [Attempt] {
        attempts
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
