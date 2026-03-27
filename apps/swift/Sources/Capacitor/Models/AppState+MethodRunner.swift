import Foundation

extension AppState {
    // MARK: - Method Runner

    func listBuiltinMethods() -> [MethodTemplate] {
        let methods = methodRunnerEngine?.listBuiltinMethods() ?? []
        DebugLog.write("AppState.listBuiltinMethods count=\(methods.count) ids=\(methods.map(\.id).joined(separator: ","))")
        return methods
    }

    func runMethodOnIdea(_ idea: Idea, method: MethodTemplate, for project: Project) {
        DebugLog.write("AppState.runMethodOnIdea method=\(method.id) project=\(project.path) enabled=\(isMethodRunnerEnabled)")

        guard isMethodRunnerEnabled else {
            error = "Method runner is disabled for this build."
            return
        }

        let runId = UUID().uuidString.lowercased()
        DebugLog.write("AppState.runMethodOnIdea runId=\(runId) creating...")

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                try await methodRunnerRuntimeClient.mutateRun(RuntimeRunMutationRequest(
                    kind: "create",
                    projectPath: project.path,
                    runId: runId,
                    checkpointId: nil,
                    methodId: method.id,
                    involvement: nil,
                    checkpointKind: nil,
                    checkpointTitle: nil,
                    checkpointSummary: nil,
                    checkpointBriefPath: nil,
                    checkpointManifestPath: nil,
                    checkpointMediaArtifacts: [],
                    checkpointMermaidSources: [],
                    captureUrl: nil,
                    decisionAction: nil,
                    decisionNote: nil,
                    sessionId: nil,
                    delegationWorkerId: nil,
                    statusMessage: nil,
                    captureRequestId: nil,
                    clientId: nil,
                    observedCaptureUrl: nil,
                    captureFailureReason: nil,
                    completedMediaArtifacts: [],
                    ideaId: idea.id,
                    ideaTitle: idea.title,
                    ideaDescription: compactRunIdeaDescription(idea.description),
                ))

                await MainActor.run {
                    self.toast = ToastMessage("Method run started: \(method.name)")
                    self.refreshSessionStates()
                }

                // Spawn the method-runner subprocess in the background.
                // It runs asynchronously; completion/failure is handled by the coordinator.
                if let coordinator = methodRunnerCoordinator {
                    _Concurrency.Task.detached { [weak self] in
                        do {
                            try await coordinator.startRun(
                                runID: runId,
                                methodID: method.id,
                                projectPath: project.path,
                                ideaTitle: idea.title,
                                ideaDescription: idea.description,
                            )
                        } catch {
                            DebugLog.write(
                                "MethodRunCoordinator.startRun failure runID=\(runId) error=\(error.localizedDescription)",
                            )
                            let appState = self
                            await MainActor.run {
                                appState?.toast = .error("Method run failed: \(error.localizedDescription)")
                                appState?.refreshSessionStates()
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    DebugLog.write(
                        "AppState.runMethodOnIdea failure project=\(project.path) method=\(method.id) error=\(error.localizedDescription)",
                    )
                    self.toast = .error("Failed to start method run: \(error.localizedDescription)")
                    self.refreshSessionStates()
                }
            }
        }
    }

    func runState(projectPath: String, runID: String) -> RuntimeRunState? {
        runStatesByID[RuntimeRunKey(projectPath: projectPath, runID: runID)]
    }

    /// Returns the most-recent non-terminal run matching an idea.
    func activeRun(for idea: Idea, in project: Project) -> RuntimeRunState? {
        let normalizedProjectPath = PathNormalizer.normalize(project.path)
        let terminalStatuses: Set<String> = ["completed", "failed", "cancelled"]

        return runStatesByID.values
            .filter {
                PathNormalizer.normalize($0.projectPath) == normalizedProjectPath
                    && $0.ideaId == idea.id
                    && !terminalStatuses.contains($0.status)
            }
            .sorted(by: activeIdeaRunPrecedes)
            .first
    }

    func activeRun(for project: Project) -> RuntimeRunState? {
        ProjectRunVisualStateResolver.resolve(
            projectPath: project.path,
            runsByID: runStatesByID,
        ).run
    }

    func runCheckpointState(target: RunCheckpointWindowTarget) -> RuntimeCheckpointState? {
        runCheckpointState(
            target: target,
            runsByID: runStatesByID,
        )
    }

    func submitDelegationReview(
        for project: Project,
        delegation: RuntimeDelegationState,
        decision: DelegationLoopManager.ReviewDecision,
        note: String,
        fromWindow: Bool = false,
    ) async throws {
        do {
            let accepted = try await delegationLoopManager.acceptReviewDecision(
                project: project,
                delegation: delegation,
                decision: decision,
                note: note,
            )

            applyAcceptedReviewDecisionLocally(
                delegation,
                sessionId: accepted.sessionId,
                submittedMilestoneId: accepted.submittedMilestoneId,
            )

            if !fromWindow {
                showProjectList()
                toast = ToastMessage("Feedback sent to worker")
            }

            await delegationLoopManager.launchResumeInBackground(accepted)
            scheduleDelegationRefreshAfterReviewSubmission()
        } catch {
            let message = DelegationUserFacingMessage.reviewFailure(for: error)
            DebugLog.write(
                "AppState.submitDelegationReview failure project=\(project.path) worker=\(delegation.workerId) error=\(error.localizedDescription) userMessage=\(message)",
            )
            toast = .error(message)
            refreshSessionStates()
            throw error
        }
    }

    private func applyAcceptedReviewDecisionLocally(
        _ delegation: RuntimeDelegationState,
        sessionId: String,
        submittedMilestoneId: String,
    ) {
        let normalizedProjectPath = PathNormalizer.normalize(delegation.projectPath)
        guard delegationStates[normalizedProjectPath] != nil else { return }

        setDelegationState(
            RuntimeDelegationState(
                projectPath: delegation.projectPath,
                workerId: delegation.workerId,
                ideaId: delegation.ideaId,
                worktreeName: delegation.worktreeName,
                worktreePath: delegation.worktreePath,
                sessionId: sessionId,
                status: "resume_pending",
                startedAt: delegation.startedAt,
                updatedAt: formatISO8601Timestamp(Date()),
                submittedMilestoneId: submittedMilestoneId,
                currentReview: delegation.currentReview,
            ),
            forNormalizedProjectPath: normalizedProjectPath,
        )
    }

    private func scheduleDelegationRefreshAfterReviewSubmission() {
        _Concurrency.Task { @MainActor in
            // Give the runtime mutation a moment to land before replacing the optimistic resume_pending state.
            try? await _Concurrency.Task.sleep(nanoseconds: 300_000_000)
            refreshSessionStates()
        }
    }

    func reconcileRunCheckpointWindowTarget(
        previousRunsByID: [RuntimeRunKey: RuntimeRunState],
        nextRunsByID: [RuntimeRunKey: RuntimeRunState],
    ) {
        if let currentTarget = runCheckpointWindowTarget,
           runCheckpointState(
               target: currentTarget,
               runsByID: nextRunsByID,
           ) != nil
        {
            return
        }

        let queuedTargets = nextRunsByID.values
            .filter(isEligibleRunCheckpointCandidate)
            .sorted(by: runCheckpointCandidatePrecedes)
            .compactMap(runCheckpointTarget(for:))

        guard !queuedTargets.isEmpty else {
            runCheckpointWindowTarget = nil
            return
        }

        let newlySurfacedTargets = nextRunsByID.values
            .filter(isEligibleRunCheckpointCandidate)
            .filter { run in
                isNewlySurfacedRunCheckpoint(
                    run,
                    previousRunsByID: previousRunsByID,
                )
            }
            .sorted(by: runCheckpointCandidatePrecedes)
            .compactMap(runCheckpointTarget(for:))

        if runCheckpointWindowTarget != nil {
            runCheckpointWindowTarget = queuedTargets.first
        } else if let newlySurfacedTarget = newlySurfacedTargets.first {
            runCheckpointWindowTarget = newlySurfacedTarget
        }
    }

    private func isEligibleRunCheckpointCandidate(_ run: RuntimeRunState) -> Bool {
        run.status == "paused" && run.activeCheckpoint != nil
    }

    private func isNewlySurfacedRunCheckpoint(
        _ run: RuntimeRunState,
        previousRunsByID: [RuntimeRunKey: RuntimeRunState],
    ) -> Bool {
        guard let checkpoint = run.activeCheckpoint else { return false }
        guard let previousRun = previousRunsByID[RuntimeRunKey(run: run)] else { return true }
        guard previousRun.status == "paused",
              let previousCheckpoint = previousRun.activeCheckpoint
        else {
            return true
        }

        return previousCheckpoint.id != checkpoint.id
    }

    private func runCheckpointTarget(for run: RuntimeRunState) -> RunCheckpointWindowTarget? {
        guard let checkpoint = run.activeCheckpoint else { return nil }
        return RunCheckpointWindowTarget(
            projectPath: run.projectPath,
            runID: run.id,
            checkpointID: checkpoint.id,
        )
    }

    private func runCheckpointCandidatePrecedes(
        _ lhs: RuntimeRunState,
        _ rhs: RuntimeRunState,
    ) -> Bool {
        let lhsCreatedAt = lhs.activeCheckpoint?.createdAt ?? lhs.createdAt
        let rhsCreatedAt = rhs.activeCheckpoint?.createdAt ?? rhs.createdAt

        switch (parseISO8601Date(lhsCreatedAt), parseISO8601Date(rhsCreatedAt)) {
        case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhsCreatedAt != rhsCreatedAt {
                return lhsCreatedAt < rhsCreatedAt
            }
        }

        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }

        return PathNormalizer.normalize(lhs.projectPath) < PathNormalizer.normalize(rhs.projectPath)
    }

    private func activeIdeaRunPrecedes(
        _ lhs: RuntimeRunState,
        _ rhs: RuntimeRunState,
    ) -> Bool {
        switch (parseISO8601Date(lhs.updatedAt), parseISO8601Date(rhs.updatedAt)) {
        case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
        }

        switch (parseISO8601Date(lhs.createdAt), parseISO8601Date(rhs.createdAt)) {
        case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
        }

        return lhs.id < rhs.id
    }

    private func runCheckpointState(
        target: RunCheckpointWindowTarget,
        runsByID: [RuntimeRunKey: RuntimeRunState],
    ) -> RuntimeCheckpointState? {
        guard let run = runsByID[RuntimeRunKey(projectPath: target.projectPath, runID: target.runID)],
              run.status == "paused",
              let checkpoint = run.activeCheckpoint,
              checkpoint.id == target.checkpointID
        else {
            return nil
        }

        return checkpoint
    }
}
