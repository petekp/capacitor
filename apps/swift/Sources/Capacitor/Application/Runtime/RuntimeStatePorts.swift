import Foundation

@MainActor
protocol ProjectSessionReading: AnyObject {
    func sessionState(for projectPath: String) -> ProjectSessionState?
    func preferredSessionID(for projectPath: String) -> String?
}

@MainActor
protocol RuntimeSessionStateProjecting: ProjectSessionReading {
    var sessionStates: [String: ProjectSessionState] { get }
    func applyRuntimeProjectStates(
        _ runtimeProjects: [RuntimeProjectState],
        for projectPaths: [String],
        correlationId: String?,
    )
    func clearRuntimeProjectStates()
}

@MainActor
protocol RuntimeShellStateProjecting: AnyObject {
    func applyRuntimeShellState(_ runtimeState: ShellCwdState, correlationId: String?) async
    func clearRuntimeShellState(correlationId: String?)
}

struct ProjectPathReference: ProjectPathProviding {
    let path: String
}
