import Foundation
import Observation

@MainActor
final class ProjectMutationService {
    struct ConnectSuggestedProjectsOutcome: Equatable {
        let connectedCount: Int
    }

    enum ProjectSelectionResolution: Equatable {
        case connect(path: String)
        case alreadyTracked(path: String, isDormant: Bool)
        case failed(message: String)
    }

    struct ImportedProjectsOutcome: Equatable {
        let addedPaths: [String]
        let alreadyTrackedPaths: [String]
        let failedNames: [String]

        var addedCount: Int {
            addedPaths.count
        }
    }

    struct RecoveredTrackedProjectsOutcome: Equatable {
        let movedPaths: [String]
        let alreadyInProgressCount: Int
    }

    @ObservationIgnored
    private let projectMutationGateway: any ProjectMutationGateway
    private let projectWorkflowState: ProjectWorkflowState
    private let projectListState: ProjectListState
    @ObservationIgnored
    private let reloadDashboard: (_ hydrateIdeas: Bool, _ showLoadingState: Bool) -> Void
    @ObservationIgnored
    private let scheduleDeferredIdeaHydration: () -> Void
    @ObservationIgnored
    private let projectIngestionWorker: ProjectIngestionWorker

    init(
        projectMutationGateway: any ProjectMutationGateway,
        projectWorkflowState: ProjectWorkflowState,
        projectListState: ProjectListState,
        reloadDashboard: @escaping (_ hydrateIdeas: Bool, _ showLoadingState: Bool) -> Void = { _, _ in },
        scheduleDeferredIdeaHydration: @escaping () -> Void = {},
        projectIngestionWorker: ProjectIngestionWorker? = nil,
    ) {
        self.projectMutationGateway = projectMutationGateway
        self.projectWorkflowState = projectWorkflowState
        self.projectListState = projectListState
        self.reloadDashboard = reloadDashboard
        self.scheduleDeferredIdeaHydration = scheduleDeferredIdeaHydration
        self.projectIngestionWorker = projectIngestionWorker ?? ProjectIngestionWorker(projectMutationGateway: projectMutationGateway)
    }

    func connectSelectedSuggestedProjects() -> ConnectSuggestedProjectsOutcome {
        let selected = projectWorkflowState.selectedLegacySuggestedProjects
        let outcome = connectSuggestedProjects(selected)
        projectWorkflowState.clearSuggestedProjectSelection()
        return outcome
    }

    func resolveProjectSelection(path: String) throws -> ProjectSelectionResolution {
        let result = try projectMutationGateway.validateProject(path: path)

        switch result.kind {
        case .valid, .missingClaudeMd:
            return .connect(path: path)
        case .suggestParent:
            if let suggestedPath = result.suggestedPath {
                return .connect(path: suggestedPath)
            }
            return .failed(message: "Could not determine project root")
        case .alreadyTracked:
            return .alreadyTracked(
                path: result.path,
                isDormant: projectListState.isManuallyDormant(path: result.path),
            )
        case .dangerousPath:
            return .failed(message: result.reason ?? "Path is too broad")
        case .pathNotFound:
            return .failed(message: "Path not found")
        case .notAProject, .unknown:
            return .failed(message: result.reason ?? "Could not connect project")
        }
    }

    func connectProject(path: String) throws {
        try projectMutationGateway.addProject(path: path)
        projectListState.prependProject(path: path)
        reloadDashboard(true, true)
    }

    func moveTrackedProjectToRecent(path: String) {
        projectListState.movePathToRecent(path)
    }

    func importProjectsFromDrop(paths: [String]) async -> ImportedProjectsOutcome {
        let outcome = await projectIngestionWorker.addProjects(paths: paths)

        if !outcome.addedPaths.isEmpty {
            projectListState.prependProjects(paths: outcome.addedPaths)
            reloadDashboard(false, false)
            scheduleDeferredIdeaHydration()
        }

        return ImportedProjectsOutcome(
            addedPaths: outcome.addedPaths,
            alreadyTrackedPaths: outcome.alreadyTrackedPaths,
            failedNames: outcome.failedNames,
        )
    }

    func recoverTrackedProjects(paths: [String]) -> RecoveredTrackedProjectsOutcome {
        var movedPaths: [String] = []
        var alreadyInProgressCount = 0

        for path in paths {
            if projectListState.isManuallyDormant(path: path) {
                projectListState.movePathToRecent(path)
                movedPaths.append(path)
            } else {
                alreadyInProgressCount += 1
            }
        }

        return RecoveredTrackedProjectsOutcome(
            movedPaths: movedPaths,
            alreadyInProgressCount: alreadyInProgressCount,
        )
    }

    func removeProject(path: String) throws {
        try projectMutationGateway.removeProject(path: path)
        projectListState.removeProject(path: path)
        reloadDashboard(true, true)
    }

    func registerCreatedProject(path: String) throws {
        try projectMutationGateway.addProject(path: path)
    }

    func createClaudeMd(for path: String) throws {
        try projectMutationGateway.createProjectClaudeMd(projectPath: path)
    }

    private func connectSuggestedProjects(_ suggestions: [SuggestedProject]) -> ConnectSuggestedProjectsOutcome {
        guard !suggestions.isEmpty else {
            return ConnectSuggestedProjectsOutcome(connectedCount: 0)
        }

        var connectedPaths: [String] = []

        for suggestion in suggestions {
            do {
                try projectMutationGateway.addProject(path: suggestion.path)
                projectListState.prependProject(path: suggestion.path)
                connectedPaths.append(suggestion.path)
            } catch {
                continue
            }
        }

        if !connectedPaths.isEmpty {
            let connectedPathSet = Set(connectedPaths)
            let remainingSuggestions = projectWorkflowState.suggestedProjectCatalog.filter { suggestion in
                !connectedPathSet.contains(suggestion.path)
            }
            projectWorkflowState.replaceSuggestedProjectCatalog(with: remainingSuggestions)
            reloadDashboard(true, true)
        }

        return ConnectSuggestedProjectsOutcome(connectedCount: connectedPaths.count)
    }
}
