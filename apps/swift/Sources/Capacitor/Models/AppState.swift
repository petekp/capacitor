import Foundation
import SwiftUI

enum LayoutMode: String, CaseIterable {
    case vertical
    case dock
}

enum AppFeatureError: LocalizedError {
    case ideaCaptureDisabled
    case projectDetailsDisabled
    case projectCreationDisabled

    var errorDescription: String? {
        switch self {
        case .ideaCaptureDisabled:
            "Idea capture is disabled for this build."
        case .projectDetailsDisabled:
            "Project details are disabled for this build."
        case .projectCreationDisabled:
            "Project creation is disabled for this build."
        }
    }
}

@Observable
@MainActor
class AppState {
    // MARK: - Layout Mode

    var layoutMode: LayoutMode = .vertical

    // MARK: - Build Channel + Feature Flags

    private(set) var channel: AppChannel = AppConfig.defaultChannel
    private(set) var featureFlags: FeatureFlags = .defaults(for: .stable)
    var isIdeaCaptureEnabled: Bool {
        featureFlags.ideaCapture
    }

    var isProjectDetailsEnabled: Bool {
        featureFlags.projectDetails
    }

    var isWorkstreamsEnabled: Bool {
        featureFlags.workstreams && isProjectDetailsEnabled
    }

    var isProjectCreationEnabled: Bool {
        featureFlags.projectCreation
    }

    var isLlmFeaturesEnabled: Bool {
        featureFlags.llmFeatures && isProjectDetailsEnabled
    }

    var isWindowAnchoringEnabled: Bool {
        featureFlags.windowAnchoring
    }

    // MARK: - UI State

    var error: String?
    var toast: ToastMessage?
    /// Set by card-level DropDelegates when a file URL drag hovers over a project card.
    /// Complements ContentView's `isDragHovered` (which only fires between cards).
    var isFileDragOverCard = false

    // MARK: - Activation Trace (Debug)

    var activationTrace: String?

    // MARK: - Runtime Diagnostic

    // MARK: - Modal State for Idea Capture

    var showCaptureModal = false
    var captureModalProject: ShellProjectReference?
    var captureModalOrigin: CGRect?

    // MARK: - Managers (extracted for cleaner architecture)

    let anchoringController = WindowAnchoringController()
    let shellStateStore = ShellStateStore()
    let sessionStateManager = SessionStateManager()
    let hookServerManager = HookServerManager()
    let projectDetailsManager = ProjectDetailsManager()
    private(set) var projectMutationService: ProjectMutationService!
    private(set) var projectActionState: ProjectActionState!
    private(set) var projectActivationCoordinator: ProjectActivationCoordinator!
    private(set) var projectImportCoordinator: ProjectImportCoordinator!
    private(set) var quickFeedbackWorkflow: QuickFeedbackWorkflow!
    private(set) var setupActionState: SetupActionState!
    private(set) var dashboardLoader: DashboardLoader!
    private(set) var projectCreationCoordinator: ProjectCreationCoordinator!
    private(set) var projectFeatureCoordinator: ProjectFeatureCoordinator!
    private(set) var dashboardState: DashboardState!
    @ObservationIgnored
    lazy var workstreamsManager: WorkstreamsManager = .init(
        openWorktree: { [weak self] worktreeProject in
            self?.projectActivationCoordinator.activate(worktreeProject)
        },
        activeWorktreePathsProvider: { [weak self] in
            self?.runtimeRefreshOrchestrator.activeWorktreePathsForGuardrails() ?? []
        },
    )

    private(set) var activeProjectTrackingState: ActiveProjectTrackingState!
    let navigationState: NavigationState
    let projectWorkflowState: ProjectWorkflowState
    let projectListState: ProjectListState
    private(set) var projectStatusCacheState: ProjectStatusCacheState!
    let runtimeSupervisor: RuntimeSupervisor
    private(set) var runtimeHealthState: RuntimeHealthState!
    private(set) var runtimeRefreshOrchestrator: RuntimeRefreshOrchestrator!
    private(set) var runtimeAutomationController: RuntimeAutomationController!
    private(set) var runtimeSessionRefreshController: RuntimeSessionRefreshController!
    let setupSupervisor: SetupSupervisor

    // MARK: - Private State

    private var engine: CoreRuntime?
    private(set) var sessionStateRevision = 0

