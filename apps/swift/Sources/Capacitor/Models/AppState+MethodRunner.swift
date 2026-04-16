import Foundation

extension AppState {
    func listBuiltinMethods() -> [MethodTemplate] {
        let methods = methodRunnerEngine?.listBuiltinMethods() ?? []
        DebugLog.write("AppState.listBuiltinMethods count=\(methods.count) ids=\(methods.map(\.id).joined(separator: ","))")
        return methods
    }

    func runMethodOnIdea(_ idea: Idea, method: MethodTemplate, for project: Project) {
        DebugLog.write(
            "AppState.runMethodOnIdea method=\(method.id) project=\(project.path) enabled=\(featureState.isMethodRunnerEnabled)",
        )

        guard featureState.isMethodRunnerEnabled else {
            uiState.error = "Method runner is disabled for this build."
            return
        }

        let runID = UUID().uuidString.lowercased()
        DebugLog.write("AppState.runMethodOnIdea runId=\(runID) creating...")

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                try await methodRunnerRuntimeClient.mutateRun(RuntimeRunMutationRequest(
                    kind: "create",
                    projectPath: project.path,
                    runId: runID,
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
                    self.uiState.toast = ToastMessage("Method run started: \(method.name)")
                    self.refreshSessionStates()
                }

                if let coordinator = methodRunnerCoordinator {
                    _Concurrency.Task.detached { [weak self] in
                        do {
                            try await coordinator.startRun(
                                runID: runID,
                                methodID: method.id,
                                projectPath: project.path,
                                ideaTitle: idea.title,
                                ideaDescription: idea.description,
                            )
                        } catch {
                            DebugLog.write(
                                "MethodRunCoordinator.startRun failure runID=\(runID) error=\(error.localizedDescription)",
                            )
                            let appState = self
                            await MainActor.run {
                                appState?.uiState.toast = .error("Method run failed: \(error.localizedDescription)")
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
                    self.uiState.toast = .error("Failed to start method run: \(error.localizedDescription)")
                    self.refreshSessionStates()
                }
            }
        }
    }

    func runState(projectPath: String, runID: String) -> RuntimeRunState? {
        runState.runState(projectPath: projectPath, runID: runID)
    }

    var recentTerminalRuns: [RuntimeRunState] {
        runState.recentTerminalRuns
    }

    func activeRun(for idea: Idea, in project: Project) -> RuntimeRunState? {
        runState.activeRun(for: idea, in: project)
    }

    func activeRun(for project: Project) -> RuntimeRunState? {
        runState.activeRun(for: project)
    }

    func runCheckpointState(target: RunCheckpointWindowTarget) -> RuntimeCheckpointState? {
        runState.runCheckpointState(target: target)
    }

    func showRunCheckpointReview(for run: RuntimeRunState) {
        guard let checkpoint = run.activeCheckpoint else { return }
        uiState.runCheckpointWindowTarget = RunCheckpointWindowTarget(
            projectPath: run.projectPath,
            runID: run.id,
            checkpointID: checkpoint.id,
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

            runState.applyAcceptedReviewDecisionLocally(
                delegation,
                sessionId: accepted.sessionId,
                submittedMilestoneId: accepted.submittedMilestoneId,
            )

            if !fromWindow {
                showProjectList()
                uiState.toast = ToastMessage("Feedback sent to worker")
            }

            await delegationLoopManager.launchResumeInBackground(accepted)
            scheduleDelegationRefreshAfterReviewSubmission()
        } catch {
            let message = DelegationUserFacingMessage.reviewFailure(for: error)
            DebugLog.write(
                "AppState.submitDelegationReview failure project=\(project.path) worker=\(delegation.workerId) error=\(error.localizedDescription) userMessage=\(message)",
            )
            uiState.toast = .error(message)
            refreshSessionStates()
            throw error
        }
    }

    func scheduleDelegationRefreshAfterReviewSubmission() {
        _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(nanoseconds: 300_000_000)
            refreshSessionStates()
        }
    }
}
