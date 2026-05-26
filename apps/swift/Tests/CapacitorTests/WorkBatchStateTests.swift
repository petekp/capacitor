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
        )
        snapshot.recordDeliveryAttempt(
            batchID: "batch-mobile",
            attemptedAt: now.addingTimeInterval(1),
            kind: "resume_existing_session",
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
