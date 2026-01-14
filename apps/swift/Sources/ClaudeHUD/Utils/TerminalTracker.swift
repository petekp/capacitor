import AppKit
import Foundation

// MARK: - Types

/// Represents a tmux client with its process ID and active session
private struct TmuxClient {
    let pid: Int
    let sessionName: String
}

// MARK: - TerminalTracker

/// Tracks which terminal window/tmux session is currently focused and maps it to a project path.
///
/// This actor provides thread-safe polling of terminal state at 500ms intervals.
/// It detects which terminal application is frontmost, queries tmux for active sessions,
/// and intelligently matches tmux clients to the focused terminal's process tree.
actor TerminalTracker {

    // MARK: - Constants

    private enum Constants {
        static let pollingIntervalNanoseconds: UInt64 = 500_000_000 // 500ms

        /// Known terminal applications with their bundle identifiers
        static let terminalBundleIds: [String: String] = [
            "Ghostty": "com.mitchellh.ghostty",
            "iTerm2": "com.googlecode.iterm2",
            "Terminal": "com.apple.Terminal",
            "Alacritty": "org.alacritty",
            "kitty": "net.kovidgoyal.kitty",
            "WarpTerminal": "dev.warp.Warp-Stable"
        ]
    }

    // MARK: - State

    private var activeProjectPath: String?
    private var pollingTask: _Concurrency.Task<Void, Never>?
    private var projectsByName: [String: String] = [:]

    // MARK: - Public API

    /// Starts tracking terminal focus and tmux sessions with periodic polling.
    func startTracking(projects: [Project]) {
        updateProjectMapping(projects)
        pollingTask = createPollingTask()
    }

    /// Stops tracking and cancels the polling task.
    func stopTracking() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Updates the internal project name → path mapping.
    func updateProjectMapping(_ projects: [Project]) {
        projectsByName = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.name, $0.path) }
        )
    }

    /// Returns the currently active project path, if any.
    func getActiveProjectPath() -> String? {
        activeProjectPath
    }

    // MARK: - Polling

    private func createPollingTask() -> _Concurrency.Task<Void, Never> {
        _Concurrency.Task {
            while !_Concurrency.Task.isCancelled {
                await detectActiveProject()
                try? await _Concurrency.Task.sleep(nanoseconds: Constants.pollingIntervalNanoseconds)
            }
        }
    }

    // MARK: - Detection Logic

    /// Detects the active project based on frontmost terminal and tmux session.
    ///
    /// Detection flow:
    /// 1. Check if a terminal app is frontmost
    /// 2. Query tmux for active session name
    /// 3. Map session name to project path
    private func detectActiveProject() async {
        guard isFrontmostAppATerminal(),
              let sessionName = await getActiveTmuxSession() else {
            activeProjectPath = nil
            return
        }

        activeProjectPath = projectsByName[sessionName]
    }

    /// Checks if the frontmost application is a known terminal.
    private func isFrontmostAppATerminal() -> Bool {
        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Constants.terminalBundleIds.values.contains(bundleId)
    }

    /// Queries tmux for the active session in the focused terminal.
    ///
    /// For single tmux clients, returns that session immediately.
    /// For multiple clients, matches the client to the frontmost terminal's process tree.
    private func getActiveTmuxSession() async -> String? {
        guard let clients = await fetchTmuxClients(), !clients.isEmpty else {
            return nil
        }

        // Fast path: single client
        if clients.count == 1 {
            return clients[0].sessionName
        }

        // Multiple clients: find which belongs to frontmost terminal
        return await findSessionInFrontmostTerminal(clients: clients)
    }

    /// Fetches all tmux clients with their PIDs and session names.
    private func fetchTmuxClients() async -> [TmuxClient]? {
        guard let output = await runShellCommand("tmux list-clients -F '#{client_pid}:#{session_name}' 2>/dev/null"),
              !output.isEmpty else {
            return nil
        }

        return output
            .split(separator: "\n")
            .compactMap(parseTmuxClientLine)
    }

    /// Parses a single line from tmux list-clients output.
    ///
    /// Expected format: "PID:session_name"
    private func parseTmuxClientLine(_ line: Substring) -> TmuxClient? {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let pid = Int(parts[0]) else {
            return nil
        }
        return TmuxClient(pid: pid, sessionName: String(parts[1]))
    }

    /// Finds which tmux client belongs to the frontmost terminal by matching process trees.
    private func findSessionInFrontmostTerminal(clients: [TmuxClient]) async -> String? {
        guard let terminalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return clients.first?.sessionName
        }

        let childPIDs = await getChildProcesses(of: terminalPID)

        // Find client whose PID is in the terminal's process tree
        for client in clients {
            if childPIDs.contains(Int32(client.pid)) {
                return client.sessionName
            }
        }

        return clients.first?.sessionName
    }

    // MARK: - Process Tree

    /// Recursively gets all child process PIDs of a given parent.
    ///
    /// Uses `ps` to find direct children, then recursively traverses to build complete tree.
    private func getChildProcesses(of parentPID: pid_t) async -> Set<pid_t> {
        let command = "ps -A -o pid,ppid | awk '{if ($2 == \(parentPID)) print $1}'"
        guard let output = await runShellCommand(command) else {
            return []
        }

        let directChildren = output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        var result = Set<pid_t>()
        for child in directChildren {
            result.insert(child)
            // Recursively collect grandchildren
            let descendants = await getChildProcesses(of: child)
            result.formUnion(descendants)
        }

        return result
    }

    // MARK: - Shell Execution

    /// Executes a shell command and returns its output, if successful.
    private func runShellCommand(_ command: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
