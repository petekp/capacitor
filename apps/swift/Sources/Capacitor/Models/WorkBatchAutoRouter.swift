import Foundation
import Observation

struct WorkBatchRouteResult: Equatable {
    let batch: WorkBatchRecord
    let task: WorkBatchTaskRecord
    let classification: WorkBatchClassificationRecord
    let binding: WorkBatchCockpitBinding?
    let startedNewSession: Bool
}

struct WorkBatchCompletionIngestResult: Equatable {
    let projectPath: String
    let batchID: String
    let batchName: String
    let taskID: String
    let sourceIdeaID: String?
    let taskTitle: String
    let summary: String
    let evidence: [String]
}

struct WorkBatchCheckpointIngestResult: Equatable {
    let projectPath: String
    let batchID: String
    let batchName: String
    let taskID: String
    let sourceIdeaID: String?
    let taskTitle: String
    let checkpoint: WorkBatchCheckpointRecord
}

struct WorkBatchTaskClaimIngestResult: Equatable {
    let projectPath: String
    let batchID: String
    let batchName: String
    let taskID: String
    let sourceIdeaID: String?
    let taskTitle: String
    let summary: String?
    let claim: WorkBatchTaskClaim
}

struct WorkBatchTaskRequestIngestResult: Equatable {
    let projectPath: String
    let batchID: String
    let batchName: String
    let taskID: String
    let taskTitle: String
    let request: WorkBatchTaskRequest
}

struct WorkBatchContextMirrorWriteResult: Equatable {
    let updatedAt: Date
    let deliveryGeneration: String
    let actionableContextDigest: String?
}

struct WorkBatchCheckpointDecisionResult: Equatable {
    let batch: WorkBatchRecord
    let task: WorkBatchTaskRecord
    let checkpoint: WorkBatchCheckpointRecord
    let binding: WorkBatchCockpitBinding?
}

struct WorkBatchUnresolveResult: Equatable {
    let batch: WorkBatchRecord
    let task: WorkBatchTaskRecord
    let binding: WorkBatchCockpitBinding?
}

enum WorkBatchAutoRouterError: Error, Equatable, LocalizedError {
    case duplicateCockpit(batchName: String)
    case batchNotFound
    case bindingNotFound
    case taskNotFound
    case checkpointNotFound
    case checkpointAlreadyAnswered
    case emptyCheckpointResponse

    var errorDescription: String? {
        switch self {
        case let .duplicateCockpit(batchName):
            "Multiple Claude Code sessions match \(batchName)"
        case .batchNotFound:
            "Work Batch not found"
        case .bindingNotFound:
            "Batch Cockpit Binding not found"
        case .taskNotFound:
            "Task not found"
        case .checkpointNotFound:
            "Checkpoint not found"
        case .checkpointAlreadyAnswered:
            "Checkpoint already answered"
        case .emptyCheckpointResponse:
            "Checkpoint response cannot be empty"
        }
    }
}

@Observable
@MainActor
final class WorkBatchAutoRouter {
    typealias Classifier = @Sendable (WorkBatchClassificationRequest) async throws -> WorkBatchClassificationRecord
    typealias StateStoreFactory = (String) -> WorkBatchStateStore
    typealias BindingStoreFactory = (String) -> WorkBatchCockpitBindingStore
    typealias PreviewStoreFactory = (String) -> WorkBatchPreviewStateStore
    typealias ProcessSessionLookup = WorkBatchBindingReconciler.ProcessSessionLookup
    typealias SafeWakeBoundaryLookup = (WorkBatchCockpitBinding) -> Bool
    typealias PreviewRunner = (MacOSPreviewWorkRequest) async throws -> MacOSPreviewWorkProof
    typealias PreviewActivator = (WorkBatchPreviewRecord) -> Bool
    typealias PreviewRunningMatcher = (WorkBatchPreviewRecord) -> Bool
    typealias PreviewSourceSnapshotLoader = (String) async -> MacOSPreviewSourceSnapshot

    @ObservationIgnored private let classifier: Classifier
    @ObservationIgnored private let stateStoreFactory: StateStoreFactory
    @ObservationIgnored private let bindingStoreFactory: BindingStoreFactory
    @ObservationIgnored private let previewStoreFactory: PreviewStoreFactory
    @ObservationIgnored private let taskSessionCoordinator: WorkBatchTaskSessionCoordinator
    @ObservationIgnored private let processSessionIDs: ProcessSessionLookup
    @ObservationIgnored private let safeWakeBoundaryAllowsInputOverride: SafeWakeBoundaryLookup?
    @ObservationIgnored private let previewRunner: PreviewRunner
    @ObservationIgnored private let previewActivator: PreviewActivator
    @ObservationIgnored private let previewRunningMatcher: PreviewRunningMatcher
    @ObservationIgnored private let previewSourceSnapshotLoader: PreviewSourceSnapshotLoader
    @ObservationIgnored private let previewProjector: WorkBatchPreviewProjector
    @ObservationIgnored private var isRouting = false
    @ObservationIgnored private var routeWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var latestRuntimeSessions: [RuntimeSession] = []
    @ObservationIgnored private var hasRuntimeSessionSnapshot = false

    /// Single in-memory working value per project. Disk (`WorkBatchStateStore`)
    /// is a write-behind sink: this in-memory snapshot is the source of truth.
    /// Lazy-hydrated from disk on first access per project; thereafter all ops
    /// read and mutate this value, and a synchronous `save` mirrors it to disk.
    @ObservationIgnored private var workingState: [String: WorkBatchStateSnapshot] = [:]

    /// Published projections cache the @Observable view graph tracks. Recomputed
    /// after every store-mutating op and seeded lazily on first read per project.
    private(set) var projectionsByProjectPath: [String: [WorkBatchProjection]] = [:]

    init(
        classifier: Classifier? = nil,
        stateStoreFactory: StateStoreFactory? = nil,
        bindingStoreFactory: BindingStoreFactory? = nil,
        previewStoreFactory: PreviewStoreFactory? = nil,
        taskSessionCoordinator: WorkBatchTaskSessionCoordinator? = nil,
        processSessionIDs: ProcessSessionLookup? = nil,
        safeWakeBoundaryAllowsInput: SafeWakeBoundaryLookup? = nil,
        previewRunner: PreviewRunner? = nil,
        previewActivator: PreviewActivator? = nil,
        previewRunningMatcher: PreviewRunningMatcher? = nil,
        previewSourceSnapshotLoader: PreviewSourceSnapshotLoader? = nil,
        previewProjector: WorkBatchPreviewProjector = WorkBatchPreviewProjector(),
    ) {
        let defaultClassifier = ClaudeWorkBatchClassifier()
        let processScanner = WorkBatchClaudeProcessScanner()
        let previewCoordinator = MacOSPreviewWorkCoordinator()
        let previewActivity = WorkBatchPreviewAppActivity()
        self.classifier = classifier ?? { request in
            try await defaultClassifier.classify(request)
        }
        self.stateStoreFactory = stateStoreFactory ?? { projectPath in
            WorkBatchStateStore(projectPath: projectPath)
        }
        self.bindingStoreFactory = bindingStoreFactory ?? { projectPath in
            WorkBatchCockpitBindingStore(projectPath: projectPath)
        }
        self.previewStoreFactory = previewStoreFactory ?? { projectPath in
            WorkBatchPreviewStateStore(projectPath: projectPath)
        }
        self.taskSessionCoordinator = taskSessionCoordinator ?? WorkBatchTaskSessionCoordinator()
        self.processSessionIDs = processSessionIDs ?? { binding in
            processScanner.sessionIDs(inWorktree: binding.worktreePath)
        }
        // New Work Batch delivery keeps the legacy Ghostty text-input path
        // behind a proven safe boundary. Tests may inject an override, but
        // production derives this from reducer-backed runtime session state.
        safeWakeBoundaryAllowsInputOverride = safeWakeBoundaryAllowsInput
        self.previewRunner = previewRunner ?? { request in
            try await previewCoordinator.run(request)
        }
        self.previewActivator = previewActivator ?? { record in
            previewActivity.activate(record: record)
        }
        self.previewRunningMatcher = previewRunningMatcher ?? { record in
            previewActivity.isMatchingRunning(record: record)
        }
        self.previewSourceSnapshotLoader = previewSourceSnapshotLoader ?? { worktreePath in
            await MacOSPreviewSourceFingerprinter.snapshot(worktreeURL: URL(fileURLWithPath: worktreePath, isDirectory: true))
        }
        self.previewProjector = previewProjector
    }

    // MARK: - In-memory working value (write-behind to disk)

    /// Returns the in-memory working snapshot for `projectPath`, lazy-hydrating
    /// from disk on a cache miss. After the first access all ops mutate this
    /// in-memory value, so the snapshot — not disk — is the source of truth.
    private func workingState(for projectPath: String) -> WorkBatchStateSnapshot {
        if let existing = workingState[projectPath] {
            return existing
        }
        let hydrated = (try? stateStoreFactory(projectPath).load()) ?? .empty
        workingState[projectPath] = hydrated
        return hydrated
    }

    /// Commits a mutated working snapshot: updates the single in-memory value,
    /// refreshes the published projections cache, then mirrors to disk as a
    /// write-behind sink. The in-memory value is authoritative; the save is the
    /// durable mirror, not a re-read source.
    private func commitWorkingState(_ snapshot: WorkBatchStateSnapshot, for projectPath: String) {
        workingState[projectPath] = snapshot
        recomputeProjections(for: projectPath)
        do {
            try stateStoreFactory(projectPath).save(snapshot)
        } catch {
            DebugLog.write(
                "WorkBatchAutoRouter.commitWorkingState save failure project=\(projectPath) error=\(error.localizedDescription)",
            )
        }
    }

    /// Recomputes the published projections for `projectPath` from the in-memory
    /// working value plus the on-disk binding/preview stores (the binding store
    /// is the agent<->app worktree contract and stays on disk; the preview store
    /// stays on disk too). Mutating this property drives @Observable re-render.
    private func recomputeProjections(for projectPath: String) {
        projectionsByProjectPath[projectPath] = computeProjections(for: projectPath)
    }

