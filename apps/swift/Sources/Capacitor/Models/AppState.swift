import Foundation
import Observation

@Observable
@MainActor
class AppState {
    typealias ReviewWindowTarget = Capacitor.ReviewWindowTarget
    typealias RunCheckpointWindowTarget = Capacitor.RunCheckpointWindowTarget

    let projectState = ProjectState()
    let uiState = UIState()
    let featureState = FeatureState()
    let runState = RunStateStore()

    let anchoringController = WindowAnchoringController()
    let shellStateStore = ShellStateStore()
    let routingStateStore = RoutingStateStore()
    let terminalLauncher = TerminalLauncher()
    let sessionStateManager = SessionStateManager()
    let operatorViewStateStore: OperatorViewStateStore
    let hookServerManager: HookServerManager
    let projectDetailsManager = ProjectDetailsManager()
    let workBatchAutoRouter: WorkBatchAutoRouter
    let sessionSummarizer = SessionSummarizer()
    private(set) var runtimeSnapshotApplicator: RuntimeSnapshotApplicator!
    private(set) var delegationLoopManager: DelegationLoopManager!
    let runCaptureCoordinator: RunCaptureCoordinator
    let projectIngestionWorker = ProjectIngestionWorker()
    private(set) var projectCreationCoordinator: ProjectCreationCoordinator!
    private(set) var projectFeatureCoordinator: ProjectFeatureCoordinator!
    private(set) var activeProjectResolver: ActiveProjectResolver!

    let activationPolicy = ActivationPolicy()
    let runtimeClient: RuntimeClient
    var methodRunCoordinator: MethodRunCoordinator?
    @ObservationIgnored var runtimeSnapshotEffectHandlers: RuntimeSnapshotEffectHandlers!
    var engine: CoreRuntime?
    private(set) var operatorViewStateSnapshot = OperatorViewStateStore.Snapshot.empty
    var receiptLoopRunsByProjectPath: [String: ReceiptLoopRunState] = [:]

    @ObservationIgnored var refreshTimer: Timer?
    @ObservationIgnored var longPollTask: _Concurrency.Task<Void, Never>?
    @ObservationIgnored var runtimeBootstrapTask: _Concurrency.Task<Void, Never>?
    @ObservationIgnored var runtimeSnapshotTask: _Concurrency.Task<Void, Never>?
    @ObservationIgnored var didShutdownForTesting = false
    #if DEBUG
        @ObservationIgnored var runtimeBootstrapTraceForTesting: [String] = []
    #endif
    @ObservationIgnored var isShuttingDown = false
    @ObservationIgnored var hookHealthCheckCounter = 0
    @ObservationIgnored var hookServerHealthCounter = 0
    @ObservationIgnored var statsRefreshCounter = 0
    @ObservationIgnored var runtimeHealthCheckCounter = 0

    var activeProjectPath: String? {
        activeProjectResolver?.activeProject?.path
    }

    var activeSource: ActiveSource {
        activeProjectResolver?.activeSource ?? .none
    }

    var methodRunnerRuntimeClient: RuntimeClient {
        runtimeClient
    }

    var systemPowerRuntimeClient: RuntimeClient {
        runtimeClient
    }

    var methodRunnerCoordinator: MethodRunCoordinator? {
        methodRunCoordinator
    }

    var methodRunnerEngine: CoreRuntime? {
        engine
    }

