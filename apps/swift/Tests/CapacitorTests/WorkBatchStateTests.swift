@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchStateTests: XCTestCase {
    func testStateStorePersistsBatchesTasksClassificationsAndCheckpoints() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: "/tmp/project",
                    status: .working,
                    currentActivitySummary: "Adding a green border.",
                    taskIDs: ["task-1"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-1",
                    sourceIdeaID: "idea-1",
                    title: "Add green border",
                    body: "Around the mobile prototype.",
                    status: .working,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [
                .existing(
                    taskID: "task-1",
                    batchID: "batch-mobile",
                    confidence: 0.91,
                    rationale: "Same prototype work.",
                    summary: "Added to Mobile prototype.",
                    createdAt: now,
                ),
            ],
            checkpoints: [
                WorkBatchCheckpointRecord(
                    id: "checkpoint-green-token",
                    batchID: "batch-mobile",
                    taskID: "task-1",
                    question: "Which green token should I use?",
                    reason: "There are multiple green tokens.",
                    recommendedAction: "Use production if this is user-facing.",
                    status: .pending,
                    requestedAt: now,
                    respondedAt: nil,
                    response: nil,
                    updatedAt: now,
                ),
            ],
            deliveryRecords: [
                WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: now,
                    lastDeliveryGeneration: "batch-mobile:1775000000",
                    lastDeliveryAttemptAt: now.addingTimeInterval(1),
                    lastDeliveryAttemptKind: "resume_existing_session",
                    lastClaimAt: now.addingTimeInterval(2),
                    lastActionableContextDigest: "actionable-digest",
                    lastDeliveryAttemptDigest: "actionable-digest",
                ),
            ],
        )

        let store = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)
    }

    func testStateStoreLoadsOlderSnapshotsWithoutCheckpoints() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let storeURL = tempDir.appendingPathComponent("state.json")
        try """
        {
          "version": 1,
          "batches": [],
          "tasks": [],
          "classifications": []
        }
        """.write(to: storeURL, atomically: true, encoding: .utf8)

        let store = WorkBatchStateStore(fileURL: storeURL, fileManager: fileManager)

        XCTAssertEqual(try store.load().checkpoints, [])
        XCTAssertEqual(try store.load().deliveryRecords, [])
    }

    func testStateStoreLoadsOlderBatchesWithoutAttentionReasonAsNone() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        // A batch written before the T2 teardown has no `attention_reason` key.
        // It must decode to `.none` rather than failing the whole snapshot.
        let storeURL = tempDir.appendingPathComponent("state.json")
        try """
        {
          "version": 1,
          "batches": [
            {
              "id": "batch-mobile",
              "name": "Mobile prototype",
              "project_path": "/tmp/project",
              "status": "waiting",
              "current_activity_summary": "Multiple Claude Code sessions match this Work Batch.",
              "task_ids": ["task-green"],
              "cockpit_binding_id": "batch-mobile",
              "created_at": "2026-05-01T00:00:00Z",
              "updated_at": "2026-05-01T00:00:00Z"
            }
          ],
          "tasks": [],
          "classifications": []
        }
        """.write(to: storeURL, atomically: true, encoding: .utf8)

        let store = WorkBatchStateStore(fileURL: storeURL, fileManager: fileManager)
        let loaded = try store.load()
        XCTAssertEqual(loaded.batches.count, 1)
        XCTAssertEqual(loaded.batches.first?.attentionReason, WorkBatchAttentionReason.none)
    }

    func testStateStoreRoundTripsAttentionReasonVariants() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let reasons: [WorkBatchAttentionReason] = [
            .none,
            .duplicateCockpit(assignedProcessDuplicate: false),
            .duplicateCockpit(assignedProcessDuplicate: true),
            .pickupTimeout(taskID: "task-green", taskTitle: "Add green border"),
            .launchFailed,
            .wakeFailed,
            .deliveryFailure,
            .needsReconnect,
        ]

        let batches = reasons.enumerated().map { index, reason in
            WorkBatchRecord(
                id: "batch-\(index)",
                name: "Batch \(index)",
                projectPath: "/tmp/project",
                status: .waiting,
                currentActivitySummary: "",
                taskIDs: [],
                cockpitBindingID: nil,
                attentionReason: reason,
                createdAt: now,
                updatedAt: now,
            )
        }
        let snapshot = WorkBatchStateSnapshot(version: 1, batches: batches, tasks: [], classifications: [])
        let store = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        try store.save(snapshot)
        XCTAssertEqual(try store.load().batches.map(\.attentionReason), reasons)
    }

    func testStateStoreDecodesWakeFailedAttentionReasonFromDiskKey() throws {
        // Pin the persisted discriminator key ("wake_failed") for the new
        // attention variant restored for 3a parity. A future rename would break
        // round-trip silently otherwise.
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fileManager.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("state.json")
        try """
        {
          "version": 1,
          "batches": [
            {
              "id": "batch-mobile",
              "name": "Mobile prototype",
              "project_path": "/tmp/project",
              "status": "waiting",
              "current_activity_summary": "",
              "task_ids": [],
              "cockpit_binding_id": null,
              "attention_reason": { "kind": "wake_failed" },
              "created_at": "2026-05-01T00:00:00Z",
              "updated_at": "2026-05-01T00:00:00Z"
            }
          ],
          "tasks": [],
          "classifications": []
        }
        """.write(to: storeURL, atomically: true, encoding: .utf8)

        let loaded = try WorkBatchStateStore(fileURL: storeURL, fileManager: fileManager).load()
        XCTAssertEqual(loaded.batches.first?.attentionReason, WorkBatchAttentionReason.wakeFailed)
    }

    func testStateStoreDecodesUnknownAttentionReasonKindAsNoneWithoutThrowing() throws {
        // FORWARD-COMPAT (finding 4 of the parity re-review): attentionReason is
        // a LOCAL persisted enum, not a wire-status contract. A state file
        // written by a NEWER build may carry an attention kind this build does
        // not recognize. Decoding must degrade that to `.none` rather than
        // throwing and failing the whole snapshot load, so an older build can
        // still open a newer state file. The rest of the snapshot must load.
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fileManager.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("state.json")
        try """
        {
          "version": 1,
          "batches": [
            {
              "id": "batch-mobile",
              "name": "Mobile prototype",
              "project_path": "/tmp/project",
              "status": "waiting",
              "current_activity_summary": "Working on something.",
              "task_ids": ["task-green"],
              "cockpit_binding_id": "batch-mobile",
              "attention_reason": { "kind": "some_future_reason" },
              "created_at": "2026-05-01T00:00:00Z",
              "updated_at": "2026-05-01T00:00:00Z"
            }
          ],
          "tasks": [
            {
              "id": "task-green",
              "source_idea_id": "task-green",
              "title": "Add green border",
              "body": "",
              "status": "queued",
              "batch_id": "batch-mobile",
              "created_at": "2026-05-01T00:00:00Z",
              "updated_at": "2026-05-01T00:00:00Z"
            }
          ],
          "classifications": []
        }
        """.write(to: storeURL, atomically: true, encoding: .utf8)

        let loaded = try WorkBatchStateStore(fileURL: storeURL, fileManager: fileManager).load()
        XCTAssertEqual(loaded.batches.count, 1)
        XCTAssertEqual(loaded.batches.first?.attentionReason, WorkBatchAttentionReason.none)
        // Rest of the snapshot still loads.
        XCTAssertEqual(loaded.tasks.count, 1)
        XCTAssertEqual(loaded.tasks.first?.id, "task-green")
        XCTAssertEqual(loaded.batches.first?.currentActivitySummary, "Working on something.")
    }

    func testStateStorePersistsDeliveryRecords() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let now = Date(timeIntervalSince1970: 1_775_000_000)
        var snapshot = WorkBatchStateSnapshot.empty
        snapshot.recordContextWrite(
            batchID: "batch-mobile",
            updatedAt: now,
            deliveryGeneration: "batch-mobile:1775000000",
            actionableContextDigest: "actionable-digest",
        )
        snapshot.recordDeliveryAttempt(
            batchID: "batch-mobile",
            attemptedAt: now.addingTimeInterval(1),
            kind: "resume_existing_session",
            actionableContextDigest: "actionable-digest",
        )
        snapshot.recordTaskClaim(
            batchID: "batch-mobile",
            claimedAt: now.addingTimeInterval(2),
        )

        let store = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(
            try store.load().deliveryRecord(batchID: "batch-mobile")?.lastDeliveryGeneration,
            "batch-mobile:1775000000",
        )
        XCTAssertEqual(
            try store.load().deliveryRecord(batchID: "batch-mobile")?.lastActionableContextDigest,
            "actionable-digest",
        )
        XCTAssertEqual(
            try store.load().deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptDigest,
            "actionable-digest",
        )
    }

    func testProjectionSortsRecentlyUpdatedBatchesAndCountsQueuedTasks() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 200)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                batch(id: "batch-old", name: "Old", updatedAt: old),
                batch(id: "batch-new", name: "New", updatedAt: recent),
            ],
            tasks: [
                task(id: "task-1", batchID: "batch-new", status: .queued),
                task(id: "task-2", batchID: "batch-new", status: .done),
                task(id: "task-3", batchID: "batch-old", status: .working),
            ],
            classifications: [],
        )

        let projections = WorkBatchProjectionBuilder.build(state: state, bindings: [
            WorkBatchCockpitBinding(
                id: "batch-new",
                batchID: "batch-new",
                batchName: "New",
                projectPath: "/tmp/project",
                worktreeName: "batch-new",
                worktreePath: "/tmp/project/.capacitor/worktrees/batch-new",
                host: .claudeCode,
                claudeSessionID: "session-new",
                status: .running,
                createdAt: recent,
                updatedAt: recent,
            ),
        ])

        XCTAssertEqual(projections.map(\.id), ["batch-new", "batch-old"])
        XCTAssertEqual(projections[0].queuedTaskCount, 1)
        XCTAssertEqual(projections[0].binding?.claudeSessionID, "session-new")
        XCTAssertEqual(projections[1].queuedTaskCount, 0)
    }

    func testProjectionUsesTaskBodyWhenStoredTitleIsStillPlaceholder() {
        let now = Date(timeIntervalSince1970: 100)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile Prototype Polish",
                    projectPath: "/tmp/project",
                    status: .working,
                    currentActivitySummary: "Claude Code is starting on ....",
                    taskIDs: ["task-1"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-1",
                    sourceIdeaID: "idea-1",
                    title: "...",
                    body: "add a green border around the mobile prototype",
                    status: .working,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        )

        let projections = WorkBatchProjectionBuilder.build(state: state, bindings: [])

        XCTAssertEqual(
            projections[0].currentActivitySummary,
            "Claude Code is starting on add a green border around the mobile prototype.",
        )
        XCTAssertEqual(projections[0].tasks[0].displayTitle, "add a green border around the mobile prototype")
    }

    func testProjectionPrioritizesWaitingAndQueuedWorkBeforeOlderWorkingSummaries() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 300)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-working",
                    name: "Footer Fix",
                    projectPath: "/tmp/project",
                    status: .working,
                    currentActivitySummary: "Fixed footer responsive breakpoint bug",
                    taskIDs: ["task-footer"],
                    cockpitBindingID: nil,
                    createdAt: recent,
                    updatedAt: recent,
                ),
                WorkBatchRecord(
                    id: "batch-queued",
                    name: "Mobile Prototype Polish",
                    projectPath: "/tmp/project",
                    status: .working,
                    currentActivitySummary: "Queued Add green border in Mobile Prototype Polish.",
                    taskIDs: ["task-green"],
                    cockpitBindingID: nil,
                    createdAt: old,
                    updatedAt: old,
                ),
                WorkBatchRecord(
                    id: "batch-waiting",
                    name: "Recovery",
                    projectPath: "/tmp/project",
                    status: .waiting,
                    currentActivitySummary: "Claude Code session needs reconnect.",
                    taskIDs: ["task-recovery"],
                    cockpitBindingID: nil,
                    createdAt: old,
                    updatedAt: old,
                ),
            ],
            tasks: [
                task(id: "task-footer", batchID: "batch-working", status: .working),
                task(id: "task-green", batchID: "batch-queued", status: .queued),
                task(id: "task-recovery", batchID: "batch-waiting", status: .queued),
            ],
            classifications: [],
        )

        let projections = WorkBatchProjectionBuilder.build(state: state, bindings: [])

        XCTAssertEqual(projections.map(\.id), ["batch-waiting", "batch-queued", "batch-working"])
    }

    func testProjectionSummaryMentionsQueuedTaskWhenNotClaimed() {
        let now = Date(timeIntervalSince1970: 100)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile Prototype Polish",
                    projectPath: "/tmp/project",
                    status: .working,
                    currentActivitySummary: "Fixed footer responsive breakpoint bug",
                    taskIDs: ["task-green"],
                    cockpitBindingID: nil,
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: .queued,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        )

        let projection = WorkBatchProjectionBuilder.build(state: state, bindings: [])[0]

        XCTAssertEqual(projection.currentActivitySummary, "Queued Add green border.")
    }

    func testProjectionSummaryPrefersClaimedWorkingTaskAndQueuedCount() {
        let now = Date(timeIntervalSince1970: 100)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile Prototype Polish",
                    projectPath: "/tmp/project",
                    status: .working,
                    currentActivitySummary: "Queued Add green border in Mobile Prototype Polish.",
                    taskIDs: ["task-spacing", "task-green"],
                    cockpitBindingID: nil,
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-spacing",
                    sourceIdeaID: "task-spacing",
                    title: "Adjust mobile spacing",
                    body: "",
                    status: .working,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: .queued,
                    batchID: "batch-mobile",
                    createdAt: now.addingTimeInterval(1),
                    updatedAt: now.addingTimeInterval(1),
                ),
            ],
            classifications: [],
        )

        let projection = WorkBatchProjectionBuilder.build(state: state, bindings: [])[0]

        XCTAssertEqual(projection.currentActivitySummary, "Working on Adjust mobile spacing. 1 queued.")
    }

    func testProjectionSummaryAvoidsSelfReferentialWorkingFallbackAfterTasksAreDone() {
        let now = Date(timeIntervalSince1970: 100)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "some kind of menu bar has become visible at the",
                    projectPath: "/tmp/project",
                    status: .working,
                    currentActivitySummary: "Claude Code is working in some kind of menu bar has become visible at the.",
                    taskIDs: ["task-menu"],
                    cockpitBindingID: nil,
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-menu",
                    sourceIdeaID: "task-menu",
                    title: "Fix the stray menu bar artifact",
                    body: "",
                    status: .done,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        )

        let projection = WorkBatchProjectionBuilder.build(state: state, bindings: [])[0]

        XCTAssertEqual(projection.currentActivitySummary, "Checking final result.")
    }

    func testProjectionSummaryCleansLegacyGenericDoneSummary() {
        let now = Date(timeIntervalSince1970: 100)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile Prototype Polish",
                    projectPath: "/tmp/project",
                    status: .idle,
                    currentActivitySummary: "Done: all Tasks completed.",
                    taskIDs: ["task-green"],
                    cockpitBindingID: nil,
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: .done,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        )

        let projection = WorkBatchProjectionBuilder.build(state: state, bindings: [])[0]

        XCTAssertEqual(projection.currentActivitySummary, "Done: Add green border.")
    }

    func testProjectionCarriesPendingCheckpoints() {
        let now = Date(timeIntervalSince1970: 100)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile Prototype Polish",
                    projectPath: "/tmp/project",
                    status: .waiting,
                    currentActivitySummary: "Checkpoint ready: Which green token should I use?",
                    taskIDs: ["task-green"],
                    cockpitBindingID: nil,
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                task(id: "task-green", batchID: "batch-mobile", status: .needsYou),
            ],
            classifications: [],
            checkpoints: [
                WorkBatchCheckpointRecord(
                    id: "checkpoint-answered",
                    batchID: "batch-mobile",
                    taskID: "task-green",
                    question: "How wide should the border be?",
                    reason: "No width was specified.",
                    recommendedAction: nil,
                    status: .answered,
                    requestedAt: now,
                    respondedAt: now.addingTimeInterval(20),
                    response: "Use 2px.",
                    updatedAt: now.addingTimeInterval(20),
                ),
                WorkBatchCheckpointRecord(
                    id: "checkpoint-pending",
                    batchID: "batch-mobile",
                    taskID: "task-green",
                    question: "Which green token should I use?",
                    reason: "There are multiple green tokens.",
                    recommendedAction: nil,
                    status: .pending,
                    requestedAt: now.addingTimeInterval(10),
                    respondedAt: nil,
                    response: nil,
                    updatedAt: now.addingTimeInterval(10),
                ),
            ],
        )

        let projection = WorkBatchProjectionBuilder.build(state: state, bindings: [])[0]

        XCTAssertEqual(projection.pendingCheckpoints.map(\.id), ["checkpoint-pending"])
        XCTAssertEqual(projection.checkpoints.map(\.id), ["checkpoint-pending", "checkpoint-answered"])
    }

    func testProjectContextSummaryUsesLatestIdleBatchInsteadOfFallingBackToLegacyText() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 200)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-old",
                    name: "Old done",
                    projectPath: "/tmp/project",
                    status: .idle,
                    currentActivitySummary: "Done: Older work.",
                    taskIDs: ["task-old"],
                    cockpitBindingID: nil,
                    createdAt: old,
                    updatedAt: old,
                ),
                WorkBatchRecord(
                    id: "batch-recent",
                    name: "Recent done",
                    projectPath: "/tmp/project",
                    status: .idle,
                    currentActivitySummary: "Done: Softened mobile prototype border.",
                    taskIDs: ["task-recent"],
                    cockpitBindingID: nil,
                    createdAt: recent,
                    updatedAt: recent,
                ),
            ],
            tasks: [
                task(id: "task-old", batchID: "batch-old", status: .done),
                task(id: "task-recent", batchID: "batch-recent", status: .done),
            ],
            classifications: [],
        )
        let projections = WorkBatchProjectionBuilder.build(state: state, bindings: [])

        XCTAssertEqual(
            WorkBatchProjectContextSummaryResolver.resolve(projections),
            "Done: Softened mobile prototype border.",
        )
    }

    func testProjectVisualStateElevatesPendingCheckpointEvenWhenBatchIsIdle() {
        let now = Date(timeIntervalSince1970: 100)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile Prototype Polish",
                    projectPath: "/tmp/project",
                    status: .idle,
                    currentActivitySummary: "Checkpoint ready: Which green token should I use?",
                    taskIDs: ["task-green"],
                    cockpitBindingID: nil,
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                task(id: "task-green", batchID: "batch-mobile", status: .needsYou),
            ],
            classifications: [],
            checkpoints: [
                WorkBatchCheckpointRecord(
                    id: "checkpoint-green-token",
                    batchID: "batch-mobile",
                    taskID: "task-green",
                    question: "Which green token should I use?",
                    reason: "There are multiple green tokens.",
                    recommendedAction: nil,
                    status: .pending,
                    requestedAt: now,
                    respondedAt: nil,
                    response: nil,
                    updatedAt: now,
                ),
            ],
        )
        let projections = WorkBatchProjectionBuilder.build(state: state, bindings: [])

        XCTAssertEqual(WorkBatchProjectVisualStateResolver.resolve(projections), .waiting)
    }

    func testProjectVisualStateUsesFirstActiveBatchStatus() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 200)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-idle",
                    name: "Done",
                    projectPath: "/tmp/project",
                    status: .idle,
                    currentActivitySummary: "Done: Older work.",
                    taskIDs: ["task-done"],
                    cockpitBindingID: nil,
                    createdAt: recent,
                    updatedAt: recent,
                ),
                WorkBatchRecord(
                    id: "batch-working",
                    name: "Mobile Prototype Polish",
                    projectPath: "/tmp/project",
                    status: .working,
                    currentActivitySummary: "Working on Add green border.",
                    taskIDs: ["task-green"],
                    cockpitBindingID: nil,
                    createdAt: old,
                    updatedAt: old,
                ),
            ],
            tasks: [
                task(id: "task-done", batchID: "batch-idle", status: .done),
                task(id: "task-green", batchID: "batch-working", status: .working),
            ],
            classifications: [],
        )
        let projections = WorkBatchProjectionBuilder.build(state: state, bindings: [])

        XCTAssertEqual(WorkBatchProjectVisualStateResolver.resolve(projections), .working)
    }

    func testProjectVisualStateIgnoresIdleDoneBatches() {
        let now = Date(timeIntervalSince1970: 100)
        let state = WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-done",
                    name: "Done",
                    projectPath: "/tmp/project",
                    status: .idle,
                    currentActivitySummary: "Done: Softened mobile prototype border.",
                    taskIDs: ["task-done"],
                    cockpitBindingID: nil,
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                task(id: "task-done", batchID: "batch-done", status: .done),
            ],
            classifications: [],
        )
        let projections = WorkBatchProjectionBuilder.build(state: state, bindings: [])

        XCTAssertNil(WorkBatchProjectVisualStateResolver.resolve(projections))
    }

    private func batch(id: String, name: String, updatedAt: Date) -> WorkBatchRecord {
        WorkBatchRecord(
            id: id,
            name: name,
            projectPath: "/tmp/project",
            status: .working,
            currentActivitySummary: "Working",
            taskIDs: [],
            cockpitBindingID: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
        )
    }

    private func task(id: String, batchID: String, status: WorkBatchTaskStatus) -> WorkBatchTaskRecord {
        WorkBatchTaskRecord(
            id: id,
            sourceIdeaID: id,
            title: id,
            body: "",
            status: status,
            batchID: batchID,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
        )
    }
}
