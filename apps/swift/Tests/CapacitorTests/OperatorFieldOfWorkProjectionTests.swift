@testable import Capacitor
import XCTest

final class OperatorFieldOfWorkProjectionTests: XCTestCase {
    func testBuildsAttentionSectionsInStoryboardOrder() {
        let projects = [
            makeProject(name: "Decision", path: "/tmp/decision"),
            makeProject(name: "Running", path: "/tmp/running"),
            makeProject(name: "Changed", path: "/tmp/changed"),
            makeProject(name: "Dormant", path: "/tmp/dormant"),
        ]
        let summary = OperatorAttentionSummary(
            needsYou: [
                item(kind: .checkpoint, projectPath: "/tmp/decision", title: "Decision"),
            ],
            runningNormally: [
                item(kind: .runningRun, projectPath: "/tmp/running", title: "Running"),
            ],
            recentlyChanged: [
                item(kind: .completedRun, projectPath: "/tmp/changed", title: "Changed"),
            ],
            dormant: [
                item(kind: .dormantProject, projectPath: "/tmp/dormant", title: "Dormant"),
            ],
        )

        let sections = OperatorFieldOfWorkProjection.make(
            projects: projects,
            summary: summary,
            projectOrder: [],
            hiddenProjectPaths: [],
        )

        XCTAssertEqual(sections.map(\.kind), [
            .needsYou,
            .runningNormally,
            .recentlyChanged,
            .dormantHidden,
        ])
        XCTAssertEqual(sections.map(\.title), [
            "Needs You",
            "Running Normally",
            "Recently Changed",
            "Dormant / Hidden",
        ])
        XCTAssertEqual(sections.flatMap { $0.rows.map(\.project.path) }, [
            "/tmp/decision",
            "/tmp/running",
            "/tmp/changed",
            "/tmp/dormant",
        ])
    }

    func testDeduplicatesProjectIntoHighestPrioritySection() {
        let project = makeProject(name: "Both", path: "/tmp/both")
        let summary = OperatorAttentionSummary(
            needsYou: [
                item(kind: .checkpoint, projectPath: project.path, title: "Needs direction"),
            ],
            runningNormally: [
                item(kind: .runningRun, projectPath: project.path, title: "Running"),
            ],
            recentlyChanged: [
                item(kind: .completedRun, projectPath: project.path, title: "Changed"),
            ],
        )

        let sections = OperatorFieldOfWorkProjection.make(
            projects: [project],
            summary: summary,
            projectOrder: [],
            hiddenProjectPaths: [],
        )

        XCTAssertEqual(sections.map(\.kind), [.needsYou])
        XCTAssertEqual(sections.first?.rows.map(\.project.path), [project.path])
        XCTAssertEqual(sections.first?.rows.first?.attentionItem?.kind, .checkpoint)
    }

    func testProjectionCheckpointPriorityFeedsNeedsYouSection() {
        let project = makeProject(name: "Proof", path: "/tmp/proof")
        let checkpointRun = makeRun(
            id: "run-checkpoint",
            projectPath: project.path,
            status: "paused",
            updatedAt: "2026-05-24T15:01:00Z",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-1",
                title: "Evidence packet ready",
                createdAt: "2026-05-24T15:00:00Z",
            ),
        )
        let activeRun = makeRun(
            id: "run-active",
            projectPath: project.path,
            status: "active",
            updatedAt: "2027-01-15T08:00:00Z",
        )
        let summary = OperatorAttentionProjection.build(
            projects: [project],
            runsByID: runsByID([checkpointRun, activeRun]),
            now: Date(timeIntervalSince1970: 1_800_000_000),
        )

        let sections = OperatorFieldOfWorkProjection.make(
            projects: [project],
            summary: summary,
            projectOrder: [],
            hiddenProjectPaths: [],
        )

