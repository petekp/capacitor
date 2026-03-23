@testable import Capacitor
import Foundation
import XCTest

final class RunCaptureCoordinatorTests: XCTestCase {
    func testReconcileClaimsPendingCheckpointAndCompletesCapture() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let captureRecorder = CaptureRecorder()
        let closeCounter = AsyncCounter()
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            clientID: "capacitor-mac-test",
            mutateRun: { request in
                await mutationRecorder.record(request)
            },
            captureURL: { url, outputPath in
                await captureRecorder.recordURL(url: url, outputPath: outputPath)
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1440,
                    height: 900,
                )
            },
            closeBrowser: {
                await closeCounter.increment()
            },
        )

        let run = makeRun(
            runID: "run:/1",
            checkpointID: "checkpoint:1",
            captureStatus: .pending,
            captureUrl: "http://localhost:3000/review",
        )

        await coordinator.reconcile(runs: [run])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["capture_claim", "capture_complete"])
        XCTAssertEqual(requests.first?.projectPath, run.projectPath)
        XCTAssertEqual(requests.first?.runId, run.id)
        XCTAssertEqual(requests.first?.checkpointId, run.activeCheckpoint?.id)
        XCTAssertEqual(requests.first?.clientId, "capacitor-mac-test")
        XCTAssertEqual(requests.first?.observedCaptureUrl, run.activeCheckpoint?.captureUrl)
        XCTAssertEqual(
            requests.last?.captureRequestId,
            requests.first?.captureRequestId,
            "completion should use the same capture request id as the claim",
        )
        XCTAssertEqual(requests.last?.completedMediaArtifacts.count, 1)
        XCTAssertEqual(requests.last?.completedMediaArtifacts.first?.artifactType, "screenshot")
        XCTAssertEqual(requests.last?.completedMediaArtifacts.first?.label, "Web capture")
        let urlCaptureCount = await captureRecorder.urlCaptureCount()
        let mermaidCaptureCount = await captureRecorder.mermaidCaptureCount()
        let closeCount = await closeCounter.value()
        XCTAssertEqual(urlCaptureCount, 1)
        XCTAssertEqual(mermaidCaptureCount, 0)
        XCTAssertEqual(closeCount, 1)

        let captureDirectory = try captureDirectoryURL(
            homeDirectory: homeDirectory,
            runID: run.id,
            checkpointID: XCTUnwrap(run.activeCheckpoint?.id),
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: captureDirectory.appendingPathComponent("web-capture.png").path,
            ),
        )
    }

    func testReconcileRetriesOwnedInProgressCheckpoint() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let captureRecorder = CaptureRecorder()
        let existingClaim = RuntimeCaptureClaim(
            captureRequestId: "claim-123",
            clientId: "capacitor-mac-test",
            claimedAt: "2026-03-22T00:00:00Z",
            observedCaptureUrl: "http://localhost:3000/review",
        )
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            clientID: existingClaim.clientId,
            mutateRun: { request in
                await mutationRecorder.record(request)
            },
            captureURL: { url, outputPath in
                await captureRecorder.recordURL(url: url, outputPath: outputPath)
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1280,
                    height: 720,
                )
            },
        )

        await coordinator.reconcile(runs: [
            makeRun(
                captureStatus: .inProgress,
                captureClaim: existingClaim,
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["capture_complete"])
        XCTAssertEqual(requests.first?.captureRequestId, existingClaim.captureRequestId)
        let urlCaptureCount = await captureRecorder.urlCaptureCount()
        XCTAssertEqual(urlCaptureCount, 1)
    }

    func testReconcileSkipsForeignInProgressCheckpoint() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let captureRecorder = CaptureRecorder()
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            clientID: "capacitor-mac-local",
            mutateRun: { request in
                await mutationRecorder.record(request)
            },
            captureURL: { url, outputPath in
                await captureRecorder.recordURL(url: url, outputPath: outputPath)
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1,
                    height: 1,
                )
            },
        )

        await coordinator.reconcile(runs: [
            makeRun(
                captureStatus: .inProgress,
                captureClaim: RuntimeCaptureClaim(
                    captureRequestId: "claim-foreign",
                    clientId: "capacitor-mac-other",
                    claimedAt: "2026-03-22T00:00:00Z",
                    observedCaptureUrl: "http://localhost:3000/review",
                ),
            ),
        ])

        let requests = await mutationRecorder.snapshot()
        let urlCaptureCount = await captureRecorder.urlCaptureCount()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(urlCaptureCount, 0)
    }

    func testReconcileSkipsCheckpointWithoutCaptureURL() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let captureRecorder = CaptureRecorder()
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            mutateRun: { request in
                await mutationRecorder.record(request)
            },
            captureURL: { url, outputPath in
                await captureRecorder.recordURL(url: url, outputPath: outputPath)
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1,
                    height: 1,
                )
            },
        )

        await coordinator.reconcile(runs: [
            makeRun(captureStatus: .pending, captureUrl: "   "),
            makeRun(runID: "run-2", checkpointID: "checkpoint-2", captureStatus: .pending, captureUrl: nil),
        ])

        let requests = await mutationRecorder.snapshot()
        let urlCaptureCount = await captureRecorder.urlCaptureCount()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(urlCaptureCount, 0)
    }

    func testReconcileSkipsNonPendingCheckpointWithoutOwnedClaim() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let captureRecorder = CaptureRecorder()
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            mutateRun: { request in
                await mutationRecorder.record(request)
            },
            captureURL: { url, outputPath in
                await captureRecorder.recordURL(url: url, outputPath: outputPath)
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1,
                    height: 1,
                )
            },
        )

        await coordinator.reconcile(runs: [
            makeRun(captureStatus: .completed, captureClaim: nil),
            makeRun(runID: "run-2", checkpointID: "checkpoint-2", captureStatus: .inProgress, captureClaim: nil),
        ])

        let requests = await mutationRecorder.snapshot()
        let urlCaptureCount = await captureRecorder.urlCaptureCount()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(urlCaptureCount, 0)
    }

    func testClaimRejectedDoesNotInvokeCapture() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let captureRecorder = CaptureRecorder()
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            mutateRun: { request in
                await mutationRecorder.record(request)
                if request.kind == "capture_claim" {
                    throw RuntimeClientError.mutationRejected("already claimed")
                }
            },
            captureURL: { url, outputPath in
                await captureRecorder.recordURL(url: url, outputPath: outputPath)
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1,
                    height: 1,
                )
            },
        )

        await coordinator.reconcile(runs: [makeRun()])

        let requests = await mutationRecorder.snapshot()
        let urlCaptureCount = await captureRecorder.urlCaptureCount()
        XCTAssertEqual(requests.map(\.kind), ["capture_claim"])
        XCTAssertEqual(urlCaptureCount, 0)
    }

    func testCaptureFailureDeletesCheckpointDirectoryAndSendsCaptureFailed() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let closeCounter = AsyncCounter()
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            mutateRun: { request in
                await mutationRecorder.record(request)
            },
            captureURL: { _, _ in
                throw WebCaptureService.CaptureError.timeout
            },
            closeBrowser: {
                await closeCounter.increment()
            },
        )
        let run = makeRun(runID: "run:/1", checkpointID: "checkpoint:1")

        await coordinator.reconcile(runs: [run])

        let requests = await mutationRecorder.snapshot()
        let closeCount = await closeCounter.value()
        XCTAssertEqual(requests.map(\.kind), ["capture_claim", "capture_failed"])
        XCTAssertEqual(requests.last?.captureFailureReason, "timeout")
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(
            try FileManager.default.fileExists(
                atPath: captureDirectoryURL(
                    homeDirectory: homeDirectory,
                    runID: run.id,
                    checkpointID: XCTUnwrap(run.activeCheckpoint?.id),
                ).path,
            ),
        )
    }

    func testFinalizeTransportFailurePreservesArtifactsOnDisk() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            mutateRun: { request in
                await mutationRecorder.record(request)
                if request.kind == "capture_complete" {
                    throw RuntimeClientError.runtimeUnavailable("offline")
                }
            },
            captureURL: { _, outputPath in
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1024,
                    height: 768,
                )
            },
        )
        let run = makeRun(runID: "run:/1", checkpointID: "checkpoint:1")

        await coordinator.reconcile(runs: [run])

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["capture_claim", "capture_complete"])
        XCTAssertFalse(requests.contains(where: { $0.kind == "capture_failed" }))
        let captureDirectory = try captureDirectoryURL(
            homeDirectory: homeDirectory,
            runID: run.id,
            checkpointID: XCTUnwrap(run.activeCheckpoint?.id),
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureDirectory.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: captureDirectory.appendingPathComponent("web-capture.png").path,
            ),
        )
    }

    func testOwnedInProgressRetryFinalizesFromPreservedArtifactsWhenToolUnavailable() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let captureRecorder = CaptureRecorder()

        // Phase 1: Initial capture succeeds locally but transport fails on finalize.
        let firstRunCoordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            clientID: "capacitor-mac-test",
            mutateRun: { request in
                await mutationRecorder.record(request)
                if request.kind == "capture_complete" {
                    throw RuntimeClientError.runtimeUnavailable("offline")
                }
            },
            captureURL: { url, outputPath in
                await captureRecorder.recordURL(url: url, outputPath: outputPath)
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1440,
                    height: 900,
                )
            },
        )
        let run = makeRun(
            runID: "run:/1",
            checkpointID: "checkpoint:1",
            captureStatus: .pending,
            captureUrl: "http://localhost:3000/review",
        )
        await firstRunCoordinator.reconcile(runs: [run])

        // Verify: claim + failed capture_complete, artifacts preserved on disk.
        var requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["capture_claim", "capture_complete"])

        let captureDirectory = try captureDirectoryURL(
            homeDirectory: homeDirectory,
            runID: run.id,
            checkpointID: XCTUnwrap(run.activeCheckpoint?.id),
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: captureDirectory.appendingPathComponent("web-capture.png").path,
            ),
            "artifacts should be preserved after transport failure",
        )

        // Phase 2: Retry as ownedInProgress with tool UNAVAILABLE.
        // The coordinator should finalize from preserved artifacts, not re-capture.
        let retryRecorder = RunMutationRecorder()
        let retryCoordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            clientID: "capacitor-mac-test",
            mutateRun: { request in
                await retryRecorder.record(request)
            },
            captureURL: { url, outputPath in
                await captureRecorder.recordURL(url: url, outputPath: outputPath)
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1,
                    height: 1,
                )
            },
            isCaptureToolAvailable: { false },
        )

        let existingClaim = try RuntimeCaptureClaim(
            captureRequestId: XCTUnwrap(requests.first?.captureRequestId),
            clientId: "capacitor-mac-test",
            claimedAt: "2026-03-22T00:00:00Z",
            observedCaptureUrl: "http://localhost:3000/review",
        )
        let retryRun = makeRun(
            runID: "run:/1",
            checkpointID: "checkpoint:1",
            captureStatus: .inProgress,
            captureUrl: "http://localhost:3000/review",
            captureClaim: existingClaim,
        )

        await retryCoordinator.reconcile(runs: [retryRun])

        // Should finalize with capture_complete from preserved artifacts, NOT capture_failed.
        let retryRequests = await retryRecorder.snapshot()
        XCTAssertEqual(
            retryRequests.map(\.kind),
            ["capture_complete"],
            "should finalize from preserved artifacts, not send capture_failed",
        )
        XCTAssertFalse(
            retryRequests.contains(where: { $0.kind == "capture_failed" }),
            "should never send capture_failed when preserved artifacts exist",
        )
        XCTAssertEqual(
            retryRequests.first?.completedMediaArtifacts.count, 1,
            "should include the preserved web-capture.png artifact",
        )

        // Should NOT have invoked browser capture again.
        let urlCaptureCount = await captureRecorder.urlCaptureCount()
        XCTAssertEqual(urlCaptureCount, 1, "browser capture should have been called only once (initial)")
    }

    func testInFlightCheckpointSkipsDuplicateReconcileTick() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let captureRecorder = CaptureRecorder()
        let gate = AsyncGate()
        let started = expectation(description: "first capture started")
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            mutateRun: { request in
                await mutationRecorder.record(request)
            },
            captureURL: { url, outputPath in
                await captureRecorder.recordURL(url: url, outputPath: outputPath)
                started.fulfill()
                await gate.wait()
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1,
                    height: 1,
                )
            },
        )
        let run = makeRun()

        let firstReconcile = _Concurrency.Task {
            await coordinator.reconcile(runs: [run])
        }
        await fulfillment(of: [started], timeout: 1.0)

        await coordinator.reconcile(runs: [run])

        let urlCaptureCount = await captureRecorder.urlCaptureCount()
        let claimCount = await mutationRecorder.kindCount("capture_claim")
        XCTAssertEqual(urlCaptureCount, 1)
        XCTAssertEqual(claimCount, 1)

        await gate.releaseAll()
        await firstReconcile.value

        let requests = await mutationRecorder.snapshot()
        XCTAssertEqual(requests.map(\.kind), ["capture_claim", "capture_complete"])
    }

    func testMermaidSourcesProducePngAndMmdCompanionFiles() async throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let mutationRecorder = RunMutationRecorder()
        let captureRecorder = CaptureRecorder()
        let mermaidSources = [
            RuntimeMermaidSource(label: "Flow A", source: "graph TD\nA-->B"),
            RuntimeMermaidSource(label: "Flow B", source: "graph TD\nB-->C"),
        ]
        let coordinator = makeCoordinator(
            homeDirectory: homeDirectory,
            mutateRun: { request in
                await mutationRecorder.record(request)
            },
            captureURL: { _, outputPath in
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 1600,
                    height: 900,
                )
            },
            captureMermaid: { source, outputPath in
                await captureRecorder.recordMermaid(source: source, outputPath: outputPath)
                try writeArtifact(at: outputPath)
                return WebCaptureService.CaptureResult(
                    imagePath: outputPath,
                    width: 800,
                    height: 600,
                )
            },
        )
        let run = makeRun(mermaidSources: mermaidSources)

        await coordinator.reconcile(runs: [run])

        let captureDirectory = try captureDirectoryURL(
            homeDirectory: homeDirectory,
            runID: run.id,
            checkpointID: XCTUnwrap(run.activeCheckpoint?.id),
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: captureDirectory.appendingPathComponent("mermaid-0.mmd").path,
            ),
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: captureDirectory.appendingPathComponent("mermaid-0.png").path,
            ),
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: captureDirectory.appendingPathComponent("mermaid-1.mmd").path,
            ),
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: captureDirectory.appendingPathComponent("mermaid-1.png").path,
            ),
        )
        let mermaidCaptureCount = await captureRecorder.mermaidCaptureCount()
        XCTAssertEqual(mermaidCaptureCount, 2)

        let requests = await mutationRecorder.snapshot()
        let artifacts = try XCTUnwrap(requests.last?.completedMediaArtifacts)
        XCTAssertEqual(artifacts.count, 3)
        XCTAssertEqual(artifacts.count(where: { $0.artifactType == "mermaid_diagram" }), 2)
        XCTAssertEqual(artifacts.count(where: { $0.artifactType == "screenshot" }), 1)
    }

    private func makeCoordinator(
        homeDirectory: URL,
        clientID: String = "capacitor-mac-test",
        mutateRun: @escaping RunCaptureCoordinator.RunMutator = { _ in },
        captureURL: @escaping @Sendable (String, String) async throws -> WebCaptureService.CaptureResult = { _, outputPath in
            try writeArtifact(at: outputPath)
            return WebCaptureService.CaptureResult(
                imagePath: outputPath,
                width: 1280,
                height: 720,
            )
        },
        captureMermaid: @escaping @Sendable (String, String) async throws -> WebCaptureService.CaptureResult = { _, outputPath in
            try writeArtifact(at: outputPath)
            return WebCaptureService.CaptureResult(
                imagePath: outputPath,
                width: 1280,
                height: 720,
            )
        },
        closeBrowser: @escaping @Sendable () async -> Void = {},
        isCaptureToolAvailable: @escaping @Sendable () async -> Bool = { true },
    ) -> RunCaptureCoordinator {
        RunCaptureCoordinator(
            mutateRun: mutateRun,
            captureURL: captureURL,
            captureMermaid: captureMermaid,
            closeBrowser: closeBrowser,
            isCaptureToolAvailable: isCaptureToolAvailable,
            fileManager: .default,
            homeDirectoryProvider: { homeDirectory },
            clientID: clientID,
        )
    }

    private func makeRun(
        projectPath: String = "/tmp/projects/capacitor",
        runID: String = "run-1",
        checkpointID: String = "checkpoint-1",
        captureStatus: RuntimeCaptureStatus = .pending,
        captureUrl: String? = "http://localhost:3000/review",
        captureClaim: RuntimeCaptureClaim? = nil,
        mermaidSources: [RuntimeMermaidSource] = [],
    ) -> RuntimeRunState {
        let timestamp = "2026-03-22T00:00:00Z"
        return RuntimeRunState(
            id: runID,
            projectPath: projectPath,
            methodId: "checkpoint-review",
            methodName: "Checkpoint Review",
            status: "paused",
            sessionId: "session-1",
            delegationWorkerId: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            activeCheckpoint: RuntimeCheckpointState(
                id: checkpointID,
                phaseId: "phase-1",
                kind: .proposal,
                status: "active",
                title: "Checkpoint",
                summary: "Review the output",
                briefPath: nil,
                manifestPath: nil,
                mediaArtifacts: [],
                mermaidSources: mermaidSources,
                captureStatus: captureStatus,
                captureUrl: captureUrl,
                captureClaim: captureClaim,
                createdAt: timestamp,
                decidedAt: nil,
            ),
        )
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private actor RunMutationRecorder {
    private var requests: [RuntimeRunMutationRequest] = []

    func record(_ request: RuntimeRunMutationRequest) {
        requests.append(request)
    }

    func snapshot() -> [RuntimeRunMutationRequest] {
        requests
    }

    func kindCount(_ kind: String) -> Int {
        requests.count(where: { $0.kind == kind })
    }
}

private actor CaptureRecorder {
    private var urlCaptures: [(url: String, outputPath: String)] = []
    private var mermaidCaptures: [(source: String, outputPath: String)] = []

    func recordURL(url: String, outputPath: String) {
        urlCaptures.append((url: url, outputPath: outputPath))
    }

    func recordMermaid(source: String, outputPath: String) {
        mermaidCaptures.append((source: source, outputPath: outputPath))
    }

    func urlCaptureCount() -> Int {
        urlCaptures.count
    }

    func mermaidCaptureCount() -> Int {
        mermaidCaptures.count
    }
}

private actor AsyncCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        let activeContinuations = continuations
        continuations.removeAll()
        for continuation in activeContinuations {
            continuation.resume()
        }
    }
}

private func writeArtifact(at path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
    )
    try Data("artifact".utf8).write(to: url)
}

private func captureDirectoryURL(homeDirectory: URL, runID: String, checkpointID: String) -> URL {
    homeDirectory
        .appendingPathComponent(".capacitor", isDirectory: true)
        .appendingPathComponent("runtime", isDirectory: true)
        .appendingPathComponent("captures", isDirectory: true)
        .appendingPathComponent(sanitizedPathComponent(runID), isDirectory: true)
        .appendingPathComponent(sanitizedPathComponent(checkpointID), isDirectory: true)
}

private func sanitizedPathComponent(_ value: String) -> String {
    value
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
}
