@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class WorkBatchPreviewActionTests: XCTestCase {
    func testOpenPreviewWithoutBindingWritesUnavailableWithoutRunningPreview() async throws {
        let harness = try PreviewActionHarness()
        try harness.seedBatch(withBinding: false)
        var didRunPreview = false
        let router = harness.router(
            previewRunner: { _ in
                didRunPreview = true
                throw NSError(domain: "test", code: 1)
            },
        )

        let record = try await router.openPreview(
            project: harness.project,
            batchID: "batch-mobile",
            now: harness.now,
        )

        XCTAssertFalse(didRunPreview)
        XCTAssertEqual(record.status, .previewUnavailable)
        XCTAssertEqual(record.failureReason, "No batch worktree yet")
        XCTAssertEqual(try harness.previewStore.record(batchID: "batch-mobile"), record)
    }

    func testOpenPreviewBuildsFromBatchWorktreeAndStoresReadyProof() async throws {
        let harness = try PreviewActionHarness()
        try harness.seedBatch(withBinding: true)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot)
        var capturedRequest: MacOSPreviewWorkRequest?
        var changedStatuses: [WorkBatchPreviewStatus] = []
        let router = harness.router(
            previewRunner: { request in
                capturedRequest = request
                return MacOSPreviewWorkProof(
                    status: .readyToInspect,
                    appPath: request.appURL.path,
                    bundleID: request.expectedBundleID,
                    displayName: request.expectedDisplayName,
                    pid: 777,
                    launchTime: harness.now,
                    worktreePath: request.worktreeURL.path,
                    gitHead: "abc123",
                    dirtyState: "clean",
                    buildCommand: "build",
                    buildLogPath: request.buildLogURL.path,
                    expectedBundleID: request.expectedBundleID,
                    expectedDisplayName: request.expectedDisplayName,
                    failureReason: nil,
                    recordedAt: harness.now,
                )
            },
        )

        let record = try await router.openPreview(
            project: harness.project,
            batchID: "batch-mobile",
            now: harness.now,
            onRecordChanged: { record in
                changedStatuses.append(record.status)
            },
        )

        XCTAssertEqual(capturedRequest?.worktreeURL.path, harness.worktreeRoot.path)
        XCTAssertEqual(
            capturedRequest?.buildScriptURL.path,
            harness.projectRoot.appendingPathComponent("scripts/dev/build-preview-app.sh").path,
        )
        XCTAssertEqual(capturedRequest?.proofURL.path, harness.previewStore.proofURL(batchID: "batch-mobile").path)
        XCTAssertEqual(capturedRequest?.buildLogURL.path, harness.previewStore.buildLogURL(batchID: "batch-mobile").path)
        XCTAssertEqual(record.status, .readyToInspect)
        XCTAssertEqual(record.pid, 777)
        XCTAssertEqual(record.worktreePath, PathNormalizer.normalize(harness.worktreeRoot.path))
        XCTAssertEqual(try harness.previewStore.record(batchID: "batch-mobile"), record)
        XCTAssertEqual(changedStatuses, [.previewBuilding, .readyToInspect])
    }

    func testOpenPreviewActivatesExistingMatchingReadyPreviewWithoutRebuilding() async throws {
        let harness = try PreviewActionHarness()
        try harness.seedBatch(withBinding: true)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot)
        let existingRecord = harness.readyPreviewRecord()
        try harness.previewStore.upsert(existingRecord)
        var didRunPreview = false
        var activatedRecord: WorkBatchPreviewRecord?
        let router = harness.router(
            previewRunner: { _ in
                didRunPreview = true
                throw NSError(domain: "test", code: 1)
            },
            previewActivator: { record in
                activatedRecord = record
                return true
            },
            previewRunningMatcher: { _ in true },
        )

        let record = try await router.openPreview(
            project: harness.project,
            batchID: "batch-mobile",
            now: harness.now,
        )

        XCTAssertFalse(didRunPreview)
        XCTAssertEqual(activatedRecord, existingRecord)
        XCTAssertEqual(record, existingRecord)
    }

    func testOpenPreviewDoesNotRebuildWhenMatchingReadyPreviewActivationFails() async throws {
        let harness = try PreviewActionHarness()
        try harness.seedBatch(withBinding: true)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot)
        let existingRecord = harness.readyPreviewRecord()
        try harness.previewStore.upsert(existingRecord)
        var didRunPreview = false
        let router = harness.router(
            previewRunner: { _ in
                didRunPreview = true
                return existingRecord.asProof()
            },
            previewActivator: { _ in false },
            previewRunningMatcher: { _ in true },
        )

        let record = try await router.openPreview(
            project: harness.project,
            batchID: "batch-mobile",
            now: harness.now,
        )

        XCTAssertFalse(didRunPreview)
        XCTAssertEqual(record, existingRecord)
        XCTAssertEqual(try harness.previewStore.record(batchID: "batch-mobile"), existingRecord)
    }

    func testOpenPreviewFailurePreservesFailedRecord() async throws {
        let harness = try PreviewActionHarness()
        try harness.seedBatch(withBinding: true)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot)
        let router = harness.router(
            previewRunner: { request in
                MacOSPreviewWorkProof(
                    status: .previewFailed,
                    appPath: request.appURL.path,
                    bundleID: request.expectedBundleID,
                    displayName: request.expectedDisplayName,
                    pid: nil,
                    launchTime: nil,
                    worktreePath: request.worktreeURL.path,
                    gitHead: "abc123",
                    dirtyState: "dirty",
                    buildCommand: "build",
                    buildLogPath: request.buildLogURL.path,
                    expectedBundleID: request.expectedBundleID,
                    expectedDisplayName: request.expectedDisplayName,
                    failureReason: "Preview build failed with exit 1.",
                    recordedAt: harness.now,
                )
            },
        )

        let record = try await router.openPreview(
            project: harness.project,
            batchID: "batch-mobile",
            now: harness.now,
        )

        XCTAssertEqual(record.status, .previewFailed)
        XCTAssertEqual(record.failureReason, "Preview build failed with exit 1.")

        let state = try harness.stateStore.load()
        XCTAssertEqual(state.batches.first?.status, .working)
        XCTAssertEqual(state.tasks.first?.status, .working)
    }
}

