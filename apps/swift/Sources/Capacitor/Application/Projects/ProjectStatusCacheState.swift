import Foundation

@MainActor
@Observable
final class ProjectStatusCacheState {
    private(set) var statuses: [String: ProjectStatus] = [:]

    func refresh(projectPaths: [String], engine: CoreRuntime?) {
        guard let engine else { return }

        var updated: [String: ProjectStatus] = [:]
        for projectPath in projectPaths {
            if let status = engine.getProjectStatus(projectPath: projectPath) {
                updated[projectPath] = status
            }
        }

        if updated != statuses {
            statuses = updated
        }
    }
}
