import Foundation

struct AppStateDependencies {
    let navigationState: NavigationState
    let projectWorkflowState: ProjectWorkflowState
    let projectListState: ProjectListState
    let projectMutationGateway: any ProjectMutationGateway
    let runtimeSupervisor: RuntimeSupervisor
    let setupSupervisor: SetupSupervisor
    let runtimeAutomationController: RuntimeAutomationController?
    let activateProjectTerminal: ActivateProjectTerminalUseCase?
}

extension AppStateDependencies {
    @MainActor
    static func live(
        navigationState: NavigationState? = nil,
        projectWorkflowState: ProjectWorkflowState? = nil,
        projectListState: ProjectListState? = nil,
        projectMutationGateway: (any ProjectMutationGateway)? = nil,
        runtimeSupervisor: RuntimeSupervisor? = nil,
        setupSupervisor: SetupSupervisor? = nil,
        runtimeAutomationController: RuntimeAutomationController? = nil,
        activateProjectTerminal: ActivateProjectTerminalUseCase? = nil,
    ) -> AppStateDependencies {
        let runtimeGateway = LiveRuntimeGateway()
        let projectCatalogGateway = LiveProjectCatalogGateway()
        let projectListPreferencesGateway = LiveProjectListPreferencesGateway()
        let setupGateway = LiveSetupGateway()
        let resolvedNavigationState = navigationState ?? NavigationState()

        return AppStateDependencies(
            navigationState: resolvedNavigationState,
            projectWorkflowState: projectWorkflowState ?? ProjectWorkflowState(projectCatalogGateway: projectCatalogGateway),
            projectListState: projectListState ?? ProjectListState(projectListPreferencesGateway: projectListPreferencesGateway),
            projectMutationGateway: projectMutationGateway ?? LiveProjectMutationGateway(),
            runtimeSupervisor: runtimeSupervisor ?? RuntimeSupervisor(runtimeGateway: runtimeGateway),
            setupSupervisor: setupSupervisor ?? SetupSupervisor(setupGateway: setupGateway),
            runtimeAutomationController: runtimeAutomationController,
            activateProjectTerminal: activateProjectTerminal,
        )
    }
}
