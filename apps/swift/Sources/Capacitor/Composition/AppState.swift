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

    // MARK: - Installed Services

    private(set) var anchoringController: WindowAnchoringController!
    private(set) var shellStateStore: ShellStateStore!
    private(set) var sessionStateManager: SessionStateManager!
    private(set) var hookServerManager: HookServerManager!
    private(set) var projectDetailsManager: ProjectDetailsManager!
    private(set) var projectMutationService: ProjectMutationService!
    private(set) var projectActionState: ProjectActionState!
    private(set) var projectActivationCoordinator: ProjectActivationCoordinator!
    private(set) var projectImportCoordinator: ProjectImportCoordinator!
    private(set) var quickFeedbackWorkflow: QuickFeedbackWorkflow!
    private(set) var setupActionState: SetupActionState!
    private(set) var dashboardLoader: DashboardLoader!
    private(set) var projectCreationCoordinator: ProjectCreationCoordinator!
    private(set) var projectPresentationState: ProjectPresentationState!
    private(set) var dashboardState: DashboardState!
    private(set) var workstreamsManager: WorkstreamsManager!

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

    var engine: CoreRuntime?
    private(set) var sessionStateRevision = 0
    var isRuntimeAvailable: Bool {
        engine != nil
    }

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
        let config = AppConfig.current()
        #if DEBUG
            AlphaChannelGuardrail.enforceOrExit(channel: config.channel)
        #endif
        channel = config.channel
        DebugLog.write("AppState.init config channel=\(channel.rawValue)")
        featureFlags = config.featureFlags
    }

    func installServices(_ services: AppStateServices) {
        anchoringController = services.anchoringController
        shellStateStore = services.shellStateStore
        sessionStateManager = services.sessionStateManager
        hookServerManager = services.hookServerManager
        projectDetailsManager = services.projectDetailsManager
        projectMutationService = services.projectMutationService
        projectActionState = services.projectActionState
        projectActivationCoordinator = services.projectActivationCoordinator
        projectImportCoordinator = services.projectImportCoordinator
        quickFeedbackWorkflow = services.quickFeedbackWorkflow
        setupActionState = services.setupActionState
        dashboardLoader = services.dashboardLoader
        projectCreationCoordinator = services.projectCreationCoordinator
        projectPresentationState = services.projectPresentationState
        dashboardState = services.dashboardState
        workstreamsManager = services.workstreamsManager
        activeProjectTrackingState = services.activeProjectTrackingState
        projectStatusCacheState = services.projectStatusCacheState
        runtimeHealthState = services.runtimeHealthState
        runtimeRefreshOrchestrator = services.runtimeRefreshOrchestrator
        runtimeAutomationController = services.runtimeAutomationController
        runtimeSessionRefreshController = services.runtimeSessionRefreshController

        sessionStateManager.onVisualStateChanged = { [weak self] in
            guard let self else { return }
            sessionStateRevision &+= 1
        }
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

    func refreshRuntimeSessions() {
        runtimeRefreshOrchestrator.refreshSessionStates(engine: engine)
    }

    func scheduleDeferredIdeaHydration() {
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
