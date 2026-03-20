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
}
