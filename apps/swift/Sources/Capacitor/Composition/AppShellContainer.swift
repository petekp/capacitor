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
        let ideaGateway = LiveIdeaGateway()
        let feedbackGateway = LiveFeedbackGateway()
        let terminalLauncher = TerminalLauncher()
        let activationGateway = LiveActivationGateway(terminalLauncher: terminalLauncher)
        let activateProjectTerminal = ActivateProjectTerminalUseCase(activationGateway: activationGateway)
        let navigationState = NavigationState()
        let projectWorkflowState = ProjectWorkflowState(projectCatalogGateway: projectCatalogGateway)
        let projectListState = ProjectListState(projectListPreferencesGateway: projectListPreferencesGateway)
        let runtimeSupervisor = RuntimeSupervisor(runtimeGateway: runtimeGateway)
        let setupSupervisor = SetupSupervisor(setupGateway: setupGateway)
        let setupWorkflowState = SetupWorkflowState()
        let appState = AppState(dependencies: AppStateDependencies(
            navigationState: navigationState,
            projectWorkflowState: projectWorkflowState,
            projectListState: projectListState,
            projectMutationGateway: projectMutationGateway,
            runtimeSupervisor: runtimeSupervisor,
            setupSupervisor: setupSupervisor,
            runtimeAutomationController: nil,
            activateProjectTerminal: activateProjectTerminal,
        ))
        terminalLauncher.preferredTerminalAppResolver = { [weak appState] clientTty, projectPath, sessionName in
            guard let shellState = appState?.shellStateStore.state else {
                return nil
            }
            return TerminalLauncher.resolvePreferredTerminalApp(
                clientTty: clientTty,
                projectPath: projectPath,
                sessionName: sessionName,
                shellState: shellState,
            )
        }
        terminalLauncher.onActivationResult = { [weak appState] result in
            guard let appState else { return }
            appState.activationTrace = [
                "project=\(result.projectName)",
                "path=\(result.projectPath)",
                "success=\(result.success)",
                "used_fallback=\(result.usedFallback)",
            ].joined(separator: "\n")
            if !result.success {
                appState.toast = ToastMessage(
                    "Couldn’t activate Ghostty.",
                    isError: true,
                )
            }
        }

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
            activateProjectTerminal: activateProjectTerminal,
            ideaCaptureWorkflow: IdeaCaptureWorkflow(ideaGateway: ideaGateway),
            feedbackWorkflow: FeedbackWorkflow(feedbackGateway: feedbackGateway),
        )
    }
}
