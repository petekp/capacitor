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

    private func makeProject(path: String) -> Project {
        Project(
            name: "Capacitor",
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
                    state: "working",
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
            snapshotVersion: 0,
        )
    }

    private func makeRun(
        projectPath: String,
        runID: String,
        status: String,
        ideaId: String?,
        createdAt: String,
        updatedAt: String,
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: runID,
            projectPath: projectPath,
            methodId: "method-1",
            methodName: "Method",
            status: status,
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: "Drafting packet",
            createdAt: createdAt,
            updatedAt: updatedAt,
            activeCheckpoint: nil,
            ideaId: ideaId,
            ideaTitle: "Fix bug",
            ideaDescription: "Description",
        )
    }
}
