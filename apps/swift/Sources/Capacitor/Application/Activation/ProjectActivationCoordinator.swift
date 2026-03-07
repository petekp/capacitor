import Foundation

@MainActor
final class ProjectActivationCoordinator {
    private let activateTracking: (Project) -> Void
    private let activateProject: (Project) -> Void

    init(
        activeProjectTrackingState: ActiveProjectTrackingState,
        activateProjectTerminal: ActivateProjectTerminalUseCase,
    ) {
        activateTracking = { project in
            activeProjectTrackingState.activate(project)
        }
        activateProject = { project in
            let reference = ShellProjectReference(
                displayName: project.name,
                path: project.path,
            )
            _Concurrency.Task {
                try? await activateProjectTerminal.execute(project: reference)
            }
        }
    }

    init(
        activateTracking: @escaping (Project) -> Void,
        activateProject: @escaping (Project) -> Void,
    ) {
        self.activateTracking = activateTracking
        self.activateProject = activateProject
    }

    func activate(_ project: Project) {
        activateTracking(project)
        activateProject(project)
    }
}
