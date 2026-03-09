import Foundation

@MainActor
protocol ProjectListPreferencesGateway {
    func loadDormantProjectPaths() -> Set<String>
    func saveDormantProjectPaths(_ paths: Set<String>)
    func loadProjectOrder() -> [String]
    func saveProjectOrder(_ order: [String])
}
