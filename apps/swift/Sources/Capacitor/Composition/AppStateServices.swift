import Foundation
import SwiftUI

@MainActor
struct AppStateServices {
    let anchoringController: WindowAnchoringController
    let shellStateStore: ShellStateStore
    let sessionStateManager: SessionStateManager
    let hookServerManager: HookServerManager
    let projectDetailsManager: ProjectDetailsManager
    let projectMutationService: ProjectMutationService
    let projectActionState: ProjectActionState
    let projectActivationCoordinator: ProjectActivationCoordinator
    let projectImportCoordinator: ProjectImportCoordinator
    let quickFeedbackWorkflow: QuickFeedbackWorkflow
    let setupActionState: SetupActionState
    let dashboardLoader: DashboardLoader
    let projectCreationCoordinator: ProjectCreationCoordinator
    let projectPresentationState: ProjectPresentationState
    let dashboardState: DashboardState
    let workstreamsManager: WorkstreamsManager
    let activeProjectTrackingState: ActiveProjectTrackingState
    let projectStatusCacheState: ProjectStatusCacheState
    let runtimeHealthState: RuntimeHealthState
    let runtimeRefreshOrchestrator: RuntimeRefreshOrchestrator
    let runtimeAutomationController: RuntimeAutomationController
    let runtimeSessionRefreshController: RuntimeSessionRefreshController
}

