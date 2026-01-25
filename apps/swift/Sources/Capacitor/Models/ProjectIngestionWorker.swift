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

    private let engine: CoreRuntime

    init?() {
        guard let engine = try? CoreRuntime() else { return nil }
        self.engine = engine
    }

    static func decision(for path: String, result: ValidationResultFfi) -> IngestionDecision {
        let name = URL(fileURLWithPath: path).lastPathComponent

        switch result.resultType {
        case "valid", "missing_claude_md":
            return .add(path: path)
        case "suggest_parent":
            if let suggested = result.suggestedPath {
                let suggestedName = URL(fileURLWithPath: suggested).lastPathComponent
                return .failed(name: "\(name) (use \(suggestedName))")
            }
            return .failed(name: "\(name) (use project root)")
        case "not_a_project":
            return .failed(name: "\(name) (not a project)")
        case "already_tracked":
            return .alreadyTracked(path: result.path)
        case "path_not_found":
            return .failed(name: "\(name) (not found)")
        case "dangerous_path":
            return .failed(name: "\(name) (too broad)")
        default:
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

            let result = engine.validateProject(path: path)

            switch Self.decision(for: path, result: result) {
            case let .add(path):
                do {
                    try engine.addProject(path: path)
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
