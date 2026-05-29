import Foundation

extension AppState {
    func listBuiltinMethods() -> [MethodTemplate] {
        let methods = methodRunnerEngine?.listBuiltinMethods() ?? []
        let visibleMethods = CircuitReceiptGoalPacketMethod.includingReceiptGoalPacket(methods)
        DebugLog.write("AppState.listBuiltinMethods count=\(visibleMethods.count) ids=\(visibleMethods.map(\.id).joined(separator: ","))")
        return visibleMethods
    }

    func runMethodOnIdea(_ idea: Idea, method: MethodTemplate, for project: Project) {
        DebugLog.write(
            "AppState.runMethodOnIdea method=\(method.id) project=\(project.path) enabled=\(featureState.isMethodRunnerEnabled)",
        )

        guard featureState.isMethodRunnerEnabled else {
            uiState.error = "Method runner is disabled for this build."
            return
        }

        if CircuitReceiptGoalPacketMethod.isReceiptGoalPacket(method) {
            runClaudeReceiptGoalPacketOnIdea(idea, method: method, for: project)
            return
        }

        let runID = UUID().uuidString.lowercased()
        let runIntent = IdeaRunIntent.project(idea)
        DebugLog.write("AppState.runMethodOnIdea runId=\(runID) creating...")

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                try await methodRunnerRuntimeClient.mutateRun(.create(
                    projectPath: project.path,
                    runId: runID,
                    methodId: method.id,
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
                                ideaIntent: runIntent.intent,
                                ideaSuccessCriteria: runIntent.successCriteria,
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

    private func runClaudeReceiptGoalPacketOnIdea(_ idea: Idea, method: MethodTemplate, for project: Project) {
        DebugLog.write(
            "AppState.runClaudeReceiptGoalPacketOnIdea method=\(method.id) project=\(project.path) idea=\(idea.id)",
        )
        let receiptStart = beginReceiptLoopRun(for: idea, project: project)
        guard receiptStart.didStart else {
            uiState.toast = ToastMessage("Claude receipt loop already running")
            NotificationCenter.default.post(name: .circuitFirstSliceDidFail, object: nil)
            return
        }

        let receiptRun = receiptStart.state
        uiState.toast = ToastMessage("Claude receipt loop started: \(idea.title)")

        _Concurrency.Task { [weak self, receiptRun] in
            do {
                let result = try await CircuitReceiptProductLoop().run(project: project, idea: idea)
                DebugLog.write(
                    "[CircuitClaudeProductLoop] completed from ordinary idea goalPacket=\(result.planningResponse.goalPacket.id) rawReceipt=\(result.launchResult.launch.artifacts.rawReceiptURL.path) event=\(result.agentEvent.id)",
                )
                await MainActor.run {
                    self?.recordReceiptLoopCompleted(project: project, runID: receiptRun.id)
                    self?.uiState.toast = ToastMessage("Claude receipt captured")
                    NotificationCenter.default.post(name: .circuitFirstSliceDidCapture, object: nil)
                    self?.refreshSessionStates()
                }
            } catch {
                DebugLog.write("[CircuitClaudeProductLoop] ordinary idea failed error=\(error.localizedDescription)")
                await MainActor.run {
                    self?.recordReceiptLoopFailed(
                        project: project,
                        runID: receiptRun.id,
                        reason: "Claude receipt loop failed",
                    )
                    self?.uiState.toast = .error("Claude receipt loop failed")
                    NotificationCenter.default.post(name: .circuitFirstSliceDidFail, object: nil)
                    self?.refreshSessionStates()
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
        if let run = runState.activeRun(for: idea, in: project) {
            return run
        }

        guard let receiptRun = receiptLoopRun(for: project),
              receiptRun.ideaId == idea.id,
              receiptRun.status == .running
        else {
            return nil
        }
        return receiptRun.runtimeRunState(updatedAtOverride: currentISO8601Timestamp())
    }

    func activeRun(for project: Project) -> RuntimeRunState? {
        runState.activeRun(for: project) ?? receiptLoopRuntimeRun(for: project)
    }

    func checkpointTimelineRun(for project: Project) -> RuntimeRunState? {
        runState.checkpointTimelineRun(for: project)
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

    func showRunCheckpointReview(projectPath: String, runID: String, checkpointID: String) {
        uiState.runCheckpointWindowTarget = RunCheckpointWindowTarget(
            projectPath: projectPath,
            runID: runID,
            checkpointID: checkpointID,
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
