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
