import Foundation

struct WorktreeService {
    struct Worktree: Equatable {
        let path: String
        let branchRef: String?
        let head: String?
        let isDetached: Bool
        let isLocked: Bool
        let isPrunable: Bool

        var name: String {
            URL(fileURLWithPath: path).lastPathComponent
        }
    }

    struct GitCommandResult: Equatable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidWorktreeName(String)
        case dirtyWorktree(path: String)
        case activeSessionWorktree(path: String)
        case lockedWorktree(path: String, message: String)
        case gitCommandFailed(arguments: [String], exitCode: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case let .invalidWorktreeName(name):
                return "Invalid worktree name: \(name)"
            case let .dirtyWorktree(path):
                return "Cannot remove dirty worktree at \(path)"
            case let .activeSessionWorktree(path):
                return "Cannot remove worktree with active session at \(path)"
            case let .lockedWorktree(path, message):
                if message.isEmpty {
                    return "Cannot remove locked worktree at \(path)"
                }
                return "Cannot remove locked worktree at \(path): \(message)"
            case let .gitCommandFailed(arguments, exitCode, output):
                let command = (["git"] + arguments).joined(separator: " ")
                if output.isEmpty {
                    return "Command failed (\(exitCode)): \(command)"
                }
                return "Command failed (\(exitCode)): \(command)\n\(output)"
            }
        }
    }

    typealias GitRunner = (_ arguments: [String], _ cwd: String) -> GitCommandResult

    private let fileManager: FileManager
    private let runGit: GitRunner

    init(fileManager: FileManager = .default, runGit: @escaping GitRunner = Self.systemRunGit) {
        self.fileManager = fileManager
        self.runGit = runGit
    }

    static func parseWorktreeListPorcelain(_ output: String) -> [Worktree] {
        struct Builder {
            var path: String?
            var branchRef: String?
            var head: String?
            var isDetached = false
            var isLocked = false
            var isPrunable = false
        }

        var parsed: [Worktree] = []
        var current = Builder()

        func finishCurrent() {
            guard let path = current.path else { return }
            parsed.append(
                Worktree(
                    path: PathNormalizer.normalize(path),
                    branchRef: current.branchRef,
                    head: current.head,
                    isDetached: current.isDetached,
                    isLocked: current.isLocked,
                    isPrunable: current.isPrunable,
                ),
            )
            current = Builder()
        }

        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for rawLine in lines {
            let line = String(rawLine)
            if line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                finishCurrent()
                continue
            }

            if line.hasPrefix("worktree ") {
                finishCurrent()
                current.path = String(line.dropFirst("worktree ".count))
                continue
            }

            if line.hasPrefix("HEAD ") {
                current.head = String(line.dropFirst("HEAD ".count))
                continue
            }

            if line.hasPrefix("branch ") {
                current.branchRef = String(line.dropFirst("branch ".count))
                continue
            }

            if line == "detached" {
                current.isDetached = true
                continue
            }

            if line.hasPrefix("locked") {
                current.isLocked = true
                continue
            }

            if line.hasPrefix("prunable") {
                current.isPrunable = true
                continue
            }
        }

        finishCurrent()
        return parsed
    }

    func listManagedWorktrees(in repoPath: String) throws -> [Worktree] {
        try pruneWorktrees(in: repoPath)

        let listArgs = ["worktree", "list", "--porcelain"]
        let result = runGit(listArgs, repoPath)
        try ensureGitSuccess(result, arguments: listArgs)

        let managedRoot = Self.managedRootPath(in: repoPath)
        return Self.parseWorktreeListPorcelain(result.stdout)
            .filter { Self.isManagedPath($0.path, managedRoot: managedRoot) }
            .sorted { $0.name < $1.name }
    }

    func createManagedWorktree(in repoPath: String, name: String) throws -> Worktree {
        try validateWorktreeName(name)

        let managedRootURL = URL(fileURLWithPath: repoPath)
            .appendingPathComponent(".capacitor/worktrees", isDirectory: true)
        try fileManager.createDirectory(at: managedRootURL, withIntermediateDirectories: true)

        let relativePath = ".capacitor/worktrees/\(name)"
        let arguments = ["worktree", "add", relativePath, "-b", name]
        let result = runGit(arguments, repoPath)
        try ensureGitSuccess(result, arguments: arguments)

        let fullPath = managedRootURL.appendingPathComponent(name, isDirectory: true).path
        return Worktree(
            path: PathNormalizer.normalize(fullPath),
            branchRef: "refs/heads/\(name)",
            head: nil,
            isDetached: false,
            isLocked: false,
            isPrunable: false,
        )
    }

    func removeManagedWorktree(
        in repoPath: String,
        name: String,
        force: Bool = false,
        activeWorktreePaths: Set<String> = [],
    ) throws {
        try validateWorktreeName(name)
        let worktreePath = managedWorktreePath(in: repoPath, name: name)

        if !force {
            let activePaths = Set(activeWorktreePaths.map(PathNormalizer.normalize))
            if activePaths.contains(where: { path in
                path == worktreePath || path.hasPrefix(worktreePath + "/")
            }) {
                throw Error.activeSessionWorktree(path: worktreePath)
            }
        }

        try pruneWorktrees(in: repoPath)

        if !force {
            let statusResult = runGit(["status", "--porcelain"], worktreePath)
            try ensureGitSuccess(statusResult, arguments: ["status", "--porcelain"])
            if !statusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Error.dirtyWorktree(path: worktreePath)
            }
        }

        var arguments = ["worktree", "remove"]
        if force {
            arguments.append("--force")
        }
        arguments.append(".capacitor/worktrees/\(name)")

        let result = runGit(arguments, repoPath)
        do {
            try ensureGitSuccess(result, arguments: arguments)
        } catch let error as Error {
            if case let .gitCommandFailed(_, _, output) = error,
               output.lowercased().contains("locked")
            {
                throw Error.lockedWorktree(path: worktreePath, message: output)
            }
            throw error
        }
    }

    private static func managedRootPath(in repoPath: String) -> String {
        let path = URL(fileURLWithPath: repoPath)
            .appendingPathComponent(".capacitor/worktrees", isDirectory: true)
            .path
        return PathNormalizer.normalize(path)
    }

    private static func isManagedPath(_ path: String, managedRoot: String) -> Bool {
        path == managedRoot || path.hasPrefix(managedRoot + "/")
    }

    private func managedWorktreePath(in repoPath: String, name: String) -> String {
        let path = URL(fileURLWithPath: repoPath)
            .appendingPathComponent(".capacitor/worktrees", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .path
        return PathNormalizer.normalize(path)
    }

    private func validateWorktreeName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("/") || trimmed.contains("..") {
            throw Error.invalidWorktreeName(name)
        }
    }

    private func pruneWorktrees(in repoPath: String) throws {
        let pruneArgs = ["worktree", "prune"]
        let pruneResult = runGit(pruneArgs, repoPath)
        try ensureGitSuccess(pruneResult, arguments: pruneArgs)
    }

    private func ensureGitSuccess(_ result: GitCommandResult, arguments: [String]) throws {
        guard result.exitCode == 0 else {
            let output = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.gitCommandFailed(arguments: arguments, exitCode: result.exitCode, output: output)
        }
    }

    private static func systemRunGit(arguments: [String], cwd: String) -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return GitCommandResult(
                exitCode: 1,
                stdout: "",
                stderr: error.localizedDescription,
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return GitCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
        )
    }
}
