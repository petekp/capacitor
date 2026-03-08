import Foundation

@MainActor
final class ProjectActivationCoordinator {
    private let activateTracking: (ShellProjectReference) -> Void
    private let activateProject: (ShellProjectReference) -> Void

    init(
        activeProjectTrackingState: ActiveProjectTrackingState,
        activateProjectTerminal: ActivateProjectTerminalUseCase,
    ) {
        activateTracking = { project in
            activeProjectTrackingState.activate(project)
        }
        activateProject = { project in
            _Concurrency.Task {
                try? await activateProjectTerminal.execute(project: project)
            }
        }
    }

    init(
        activateTracking: @escaping (ShellProjectReference) -> Void,
        activateProject: @escaping (ShellProjectReference) -> Void,
    ) {
        self.activateTracking = activateTracking
        self.activateProject = activateProject
    }

    func activate(_ project: some ShellProjectReferenceProviding) {
        let projectReference = project.shellProjectReference
        activateTracking(projectReference)
        activateProject(projectReference)
    }
}
