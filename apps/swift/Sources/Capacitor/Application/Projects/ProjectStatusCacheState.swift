import Foundation

@MainActor
@Observable
final class ProjectStatusCacheState {
    private(set) var statuses: [String: ProjectStatus] = [:]

    func refresh(projects: [Project], engine: CoreRuntime?) {
        guard let engine else { return }

        var updated: [String: ProjectStatus] = [:]
        for project in projects {
            if let status = engine.getProjectStatus(projectPath: project.path) {
                updated[project.path] = status
            }
        }

        if updated != statuses {
            statuses = updated
        }
    }
}