    /// Periodic-poll entry point that refreshes the published projections for
    /// projects whose cached projection embeds LIVE preview state. The preview
    /// piece of a projection is derived from `NSRunningApplication` (via
    /// `WorkBatchPreviewProjector`), which can flip — e.g. the user quits the
    /// preview app — without any store mutation. Store-mutating ops are the only
    /// other thing that recomputes the cache, so without this the cache would
    /// freeze a stale `.ready`/`.conflict` and the UI would show a stale
    /// "Bring Preview Forward"/disabled button. The poll calls this on the same
    /// cadence the old uncached projection enjoyed.
    ///
    /// Re-publishing is diff-gated: we only assign `projectionsByProjectPath`
    /// when the freshly computed value differs from the cached one, so a steady
    /// state (no preview change) does not thrash the @Observable view graph.
    /// The recompute reads the in-memory working value (no disk reload of
    /// state.json) plus the live preview query, so it is cheap.
    func refreshPreviewSensitiveProjections(for projectPaths: [String]) {
        for projectPath in projectPaths where hasPreviewCapableBatch(for: projectPath) {
            recomputeProjectionsIfChanged(for: projectPath)
        }
    }

    /// Recomputes projections and only re-publishes when the value actually
    /// changed. Used by the poll tick to avoid needless render thrash.
    private func recomputeProjectionsIfChanged(for projectPath: String) {
        let computed = computeProjections(for: projectPath)
        if projectionsByProjectPath[projectPath] != computed {
            projectionsByProjectPath[projectPath] = computed
        }
    }

    /// True when this project has at least one batch whose projection could
    /// carry a live preview state worth re-polling. We gate on whether the
    /// project is preview-capable at all (cheap filesystem check) so that
    /// non-Capacitor projects never pay for the live `NSRunningApplication`
    /// query on every tick.
    private func hasPreviewCapableBatch(for projectPath: String) -> Bool {
        guard previewProjector.isCapacitorPreviewBuildToolAvailable(projectPath: projectPath) else {
            return false
        }
        let state = workingState(for: projectPath)
        return !state.batches.isEmpty
    }

    private func computeProjections(for projectPath: String) -> [WorkBatchProjection] {
        let state = workingState(for: projectPath)
        let bindings = (try? bindingStoreFactory(projectPath).load()) ?? []
        let previewRecords = (try? previewStoreFactory(projectPath).load()) ?? []
        let previewProjector = previewProjector
        return WorkBatchProjectionBuilder.build(
            state: state,
            bindings: bindings,
            previewRecords: previewRecords,
        ) { batch, binding, previewRecord in
            previewProjector.projection(
                projectPath: projectPath,
                batch: batch,
                binding: binding,
                previewRecord: previewRecord,
            )
        }
    }

    func routeCapturedTask(
        project: Project,
        idea: Idea,
        now: Date = Date(),
    ) async throws -> WorkBatchRouteResult {
        await acquireRouteTurn()
        defer { releaseRouteTurn() }
        return try await routeCapturedTaskUnlocked(
            project: project,
            idea: idea,
            now: now,
        )
    }

    private func routeCapturedTaskUnlocked(
        project: Project,
        idea: Idea,
        now: Date,
    ) async throws -> WorkBatchRouteResult {
        let task = WorkBatchTaskRecord(
            id: idea.id,
            sourceIdeaID: idea.id,
            title: normalizedTitle(for: idea),
            body: idea.description,
            status: .queued,
            batchID: "",
            createdAt: now,
            updatedAt: now,
        )

        let bindingStore = bindingStoreFactory(project.path)
        var bindings = try bindingStore.load()
        var reconciliationIssues: [WorkBatchBindingReconciliationIssue] = []
        if hasRuntimeSessionSnapshot {
            let result = try reconcileBindings(
                projectPath: project.path,
                bindingStore: bindingStore,
                sessions: latestRuntimeSessions,
                now: now,
            )
            bindings = result.bindings
            reconciliationIssues = result.issues
        }
        let projections = WorkBatchProjectionBuilder.build(
            state: workingState(for: project.path),
            bindings: bindings,
        )

        let classificationRequest = WorkBatchClassificationRequest(
            projectName: project.name,
            projectPath: project.path,
            task: task,
            existingBatches: projections,
        )
        let classification: WorkBatchClassificationRecord
        do {
            classification = try await classifier(classificationRequest)
        } catch {
            classification = fallbackClassification(
                for: classificationRequest,
                error: error,
                now: now,
            )
            DebugLog.write(
                "WorkBatchAutoRouter.classifier fallback project=\(project.path) task=\(task.id) error=\(error.localizedDescription)",
            )
        }

        // No defensive disk re-load here: the single @MainActor in-memory
        // working value is the source of truth. Any concurrent ingest that ran
        // during the classifier await mutated that same value (and the
        // single-flight route turn serializes routes), so reading it back picks
        // up those changes without a disk round-trip that could stomp them.
        var state = workingState(for: project.path)

        // Re-run reconciliation after the (possibly slow) classifier await. A
        // session can die or change identity while the classifier shells out,
        // which would make the pre-await `reconciliationIssues` captured above
        // stale by the time `applyDeliveryPolicy` consumes them. This re-derives
        // bindings/reconciliation against the CURRENT in-memory working value +
        // current session set — no disk reload of state.json. We keep the
        // pre-await reconcile too (it feeds the classification `projections`).
        if hasRuntimeSessionSnapshot {
            let postAwaitResult = try reconcileBindings(
                projectPath: project.path,
                bindingStore: bindingStore,
                sessions: latestRuntimeSessions,
                now: now,
            )
            bindings = postAwaitResult.bindings
            reconciliationIssues = postAwaitResult.issues
            state = workingState(for: project.path)
        }

        let activeProjections = WorkBatchProjectionBuilder.build(state: state, bindings: bindings)
        let effectiveClassification = relatednessGuardedClassification(
            classification,
            request: classificationRequest,
            existingBatches: activeProjections,
            now: now,
        )

        let route = applyClassification(
            effectiveClassification,
            task: task,
            project: project,
            state: &state,
            now: now,
        )
        commitWorkingState(state, for: project.path)

        let updatedBatchTasks = state.tasks
            .filter { $0.batchID == route.batch.id }
            .map(\.taskItem)

        if var existingBinding = try bindingStore.binding(batchID: route.batch.id) {
            do {
                let mirrorResult = try writeContextMirror(
                    batch: route.batch,
                    projectPath: project.path,
                    worktreePath: existingBinding.worktreePath,
                    tasks: updatedBatchTasks,
                    checkpoints: state.checkpoints.filter { $0.batchID == route.batch.id },
                    now: now,
                )
                state.recordContextWrite(
                    batchID: route.batch.id,
                    updatedAt: mirrorResult.updatedAt,
                    deliveryGeneration: mirrorResult.deliveryGeneration,
                    actionableContextDigest: mirrorResult.actionableContextDigest,
                )
                commitWorkingState(state, for: project.path)
            } catch {
                try markLaunchFailed(
                    projectPath: project.path,
                    batchID: route.batch.id,
                    taskID: route.task.id,
                    now: now,
                )
                throw error
            }
            existingBinding = try await applyDeliveryPolicy(
                projectPath: project.path,
                bindingStore: bindingStore,
                batchID: route.batch.id,
                preferredTaskID: route.task.id,
                reconciliationIssues: reconciliationIssues,
                mirrorWriteSucceeded: true,
                now: now,
            ) ?? existingBinding
            return WorkBatchRouteResult(
                batch: route.batch,
                task: route.task,
                classification: effectiveClassification,
                binding: existingBinding,
                startedNewSession: false,
            )
        }

        let startResult: WorkBatchTaskSessionStartResult
        do {
            let deliveryGeneration = Self.deliveryGeneration(batchID: route.batch.id, updatedAt: now)
            startResult = try await taskSessionCoordinator.startNewSession(
                WorkBatchTaskSessionStartRequest(
                    projectPath: project.path,
                    batchID: route.batch.id,
                    batchName: route.batch.name,
                    tasks: updatedBatchTasks,
                    deliveryGeneration: deliveryGeneration,
                    now: now,
                ),
            )
        } catch {
            try markLaunchFailed(
                projectPath: project.path,
                batchID: route.batch.id,
                taskID: route.task.id,
                now: now,
            )
            throw error
        }

        var stateAfterLaunch = workingState(for: project.path)
        if let index = stateAfterLaunch.batches.firstIndex(where: { $0.id == route.batch.id }) {
            stateAfterLaunch.batches[index].cockpitBindingID = startResult.binding.id
            stateAfterLaunch.batches[index].status = .working
            stateAfterLaunch.batches[index].currentActivitySummary = "Claude Code is starting on \(route.task.title)."
            stateAfterLaunch.batches[index].updatedAt = now
        }
        if let taskIndex = stateAfterLaunch.tasks.firstIndex(where: { $0.id == route.task.id }) {
            stateAfterLaunch.tasks[taskIndex].status = .working
            stateAfterLaunch.tasks[taskIndex].updatedAt = now
        }
        stateAfterLaunch.recordContextWrite(
            batchID: route.batch.id,
            updatedAt: now,
            deliveryGeneration: Self.deliveryGeneration(batchID: route.batch.id, updatedAt: now),
            actionableContextDigest: startResult.actionableContextDigest,
        )
        commitWorkingState(stateAfterLaunch, for: project.path)

        let launchedBatch = stateAfterLaunch.batches.first(where: { $0.id == route.batch.id }) ?? route.batch
        let launchedTask = stateAfterLaunch.tasks.first(where: { $0.id == route.task.id }) ?? route.task
        return WorkBatchRouteResult(
            batch: launchedBatch,
            task: launchedTask,
            classification: effectiveClassification,
            binding: startResult.binding,
            startedNewSession: true,
        )
    }

    private func acquireRouteTurn() async {
        if !isRouting {
            isRouting = true
            return
        }

        await withCheckedContinuation { continuation in
            routeWaiters.append(continuation)
        }
    }

    private func releaseRouteTurn() {
        if routeWaiters.isEmpty {
            isRouting = false
            return
        }

        let next = routeWaiters.removeFirst()
        next.resume()
    }

    func projections(for projectPath: String) -> [WorkBatchProjection] {
        if let cached = projectionsByProjectPath[projectPath] {
            return cached
        }
        // PURE read on a cache miss: compute and RETURN without assigning to the
        // published cache. `projections(for:)` is called from view bodies
        // (ProjectDetailView -> AppState.workBatches(for:)), and assigning an
        // @Observable property during body evaluation trips the SwiftUI
        // "Modifying state during view update is not allowed" contract. The
        // cache is seeded only from non-body triggers — store-mutating ops
        // (commitWorkingState / recomputeProjections) and the periodic poll-tick
        // recompute (refreshPreviewSensitiveProjections). A cold-open miss here
        // returns a freshly computed value (correct) without mutating observable
        // state mid-render.
        return computeProjections(for: projectPath)
    }

