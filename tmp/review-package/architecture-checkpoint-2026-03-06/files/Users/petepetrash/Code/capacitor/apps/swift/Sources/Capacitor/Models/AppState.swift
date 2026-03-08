import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum LayoutMode: String, CaseIterable {
    case vertical
    case dock
}

enum ProjectView: Equatable {
    case list
    case detail(Project)
    case newIdea

    static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list), (.newIdea, .newIdea):
            true
        case let (.detail(p1), .detail(p2)):
            p1.path == p2.path
        default:
            false
        }
    }
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

    var layoutMode: LayoutMode = .vertical {
        didSet { saveLayoutMode() }
    }

    // MARK: - Build Channel + Feature Flags

    private(set) var channel: AppChannel = AppConfig.defaultChannel
    private(set) var profile: AppProfile = .stable
    private(set) var featureFlags: FeatureFlags = .defaults(for: .stable)
    private(set) var routingRollout: RuntimeRoutingRollout?

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

    // MARK: - Navigation

    var projectView: ProjectView = .list

    // MARK: - Data

    var dashboard: DashboardData?
    var projects: [Project] {
        get { projectWorkflowState.legacyProjects }
        set {
            projectWorkflowState.replaceProjectCatalog(
                with: ProjectCatalogBridge.projectCatalogEntries(from: newValue)
            )
        }
    }

    var suggestedProjects: [SuggestedProject] {
        get { projectWorkflowState.legacySuggestedProjects }
        set {
            projectWorkflowState.replaceSuggestedProjectCatalog(
                with: ProjectCatalogBridge.suggestedProjectCandidates(from: newValue)
            )
        }
    }

    // MARK: - Active project creations (Idea → V1)

    var activeCreations: [ProjectCreation] = []

    // MARK: - Cached Project Statuses (avoids FFI call per card per render)

    private(set) var projectStatuses: [String: ProjectStatus] = [:]

    // MARK: - UI State

    var isLoading = true
    var error: String?
    var toast: ToastMessage?
    /// Set by card-level DropDelegates when a file URL drag hovers over a project card.
    /// Complements ContentView's `isDragHovered` (which only fires between cards).
    var isFileDragOverCard = false

    // MARK: - Activation Trace (Debug)

    var activationTrace: String?

    // MARK: - Runtime Diagnostic

    var runtimeStatus: RuntimeStatus?

    // MARK: - Modal State for Idea Capture

    var showCaptureModal = false
    var captureModalProject: Project?
    var captureModalOrigin: CGRect?

    // MARK: - Managers (extracted for cleaner architecture)

    let anchoringController = WindowAnchoringController()
    let shellStateStore = ShellStateStore()
    let terminalLauncher = TerminalLauncher()
    let sessionStateManager = SessionStateManager()
    let hookServerManager = HookServerManager()
    let projectDetailsManager = ProjectDetailsManager()
    private(set) var projectMutationService: ProjectMutationService!
    private(set) var projectActionState: ProjectActionState!
    private(set) var setupActionState: SetupActionState!
    private(set) var projectCreationCoordinator: ProjectCreationCoordinator!
    private(set) var projectFeatureCoordinator: ProjectFeatureCoordinator!
    @ObservationIgnored
    lazy var workstreamsManager: WorkstreamsManager = .init(
        openWorktree: { [weak self] worktreeProject in
            self?.launchTerminal(for: worktreeProject)
        },
        activeWorktreePathsProvider: { [weak self] in
            self?.activeWorktreePathsForGuardrails() ?? []
        },
    )

    private(set) var activeProjectResolver: ActiveProjectResolver!
    let navigationState: NavigationState
    let projectWorkflowState: ProjectWorkflowState
    let projectListState: ProjectListState
    let runtimeSupervisor: RuntimeSupervisor
    private(set) var runtimeAutomationController: RuntimeAutomationController!
    let setupSupervisor: SetupSupervisor

    // MARK: - Private State

    private let layoutModeKey = "layoutMode"
    private var engine: CoreRuntime?
    private var runtimeSnapshotTask: _Concurrency.Task<Void, Never>?
    private var runtimeSnapshotGeneration: UInt64 = 0
    private var runtimeSnapshotCorrelationCounter: UInt64 = 0
    private var consecutiveRuntimeSnapshotFailures = 0
    private(set) var sessionStateRevision = 0
    private(set) var didAttemptRuntimeHealthCheckForTesting = false
    private(set) var didStartShellTrackingForTesting = false

    // MARK: - Computed Properties (bridging to managers)

    var activeProjectPath: String? {
        activeProjectResolver?.activeProject?.path
    }

    var activeSource: ActiveSource {
        activeProjectResolver?.activeSource ?? .none
    }

    // MARK: - Initialization

    init() {
        let projectMutationGateway = Self.makeLiveProjectMutationGateway()
        self.navigationState = NavigationState()
        self.projectWorkflowState = Self.makeLiveProjectWorkflowState()
        self.projectListState = Self.makeLiveProjectListState()
        self.runtimeSupervisor = Self.makeLiveRuntimeSupervisor()
        self.setupSupervisor = Self.makeLiveSetupSupervisor()
        DebugLog.write(
            "AppState.init start runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        commonInit(
            projectMutationGateway: projectMutationGateway,
            runtimeSupervisor: runtimeSupervisor,
            setupSupervisor: setupSupervisor
        )
    }

    init(navigationState: NavigationState) {
        let projectMutationGateway = Self.makeLiveProjectMutationGateway()
        self.navigationState = navigationState
        self.projectWorkflowState = Self.makeLiveProjectWorkflowState()
        self.projectListState = Self.makeLiveProjectListState()
        self.runtimeSupervisor = Self.makeLiveRuntimeSupervisor()
        self.setupSupervisor = Self.makeLiveSetupSupervisor()
        DebugLog.write(
            "AppState.init start runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        commonInit(
            projectMutationGateway: projectMutationGateway,
            runtimeSupervisor: runtimeSupervisor,
            setupSupervisor: setupSupervisor
        )
    }

    init(navigationState: NavigationState, projectWorkflowState: ProjectWorkflowState) {
        let projectMutationGateway = Self.makeLiveProjectMutationGateway()
        self.navigationState = navigationState
        self.projectWorkflowState = projectWorkflowState
        self.projectListState = Self.makeLiveProjectListState()
        self.runtimeSupervisor = Self.makeLiveRuntimeSupervisor()
        self.setupSupervisor = Self.makeLiveSetupSupervisor()
        DebugLog.write(
            "AppState.init start runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        commonInit(
            projectMutationGateway: projectMutationGateway,
            runtimeSupervisor: runtimeSupervisor,
            setupSupervisor: setupSupervisor
        )
    }

    init(
        navigationState: NavigationState,
        projectWorkflowState: ProjectWorkflowState,
        projectListState: ProjectListState
    ) {
        let projectMutationGateway = Self.makeLiveProjectMutationGateway()
        self.navigationState = navigationState
        self.projectWorkflowState = projectWorkflowState
        self.projectListState = projectListState
        self.runtimeSupervisor = Self.makeLiveRuntimeSupervisor()
        self.setupSupervisor = Self.makeLiveSetupSupervisor()
        DebugLog.write(
            "AppState.init start runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        commonInit(
            projectMutationGateway: projectMutationGateway,
            runtimeSupervisor: runtimeSupervisor,
            setupSupervisor: setupSupervisor
        )
    }

    init(
        navigationState: NavigationState,
        projectWorkflowState: ProjectWorkflowState,
        projectListState: ProjectListState,
        projectMutationGateway: any ProjectMutationGateway
    ) {
        self.navigationState = navigationState
        self.projectWorkflowState = projectWorkflowState
        self.projectListState = projectListState
        self.runtimeSupervisor = Self.makeLiveRuntimeSupervisor()
        self.setupSupervisor = Self.makeLiveSetupSupervisor()
        DebugLog.write(
            "AppState.init start runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        commonInit(
            projectMutationGateway: projectMutationGateway,
            runtimeSupervisor: runtimeSupervisor,
            setupSupervisor: setupSupervisor
        )
    }

    init(
        navigationState: NavigationState,
        projectWorkflowState: ProjectWorkflowState,
        projectListState: ProjectListState,
        projectMutationGateway: any ProjectMutationGateway,
        runtimeSupervisor: RuntimeSupervisor,
        setupSupervisor: SetupSupervisor,
        runtimeAutomationController: RuntimeAutomationController? = nil
    ) {
        self.navigationState = navigationState
        self.projectWorkflowState = projectWorkflowState
        self.projectListState = projectListState
        self.runtimeSupervisor = runtimeSupervisor
        self.setupSupervisor = setupSupervisor
        DebugLog.write(
            "AppState.init start runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        commonInit(
            projectMutationGateway: projectMutationGateway,
            runtimeSupervisor: runtimeSupervisor,
            setupSupervisor: setupSupervisor
        )
        if let runtimeAutomationController {
            self.runtimeAutomationController = runtimeAutomationController
        }
    }

    private static func makeLiveProjectWorkflowState() -> ProjectWorkflowState {
        ProjectWorkflowState(projectCatalogGateway: LiveProjectCatalogGateway())
    }

    private static func makeLiveProjectListState() -> ProjectListState {
        ProjectListState(projectListPreferencesGateway: LiveProjectListPreferencesGateway())
    }

    private static func makeLiveProjectMutationGateway() -> any ProjectMutationGateway {
        LiveProjectMutationGateway()
    }

    private static func makeLiveRuntimeSupervisor() -> RuntimeSupervisor {
        RuntimeSupervisor(runtimeGateway: LiveRuntimeGateway())
    }

    private static func makeLiveSetupSupervisor() -> SetupSupervisor {
        SetupSupervisor(setupGateway: LiveSetupGateway())
    }

    private func commonInit(
        projectMutationGateway: any ProjectMutationGateway,
        runtimeSupervisor _: RuntimeSupervisor,
        setupSupervisor _: SetupSupervisor
    ) {
        DebugLog.write(
            "AppState.init commonInit runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        let config = AppConfig.current()
        #if DEBUG
            AlphaChannelGuardrail.enforceOrExit(channel: config.channel)
        #endif
        channel = config.channel
        profile = config.profile
        DebugLog.write("AppState.init config channel=\(channel.rawValue) profile=\(profile.rawValue)")
        featureFlags = config.featureFlags
        refreshAERoutingRuntimeFlags(with: nil)
        loadLayoutMode()

        activeProjectResolver = ActiveProjectResolver(
            sessionStateManager: sessionStateManager,
        )
        terminalLauncher.preferredTerminalAppResolver = { [weak self] clientTty, projectPath, sessionName in
            guard let shellState = self?.shellStateStore.state else {
                return nil
            }
            return TerminalLauncher.resolvePreferredTerminalApp(
                clientTty: clientTty,
                projectPath: projectPath,
                sessionName: sessionName,
                shellState: shellState,
            )
        }
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
                        self.loadDashboard(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState)
                    }
                } else {
                    self.loadDashboard(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState)
                }
            },
            scheduleDeferredIdeaHydration: { [weak self] in
                self?.scheduleDeferredIdeaHydration()
            }
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
                        alreadyInProgressCount: 0
                    )
                }
                return withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    self.projectMutationService.recoverTrackedProjects(paths: paths)
                }
            }
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
                self?.refreshSessionStates()
            }
        )
        if runtimeAutomationController == nil {
            var hookHealthCheckCounter = 0
            var hookServerHealthCounter = 0
            var statsRefreshCounter = 0
            var runtimeHealthCheckCounter = 0

            runtimeAutomationController = RuntimeAutomationController(
                bootstrapRuntime: { [weak self] in
                    guard let self else { return }
                    do {
                        guard !_Concurrency.Task.isCancelled else { return }
                        self.engine = try CoreRuntime()
                        guard !_Concurrency.Task.isCancelled else { return }

                        self.ensureRuntimeReady()
                        guard !_Concurrency.Task.isCancelled else { return }

                        self.projectDetailsManager.configure(engine: self.engine)
                        self.loadDashboard()
                        guard !_Concurrency.Task.isCancelled else { return }
                        self.setupActionState.refreshHookDiagnostic()
                        self.hookServerManager.startIfNeeded()
                        self.runtimeAutomationController.startRefreshLoop()
                        self.startShellTracking()
                    } catch {
                        self.error = error.localizedDescription
                        self.isLoading = false
                    }
                },
                onTimerTick: { [weak self] in
                    guard let self else { return }
                    self.refreshSessionStates()
                    if self.isIdeaCaptureEnabled {
                        self.projectFeatureCoordinator.checkIdeasFileChanges(for: self.projects)
                    }

                    hookHealthCheckCounter += 1
                    if hookHealthCheckCounter >= 5 {
                        hookHealthCheckCounter = 0
                        self.setupActionState.refreshHookDiagnostic()
                    }

                    hookServerHealthCounter += 1
                    if hookServerHealthCounter >= 5 {
                        hookServerHealthCounter = 0
                        self.hookServerManager.checkHealth()
                    }

                    runtimeHealthCheckCounter += 1
                    if runtimeHealthCheckCounter >= 8 {
                        runtimeHealthCheckCounter = 0
                        self.checkRuntimeHealth()
                    }

                    statsRefreshCounter += 1
                    if statsRefreshCounter >= 15 {
                        statsRefreshCounter = 0
                        self.loadDashboard()
                    }
                }
            )
        }
        projectCreationCoordinator = ProjectCreationCoordinator(
            ideaCaptureEnabled: { [weak self] in
                self?.isIdeaCaptureEnabled ?? false
            },
            readCreations: { [weak self] in
                self?.activeCreations ?? []
            },
            writeCreations: { [weak self] creations in
                self?.activeCreations = creations
            },
            registerCreatedProject: { [weak self] path in
                guard let self else { return }
                try self.projectMutationService.registerCreatedProject(path: path)
            },
            dashboardReloader: { [weak self] in
                self?.loadDashboard()
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
            writeProjectView: { [weak self] in
                self?.projectView = $0
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
                            path: projectID
                        )
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

        terminalLauncher.onActivationResult = { [weak self] result in
            guard let self else { return }
            if !result.success {
                toast = ToastMessage(
                    "Couldn’t activate Ghostty.",
                    isError: true,
                )
            }
        }

        if isIdeaCaptureEnabled {
            loadCreations()
        }
        runtimeAutomationController.startBootstrap()
    }

    private func startShellTracking() {
        didStartShellTrackingForTesting = true
        activeProjectResolver.updateProjects(projects)
    }

    // MARK: - Data Loading

    func loadDashboard(hydrateIdeas: Bool = true, showLoadingState: Bool = true) {
        guard let engine else { return }
        if showLoadingState {
            isLoading = true
        }

        do {
            dashboard = try engine.loadDashboard()
            projectWorkflowState.replaceProjectCatalog(
                with: ProjectCatalogBridge.projectCatalogEntries(from: dashboard?.projects ?? [])
            )
            if projects.isEmpty, suggestedProjects.isEmpty {
                refreshSuggestedProjects()
            } else if !projects.isEmpty, !suggestedProjects.isEmpty {
                projectWorkflowState.clearSuggestedProjects()
            }
            activeProjectResolver.updateProjects(projects)
            refreshSessionStates()
            if hydrateIdeas, isIdeaCaptureEnabled {
                projectDetailsManager.loadAllIdeas(for: projects)
            }
            if showLoadingState {
                isLoading = false
            }
        } catch {
            self.error = error.localizedDescription
            if showLoadingState {
                isLoading = false
            }
        }
    }

    func refreshSessionStates() {
        refreshProjectStatuses()
        runtimeSnapshotGeneration &+= 1
        let refreshGeneration = runtimeSnapshotGeneration
        let correlationId = nextRuntimeSnapshotCorrelationId()
        let currentProjects = projects
        runtimeSnapshotTask?.cancel()
        runtimeSnapshotTask = _Concurrency.Task { [weak self] in
            guard let self else { return }

            let observationResult = await runtimeSupervisor.refreshObservation(correlationId: correlationId)
            guard !_Concurrency.Task.isCancelled else { return }

            switch observationResult {
            case let .success(observation):
                await applyRuntimeObservationIfFresh(
                    observation,
                    refreshGeneration: refreshGeneration,
                    correlationId: correlationId,
                    projects: currentProjects,
                )
            case let .failure(error):
                await MainActor.run {
                    self.handleRuntimeSnapshotFailureIfFresh(
                        refreshGeneration: refreshGeneration,
                        correlationId: correlationId,
                        errorDescription: String(describing: error),
                    )
                }
            }
        }
    }

    @MainActor
    private func applySessionStateIfFresh(
        _ observation: ShellRuntimeObservation,
        refreshGeneration: UInt64,
        correlationId: String,
        projects: [Project],
    ) -> Bool {
        guard refreshGeneration == runtimeSnapshotGeneration else {
            DebugLog.write(
                "AppState.refreshSessionStates source=runtime_snapshot_drop_stale cid=\(correlationId) generation=\(refreshGeneration) current=\(runtimeSnapshotGeneration)",
            )
            return false
        }

        sessionStateManager.applyRuntimeProjectStates(
            observation.projectStates,
            for: projects,
            correlationId: correlationId,
        )
        consecutiveRuntimeSnapshotFailures = 0

        DebugLog.write(
            "AppState.refreshSessionStates source=runtime_snapshot_apply cid=\(correlationId) projects=\(observation.projectStates.count) sessions=\(observation.sessions.count) shells=\(observation.shellState.shells.count)",
        )
        updatePostSessionRefreshContext()
        return true
    }

    private func applyRuntimeObservationIfFresh(
        _ observation: ShellRuntimeObservation,
        refreshGeneration: UInt64,
        correlationId: String,
        projects: [Project],
    ) async {
        let shouldApply = await MainActor.run {
            applySessionStateIfFresh(
                observation,
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                projects: projects,
            )
        }

        guard shouldApply else { return }

        await shellStateStore.applyRuntimeShellState(
            observation.shellState,
            correlationId: correlationId,
        )
    }

    @MainActor
    private func handleRuntimeSnapshotFailureIfFresh(
        refreshGeneration: UInt64,
        correlationId: String,
        errorDescription: String,
    ) {
        guard refreshGeneration == runtimeSnapshotGeneration else {
            DebugLog.write(
                "AppState.refreshSessionStates source=runtime_snapshot_error_drop_stale cid=\(correlationId) generation=\(refreshGeneration) current=\(runtimeSnapshotGeneration)",
            )
            return
        }

        consecutiveRuntimeSnapshotFailures += 1
        DebugLog.write(
            "AppState.refreshSessionStates source=runtime_snapshot_error cid=\(correlationId) failures=\(consecutiveRuntimeSnapshotFailures) error=\(errorDescription)",
        )

        if consecutiveRuntimeSnapshotFailures >= 2 {
            DebugLog.write(
                "AppState.refreshSessionStates source=runtime_snapshot_error_clear cid=\(correlationId) failures=\(consecutiveRuntimeSnapshotFailures)",
            )
            sessionStateManager.clearRuntimeProjectStates()
            shellStateStore.clearRuntimeShellState(correlationId: correlationId)
        }

        updatePostSessionRefreshContext()
    }

    #if DEBUG
        func applyRuntimeSnapshotForTesting(
            _ snapshot: RuntimeSnapshot,
            refreshGeneration: UInt64,
            correlationId: String,
            projects: [Project],
        ) async {
            await applyRuntimeObservationIfFresh(
                ShellRuntimeObservation(
                    projectStates: snapshot.projectStates,
                    sessions: snapshot.sessions,
                    shellState: snapshot.shellState
                ),
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                projects: projects,
            )
        }

        func setRuntimeSnapshotGenerationForTesting(_ generation: UInt64) {
            runtimeSnapshotGeneration = generation
        }

        func handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: UInt64,
            correlationId: String,
            errorDescription: String,
        ) {
            handleRuntimeSnapshotFailureIfFresh(
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                errorDescription: errorDescription,
            )
        }

        func cancelRuntimeAutomationForTesting() {
            runtimeAutomationController.stopAutomation()
            runtimeSnapshotTask?.cancel()
            runtimeSnapshotTask = nil
        }
    #endif

    private func nextRuntimeSnapshotCorrelationId() -> String {
        runtimeSnapshotCorrelationCounter &+= 1
        return "app-snap-\(runtimeSnapshotCorrelationCounter)"
    }

    private func updatePostSessionRefreshContext() {
        activeProjectResolver.resolve()
        reconcileProjectGroups()
        DiagnosticsSnapshotLogger.updateContext(
            activeProjectPath: activeProjectPath,
            activeSource: activeSource,
        )
        DebugLog.write("AppState.refreshSessionStates activeProject=\(activeProjectResolver.activeProject?.path ?? "nil") source=\(String(describing: activeProjectResolver.activeSource))")
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
    }

    // MARK: - Runtime Diagnostic

    func ensureRuntimeReady() {
        didAttemptRuntimeHealthCheckForTesting = true
        // Hard cutover mode: runtime state is sourced from the core snapshot file.
        // No legacy launchd lifecycle orchestration remains in AppState.
        checkRuntimeHealth()
    }

    func checkRuntimeHealth() {
        _Concurrency.Task { [weak self] in
            let healthStatus = await self?.runtimeSupervisor.refreshHealthStatus()
            await MainActor.run {
                guard let self, let healthStatus else { return }
                self.runtimeStatus = RuntimeStatus(
                    isEnabled: healthStatus.isEnabled,
                    isHealthy: healthStatus.isHealthy,
                    message: healthStatus.message,
                    pid: healthStatus.pid,
                    version: healthStatus.version,
                )
                self.refreshAERoutingRuntimeFlags(with: healthStatus.routingRollout)

                if !healthStatus.isEnabled {
                    Telemetry.emit("runtime_health", "Runtime disabled", payload: [
                        "enabled": false,
                    ])
                } else if healthStatus.isHealthy {
                    Telemetry.emit("runtime_health", "Runtime healthy", payload: [
                        "enabled": true,
                        "healthy": true,
                        "pid": healthStatus.pid ?? -1,
                        "version": healthStatus.version ?? "unknown",
                    ])
                } else {
                    Telemetry.emit("runtime_health", "Runtime unhealthy", payload: [
                        "enabled": true,
                        "healthy": false,
                    ])
                }
            }
        }
    }

    // MARK: - Quick Feedback

    func submitQuickFeedback(
        _ draft: QuickFeedbackDraft,
        preferences overridePreferences: QuickFeedbackPreferences? = nil,
        formSessionID: String? = nil,
        openGitHubIssue: Bool = true,
    ) {
        let normalizedDraft = draft.normalized()
        let preferences = overridePreferences ?? QuickFeedbackPreferences.load()
        let context = quickFeedbackContext()
        let submitter = QuickFeedbackSubmitter(
            openURL: { url in
                NSWorkspace.shared.open(url)
            },
            sendRequest: { request in
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(httpResponse.statusCode)
                {
                    throw URLError(.badServerResponse)
                }
            },
        )

        _Concurrency.Task { [weak self] in
            let outcome = await submitter.submit(
                draft: normalizedDraft,
                context: context,
                preferences: preferences,
                openGitHubIssue: openGitHubIssue,
            )

            await MainActor.run {
                guard let self else { return }

                if openGitHubIssue {
                    if outcome.issueOpened {
                        if outcome.endpointAttempted, outcome.endpointSucceeded {
                            self.toast = ToastMessage("Opened GitHub issue and sent telemetry")
                        } else if outcome.endpointAttempted {
                            self.toast = ToastMessage("Opened GitHub issue (endpoint send failed)")
                        } else {
                            self.toast = ToastMessage("Opened GitHub issue")
                        }
                    } else {
                        self.toast = .error("Couldn’t open GitHub issue")
                    }
                } else {
                    if outcome.endpointAttempted, outcome.endpointSucceeded {
                        self.toast = ToastMessage("Shared feedback")
                    } else if outcome.endpointAttempted {
                        self.toast = .error("Couldn’t share feedback")
                    } else {
                        self.toast = .error("Couldn’t share feedback (no endpoint configured)")
                    }
                }

                Telemetry.emit("quick_feedback_submitted", "Quick feedback submitted", payload: [
                    "feedback_id": outcome.feedbackID,
                    "issue_requested": openGitHubIssue,
                    "issue_opened": outcome.issueOpened,
                    "endpoint_attempted": outcome.endpointAttempted,
                    "endpoint_succeeded": outcome.endpointSucceeded,
                    "category": normalizedDraft.category.rawValue,
                    "impact": normalizedDraft.impact.rawValue,
                    "reproducibility": normalizedDraft.reproducibility.rawValue,
                    "completion_count": normalizedDraft.completionCount,
                    "telemetry_enabled": preferences.includeTelemetry,
                    "project_paths_enabled": preferences.includeProjectPaths,
                    "session_count": context.sessionStates.count,
                    "project_count": context.projectCount,
                    "active_source": context.activeSource,
                ])

                QuickFeedbackFunnel.emitSubmitResult(
                    sessionID: formSessionID,
                    feedbackID: outcome.feedbackID,
                    draft: normalizedDraft,
                    preferences: preferences,
                    issueRequested: openGitHubIssue,
                    issueOpened: outcome.issueOpened,
                    endpointAttempted: outcome.endpointAttempted,
                    endpointSucceeded: outcome.endpointSucceeded,
                )
            }
        }
    }

    func submitQuickFeedback(
        _ message: String,
        preferences overridePreferences: QuickFeedbackPreferences? = nil,
    ) {
        submitQuickFeedback(
            QuickFeedbackDraft.legacy(message: message),
            preferences: overridePreferences,
            formSessionID: nil,
            openGitHubIssue: true,
        )
    }

    private func refreshAERoutingRuntimeFlags(with rollout: RuntimeRoutingRollout?) {
        routingRollout = rollout
    }

    private func quickFeedbackContext() -> QuickFeedbackContext {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "unknown"

        return QuickFeedbackContext(
            appVersion: appVersion,
            buildNumber: buildNumber,
            channel: channel,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            runtimeStatus: runtimeStatus,
            activeProjectPath: activeProjectPath,
            activeSource: String(describing: activeSource),
            projectCount: projects.count,
            sessionStates: sessionStateManager.sessionStates,
            activationTrace: activationTrace,
        )
    }

    // MARK: - Project Management

    func refreshSuggestedProjects() {
        projectWorkflowState.refreshSuggestedProjects()
        if let lastError = projectWorkflowState.lastError {
            DebugLog.write("AppState.refreshSuggestedProjects error=\(lastError.localizedDescription)")
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
            _Concurrency.Task { [weak self] in
                guard let self else { return }
                    await self.projectActionState.importProjects(
                        from: urls,
                        ensureProjectListVisible: { [weak self] in
                            guard let self else { return }
                            if self.projectView != .list {
                                self.projectFeatureCoordinator.showProjectList()
                            }
                        }
                    )
            }
            return
        }

        guard let url = urls.first else { return }
        projectActionState.connectProjectSelection(path: url.path)
    }

    /// Extracts file URLs from drop providers and forwards to `addProjectsFromDrop`.
    /// Used by card-level DropDelegates to handle external file drags that land on project cards.
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
                _Concurrency.Task { [weak self] in
                    guard let self else { return }
                    await self.projectActionState.importProjects(
                        from: urls,
                        ensureProjectListVisible: { [weak self] in
                            guard let self else { return }
                            if self.projectView != .list {
                                self.projectFeatureCoordinator.showProjectList()
                            }
                        }
                    )
                }
            }
        }
    }

    private func collectDroppedFileURLs(
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

    private func scheduleDeferredIdeaHydration() {
        guard isIdeaCaptureEnabled else { return }

        _Concurrency.Task { [weak self] in
            guard let self else { return }

            // Yield one frame so connect-state -> list transition can complete first.
            await _Concurrency.Task.yield()
            guard isIdeaCaptureEnabled else { return }
            await projectDetailsManager.loadAllIdeasIncrementally(for: projects)
        }
    }

    // MARK: - Session State Access (delegating to manager)

    func getSessionState(for project: Project) -> ProjectSessionState? {
        _ = sessionStateRevision
        return sessionStateManager.getSessionState(for: project)
    }

    func isFlashing(_ project: Project) -> SessionState? {
        _ = sessionStateRevision
        return sessionStateManager.isFlashing(project)
    }

    func getProjectStatus(for project: Project) -> ProjectStatus? {
        projectStatuses[project.path]
    }

    /// Batch-refresh project statuses from the Rust engine.
    /// Called on the 2-second timer alongside session state refresh.
    /// Replaces per-card FFI calls with a single batch update.
    private func refreshProjectStatuses() {
        guard let engine else { return }
        var updated: [String: ProjectStatus] = [:]
        for project in projects {
            if let status = engine.getProjectStatus(projectPath: project.path) {
                updated[project.path] = status
            }
        }
        if updated != projectStatuses {
            projectStatuses = updated
        }
    }

    // MARK: - Terminal Operations

    func launchTerminal(for project: Project) {
        activeProjectResolver.setManualOverride(project)
        activeProjectResolver.resolve()
        terminalLauncher.launchTerminal(for: project)
    }

    private func activeWorktreePathsForGuardrails() -> Set<String> {
        var paths: Set<String> = []

        for (projectPath, state) in sessionStateManager.sessionStates where state.state == .working {
            paths.insert(PathNormalizer.normalize(projectPath))
        }

        if let activePath = activeProjectPath {
            paths.insert(PathNormalizer.normalize(activePath))
        }

        return paths
    }

    // MARK: - Layout Mode Persistence

    private func loadLayoutMode() {
        if let rawValue = UserDefaults.standard.string(forKey: layoutModeKey),
           let mode = LayoutMode(rawValue: rawValue)
        {
            layoutMode = mode
        }
    }

    private func saveLayoutMode() {
        UserDefaults.standard.set(layoutMode.rawValue, forKey: layoutModeKey)
    }

    // MARK: - Activity Group Reconciliation

    /// Tracks activity transitions and keeps persisted global order clean.
    private func reconcileProjectGroups() {
        projectListState.reconcileProjectGroups(
            projects: projects,
            sessionStates: sessionStateManager.sessionStates,
        )
    }

    // MARK: - Project Creation

    private func loadCreations() {
        projectCreationCoordinator.loadCreations()
    }

    #if DEBUG
        func applyDiscoveredSessionToCreationForTesting(_ creationId: String, sessionId: String) -> Bool {
            projectCreationCoordinator.applyDiscoveredSessionToCreationForTesting(creationId, sessionId: sessionId)
        }

        func setCreationMonitorTasksForTesting(
            creationId: String,
            sessionTask: _Concurrency.Task<Void, Never>?,
            completionTask: _Concurrency.Task<Void, Never>?,
        ) {
            projectCreationCoordinator.setCreationMonitorTasksForTesting(
                creationId: creationId,
                sessionTask: sessionTask,
                completionTask: completionTask,
            )
        }

        func hasCreationMonitorTasksForTesting(creationId: String) -> Bool {
            projectCreationCoordinator.hasCreationMonitorTasksForTesting(creationId: creationId)
        }
    #endif

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
