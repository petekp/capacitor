import Foundation

struct SessionResolutionPolicy {
    private let discoverFallbackSession: ((String) async -> String?)?

    init(discoverFallbackSession: ((String) async -> String?)? = nil) {
        self.discoverFallbackSession = discoverFallbackSession
    }

    /// Prefer the runtime's canonical tmux session name. The Rust runtime
    /// resolves which session belongs to a project based on live shell/CWD
    /// data — trust that resolution rather than second-guessing with string
    /// similarity.
    func chooseSessionName(
        projectPath: String,
        routedSessionName: String?,
    ) async -> String {
        if let resolved = normalized(routedSessionName) {
            return resolved
        }
        if let discoverFallbackSession,
           let resolved = await discoverFallbackSession(projectPath),
           let normalizedResolved = normalized(resolved)
        {
            return normalizedResolved
        }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