    func openPreview(
        project: Project,
        batchID: String,
        now: Date = Date(),
        onRecordChanged: ((WorkBatchPreviewRecord) -> Void)? = nil,
    ) async throws -> WorkBatchPreviewRecord {
        let bindingStore = bindingStoreFactory(project.path)
        let previewStore = previewStoreFactory(project.path)
        let state = workingState(for: project.path)

        /// Preview record changes feed the published projections cache, so wrap
        /// every upsert: persist to the preview store, recompute the @Observable
        /// projections, then notify the caller (which drives toast state).
        func publishPreview(_ record: WorkBatchPreviewRecord) throws {
            try previewStore.upsert(record)
            recomputeProjections(for: project.path)
            onRecordChanged?(record)
        }

        guard state.batches.contains(where: { $0.id == batchID }) else {
            throw WorkBatchAutoRouterError.batchNotFound
        }

        guard let binding = try bindingStore.binding(batchID: batchID) else {
            let record = WorkBatchPreviewRecord.unavailable(
                batchID: batchID,
                projectPath: project.path,
                worktreePath: nil,
                reason: "No batch worktree yet",
                updatedAt: now,
            )
            try publishPreview(record)
            return record
        }

        guard previewProjector.isCapacitorPreviewBuildToolAvailable(projectPath: project.path),
              previewProjector.isCapacitorPreviewSourceCapable(at: binding.worktreePath)
        else {
            let record = WorkBatchPreviewRecord.unavailable(
                batchID: batchID,
                projectPath: project.path,
                worktreePath: binding.worktreePath,
                reason: "Preview is not available in this batch worktree",
                updatedAt: now,
            )
            try publishPreview(record)
            return record
        }

        let currentSourceSnapshot = await previewSourceSnapshotLoader(binding.worktreePath)
        if let existingRecord = try previewStore.record(batchID: batchID),
           existingRecord.status == .readyToInspect,
           existingRecord.worktreePath.map(PathNormalizer.normalize) == PathNormalizer.normalize(binding.worktreePath),
           existingRecord.sourceFingerprint == currentSourceSnapshot.fingerprint,
           previewRunningMatcher(existingRecord)
        {
            _ = previewActivator(existingRecord)
            return existingRecord
        }

        let request = MacOSPreviewWorkRequest.capacitorPreview(
            worktreeURL: URL(fileURLWithPath: binding.worktreePath, isDirectory: true),
            proofDirectoryURL: previewStore.previewDirectoryURL(batchID: batchID),
            buildScriptURL: previewProjector.buildScriptURL(projectPath: project.path),
        )
        let building = WorkBatchPreviewRecord.building(
            batchID: batchID,
            projectPath: project.path,
            binding: binding,
            request: request,
            updatedAt: now,
            sourceFingerprint: currentSourceSnapshot.fingerprint,
        )
        try publishPreview(building)

        let proof: MacOSPreviewWorkProof
        do {
            proof = try await previewRunner(request)
        } catch {
            let failed = WorkBatchPreviewRecord(
                id: batchID,
                batchID: batchID,
                projectPath: project.path,
                worktreePath: PathNormalizer.normalize(binding.worktreePath),
                status: .previewFailed,
                appPath: PathNormalizer.normalize(request.appURL.path),
                bundleID: request.expectedBundleID,
                displayName: request.expectedDisplayName,
                pid: nil,
                proofPath: request.proofURL.path,
                buildLogPath: request.buildLogURL.path,
                failureReason: "Preview build could not run: \(error.localizedDescription)",
                updatedAt: now,
                sourceFingerprint: currentSourceSnapshot.fingerprint,
            )
            try publishPreview(failed)
            return failed
        }

        let record = WorkBatchPreviewRecord.fromProof(
            proof,
            batchID: batchID,
            projectPath: project.path,
            proofPath: request.proofURL.path,
            updatedAt: now,
        )
        try publishPreview(record)
        return record
    }

    func startSessionForUnboundBatch(
        project: Project,
        batchID: String,
        now: Date = Date(),
    ) async throws -> WorkBatchCockpitBinding {
        await acquireRouteTurn()
        defer { releaseRouteTurn() }

        let bindingStore = bindingStoreFactory(project.path)

        if let existingBinding = try bindingStore.binding(batchID: batchID) {
            return existingBinding
        }

        let state = workingState(for: project.path)
        guard let batch = state.batches.first(where: { $0.id == batchID }) else {
            throw WorkBatchAutoRouterError.batchNotFound
        }

        let openTasks = state.tasks
            .filter { $0.batchID == batchID && $0.status != .done }
            .sorted { $0.createdAt < $1.createdAt }
        guard !openTasks.isEmpty else {
            throw WorkBatchAutoRouterError.taskNotFound
        }

        let deliveryGeneration = Self.deliveryGeneration(batchID: batch.id, updatedAt: now)
        let startResult: WorkBatchTaskSessionStartResult
        do {
            startResult = try await taskSessionCoordinator.startNewSession(
                WorkBatchTaskSessionStartRequest(
                    projectPath: project.path,
                    batchID: batch.id,
                    batchName: batch.name,
                    tasks: openTasks.map(\.taskItem),
                    deliveryGeneration: deliveryGeneration,
                    now: now,
                ),
            )
        } catch {
            try markLaunchFailed(
                projectPath: project.path,
                batchID: batch.id,
                taskID: openTasks[0].id,
                now: now,
            )
            throw error
        }

        var stateAfterLaunch = workingState(for: project.path)
        if let batchIndex = stateAfterLaunch.batches.firstIndex(where: { $0.id == batch.id }) {
            stateAfterLaunch.batches[batchIndex].cockpitBindingID = startResult.binding.id
            stateAfterLaunch.batches[batchIndex].status = .working
            stateAfterLaunch.batches[batchIndex].currentActivitySummary = "Claude Code is starting on \(openTasks.first?.displayTitle ?? batch.name)."
            stateAfterLaunch.batches[batchIndex].updatedAt = now
        }
        for taskIndex in stateAfterLaunch.tasks.indices where stateAfterLaunch.tasks[taskIndex].batchID == batch.id && stateAfterLaunch.tasks[taskIndex].status == .queued {
            stateAfterLaunch.tasks[taskIndex].status = .working
            stateAfterLaunch.tasks[taskIndex].updatedAt = now
        }
        stateAfterLaunch.recordContextWrite(
            batchID: batch.id,
            updatedAt: now,
            deliveryGeneration: deliveryGeneration,
            actionableContextDigest: startResult.actionableContextDigest,
        )
        commitWorkingState(stateAfterLaunch, for: project.path)

        return startResult.binding
    }

