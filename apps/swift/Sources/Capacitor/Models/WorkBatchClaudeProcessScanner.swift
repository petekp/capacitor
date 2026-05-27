import Foundation

struct LiveClaudeProjectProcessEvidence: Equatable {
    let processCount: Int
    let sessionIDs: [String]

    var hasLiveProcess: Bool {
        processCount > 0
    }

    var firstSessionID: String? {
        sessionIDs.first
    }
}

struct WorkBatchClaudeProcessScanner {
    struct ProcessRecord: Equatable {
        let pid: Int32
        let command: String
        let cwd: String?

        var sessionID: String? {
            Self.extractSessionID(from: command)
        }

        private static func extractSessionID(from command: String) -> String? {
            for flag in ["--session-id", "--resume"] {
                if let value = argumentValue(after: flag, in: command) {
                    return value
                }
            }
            return nil
        }

        private static func argumentValue(after flag: String, in command: String) -> String? {
            let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let index = parts.firstIndex(of: flag),
                  parts.indices.contains(index + 1)
            else {
                return nil
            }
            return parts[index + 1]
        }
    }

    typealias ProcessListProvider = () -> [ProcessRecord]

    private let processListProvider: ProcessListProvider

    init(processListProvider: ProcessListProvider? = nil) {
        self.processListProvider = processListProvider ?? Self.readClaudeProcesses
    }

    func sessionIDs(inWorktree worktreePath: String) -> [String] {
        processListProvider().compactMap { process in
            guard Self.commandLooksLikeClaude(process.command),
                  let sessionID = process.sessionID,
                  let cwd = process.cwd,
                  Self.pathIsInside(cwd, root: worktreePath)
            else {
                return nil
            }
            return sessionID
        }
    }

    func processEvidenceByProjectPath(for projects: [Project]) -> [String: LiveClaudeProjectProcessEvidence] {
        let candidates = projects.compactMap { project -> (path: String, normalizedPath: String, depth: Int)? in
            let normalizedPath = PathNormalizer.normalize(project.path)
            guard !normalizedPath.isEmpty, normalizedPath != "/" else { return nil }
            return (
                path: project.path,
                normalizedPath: normalizedPath,
                depth: normalizedPath.split(separator: "/").count,
            )
        }

        var processCounts: [String: Int] = [:]
        var sessionIDsByProject: [String: [String]] = [:]

        for process in processListProvider() {
            guard Self.commandLooksLikeClaude(process.command),
                  let cwd = process.cwd,
                  let projectPath = Self.deepestProjectPath(containing: cwd, in: candidates)
            else {
                continue
            }

            processCounts[projectPath, default: 0] += 1
            if let sessionID = process.sessionID {
                sessionIDsByProject[projectPath, default: []].append(sessionID)
            }
        }

        var result: [String: LiveClaudeProjectProcessEvidence] = [:]
        for (projectPath, count) in processCounts {
            result[projectPath] = LiveClaudeProjectProcessEvidence(
                processCount: count,
                sessionIDs: sessionIDsByProject[projectPath, default: []],
            )
        }
        return result
    }

    private static func readClaudeProcesses() -> [ProcessRecord] {
        let processLines = runProcess(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,command="],
        )
        return processLines.compactMap(parseProcessLine).compactMap { parsed in
            let (pid, command) = parsed
            guard commandLooksLikeClaude(command) else {
                return nil
            }
            return ProcessRecord(
                pid: pid,
                command: command,
                cwd: cwd(for: pid),
            )
        }
    }

    private static func parseProcessLine(_ line: String) -> (Int32, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              let pid = Int32(parts[0])
        else {
            return nil
        }
        return (pid, String(parts[1]))
    }

    private static func commandLooksLikeClaude(_ command: String) -> Bool {
        let firstToken = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return firstToken == "claude" || firstToken.hasSuffix("/claude")
    }

    private static func deepestProjectPath(
        containing cwd: String,
        in candidates: [(path: String, normalizedPath: String, depth: Int)],
    ) -> String? {
        let normalizedCwd = PathNormalizer.normalize(cwd)
        return candidates
            .filter { pathIsInside(normalizedCwd, root: $0.normalizedPath) }
            .max { lhs, rhs in
                if lhs.depth == rhs.depth {
                    return lhs.normalizedPath < rhs.normalizedPath
                }
                return lhs.depth < rhs.depth
            }?
            .path
    }

    private static func cwd(for pid: Int32) -> String? {
        let lines = runProcess(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
        )
        return lines
            .first(where: { $0.hasPrefix("n") })
            .map { String($0.dropFirst()) }
    }

    private static func runProcess(executablePath: String, arguments: [String]) -> [String] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return []
        }
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        let normalizedPath = PathNormalizer.normalize(path)
        let normalizedRoot = PathNormalizer.normalize(root)
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }
}