        XCTAssertEqual(sections.map(\.kind), [.needsYou])
        XCTAssertEqual(sections.first?.rows.first?.attentionItem?.kind, .checkpoint)
    }

    func testExceptionsSurfaceInNeedsYouSection() {
        let project = makeProject(name: "Stale", path: "/tmp/stale")
        let summary = OperatorAttentionSummary(
            exceptions: [
                item(kind: .staleSession, projectPath: project.path, title: "Possible stale worker"),
            ],
        )

        let sections = OperatorFieldOfWorkProjection.make(
            projects: [project],
            summary: summary,
            projectOrder: [],
            hiddenProjectPaths: [],
        )

        XCTAssertEqual(sections.map(\.kind), [.needsYou])
        XCTAssertEqual(sections.first?.rows.first?.attentionItem?.kind, .staleSession)
    }

    func testWaitingWorkBatchExceptionSurfacesInNeedsYouSection() {
        let project = makeProject(name: "Batch", path: "/tmp/batch")
        let summary = OperatorAttentionSummary(
            exceptions: [
                item(kind: .waitingWorkBatch, projectPath: project.path, title: "Batch needs recovery"),
            ],
        )

        let sections = OperatorFieldOfWorkProjection.make(
            projects: [project],
            summary: summary,
            projectOrder: [],
            hiddenProjectPaths: [],
        )

        XCTAssertEqual(sections.map(\.kind), [.needsYou])
        XCTAssertEqual(sections.first?.rows.first?.attentionItem?.kind, .waitingWorkBatch)
    }

    func testCheckpointBeatsExceptionForSameProject() {
        let project = makeProject(name: "Needs Direction", path: "/tmp/needs-direction")
        let summary = OperatorAttentionSummary(
            needsYou: [
                item(kind: .checkpoint, projectPath: project.path, title: "Checkpoint ready"),
            ],
            exceptions: [
                item(kind: .staleRun, projectPath: project.path, title: "Possibly stale"),
            ],
        )

        let sections = OperatorFieldOfWorkProjection.make(
            projects: [project],
            summary: summary,
            projectOrder: [],
            hiddenProjectPaths: [],
        )

        XCTAssertEqual(sections.map(\.kind), [.needsYou])
        XCTAssertEqual(sections.first?.rows.count, 1)
        XCTAssertEqual(sections.first?.rows.first?.attentionItem?.kind, .checkpoint)
    }

    func testManualHiddenProjectStaysMarkedInsideDormantHiddenSection() {
        let visibleDormant = makeProject(name: "Dormant", path: "/tmp/dormant")
        let hiddenDormant = makeProject(name: "Hidden", path: "/tmp/hidden")
        let summary = OperatorAttentionSummary(
            dormant: [
                item(kind: .dormantProject, projectPath: visibleDormant.path, title: "Dormant"),
                item(kind: .dormantProject, projectPath: hiddenDormant.path, title: "Hidden"),
            ],
        )

        let sections = OperatorFieldOfWorkProjection.make(
            projects: [visibleDormant, hiddenDormant],
            summary: summary,
            projectOrder: [],
            hiddenProjectPaths: [hiddenDormant.path],
        )

        XCTAssertEqual(sections.map(\.kind), [.dormantHidden])
        XCTAssertEqual(sections.first?.rows.map(\.project.path), [
            visibleDormant.path,
            hiddenDormant.path,
        ])
        XCTAssertEqual(sections.first?.rows.map(\.isHidden), [false, true])
    }

    func testProjectsMissingFromAttentionSummaryStillRenderAsDormantHiddenFallback() {
        let project = makeProject(name: "Missing Signal", path: "/tmp/missing-signal")

        let sections = OperatorFieldOfWorkProjection.make(
            projects: [project],
            summary: OperatorAttentionSummary(),
            projectOrder: [],
            hiddenProjectPaths: [],
        )

        XCTAssertEqual(sections.map(\.kind), [.dormantHidden])
        XCTAssertEqual(sections.first?.rows.first?.project.path, project.path)
        XCTAssertNil(sections.first?.rows.first?.attentionItem)
    }

    func testSectionKindsPreserveExistingCardActivityContexts() {
        XCTAssertEqual(OperatorFieldOfWorkSection.Kind.needsYou.cardActivityGroup, .active)
        XCTAssertEqual(OperatorFieldOfWorkSection.Kind.runningNormally.cardActivityGroup, .active)
        XCTAssertEqual(OperatorFieldOfWorkSection.Kind.recentlyChanged.cardActivityGroup, .active)
        XCTAssertEqual(OperatorFieldOfWorkSection.Kind.dormantHidden.cardActivityGroup, .idle)
    }

    private func item(
        kind: OperatorAttentionItem.Kind,
        projectPath: String,
        title: String,
    ) -> OperatorAttentionItem {
        OperatorAttentionItem(
            id: "\(kind)-\(projectPath)",
            kind: kind,
            projectPath: projectPath,
            title: title,
            reason: title,
            ageLabel: nil,
            recommendedAction: nil,
            target: .project(path: projectPath),
        )
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    private func makeRun(
        id: String,
        projectPath: String,
        status: String,
        updatedAt: String,
        activeCheckpoint: RuntimeCheckpointState? = nil,
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: id,
            projectPath: projectPath,
            methodId: "method",
            methodName: "Method",
            status: try! RunStatus.decode(wire: status),
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: "Run in progress",
            createdAt: "2026-05-24T14:00:00Z",
            updatedAt: updatedAt,
            activeCheckpoint: activeCheckpoint,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    private func makeCheckpoint(
        id: String,
        title: String,
        createdAt: String,
    ) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: id,
            phaseId: "phase",
            kind: .implementationMilestone,
            status: "pending",
            title: title,
            summary: "Needs direction",
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureStatus: .notRequested,
            captureUrl: nil,
            captureClaim: nil,
            createdAt: createdAt,
            decidedAt: nil,
        )
    }

    private func runsByID(_ runs: [RuntimeRunState]) -> [RuntimeRunKey: RuntimeRunState] {
        Dictionary(uniqueKeysWithValues: runs.map { (RuntimeRunKey(run: $0), $0) })
    }
}
