import Foundation
import Observation

@Observable
@MainActor
final class ProjectWorkflowState {
    @ObservationIgnored
    private let projectCatalogGateway: any ProjectCatalogGateway

    private(set) var projectCatalog: [ShellProjectCatalogEntry] = []
    private(set) var suggestedProjectCatalog: [ShellSuggestedProjectCandidate] = []
    private(set) var selectedSuggestedPaths: Set<String> = []
    private(set) var legacyProjects: [Project] = []
    private(set) var legacySuggestedProjects: [SuggestedProject] = []
    private(set) var projects: [ShellProjectReference] = []
    private(set) var suggestedProjects: [ShellProjectReference] = []
    private(set) var selectedProject: ShellProjectReference?
    private(set) var lastError: Error?

    var selectedSuggestedProjectCount: Int {
        selectedSuggestedPaths.count
    }

    var hasSelectedSuggestedProjects: Bool {
        !selectedSuggestedPaths.isEmpty
    }

    var selectedLegacySuggestedProjects: [SuggestedProject] {
        legacySuggestedProjects.filter { selectedSuggestedPaths.contains($0.path) }
    }

    init(projectCatalogGateway: any ProjectCatalogGateway) {
        self.projectCatalogGateway = projectCatalogGateway
    }

    func refresh() {
        do {
            try replaceProjectCatalog(with: projectCatalogGateway.loadProjects())
            try replaceSuggestedProjectCatalog(with: projectCatalogGateway.loadSuggestedProjects())
            lastError = nil
        } catch {
            lastError = error
        }
    }

    func refreshProjects() {
        do {
            try replaceProjectCatalog(with: projectCatalogGateway.loadProjects())
            lastError = nil
        } catch {
            lastError = error
        }
    }

    func refreshSuggestedProjects() {
        do {
            try replaceSuggestedProjectCatalog(with: projectCatalogGateway.loadSuggestedProjects())
            lastError = nil
        } catch {
            clearSuggestedProjects()
            lastError = error
        }
    }

    func replaceProjectCatalog(with projects: [ShellProjectCatalogEntry]) {
        projectCatalog = projects
        legacyProjects = projects.map(Self.legacyProject)
        self.projects = projects.map(Self.projectReference)
    }

    func replaceSuggestedProjectCatalog(with suggestedProjects: [ShellSuggestedProjectCandidate]) {
        suggestedProjectCatalog = suggestedProjects
        legacySuggestedProjects = suggestedProjects.map(Self.legacySuggestedProject)
        self.suggestedProjects = suggestedProjects.map(Self.suggestedProjectReference)
        reconcileSuggestedProjectSelection()
    }

    func clearSuggestedProjects() {
        suggestedProjectCatalog = []
        legacySuggestedProjects = []
        suggestedProjects = []
        clearSuggestedProjectSelection()
    }

    func select(project: ShellProjectReference?) {
        selectedProject = project
    }

    func toggleSuggestedProjectSelection(path: String) {
        guard suggestedProjectCatalog.contains(where: { $0.path == path }) else { return }

        if selectedSuggestedPaths.contains(path) {
            selectedSuggestedPaths.remove(path)
        } else {
            selectedSuggestedPaths.insert(path)
        }
    }

    func clearSuggestedProjectSelection() {
        selectedSuggestedPaths.removeAll()
    }

    func isSuggestedProjectSelected(path: String) -> Bool {
        selectedSuggestedPaths.contains(path)
    }

    private static func projectReference(_ project: ShellProjectCatalogEntry) -> ShellProjectReference {
        ShellProjectReference(
            displayName: project.displayName,
            path: project.path,
        )
    }

    private static func suggestedProjectReference(_ project: ShellSuggestedProjectCandidate) -> ShellProjectReference {
        ShellProjectReference(
            displayName: project.displayName,
            path: project.path,
        )
    }

    private static func legacyProject(_ project: ShellProjectCatalogEntry) -> Project {
        Project(
            name: project.displayName,
            path: project.path,
            displayPath: project.displayPath,
            lastActive: project.lastActiveAt,
            claudeMdPath: project.claudeMdPath,
            claudeMdPreview: project.claudeMdPreview,
            hasLocalSettings: project.hasLocalSettings,
            taskCount: project.taskCount,
            stats: project.stats.map(legacyProjectStats),
            isMissing: project.isMissing,
        )
    }

    private static func legacySuggestedProject(_ project: ShellSuggestedProjectCandidate) -> SuggestedProject {
        SuggestedProject(
            path: project.path,
            displayPath: project.displayPath,
            name: project.displayName,
            taskCount: project.taskCount,
            hasClaudeMd: project.hasClaudeMd,
            hasProjectIndicators: project.hasProjectIndicators,
        )
    }

    private static func legacyProjectStats(_ stats: ShellProjectStats) -> ProjectStats {
        ProjectStats(
            totalInputTokens: stats.totalInputTokens,
            totalOutputTokens: stats.totalOutputTokens,
            totalCacheReadTokens: stats.totalCacheReadTokens,
            totalCacheCreationTokens: stats.totalCacheCreationTokens,
            opusMessages: stats.opusMessages,
            sonnetMessages: stats.sonnetMessages,
            haikuMessages: stats.haikuMessages,
            sessionCount: stats.sessionCount,
            latestSummary: stats.latestSummary,
            firstActivity: stats.firstActivity,
            lastActivity: stats.lastActivity,
        )
    }

    private func reconcileSuggestedProjectSelection() {
        let validPaths = Set(suggestedProjectCatalog.map(\.path))
        selectedSuggestedPaths = selectedSuggestedPaths.intersection(validPaths)
    }
}
