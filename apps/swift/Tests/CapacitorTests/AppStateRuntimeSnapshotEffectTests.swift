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

    func testRuntimeSnapshotApplyReconcilesWorkBatchBindings() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        let worktreeURL = projectRoot.appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let stateStore = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        let bindingStore = WorkBatchCockpitBindingStore(
            fileURL: tempDir.appendingPathComponent("bindings.json"),
            fileManager: fileManager,
        )
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        try stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: projectRoot.path,
                    status: .waiting,
                    currentActivitySummary: "Claude Code session needs reconnect.",
                    taskIDs: ["task-green"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: .queued,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        ))
        try bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: projectRoot.path,
            worktreeName: "batch-mobile",
            worktreePath: worktreeURL.path,
            host: .claudeCode,
            claudeSessionID: "session-batch",
            status: .stale,
            createdAt: now,
            updatedAt: now,
        ))

        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in stateStore },
            bindingStoreFactory: { _ in bindingStore },
            taskSessionCoordinator: WorkBatchTaskSessionCoordinator(
                wakeExistingTerminal: { projectPath, sessionName, prompt in
                    await wakeRecorder.record(
                        projectPath: projectPath,
                        sessionName: sessionName,
                        prompt: prompt,
                    )
                },
            ),
        )
        let appState = AppState(
            runtimeClient: RuntimeClient(isEnabledOverride: false),
            workBatchAutoRouter: router,
        )
        appState.cancelRuntimeAutomationForTesting()
        appState.setRuntimeSnapshotGenerationForTesting(1)
        let project = makeProject(path: projectRoot.path)

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: projectRoot.path,
                sessions: [
                    makeRuntimeSession(
                        sessionId: "session-batch",
                        cwd: worktreeURL.path,
                        projectPath: worktreeURL.path,
                    ),
                ],
                delegations: [],
                runs: [],
            ),
            refreshGeneration: 1,
            correlationId: "work-batch-reconcile",
            projects: [project],
        )

        XCTAssertEqual(try bindingStore.binding(batchID: "batch-mobile")?.status, .running)
        XCTAssertEqual(try stateStore.load().batches[0].status, .working)
        XCTAssertNil(try stateStore.load().deliveryRecord(batchID: "batch-mobile")?.lastDeliveryAttemptKind)
        let wakes = await wakeRecorder.snapshot()
        XCTAssertEqual(wakes, [])
    }

    func testRuntimeSnapshotApplyIngestsWorkBatchTaskClaims() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        let worktreeURL = projectRoot.appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let stateStore = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        let bindingStore = WorkBatchCockpitBindingStore(
            fileURL: tempDir.appendingPathComponent("bindings.json"),
            fileManager: fileManager,
        )
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let claimTime = now.addingTimeInterval(20)
        try stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: projectRoot.path,
                    status: .working,
                    currentActivitySummary: "Queued Add green border.",
                    taskIDs: ["task-green"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: .queued,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
            deliveryRecords: [
                WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: now,
                    lastDeliveryGeneration: "batch-mobile:current",
                    lastDeliveryAttemptAt: nil,
                    lastDeliveryAttemptKind: nil,
                    lastClaimAt: nil,
                ),
            ],
        ))
        try bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: projectRoot.path,
            worktreeName: "batch-mobile",
            worktreePath: worktreeURL.path,
            host: .claudeCode,
            claudeSessionID: "session-batch",
            status: .running,
            createdAt: now,
            updatedAt: now,
        ))
        _ = try WorkBatchTaskClaimStore(worktreePath: worktreeURL.path, fileManager: fileManager)
            .write(WorkBatchTaskClaim(
                taskID: "task-green",
                status: "working",
                summary: "Working on the queued green border Task.",
                claimedAt: claimTime,
                contextUpdatedAt: now,
                deliveryGeneration: "batch-mobile:current",
            ))

        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in stateStore },
            bindingStoreFactory: { _ in bindingStore },
        )
        let appState = AppState(
            runtimeClient: RuntimeClient(isEnabledOverride: false),
            workBatchAutoRouter: router,
        )
        appState.cancelRuntimeAutomationForTesting()
        appState.setRuntimeSnapshotGenerationForTesting(1)
        let project = makeProject(path: projectRoot.path)

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: projectRoot.path,
                sessions: [
                    makeRuntimeSession(
                        sessionId: "session-batch",
                        cwd: worktreeURL.path,
                        projectPath: worktreeURL.path,
                    ),
                ],
                delegations: [],
                runs: [],
            ),
            refreshGeneration: 1,
            correlationId: "work-batch-claim",
            projects: [project],
        )

        let state = try stateStore.load()
        XCTAssertEqual(state.tasks[0].status, .working)
        XCTAssertEqual(state.tasks[0].updatedAt, claimTime)
        XCTAssertEqual(state.batches[0].currentActivitySummary, "Working on the queued green border Task.")
        XCTAssertEqual(state.deliveryRecord(batchID: "batch-mobile")?.lastClaimAt, claimTime)
        XCTAssertNil(appState.uiState.toast)
    }

    func testRuntimeSnapshotApplyIngestsWorkBatchCompletionReportsAndShowsToast() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        let worktreeURL = projectRoot.appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let stateStore = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        let bindingStore = WorkBatchCockpitBindingStore(
            fileURL: tempDir.appendingPathComponent("bindings.json"),
            fileManager: fileManager,
        )
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        try stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: projectRoot.path,
                    status: .working,
                    currentActivitySummary: "Adding green border.",
                    taskIDs: ["task-green"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: .working,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        ))
        try bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: projectRoot.path,
            worktreeName: "batch-mobile",
            worktreePath: worktreeURL.path,
            host: .claudeCode,
            claudeSessionID: "session-batch",
            status: .running,
            createdAt: now,
            updatedAt: now,
        ))
        _ = try WorkBatchCompletionReportStore(worktreePath: worktreeURL.path, fileManager: fileManager)
            .write(WorkBatchCompletionReport(
                taskID: "task-green",
                status: "done",
                summary: "Added green border",
                evidence: ["Updated prototype styles"],
                completedAt: now.addingTimeInterval(10),
            ))

        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in stateStore },
            bindingStoreFactory: { _ in bindingStore },
        )
        let appState = AppState(
            runtimeClient: RuntimeClient(isEnabledOverride: false),
            workBatchAutoRouter: router,
        )
        appState.cancelRuntimeAutomationForTesting()
        appState.setRuntimeSnapshotGenerationForTesting(1)
        let project = makeProject(path: projectRoot.path)

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: projectRoot.path,
                sessions: [
                    makeRuntimeSession(
                        sessionId: "session-batch",
                        cwd: worktreeURL.path,
                        projectPath: worktreeURL.path,
                    ),
                ],
                delegations: [],
                runs: [],
            ),
            refreshGeneration: 1,
            correlationId: "work-batch-completion",
            projects: [project],
        )

        XCTAssertEqual(appState.uiState.toast?.message, "Task done: Add green border.")
        XCTAssertEqual(try stateStore.load().tasks[0].status, .done)
        XCTAssertEqual(try stateStore.load().batches[0].status, .ready)
        XCTAssertEqual(try bindingStore.binding(batchID: "batch-mobile")?.status, .done)
    }

    func testRuntimeSnapshotApplyIngestsWorkBatchCheckpointRequestsAndShowsToast() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        let worktreeURL = projectRoot.appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let stateStore = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        let bindingStore = WorkBatchCockpitBindingStore(
            fileURL: tempDir.appendingPathComponent("bindings.json"),
            fileManager: fileManager,
        )
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        try stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: projectRoot.path,
                    status: .working,
                    currentActivitySummary: "Adding green border.",
                    taskIDs: ["task-green"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: .working,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        ))
        try bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: projectRoot.path,
            worktreeName: "batch-mobile",
            worktreePath: worktreeURL.path,
            host: .claudeCode,
            claudeSessionID: "session-batch",
            status: .running,
            createdAt: now,
            updatedAt: now,
        ))
        _ = try WorkBatchCheckpointRequestStore(worktreePath: worktreeURL.path, fileManager: fileManager)
            .write(WorkBatchCheckpointRequest(
                checkpointID: "checkpoint-green-token",
                taskID: "task-green",
                question: "Which green token should I use?",
                reason: "The Task did not say whether this is debug-only.",
                recommendedAction: "Use production if this is product-facing.",
                requestedAt: now.addingTimeInterval(10),
            ))

        let router = WorkBatchAutoRouter(
            classifier: { _ in throw NSError(domain: "test", code: 1) },
            stateStoreFactory: { _ in stateStore },
            bindingStoreFactory: { _ in bindingStore },
        )
        let appState = AppState(
            runtimeClient: RuntimeClient(isEnabledOverride: false),
            workBatchAutoRouter: router,
        )
        appState.cancelRuntimeAutomationForTesting()
        appState.setRuntimeSnapshotGenerationForTesting(1)
        let project = makeProject(path: projectRoot.path)

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: projectRoot.path,
                sessions: [
                    makeRuntimeSession(
                        sessionId: "session-batch",
                        cwd: worktreeURL.path,
                        projectPath: worktreeURL.path,
                    ),
                ],
                delegations: [],
                runs: [],
            ),
            refreshGeneration: 1,
            correlationId: "work-batch-checkpoint",
            projects: [project],
        )

        XCTAssertEqual(appState.uiState.toast?.message, "Checkpoint ready: Add green border.")
        XCTAssertEqual(try stateStore.load().tasks[0].status, .needsYou)
        XCTAssertEqual(try stateStore.load().batches[0].status, .waiting)
        XCTAssertEqual(try stateStore.load().checkpoints.first?.status, .pending)
        XCTAssertEqual(try bindingStore.binding(batchID: "batch-mobile")?.status, .waiting)
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
        sessions: [RuntimeSession] = [],
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
            sessions: sessions,
            shellState: ShellCwdState(version: 1, shells: [:]),
            routingViews: [],
            delegations: delegations,
            runs: runs,
            snapshotVersion: 0,
        )
    }

    private func makeRuntimeSession(
        sessionId: String,
        cwd: String,
        projectPath: String,
    ) -> RuntimeSession {
        RuntimeSession(
            sessionId: sessionId,
            pid: 1234,
            state: "working",
            cwd: cwd,
            projectId: nil,
            workspaceId: nil,
            projectPath: projectPath,
            updatedAt: "2026-04-17T00:00:00Z",
            stateChangedAt: "2026-04-17T00:00:00Z",
            lastEvent: nil,
            lastActivityAt: nil,
            toolsInFlight: nil,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
            gcReason: nil,
            isAlive: true,
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

private actor ExistingTerminalWakeRecorder {
    struct Attempt: Equatable {
        let projectPath: String
        let sessionName: String?
        let prompt: String
    }

    private let result: Bool
    private var attempts: [Attempt] = []

    init(result: Bool) {
        self.result = result
    }

    func record(projectPath: String, sessionName: String?, prompt: String) -> Bool {
        attempts.append(Attempt(projectPath: projectPath, sessionName: sessionName, prompt: prompt))
        return result
    }

    func snapshot() -> [Attempt] {
        attempts
    }
}
