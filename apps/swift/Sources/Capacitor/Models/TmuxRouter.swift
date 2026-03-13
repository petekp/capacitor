import Foundation

struct TmuxRouter {
    typealias CommandResult = (exitCode: Int32, output: String?)

    private let runScript: (String) async -> CommandResult
    private let homeDirectoryProvider: () -> String

    init(
        runScript: @escaping (String) async -> CommandResult,
        homeDirectoryProvider: @escaping () -> String = { NSHomeDirectory() },
    ) {
        self.runScript = runScript
        self.homeDirectoryProvider = homeDirectoryProvider
    }

    func ensureSessionAndSwitch(
        sessionName: String,
        projectPath: String,
        clientTty: String,
        targetPane: String? = nil,
    ) async -> Bool {
        let escapedSession = shellEscape(sessionName)
        let escapedTty = shellEscape(clientTty)
        let switchCmd = "tmux switch-client -c \(escapedTty) -t \(escapedSession) 2>&1"

        let first = await runScript(switchCmd)
        if first.exitCode == 0 {
            return await selectPaneIfNeeded(targetPane)
        }

        let escapedPath = shellEscape(projectPath)
        let createResult = await runScript(
            "tmux new-session -d -s \(escapedSession) -c \(escapedPath) 2>&1",
        )
        guard createResult.exitCode == 0 else {
            return false
        }

        let retry = await runScript(switchCmd)
        guard retry.exitCode == 0 else {
            return false
        }

        return await selectPaneIfNeeded(targetPane)
    }

    func resolveAnyClientTty(
        preferredHostTty: String? = nil,
        targetSession: String? = nil,
    ) async -> String? {
        let normalizedPreferredHostTty: String? = {
            guard let value = preferredHostTty?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return nil
            }
            return value
        }()

        let currentClient = await runScript("tmux display-message -p '#{client_tty}' 2>/dev/null")
        if currentClient.exitCode == 0,
           let output = currentClient.output?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty
        {
            return output
        }

        let clients = await runScript("tmux list-clients -F '#{client_tty} #{session_name}' 2>/dev/null")
        guard clients.exitCode == 0,
              let output = clients.output
        else {
            return nil
        }

        var firstTty: String?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1)
            let tty = String(parts[0])
            let session = parts.count > 1 ? String(parts[1]) : nil

            if firstTty == nil {
                firstTty = tty
            }

            if let normalizedPreferredHostTty, tty == normalizedPreferredHostTty {
                return tty
            }

            if let targetSession, let session, session == targetSession {
                return tty
            }
        }

        return firstTty
    }

    func findSessionForPath(_ projectPath: String) async -> String? {
        let result = await runScript("tmux list-panes -a -F '#{session_name}\t#{pane_current_path}' 2>/dev/null")
        guard result.exitCode == 0,
              let output = result.output
        else {
            return nil
        }

        return Self.bestSessionForPath(
            output: output,
            projectPath: projectPath,
            homeDirectory: homeDirectoryProvider(),
        )
    }

    func pollForNewClient(
        maxAttempts: Int = 20,
        intervalNanoseconds: UInt64 = 500_000_000,
    ) async -> String? {
        for attempt in 0 ..< maxAttempts {
            guard !_Concurrency.Task.isCancelled else {
                DebugLog.write("[TmuxRouter] pollForNewClient cancelled attempt=\(attempt)")
                return nil
            }
            do {
                try await _Concurrency.Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                DebugLog.write("[TmuxRouter] pollForNewClient cancelled during sleep attempt=\(attempt)")
                return nil
            }

            let result = await runScript("tmux list-clients -F '#{client_tty}' 2>/dev/null")
            if result.exitCode == 0,
               let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty
            {
                return output.split(separator: "\n").first.map(String.init)
            }
        }

        DebugLog.write("[TmuxRouter] pollForNewClient timed out")
        return nil
    }

    static func makeAttachCommand(session: String, projectPath: String?) -> String {
        let escapedSession = shellEscape(session)
        if let projectPath {
            return "tmux new-session -A -s \(escapedSession) -c \(shellEscape(projectPath))"
        }
        return "tmux new-session -A -s \(escapedSession)"
    }

    static func bestSessionForPath(output: String, projectPath: String, homeDirectory: String) -> String? {
        func normalizePath(_ path: String) -> String {
            if path == "/" { return "/" }
            var normalized = path
            while normalized.hasSuffix("/"), normalized != "/" {
                normalized.removeLast()
            }
            return normalized.lowercased()
        }

        func managedWorktreeRoot(_ path: String) -> String? {
            let marker = "/.capacitor/worktrees/"
            guard let markerRange = path.range(of: marker) else { return nil }
            let worktreeNameStart = markerRange.upperBound
            guard worktreeNameStart < path.endIndex else { return nil }

            let suffix = path[worktreeNameStart...]
            guard let nextSlash = suffix.firstIndex(of: "/") else {
                return path
            }

            return String(path[..<nextSlash])
        }

        func isWithinPath(_ candidate: String, root: String) -> Bool {
            candidate == root || candidate.hasPrefix(root + "/")
        }

        func matchRank(shellPath: String, projectPath: String, homeDir: String) -> Int? {
            if shellPath == projectPath {
                return 2
            }

            let (shorter, longer) = shellPath.count < projectPath.count
                ? (shellPath, projectPath)
                : (projectPath, shellPath)

            if shorter == homeDir {
                return nil
            }

            guard longer.hasPrefix(shorter + "/") else { return nil }
            return shorter == projectPath ? 1 : 0
        }

        let normalizedProjectPath = normalizePath(projectPath)
        let homeDir = normalizePath(homeDirectory)
        let projectManagedRoot = managedWorktreeRoot(normalizedProjectPath)
        var bestMatch: (rank: Int, session: String)?

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let sessionName = String(parts[0])
            let panePath = normalizePath(String(parts[1]))
            let paneManagedRoot = managedWorktreeRoot(panePath)

            if let projectManagedRoot {
                if paneManagedRoot != projectManagedRoot || !isWithinPath(panePath, root: projectManagedRoot) {
                    continue
                }
            } else if paneManagedRoot != nil {
                continue
            }

            guard let rank = matchRank(
                shellPath: panePath,
                projectPath: normalizedProjectPath,
                homeDir: homeDir,
            ) else {
                continue
            }

            if bestMatch == nil || rank > bestMatch!.rank {
                bestMatch = (rank, sessionName)
                if rank == 2 {
                    break
                }
            }
        }

        return bestMatch?.session
    }

    private func selectPaneIfNeeded(_ targetPane: String?) async -> Bool {
        guard let targetPane = targetPane?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !targetPane.isEmpty
        else {
            return true
        }

        let escapedPane = shellEscape(targetPane)
        let selectWindow = await runScript("tmux select-window -t \(escapedPane) 2>&1")
        guard selectWindow.exitCode == 0 else {
            DebugLog.write("[TmuxRouter] stale pane during select-window pane=\(targetPane)")
            return true
        }

        let selectPane = await runScript("tmux select-pane -t \(escapedPane) 2>&1")
        guard selectPane.exitCode == 0 else {
            DebugLog.write("[TmuxRouter] stale pane during select-pane pane=\(targetPane)")
            return true
        }

        return true
    }
}