private final class PreviewActionHarness {
    let fileManager = FileManager.default
    let tempDir: URL
    let projectRoot: URL
    let worktreeRoot: URL
    let stateStore: WorkBatchStateStore
    let bindingStore: WorkBatchCockpitBindingStore
    let previewStore: WorkBatchPreviewStateStore
    let now = Date(timeIntervalSince1970: 1_775_000_000)

    var project: Project {
        Project(
            name: "Capacitor",
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
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("WorkBatchPreviewActionTests-\(UUID().uuidString)", isDirectory: true)
        projectRoot = tempDir.appendingPathComponent("capacitor", isDirectory: true)
        worktreeRoot = projectRoot.appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        stateStore = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        bindingStore = WorkBatchCockpitBindingStore(
            fileURL: tempDir.appendingPathComponent("bindings.json"),
            fileManager: fileManager,
        )
        previewStore = WorkBatchPreviewStateStore(
            fileURL: tempDir.appendingPathComponent("previews.json"),
            fileManager: fileManager,
        )
        try makeCapacitorPreviewCapable(at: projectRoot)
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
    }

    @MainActor
    func router(
        previewRunner: @escaping WorkBatchAutoRouter.PreviewRunner,
        previewActivator: WorkBatchAutoRouter.PreviewActivator? = nil,
        previewRunningMatcher: WorkBatchAutoRouter.PreviewRunningMatcher? = nil,
    ) -> WorkBatchAutoRouter {
        WorkBatchAutoRouter(
            stateStoreFactory: { _ in self.stateStore },
            bindingStoreFactory: { _ in self.bindingStore },
            previewStoreFactory: { _ in self.previewStore },
            previewRunner: previewRunner,
            previewActivator: previewActivator,
            previewRunningMatcher: previewRunningMatcher,
            previewProjector: WorkBatchPreviewProjector(fileManager: fileManager),
        )
    }

    func seedBatch(withBinding: Bool) throws {
        try stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: projectRoot.path,
                    status: .working,
                    currentActivitySummary: "Working on mobile prototype.",
                    taskIDs: ["task-mobile"],
                    cockpitBindingID: withBinding ? "batch-mobile" : nil,
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-mobile",
                    sourceIdeaID: "task-mobile",
                    title: "Adjust mobile preview",
                    body: "",
                    status: .working,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        ))

        guard withBinding else { return }
        try fileManager.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        try bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: projectRoot.path,
            worktreeName: "batch-mobile",
            worktreePath: worktreeRoot.path,
            host: .claudeCode,
            claudeSessionID: "session-mobile",
            status: .running,
            createdAt: now,
            updatedAt: now,
        ))
    }

    func makeCapacitorPreviewCapable(at rootURL: URL) throws {
        let requiredFiles = [
            "scripts/dev/build-preview-app.sh",
            "apps/swift/Package.swift",
            "apps/swift/Sources/Capacitor/App.swift",
        ]
        for relativePath in requiredFiles {
            let url = rootURL.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    func readyPreviewRecord() -> WorkBatchPreviewRecord {
        WorkBatchPreviewRecord(
            id: "batch-mobile",
            batchID: "batch-mobile",
            projectPath: projectRoot.path,
            worktreePath: PathNormalizer.normalize(worktreeRoot.path),
            status: .readyToInspect,
            appPath: worktreeRoot.appendingPathComponent("apps/swift/CapacitorPreview.app").path,
            bundleID: "com.capacitor.app.preview",
            displayName: "Capacitor Preview",
            pid: 777,
            proofPath: previewStore.proofURL(batchID: "batch-mobile").path,
            buildLogPath: previewStore.buildLogURL(batchID: "batch-mobile").path,
            failureReason: nil,
            updatedAt: now,
        )
    }
}

private extension WorkBatchPreviewRecord {
    func asProof() -> MacOSPreviewWorkProof {
        MacOSPreviewWorkProof(
            status: .readyToInspect,
            appPath: appPath,
            bundleID: bundleID,
            displayName: displayName,
            pid: pid,
            launchTime: updatedAt,
            worktreePath: worktreePath ?? projectPath,
            gitHead: "abc123",
            dirtyState: "clean",
            buildCommand: "build",
            buildLogPath: buildLogPath ?? "/tmp/build.log",
            expectedBundleID: bundleID ?? "com.capacitor.app.preview",
            expectedDisplayName: displayName ?? "Capacitor Preview",
            failureReason: nil,
            recordedAt: updatedAt,
        )
    }
}
