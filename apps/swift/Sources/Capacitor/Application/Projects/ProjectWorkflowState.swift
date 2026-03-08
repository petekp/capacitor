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
    private(set) var lastError: Error?

    var selectedSuggestedProjectCount: Int {
        selectedSuggestedPaths.count
    }

    var hasSelectedSuggestedProjects: Bool {
        !selectedSuggestedPaths.isEmpty
    }

    var selectedSuggestedProjectCandidates: [ShellSuggestedProjectCandidate] {
        suggestedProjectCatalog.filter { selectedSuggestedPaths.contains($0.path) }
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
    }

    func replaceSuggestedProjectCatalog(with suggestedProjects: [ShellSuggestedProjectCandidate]) {
        suggestedProjectCatalog = suggestedProjects
        reconcileSuggestedProjectSelection()
    }

    func clearSuggestedProjects() {
        suggestedProjectCatalog = []
        clearSuggestedProjectSelection()
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

    private func reconcileSuggestedProjectSelection() {
        let validPaths = Set(suggestedProjectCatalog.map(\.path))
        selectedSuggestedPaths = selectedSuggestedPaths.intersection(validPaths)
    }
}
