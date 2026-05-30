import CryptoKit
import Foundation

enum WorkspaceIdentity {
    static func fromGitInfo(_ info: GitRepositoryInfo) -> String {
        let projectId = info.commonDir ?? info.repoRoot
        let source = "\(projectId)|\(info.relativePath)"
        return hash(source)
    }

    static func fromPath(_ path: String) -> String {
        // C2-Phase2 SWIFTJOIN: mirror the Rust `workspace_id(input, input)` source
        // string so Swift's fallback key converges with the Rust-provided FFI key.
        // Rust runs `normalize_path_for_matching` on both halves (now delegated via
        // PathNormalizer.normalize), then rewrites the RELATIVE half: if the
        // project_id ends in `.git` (the git-repo common-dir form), the relative
        // path is the project_path with the repo root stripped, i.e. ".git". For a
        // plain path the relative half is the full normalized path. This makes the
        // `git_project_id` corpus row agree with Rust (source ".../.git|.git").
        let normalized = PathNormalizer.normalize(path)
        let relative = relativeForWorkspaceSource(normalized)
        let source = "\(normalized)|\(relative)"
        return hash(source)
    }

    /// Mirrors Rust `workspace_relative_path` + `repo_root_from_project_id` for the
    /// `fromPath` (project_id == project_path) case: when the normalized path ends
    /// in `/.git`, the repo root is its parent and the relative segment is ".git";
    /// otherwise the relative half is the full normalized path.
    private static func relativeForWorkspaceSource(_ normalized: String) -> String {
        guard normalized.hasSuffix("/.git") else {
            return normalized
        }
        let repoRoot = String(normalized.dropLast("/.git".count))
        let prefix = repoRoot.isEmpty ? "/" : repoRoot + "/"
        if normalized.hasPrefix(prefix) {
            return String(normalized.dropFirst(prefix.count))
        }
        return normalized
    }

    private static func hash(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
