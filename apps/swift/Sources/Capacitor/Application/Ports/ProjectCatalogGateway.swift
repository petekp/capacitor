import Foundation

protocol ProjectCatalogGateway {
    func loadProjects() throws -> [ShellProjectCatalogEntry]
    func loadSuggestedProjects() throws -> [ShellSuggestedProjectCandidate]
}
