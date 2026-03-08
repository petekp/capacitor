import Foundation

struct LiveProjectCatalogGateway: ProjectCatalogGateway {
    private let runtimeProvider: () throws -> CoreRuntime

    init(runtimeProvider: @escaping () throws -> CoreRuntime = { try CoreRuntime() }) {
        self.runtimeProvider = runtimeProvider
    }

    func loadProjects() throws -> [ShellProjectCatalogEntry] {
        try runtimeProvider().loadDashboard().projects
    }

    func loadSuggestedProjects() throws -> [ShellSuggestedProjectCandidate] {
        try runtimeProvider().getSuggestedProjects()
    }
}
