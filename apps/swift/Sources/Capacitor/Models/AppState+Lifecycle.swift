import Foundation

extension AppState {
    func scheduleRuntimeBootstrap() {
        runtimeBootstrapTask?.cancel()
        runtimeBootstrapTask = _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard !_Concurrency.Task.isCancelled else { return }
                engine = try CoreRuntime()
                recordRuntimeBootstrapStepForTesting("createCoreRuntime")
                guard !_Concurrency.Task.isCancelled else { return }

                recordRuntimeBootstrapStepForTesting("startHookServer")
                await hookServerManager.startIfNeeded()
                guard !_Concurrency.Task.isCancelled else { return }

                recordRuntimeBootstrapStepForTesting("ensureRuntimeReady")
                ensureRuntimeReady()
                guard !_Concurrency.Task.isCancelled else { return }

                projectDetailsManager.configure(engine: engine)
                loadDashboard()
                guard !_Concurrency.Task.isCancelled else { return }
                checkHookDiagnostic()
                setupRefreshTimer()
                startShellTracking()
            } catch {
                uiState.error = error.localizedDescription
                uiState.isLoading = false
            }
        }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        didShutdownForTesting = true

        runtimeBootstrapTask?.cancel()
        runtimeBootstrapTask = nil
        longPollTask?.cancel()
        longPollTask = nil
        runtimeSnapshotTask?.cancel()
        runtimeSnapshotTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        hookServerManager.stop()
    }

    func setupRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        startRuntimeSnapshotLongPoll()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.refreshSessionStates()
                if self.featureState.isIdeaCaptureEnabled {
                    self.checkIdeasFileChanges()
                }

                self.hookHealthCheckCounter += 1
                if self.hookHealthCheckCounter >= 1 {
                    self.hookHealthCheckCounter = 0
                    self.checkHookDiagnostic()
                }

                self.hookServerHealthCounter += 1
                if self.hookServerHealthCounter >= 1 {
                    self.hookServerHealthCounter = 0
                    self.hookServerManager.checkHealth()
                }

                self.runtimeHealthCheckCounter += 1
                if self.runtimeHealthCheckCounter >= 2 {
                    self.runtimeHealthCheckCounter = 0
                    self.checkRuntimeHealth()
                }

                self.statsRefreshCounter += 1
                if self.statsRefreshCounter >= 3 {
                    self.statsRefreshCounter = 0
                    self.loadDashboard()
                }
            }
        }
    }

    func startRuntimeSnapshotLongPoll() {
        longPollTask?.cancel()
        longPollTask = nil

        guard runtimeClient.isEnabled else { return }

        longPollTask = _Concurrency.Task { [weak self] in
            guard let self else { return }

            var unavailableRetryDelay: UInt64 = 1_000_000_000 // 1s
            let maxUnavailableRetryDelay: UInt64 = 30_000_000_000 // 30s

            while !_Concurrency.Task.isCancelled {
                let sinceVersion = runtimeSnapshotApplicator.nextLongPollSinceVersion()

                do {
                    let response = try await runtimeClient.longPollSnapshot(sinceVersion: sinceVersion)
                    guard !_Concurrency.Task.isCancelled else { return }

                    switch response {
                    case let .changed(snapshot):
                        unavailableRetryDelay = 1_000_000_000
                        let context = runtimeSnapshotApplicator.makeLongPollContext(projects: projectState.projects)
                        await applyRuntimeSnapshot(
                            snapshot,
                            context: context,
                        )
                    case let .unchanged(snapshotVersion):
                        unavailableRetryDelay = 1_000_000_000
                        runtimeSnapshotApplicator.recordLongPollUnchanged(snapshotVersion: snapshotVersion)
                    case .unavailable:
                        DebugLog.write(
                            "AppState.longPollSnapshot source=runtime_snapshot_long_poll_unavailable retry_in_ms=\(unavailableRetryDelay / 1_000_000)",
                        )
                        try? await _Concurrency.Task.sleep(nanoseconds: unavailableRetryDelay)
                        unavailableRetryDelay = min(unavailableRetryDelay * 2, maxUnavailableRetryDelay)
                        continue
                    }

                    try? await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    if _Concurrency.Task.isCancelled { return }
                    DebugLog.write(
                        "AppState.longPollSnapshot source=runtime_snapshot_long_poll_error error=\(String(describing: error))",
                    )
                    try? await _Concurrency.Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    func startShellTracking() {
        activeProjectResolver.updateProjects(projectState.projects)
    }

    func loadDashboard(hydrateIdeas: Bool = true, showLoadingState: Bool = true) {
        guard let engine else { return }
        if showLoadingState {
            uiState.isLoading = true
        }

        do {
            uiState.dashboard = try engine.loadDashboard()
            projectState.projects = uiState.dashboard?.projects ?? []
            if projectState.projects.isEmpty, projectState.suggestedProjects.isEmpty {
                refreshSuggestedProjects()
            } else if !projectState.projects.isEmpty, !projectState.suggestedProjects.isEmpty {
                projectState.suggestedProjects = []
                projectState.selectedSuggestedPaths = []
            }

            activeProjectResolver.updateProjects(projectState.projects)
            refreshSessionStates()
            if hydrateIdeas, featureState.isIdeaCaptureEnabled {
                projectDetailsManager.loadAllIdeas(for: projectState.projects)
            }
            if showLoadingState {
                uiState.isLoading = false
            }
        } catch {
            uiState.error = error.localizedDescription
            if showLoadingState {
                uiState.isLoading = false
            }
        }
    }

    func refreshSessionStates() {
        projectState.refreshProjectStatuses(using: engine)
        let context = runtimeSnapshotApplicator.beginFetch(projects: projectState.projects)
        runtimeSnapshotTask?.cancel()
        runtimeSnapshotTask = _Concurrency.Task { [weak self] in
            guard let self else { return }

            do {
                let snapshot = try await runtimeClient.fetchRuntimeSnapshot(correlationId: context.correlationId)
                guard !_Concurrency.Task.isCancelled else { return }

                await applyRuntimeSnapshot(
                    snapshot,
                    context: context,
                )
            } catch {
                await MainActor.run {
                    let outcome = self.runtimeSnapshotApplicator.recordFailure(
                        context: context,
                        errorDescription: String(describing: error),
                    )
                    self.executeRuntimeSnapshotEffects(outcome.effects)
                }
            }
        }
    }

    @MainActor
    func applyRuntimeSnapshot(
        _ snapshot: RuntimeSnapshot,
        context: RuntimeSnapshotApplicator.RequestContext,
    ) async {
        let outcome = runtimeSnapshotApplicator.apply(snapshot, context: context)
        executeRuntimeSnapshotEffects(outcome.effects)
    }

    @MainActor
    func executeRuntimeSnapshotEffects(_ effects: [RuntimeSnapshotApplicator.Effect]) {
        for effect in effects {
            switch effect {
            case .updatePostSessionRefreshContext:
                updatePostSessionRefreshContext()
            case let .reconcileDelegations(delegations):
                _Concurrency.Task { [delegationLoopManager] in
                    await delegationLoopManager?.reconcile(delegations: delegations)
                }
            case let .reconcileRunCaptures(runs):
                _Concurrency.Task { [runCaptureCoordinator] in
                    await runCaptureCoordinator.reconcile(runs: runs)
                }
            }
        }
    }

    func updatePostSessionRefreshContext() {
        activeProjectResolver.resolve()
        projectState.reconcileProjectGroups(sessionStates: sessionStateManager.sessionStates)
        DiagnosticsSnapshotLogger.updateContext(
            activeProjectPath: activeProjectPath,
            activeSource: activeSource,
        )
        DebugLog.write(
            "AppState.refreshSessionStates activeProject=\(activeProjectResolver.activeProject?.path ?? "nil") source=\(String(describing: activeProjectResolver.activeSource))",
        )

        if let active = activeProjectResolver.activeProject {
            Telemetry.emit("active_project_resolution", "Resolved active project", payload: [
                "project": active.name,
                "path": active.path,
                "source": String(describing: activeProjectResolver.activeSource),
            ])
        } else {
            Telemetry.emit("active_project_resolution", "No active project", payload: [
                "source": String(describing: activeProjectResolver.activeSource),
            ])
        }

        sessionSummarizer.evaluateProjects(
            projects: projectState.projects,
            sessionStates: sessionStateManager.sessionStates,
            delegationStates: runState.delegationStates,
        )
    }

    func checkHookDiagnostic() {
        guard let engine else { return }
        uiState.hookDiagnostic = try? engine.getHookDiagnostic()
    }

    func fixHooks() {
        guard let engine else { return }

        if let hookInstallError = HookInstaller.ensureHooksInstalled(using: engine) {
            uiState.toast = ToastMessage(hookInstallError, isError: true)
            return
        }

        checkHookDiagnostic()
        if uiState.hookDiagnostic?.isHealthy == true {
            uiState.toast = ToastMessage("Hooks repaired")
        }
    }

    func testHooks() -> HookTestResult {
        guard let engine else {
            return HookTestResult(
                success: false,
                hookActivityOk: false,
                hookActivityAgeSecs: nil,
                runtimeServiceOk: false,
                message: "Engine not initialized",
            )
        }
        do {
            return try engine.runHookTest()
        } catch {
            return HookTestResult(
                success: false,
                hookActivityOk: false,
                hookActivityAgeSecs: nil,
                runtimeServiceOk: false,
                message: "Engine error: \(error.localizedDescription)",
            )
        }
    }

    func ensureRuntimeReady() {
        checkRuntimeHealth()
    }

    func checkRuntimeHealth() {
        guard runtimeClient.isEnabled else {
            uiState.runtimeStatus = RuntimeStatus(
                isEnabled: false,
                isHealthy: false,
                message: "Runtime disabled",
                pid: nil,
                version: nil,
            )
            featureState.refreshRoutingRollout(with: nil)
            Telemetry.emit("runtime_health", "Runtime disabled", payload: [
                "enabled": false,
            ])
            return
        }

        _Concurrency.Task { [weak self] in
            do {
                guard let self else { return }
                let health = try await runtimeClient.fetchHealth()
                await MainActor.run {
                    self.uiState.runtimeStatus = RuntimeStatus(
                        isEnabled: true,
                        isHealthy: health.isCompatibleBootstrapService,
                        message: "Local runtime service healthy",
                        pid: health.pid,
                        version: health.version,
                    )
                    self.featureState.refreshRoutingRollout(with: health)
                    Telemetry.emit("runtime_health", "Runtime healthy", payload: [
                        "enabled": true,
                        "healthy": true,
                        "pid": health.pid,
                        "version": health.version,
                    ])
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.uiState.runtimeStatus = RuntimeStatus(
                        isEnabled: true,
                        isHealthy: false,
                        message: "Local runtime service unavailable",
                        pid: nil,
                        version: nil,
                    )
                    self.featureState.refreshRoutingRollout(with: nil)
                    Telemetry.emit("runtime_health", "Runtime unhealthy", payload: [
                        "enabled": true,
                        "healthy": false,
                        "error": String(describing: error),
                    ])
                }
            }
        }
    }

    func handleIncompatibleRuntimeServiceSchema(
        observedSchemaVersion: Int,
        minimumSchemaVersion: Int,
    ) async {
        DebugLog.write(
            "Runtime service schema version \(observedSchemaVersion) is older than required version \(minimumSchemaVersion). Restarting runtime.",
        )
        hookServerManager.stop()
        await hookServerManager.startIfNeeded()
        uiState.toast = ToastMessage("Runtime service restarted for compatibility")
    }

    func resolveActivationRoute(
        projectPath: String,
        clientTty: String?,
        sessionName: String?,
    ) async -> RuntimeRoutingView? {
        do {
            let snapshot = try await runtimeClient.fetchCoreRoutingSnapshot(
                projectPath: projectPath,
                workspaceId: nil,
                clientTty: clientTty,
                sessionName: sessionName,
            )
            guard snapshot.status != "unavailable", snapshot.target.kind != "none" else {
                return nil
            }
            return RuntimeRoutingView(
                workspaceId: snapshot.workspaceId,
                projectPath: snapshot.projectPath,
                status: snapshot.status,
                target: snapshot.target,
                reasonCode: snapshot.reasonCode,
                reason: snapshot.reason,
                updatedAt: snapshot.updatedAt,
            )
        } catch {
            DebugLog.write(
                "AppState.resolveActivationRoute source=runtime_route_error path=\(projectPath) error=\(error)",
            )
            return nil
        }
    }
}
