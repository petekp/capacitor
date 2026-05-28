import Foundation

struct WorkBatchHomeSection: Equatable, Identifiable {
    let project: Project
    let batches: [WorkBatchProjection]

    var id: String {
        project.path
    }

    var batchCount: Int {
        batches.count
    }

    var queuedTaskCount: Int {
        batches.reduce(0) { $0 + $1.queuedTaskCount }
    }
}

enum WorkBatchHomeProjection {
    static func make(
        projects: [Project],
        projectOrder: [String],
        hiddenProjectPaths: Set<String>,
        batchesByProjectPath: [String: [WorkBatchProjection]],
    ) -> [WorkBatchHomeSection] {
        ProjectOrdering
            .orderedProjects(
                projects.filter { !hiddenProjectPaths.contains($0.path) },
                customOrder: projectOrder,
            )
            .map { project in
                WorkBatchHomeSection(
                    project: project,
                    batches: batchesByProjectPath[project.path] ?? [],
                )
            }
    }
}
