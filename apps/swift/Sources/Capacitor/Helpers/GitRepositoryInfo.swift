import Foundation

struct GitRepositoryInfo {
    let repoRoot: String
    let commonDir: String?
    let relativePath: String

    static func resolve(for path: String) -> GitRepositoryInfo? {
        let fsPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let repoRootUrl = findRepoRoot(startingAt: fsPath) else {
            return nil
        }

        let repoRootNormalized = PathNormalizer.normalize(repoRootUrl.path)
        let commonDirNormalized = resolveCommonDir(repoRootUrl: repoRootUrl)
            .map { PathNormalizer.normalize($0.path) }
        let normalizedPath = PathNormalizer.normalize(path)
        guard let relativePath = relativePath(from: repoRootNormalized, to: normalizedPath) else {
            return nil
        }

        return GitRepositoryInfo(
            repoRoot: repoRootNormalized,
            commonDir: commonDirNormalized,
            relativePath: relativePath,
        )
    }

    private static func findRepoRoot(startingAt path: String) -> URL? {
        var current = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: current.path, isDirectory: &isDir) || !isDir.boolValue {
            current.deleteLastPathComponent()
        }

        while true {
            // Avoid URL.appendingPathComponent(_:) which can hit the filesystem
            // to infer directory-ness and can become extremely slow for non-existent paths.
            let gitEntry = current.appendingPathComponent(".git", isDirectory: false)
            if FileManager.default.fileExists(atPath: gitEntry.path) {
                return current
            }
            // URL.deletingLastPathComponent() returns "/.." for "/", so we must explicitly stop at root.
            // (See: URL(fileURLWithPath: "/").deletingLastPathComponent().path)
            if current.path == "/" {
                return nil
            }
            current.deleteLastPathComponent()
        }
    }

    private static func resolveCommonDir(repoRootUrl: URL) -> URL? {
        let gitEntry = repoRootUrl.appendingPathComponent(".git", isDirectory: false)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitEntry.path, isDirectory: &isDir) else {
            return nil
        }

        if isDir.boolValue {
            return gitEntry
        }

        guard let gitDir = parseGitdir(from: gitEntry, repoRoot: repoRootUrl) else {
            return nil
        }

        let commondirFile = gitDir.appendingPathComponent("commondir")
        if FileManager.default.fileExists(atPath: commondirFile.path),
           let commondirRaw = try? String(contentsOf: commondirFile, encoding: .utf8)
        {
            let trimmed = commondirRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return resolveGitPath(base: gitDir, raw: trimmed)
            }
        }

        return gitDir
    }

    private static func parseGitdir(from gitFile: URL, repoRoot: URL) -> URL? {
        guard let contents = try? String(contentsOf: gitFile, encoding: .utf8) else {
            return nil
        }

        guard let line = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.lowercased().hasPrefix("gitdir:") })
        else {
            return nil
        }

        let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty else { return nil }
        return resolveGitPath(base: repoRoot, raw: String(rawPath))
    }

    private static func resolveGitPath(base: URL, raw: String) -> URL {
        URL(fileURLWithPath: raw, relativeTo: base).standardizedFileURL
    }

    private static func relativePath(from root: String, to path: String) -> String? {
        if root == path {
            return ""
        }
        let prefix = root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