    init(
        runtimeClient: RuntimeClient = RuntimeClient.shared,
        hookServerManager: HookServerManager = HookServerManager(),
        operatorViewStateStore: OperatorViewStateStore = OperatorViewStateStore(),
        workBatchAutoRouter: WorkBatchAutoRouter? = nil,
        operatorViewOpenedAt: Date = Date(),
    ) {
        self.runtimeClient = runtimeClient
        self.hookServerManager = hookServerManager
        self.operatorViewStateStore = operatorViewStateStore
        self.workBatchAutoRouter = workBatchAutoRouter ?? WorkBatchAutoRouter()
        runCaptureCoordinator = RunCaptureCoordinator(runtimeClient: runtimeClient)
        methodRunCoordinator = MethodRunCoordinator(mutateRun: { request in
            try await runtimeClient.mutateRun(request)
        })

        self.runtimeClient.setIncompatibleSchemaHandler { [weak self] health, minimumSchemaVersion in
            guard let self else { return }
            await handleIncompatibleRuntimeServiceSchema(
                observedSchemaVersion: health.normalizedSchemaVersion,
                minimumSchemaVersion: minimumSchemaVersion,
            )
        }

        DebugLog.write(
            "AppState.init start runtimeEnabled=\(runtimeClient.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        let config = AppConfig.current()
        #if DEBUG
            AlphaChannelGuardrail.enforceOrExit(channel: config.channel)
        #endif
        featureState.configure(with: config)
        DebugLog.write(
            "AppState.init config channel=\(featureState.channel.rawValue) profile=\(featureState.profile.rawValue)",
        )
        featureState.refreshRoutingRollout(with: nil)
        runtimeSnapshotApplicator = RuntimeSnapshotApplicator(
            sessionStateManager: sessionStateManager,
            shellStateStore: shellStateStore,
            routingStateStore: routingStateStore,
            runState: runState,
            uiState: uiState,
            isDelegationLoopEnabled: { [featureState] in
                featureState.isDelegationLoopEnabled
            },
        )

        activeProjectResolver = ActiveProjectResolver(
            sessionStateManager: sessionStateManager,
        )
        terminalLauncher.activationIntentResolver = { [weak self] clientTty, projectPath, sessionName in
            guard let self else {
                return ActivationPolicy().resolveIntent(
                    projectPath: projectPath,
                    clientTty: clientTty,
                    sessionName: sessionName,
                    route: nil,
                )
            }

            let route = if let cachedRoute = routingStateStore.routingView(
                projectPath: projectPath,
                workspaceId: nil,
            ) {
                cachedRoute
            } else {
                await resolveActivationRoute(
                    projectPath: projectPath,
                    clientTty: clientTty,
                    sessionName: sessionName,
                )
            }

            return activationPolicy.resolveIntent(
                projectPath: projectPath,
                clientTty: clientTty,
                sessionName: sessionName,
                route: route,
            )
        }

        projectCreationCoordinator = ProjectCreationCoordinator(
            ideaCaptureEnabled: { [weak self] in
                self?.featureState.isIdeaCaptureEnabled ?? false
            },
            readCreations: { [weak self] in
                self?.projectState.activeCreations ?? []
            },
            writeCreations: { [weak self] creations in
                self?.projectState.activeCreations = creations
            },
            engineProvider: { [weak self] in
                self?.engine
            },
            dashboardReloader: { [weak self] in
                self?.loadDashboard()
            },
        )
        delegationLoopManager = DelegationLoopManager(runtimeClient: runtimeClient)
        projectFeatureCoordinator = ProjectFeatureCoordinator(
            projectDetailsEnabled: { [weak self] in
                self?.featureState.isProjectDetailsEnabled ?? false
            },
            ideaCaptureEnabled: { [weak self] in
                self?.featureState.isIdeaCaptureEnabled ?? false
            },
            llmFeaturesEnabled: { [weak self] in
                self?.featureState.isLlmFeaturesEnabled ?? false
            },
            writeProjectView: { [weak self] in
                self?.uiState.projectView = $0
            },
            writeCaptureModalProject: { [weak self] in
                self?.uiState.captureModalProject = $0
            },
            writeCaptureModalOrigin: { [weak self] in
                self?.uiState.captureModalOrigin = $0
            },
            writeShowCaptureModal: { [weak self] in
                self?.uiState.showCaptureModal = $0
            },
            writeError: { [weak self] in
                self?.uiState.error = $0
            },
            captureIdeaHandler: { [weak self] project, text in
                guard let self else {
                    return .failure(AppFeatureError.ideaCaptureDisabled)
                }
                switch projectDetailsManager.captureTask(for: project, text: text) {
                case let .success(idea):
                    startWorkBatchRouting(for: idea, project: project)
                    return .success(())
                case let .failure(error):
                    return .failure(error)
                }
            },
            checkIdeasFileChangesHandler: { [weak self] projects in
                self?.projectDetailsManager.checkIdeasFileChanges(for: projects)
            },
            getIdeasHandler: { [weak self] project in
                self?.projectDetailsManager.getIdeas(for: project) ?? []
            },
            isGeneratingTitleHandler: { [weak self] ideaID in
                self?.projectDetailsManager.isGeneratingTitle(for: ideaID) ?? false
            },
            dismissIdeaHandler: { [weak self] idea, project in
                try self?.projectDetailsManager.updateIdeaStatus(for: project, idea: idea, newStatus: "done")
            },
            reorderIdeasHandler: { [weak self] ideas, project in
                self?.projectDetailsManager.reorderIdeas(ideas, for: project)
            },
            getDescriptionHandler: { [weak self] project in
                self?.projectDetailsManager.getDescription(for: project)
            },
            isGeneratingDescriptionHandler: { [weak self] project in
                self?.projectDetailsManager.isGeneratingDescription(for: project) ?? false
            },
            generateDescriptionHandler: { [weak self] project in
                self?.projectDetailsManager.generateDescription(for: project)
            },
        )

        runtimeSnapshotEffectHandlers = RuntimeSnapshotEffectHandlers.live(
            delegationLoopManager: delegationLoopManager,
            runCaptureCoordinator: runCaptureCoordinator,
            updatePostSessionRefreshContext: { [weak self] in
                self?.updatePostSessionRefreshContext()
            },
        )

        // Session-state and flashing changes now drive view re-render directly
        // via @Observable tracking of SessionStateManager.sessionStates /
        // .flashingProjects, so no manual revision-counter bridge is needed.
        terminalLauncher.onActivationResult = { [weak self] result in
            guard let self, !result.success else { return }
            uiState.toast = ToastMessage(
                result.failureReason?.userMessage ?? "Couldn't activate terminal.",
                isError: true,
            )
        }

        if featureState.isIdeaCaptureEnabled {
            loadCreations()
        }

        scheduleRuntimeBootstrap()
        loadOperatorViewState(openedAt: operatorViewOpenedAt)
    }

    deinit {
        refreshTimer?.invalidate()
        longPollTask?.cancel()
        runtimeBootstrapTask?.cancel()
        runtimeSnapshotTask?.cancel()
    }
}

extension AppState {
    func loadOperatorViewState(openedAt: Date = Date()) {
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                let previousSnapshot = try await operatorViewStateStore.load()
                operatorViewStateSnapshot = previousSnapshot
                try await operatorViewStateStore.recordAppOpened(at: openedAt)
            } catch {
                DebugLog.write("AppState.loadOperatorViewState failed error=\(error.localizedDescription)")
            }
        }
    }

    func markProjectCaseFileSeen(
        projectPath: String,
        runID: String?,
        checkpointIDs: [String],
        at date: Date = Date(),
    ) {
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                try await operatorViewStateStore.markProjectSeen(projectPath, at: date)
                if let runID {
                    try await operatorViewStateStore.markRunSeen(runID: runID, at: date)
                }
                for checkpointID in checkpointIDs {
                    try await operatorViewStateStore.markCheckpointSeen(checkpointID: checkpointID, at: date)
                }
            } catch {
                DebugLog.write("AppState.markProjectCaseFileSeen failed error=\(error.localizedDescription)")
            }
        }
    }
}
