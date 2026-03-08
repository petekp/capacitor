import Foundation

@MainActor
struct AppShellContainer {
    let appState: AppState
    let runtimeSupervisor: RuntimeSupervisor
    let projectWorkflowState: ProjectWorkflowState
    let projectListState: ProjectListState
    let projectActionState: ProjectActionState
    let navigationState: NavigationState
    let setupSupervisor: SetupSupervisor
    let setupActionState: SetupActionState
    let setupWorkflowState: SetupWorkflowState
    let activateProjectTerminal: ActivateProjectTerminalUseCase
    let ideaCaptureWorkflow: IdeaCaptureWorkflow
    let feedbackWorkflow: FeedbackWorkflow

    static func live() -> AppShellContainer {
        let runtimeGateway = LiveRuntimeGateway()
        let projectCatalogGateway = LiveProjectCatalogGateway()
        let projectMutationGateway = LiveProjectMutationGateway()
        let projectListPreferencesGateway = LiveProjectListPreferencesGateway()
        let setupGateway = LiveSetupGateway()
        let activationGateway = LiveActivationGateway()
        let ideaGateway = LiveIdeaGateway()
        let feedbackGateway = LiveFeedbackGateway()
        let navigationState = NavigationState()
        let projectWorkflowState = ProjectWorkflowState(projectCatalogGateway: projectCatalogGateway)
        let projectListState = ProjectListState(projectListPreferencesGateway: projectListPreferencesGateway)
        let runtimeSupervisor = RuntimeSupervisor(runtimeGateway: runtimeGateway)
        let setupSupervisor = SetupSupervisor(setupGateway: setupGateway)
        let setupWorkflowState = SetupWorkflowState()
        let appState = AppState(
            navigationState: navigationState,
            projectWorkflowState: projectWorkflowState,
            projectListState: projectListState,
            projectMutationGateway: projectMutationGateway,
            runtimeSupervisor: runtimeSupervisor,
            setupSupervisor: setupSupervisor
        )

        return AppShellContainer(
            appState: appState,
            runtimeSupervisor: runtimeSupervisor,
            projectWorkflowState: projectWorkflowState,
            projectListState: projectListState,
            projectActionState: appState.projectActionState,
            navigationState: navigationState,
            setupSupervisor: setupSupervisor,
            setupActionState: appState.setupActionState,
            setupWorkflowState: setupWorkflowState,
            activateProjectTerminal: ActivateProjectTerminalUseCase(activationGateway: activationGateway),
            ideaCaptureWorkflow: IdeaCaptureWorkflow(ideaGateway: ideaGateway),
            feedbackWorkflow: FeedbackWorkflow(feedbackGateway: feedbackGateway)
        )
    }
}
