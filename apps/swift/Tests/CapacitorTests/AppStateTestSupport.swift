@testable import Capacitor

@MainActor
func makeTestAppState(
    navigationState: NavigationState? = nil,
    projectWorkflowState: ProjectWorkflowState? = nil,
    projectListState: ProjectListState? = nil,
    projectMutationGateway: (any ProjectMutationGateway)? = nil,
    runtimeSupervisor: RuntimeSupervisor? = nil,
    setupSupervisor: SetupSupervisor? = nil,
    runtimeAutomationController: RuntimeAutomationController? = nil,
    activateProjectTerminal: ActivateProjectTerminalUseCase? = nil,
) -> AppState {
    let resolvedNavigationState = navigationState ?? NavigationState()
    let resolvedProjectWorkflowState = projectWorkflowState ?? ProjectWorkflowState(
        projectCatalogGateway: LiveProjectCatalogGateway(),
    )
    let resolvedProjectListState = projectListState ?? ProjectListState(
        projectListPreferencesGateway: LiveProjectListPreferencesGateway(),
    )
    let resolvedRuntimeSupervisor = runtimeSupervisor ?? RuntimeSupervisor(
        runtimeGateway: LiveRuntimeGateway(),
    )
    let resolvedSetupSupervisor = setupSupervisor ?? SetupSupervisor(
        setupGateway: LiveSetupGateway(),
    )

    return AppState(
        dependencies: AppStateDependencies(
            navigationState: resolvedNavigationState,
            projectWorkflowState: resolvedProjectWorkflowState,
            projectListState: resolvedProjectListState,
            projectMutationGateway: projectMutationGateway ?? LiveProjectMutationGateway(),
            runtimeSupervisor: resolvedRuntimeSupervisor,
            setupSupervisor: resolvedSetupSupervisor,
            runtimeAutomationController: runtimeAutomationController,
            activateProjectTerminal: activateProjectTerminal,
        ),
    )
}
