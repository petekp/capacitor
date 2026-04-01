import Foundation

struct SessionResolutionPolicy {
    private let discoverFallbackSession: ((String) async -> String?)?

    /// Generic session names that are acceptable for any project. These are names
    /// users commonly assign to tmux sessions that are not project-specific.
    static let genericSessionNames: Set<String> = [
        "main", "dev", "work", "default", "scratch", "temp", "tmp",
    ]

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

    /// Returns true when the session name is plausibly associated with the
    /// given project. The heuristic accepts:
    ///
    /// 1. Generic names ("main", "dev", "work", etc.) — acceptable for any project.
    /// 2. Names that contain the project's display name (case-insensitive).
    /// 3. Names where the project path's last component matches or is contained
    ///    in the session name (case-insensitive).
    func sessionNameBelongsToProject(
        sessionName: String,
        projectPath: String,
    ) -> Bool {
        let lowerSession = sessionName.lowercased()

        // Generic names are fine for any project.
        if Self.genericSessionNames.contains(lowerSession) {
            return true
        }

        let projectSlug = URL(fileURLWithPath: projectPath)
            .lastPathComponent
            .lowercased()

        guard !projectSlug.isEmpty else {
            return true
        }

        // Forward containment: session name contains the project slug
        if lowerSession.contains(projectSlug) {
            return true
        }

        // Reverse containment: project slug contains the session name.
        // Require minimum 3 characters to prevent overly permissive matching
        // for very short session names (e.g., "a" would match "capacitor").
        if lowerSession.count >= 3, projectSlug.contains(lowerSession) {
            return true
        }

        return false
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
