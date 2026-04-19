@testable import Capacitor
import Foundation
import Testing

struct WebCaptureServiceTests {
    // MARK: - Availability

    @Test
    func `isAvailable returns without crashing`() async {
        let service = WebCaptureService()
        let available = await service.isAvailable()
        // On machines with agent-browser: true. On CI without it: false.
        // We just verify it doesn't crash.
        _ = available
    }

    // MARK: - Error Handling

    @Test
    func `captureURL handles missing agent-browser or invalid URL gracefully`() async throws {
        let service = WebCaptureService()

        let tempDir = NSTemporaryDirectory() + "cap-test-\(UUID().uuidString)"
        let outputPath = "\(tempDir)/test-capture.png"
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        do {
            _ = try await service.captureURL(
                "not-a-valid-url-at-all",
                outputPath: outputPath,
                timeoutSeconds: 5,
            )
        } catch let error as WebCaptureService.CaptureError {
            // Any CaptureError is acceptable — proves error paths work
            #expect(error.errorDescription != nil)
        }
    }

    @Test
    func `captureMermaid handles missing agent-browser gracefully`() async throws {
        let service = WebCaptureService()

        let tempDir = NSTemporaryDirectory() + "cap-test-\(UUID().uuidString)"
        let outputPath = "\(tempDir)/test-mermaid.png"
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        do {
            _ = try await service.captureMermaid(
                source: "graph LR; A-->B",
                outputPath: outputPath,
                timeoutSeconds: 5,
            )
        } catch let error as WebCaptureService.CaptureError {
            #expect(error.errorDescription != nil)
        }
    }

    // MARK: - Output Directory Creation

    @Test
    func `captureURL creates nested output directory before attempting capture`() async throws {
        let service = WebCaptureService()
        guard await service.isAvailable() else { return }

        let basePath = NSTemporaryDirectory() + "cap-nested-\(UUID().uuidString)"
        let outputPath = "\(basePath)/sub/dir/test.png"
        defer { try? FileManager.default.removeItem(atPath: basePath) }

        do {
            _ = try await service.captureURL(
                "http://localhost:99999",
                outputPath: outputPath,
                timeoutSeconds: 5,
            )
        } catch {
            // Connection refused is expected; directory should still be created
        }

        let dirPath = (outputPath as NSString).deletingLastPathComponent
        #expect(FileManager.default.fileExists(atPath: dirPath))
    }

    // MARK: - CaptureError descriptions

    @Test
    func `CaptureError provides human-readable descriptions`() throws {
        let errors: [WebCaptureService.CaptureError] = [
            .agentBrowserNotFound,
            .navigationFailed(url: "http://localhost:3000", stderr: "connection refused"),
            .screenshotFailed(stderr: "page not loaded"),
            .timeout,
            .outputFileMissing(path: "/tmp/test.png"),
        ]

        for error in errors {
            let desc = error.errorDescription
            #expect(desc != nil)
            #expect(try !#require(desc?.isEmpty as Bool?))
        }
    }
}

// MARK: - Capture URL UniFFI Bridge Tests

struct CaptureURLBridgeTests {
    @Test
    func `CheckpointPacket carries capture_url through UniFFI bridge`() {
        let packet = CheckpointPacket(
            kind: .implementationMilestone,
            title: "Test",
            summary: nil,
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureUrl: "http://localhost:3000",
        )

        #expect(packet.captureUrl == "http://localhost:3000")
    }

    @Test
    func `CheckpointPacket works without capture_url (nil)`() {
        let packet = CheckpointPacket(
            kind: .proposal,
            title: "No capture",
            summary: nil,
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureUrl: nil,
        )

        #expect(packet.captureUrl == nil)
    }

    @Test
    func `ActiveCheckpoint exposes capture_url and capture_status`() {
        let captureClaim = CaptureClaim(
            captureRequestId: "capture-001",
            clientId: "capacitor-mac-1234",
            claimedAt: "2026-03-21T12:00:05Z",
            observedCaptureUrl: "http://localhost:5173",
        )
        let checkpoint = ActiveCheckpoint(
            id: "test-ckpt",
            historyOrdinal: nil,
            phaseId: "phase-001",
            kind: .implementationMilestone,
            status: .active,
            title: "Test",
            summary: nil,
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureStatus: .pending,
            captureUrl: "http://localhost:5173",
            captureClaim: captureClaim,
            decisionRelay: nil,
            decision: nil,
            createdAt: "2026-03-21T12:00:00Z",
            decidedAt: nil,
        )

        #expect(checkpoint.captureUrl == "http://localhost:5173")
        #expect(checkpoint.captureStatus == .pending)
        #expect(checkpoint.captureClaim == captureClaim)
        #expect(checkpoint.decisionRelay == nil)
    }

    @Test
    func `MutateRunCommand carries capture_url`() {
        let cmd = MutateRunCommand(
            kind: .emitCheckpoint,
            projectPath: "/test",
            runId: "run-001",
            methodId: nil,
            involvement: nil,
            checkpointKind: .implementationMilestone,
            checkpointTitle: "Test",
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            checkpointDecisionRelay: nil,
            captureUrl: "http://localhost:3000",
            checkpointId: "checkpoint-001",
            captureRequestId: "capture-001",
            clientId: "capacitor-mac-1234",
            observedCaptureUrl: "http://localhost:3000",
            captureFailureReason: nil,
            decisionAction: nil,
            decisionNote: nil,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
            completedMediaArtifacts: [],
        )

        #expect(cmd.captureUrl == "http://localhost:3000")
        #expect(cmd.checkpointId == "checkpoint-001")
        #expect(cmd.checkpointDecisionRelay == nil)
        #expect(cmd.captureRequestId == "capture-001")
        #expect(cmd.clientId == "capacitor-mac-1234")
        #expect(cmd.observedCaptureUrl == "http://localhost:3000")
    }

    @Test
    func `CaptureClaim bridge value carries claim metadata`() {
        let claim = CaptureClaim(
            captureRequestId: "capture-001",
            clientId: "capacitor-mac-1234",
            claimedAt: "2026-03-21T12:00:05Z",
            observedCaptureUrl: "http://localhost:5173",
        )

        #expect(claim.captureRequestId == "capture-001")
        #expect(claim.clientId == "capacitor-mac-1234")
        #expect(claim.claimedAt == "2026-03-21T12:00:05Z")
        #expect(claim.observedCaptureUrl == "http://localhost:5173")
    }

    @Test
    func `MediaArtifact type includes Screenshot variant`() {
        let artifact = MediaArtifact(
            artifactType: .screenshot,
            path: "/tmp/capture.png",
            label: "Web capture",
            width: 1920,
            height: 1080,
            durationSecs: nil,
        )

        #expect(artifact.artifactType == .screenshot)
        #expect(artifact.path == "/tmp/capture.png")
    }

    @Test
    func `CaptureStatus enum has expected variants`() {
        let statuses: [CaptureStatus] = [
            .notRequested,
            .pending,
            .inProgress,
            .completed,
            .failed(reason: "timeout"),
        ]

        #expect(statuses.count == 5)

        #expect(statuses[2] == .inProgress)

        if case let .failed(reason) = statuses[4] {
            #expect(reason == "timeout")
        } else {
            Issue.record("Expected .failed variant")
        }
    }
}