    @discardableResult
    func ingestTaskRequests(
        projects: [Project],
        now: Date = Date(),
    ) -> [WorkBatchTaskRequestIngestResult] {
        var results: [WorkBatchTaskRequestIngestResult] = []
        for project in projects {
            do {
                try results.append(contentsOf: ingestTaskRequests(project: project, now: now))
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.ingestTaskRequests failure project=\(project.path) error=\(error.localizedDescription)",
                )
            }
        }
        return results
    }

    @discardableResult
    func ingestTaskClaims(
        projects: [Project],
        now: Date = Date(),
    ) -> [WorkBatchTaskClaimIngestResult] {
        var results: [WorkBatchTaskClaimIngestResult] = []
        for project in projects {
            do {
                try results.append(contentsOf: ingestTaskClaims(project: project, now: now))
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.ingestTaskClaims failure project=\(project.path) error=\(error.localizedDescription)",
                )
            }
        }
        return results
    }

    @discardableResult
    func ingestCompletionReports(
        projects: [Project],
        now: Date = Date(),
    ) -> [WorkBatchCompletionIngestResult] {
        var results: [WorkBatchCompletionIngestResult] = []
        for project in projects {
            do {
                try results.append(contentsOf: ingestCompletionReports(project: project, now: now))
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.ingestCompletionReports failure project=\(project.path) error=\(error.localizedDescription)",
                )
            }
        }
        return results
    }

    @discardableResult
    func ingestCheckpointRequests(
        projects: [Project],
        now: Date = Date(),
    ) -> [WorkBatchCheckpointIngestResult] {
        var results: [WorkBatchCheckpointIngestResult] = []
        for project in projects {
            do {
                try results.append(contentsOf: ingestCheckpointRequests(project: project, now: now))
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.ingestCheckpointRequests failure project=\(project.path) error=\(error.localizedDescription)",
                )
            }
        }
        return results
    }

    func unresolveTask(
        project: Project,
        batchID: String,
        taskID: String,
        now: Date = Date(),
    ) throws -> WorkBatchUnresolveResult {
        let bindingStore = bindingStoreFactory(project.path)
        var state = workingState(for: project.path)
        var bindings = try bindingStore.load()

        guard let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) else {
            throw WorkBatchAutoRouterError.batchNotFound
        }
        guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID && $0.batchID == batchID }) else {
            throw WorkBatchAutoRouterError.taskNotFound
        }

        let bindingIndex = bindings.firstIndex { $0.batchID == batchID }
        if let bindingIndex {
            try WorkBatchCompletionReportStore(worktreePath: bindings[bindingIndex].worktreePath)
                .deleteReport(taskID: taskID)
        }

        state.tasks[taskIndex].status = .queued
        state.tasks[taskIndex].updatedAt = now

        let task = state.tasks[taskIndex]
        state.batches[batchIndex].status = .waiting
        state.batches[batchIndex].currentActivitySummary = "Reopened \(task.displayTitle). Claude Code will pick it back up."
        state.batches[batchIndex].updatedAt = now

        if let bindingIndex {
            switch bindings[bindingIndex].status {
            case .done, .waiting, .stale:
                bindings[bindingIndex].status = .waiting
                bindings[bindingIndex].updatedAt = now
            case .launching, .running:
                break
            }
        }

        commitWorkingState(state, for: project.path)
        try bindingStore.save(bindings)
        recomputeProjections(for: project.path)

        let batch = state.batches[batchIndex]
        let batchTasks = state.tasks
            .filter { $0.batchID == batch.id }
            .map(\.taskItem)
        let binding = bindingIndex.map { bindings[$0] }
        if let binding {
            let mirrorResult = try writeContextMirror(
                batch: batch,
                projectPath: project.path,
                worktreePath: binding.worktreePath,
                tasks: batchTasks,
                checkpoints: state.checkpoints.filter { $0.batchID == batch.id },
                now: now,
            )
            state.recordContextWrite(
                batchID: batch.id,
                updatedAt: mirrorResult.updatedAt,
                deliveryGeneration: mirrorResult.deliveryGeneration,
                actionableContextDigest: mirrorResult.actionableContextDigest,
            )
            commitWorkingState(state, for: project.path)
        }

        return WorkBatchUnresolveResult(
            batch: batch,
            task: task,
            binding: binding,
        )
    }

    @discardableResult
    func followThroughWorkBatchDelivery(
        project: Project,
        batchID: String,
        preferredTaskID: String? = nil,
        now: Date = Date(),
    ) async throws -> WorkBatchCockpitBinding? {
        let bindingStore = bindingStoreFactory(project.path)
        var reconciliationIssues: [WorkBatchBindingReconciliationIssue] = []
        if hasRuntimeSessionSnapshot {
            reconciliationIssues = try reconcileBindings(
                projectPath: project.path,
                bindingStore: bindingStore,
                sessions: latestRuntimeSessions,
                now: now,
            ).issues
        }
        return try await applyDeliveryPolicy(
            projectPath: project.path,
            bindingStore: bindingStore,
            batchID: batchID,
            preferredTaskID: preferredTaskID,
            reconciliationIssues: reconciliationIssues,
            mirrorWriteSucceeded: true,
            now: now,
        )
    }

    func submitCheckpointResponse(
        project: Project,
        batchID: String,
        checkpointID: String,
        response: String,
        now: Date = Date(),
    ) throws -> WorkBatchCheckpointDecisionResult {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            throw WorkBatchAutoRouterError.emptyCheckpointResponse
        }

        let bindingStore = bindingStoreFactory(project.path)
        var state = workingState(for: project.path)
        var bindings = try bindingStore.load()

        guard let checkpointIndex = state.checkpoints.firstIndex(where: {
            $0.id == checkpointID && $0.batchID == batchID
        }) else {
            throw WorkBatchAutoRouterError.checkpointNotFound
        }
        guard state.checkpoints[checkpointIndex].status == .pending else {
            throw WorkBatchAutoRouterError.checkpointAlreadyAnswered
        }
        guard let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) else {
            throw WorkBatchAutoRouterError.batchNotFound
        }
        guard let taskIndex = state.tasks.firstIndex(where: {
            $0.id == state.checkpoints[checkpointIndex].taskID && $0.batchID == batchID
        }) else {
            throw WorkBatchAutoRouterError.taskNotFound
        }

        guard let bindingIndex = bindings.firstIndex(where: { $0.batchID == batchID }) else {
            throw WorkBatchAutoRouterError.bindingNotFound
        }

        _ = try WorkBatchCheckpointResponseStore(worktreePath: bindings[bindingIndex].worktreePath)
            .write(WorkBatchCheckpointResponse(
                checkpointID: checkpointID,
                taskID: state.checkpoints[checkpointIndex].taskID,
                response: trimmedResponse,
                respondedAt: now,
            ))

        state.checkpoints[checkpointIndex].status = .answered
        state.checkpoints[checkpointIndex].response = trimmedResponse
        state.checkpoints[checkpointIndex].respondedAt = now
        state.checkpoints[checkpointIndex].updatedAt = now

        if state.tasks[taskIndex].status != .done {
            state.tasks[taskIndex].status = .queued
            state.tasks[taskIndex].updatedAt = now
        }

        let task = state.tasks[taskIndex]
        let openTasks = state.tasks.filter { $0.batchID == batchID && $0.status != .done }
        if openTasks.isEmpty {
            // New Work Batch Done behavior: answering a stale checkpoint for an
            // already-completed Task should close the attention item, not imply
            // Claude Code has more work to continue.
            state.batches[batchIndex].status = .idle
            state.batches[batchIndex].currentActivitySummary = doneSummary(taskTitle: task.displayTitle)
            state.batches[batchIndex].updatedAt = now
            if bindings[bindingIndex].status != .done {
                bindings[bindingIndex].status = .done
                bindings[bindingIndex].updatedAt = now
            }
        } else {
            state.batches[batchIndex].status = .waiting
            state.batches[batchIndex].currentActivitySummary = "Answered checkpoint for \(task.displayTitle). Claude Code will continue."
            state.batches[batchIndex].updatedAt = now

            switch bindings[bindingIndex].status {
            case .stale, .waiting, .done:
                bindings[bindingIndex].status = .waiting
                bindings[bindingIndex].updatedAt = now
            case .launching, .running:
                break
            }
        }

        commitWorkingState(state, for: project.path)
        try bindingStore.save(bindings)
        recomputeProjections(for: project.path)

        let batch = state.batches[batchIndex]
        let binding = bindings[bindingIndex]
        let mirrorResult = try writeContextMirror(
            batch: batch,
            projectPath: project.path,
            worktreePath: binding.worktreePath,
            tasks: state.tasks.filter { $0.batchID == batch.id }.map(\.taskItem),
            checkpoints: state.checkpoints.filter { $0.batchID == batch.id },
            now: now,
        )
        state.recordContextWrite(
            batchID: batch.id,
            updatedAt: mirrorResult.updatedAt,
            deliveryGeneration: mirrorResult.deliveryGeneration,
            actionableContextDigest: mirrorResult.actionableContextDigest,
        )
        commitWorkingState(state, for: project.path)

        return WorkBatchCheckpointDecisionResult(
            batch: batch,
            task: task,
            checkpoint: state.checkpoints[checkpointIndex],
            binding: binding,
        )
    }

    @discardableResult
    func openCockpit(binding: WorkBatchCockpitBinding) async throws -> ClaudeCodeTaskSessionLaunchRequest? {
        var currentBinding = binding
        var focusOnlyExistingProcess = false
        if hasRuntimeSessionSnapshot {
            let bindingStore = bindingStoreFactory(binding.projectPath)
            let result = try reconcileBindings(
                projectPath: binding.projectPath,
                bindingStore: bindingStore,
                sessions: latestRuntimeSessions,
                now: Date(),
            )
            if hasBlockingDuplicateCockpitIssue(for: binding, in: result.issues) {
                throw WorkBatchAutoRouterError.duplicateCockpit(batchName: binding.batchName)
            }
            focusOnlyExistingProcess = hasAssignedSessionProcessDuplicateIssue(for: binding, in: result.issues)
            currentBinding = result.bindings.first(where: { $0.batchID == binding.batchID }) ?? binding
        }

        let canResumeExistingBinding = shouldResumeExistingBinding(currentBinding) && !focusOnlyExistingProcess
        let preferFocusBeforeResume = !canResumeExistingBinding || exactLiveSessionExists(for: currentBinding)

        return try await taskSessionCoordinator.openExistingSession(
            currentBinding,
            allowResumeWhenFocusFails: canResumeExistingBinding,
            preferFocusBeforeResume: preferFocusBeforeResume,
        )
    }

    @discardableResult
    func reconcileBindings(
        projects: [Project],
        sessions: [RuntimeSession],
        now: Date = Date(),
    ) -> [WorkBatchBindingReconciliationIssue] {
        latestRuntimeSessions = sessions
        hasRuntimeSessionSnapshot = true

        var issues: [WorkBatchBindingReconciliationIssue] = []
        for project in projects {
            do {
                let result = try reconcileBindings(
                    projectPath: project.path,
                    bindingStore: bindingStoreFactory(project.path),
                    sessions: sessions,
                    now: now,
                )
                issues.append(contentsOf: result.issues)
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.reconcileBindings failure project=\(project.path) error=\(error.localizedDescription)",
                )
            }
        }
        return issues
    }

    private func ingestTaskRequests(
        project: Project,
        now: Date,
    ) throws -> [WorkBatchTaskRequestIngestResult] {
        let bindingStore = bindingStoreFactory(project.path)
        var state = workingState(for: project.path)
        var bindings = try bindingStore.load()
        guard !bindings.isEmpty else { return [] }

        let originalState = state
        let originalBindings = bindings
        var results: [WorkBatchTaskRequestIngestResult] = []
        var batchesNeedingMirrorRewrite: Set<String> = []

        for bindingIndex in bindings.indices {
            let binding = bindings[bindingIndex]
            let requestStore = WorkBatchTaskRequestStore(worktreePath: binding.worktreePath)
            let requests = try requestStore.loadRequests()
                .sorted { lhs, rhs in
                    lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
                }

            for loadedRequest in requests {
                let request = loadedRequest.request
                let taskID = loadedRequest.canonicalTaskID
                guard !state.tasks.contains(where: { $0.id == taskID }) else {
                    continue
                }
                guard let batchIndex = state.batches.firstIndex(where: { $0.id == binding.batchID }) else {
                    continue
                }

                let requestTime = min(request.requestedAt ?? now, now)
                let stateUpdateTime = max(requestTime, state.batches[batchIndex].updatedAt)
                let title = taskRequestTitle(request)
                let body = taskRequestBody(request, fallbackTitle: title)
                let task = WorkBatchTaskRecord(
                    id: taskID,
                    sourceIdeaID: nil,
                    title: title,
                    body: body,
                    status: .queued,
                    batchID: binding.batchID,
                    createdAt: requestTime,
                    updatedAt: requestTime,
                )

                state.tasks.append(task)
                if !state.batches[batchIndex].taskIDs.contains(taskID) {
                    state.batches[batchIndex].taskIDs.append(taskID)
                }
                state.batches[batchIndex].status = statusAfterQueuedTaskRequest(binding: binding)
                state.batches[batchIndex].currentActivitySummary = "Queued \(task.displayTitle)."
                state.batches[batchIndex].updatedAt = stateUpdateTime
                state.classifications.append(WorkBatchClassificationRecord.existing(
                    taskID: taskID,
                    batchID: binding.batchID,
                    confidence: 1,
                    rationale: "Added from Work Batch in-session Task request artifact \(loadedRequest.url.lastPathComponent).",
                    summary: "Added to \(state.batches[batchIndex].name).",
                    createdAt: stateUpdateTime,
                ))

                if bindings[bindingIndex].status == .done || bindings[bindingIndex].status == .stale {
                    bindings[bindingIndex].status = .waiting
                    bindings[bindingIndex].updatedAt = stateUpdateTime
                }

                batchesNeedingMirrorRewrite.insert(binding.batchID)
                results.append(WorkBatchTaskRequestIngestResult(
                    projectPath: project.path,
                    batchID: binding.batchID,
                    batchName: state.batches[batchIndex].name,
                    taskID: task.id,
                    taskTitle: task.displayTitle,
                    request: request,
                ))
            }
        }

        if state != originalState {
            commitWorkingState(state, for: project.path)
        }
        if bindings != originalBindings {
            try bindingStore.save(bindings)
            recomputeProjections(for: project.path)
        }

        for batchID in batchesNeedingMirrorRewrite {
            guard let batch = state.batches.first(where: { $0.id == batchID }),
                  let binding = bindings.first(where: { $0.batchID == batchID })
            else {
                continue
            }
            do {
                let mirrorResult = try writeContextMirror(
                    batch: batch,
                    projectPath: project.path,
                    worktreePath: binding.worktreePath,
                    tasks: state.tasks.filter { $0.batchID == batchID }.map(\.taskItem),
                    checkpoints: state.checkpoints.filter { $0.batchID == batchID },
                    now: now,
                )
                state.recordContextWrite(
                    batchID: batchID,
                    updatedAt: mirrorResult.updatedAt,
                    deliveryGeneration: mirrorResult.deliveryGeneration,
                    actionableContextDigest: mirrorResult.actionableContextDigest,
                )
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.ingestTaskRequests mirror failure project=\(project.path) batch=\(batchID) error=\(error.localizedDescription)",
                )
            }
        }
        if state != originalState {
            commitWorkingState(state, for: project.path)
        }

        return results
    }

    private func ingestCompletionReports(
        project: Project,
        now: Date,
    ) throws -> [WorkBatchCompletionIngestResult] {
        let bindingStore = bindingStoreFactory(project.path)
        var state = workingState(for: project.path)
        var bindings = try bindingStore.load()
        guard !bindings.isEmpty else { return [] }

        let originalState = state
        let originalBindings = bindings
        var results: [WorkBatchCompletionIngestResult] = []
        var batchesNeedingMirrorRewrite: Set<String> = []

        for bindingIndex in bindings.indices {
            let binding = bindings[bindingIndex]
            let reportStore = WorkBatchCompletionReportStore(worktreePath: binding.worktreePath)
            let reports = try reportStore.loadReports()
                .filter(\.report.isDone)
                .sorted { lhs, rhs in
                    lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
                }

            for loadedReport in reports {
                let report = loadedReport.report
                guard let taskIndex = state.tasks.firstIndex(where: {
                    $0.id == report.taskID && $0.batchID == binding.batchID
                }) else {
                    continue
                }

                let task = state.tasks[taskIndex]
                guard task.status != .done else { continue }

                // Done reports are terminal worker claims. Agent-written clocks can lag
                // after a wake/resume, so accept the artifact and keep state monotonic.
                let updateTime = max(report.completedAt ?? now, task.updatedAt)
                state.tasks[taskIndex].status = .done
                state.tasks[taskIndex].updatedAt = updateTime

                guard let batchIndex = state.batches.firstIndex(where: { $0.id == binding.batchID }) else {
                    continue
                }
                let batchTasks = state.tasks.filter { $0.batchID == binding.batchID }
                let openTasks = batchTasks.filter { $0.status != .done }
                let summary = doneSentence(report.summary, fallback: task.displayTitle)

                if openTasks.isEmpty {
                    state.batches[batchIndex].status = .idle
                    state.batches[batchIndex].currentActivitySummary = "Done: \(summary)"
                    bindings[bindingIndex].status = .done
                    bindings[bindingIndex].updatedAt = updateTime
                } else {
                    state.batches[batchIndex].status = batchStatusAfterPartialDone(
                        binding: bindings[bindingIndex],
                        openTasks: openTasks,
                    )
                    state.batches[batchIndex].currentActivitySummary = "Done: \(summary) \(openTasks.count) Task\(openTasks.count == 1 ? "" : "s") still open."
                }
                state.batches[batchIndex].updatedAt = updateTime
                batchesNeedingMirrorRewrite.insert(binding.batchID)

                results.append(WorkBatchCompletionIngestResult(
                    projectPath: project.path,
                    batchID: binding.batchID,
                    batchName: state.batches[batchIndex].name,
                    taskID: state.tasks[taskIndex].id,
                    sourceIdeaID: state.tasks[taskIndex].sourceIdeaID,
                    taskTitle: state.tasks[taskIndex].displayTitle,
                    summary: report.summary,
                    evidence: report.evidence,
                ))
            }
        }

        if state != originalState {
            commitWorkingState(state, for: project.path)
        }
        if bindings != originalBindings {
            try bindingStore.save(bindings)
            recomputeProjections(for: project.path)
        }

        for batchID in batchesNeedingMirrorRewrite {
            guard let batch = state.batches.first(where: { $0.id == batchID }),
                  let binding = bindings.first(where: { $0.batchID == batchID })
            else {
                continue
            }
            let batchTasks = state.tasks
                .filter { $0.batchID == batchID }
                .map(\.taskItem)
            do {
                let mirrorResult = try writeContextMirror(
                    batch: batch,
                    projectPath: project.path,
                    worktreePath: binding.worktreePath,
                    tasks: batchTasks,
                    checkpoints: state.checkpoints.filter { $0.batchID == batchID },
                    now: now,
                )
                state.recordContextWrite(
                    batchID: batchID,
                    updatedAt: mirrorResult.updatedAt,
                    deliveryGeneration: mirrorResult.deliveryGeneration,
                    actionableContextDigest: mirrorResult.actionableContextDigest,
                )
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.ingestCompletionReports mirror failure project=\(project.path) batch=\(batchID) error=\(error.localizedDescription)",
                )
            }
        }
        if state != originalState {
            commitWorkingState(state, for: project.path)
        }

        return results
    }

    private func ingestTaskClaims(
        project: Project,
        now _: Date,
    ) throws -> [WorkBatchTaskClaimIngestResult] {
        let bindingStore = bindingStoreFactory(project.path)
        var state = workingState(for: project.path)
        let bindings = try bindingStore.load()
        guard !bindings.isEmpty else { return [] }

        let originalState = state
        var results: [WorkBatchTaskClaimIngestResult] = []

        for binding in bindings {
            let claimStore = WorkBatchTaskClaimStore(worktreePath: binding.worktreePath)
            let claims = try claimStore.loadClaims()
                .sorted { lhs, rhs in
                    lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
                }

            for loadedClaim in claims {
                let claim = loadedClaim.claim
                guard let taskIndex = state.tasks.firstIndex(where: {
                    $0.id == claim.taskID && $0.batchID == binding.batchID
                }) else {
                    continue
                }
                guard state.tasks[taskIndex].status == .queued else {
                    continue
                }
                guard let claimedAt = claim.claimedAt else {
                    continue
                }
                if let deliveryGeneration = claim.deliveryGeneration {
                    guard state.deliveryRecord(batchID: binding.batchID)?.lastDeliveryGeneration == deliveryGeneration else {
                        continue
                    }
                } else if claimedAt < state.tasks[taskIndex].updatedAt {
                    continue
                }
                guard let batchIndex = state.batches.firstIndex(where: { $0.id == binding.batchID }) else {
                    continue
                }

                let effectiveClaimedAt = max(claimedAt, state.tasks[taskIndex].updatedAt)
                state.tasks[taskIndex].status = .working
                state.tasks[taskIndex].updatedAt = effectiveClaimedAt
                let task = state.tasks[taskIndex]
                state.batches[batchIndex].status = .working
                state.batches[batchIndex].currentActivitySummary = workingSummary(
                    claimSummary: claim.summary,
                    taskTitle: task.displayTitle,
                )
                state.batches[batchIndex].updatedAt = effectiveClaimedAt
                state.recordTaskClaim(batchID: binding.batchID, claimedAt: effectiveClaimedAt)

                results.append(WorkBatchTaskClaimIngestResult(
                    projectPath: project.path,
                    batchID: binding.batchID,
                    batchName: state.batches[batchIndex].name,
                    taskID: task.id,
                    sourceIdeaID: task.sourceIdeaID,
                    taskTitle: task.displayTitle,
                    summary: claim.summary,
                    claim: claim,
                ))
            }
        }

        if state != originalState {
            commitWorkingState(state, for: project.path)
        }

        return results
    }

    private func ingestCheckpointRequests(
        project: Project,
        now: Date,
    ) throws -> [WorkBatchCheckpointIngestResult] {
        let bindingStore = bindingStoreFactory(project.path)
        var state = workingState(for: project.path)
        var bindings = try bindingStore.load()
        guard !bindings.isEmpty else { return [] }

        let originalState = state
        let originalBindings = bindings
        var results: [WorkBatchCheckpointIngestResult] = []
        var batchesNeedingMirrorRewrite: Set<String> = []

        for bindingIndex in bindings.indices {
            let binding = bindings[bindingIndex]
            let requestStore = WorkBatchCheckpointRequestStore(worktreePath: binding.worktreePath)
            let requests = try requestStore.loadRequests()
                .sorted { lhs, rhs in
                    lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
                }

            for loadedRequest in requests {
                let request = loadedRequest.request
                guard let taskIndex = state.tasks.firstIndex(where: {
                    $0.id == request.taskID && $0.batchID == binding.batchID
                }) else {
                    continue
                }
                let task = state.tasks[taskIndex]
                guard task.status != .done else { continue }

                if state.checkpoints.contains(where: {
                    $0.id == request.checkpointID && $0.batchID == binding.batchID
                }) {
                    continue
                }

                guard let batchIndex = state.batches.firstIndex(where: { $0.id == binding.batchID }) else {
                    continue
                }

                let requestTime = request.requestedAt ?? now
                let checkpoint = WorkBatchCheckpointRecord(
                    id: request.checkpointID,
                    batchID: binding.batchID,
                    taskID: request.taskID,
                    question: request.question,
                    reason: request.reason,
                    recommendedAction: request.recommendedAction,
                    status: .pending,
                    requestedAt: requestTime,
                    respondedAt: nil,
                    response: nil,
                    updatedAt: requestTime,
                )

                state.checkpoints.append(checkpoint)
                state.tasks[taskIndex].status = .needsYou
                state.tasks[taskIndex].updatedAt = requestTime
                state.batches[batchIndex].status = .waiting
                state.batches[batchIndex].currentActivitySummary = "Checkpoint ready: \(questionSentence(request.question))"
                state.batches[batchIndex].updatedAt = requestTime
                bindings[bindingIndex].status = .waiting
                bindings[bindingIndex].updatedAt = requestTime
                batchesNeedingMirrorRewrite.insert(binding.batchID)

                results.append(WorkBatchCheckpointIngestResult(
                    projectPath: project.path,
                    batchID: binding.batchID,
                    batchName: state.batches[batchIndex].name,
                    taskID: state.tasks[taskIndex].id,
                    sourceIdeaID: state.tasks[taskIndex].sourceIdeaID,
                    taskTitle: state.tasks[taskIndex].displayTitle,
                    checkpoint: checkpoint,
                ))
            }
        }

        if state != originalState {
            commitWorkingState(state, for: project.path)
        }
        if bindings != originalBindings {
            try bindingStore.save(bindings)
            recomputeProjections(for: project.path)
        }

        for batchID in batchesNeedingMirrorRewrite {
            guard let batch = state.batches.first(where: { $0.id == batchID }),
                  let binding = bindings.first(where: { $0.batchID == batchID })
            else {
                continue
            }
            do {
                let mirrorResult = try writeContextMirror(
                    batch: batch,
                    projectPath: project.path,
                    worktreePath: binding.worktreePath,
                    tasks: state.tasks.filter { $0.batchID == batchID }.map(\.taskItem),
                    checkpoints: state.checkpoints.filter { $0.batchID == batchID },
                    now: now,
                )
                state.recordContextWrite(
                    batchID: batchID,
                    updatedAt: mirrorResult.updatedAt,
                    deliveryGeneration: mirrorResult.deliveryGeneration,
                    actionableContextDigest: mirrorResult.actionableContextDigest,
                )
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.ingestCheckpointRequests mirror failure project=\(project.path) batch=\(batchID) error=\(error.localizedDescription)",
                )
            }
        }
        if state != originalState {
            commitWorkingState(state, for: project.path)
        }

        return results
    }

    private func batchStatusAfterPartialDone(
        binding: WorkBatchCockpitBinding,
        openTasks: [WorkBatchTaskRecord],
    ) -> WorkBatchStatus {
        if openTasks.contains(where: { $0.status == .needsYou }) {
            return .waiting
        }
        switch binding.status {
        case .launching, .running:
            return .working
        case .stale, .waiting, .done:
            return .waiting
        }
    }

    private func statusAfterQueuedTaskRequest(binding: WorkBatchCockpitBinding) -> WorkBatchStatus {
        switch binding.status {
        case .launching, .running:
            .working
        case .stale, .waiting, .done:
            .waiting
        }
    }

    private func taskRequestTitle(_ request: WorkBatchTaskRequest) -> String {
        let title = request.normalizedTitle
        if !title.isEmpty {
            return String(title.prefix(80))
        }
        let body = request.normalizedBody
        guard !body.isEmpty else { return "Untitled Task" }
        return String(body.prefix(80))
    }

    private func taskRequestBody(
        _ request: WorkBatchTaskRequest,
        fallbackTitle: String,
    ) -> String {
        let body = request.normalizedBody
        if !body.isEmpty {
            return body
        }
        return fallbackTitle
    }

    private func doneSentence(_ rawSummary: String, fallback: String) -> String {
        let trimmed = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? fallback : trimmed
        if let last = value.last,
           [".", "!", "?"].contains(last)
        {
            return value
        }
        return "\(value)."
    }

    private func doneSummary(taskTitle: String) -> String {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Done." }
        if let last = title.last,
           [".", "!", "?"].contains(last)
        {
            return "Done: \(title)"
        }
        return "Done: \(title)."
    }

    private func workingSummary(claimSummary: String?, taskTitle: String) -> String {
        let trimmed = claimSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? "Working on \(taskTitle)" : trimmed
        if let last = value.last,
           [".", "!", "?"].contains(last)
        {
            return value
        }
        return "\(value)."
    }

    private func questionSentence(_ rawQuestion: String) -> String {
        let trimmed = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "User input needed." }
        if let last = trimmed.last,
           [".", "!", "?"].contains(last)
        {
            return trimmed
        }
        return "\(trimmed)?"
    }

    private func shouldResumeExistingBinding(_ binding: WorkBatchCockpitBinding) -> Bool {
        switch binding.status {
        case .stale, .waiting, .done:
            true
        case .launching, .running:
            false
        }
    }

    private func hasBlockingDuplicateCockpitIssue(
        for binding: WorkBatchCockpitBinding,
        in issues: [WorkBatchBindingReconciliationIssue],
    ) -> Bool {
        issues.contains { issue in
            guard issue.batchID == binding.batchID, issue.kind == .duplicateCockpit else {
                return false
            }
            // New Work Batch cockpit behavior: two processes attached to the
            // same assigned Claude session are a delivery risk, but manual
            // re-entry should still focus that cockpit. Different session IDs
            // in the same worktree are still ambiguous and must block.
            return issue.sessionIDs.contains {
                isForeignDuplicateSessionID($0, assignedSessionID: binding.claudeSessionID)
            }
        }
    }

    private func hasAssignedSessionProcessDuplicateIssue(
        for binding: WorkBatchCockpitBinding,
        in issues: [WorkBatchBindingReconciliationIssue],
    ) -> Bool {
        issues.contains { issue in
            issue.batchID == binding.batchID &&
                issue.kind == .duplicateCockpit &&
                issue.sessionIDs.contains(assignedSessionDuplicateProcessMarker(binding.claudeSessionID))
        }
    }

    private func isForeignDuplicateSessionID(_ sessionID: String, assignedSessionID: String) -> Bool {
        sessionID != assignedSessionID && sessionID != assignedSessionDuplicateProcessMarker(assignedSessionID)
    }

    private func assignedSessionDuplicateProcessMarker(_ assignedSessionID: String) -> String {
        "\(assignedSessionID) (duplicate process)"
    }

    private func duplicateCockpitSummary(
        for binding: WorkBatchCockpitBinding?,
        batchID: String,
        issues: [WorkBatchBindingReconciliationIssue],
    ) -> String {
        guard let binding,
              binding.batchID == batchID,
              hasAssignedSessionProcessDuplicateIssue(for: binding, in: issues),
              !hasBlockingDuplicateCockpitIssue(for: binding, in: issues)
        else {
            return "Multiple Claude Code sessions match this Work Batch."
        }
        return "Claude Code is already open; click to re-enter."
    }

    @discardableResult
    private func applyDeliveryPolicy(
        projectPath: String,
        bindingStore: WorkBatchCockpitBindingStore,
        batchID: String,
        preferredTaskID: String?,
        reconciliationIssues: [WorkBatchBindingReconciliationIssue],
        mirrorWriteSucceeded: Bool,
        now: Date,
    ) async throws -> WorkBatchCockpitBinding? {
        let state = workingState(for: projectPath)
        let binding = try bindingStore.binding(batchID: batchID)
        let batchTasks = state.tasks.filter { $0.batchID == batchID }
        let batchCheckpoints = state.checkpoints.filter { $0.batchID == batchID }
        let policyAction = WorkBatchDeliveryPolicy.decide(WorkBatchDeliveryPolicyInput(
            batchID: batchID,
            now: now,
            tasks: batchTasks,
            checkpoints: batchCheckpoints,
            binding: binding,
            reconciliationIssues: reconciliationIssues,
            mirrorWriteSucceeded: mirrorWriteSucceeded,
            exactLiveSessionExists: binding.map(exactLiveSessionExists) ?? false,
            safeWakeBoundarySatisfied: binding.map(safeWakeBoundarySatisfied) ?? false,
            deliveryRecord: state.deliveryRecord(batchID: batchID),
        ))

        switch policyAction {
        case .queueOnly, .safeWakeDeferred:
            return binding

        case .wakeExistingSession:
            guard let binding else { return nil }
            let taskID = preferredTaskID ?? firstOpenTaskID(in: batchTasks)
            let prompt = deliveryPrompt(
                batchID: batchID,
                tasks: batchTasks,
                preferredTaskID: taskID,
            )
            guard let prompt else {
                return binding
            }
            do {
                try await taskSessionCoordinator.wakeExistingSession(binding, prompt: prompt)
                return try markExistingSessionWoken(
                    projectPath: projectPath,
                    bindingStore: bindingStore,
                    binding: binding,
                    batchID: batchID,
                    taskID: taskID,
                    now: now,
                )
            } catch {
                if let taskID {
                    try markLaunchFailed(
                        projectPath: projectPath,
                        batchID: batchID,
                        taskID: taskID,
                        now: now,
                    )
                } else {
                    try markBatchDeliveryWaiting(
                        projectPath: projectPath,
                        batchID: batchID,
                        summary: "Claude Code wake needs attention.",
                        now: now,
                    )
                }
                throw error
            }

        case .waitForCheckpoint:
            let checkpointSummary = state.checkpoints
                .first(where: { $0.batchID == batchID && $0.status == .pending })
                .map { "Checkpoint ready: \(questionSentence($0.question))" }
                ?? "Checkpoint needs your input."
            try markBatchDeliveryWaiting(
                projectPath: projectPath,
                batchID: batchID,
                summary: checkpointSummary,
                now: now,
            )
            return binding

        case .waitForDuplicateCockpit:
            let summary = duplicateCockpitSummary(
                for: binding,
                batchID: batchID,
                issues: reconciliationIssues,
            )
            if let taskID = preferredTaskID ?? firstOpenTaskID(in: batchTasks) {
                try markReconciliationBlocked(
                    projectPath: projectPath,
                    batchID: batchID,
                    taskID: taskID,
                    summary: summary,
                    now: now,
                )
            } else {
                try markBatchDeliveryWaiting(
                    projectPath: projectPath,
                    batchID: batchID,
                    summary: summary,
                    now: now,
                )
            }
            return binding

        case .waitForDeliveryFailure:
            try markBatchDeliveryWaiting(
                projectPath: projectPath,
                batchID: batchID,
                summary: "Claude Code delivery needs attention.",
                now: now,
            )
            return binding

        case .waitForPickupTimeout:
            let taskID = preferredTaskID ?? firstQueuedTaskID(in: batchTasks) ?? firstOpenTaskID(in: batchTasks)
            let taskTitle = taskID
                .flatMap { id in batchTasks.first(where: { $0.id == id })?.displayTitle }
                ?? "the queued Task"
            try markBatchPickupTimedOut(
                projectPath: projectPath,
                batchID: batchID,
                summary: "Claude Code has not picked up \(taskTitle) yet. Click to re-enter.",
                now: now,
            )
            return binding

        case .resumeExistingSession:
            guard let binding else { return nil }
            let taskID = preferredTaskID ?? firstOpenTaskID(in: batchTasks)
            let prompt = deliveryPrompt(
                batchID: batchID,
                tasks: batchTasks,
                preferredTaskID: taskID,
            )
            do {
                _ = try await taskSessionCoordinator.openExistingSession(
                    binding,
                    allowResumeWhenFocusFails: true,
                    prompt: prompt,
                )
                return try markResumeStarted(
                    projectPath: projectPath,
                    bindingStore: bindingStore,
                    binding: binding,
                    batchID: batchID,
                    taskID: taskID,
                    now: now,
                )
            } catch {
                if let taskID {
                    try markLaunchFailed(
                        projectPath: projectPath,
                        batchID: batchID,
                        taskID: taskID,
                        now: now,
                    )
                } else {
                    try markBatchDeliveryWaiting(
                        projectPath: projectPath,
                        batchID: batchID,
                        summary: "Claude Code launch needs attention.",
                        now: now,
                    )
                }
                throw error
            }

        case .startNewSession:
            return nil
        }
    }

    private func firstOpenTaskID(in tasks: [WorkBatchTaskRecord]) -> String? {
        tasks.first { $0.status != .done }?.id
    }

    private func firstQueuedTaskID(in tasks: [WorkBatchTaskRecord]) -> String? {
        tasks.first { $0.status == .queued }?.id
    }

    private func deliveryPrompt(
        batchID: String,
        tasks: [WorkBatchTaskRecord],
        preferredTaskID: String?,
    ) -> String? {
        WorkBatchActionableContext.deliveryPrompt(
            batchID: batchID,
            tasks: tasks,
            preferredTaskID: preferredTaskID,
        )
    }

    private func exactLiveSessionExists(for binding: WorkBatchCockpitBinding) -> Bool {
        if processSessionIDs(binding).contains(binding.claudeSessionID) {
            return true
        }
        guard hasRuntimeSessionSnapshot else { return false }
        return latestRuntimeSessions.contains { session in
            runtimeSessionMatchesBinding(session, binding: binding) ||
                runtimeSessionIsSignalAbsenceReadyBoundary(session, binding: binding)
        }
    }

    private func safeWakeBoundarySatisfied(for binding: WorkBatchCockpitBinding) -> Bool {
        if let safeWakeBoundaryAllowsInputOverride {
            return safeWakeBoundaryAllowsInputOverride(binding)
        }
        guard hasRuntimeSessionSnapshot else { return false }
        if latestRuntimeSessions.contains(where: { session in
            runtimeSessionMatchesBinding(session, binding: binding) &&
                runtimeSessionIsAtSafeWakeBoundary(session)
        }) {
            return true
        }

        if latestRuntimeSessions.contains(where: { session in
            runtimeSessionIsSignalAbsenceReadyBoundary(session, binding: binding)
        }) {
            return true
        }

        let processSessionIDs = processSessionIDs(binding)
        return latestRuntimeSessions.contains { session in
            runtimeSessionIsProcessBackedAwaitingInputBoundary(
                session,
                binding: binding,
                processSessionIDs: processSessionIDs,
            )
        }
    }

    private func runtimeSessionMatchesBinding(
        _ session: RuntimeSession,
        binding: WorkBatchCockpitBinding,
    ) -> Bool {
        runtimeSessionIdentityMatchesBinding(session, binding: binding) &&
            session.gcReason == nil
    }

    private func runtimeSessionIdentityMatchesBinding(
        _ session: RuntimeSession,
        binding: WorkBatchCockpitBinding,
    ) -> Bool {
        runtimeSessionPathAndIDMatchBinding(session, binding: binding) &&
            (session.isAlive ?? true)
    }

    private func runtimeSessionPathAndIDMatchBinding(
        _ session: RuntimeSession,
        binding: WorkBatchCockpitBinding,
    ) -> Bool {
        session.sessionId == binding.claudeSessionID &&
            (pathIsInside(session.cwd, root: binding.worktreePath) ||
                pathIsInside(session.projectPath, root: binding.worktreePath))
    }

    private func runtimeSessionIsAtSafeWakeBoundary(_ session: RuntimeSession) -> Bool {
        runtimeSessionIsReadyWithoutTools(session) &&
            session.gcReason == nil
    }

    /// New Work Batch path: a session can age out of transcript signals while
    /// still being the exact assigned Claude cockpit, alive, ready, and idle.
    /// That is safe enough for the tiny task-refresh wake prompt.
    private func runtimeSessionIsSignalAbsenceReadyBoundary(
        _ session: RuntimeSession,
        binding: WorkBatchCockpitBinding,
    ) -> Bool {
        runtimeSessionIdentityMatchesBinding(session, binding: binding) &&
            runtimeSessionIsReadyWithoutTools(session) &&
            session.gcReason == "signal_absence"
    }

    /// New Work Batch path: the reducer can lose PID confidence for an old
    /// session while a direct process scan still proves the exact assigned
    /// Claude cockpit is alive in the Batch Worktree. If that stale snapshot
    /// also says Claude was awaiting input and no tools are running, the tiny
    /// task-refresh wake is still the least surprising product behavior.
    private func runtimeSessionIsProcessBackedAwaitingInputBoundary(
        _ session: RuntimeSession,
        binding: WorkBatchCockpitBinding,
        processSessionIDs: [String],
    ) -> Bool {
        processSessionIDs.contains(binding.claudeSessionID) &&
            runtimeSessionPathAndIDMatchBinding(session, binding: binding) &&
            session.gcReason == "signal_absence" &&
            session.toolsInFlight == 0 &&
            runtimeSessionLooksAwaitingInput(session)
    }

    private func runtimeSessionLooksAwaitingInput(_ session: RuntimeSession) -> Bool {
        if session.state == .ready {
            return true
        }
        return session.state == .idle &&
            session.stateSource?.authority == "meta_awaiting_input"
    }

    private func runtimeSessionIsReadyWithoutTools(_ session: RuntimeSession) -> Bool {
        session.state == .ready &&
            session.toolsInFlight == 0 &&
            session.isAlive == true
    }

    private func pathIsInside(_ path: String, root: String) -> Bool {
        let normalizedPath = PathNormalizer.normalize(path)
        let normalizedRoot = PathNormalizer.normalize(root)
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private struct AppliedRoute {
        let batch: WorkBatchRecord
        let task: WorkBatchTaskRecord
    }

    private func applyClassification(
        _ classification: WorkBatchClassificationRecord,
        task: WorkBatchTaskRecord,
        project: Project,
        state: inout WorkBatchStateSnapshot,
        now: Date,
    ) -> AppliedRoute {
        var routedTask = task
        let batch: WorkBatchRecord
        state.batches = state.batches.map { batch in
            var updated = batch
            updated.taskIDs.removeAll { $0 == task.id }
            return updated
        }

        switch classification.target {
        case let .existing(batchID):
            if let index = state.batches.firstIndex(where: { $0.id == batchID }) {
                var existing = state.batches[index]
                existing.status = .working
                existing.currentActivitySummary = "Queued \(task.displayTitle) in \(existing.name)."
                existing.updatedAt = now
                if !existing.taskIDs.contains(task.id) {
                    existing.taskIDs.append(task.id)
                }
                state.batches[index] = existing
                routedTask.batchID = existing.id
                batch = existing
            } else {
                batch = appendNewBatch(
                    named: classification.proposedBatchName ?? fallbackBatchName(for: task),
                    task: &routedTask,
                    project: project,
                    state: &state,
                    now: now,
                )
            }

        case let .new(batchName):
            batch = appendNewBatch(
                named: batchName,
                task: &routedTask,
                project: project,
                state: &state,
                now: now,
            )
        }

        routedTask.updatedAt = now
        state.tasks.removeAll { $0.id == routedTask.id }
        state.tasks.append(routedTask)
        state.classifications.append(classification)
        return AppliedRoute(batch: batch, task: routedTask)
    }

    private func appendNewBatch(
        named rawName: String,
        task: inout WorkBatchTaskRecord,
        project: Project,
        state: inout WorkBatchStateSnapshot,
        now: Date,
    ) -> WorkBatchRecord {
        let name = normalizedBatchName(rawName, fallback: fallbackBatchName(for: task))
        let batchID = stableBatchID(name: name, taskID: task.id)
        task.batchID = batchID
        let batch = WorkBatchRecord(
            id: batchID,
            name: name,
            projectPath: project.path,
            status: .working,
            currentActivitySummary: "Starting \(task.title).",
            taskIDs: [task.id],
            cockpitBindingID: nil,
            createdAt: now,
            updatedAt: now,
        )
        state.batches.removeAll { $0.id == batchID }
        state.batches.append(batch)
        return batch
    }

    @discardableResult
    private func writeContextMirror(
        batch: WorkBatchRecord,
        projectPath: String,
        worktreePath: String,
        tasks: [WorkBatchTaskItem],
        checkpoints: [WorkBatchCheckpointRecord] = [],
        now: Date,
    ) throws -> WorkBatchContextMirrorWriteResult {
        let deliveryGeneration = Self.deliveryGeneration(batchID: batch.id, updatedAt: now)
        let actionableContextDigest = WorkBatchActionableContext.digest(
            batchID: batch.id,
            tasks: tasks,
            checkpoints: checkpoints,
        )
        _ = try WorkBatchContextMirror(
            batchID: batch.id,
            batchName: batch.name,
            projectPath: projectPath,
            worktreePath: worktreePath,
            tasks: tasks,
            checkpoints: checkpoints,
            deliveryGeneration: deliveryGeneration,
            updatedAt: now,
        ).write()
        return WorkBatchContextMirrorWriteResult(
            updatedAt: now,
            deliveryGeneration: deliveryGeneration,
            actionableContextDigest: actionableContextDigest,
        )
    }

    private static func deliveryGeneration(batchID: String, updatedAt: Date) -> String {
        "\(batchID):\(ISO8601DateFormatter.shared.string(from: updatedAt))"
    }

    private func markLaunchFailed(
        projectPath: String,
        batchID: String,
        taskID: String,
        now: Date,
    ) throws {
        var state = workingState(for: projectPath)
        if let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) {
            state.batches[batchIndex].status = .waiting
            state.batches[batchIndex].currentActivitySummary = "Claude Code launch needs attention."
            state.batches[batchIndex].updatedAt = now
        }
        if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
            state.tasks[taskIndex].status = .queued
            state.tasks[taskIndex].updatedAt = now
        }
        commitWorkingState(state, for: projectPath)
    }

    private func markResumeStarted(
        projectPath: String,
        bindingStore: WorkBatchCockpitBindingStore,
        binding: WorkBatchCockpitBinding,
        batchID: String,
        taskID: String?,
        now: Date,
    ) throws -> WorkBatchCockpitBinding {
        var updatedBinding = binding
        updatedBinding.status = .launching
        updatedBinding.updatedAt = now
        try bindingStore.upsert(updatedBinding)

        var state = workingState(for: projectPath)
        let actionableContextDigest = state.deliveryRecord(batchID: batchID)?.lastActionableContextDigest
        if let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) {
            let taskTitle = taskID
                .flatMap { id in state.tasks.first(where: { $0.id == id })?.displayTitle }
                ?? "Task"
            state.batches[batchIndex].status = .working
            state.batches[batchIndex].currentActivitySummary = "Claude Code is reconnecting to \(taskTitle)."
            state.batches[batchIndex].updatedAt = now
        }
        if let taskID,
           let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID })
        {
            state.tasks[taskIndex].status = .queued
            state.tasks[taskIndex].updatedAt = now
        }
        state.recordDeliveryAttempt(
            batchID: batchID,
            attemptedAt: now,
            kind: WorkBatchDeliveryAction.resumeExistingSession.rawValue,
            actionableContextDigest: actionableContextDigest,
        )
        commitWorkingState(state, for: projectPath)
        return updatedBinding
    }

    private func markExistingSessionWoken(
        projectPath: String,
        bindingStore: WorkBatchCockpitBindingStore,
        binding: WorkBatchCockpitBinding,
        batchID: String,
        taskID: String?,
        now: Date,
    ) throws -> WorkBatchCockpitBinding {
        var updatedBinding = binding
        updatedBinding.status = .running
        updatedBinding.updatedAt = now
        try bindingStore.upsert(updatedBinding)

        var state = workingState(for: projectPath)
        let actionableContextDigest = state.deliveryRecord(batchID: batchID)?.lastActionableContextDigest
        if let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) {
            let taskTitle = taskID
                .flatMap { id in state.tasks.first(where: { $0.id == id })?.displayTitle }
                ?? "Task"
            state.batches[batchIndex].status = .working
            state.batches[batchIndex].currentActivitySummary = "Claude Code was nudged to pick up \(taskTitle)."
            state.batches[batchIndex].updatedAt = now
        }
        if let taskID,
           let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID })
        {
            state.tasks[taskIndex].status = .queued
            state.tasks[taskIndex].updatedAt = now
        }
        state.recordDeliveryAttempt(
            batchID: batchID,
            attemptedAt: now,
            kind: WorkBatchDeliveryAction.wakeExistingSession.rawValue,
            actionableContextDigest: actionableContextDigest,
        )
        commitWorkingState(state, for: projectPath)
        return updatedBinding
    }

    private func markBatchDeliveryWaiting(
        projectPath: String,
        batchID: String,
        summary: String,
        now: Date,
    ) throws {
        var state = workingState(for: projectPath)
        if let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) {
            state.batches[batchIndex].status = .waiting
            state.batches[batchIndex].currentActivitySummary = summary
            state.batches[batchIndex].updatedAt = now
        }
        for taskIndex in state.tasks.indices where state.tasks[taskIndex].batchID == batchID {
            guard state.tasks[taskIndex].status != .done,
                  state.tasks[taskIndex].status != .needsYou
            else { continue }
            state.tasks[taskIndex].status = .queued
            state.tasks[taskIndex].updatedAt = now
        }
        commitWorkingState(state, for: projectPath)
    }

    private func markBatchPickupTimedOut(
        projectPath: String,
        batchID: String,
        summary: String,
        now: Date,
    ) throws {
        var state = workingState(for: projectPath)
        var didChange = false
        if let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) {
            if state.batches[batchIndex].status != .waiting ||
                state.batches[batchIndex].currentActivitySummary != summary
            {
                state.batches[batchIndex].status = .waiting
                state.batches[batchIndex].currentActivitySummary = summary
                state.batches[batchIndex].updatedAt = now
                didChange = true
            }
        }
        for taskIndex in state.tasks.indices where state.tasks[taskIndex].batchID == batchID {
            guard state.tasks[taskIndex].status != .done,
                  state.tasks[taskIndex].status != .needsYou
            else { continue }
            if state.tasks[taskIndex].status != .queued {
                state.tasks[taskIndex].status = .queued
                state.tasks[taskIndex].updatedAt = now
                didChange = true
            }
        }
        guard didChange else { return }
        commitWorkingState(state, for: projectPath)
    }

    private func markReconciliationBlocked(
        projectPath: String,
        batchID: String,
        taskID: String,
        summary: String,
        now: Date,
    ) throws {
        var state = workingState(for: projectPath)
        if let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) {
            state.batches[batchIndex].status = .waiting
            state.batches[batchIndex].currentActivitySummary = summary
            state.batches[batchIndex].updatedAt = now
        }
        if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
            state.tasks[taskIndex].status = .queued
            state.tasks[taskIndex].updatedAt = now
        }
        commitWorkingState(state, for: projectPath)
    }

    private func reconcileBindings(
        projectPath: String,
        bindingStore: WorkBatchCockpitBindingStore,
        sessions: [RuntimeSession],
        now: Date,
    ) throws -> WorkBatchBindingReconciliationResult {
        let state = workingState(for: projectPath)
        let bindings = try bindingStore.load()
        guard !bindings.isEmpty else {
            return WorkBatchBindingReconciliationResult(state: state, bindings: bindings, issues: [])
        }

        let result = WorkBatchBindingReconciler.reconcile(
            state: state,
            bindings: bindings,
            sessions: sessions,
            now: now,
            processSessionIDs: processSessionIDs,
        )
        if result.state != state {
            commitWorkingState(result.state, for: projectPath)
        }
        if result.bindings != bindings {
            try bindingStore.save(result.bindings)
            recomputeProjections(for: projectPath)
        }
        return result
    }

    private func normalizedTitle(for idea: Idea) -> String {
        let title = idea.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != "..." {
            return title
        }
        return String(idea.description.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedBatchName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(80))
    }

    private func fallbackBatchName(for task: WorkBatchTaskRecord) -> String {
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Task Batch" : String(trimmed.prefix(48))
    }

    private func fallbackClassification(
        for request: WorkBatchClassificationRequest,
        error: Error,
        now: Date,
    ) -> WorkBatchClassificationRecord {
        .new(
            taskID: request.task.id,
            batchName: fallbackBatchName(for: request.task),
            confidence: 0,
            rationale: "Fallback after Work Batch classification failed: \(error.localizedDescription)",
            summary: "Started a new Work Batch because automatic classification failed.",
            createdAt: now,
        )
    }

    private func relatednessGuardedClassification(
        _ classification: WorkBatchClassificationRecord,
        request: WorkBatchClassificationRequest,
        existingBatches: [WorkBatchProjection],
        now: Date,
    ) -> WorkBatchClassificationRecord {
        // New Work Batch behavior: the model still owns classification, but Capacitor
        // guards against medium-confidence splits that would spawn avoidable cockpits.
        guard case .new = classification.target,
              classification.confidence < 0.85,
              let relatedBatch = WorkBatchRelatednessPolicy.bestRelatedBatch(
                  for: request.task,
                  among: existingBatches,
                  ignoringTokensFrom: request,
              )
        else {
            return classification
        }

        return .existing(
            taskID: request.task.id,
            batchID: relatedBatch.id,
            confidence: classification.confidence,
            rationale: "Kept related Task in existing Work Batch after low-confidence new-batch classification. Model rationale: \(classification.rationale)",
            summary: "Added to \(relatedBatch.name).",
            createdAt: now,
        )
    }

    private func stableBatchID(name: String, taskID: String) -> String {
        let seed = "\(name)-\(taskID)"
        let sanitized = seed.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "batch-\(collapsed.prefix(48))"
    }
}

