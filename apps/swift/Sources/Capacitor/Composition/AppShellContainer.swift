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
        let shellActivationExecutor = ShellActivationExecutor()
        let activationGateway = LiveActivationGateway(shellProjectActivator: shellActivationExecutor)
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
        let services = AppStateServiceAssembler.makeServices(
            appState: appState,
            projectMutationGateway: projectMutationGateway,
            runtimeSupervisor: runtimeSupervisor,
            setupSupervisor: setupSupervisor,
            activateProjectTerminal: activateProjectTerminal,
            runtimeAutomationController: nil,
        )
        appState.installServices(services)
        if appState.isIdeaCaptureEnabled {
            services.projectCreationCoordinator.loadCreations()
        }
        services.runtimeAutomationController.startBootstrap()
        setupWorkflowState.setShellIntegrationActivityProvider { [weak appState] in
            guard let shellState = appState?.shellStateStore.state else {
                return false
            }
            return !shellState.shells.isEmpty
        }
        shellActivationExecutor.preferredTerminalAppResolver = { [weak appState] clientTty, projectPath, sessionName in
            guard let shellState = appState?.shellStateStore.state else {
                return nil
            }
            return ShellActivationExecutor.resolvePreferredTerminalApp(
                clientTty: clientTty,
                projectPath: projectPath,
                sessionName: sessionName,
                shellState: shellState,
            )
        }
        shellActivationExecutor.onActivationResult = { [weak appState] result in
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
            projectActionState: services.projectActionState,
            navigationState: navigationState,
            setupSupervisor: setupSupervisor,
            setupActionState: services.setupActionState,
            setupWorkflowState: setupWorkflowState,
            activateProjectTerminal: activateProjectTerminal,
            ideaCaptureWorkflow: IdeaCaptureWorkflow(ideaGateway: ideaGateway),
            feedbackWorkflow: FeedbackWorkflow(feedbackGateway: feedbackGateway),
        )
    }
}
