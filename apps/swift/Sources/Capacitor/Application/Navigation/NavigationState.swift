import Foundation

@MainActor
final class NavigationState {
    private(set) var destination: ShellNavigationDestination = .projectList

    func showProjectList() {
        destination = .projectList
    }

    func showProjectDetail(_ project: ShellProjectReference) {
        destination = .projectDetail(projectID: project.id)
    }

    func showNewIdea() {
        destination = .newIdea
    }

    func showSetup() {
        destination = .setup
    }
}
