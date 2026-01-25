import Foundation

@MainActor
final class ReadyChimeGate {
    enum Source: String {
        case visibleState = "visible_state"
        case sessionState = "session_state"
        case previewState = "preview_state"
    }

    static let shared = ReadyChimeGate()

    private var lastKnownStateByProject: [String: SessionState] = [:]

    func shouldPlay(
        projectPath: String,
        source: Source,
        playReadyChime: Bool,
        reportedOldState: SessionState?,
        newState: SessionState?,
    ) -> Bool {
        // Prefer the canonical state we have already observed for this project.
        // This prevents duplicate chimes when multiple view paths report the same
        // transition with stale `oldState` values.
        let previousState = lastKnownStateByProject[projectPath] ?? reportedOldState
        if let newState {
            lastKnownStateByProject[projectPath] = newState
        } else {
            lastKnownStateByProject.removeValue(forKey: projectPath)
        }

        guard ReadyChimePolicy.shouldPlay(
            playReadyChime: playReadyChime,
            oldState: previousState,
            newState: newState,
        ) else {
            DebugLog.write(
                "ReadyChimeGate decision=skip reason=transition source=\(source.rawValue) project_path=\(projectPath) old_state=\(String(describing: previousState)) new_state=\(String(describing: newState))",
            )
            return false
        }
        DebugLog.write(
            "ReadyChimeGate decision=play source=\(source.rawValue) project_path=\(projectPath) old_state=\(String(describing: previousState)) new_state=\(String(describing: newState))",
        )
        return true
    }

    #if DEBUG
        func resetForTesting() {
            lastKnownStateByProject = [:]
        }
    #endif
}
