import Foundation

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

@MainActor
final class WorkBatchAutoRouter {
    typealias Classifier = @Sendable (WorkBatchClassificationRequest) async throws -> WorkBatchClassificationRecord
    typealias StateStoreFactory = (String) -> WorkBatchStateStore
    typealias BindingStoreFactory = (String) -> WorkBatchCockpitBindingStore

    private let classifier: Classifier
    private let stateStoreFactory: StateStoreFactory
    private let bindingStoreFactory: BindingStoreFactory
    private let taskSessionCoordinator: WorkBatchTaskSessionCoordinator
    private var isRouting = false
    private var routeWaiters: [CheckedContinuation<Void, Never>] = []
    private var latestRuntimeSessions: [RuntimeSession] = []
    private var hasRuntimeSessionSnapshot = false

    init(
        classifier: Classifier? = nil,
        stateStoreFactory: StateStoreFactory? = nil,
        bindingStoreFactory: BindingStoreFactory? = nil,
        taskSessionCoordinator: WorkBatchTaskSessionCoordinator? = nil,
    ) {
        let defaultClassifier = ClaudeWorkBatchClassifier()
        self.classifier = classifier ?? { request in
            try await defaultClassifier.classify(request)
        }
        self.stateStoreFactory = stateStoreFactory ?? { projectPath in
            WorkBatchStateStore(projectPath: projectPath)
        }
        self.bindingStoreFactory = bindingStoreFactory ?? { projectPath in
            WorkBatchCockpitBindingStore(projectPath: projectPath)
        }
        self.taskSessionCoordinator = taskSessionCoordinator ?? WorkBatchTaskSessionCoordinator()
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

        let stateStore = stateStoreFactory(project.path)
        let bindingStore = bindingStoreFactory(project.path)
        var state = try stateStore.load()
        var bindings = try bindingStore.load()
        var reconciliationIssues: [WorkBatchBindingReconciliationIssue] = []
        if hasRuntimeSessionSnapshot {
            let result = try reconcileBindings(
                stateStore: stateStore,
                bindingStore: bindingStore,
                sessions: latestRuntimeSessions,
                now: now,
            )
            state = result.state
            bindings = result.bindings
            reconciliationIssues = result.issues
        }
        let projections = WorkBatchProjectionBuilder.build(state: state, bindings: bindings)

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

        state = try stateStore.load()
        bindings = try bindingStore.load()
        if hasRuntimeSessionSnapshot {
            let result = try reconcileBindings(
                stateStore: stateStore,
                bindingStore: bindingStore,
                sessions: latestRuntimeSessions,
                now: now,
            )
            state = result.state
            bindings = result.bindings
            reconciliationIssues = result.issues
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
        try stateStore.save(state)

        let updatedBatchTasks = state.tasks
            .filter { $0.batchID == route.batch.id }
            .map(\.taskItem)

        if var existingBinding = try bindingStore.binding(batchID: route.batch.id) {
            do {
                try writeContextMirror(
                    batch: route.batch,
                    projectPath: project.path,
                    worktreePath: existingBinding.worktreePath,
                    tasks: updatedBatchTasks,
                    checkpoints: state.checkpoints.filter { $0.batchID == route.batch.id },
                    now: now,
                )
            } catch {
                try markLaunchFailed(
                    stateStore: stateStore,
                    batchID: route.batch.id,
                    taskID: route.task.id,
                    now: now,
                )
                throw error
            }
            if hasDuplicateCockpitIssue(for: route.batch.id, in: reconciliationIssues) {
                try markReconciliationBlocked(
                    stateStore: stateStore,
                    batchID: route.batch.id,
                    taskID: route.task.id,
                    summary: "Multiple Claude Code sessions match this Work Batch.",
                    now: now,
                )
            } else if shouldResumeExistingBinding(existingBinding) {
                do {
                    _ = try await taskSessionCoordinator.openExistingSession(
                        existingBinding,
                        allowResumeWhenFocusFails: true,
                    )
                    existingBinding = try markResumeStarted(
                        stateStore: stateStore,
                        bindingStore: bindingStore,
                        binding: existingBinding,
                        batchID: route.batch.id,
                        taskID: route.task.id,
                        now: now,
                    )
                } catch {
                    try markLaunchFailed(
                        stateStore: stateStore,
                        batchID: route.batch.id,
                        taskID: route.task.id,
                        now: now,
                    )
                    throw error
                }
            }
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
            startResult = try await taskSessionCoordinator.startNewSession(
                WorkBatchTaskSessionStartRequest(
                    projectPath: project.path,
                    batchID: route.batch.id,
                    batchName: route.batch.name,
                    tasks: updatedBatchTasks,
                    now: now,
                ),
            )
        } catch {
            try markLaunchFailed(
                stateStore: stateStore,
                batchID: route.batch.id,
                taskID: route.task.id,
                now: now,
            )
            throw error
        }

        var stateAfterLaunch = try stateStore.load()
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
        try stateStore.save(stateAfterLaunch)

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
        let state = (try? stateStoreFactory(projectPath).load()) ?? .empty
        let bindings = (try? bindingStoreFactory(projectPath).load()) ?? []
        return WorkBatchProjectionBuilder.build(state: state, bindings: bindings)
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
        let stateStore = stateStoreFactory(project.path)
        let bindingStore = bindingStoreFactory(project.path)
        var state = try stateStore.load()
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

        try stateStore.save(state)
        try bindingStore.save(bindings)

        let batch = state.batches[batchIndex]
        let batchTasks = state.tasks
            .filter { $0.batchID == batch.id }
            .map(\.taskItem)
        let binding = bindingIndex.map { bindings[$0] }
        if let binding {
            try writeContextMirror(
                batch: batch,
                projectPath: project.path,
                worktreePath: binding.worktreePath,
                tasks: batchTasks,
                checkpoints: state.checkpoints.filter { $0.batchID == batch.id },
                now: now,
            )
        }

        return WorkBatchUnresolveResult(
            batch: batch,
            task: task,
            binding: binding,
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

        let stateStore = stateStoreFactory(project.path)
        let bindingStore = bindingStoreFactory(project.path)
        var state = try stateStore.load()
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

        try stateStore.save(state)
        try bindingStore.save(bindings)

        let batch = state.batches[batchIndex]
        let binding = bindings[bindingIndex]
        try writeContextMirror(
            batch: batch,
            projectPath: project.path,
            worktreePath: binding.worktreePath,
            tasks: state.tasks.filter { $0.batchID == batch.id }.map(\.taskItem),
            checkpoints: state.checkpoints.filter { $0.batchID == batch.id },
            now: now,
        )

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
        if hasRuntimeSessionSnapshot {
            let bindingStore = bindingStoreFactory(binding.projectPath)
            let result = try reconcileBindings(
                stateStore: stateStoreFactory(binding.projectPath),
                bindingStore: bindingStore,
                sessions: latestRuntimeSessions,
                now: Date(),
            )
            if hasDuplicateCockpitIssue(for: binding.batchID, in: result.issues) {
                throw WorkBatchAutoRouterError.duplicateCockpit(batchName: binding.batchName)
            }
            currentBinding = result.bindings.first(where: { $0.batchID == binding.batchID }) ?? binding
        }

        return try await taskSessionCoordinator.openExistingSession(
            currentBinding,
            allowResumeWhenFocusFails: shouldResumeExistingBinding(currentBinding),
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
                    stateStore: stateStoreFactory(project.path),
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

    private func ingestCompletionReports(
        project: Project,
        now: Date,
    ) throws -> [WorkBatchCompletionIngestResult] {
        let stateStore = stateStoreFactory(project.path)
        let bindingStore = bindingStoreFactory(project.path)
        var state = try stateStore.load()
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
                if let completedAt = report.completedAt,
                   completedAt < task.updatedAt
                {
                    continue
                }

                let updateTime = report.completedAt ?? now
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
            try stateStore.save(state)
        }
        if bindings != originalBindings {
            try bindingStore.save(bindings)
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
                try writeContextMirror(
                    batch: batch,
                    projectPath: project.path,
                    worktreePath: binding.worktreePath,
                    tasks: batchTasks,
                    checkpoints: state.checkpoints.filter { $0.batchID == batchID },
                    now: now,
                )
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.ingestCompletionReports mirror failure project=\(project.path) batch=\(batchID) error=\(error.localizedDescription)",
                )
            }
        }

        return results
    }

    private func ingestCheckpointRequests(
        project: Project,
        now: Date,
    ) throws -> [WorkBatchCheckpointIngestResult] {
        let stateStore = stateStoreFactory(project.path)
        let bindingStore = bindingStoreFactory(project.path)
        var state = try stateStore.load()
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
            try stateStore.save(state)
        }
        if bindings != originalBindings {
            try bindingStore.save(bindings)
        }

        for batchID in batchesNeedingMirrorRewrite {
            guard let batch = state.batches.first(where: { $0.id == batchID }),
                  let binding = bindings.first(where: { $0.batchID == batchID })
            else {
                continue
            }
            do {
                try writeContextMirror(
                    batch: batch,
                    projectPath: project.path,
                    worktreePath: binding.worktreePath,
                    tasks: state.tasks.filter { $0.batchID == batchID }.map(\.taskItem),
                    checkpoints: state.checkpoints.filter { $0.batchID == batchID },
                    now: now,
                )
            } catch {
                DebugLog.write(
                    "WorkBatchAutoRouter.ingestCheckpointRequests mirror failure project=\(project.path) batch=\(batchID) error=\(error.localizedDescription)",
                )
            }
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

    private func hasDuplicateCockpitIssue(
        for batchID: String,
        in issues: [WorkBatchBindingReconciliationIssue],
    ) -> Bool {
        issues.contains { issue in
            issue.batchID == batchID && issue.kind == .duplicateCockpit
        }
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

    private func writeContextMirror(
        batch: WorkBatchRecord,
        projectPath: String,
        worktreePath: String,
        tasks: [WorkBatchTaskItem],
        checkpoints: [WorkBatchCheckpointRecord] = [],
        now: Date,
    ) throws {
        _ = try WorkBatchContextMirror(
            batchID: batch.id,
            batchName: batch.name,
            projectPath: projectPath,
            worktreePath: worktreePath,
            tasks: tasks,
            checkpoints: checkpoints,
            updatedAt: now,
        ).write()
    }

    private func markLaunchFailed(
        stateStore: WorkBatchStateStore,
        batchID: String,
        taskID: String,
        now: Date,
    ) throws {
        var state = try stateStore.load()
        if let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) {
            state.batches[batchIndex].status = .waiting
            state.batches[batchIndex].currentActivitySummary = "Claude Code launch needs attention."
            state.batches[batchIndex].updatedAt = now
        }
        if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
            state.tasks[taskIndex].status = .queued
            state.tasks[taskIndex].updatedAt = now
        }
        try stateStore.save(state)
    }

    private func markResumeStarted(
        stateStore: WorkBatchStateStore,
        bindingStore: WorkBatchCockpitBindingStore,
        binding: WorkBatchCockpitBinding,
        batchID: String,
        taskID: String,
        now: Date,
    ) throws -> WorkBatchCockpitBinding {
        var updatedBinding = binding
        updatedBinding.status = .launching
        updatedBinding.updatedAt = now
        try bindingStore.upsert(updatedBinding)

        var state = try stateStore.load()
        if let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) {
            let taskTitle = state.tasks.first(where: { $0.id == taskID })?.displayTitle ?? "Task"
            state.batches[batchIndex].status = .working
            state.batches[batchIndex].currentActivitySummary = "Claude Code is reconnecting to \(taskTitle)."
            state.batches[batchIndex].updatedAt = now
        }
        if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
            state.tasks[taskIndex].status = .queued
            state.tasks[taskIndex].updatedAt = now
        }
        try stateStore.save(state)
        return updatedBinding
    }

    private func markReconciliationBlocked(
        stateStore: WorkBatchStateStore,
        batchID: String,
        taskID: String,
        summary: String,
        now: Date,
    ) throws {
        var state = try stateStore.load()
        if let batchIndex = state.batches.firstIndex(where: { $0.id == batchID }) {
            state.batches[batchIndex].status = .waiting
            state.batches[batchIndex].currentActivitySummary = summary
            state.batches[batchIndex].updatedAt = now
        }
        if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
            state.tasks[taskIndex].status = .queued
            state.tasks[taskIndex].updatedAt = now
        }
        try stateStore.save(state)
    }

    private func reconcileBindings(
        stateStore: WorkBatchStateStore,
        bindingStore: WorkBatchCockpitBindingStore,
        sessions: [RuntimeSession],
        now: Date,
    ) throws -> WorkBatchBindingReconciliationResult {
        let state = try stateStore.load()
        let bindings = try bindingStore.load()
        guard !bindings.isEmpty else {
            return WorkBatchBindingReconciliationResult(state: state, bindings: bindings, issues: [])
        }

        let result = WorkBatchBindingReconciler.reconcile(
            state: state,
            bindings: bindings,
            sessions: sessions,
            now: now,
        )
        if result.state != state {
            try stateStore.save(result.state)
        }
        if result.bindings != bindings {
            try bindingStore.save(result.bindings)
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
    ) -> WorkBatchProjection? {
        let taskTokens = tokenSet("\(task.displayTitle) \(task.body)")
        guard !taskTokens.isEmpty else { return nil }

        let candidates = batches
            .filter { $0.status != .idle }
            .compactMap { batch -> (batch: WorkBatchProjection, score: Int)? in
                let batchTokens = tokenSet(batchText(batch))
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
