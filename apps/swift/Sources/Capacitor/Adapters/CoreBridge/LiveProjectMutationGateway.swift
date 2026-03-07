import Foundation

struct LiveProjectMutationGateway: ProjectMutationGateway {
    private let runtimeProvider: () throws -> CoreRuntime

    init(runtimeProvider: @escaping () throws -> CoreRuntime = { try CoreRuntime() }) {
        self.runtimeProvider = runtimeProvider
    }

    func addProject(path: String) throws {
        try runtimeProvider().addProject(path: path)
    }

    func removeProject(path: String) throws {
        try runtimeProvider().removeProject(path: path)
    }

    func validateProject(path: String) throws -> ShellProjectValidationResult {
        try ProjectMutationBridge.validationResult(from: runtimeProvider().validateProject(path: path))
    }

    func createProjectClaudeMd(projectPath: String) throws {
        try runtimeProvider().createProjectClaudeMd(projectPath: projectPath)
    }
}
