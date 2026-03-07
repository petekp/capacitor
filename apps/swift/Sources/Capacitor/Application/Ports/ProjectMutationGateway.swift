import Foundation

protocol ProjectMutationGateway {
    func addProject(path: String) throws
    func removeProject(path: String) throws
    func validateProject(path: String) throws -> ShellProjectValidationResult
    func createProjectClaudeMd(projectPath: String) throws
}