    init(
        dependencies: AppStateDependencies,
    ) {
        navigationState = dependencies.navigationState
        projectWorkflowState = dependencies.projectWorkflowState
        projectListState = dependencies.projectListState
        runtimeSupervisor = dependencies.runtimeSupervisor
        setupSupervisor = dependencies.setupSupervisor
        DebugLog.write(
            "AppState.init start runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        configureCollaborators(
            projectMutationGateway: dependencies.projectMutationGateway,
            runtimeSupervisor: dependencies.runtimeSupervisor,
            setupSupervisor: dependencies.setupSupervisor,
            activateProjectTerminal: dependencies.activateProjectTerminal,
        )
        if let runtimeAutomationController = dependencies.runtimeAutomationController {
            self.runtimeAutomationController = runtimeAutomationController
        }
    }

    private static func makeUnavailableActivateProjectTerminal() -> ActivateProjectTerminalUseCase {
        ActivateProjectTerminalUseCase(activationGateway: UnavailableActivationGateway())
    }

    /// This self-wiring stays local because these collaborators read and write AppState-owned
    /// UI/composition state; live adapter selection remains in AppShellContainer.
    private func configureCollaborators(
        projectMutationGateway: any ProjectMutationGateway,
        runtimeSupervisor _: RuntimeSupervisor,
        setupSupervisor _: SetupSupervisor,
        activateProjectTerminal: ActivateProjectTerminalUseCase? = nil,
    ) {
        DebugLog.write(
            "AppState.init configureCollaborators runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        let config = AppConfig.current()
        #if DEBUG
            AlphaChannelGuardrail.enforceOrExit(channel: config.channel)
        #endif
        channel = config.channel
        DebugLog.write("AppState.init config channel=\(channel.rawValue)")
        featureFlags = config.featureFlags

        runtimeHealthState = RuntimeHealthState(runtimeSupervisor: runtimeSupervisor)
        projectStatusCacheState = ProjectStatusCacheState()
        activeProjectTrackingState = ActiveProjectTrackingState(
            sessionStateManager: sessionStateManager,
        )
        projectActivationCoordinator = ProjectActivationCoordinator(
            activeProjectTrackingState: activeProjectTrackingState,
            activateProjectTerminal: activateProjectTerminal ?? Self.makeUnavailableActivateProjectTerminal(),
        )
        quickFeedbackWorkflow = QuickFeedbackWorkflow(
            contextProvider: { [weak self] in
                guard let self else { return QuickFeedbackContext.empty }
                return QuickFeedbackContextBuilder.make(
                    channel: channel,
                    runtimeStatus: runtimeHealthState.status,
                    activeProjectPath: activeProjectTrackingState.activeProjectPath,
                    activeSource: activeProjectTrackingState.activeSource,
                    projectCount: projectWorkflowState.projectCatalog.count,
                    sessionStates: sessionStateManager.sessionStates,
                    activationTrace: activationTrace,
                )
            },
            writeToast: { [weak self] in
                self?.toast = $0
            },
        )
        projectImportCoordinator = ProjectImportCoordinator(
            connectSingleProject: { [weak self] path in
                self?.projectActionState.connectProjectSelection(path: path)
            },
            importProjects: { [weak self] urls in
                guard let self else { return }
                await projectActionState.importProjects(from: urls)
            },
            ensureProjectListVisible: { [weak self] in
                guard let self, navigationState.destination != .projectList else { return }
                projectFeatureCoordinator.showProjectList()
            },
        )
        projectMutationService = ProjectMutationService(
            projectMutationGateway: projectMutationGateway,
            projectWorkflowState: projectWorkflowState,
            projectListState: projectListState,
            reloadDashboard: { [weak self] hydrateIdeas, showLoadingState in
                guard let self else { return }
                if !hydrateIdeas, !showLoadingState {
                    var fastSwapTransaction = Transaction(animation: nil)
                    fastSwapTransaction.disablesAnimations = true
                    withTransaction(fastSwapTransaction) {
                        self.dashboardState.load(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState)
                    }
                } else {
                    dashboardState.load(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState)
                }
            },
            scheduleDeferredIdeaHydration: { [weak self] in
                self?.scheduleDeferredIdeaHydration()
            },
        )
        projectActionState = ProjectActionState(
            projectMutationService: projectMutationService,
            isRuntimeAvailable: { [weak self] in
                self?.engine != nil
            },
            writeToast: { [weak self] in
                self?.toast = $0
            },
            writeError: { [weak self] in
                self?.error = $0
            },
            moveTrackedProjectToRecent: { [weak self] path in
                guard let self else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    self.projectMutationService.moveTrackedProjectToRecent(path: path)
                }
            },
            recoverTrackedProjects: { [weak self] paths in
                guard let self else {
                    return ProjectMutationService.RecoveredTrackedProjectsOutcome(
                        movedPaths: [],
                        alreadyInProgressCount: 0,
                    )
                }
                return withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    self.projectMutationService.recoverTrackedProjects(paths: paths)
                }
            },
        )
        setupActionState = SetupActionState(
            setupSupervisor: setupSupervisor,
            isRuntimeAvailable: { [weak self] in
                self?.engine != nil
            },
            writeToast: { [weak self] in
                self?.toast = $0
            },
            refreshSessionStates: { [weak self] in
                self?.runtimeRefreshOrchestrator.refreshSessionStates(engine: self?.engine)
            },
        )
        runtimeSessionRefreshController = RuntimeSessionRefreshController(
            runtimeSupervisor: runtimeSupervisor,
            sessionStateManager: sessionStateManager,
            shellStateStore: shellStateStore,
            didUpdateContext: { [weak self] in
                self?.runtimeRefreshOrchestrator.handlePostSessionUpdate()
            },
        )
        runtimeRefreshOrchestrator = RuntimeRefreshOrchestrator(
            projectStatusCacheState: projectStatusCacheState,
            runtimeSessionRefreshController: runtimeSessionRefreshController,
            activeProjectTrackingState: activeProjectTrackingState,
            projectListState: projectListState,
            sessionStateManager: sessionStateManager,
            projectsProvider: { [weak self] in
                self?.projectWorkflowState.projectCatalog.map(\.shellProjectReference) ?? []
            },
        )
        if runtimeAutomationController == nil {
            runtimeAutomationController = RuntimeAutomationComposer.makeController(
                writeEngine: { [weak self] in
                    self?.engine = $0
                },
                ensureRuntimeReady: { [weak self] in
                    self?.runtimeHealthState.ensureRuntimeReady()
                },
                configureProjectDetails: { [weak self] in
                    self?.projectDetailsManager.configure(engine: $0)
                },
                reloadDashboardAfterBootstrap: { [weak self] in
                    self?.dashboardState.load()
                },
                refreshSetupDiagnosticsAfterBootstrap: { [weak self] in
                    self?.setupActionState.refreshHookDiagnostic()
                },
                startHookServer: { [weak self] in
                    self?.hookServerManager.startIfNeeded()
                },
                startRefreshLoop: { [weak self] in
                    self?.runtimeAutomationController.startRefreshLoop()
                },
                startShellTracking: { [weak self] in
                    guard let self else { return }
                    activeProjectTrackingState.updateProjects(projectWorkflowState.projectCatalog)
                },
                writeError: { [weak self] in
                    self?.error = $0
                },
                writeIsLoading: { [weak self] in
                    self?.dashboardState.setLoading($0)
                },
                refreshSessionStates: { [weak self] in
                    self?.runtimeRefreshOrchestrator.refreshSessionStates(engine: self?.engine)
                },
                ideaCaptureEnabled: { [weak self] in
                    self?.isIdeaCaptureEnabled ?? false
                },
                checkIdeasFileChanges: { [weak self] in
                    guard let self else { return }
                    projectFeatureCoordinator.checkIdeasFileChanges(for: projectWorkflowState.projectCatalog)
                },
                refreshSetupDiagnostics: { [weak self] in
                    self?.setupActionState.refreshHookDiagnostic()
                },
                checkHookServerHealth: { [weak self] in
                    self?.hookServerManager.checkHealth()
                },
                refreshRuntimeHealth: { [weak self] in
                    self?.runtimeHealthState.refresh()
                },
                reloadDashboardOnInterval: { [weak self] in
                    self?.dashboardState.load()
                },
            )
        }
        projectCreationCoordinator = ProjectCreationCoordinator(
            ideaCaptureEnabled: { [weak self] in
                self?.isIdeaCaptureEnabled ?? false
            },
            registerCreatedProject: { [weak self] path in
                guard let self else { return }
                try projectMutationService.registerCreatedProject(path: path)
            },
            dashboardReloader: { [weak self] in
                self?.dashboardState.load()
            },
        )
        dashboardLoader = DashboardLoader(
            loadDashboardData: { [weak self] in
                guard let self, let engine else {
                    throw NSError(domain: "Capacitor", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Engine not initialized",
                    ])
                }
                return try engine.loadDashboard()
            },
            projectWorkflowState: projectWorkflowState,
            updateActiveProjects: { [weak self] in
                self?.activeProjectTrackingState.updateProjects($0)
            },
            refreshRuntimeSessions: { [weak self] in
                self?.runtimeRefreshOrchestrator.refreshSessionStates(engine: self?.engine)
            },
            loadIdeas: { [weak self] in
                self?.projectDetailsManager.loadAllIdeas(for: $0)
            },
            refreshSuggestedProjects: { [weak self] in
                self?.projectWorkflowState.refreshSuggestedProjects()
            },
        )
        dashboardState = DashboardState(
            dashboardLoader: dashboardLoader,
            ideaCaptureEnabled: { [weak self] in
                self?.isIdeaCaptureEnabled ?? false
            },
            writeError: { [weak self] in
                self?.error = $0
            },
        )
        projectFeatureCoordinator = ProjectFeatureCoordinator(
            projectDetailsEnabled: { [weak self] in
                self?.isProjectDetailsEnabled ?? false
            },
            ideaCaptureEnabled: { [weak self] in
                self?.isIdeaCaptureEnabled ?? false
            },
            projectCreationEnabled: { [weak self] in
                self?.isProjectCreationEnabled ?? false
            },
            llmFeaturesEnabled: { [weak self] in
                self?.isLlmFeaturesEnabled ?? false
            },
            writeNavigationDestination: { [weak self] destination in
                switch destination {
                case .projectList:
                    self?.navigationState.showProjectList()
                case let .projectDetail(projectID):
                    self?.navigationState.showProjectDetail(
                        ShellProjectReference(
                            id: projectID,
                            displayName: projectID,
                            path: projectID,
                        ),
                    )
                case .newIdea:
                    self?.navigationState.showNewIdea()
                case .setup:
                    self?.navigationState.showSetup()
                }
            },
            writeCaptureModalProject: { [weak self] in
                self?.captureModalProject = $0
            },
            writeCaptureModalOrigin: { [weak self] in
                self?.captureModalOrigin = $0
            },
            writeShowCaptureModal: { [weak self] in
                self?.showCaptureModal = $0
            },
            writeError: { [weak self] in
                self?.error = $0
            },
            captureIdeaHandler: { [weak self] project, text in
                self?.projectDetailsManager.captureIdea(for: project, text: text) ?? .failure(AppFeatureError.ideaCaptureDisabled)
            },
            checkIdeasFileChangesHandler: { [weak self] projects in
                self?.projectDetailsManager.checkIdeasFileChanges(for: projects)
            },
            getIdeasHandler: { [weak self] project in
                self?.projectDetailsManager.getIdeas(for: project) ?? []
            },
            isGeneratingTitleHandler: { [weak self] ideaId in
                self?.projectDetailsManager.isGeneratingTitle(for: ideaId) ?? false
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
            createProjectFromIdeaHandler: { [weak self] request, completion in
                self?.projectCreationCoordinator.createProjectFromIdea(request, completion: completion)
            },
        )
        sessionStateManager.onVisualStateChanged = { [weak self] in
            guard let self else { return }
            sessionStateRevision &+= 1
        }

        if isIdeaCaptureEnabled {
            projectCreationCoordinator.loadCreations()
        }
        runtimeAutomationController.startBootstrap()
    }

    #if DEBUG
        func applyRuntimeSnapshotForTesting(
            _ snapshot: RuntimeSnapshot,
            refreshGeneration: UInt64,
            correlationId: String,
            projects: [some ProjectPathProviding],
        ) async {
            await runtimeSessionRefreshController.applyObservationForTesting(
                ShellRuntimeObservation(
                    projectStates: snapshot.projectStates,
                    sessions: snapshot.sessions,
                    shellState: snapshot.shellState,
                ),
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                projects: projects,
            )
        }

        func setRuntimeSnapshotGenerationForTesting(_ generation: UInt64) {
            runtimeSessionRefreshController.setGenerationForTesting(generation)
        }

        func handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: UInt64,
            correlationId: String,
            errorDescription: String,
        ) {
            runtimeSessionRefreshController.handleFailureForTesting(
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                errorDescription: errorDescription,
            )
        }

        func cancelRuntimeAutomationForTesting() {
            runtimeAutomationController.stopAutomation()
            runtimeSessionRefreshController.stop()
        }
    #endif

    private func scheduleDeferredIdeaHydration() {
        guard isIdeaCaptureEnabled else { return }

        _Concurrency.Task { [weak self] in
            guard let self else { return }

            // Yield one frame so connect-state -> list transition can complete first.
            await _Concurrency.Task.yield()
            guard isIdeaCaptureEnabled else { return }
            await projectDetailsManager.loadAllIdeasIncrementally(for: projectWorkflowState.projectCatalog)
        }
    }
}
