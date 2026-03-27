@testable import Capacitor
import Foundation
import Testing

struct DelegationReviewManifestTests {
    @Test
    func `Decodes manifest with swift_changes true`() throws {
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

    @Test
    func `Decodes manifest with swift_changes false`() throws {
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

    @Test
    func `Decodes manifest without swift_changes field (backwards compat)`() throws {
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

    @Test
    func `Decodes manifest with decisions and swift_changes`() throws {
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

    @Test
    func `Decodes artifact with artifact_type field`() throws {
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

    @Test
    func `Decodes mermaid_diagram artifact type emitted by runtime capture`() throws {
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

    @Test
    func `Decodes artifact without artifact_type (backwards compat)`() throws {
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
