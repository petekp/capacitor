@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class AppStateRuntimeSnapshotEffectTests: XCTestCase {
    func testRuntimeSnapshotApplyExecutesSelectedEffectsThroughAppState() async {
        let appState = AppState(runtimeClient: RuntimeClient(isEnabledOverride: false))
        appState.cancelRuntimeAutomationForTesting()
        var featureFlags = FeatureFlags.defaults(for: .frontier)
        featureFlags.projectDetails = true
        featureFlags.delegationLoop = true
        appState.featureState.configure(with: AppConfig(
            channel: .alpha,
            profile: .frontier,
            featureFlags: featureFlags,
        ))

        let project = makeProject(path: "/tmp/capacitor")
        let delegation = makeDelegation(projectPath: project.path)
        let run = makeRun(projectPath: project.path, runID: "run-1")
        var observedEffects: [RuntimeSnapshotApplicator.Effect] = []
        appState.setRuntimeSnapshotEffectHandlersForTesting(RuntimeSnapshotEffectHandlers(
            updatePostSessionRefreshContext: {
                observedEffects.append(.updatePostSessionRefreshContext)
            },
            reconcileDelegations: { delegations in
                observedEffects.append(.reconcileDelegations(delegations))
            },
            reconcileRunCaptures: { runs in
                observedEffects.append(.reconcileRunCaptures(runs))
            },
        ))

        appState.setRuntimeSnapshotGenerationForTesting(1)
        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                delegations: [delegation],
                runs: [run],
            ),
            refreshGeneration: 1,
            correlationId: "effect-bridge",
            projects: [project],
        )

        XCTAssertEqual(observedEffects, [
            .reconcileDelegations([delegation]),
            .reconcileRunCaptures([run]),
            .updatePostSessionRefreshContext,
        ])
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

    private func makeRuntimeSnapshot(
        projectPath: String,
        delegations: [RuntimeDelegationState],
        runs: [RuntimeRunState],
    ) -> RuntimeSnapshot {
        let timestamp = "2026-04-17T00:00:00Z"
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
            delegations: delegations,
            runs: runs,
            snapshotVersion: 0,
        )
    }

    private func makeDelegation(projectPath: String) -> RuntimeDelegationState {
        RuntimeDelegationState(
            projectPath: projectPath,
            workerId: "worker-1",
            ideaId: nil,
            worktreeName: "worker-1",
            worktreePath: "\(projectPath)-worker-1",
            sessionId: "session-1",
            status: "active",
            startedAt: "2026-04-17T00:00:00Z",
            updatedAt: "2026-04-17T00:00:00Z",
            currentReview: nil,
        )
    }

    private func makeRun(projectPath: String, runID: String) -> RuntimeRunState {
        RuntimeRunState(
            id: runID,
            projectPath: projectPath,
            methodId: "checkpoint-review",
            methodName: "Checkpoint Review",
            status: "paused",
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: nil,
            createdAt: "2026-04-17T00:00:00Z",
            updatedAt: "2026-04-17T00:00:00Z",
            activeCheckpoint: nil,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }
}
