@testable import Capacitor
import XCTest

@MainActor
final class AppStateRunTests: XCTestCase {
    func testActiveRunPrefersMostRecentNonTerminalRunForIdea() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: "/tmp/core-project")
        let idea = makeIdea()
        appState.projectState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        let olderPausedRun = makeRun(
            projectPath: project.path,
            runID: "run-older",
            status: "paused",
            ideaId: idea.id,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:01:00Z",
        )
        let newerActiveRun = makeRun(
            projectPath: project.path,
            runID: "run-newer",
            status: "active",
            ideaId: idea.id,
            createdAt: "2026-03-26T10:02:00Z",
            updatedAt: "2026-03-26T10:05:00Z",
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [olderPausedRun, newerActiveRun]),
            refreshGeneration: 1,
            correlationId: "active-run-most-recent",
            projects: [project],
        )

        XCTAssertEqual(appState.activeRun(for: idea, in: project)?.id, newerActiveRun.id)
    }

    func testActiveRunExcludesTerminalRunsForIdea() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: "/tmp/core-project")
        let idea = makeIdea()
        appState.projectState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        let completedRun = makeRun(
            projectPath: project.path,
            runID: "run-completed",
            status: "completed",
            ideaId: idea.id,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:05:00Z",
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [completedRun]),
            refreshGeneration: 1,
            correlationId: "active-run-terminal-excluded",
            projects: [project],
        )

        XCTAssertNil(appState.activeRun(for: idea, in: project))
    }

    func testActiveRunExcludesRunsForDifferentIdea() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: "/tmp/core-project")
        let idea = makeIdea()
        appState.projectState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        let otherIdeaRun = makeRun(
            projectPath: project.path,
            runID: "run-other-idea",
            status: "active",
            ideaId: "idea-2",
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:05:00Z",
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [otherIdeaRun]),
            refreshGeneration: 1,
            correlationId: "active-run-idea-mismatch",
            projects: [project],
        )

        XCTAssertNil(appState.activeRun(for: idea, in: project))
    }

    func testCheckpointTimelineRunIncludesCompletedHistoryOutsideVisualRunWindow() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: "/tmp/core-project")
        appState.projectState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        let completedRun = makeRun(
            projectPath: project.path,
            runID: "run-completed-history",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:20:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-approved",
                    createdAt: "2026-03-26T10:10:00Z",
                    decidedAt: "2026-03-26T10:15:00Z",
                    decisionAction: "approve",
                ),
            ],
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [completedRun]),
            refreshGeneration: 1,
            correlationId: "checkpoint-timeline-terminal-history",
            projects: [project],
        )

        XCTAssertEqual(appState.checkpointTimelineRun(for: project)?.id, completedRun.id)
    }

    func testCheckpointTimelineRunIsNotDisplacedByNewerActiveRunWithoutCheckpoints() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: "/tmp/core-project")
        appState.projectState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        let historyRun = makeRun(
            projectPath: project.path,
            runID: "run-history",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:15:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-approved",
                    createdAt: "2026-03-26T10:10:00Z",
                    decidedAt: "2026-03-26T10:14:00Z",
                    decisionAction: "approve",
                ),
            ],
        )
        let activeRunWithoutHistory = makeRun(
            projectPath: project.path,
            runID: "run-active",
            status: "active",
            ideaId: nil,
            createdAt: "2026-03-26T10:20:00Z",
            updatedAt: "2026-03-26T10:30:00Z",
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [historyRun, activeRunWithoutHistory]),
            refreshGeneration: 1,
            correlationId: "checkpoint-timeline-not-visual-run",
            projects: [project],
        )

        XCTAssertEqual(appState.activeRun(for: project)?.id, activeRunWithoutHistory.id)
        XCTAssertEqual(appState.checkpointTimelineRun(for: project)?.id, historyRun.id)
    }

    func testCheckpointTimelineRunPrefersLatestCheckpointEventAcrossHistoryRuns() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: "/tmp/core-project")
        appState.projectState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        let olderEventRun = makeRun(
            projectPath: project.path,
            runID: "run-newer-updated-older-event",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:40:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-older-event",
                    createdAt: "2026-03-26T10:10:00Z",
                    decidedAt: "2026-03-26T10:15:00Z",
                    decisionAction: "approve",
                ),
            ],
        )
        let newerEventRun = makeRun(
            projectPath: project.path,
            runID: "run-older-updated-newer-event",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:01:00Z",
            updatedAt: "2026-03-26T10:20:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-newer-event",
                    createdAt: "2026-03-26T10:12:00Z",
                    decidedAt: "2026-03-26T10:30:00Z",
                    decisionAction: "approve",
                ),
            ],
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [olderEventRun, newerEventRun]),
            refreshGeneration: 1,
            correlationId: "checkpoint-timeline-latest-event",
            projects: [project],
        )

        XCTAssertEqual(appState.checkpointTimelineRun(for: project)?.id, newerEventRun.id)
    }

    func testCheckpointTimelineRunUsesUpdatedAtWhenCheckpointEventsMatch() async {
        let projectPath = "/tmp/core-project"
        let olderUpdatedRun = makeRun(
            projectPath: projectPath,
            runID: "run-older-updated",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:10:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-same-event-a",
                    createdAt: "2026-03-26T10:05:00Z",
                    decidedAt: "2026-03-26T10:08:00Z",
                    decisionAction: "approve",
                ),
            ],
        )
        let newerUpdatedRun = makeRun(
            projectPath: projectPath,
            runID: "run-newer-updated",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:20:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-same-event-b",
                    createdAt: "2026-03-26T10:06:00Z",
                    decidedAt: "2026-03-26T10:08:00Z",
                    decisionAction: "approve",
                ),
            ],
        )

        let selectedID = await checkpointTimelineRunID(
            projectPath: projectPath,
            runs: [olderUpdatedRun, newerUpdatedRun],
            correlationId: "checkpoint-timeline-updated-tiebreaker",
        )

        XCTAssertEqual(selectedID, newerUpdatedRun.id)
    }

    func testCheckpointTimelineRunUsesCreatedAtWhenCheckpointEventAndUpdatedAtMatch() async {
        let projectPath = "/tmp/core-project"
        let olderCreatedRun = makeRun(
            projectPath: projectPath,
            runID: "run-older-created",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T09:50:00Z",
            updatedAt: "2026-03-26T10:20:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-same-event-a",
                    createdAt: "2026-03-26T10:05:00Z",
                    decidedAt: "2026-03-26T10:08:00Z",
                    decisionAction: "approve",
                ),
            ],
        )
        let newerCreatedRun = makeRun(
            projectPath: projectPath,
            runID: "run-newer-created",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:20:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-same-event-b",
                    createdAt: "2026-03-26T10:06:00Z",
                    decidedAt: "2026-03-26T10:08:00Z",
                    decisionAction: "approve",
                ),
            ],
        )

        let selectedID = await checkpointTimelineRunID(
            projectPath: projectPath,
            runs: [olderCreatedRun, newerCreatedRun],
            correlationId: "checkpoint-timeline-created-tiebreaker",
        )

        XCTAssertEqual(selectedID, newerCreatedRun.id)
    }

    func testCheckpointTimelineRunUsesRunIDWhenTimestampTiebreakersMatch() async {
        let projectPath = "/tmp/core-project"
        let higherIDRun = makeRun(
            projectPath: projectPath,
            runID: "run-z",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:20:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-z",
                    createdAt: "2026-03-26T10:05:00Z",
                    decidedAt: "2026-03-26T10:08:00Z",
                    decisionAction: "approve",
                ),
            ],
        )
        let lowerIDRun = makeRun(
            projectPath: projectPath,
            runID: "run-a",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:20:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-a",
                    createdAt: "2026-03-26T10:06:00Z",
                    decidedAt: "2026-03-26T10:08:00Z",
                    decisionAction: "approve",
                ),
            ],
        )

        let selectedID = await checkpointTimelineRunID(
            projectPath: projectPath,
            runs: [higherIDRun, lowerIDRun],
            correlationId: "checkpoint-timeline-run-id-tiebreaker",
        )

        XCTAssertEqual(selectedID, lowerIDRun.id)
    }

    func testCheckpointTimelineRunIncludesActiveCheckpointOnlyRun() async {
        let projectPath = "/tmp/core-project"
        let activeCheckpointRun = makeRun(
            projectPath: projectPath,
            runID: "run-active-checkpoint-only",
            status: "paused",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:10:00Z",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-active",
                createdAt: "2026-03-26T10:09:00Z",
            ),
        )

        let selectedID = await checkpointTimelineRunID(
            projectPath: projectPath,
            runs: [activeCheckpointRun],
            correlationId: "checkpoint-timeline-active-only",
        )

        XCTAssertEqual(selectedID, activeCheckpointRun.id)
    }

    func testCheckpointTimelineRunTreatsInvalidCheckpointTimestampBehindValidTimestamp() async {
        let projectPath = "/tmp/core-project"
        let invalidEventRun = makeRun(
            projectPath: projectPath,
            runID: "run-invalid-event",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:30:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-invalid-event",
                    createdAt: "not-a-date",
                    decidedAt: nil,
                    decisionAction: "approve",
                ),
            ],
        )
        let validEventRun = makeRun(
            projectPath: projectPath,
            runID: "run-valid-event",
            status: "completed",
            ideaId: nil,
            createdAt: "2026-03-26T09:00:00Z",
            updatedAt: "2026-03-26T09:30:00Z",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-valid-event",
                    createdAt: "2026-03-26T09:05:00Z",
                    decidedAt: "2026-03-26T09:10:00Z",
                    decisionAction: "approve",
                ),
            ],
        )

        let selectedID = await checkpointTimelineRunID(
            projectPath: projectPath,
            runs: [invalidEventRun, validEventRun],
            correlationId: "checkpoint-timeline-invalid-event",
        )

        XCTAssertEqual(selectedID, validEventRun.id)
    }

    private func makeProject(path: String) -> Project {
        Project(
            name: "Capacitor",
            path: path,
            workspaceId: WorkspaceIdentity.fromPath(path),
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

    private func makeIdea() -> Idea {
        Idea(
            id: "idea-1",
            title: "Fix bug",
            description: "Description",
            added: "2026-03-26T09:59:00Z",
            effort: "small",
            status: "open",
            triage: "validated",
            related: nil,
        )
    }

    private func checkpointTimelineRunID(
        projectPath: String,
        runs: [RuntimeRunState],
        correlationId: String,
    ) async -> String? {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: projectPath)
        appState.projectState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: runs),
            refreshGeneration: 1,
            correlationId: correlationId,
            projects: [project],
        )

        return appState.checkpointTimelineRun(for: project)?.id
    }

    private func makeRuntimeSnapshot(
        projectPath: String,
        runs: [RuntimeRunState],
    ) -> RuntimeSnapshot {
        let timestamp = "2026-03-26T10:00:00Z"
        return RuntimeSnapshot(
            projectStates: [
                RuntimeProjectState(
                    projectId: nil,
                    workspaceId: nil,
                    projectPath: projectPath,
                    state: .working,
                    updatedAt: timestamp,
                    stateChangedAt: timestamp,
                    sessionId: "session-1",
                    latestSessionId: "session-1",
                    sessionCount: 1,
                    activeCount: 1,
                    hasSession: true,
                ),
            ],
            sessions: [],
            shellState: ShellCwdState(version: 1, shells: [:]),
            routingViews: [],
            delegations: [],
            runs: runs,
            changeVersion: 0,
        )
    }

    private func makeRun(
        projectPath: String,
        runID: String,
        status: String,
        ideaId: String?,
        createdAt: String,
        updatedAt: String,
        activeCheckpoint: RuntimeCheckpointState? = nil,
        pastCheckpoints: [RuntimeCheckpointState] = [],
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: runID,
            projectPath: projectPath,
            methodId: "method-1",
            methodName: "Method",
            status: try! RunStatus.decode(wire: status),
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: "Drafting packet",
            createdAt: createdAt,
            updatedAt: updatedAt,
            activeCheckpoint: activeCheckpoint,
            pastCheckpoints: pastCheckpoints,
            ideaId: ideaId,
            ideaTitle: "Fix bug",
            ideaDescription: "Description",
        )
    }

    private func makeCheckpoint(
        id: String,
        phaseID: String = "phase-1",
        createdAt: String,
        decidedAt: String? = nil,
        decisionAction: String? = nil,
    ) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: id,
            phaseId: phaseID,
            kind: .implementationMilestone,
            status: decidedAt == nil ? "active" : "decided",
            title: "Checkpoint \(id)",
            summary: "Review the current milestone.",
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureStatus: .notRequested,
            captureUrl: nil,
            captureClaim: nil,
            decision: decisionAction.map {
                RuntimeCheckpointDecision(action: $0, note: nil)
            },
            createdAt: createdAt,
            decidedAt: decidedAt,
        )
    }
}
