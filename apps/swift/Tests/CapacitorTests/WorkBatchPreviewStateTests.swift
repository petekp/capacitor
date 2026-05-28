@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchPreviewStateTests: XCTestCase {
    func testPreviewStoreRoundTripsRecords() throws {
        let harness = try PreviewHarness()
        let store = WorkBatchPreviewStateStore(
            fileURL: harness.tempDir.appendingPathComponent("previews.json"),
            fileManager: harness.fileManager,
        )
        let record = previewRecord(
            batchID: "batch-mobile",
            projectPath: harness.projectRoot.path,
            worktreePath: harness.worktreeRoot.path,
            status: .readyToInspect,
            updatedAt: harness.now,
        )

        try store.upsert(record)

        XCTAssertEqual(try store.load(), [record])
        XCTAssertEqual(try store.record(batchID: "batch-mobile"), record)
    }

    func testMissingPreviewStoreLoadsEmptyRecords() throws {
        let harness = try PreviewHarness()
        let store = WorkBatchPreviewStateStore(
            fileURL: harness.tempDir.appendingPathComponent("missing/previews.json"),
            fileManager: harness.fileManager,
        )

        XCTAssertEqual(try store.load(), [])
    }

    func testProofMapsToPreviewRecord() throws {
        let harness = try PreviewHarness()
        let proof = MacOSPreviewWorkProof(
            status: .readyToInspect,
            appPath: harness.worktreeRoot.appendingPathComponent("apps/swift/CapacitorPreview.app").path,
            bundleID: "com.capacitor.app.preview",
            displayName: "Capacitor Preview",
            pid: 42,
            launchTime: harness.now,
            worktreePath: harness.worktreeRoot.path,
            gitHead: "abc123",
            dirtyState: "clean",
            sourceFingerprint: "fingerprint-current",
            buildCommand: "build",
            buildLogPath: harness.tempDir.appendingPathComponent("build.log").path,
            expectedBundleID: "com.capacitor.app.preview",
            expectedDisplayName: "Capacitor Preview",
            failureReason: nil,
            recordedAt: harness.now,
        )

        let record = WorkBatchPreviewRecord.fromProof(
            proof,
            batchID: "batch-mobile",
            projectPath: harness.projectRoot.path,
            proofPath: harness.tempDir.appendingPathComponent("proof.json").path,
            updatedAt: harness.now,
        )

        XCTAssertEqual(record.status, .readyToInspect)
        XCTAssertEqual(record.batchID, "batch-mobile")
        XCTAssertEqual(record.worktreePath, PathNormalizer.normalize(harness.worktreeRoot.path))
        XCTAssertEqual(record.pid, 42)
        XCTAssertEqual(record.proofPath, harness.tempDir.appendingPathComponent("proof.json").path)
    }

    func testNonCapacitorProjectDoesNotExposePreviewProjection() throws {
        let harness = try PreviewHarness()
        let projector = WorkBatchPreviewProjector(fileManager: harness.fileManager)

        XCTAssertNil(projector.projection(
            projectPath: harness.projectRoot.path,
            batch: batch(projectPath: harness.projectRoot.path),
            binding: nil,
            previewRecord: nil,
        ))
    }

    func testCapacitorProjectWithoutBindingShowsUnavailablePreview() throws {
        let harness = try PreviewHarness()
        try harness.makeCapacitorPreviewCapable(at: harness.projectRoot)
        let projector = WorkBatchPreviewProjector(fileManager: harness.fileManager)

        let projection = try XCTUnwrap(projector.projection(
            projectPath: harness.projectRoot.path,
            batch: batch(projectPath: harness.projectRoot.path),
            binding: nil,
            previewRecord: nil,
        ))

        XCTAssertEqual(projection.label, "Preview unavailable")
        XCTAssertFalse(projection.isActionEnabled)
        XCTAssertEqual(projection.reason, "No batch worktree yet")
    }

    func testCapacitorBatchWithBindingAndNoProofShowsAvailablePreview() throws {
        let harness = try PreviewHarness()
        try harness.makeCapacitorPreviewCapable(at: harness.projectRoot)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot)
        let projector = WorkBatchPreviewProjector(
            fileManager: harness.fileManager,
            isPreviewIdentityRunning: { _ in false },
        )

        let projection = try XCTUnwrap(projector.projection(
            projectPath: harness.projectRoot.path,
            batch: batch(projectPath: harness.projectRoot.path),
            binding: binding(projectPath: harness.projectRoot.path, worktreePath: harness.worktreeRoot.path),
            previewRecord: nil,
        ))

        XCTAssertEqual(projection.label, "Preview available")
        XCTAssertTrue(projection.isActionEnabled)
        XCTAssertEqual(projection.actionLabel, "Open Preview")
    }

    func testCapacitorBatchWorktreeDoesNotNeedItsOwnBuildScript() throws {
        let harness = try PreviewHarness()
        try harness.makeCapacitorPreviewCapable(at: harness.projectRoot)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot, includeBuildScript: false)
        let projector = WorkBatchPreviewProjector(
            fileManager: harness.fileManager,
            isPreviewIdentityRunning: { _ in false },
        )

        let projection = try XCTUnwrap(projector.projection(
            projectPath: harness.projectRoot.path,
            batch: batch(projectPath: harness.projectRoot.path),
            binding: binding(projectPath: harness.projectRoot.path, worktreePath: harness.worktreeRoot.path),
            previewRecord: nil,
        ))

        XCTAssertEqual(projection.label, "Preview available")
        XCTAssertTrue(projection.isActionEnabled)
        XCTAssertEqual(projection.actionLabel, "Open Preview")
    }

    func testStaleUnavailableRecordDoesNotLeakReasonAfterWorktreeBecomesPreviewCapable() throws {
        let harness = try PreviewHarness()
        try harness.makeCapacitorPreviewCapable(at: harness.projectRoot)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot, includeBuildScript: false)
        let record = previewRecord(
            batchID: "batch-mobile",
            projectPath: harness.projectRoot.path,
            worktreePath: nil,
            status: .previewUnavailable,
            failureReason: "No batch worktree yet",
            updatedAt: harness.now,
        )
        let projector = WorkBatchPreviewProjector(
            fileManager: harness.fileManager,
            isPreviewIdentityRunning: { _ in false },
        )

        let projection = try XCTUnwrap(projector.projection(
            projectPath: harness.projectRoot.path,
            batch: batch(projectPath: harness.projectRoot.path),
            binding: binding(projectPath: harness.projectRoot.path, worktreePath: harness.worktreeRoot.path),
            previewRecord: record,
        ))

        XCTAssertEqual(projection.label, "Preview available")
        XCTAssertTrue(projection.isActionEnabled)
        XCTAssertNil(projection.reason)
    }

    func testReadyProofRequiresMatchingRunningPreview() throws {
        let harness = try PreviewHarness()
        try harness.makeCapacitorPreviewCapable(at: harness.projectRoot)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot)
        let record = previewRecord(
            batchID: "batch-mobile",
            projectPath: harness.projectRoot.path,
            worktreePath: harness.worktreeRoot.path,
            status: .readyToInspect,
            updatedAt: harness.now,
        )
        let projector = WorkBatchPreviewProjector(
            fileManager: harness.fileManager,
            isPreviewRunning: { _ in true },
            isPreviewIdentityRunning: { _ in false },
        )

        let projection = try XCTUnwrap(projector.projection(
            projectPath: harness.projectRoot.path,
            batch: batch(projectPath: harness.projectRoot.path),
            binding: binding(projectPath: harness.projectRoot.path, worktreePath: harness.worktreeRoot.path),
            previewRecord: record,
        ))

        XCTAssertEqual(projection.label, "Ready to inspect")
        XCTAssertEqual(projection.actionLabel, "Bring Preview Forward")
    }

    func testRunningPreviewIdentityWithoutMatchingProofDisablesPreviewAction() throws {
        let harness = try PreviewHarness()
        try harness.makeCapacitorPreviewCapable(at: harness.projectRoot)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot)
        let projector = WorkBatchPreviewProjector(
            fileManager: harness.fileManager,
            isPreviewRunning: { _ in false },
            isPreviewIdentityRunning: { _ in true },
        )

        let projection = try XCTUnwrap(projector.projection(
            projectPath: harness.projectRoot.path,
            batch: batch(projectPath: harness.projectRoot.path),
            binding: binding(projectPath: harness.projectRoot.path, worktreePath: harness.worktreeRoot.path),
            previewRecord: nil,
        ))

        XCTAssertEqual(projection.label, "Preview already open")
        XCTAssertFalse(projection.isActionEnabled)
        XCTAssertEqual(projection.reason, "A Capacitor Preview is already open. Close it before opening this batch preview.")
    }

    func testReadyPreviewCanMatchRunningAppFromExecutableURLWhenBundleURLIsMissing() throws {
        let harness = try PreviewHarness()
        let record = previewRecord(
            batchID: "batch-mobile",
            projectPath: harness.projectRoot.path,
            worktreePath: harness.worktreeRoot.path,
            status: .readyToInspect,
            updatedAt: harness.now,
        )
        let executableURL = harness.worktreeRoot
            .appendingPathComponent("apps/swift/CapacitorPreview.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Capacitor")
        let activity = WorkBatchPreviewAppActivity(
            runningApplicationResolver: PreviewRunningResolver(apps: [
                MacOSPreviewRunningApplication(
                    pid: 123,
                    bundleURL: nil,
                    executableURL: executableURL,
                ),
            ]),
        )

        XCTAssertTrue(activity.isMatchingRunning(record: record))
    }

    func testClosedReadyProofFallsBackToAvailablePreview() throws {
        let harness = try PreviewHarness()
        try harness.makeCapacitorPreviewCapable(at: harness.projectRoot)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot)
        let record = previewRecord(
            batchID: "batch-mobile",
            projectPath: harness.projectRoot.path,
            worktreePath: harness.worktreeRoot.path,
            status: .readyToInspect,
            updatedAt: harness.now,
        )
        let projector = WorkBatchPreviewProjector(
            fileManager: harness.fileManager,
            isPreviewRunning: { _ in false },
            isPreviewIdentityRunning: { _ in false },
        )

        let projection = try XCTUnwrap(projector.projection(
            projectPath: harness.projectRoot.path,
            batch: batch(projectPath: harness.projectRoot.path),
            binding: binding(projectPath: harness.projectRoot.path, worktreePath: harness.worktreeRoot.path),
            previewRecord: record,
        ))

        XCTAssertEqual(projection.label, "Preview available")
        XCTAssertEqual(projection.actionLabel, "Open Preview")
    }

    func testAlreadyRunningConflictDisablesPreviewUntilClosed() throws {
        let harness = try PreviewHarness()
        try harness.makeCapacitorPreviewCapable(at: harness.projectRoot)
        try harness.makeCapacitorPreviewCapable(at: harness.worktreeRoot)
        let record = previewRecord(
            batchID: "batch-mobile",
            projectPath: harness.projectRoot.path,
            worktreePath: harness.worktreeRoot.path,
            status: .previewFailed,
            failureReason: "Preview identity is already running: pid=123 path=/tmp/Other.app",
            updatedAt: harness.now,
        )
        let projector = WorkBatchPreviewProjector(
            fileManager: harness.fileManager,
            isPreviewRunning: { _ in false },
            isPreviewIdentityRunning: { _ in true },
        )

        let projection = try XCTUnwrap(projector.projection(
            projectPath: harness.projectRoot.path,
            batch: batch(projectPath: harness.projectRoot.path),
            binding: binding(projectPath: harness.projectRoot.path, worktreePath: harness.worktreeRoot.path),
            previewRecord: record,
        ))

        XCTAssertEqual(projection.label, "Preview already open")
        XCTAssertFalse(projection.isActionEnabled)
    }

    private func batch(projectPath: String) -> WorkBatchRecord {
        WorkBatchRecord(
            id: "batch-mobile",
            name: "Mobile prototype",
            projectPath: projectPath,
            status: .working,
            currentActivitySummary: "Working on mobile prototype.",
            taskIDs: ["task-mobile"],
            cockpitBindingID: "batch-mobile",
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_775_000_000),
        )
    }

    private func binding(projectPath: String, worktreePath: String) -> WorkBatchCockpitBinding {
        WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: projectPath,
            worktreeName: "batch-mobile",
            worktreePath: worktreePath,
            host: .claudeCode,
            claudeSessionID: "session-mobile",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_775_000_000),
        )
    }

    private func previewRecord(
        batchID: String,
        projectPath: String,
        worktreePath: String?,
        status: WorkBatchPreviewStatus,
        failureReason: String? = nil,
        updatedAt: Date,
    ) -> WorkBatchPreviewRecord {
        WorkBatchPreviewRecord(
            id: batchID,
            batchID: batchID,
            projectPath: projectPath,
            worktreePath: worktreePath,
            status: status,
            appPath: URL(fileURLWithPath: worktreePath ?? projectPath)
                .appendingPathComponent("apps/swift/CapacitorPreview.app", isDirectory: true)
                .path,
            bundleID: "com.capacitor.app.preview",
            displayName: "Capacitor Preview",
            pid: 123,
            proofPath: "/tmp/proof.json",
            buildLogPath: "/tmp/build.log",
            failureReason: failureReason,
            updatedAt: updatedAt,
            sourceFingerprint: "fingerprint-current",
        )
    }
}

private struct PreviewRunningResolver: MacOSPreviewRunningApplicationResolving {
    let apps: [MacOSPreviewRunningApplication]

    func runningApplications(bundleIdentifier _: String) -> [MacOSPreviewRunningApplication] {
        apps
    }
}

private final class PreviewHarness {
    let fileManager = FileManager.default
    let tempDir: URL
    let projectRoot: URL
    let worktreeRoot: URL
    let now = Date(timeIntervalSince1970: 1_775_000_000)

    init() throws {
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("WorkBatchPreviewStateTests-\(UUID().uuidString)", isDirectory: true)
        projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        worktreeRoot = projectRoot.appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
    }

    func makeCapacitorPreviewCapable(at rootURL: URL, includeBuildScript: Bool = true) throws {
        var requiredFiles = [
            "apps/swift/Package.swift",
            "apps/swift/Sources/Capacitor/App.swift",
        ]
        if includeBuildScript {
            requiredFiles.append("scripts/dev/build-preview-app.sh")
        }
        for relativePath in requiredFiles {
            let url = rootURL.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }
}
