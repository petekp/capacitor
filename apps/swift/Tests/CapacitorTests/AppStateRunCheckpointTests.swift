@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class AppStateRunCheckpointTests: XCTestCase {
    func testFreshRuntimeSnapshotTargetsRunCheckpointWithoutTouchingDelegationReviewState() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projects = [project]
        appState.reviewWindowTarget = AppState.ReviewWindowTarget(
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
            appState.runCheckpointWindowTarget,
            AppState.RunCheckpointWindowTarget(
                projectPath: project.path,
                runID: run.id,
                checkpointID: "checkpoint-1",
            ),
        )
        XCTAssertEqual(
            appState.reviewWindowTarget,
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
        appState.projects = [project]
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
            appState.runCheckpointWindowTarget,
            AppState.RunCheckpointWindowTarget(
                projectPath: project.path,
                runID: olderRun.id,
                checkpointID: "checkpoint-older",
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
        )
    }

    private func makeRun(
        projectPath: String,
        runID: String,
        checkpointID: String,
        checkpointCreatedAt: String,
    ) -> RuntimeRunState {
        let timestamp = "2026-03-24T10:00:00Z"
        return RuntimeRunState(
            id: runID,
            projectPath: projectPath,
            methodId: "checkpoint-review",
            methodName: "Checkpoint Review",
            status: "paused",
            sessionId: "session-1",
            delegationWorkerId: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            activeCheckpoint: RuntimeCheckpointState(
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
            ),
        )
    }
}
