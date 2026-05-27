@testable import Capacitor
import XCTest

final class RunCheckpointOperatorBriefProjectionTests: XCTestCase {
    func testBuildsConceptFirstBriefFromCheckpointAndManifest() throws {
        let run = makeRun(
            methodName: "Build",
            ideaTitle: "Improve checkpoint evidence packets",
            ideaDescription: "Success means I can approve without reading the diff first.",
        )
        let checkpoint = makeCheckpoint(
            title: "Evidence packet structure",
            summary: "Introduced a four-level evidence packet model.",
            mediaArtifacts: [
                RuntimeMediaArtifact(
                    artifactType: "screenshot",
                    path: "/tmp/checkpoint.png",
                    label: "Checkpoint review screenshot",
                    width: nil,
                    height: nil,
                    durationSecs: nil,
                ),
            ],
            mermaidSources: [
                RuntimeMermaidSource(label: "Decision flow", source: "flowchart TD"),
            ],
        )
        let manifest = try decodeManifest("""
        {
            "version": 1,
            "milestone_id": "01",
            "summary": "Review flow now leads with intent, outcome, evidence, and risk.",
            "artifacts": [
                {"label": "Implementation diff", "path": "diff.md"},
                {"label": "Test output", "path": "test-output.txt"}
            ],
            "swift_changes": true
        }
        """)

        let brief = RunCheckpointOperatorBriefProjection.make(
            run: run,
            checkpoint: checkpoint,
            manifest: manifest,
            manifestLoadError: nil,
        )

        XCTAssertEqual(brief.goal, "Improve checkpoint evidence packets")
        XCTAssertEqual(brief.claim, "Review flow now leads with intent, outcome, evidence, and risk.")
        XCTAssertEqual(brief.changed, [
            "Evidence packet structure",
            "Swift changes are included.",
        ])
        XCTAssertEqual(brief.evidence, [
            "Implementation diff: diff.md",
            "Test output: test-output.txt",
            "Checkpoint review screenshot: /tmp/checkpoint.png",
            "Decision flow: Mermaid source attached",
        ])
        XCTAssertEqual(brief.risks, ["No explicit risks were reported."])
        XCTAssertEqual(brief.ask, "Approve direction or request changes before the run continues.")
    }

    func testUsesPlainFallbacksWhenManifestIsUnavailable() {
        let run = makeRun(
            methodName: "Build",
            ideaTitle: nil,
            ideaDescription: nil,
        )
        let checkpoint = makeCheckpoint(
            title: "Checkpoint review",
            summary: "Agent needs direction before continuing.",
        )

        let brief = RunCheckpointOperatorBriefProjection.make(
            run: run,
            checkpoint: checkpoint,
            manifest: nil,
            manifestLoadError: "No such file",
        )

        XCTAssertEqual(brief.goal, "Build checkpoint")
        XCTAssertEqual(brief.claim, "Agent needs direction before continuing.")
        XCTAssertEqual(brief.changed, ["Checkpoint review"])
        XCTAssertEqual(brief.evidence, ["No evidence artifacts are attached yet."])
        XCTAssertEqual(brief.risks, ["Manifest unavailable: No such file"])
        XCTAssertEqual(brief.ask, "Approve direction or request changes before the run continues.")
    }

    private func decodeManifest(_ json: String) throws -> DelegationReviewManifest {
        try JSONDecoder().decode(DelegationReviewManifest.self, from: Data(json.utf8))
    }

    private func makeRun(
        methodName: String,
        ideaTitle: String?,
        ideaDescription: String?,
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: "run-1",
            projectPath: "/tmp/project",
            methodId: "method",
            methodName: methodName,
            status: "paused",
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            createdAt: "2026-05-24T15:00:00Z",
            updatedAt: "2026-05-24T15:05:00Z",
            activeCheckpoint: nil,
            ideaId: "idea-1",
            ideaTitle: ideaTitle,
            ideaDescription: ideaDescription,
        )
    }

    private func makeCheckpoint(
        title: String,
        summary: String?,
        mediaArtifacts: [RuntimeMediaArtifact] = [],
        mermaidSources: [RuntimeMermaidSource] = [],
    ) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: "checkpoint-1",
            phaseId: "phase",
            kind: .implementationMilestone,
            status: "pending",
            title: title,
            summary: summary,
            briefPath: nil,
            manifestPath: "/tmp/manifest.json",
            mediaArtifacts: mediaArtifacts,
            mermaidSources: mermaidSources,
            captureStatus: .notRequested,
            captureUrl: nil,
            captureClaim: nil,
            createdAt: "2026-05-24T15:01:00Z",
            decidedAt: nil,
        )
    }
}
