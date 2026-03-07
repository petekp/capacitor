import Foundation

struct LiveProjectCatalogGateway: ProjectCatalogGateway {
    private let runtimeProvider: () throws -> CoreRuntime

    init(runtimeProvider: @escaping () throws -> CoreRuntime = { try CoreRuntime() }) {
        self.runtimeProvider = runtimeProvider
    }

    func loadProjects() throws -> [ShellProjectCatalogEntry] {
        try ProjectCatalogBridge.projectCatalogEntries(
            from: runtimeProvider()
                .loadDashboard()
                .projects,
        )
    }

    func loadSuggestedProjects() throws -> [ShellSuggestedProjectCandidate] {
        try ProjectCatalogBridge.suggestedProjectCandidates(
            from: runtimeProvider()
                .getSuggestedProjects(),
        )
    }
}
