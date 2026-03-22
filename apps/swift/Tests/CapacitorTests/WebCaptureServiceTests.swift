@testable import Capacitor
import Foundation
import Testing

@Suite("WebCaptureService")
struct WebCaptureServiceTests {
    // MARK: - Availability

    @Test("isAvailable returns without crashing")
    func isAvailableDoesNotCrash() async {
        let service = WebCaptureService()
        let available = await service.isAvailable()
        // On machines with agent-browser: true. On CI without it: false.
        // We just verify it doesn't crash.
        _ = available
    }

    // MARK: - Error Handling

    @Test("captureURL handles missing agent-browser or invalid URL gracefully")
    func captureURLHandlesErrors() async throws {
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

    @Test("captureMermaid handles missing agent-browser gracefully")
    func captureMermaidHandlesErrors() async throws {
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

    @Test("captureURL creates nested output directory before attempting capture")
    func createsNestedOutputDirectory() async throws {
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

    @Test("CaptureError provides human-readable descriptions")
    func errorDescriptions() throws {
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
            #expect(try !(#require(desc?.isEmpty)))
        }
    }
}

// MARK: - Capture URL UniFFI Bridge Tests

@Suite("Capture URL UniFFI bridge")
struct CaptureURLBridgeTests {
    @Test("CheckpointPacket carries capture_url through UniFFI bridge")
    func checkpointPacketHasCaptureUrl() {
        let packet = CheckpointPacket(
            kind: .implementationMilestone,
            title: "Test",
            summary: nil,
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureRequested: false,
            captureUrl: "http://localhost:3000",
        )

        #expect(packet.captureUrl == "http://localhost:3000")
        #expect(packet.captureRequested == false)
    }

    @Test("CheckpointPacket works without capture_url (nil)")
    func checkpointPacketNilCaptureUrl() {
        let packet = CheckpointPacket(
            kind: .proposal,
            title: "No capture",
            summary: nil,
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureRequested: false,
            captureUrl: nil,
        )

        #expect(packet.captureUrl == nil)
    }

    @Test("ActiveCheckpoint exposes capture_url and capture_status")
    func activeCheckpointHasCaptureFields() {
        let checkpoint = ActiveCheckpoint(
            id: "test-ckpt",
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
            decision: nil,
            createdAt: "2026-03-21T12:00:00Z",
            decidedAt: nil,
        )

        #expect(checkpoint.captureUrl == "http://localhost:5173")
        #expect(checkpoint.captureStatus == .pending)
    }

    @Test("MutateRunCommand carries capture_url")
    func mutateRunCommandHasCaptureUrl() {
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
            captureRequested: true,
            captureUrl: "http://localhost:3000",
            decisionAction: nil,
            decisionNote: nil,
            sessionId: nil,
            delegationWorkerId: nil,
            completedMediaArtifacts: [],
        )

        #expect(cmd.captureUrl == "http://localhost:3000")
        #expect(cmd.captureRequested == true)
    }

    @Test("MediaArtifact type includes Screenshot variant")
    func mediaArtifactTypeScreenshot() {
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

    @Test("CaptureStatus enum has expected variants")
    func captureStatusVariants() {
        let statuses: [CaptureStatus] = [
            .notRequested,
            .pending,
            .completed,
            .failed(reason: "timeout"),
        ]

        #expect(statuses.count == 4)

        if case let .failed(reason) = statuses[3] {
            #expect(reason == "timeout")
        } else {
            Issue.record("Expected .failed variant")
        }
    }
}