private enum WorkBatchRelatednessPolicy {
    private static let stopWords: Set<String> = [
        "about", "across", "added", "after", "again", "against", "all", "also", "and", "are", "around",
        "batch", "being", "bit", "but", "can", "code", "concurrent", "could", "for", "from", "has", "have", "into",
        "its", "make", "more", "new", "now", "old", "one", "other", "same", "session", "should", "some",
        "task", "that", "the", "this", "through", "use", "used", "using", "was", "were", "when", "with",
        "work",

        "change", "changes", "check", "checking", "create", "created", "disposable", "file", "files",
        "keep", "local", "note", "notes", "sentence", "tiny", "txt", "update", "updated",
    ]

    private static let aliases: [String: String] = [
        "copy": "typography",
        "font": "typography",
        "fonts": "typography",
        "text": "typography",
        "type": "typography",
        "typeface": "typography",
        "typefaces": "typography",
        "typographic": "typography",
        "typography": "typography",

        "margin": "layout",
        "margins": "layout",
        "padding": "layout",
        "spacing": "layout",

        "colour": "color",
        "colors": "color",
        "colours": "color",

        "responsive": "mobile",
        "phone": "mobile",
    ]

    static func bestRelatedBatch(
        for task: WorkBatchTaskRecord,
        among batches: [WorkBatchProjection],
        ignoringTokensFrom request: WorkBatchClassificationRequest,
    ) -> WorkBatchProjection? {
        let ignoredTokens = projectIdentityTokens(from: request)
        let taskTokens = tokenSet("\(task.displayTitle) \(task.body)")
            .subtracting(ignoredTokens)
        guard !taskTokens.isEmpty else { return nil }

        let candidates = batches
            .filter { $0.status != .idle }
            .compactMap { batch -> (batch: WorkBatchProjection, score: Int)? in
                let batchTokens = tokenSet(batchText(batch))
                    .subtracting(ignoredTokens)
                let score = taskTokens.intersection(batchTokens).count
                return score > 0 ? (batch, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.batch.updatedAtForRelatedness != rhs.batch.updatedAtForRelatedness {
                    return lhs.batch.updatedAtForRelatedness > rhs.batch.updatedAtForRelatedness
                }
                return lhs.batch.name.localizedStandardCompare(rhs.batch.name) == .orderedAscending
            }

        return candidates.first?.batch
    }

    private static func batchText(_ batch: WorkBatchProjection) -> String {
        (
            [batch.name, batch.currentActivitySummary]
                + batch.tasks.flatMap { [$0.displayTitle, $0.body] },
        )
        .joined(separator: " ")
    }

    private static func projectIdentityTokens(from request: WorkBatchClassificationRequest) -> Set<String> {
        let projectURL = URL(fileURLWithPath: request.projectPath)
        let lastPathComponent = projectURL.lastPathComponent
        return tokenSet("\(request.projectName) \(lastPathComponent)")
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)

        return Set(words.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3,
                  !stopWords.contains(trimmed)
            else {
                return nil
            }
            return aliases[trimmed] ?? trimmed
        })
    }
}

private extension WorkBatchProjection {
    var updatedAtForRelatedness: Date {
        tasks.map(\.updatedAt).max() ?? .distantPast
    }
}
