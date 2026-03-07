import Foundation

actor ProjectIngestionWorker {
    struct AddProjectsOutcome: Sendable {
        var addedCount: Int
        var addedPaths: [String]
        var alreadyTrackedPaths: [String]
        var failedNames: [String]
    }

    enum IngestionDecision {
        case add(path: String)
        case alreadyTracked(path: String)
        case failed(name: String)
    }

    private let projectMutationGateway: any ProjectMutationGateway

    init(projectMutationGateway: any ProjectMutationGateway) {
        self.projectMutationGateway = projectMutationGateway
    }

    static func decision(for path: String, result: ShellProjectValidationResult) -> IngestionDecision {
        let name = URL(fileURLWithPath: path).lastPathComponent

        switch result.kind {
        case .valid, .missingClaudeMd:
            return .add(path: path)
        case .suggestParent:
            if let suggested = result.suggestedPath {
                let suggestedName = URL(fileURLWithPath: suggested).lastPathComponent
                return .failed(name: "\(name) (use \(suggestedName))")
            }
            return .failed(name: "\(name) (use project root)")
        case .notAProject:
            return .failed(name: "\(name) (not a project)")
        case .alreadyTracked:
            return .alreadyTracked(path: result.path)
        case .pathNotFound:
            return .failed(name: "\(name) (not found)")
        case .dangerousPath:
            return .failed(name: "\(name) (too broad)")
        case .unknown:
            return .failed(name: name)
        }
    }

    func addProjects(paths: [String]) async -> AddProjectsOutcome {
        let fm = FileManager.default
        var addedCount = 0
        var addedPaths: [String] = []
        var alreadyTrackedPaths: [String] = []
        var failedNames: [String] = []

        for (index, path) in paths.enumerated() {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                continue
            }

            do {
                let result = try projectMutationGateway.validateProject(path: path)

                switch Self.decision(for: path, result: result) {
                case let .add(path):
                    do {
                        try projectMutationGateway.addProject(path: path)
                        addedCount += 1
                        addedPaths.append(path)
                    } catch {
                        failedNames.append(URL(fileURLWithPath: path).lastPathComponent)
                    }
                case let .alreadyTracked(path):
                    alreadyTrackedPaths.append(path)
                case let .failed(name):
                    failedNames.append(name)
                }
            } catch {
                failedNames.append(URL(fileURLWithPath: path).lastPathComponent)
            }

            if index > 0, index % 5 == 0 {
                await _Concurrency.Task.yield()
            }
        }

        return AddProjectsOutcome(
            addedCount: addedCount,
            addedPaths: addedPaths,
            alreadyTrackedPaths: alreadyTrackedPaths,
            failedNames: failedNames,
        )
    }
}