@MainActor
enum AppStateServiceAssembler {
    static func makeServices(
        appState: AppState,
        projectMutationGateway: any ProjectMutationGateway,
        runtimeSupervisor: RuntimeSupervisor,
        setupSupervisor: SetupSupervisor,
        activateProjectTerminal: ActivateProjectTerminalUseCase? = nil,
        runtimeAutomationController: RuntimeAutomationController? = nil,
    ) -> AppStateServices {
        let anchoringController = WindowAnchoringController()
        let shellStateStore = ShellStateStore()
        let sessionStateManager = SessionStateManager()
        let hookServerManager = HookServerManager()
        let projectDetailsManager = ProjectDetailsManager()
        let projectStatusCacheState = ProjectStatusCacheState()
        let activeProjectTrackingState = ActiveProjectTrackingState(projectSessionReader: sessionStateManager)
        let runtimeHealthState = RuntimeHealthState(runtimeSupervisor: runtimeSupervisor)
        let projectActivationCoordinator = ProjectActivationCoordinator(
            activeProjectTrackingState: activeProjectTrackingState,
            activateProjectTerminal: activateProjectTerminal ?? makeUnavailableActivateProjectTerminal(),
        )

        var dashboardState: DashboardState!
        var projectActionState: ProjectActionState!
        var projectCreationCoordinator: ProjectCreationCoordinator!
        var projectPresentationState: ProjectPresentationState!
        var runtimeRefreshOrchestrator: RuntimeRefreshOrchestrator!
        var runtimeSessionRefreshController: RuntimeSessionRefreshController!
        var runtimeAutomationControllerValue: RuntimeAutomationController!
        var projectMutationService: ProjectMutationService!

        let quickFeedbackWorkflow = QuickFeedbackWorkflow(
            contextProvider: { [weak appState] in
                guard let appState else { return QuickFeedbackContext.empty }
                return QuickFeedbackContextBuilder.make(
                    channel: appState.channel,
                    runtimeStatus: runtimeHealthState.status,
                    activeProjectPath: activeProjectTrackingState.activeProjectPath,
                    activeSource: activeProjectTrackingState.activeSource,
                    projectCount: appState.projectWorkflowState.projectCatalog.count,
                    sessionStates: sessionStateManager.sessionStates,
                    activationTrace: appState.activationTrace,
                )
            },
            writeToast: { [weak appState] in
                appState?.toast = $0
            },
        )

        projectMutationService = ProjectMutationService(
            projectMutationGateway: projectMutationGateway,
            projectWorkflowState: appState.projectWorkflowState,
            projectListState: appState.projectListState,
            reloadDashboard: { [weak appState] hydrateIdeas, showLoadingState in
                guard appState != nil else { return }
                if !hydrateIdeas, !showLoadingState {
                    var fastSwapTransaction = Transaction(animation: nil)
                    fastSwapTransaction.disablesAnimations = true
                    withTransaction(fastSwapTransaction) {
                        dashboardState.load(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState)
                    }
                } else {
                    dashboardState.load(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState)
                }
            },
            scheduleDeferredIdeaHydration: { [weak appState] in
                appState?.scheduleDeferredIdeaHydration()
            },
        )

        projectActionState = ProjectActionState(
            projectMutationService: projectMutationService,
            isRuntimeAvailable: { [weak appState] in
                appState?.isRuntimeAvailable ?? false
            },
            writeToast: { [weak appState] in
                appState?.toast = $0
            },
            writeError: { [weak appState] in
                appState?.error = $0
            },
            moveTrackedProjectToRecent: { [weak appState] path in
                guard appState != nil else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    projectMutationService.moveTrackedProjectToRecent(path: path)
                }
            },
            recoverTrackedProjects: { [weak appState] paths in
                guard appState != nil else {
                    return ProjectMutationService.RecoveredTrackedProjectsOutcome(
                        movedPaths: [],
                        alreadyInProgressCount: 0,
                    )
                }
                return withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    projectMutationService.recoverTrackedProjects(paths: paths)
                }
            },
        )

        let projectImportCoordinator = ProjectImportCoordinator(
            connectSingleProject: { path in
                projectActionState.connectProjectSelection(path: path)
            },
            importProjects: { urls in
                await projectActionState.importProjects(from: urls)
            },
            ensureProjectListVisible: {
                guard appState.navigationState.destination != .projectList else { return }
                appState.navigationState.showProjectList()
            },
        )

        let setupActionState = SetupActionState(
            setupSupervisor: setupSupervisor,
            isRuntimeAvailable: { [weak appState] in
                appState?.isRuntimeAvailable ?? false
            },
            writeToast: { [weak appState] in
                appState?.toast = $0
            },
            refreshSessionStates: { [weak appState] in
                appState?.refreshRuntimeSessions()
            },
        )

        runtimeSessionRefreshController = RuntimeSessionRefreshController(
            runtimeSupervisor: runtimeSupervisor,
            sessionStateProjector: sessionStateManager,
            shellStateProjector: shellStateStore,
            didUpdateContext: {
                runtimeRefreshOrchestrator.handlePostSessionUpdate()
            },
        )

        runtimeRefreshOrchestrator = RuntimeRefreshOrchestrator(
            projectStatusCacheState: projectStatusCacheState,
            runtimeSessionRefreshController: runtimeSessionRefreshController,
            activeProjectTrackingState: activeProjectTrackingState,
            projectListState: appState.projectListState,
            sessionStateProjector: sessionStateManager,
            projectsProvider: { appState.projectWorkflowState.projectCatalog.map(\.shellProjectReference) },
        )

        projectCreationCoordinator = ProjectCreationCoordinator(
            ideaCaptureEnabled: { appState.isIdeaCaptureEnabled },
            registerCreatedProject: { path in
                try projectMutationService.registerCreatedProject(path: path)
            },
            dashboardReloader: {
                dashboardState.load()
            },
        )

        let dashboardLoader = DashboardLoader(
            loadDashboardData: {
                guard let engine = appState.engine else {
                    throw NSError(domain: "Capacitor", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Engine not initialized",
                    ])
                }
                return try engine.loadDashboard()
            },
            projectWorkflowState: appState.projectWorkflowState,
            updateActiveProjects: {
                activeProjectTrackingState.updateProjects($0)
            },
            refreshRuntimeSessions: { [weak appState] in
                appState?.refreshRuntimeSessions()
            },
            loadIdeas: {
                projectDetailsManager.loadAllIdeas(for: $0)
            },
            refreshSuggestedProjects: {
                appState.projectWorkflowState.refreshSuggestedProjects()
            },
        )

        dashboardState = DashboardState(
            dashboardLoader: dashboardLoader,
            ideaCaptureEnabled: { appState.isIdeaCaptureEnabled },
            writeError: { [weak appState] in
                appState?.error = $0
            },
        )

        projectPresentationState = ProjectPresentationState(
            ideaCaptureEnabled: { appState.isIdeaCaptureEnabled },
            projectCreationEnabled: { appState.isProjectCreationEnabled },
            llmFeaturesEnabled: { appState.isLlmFeaturesEnabled },
            projectDetails: projectDetailsManager,
            projectCreation: projectCreationCoordinator,
            writeCaptureModalProject: { [weak appState] in
                appState?.captureModalProject = $0
            },
            writeCaptureModalOrigin: { [weak appState] in
                appState?.captureModalOrigin = $0
            },
            writeShowCaptureModal: { [weak appState] in
                appState?.showCaptureModal = $0
            },
            writeError: { [weak appState] in
                appState?.error = $0
            },
        )

        runtimeAutomationControllerValue = runtimeAutomationController ?? RuntimeAutomationComposer.makeController(
            writeEngine: { [weak appState] in
                appState?.engine = $0
            },
            ensureRuntimeReady: {
                runtimeHealthState.ensureRuntimeReady()
            },
            configureProjectDetails: {
                projectDetailsManager.configure(engine: $0)
            },
            reloadDashboardAfterBootstrap: {
                dashboardState.load()
            },
            refreshSetupDiagnosticsAfterBootstrap: {
                setupActionState.refreshHookDiagnostic()
            },
            startHookServer: {
                hookServerManager.startIfNeeded()
            },
            startRefreshLoop: {
                runtimeAutomationControllerValue.startRefreshLoop()
            },
            startShellTracking: {
                activeProjectTrackingState.updateProjects(appState.projectWorkflowState.projectCatalog)
            },
            writeError: { [weak appState] in
                appState?.error = $0
            },
            writeIsLoading: {
                dashboardState.setLoading($0)
            },
            refreshSessionStates: { [weak appState] in
                appState?.refreshRuntimeSessions()
            },
            ideaCaptureEnabled: { appState.isIdeaCaptureEnabled },
            checkIdeasFileChanges: {
                projectPresentationState.checkIdeasFileChanges(for: appState.projectWorkflowState.projectCatalog)
            },
            refreshSetupDiagnostics: {
                setupActionState.refreshHookDiagnostic()
            },
            checkHookServerHealth: {
                hookServerManager.checkHealth()
            },
            refreshRuntimeHealth: {
                runtimeHealthState.refresh()
            },
            reloadDashboardOnInterval: {
                dashboardState.load()
            },
        )

        let workstreamsManager = WorkstreamsManager(
            openWorktree: { worktreeProject in
                projectActivationCoordinator.activate(worktreeProject)
            },
            activeWorktreePathsProvider: {
                runtimeRefreshOrchestrator.activeWorktreePathsForGuardrails()
            },
        )

        return AppStateServices(
            anchoringController: anchoringController,
            shellStateStore: shellStateStore,
            sessionStateManager: sessionStateManager,
            hookServerManager: hookServerManager,
            projectDetailsManager: projectDetailsManager,
            projectMutationService: projectMutationService,
            projectActionState: projectActionState,
            projectActivationCoordinator: projectActivationCoordinator,
            projectImportCoordinator: projectImportCoordinator,
            quickFeedbackWorkflow: quickFeedbackWorkflow,
            setupActionState: setupActionState,
            dashboardLoader: dashboardLoader,
            projectCreationCoordinator: projectCreationCoordinator,
            projectPresentationState: projectPresentationState,
            dashboardState: dashboardState,
            workstreamsManager: workstreamsManager,
            activeProjectTrackingState: activeProjectTrackingState,
            projectStatusCacheState: projectStatusCacheState,
            runtimeHealthState: runtimeHealthState,
            runtimeRefreshOrchestrator: runtimeRefreshOrchestrator,
            runtimeAutomationController: runtimeAutomationControllerValue,
            runtimeSessionRefreshController: runtimeSessionRefreshController,
        )
    }

    private static func makeUnavailableActivateProjectTerminal() -> ActivateProjectTerminalUseCase {
        ActivateProjectTerminalUseCase(activationGateway: UnavailableActivationGateway())
    }
}
