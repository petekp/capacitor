@testable import Capacitor
import Foundation
import Testing

@Suite("DelegationReviewManifest decoding")
struct DelegationReviewManifestTests {
    @Test("Decodes manifest with swift_changes true")
    func decodesSwiftChangesTrue() throws {
        let json = """
        {
            "version": 1,
            "milestone_id": "01",
            "summary": "Added new view",
            "artifacts": [],
            "swift_changes": true
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(DelegationReviewManifest.self, from: json)
        #expect(manifest.swiftChanges == true)
    }

    @Test("Decodes manifest with swift_changes false")
    func decodesSwiftChangesFalse() throws {
        let json = """
        {
            "version": 1,
            "milestone_id": "01",
            "summary": "Updated config",
            "artifacts": [],
            "swift_changes": false
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(DelegationReviewManifest.self, from: json)
        #expect(manifest.swiftChanges == false)
    }

    @Test("Decodes manifest without swift_changes field (backwards compat)")
    func decodesWithoutSwiftChanges() throws {
        let json = """
        {
            "version": 1,
            "milestone_id": "01",
            "summary": "Legacy manifest",
            "artifacts": []
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(DelegationReviewManifest.self, from: json)
        #expect(manifest.swiftChanges == nil)
    }

    @Test("Decodes manifest with decisions and swift_changes")
    func decodesFullManifest() throws {
        let json = """
        {
            "version": 1,
            "milestone_id": "02",
            "summary": "Refactored review window",
            "artifacts": [
                {"label": "Review window", "path": "apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewWindow.swift"}
            ],
            "decisions": {
                "approve": {"label": "Ship It", "description": "Changes look good"},
                "request_changes": {"label": "Needs Work", "description": "Layout is off"}
            },
            "swift_changes": true
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(DelegationReviewManifest.self, from: json)
        #expect(manifest.swiftChanges == true)
        #expect(manifest.decisions?.approve?.label == "Ship It")
        #expect(manifest.artifacts.count == 1)
    }

    @Test("Decodes artifact with artifact_type field")
    func decodesArtifactWithType() throws {
        let json = """
        {
            "version": 1,
            "milestone_id": "01",
            "summary": "With media",
            "artifacts": [
                {"label": "Terminal", "path": "terminal-001.png", "artifact_type": "screenshot", "width": 2560, "height": 1440},
                {"label": "Architecture", "path": "arch.mmd", "artifact_type": "mermaid"},
                {"label": "Flow recording", "path": "phase.mov", "artifact_type": "recording", "duration_secs": 42.5}
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(DelegationReviewManifest.self, from: json)
        #expect(manifest.artifacts.count == 3)

        #expect(manifest.artifacts[0].artifactType == .screenshot)
        #expect(manifest.artifacts[0].width == 2560)
        #expect(manifest.artifacts[0].height == 1440)
        #expect(manifest.artifacts[0].isMedia == true)

        #expect(manifest.artifacts[1].artifactType == .mermaid)
        #expect(manifest.artifacts[1].isMedia == true)

        #expect(manifest.artifacts[2].artifactType == .recording)
        #expect(manifest.artifacts[2].durationSecs == 42.5)
        #expect(manifest.artifacts[2].isMedia == true)
    }

    @Test("Decodes mermaid_diagram artifact type emitted by runtime capture")
    func decodesArtifactWithMermaidDiagramType() throws {
        let json = """
        {
            "version": 1,
            "milestone_id": "01",
            "summary": "With runtime mermaid artifact",
            "artifacts": [
                {"label": "Architecture", "path": "arch.png", "artifact_type": "mermaid_diagram"}
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(DelegationReviewManifest.self, from: json)
        #expect(manifest.artifacts.count == 1)
        #expect(manifest.artifacts[0].artifactType == .mermaid)
        #expect(manifest.artifacts[0].isMedia == true)
    }

    @Test("Decodes artifact without artifact_type (backwards compat)")
    func decodesArtifactWithoutType() throws {
        let json = """
        {
            "version": 1,
            "milestone_id": "01",
            "summary": "Legacy",
            "artifacts": [
                {"label": "Some file", "path": "some/path.swift"}
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(DelegationReviewManifest.self, from: json)
        #expect(manifest.artifacts[0].artifactType == nil)
        #expect(manifest.artifacts[0].width == nil)
        #expect(manifest.artifacts[0].isMedia == false)
    }
}
