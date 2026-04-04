@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class AppStateRunCheckpointTests: XCTestCase {
    func testFreshRuntimeSnapshotTargetsRunCheckpointWithoutTouchingDelegationReviewState() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projectState.projects = [project]
        appState.uiState.reviewWindowTarget = AppState.ReviewWindowTarget(
            projectPath: project.path,
            workerID: "worker-existing",
        )
        appState.setRuntimeSnapshotGenerationForTesting(1)

        let run = makeRun(
            projectPath: project.path,
            runID: "run-checkpoint-1",
            checkpointID: "checkpoint-1",
            checkpointCreatedAt: "2026-03-24T10:00:00Z",
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [run]),
            refreshGeneration: 1,
            correlationId: "run-checkpoint-target",
            projects: [project],
        )

        XCTAssertEqual(
            appState.uiState.runCheckpointWindowTarget,
            AppState.RunCheckpointWindowTarget(
                projectPath: project.path,
                runID: run.id,
                checkpointID: "checkpoint-1",
            ),
        )
        XCTAssertEqual(
            appState.uiState.reviewWindowTarget,
            AppState.ReviewWindowTarget(
                projectPath: project.path,
                workerID: "worker-existing",
            ),
            "run checkpoints should not mutate delegation review presentation state",
        )
    }

    func testFreshRuntimeSnapshotChoosesOldestPausedRunCheckpointFirst() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projectState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        let newerRun = makeRun(
            projectPath: project.path,
            runID: "run-zeta",
            checkpointID: "checkpoint-newer",
            checkpointCreatedAt: "2026-03-24T10:05:00Z",
        )
        let olderRun = makeRun(
            projectPath: project.path,
            runID: "run-alpha",
            checkpointID: "checkpoint-older",
            checkpointCreatedAt: "2026-03-24T10:00:00Z",
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [newerRun, olderRun]),
            refreshGeneration: 1,
            correlationId: "run-checkpoint-ordering",
            projects: [project],
        )

        XCTAssertEqual(
            appState.uiState.runCheckpointWindowTarget,
            AppState.RunCheckpointWindowTarget(
                projectPath: project.path,
                runID: olderRun.id,
                checkpointID: "checkpoint-older",
            ),
        )
    }

    func testFreshRuntimeSnapshotPresentsNextPausedRunCheckpointAfterFirstCheckpointClears() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projectState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        let olderRun = makeRun(
            projectPath: project.path,
            runID: "run-alpha",
            checkpointID: "checkpoint-older",
            checkpointCreatedAt: "2026-03-24T10:00:00Z",
        )
        let newerRun = makeRun(
            projectPath: project.path,
            runID: "run-zeta",
            checkpointID: "checkpoint-newer",
            checkpointCreatedAt: "2026-03-24T10:05:00Z",
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [newerRun, olderRun]),
            refreshGeneration: 1,
            correlationId: "run-checkpoint-next-initial",
            projects: [project],
        )

        XCTAssertEqual(
            appState.uiState.runCheckpointWindowTarget,
            AppState.RunCheckpointWindowTarget(
                projectPath: project.path,
                runID: olderRun.id,
                checkpointID: "checkpoint-older",
            ),
        )

        let resumedOlderRun = makeRun(
            projectPath: project.path,
            runID: olderRun.id,
            status: "active",
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(projectPath: project.path, runs: [resumedOlderRun, newerRun]),
            refreshGeneration: 1,
            correlationId: "run-checkpoint-next-after-clear",
            projects: [project],
        )

        XCTAssertEqual(
            appState.uiState.runCheckpointWindowTarget,
            AppState.RunCheckpointWindowTarget(
                projectPath: project.path,
                runID: newerRun.id,
                checkpointID: "checkpoint-newer",
            ),
        )
    }

    func testSubmitRunCheckpointDecisionMutatesRuntimeRunWithCheckpointIdentity() async throws {
        var capturedRequest: URLRequest?
        let runtimeClient = try RuntimeClient(
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:7812")),
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                capturedRequest = request
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                return (Data(#"{"ok":true,"message":"decision submitted"}"#.utf8), response)
            },
        )
        let appState = AppState(runtimeClient: runtimeClient)
        appState.cancelRuntimeAutomationForTesting()

        try await appState.submitRunCheckpointDecision(
            projectPath: "/Users/petepetrash/Code/capacitor",
            runID: "run-123",
            checkpointID: "checkpoint-456",
            action: "request_changes",
            note: "Please tighten the review notes.",
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/runtime/run/mutate")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["kind"] as? String, "submit_decision")
        XCTAssertEqual(payload["project_path"] as? String, "/Users/petepetrash/Code/capacitor")
        XCTAssertEqual(payload["run_id"] as? String, "run-123")
        XCTAssertEqual(payload["checkpoint_id"] as? String, "checkpoint-456")
        XCTAssertEqual(payload["decision_action"] as? String, "request_changes")
        XCTAssertEqual(payload["decision_note"] as? String, "Please tighten the review notes.")
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

    private func makeRuntimeSnapshot(
        projectPath: String,
        runs: [RuntimeRunState],
    ) -> RuntimeSnapshot {
        let timestamp = "2026-03-24T10:00:00Z"
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
        checkpointID: String? = nil,
        checkpointCreatedAt: String? = nil,
        status: String = "paused",
    ) -> RuntimeRunState {
        let timestamp = "2026-03-24T10:00:00Z"
        let activeCheckpoint: RuntimeCheckpointState? = if let checkpointID, let checkpointCreatedAt {
            RuntimeCheckpointState(
                id: checkpointID,
                phaseId: "phase-\(checkpointID)",
                kind: .implementationMilestone,
                status: "active",
                title: "Checkpoint \(checkpointID)",
                summary: "Review the current milestone.",
                briefPath: nil,
                manifestPath: nil,
                mediaArtifacts: [],
                mermaidSources: [],
                captureStatus: .notRequested,
                captureUrl: nil,
                captureClaim: nil,
                createdAt: checkpointCreatedAt,
                decidedAt: nil,
            )
        } else {
            nil
        }

        return RuntimeRunState(
            id: runID,
            projectPath: projectPath,
            methodId: "checkpoint-review",
            methodName: "Checkpoint Review",
            status: status,
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            activeCheckpoint: activeCheckpoint,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }
}
