import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension AppState {
    func refreshSuggestedProjects() {
        guard let engine else { return }
        do {
            projectState.suggestedProjects = try engine.getSuggestedProjects()
        } catch {
            DebugLog.write("AppState.refreshSuggestedProjects error=\(error.localizedDescription)")
            projectState.suggestedProjects = []
        }
    }

    func addSuggestedProjects(_ suggestions: [SuggestedProject]) {
        guard let engine else { return }
        var addedCount = 0
        for suggestion in suggestions {
            do {
                try engine.addProject(path: suggestion.path)
                projectState.prependToProjectOrder(suggestion.path)
                projectState.suggestedProjects.removeAll { $0.path == suggestion.path }
                addedCount += 1
            } catch {
                DebugLog.write("AppState.addSuggestedProjects error for \(suggestion.name): \(error.localizedDescription)")
            }
        }
        if addedCount > 0 {
            loadDashboard()
            uiState.toast = ToastMessage("Connected \(addedCount) project\(addedCount == 1 ? "" : "s")")
        }
    }

    func connectSelectedSuggestions() {
        let selected = projectState.suggestedProjects.filter { projectState.selectedSuggestedPaths.contains($0.path) }
        addSuggestedProjects(selected)
        projectState.selectedSuggestedPaths = []
    }

    func addProject(_ path: String) {
        guard let engine else { return }
        do {
            try engine.addProject(path: path)
            projectState.prependToProjectOrder(path)
            loadDashboard()
        } catch {
            uiState.error = error.localizedDescription
        }
    }

    func connectProjectViaFileBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select a project folder to connect"
        panel.prompt = "Connect"

        guard panel.runModal() == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        if urls.count > 1 {
            addProjectsFromDrop(urls)
            return
        }

        guard let url = urls.first else { return }
        let path = url.path
        guard let result = validateProject(path) else { return }

        switch result.resultType {
        case "valid", "missing_claude_md":
            addProject(path)
            uiState.pendingDragDropTip = true

        case "suggest_parent":
            if let suggested = result.suggestedPath {
                addProject(suggested)
                uiState.pendingDragDropTip = true
            } else {
                uiState.toast = .error("Could not determine project root")
            }

        case "already_tracked":
            if projectState.manuallyDormant.contains(path) {
                _ = withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    projectState.manuallyDormant.remove(path)
                }
                uiState.toast = ToastMessage("Moved to In Progress")
            } else {
                uiState.toast = ToastMessage("Already linked!")
            }

        case "dangerous_path":
            uiState.toast = .error(result.reason ?? "Path is too broad")

        case "path_not_found":
            uiState.toast = .error("Path not found")

        default:
            uiState.toast = .error(result.reason ?? "Could not connect project")
        }
    }

    func handleFileURLDrop(_ providers: [NSItemProvider]) {
        let loaders: [(@escaping (Data?) -> Void) -> Void] = providers.compactMap { provider in
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                return nil
            }
            return { completion in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    completion(item as? Data)
                }
            }
        }

        collectDroppedFileURLs(loaders: loaders) { [weak self] urls in
            if !urls.isEmpty {
                self?.addProjectsFromDrop(urls)
            }
        }
    }

    func collectDroppedFileURLs(
        loaders: [(@escaping (Data?) -> Void) -> Void],
        completion: @escaping ([URL]) -> Void,
    ) {
        guard !loaders.isEmpty else {
            completion([])
            return
        }

        var urls: [URL] = []
        let urlsLock = NSLock()
        let group = DispatchGroup()

        for load in loaders {
            group.enter()
            load { data in
                defer { group.leave() }
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    return
                }
                urlsLock.lock()
                urls.append(url)
                urlsLock.unlock()
            }
        }

        group.notify(queue: .main) {
            urlsLock.lock()
            let snapshot = urls
            urlsLock.unlock()
            completion(snapshot)
        }
    }

    #if DEBUG
        func collectDroppedFileURLsForTesting(
            loaders: [(@escaping (Data?) -> Void) -> Void],
            completion: @escaping ([URL]) -> Void,
        ) {
            collectDroppedFileURLs(loaders: loaders, completion: completion)
        }
    #endif

    func addProjectsFromDrop(_ urls: [URL]) {
        guard engine != nil else { return }
        guard let worker = projectIngestionWorker else { return }

        if uiState.projectView != .list {
            showProjectList()
        }

        let paths = urls.map(\.path)
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            let outcome = await worker.addProjects(paths: paths)
            await MainActor.run {
                let finalAddedCount = outcome.addedCount
                let finalAddedPaths = outcome.addedPaths
                let finalAlreadyTrackedPaths = outcome.alreadyTrackedPaths
                let finalFailedNames = outcome.failedNames

                var movedCount = 0
                var alreadyInProgressCount = 0

                if !finalAlreadyTrackedPaths.isEmpty {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        for path in finalAlreadyTrackedPaths {
                            if self.projectState.manuallyDormant.contains(path) {
                                self.projectState.manuallyDormant.remove(path)
                                movedCount += 1
                            } else {
                                alreadyInProgressCount += 1
                            }
                        }
                    }
                }

                if finalAddedCount > 0 {
                    self.projectState.prependToProjectOrder(paths: finalAddedPaths)
                    var fastSwapTransaction = Transaction(animation: nil)
                    fastSwapTransaction.disablesAnimations = true
                    withTransaction(fastSwapTransaction) {
                        self.loadDashboard(hydrateIdeas: false, showLoadingState: false)
                    }
                    self.scheduleDeferredIdeaHydration()
                    self.uiState.pendingDragDropTip = true
                }

                if !finalFailedNames.isEmpty {
                    let message = Self.formatMixedResultsToast(
                        failedNames: finalFailedNames,
                        connectedCount: finalAddedCount,
                    )
                    self.uiState.toast = .error(message)
                } else if finalAddedCount == 0 {
                    if movedCount > 0 {
                        self.uiState.toast = ToastMessage(
                            movedCount == 1 ? "Moved to In Progress" : "Moved \(movedCount) projects to In Progress",
                        )
                    } else if alreadyInProgressCount > 0 {
                        self.uiState.toast = ToastMessage("Already linked!")
                    }
                }
            }
        }
    }

    static func formatMixedResultsToast(failedNames: [String], connectedCount: Int) -> String {
        let failedCount = failedNames.count

        let failedPortion: String
        if failedCount == 1 {
            failedPortion = "\(failedNames[0]) failed"
        } else if failedCount == 2 {
            failedPortion = "\(failedNames[0]), \(failedNames[1]) failed"
        } else {
            let remainder = failedCount - 2
            failedPortion = "\(failedNames[0]), \(failedNames[1]) and \(remainder) more failed"
        }

        if connectedCount > 0 {
            return "\(failedPortion) (\(connectedCount) connected)"
        }
        return failedPortion
    }

    func scheduleDeferredIdeaHydration() {
        guard featureState.isIdeaCaptureEnabled else { return }

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            await _Concurrency.Task.yield()
            guard featureState.isIdeaCaptureEnabled else { return }
            await projectDetailsManager.loadAllIdeasIncrementally(for: projectState.projects)
        }
    }

    func removeProject(_ path: String) {
        guard let engine else { return }
        do {
            try engine.removeProject(path: path)
            projectState.removeProjectOrderEntry(for: path)
            projectState.resetProjectTracking(for: path)
            loadDashboard()
        } catch {
            uiState.error = error.localizedDescription
        }
    }

    func validateProject(_ path: String) -> ValidationResultFfi? {
        guard let engine else { return nil }
        return try? engine.validateProject(path: path)
    }

    func getSessionState(for project: Project) -> ProjectSessionState? {
        _ = sessionStateRevision
        return sessionStateManager.getSessionState(for: project)
    }

    func isFlashing(_ project: Project) -> SessionState? {
        _ = sessionStateRevision
        return sessionStateManager.isFlashing(project)
    }

    func getProjectStatus(for project: Project) -> ProjectStatus? {
        projectState.getProjectStatus(for: project)
    }

    func launchTerminal(for project: Project) {
        activeProjectResolver.setManualOverride(project)
        activeProjectResolver.resolve()
        terminalLauncher.launchTerminal(for: project)
    }

    func handlePrimaryProjectAction(for project: Project) {
        let action = ProjectPrimaryActionResolver.resolve(
            delegationState: delegationState(for: project),
            isDelegationEnabled: featureState.isDelegationLoopEnabled,
        )

        switch action {
        case .openTerminal:
            launchTerminal(for: project)
        case .openDelegationReview:
            showDelegationReview(project)
        }
    }

    func showProjectDetail(_ project: Project) {
        projectFeatureCoordinator.showProjectDetail(project)
    }

    func showDelegationReview(_ project: Project) {
        guard featureState.isDelegationLoopEnabled else {
            launchTerminal(for: project)
            return
        }
        if let delegation = delegationState(for: project) {
            uiState.reviewWindowTarget = ReviewWindowTarget(
                projectPath: project.path,
                workerID: delegation.workerId,
            )
        }
    }

    func submitRunCheckpointDecision(
        projectPath: String,
        runID: String,
        checkpointID: String,
        action: String,
        note: String?,
    ) async throws {
        try await runtimeClient.mutateRun(RuntimeRunMutationRequest(
            kind: "submit_decision",
            projectPath: projectPath,
            runId: runID,
            checkpointId: checkpointID,
            methodId: nil,
            involvement: nil,
            checkpointKind: nil,
            checkpointTitle: nil,
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: nil,
            decisionAction: action,
            decisionNote: note?.isEmpty == true ? nil : note,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            captureRequestId: nil,
            clientId: nil,
            observedCaptureUrl: nil,
            captureFailureReason: nil,
            completedMediaArtifacts: [],
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        ))
    }

    func showProjectList() {
        projectFeatureCoordinator.showProjectList()
    }

    func orderedGroupedProjects(_ projects: [Project]) -> (active: [Project], idle: [Project]) {
        projectState.orderedGroupedProjects(
            projects,
            sessionStates: sessionStateManager.sessionStates,
            sessionStateRevision: sessionStateRevision,
        )
    }

    func moveProject(from source: IndexSet, to destination: Int, in projectList: [Project], group: ActivityGroup) {
        projectState.moveProject(
            from: source,
            to: destination,
            in: projectList,
            group: group,
        )
    }

    func moveToDormant(_ project: Project) {
        projectState.moveToDormant(project)
    }

    func moveToRecent(_ project: Project) {
        projectState.moveToRecent(project)
    }

    func isManuallyDormant(_ project: Project) -> Bool {
        projectState.isManuallyDormant(project)
    }

    func showIdeaCaptureModal(for project: Project, from origin: CGRect? = nil) {
        projectFeatureCoordinator.showIdeaCaptureModal(for: project, from: origin)
    }

    func captureIdea(for project: Project, text: String) -> Result<Void, Error> {
        projectFeatureCoordinator.captureIdea(for: project, text: text)
    }

    func checkIdeasFileChanges() {
        projectFeatureCoordinator.checkIdeasFileChanges(for: projectState.projects)
    }

    func getIdeas(for project: Project) -> [Idea] {
        projectFeatureCoordinator.getIdeas(for: project)
    }

    func workBatches(for project: Project) -> [WorkBatchProjection] {
        workBatchAutoRouter.projections(for: project.path)
    }

    func workBatchContextSummary(for project: Project) -> String? {
        let summary = workBatches(for: project)
            .first(where: { batch in
                switch batch.status {
                case .working, .waiting, .ready, .compacting:
                    true
                case .idle:
                    false
                }
            })?
            .currentActivitySummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summary?.isEmpty == false ? summary : nil
    }

    func openWorkBatch(_ batch: WorkBatchProjection, for project: Project) {
        switch WorkBatchOpenActionResolver.resolve(batch) {
        case let .answerCheckpoint(checkpoint):
            uiState.workBatchCheckpointFocusTarget = WorkBatchCheckpointFocusTarget(
                projectPath: project.path,
                batchID: batch.id,
                checkpointID: checkpoint.id,
            )
            uiState.toast = ToastMessage("Checkpoint needs your input.")

        case .openCockpit:
            openWorkBatchCockpit(batch)
        }
    }

    func openWorkBatchCockpit(_ batch: WorkBatchProjection) {
        guard let binding = batch.binding else {
            uiState.toast = .error("No Claude Code session is bound to this Work Batch yet.")
            return
        }

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await workBatchAutoRouter.openCockpit(binding: binding)
            } catch {
                await MainActor.run {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? "Couldn't open the Claude Code session."
                    self.uiState.toast = .error(message)
                }
            }
        }
    }

    func unresolveWorkBatchTask(
        _ task: WorkBatchTaskRecord,
        in batch: WorkBatchProjection,
        for project: Project,
    ) {
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                let result = try workBatchAutoRouter.unresolveTask(
                    project: project,
                    batchID: batch.id,
                    taskID: task.id,
                )
                try? projectDetailsManager.updateIdeaStatus(
                    for: project,
                    ideaID: result.task.sourceIdeaID ?? result.task.id,
                    newStatus: "open",
                )

                if let binding = result.binding,
                   shouldResumeWorkBatchBinding(binding)
                {
                    _ = try await workBatchAutoRouter.openCockpit(binding: binding)
                }

                await MainActor.run {
                    self.uiState.toast = ToastMessage("Reopened \(result.task.displayTitle).")
                    self.refreshSessionStates()
                }
            } catch {
                await MainActor.run {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? "Couldn't reopen the Task."
                    self.uiState.toast = .error(message)
                }
            }
        }
    }

    func submitWorkBatchCheckpointResponse(
        _ checkpoint: WorkBatchCheckpointRecord,
        in batch: WorkBatchProjection,
        for project: Project,
        response: String,
    ) {
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                let result = try workBatchAutoRouter.submitCheckpointResponse(
                    project: project,
                    batchID: batch.id,
                    checkpointID: checkpoint.id,
                    response: response,
                )

                if let binding = result.binding,
                   shouldResumeWorkBatchBinding(binding)
                {
                    _ = try await workBatchAutoRouter.openCockpit(binding: binding)
                }

                await MainActor.run {
                    if self.uiState.workBatchCheckpointFocusTarget?.projectPath == project.path,
                       self.uiState.workBatchCheckpointFocusTarget?.batchID == batch.id,
                       self.uiState.workBatchCheckpointFocusTarget?.checkpointID == checkpoint.id
                    {
                        self.uiState.workBatchCheckpointFocusTarget = nil
                    }
                    self.uiState.toast = ToastMessage("Answered checkpoint for \(result.task.displayTitle).")
                    self.refreshSessionStates()
                }
            } catch {
                await MainActor.run {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? "Couldn't answer the checkpoint."
                    self.uiState.toast = .error(message)
                }
            }
        }
    }

    func handleWorkBatchCompletionIngestResults(
        _ results: [WorkBatchCompletionIngestResult],
        projects: [Project],
    ) {
        guard !results.isEmpty else { return }

        let projectsByPath = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) })
        for result in results {
            guard let project = projectsByPath[result.projectPath] else { continue }
            try? projectDetailsManager.updateIdeaStatus(
                for: project,
                ideaID: result.sourceIdeaID ?? result.taskID,
                newStatus: "done",
            )
        }

        if results.count == 1, let result = results.first {
            uiState.toast = ToastMessage("Task done: \(result.taskTitle).")
        } else {
            uiState.toast = ToastMessage("\(results.count) Tasks done.")
        }
    }

    func handleWorkBatchCheckpointIngestResults(
        _ results: [WorkBatchCheckpointIngestResult],
        projects _: [Project],
    ) {
        guard !results.isEmpty else { return }

        if results.count == 1, let result = results.first {
            uiState.toast = ToastMessage("Checkpoint ready: \(result.taskTitle).")
        } else {
            uiState.toast = ToastMessage("\(results.count) checkpoints need you.")
        }
    }

    private func shouldResumeWorkBatchBinding(_ binding: WorkBatchCockpitBinding) -> Bool {
        switch binding.status {
        case .stale, .waiting, .done:
            true
        case .launching, .running:
            false
        }
    }

    func isGeneratingTitle(for ideaID: String) -> Bool {
        projectFeatureCoordinator.isGeneratingTitle(for: ideaID)
    }

    func dismissIdea(_ idea: Idea, for project: Project) {
        projectFeatureCoordinator.dismissIdea(idea, for: project)
    }

    func reorderIdeas(_ reorderedIdeas: [Idea], for project: Project) {
        projectFeatureCoordinator.reorderIdeas(reorderedIdeas, for: project)
    }

    func startWorkBatchRouting(for idea: Idea, project: Project) {
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await workBatchAutoRouter.routeCapturedTask(
                    project: project,
                    idea: idea,
                )
                await MainActor.run {
                    self.uiState.toast = ToastMessage(
                        result.startedNewSession
                            ? "Task started in \(result.batch.name)."
                            : "Task added to \(result.batch.name).",
                        isError: false,
                    )
                    self.refreshSessionStates()
                }
            } catch {
                await MainActor.run {
                    DebugLog.write(
                        "AppState.startWorkBatchRouting failure project=\(project.path) idea=\(idea.id) error=\(error.localizedDescription)",
                    )
                    self.uiState.toast = .error("Task saved, but Capacitor couldn't start Claude Code.")
                    self.refreshSessionStates()
                }
            }
        }
    }

    func delegateIdea(_ idea: Idea, for project: Project) {
        guard featureState.isDelegationLoopEnabled else {
            uiState.error = "Delegation loop is disabled for this build."
            return
        }

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                try await delegationLoopManager.startDelegation(project: project, idea: idea)
                await MainActor.run {
                    self.refreshSessionStates()
                }
            } catch {
                await MainActor.run {
                    let message = DelegationUserFacingMessage.startFailure(for: error)
                    DebugLog.write(
                        "AppState.delegateIdea failure project=\(project.path) error=\(error.localizedDescription) userMessage=\(message)",
                    )
                    self.uiState.toast = .error(message)
                    self.refreshSessionStates()
                }
            }
        }
    }

    func delegationState(for project: Project) -> RuntimeDelegationState? {
        delegationState(forPath: project.path)
    }

    func delegationState(forPath projectPath: String) -> RuntimeDelegationState? {
        guard featureState.isDelegationLoopEnabled else { return nil }
        return runState.delegationState(forPath: projectPath)
    }

    func getDescription(for project: Project) -> String? {
        projectFeatureCoordinator.getDescription(for: project)
    }

    func isGeneratingDescription(for project: Project) -> Bool {
        projectFeatureCoordinator.isGeneratingDescription(for: project)
    }

    func generateDescription(for project: Project) {
        projectFeatureCoordinator.generateDescription(for: project)
    }

    func loadCreations() {
        projectCreationCoordinator.loadCreations()
    }

    func cancelCreation(_ id: String) {
        projectCreationCoordinator.cancelCreation(id)
    }

    func resumeCreation(_ id: String) {
        projectCreationCoordinator.resumeCreation(id)
    }

    func canResumeCreation(_ id: String) -> Bool {
        projectCreationCoordinator.canResumeCreation(id)
    }
}
