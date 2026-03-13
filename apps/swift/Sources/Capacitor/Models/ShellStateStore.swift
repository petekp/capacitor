import Foundation
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "ShellStateStore")

struct ShellEntry: Codable, Equatable {
    let cwd: String
    let tty: String
    let parentApp: String?
    let tmuxSession: String?
    let tmuxClientTty: String?
    let tmuxPane: String?
    let updatedAt: Date

    init(
        cwd: String,
        tty: String,
        parentApp: String?,
        tmuxSession: String?,
        tmuxClientTty: String?,
        tmuxPane: String? = nil,
        updatedAt: Date,
    ) {
        self.cwd = cwd
        self.tty = tty
        self.parentApp = parentApp
        self.tmuxSession = tmuxSession
        self.tmuxClientTty = tmuxClientTty
        self.tmuxPane = tmuxPane
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case cwd, tty
        case parentApp = "parent_app"
        case tmuxSession = "tmux_session"
        case tmuxClientTty = "tmux_client_tty"
        case tmuxPane = "tmux_pane"
        case updatedAt = "updated_at"
    }
}

struct ShellCwdState: Codable {
    let version: Int
    let shells: [String: ShellEntry]
}

@MainActor
@Observable
final class ShellStateStore {
    private enum Constants {
        /// Shells not updated within this threshold are considered stale and won't be used for focus detection.
        /// 10 minutes allows for typical idle periods while filtering out truly abandoned shells.
        static let shellStalenessThresholdSeconds: TimeInterval = 10 * 60
    }

    private(set) var state: ShellCwdState?

    init() {}

    func applyRuntimeShellState(_ runtimeState: ShellCwdState, correlationId: String? = nil) async {
        state = runtimeState
        let summary = runtimeState.shells.map { pid, entry in
            "\(pid) cwd=\(entry.cwd) tty=\(entry.tty) updated=\(entry.updatedAt)"
        }
        .sorted()
        .joined(separator: " | ")
        logger.info("Shell state updated: shells=\(runtimeState.shells.count) summary=\(summary, privacy: .public)")
        let cid = correlationId ?? "none"
        DebugLog.write(
            "ShellStateStore.applyRuntimeShellState cid=\(cid) shells=\(runtimeState.shells.count) summary=\(summary)",
        )
        let threshold = Date().addingTimeInterval(-Constants.shellStalenessThresholdSeconds)
        let staleCount = runtimeState.shells.values.count(where: { $0.updatedAt <= threshold })
        Telemetry.emit("shell_state_refresh", "Shell state updated", payload: [
            "shell_count": runtimeState.shells.count,
            "stale_filtered_count": staleCount,
        ])
    }

    func clearRuntimeShellState(correlationId: String? = nil) {
        state = nil
        let cid = correlationId ?? "none"
        logger.info("Shell state cleared")
        DebugLog.write("ShellStateStore.clearRuntimeShellState cid=\(cid)")
        Telemetry.emit("shell_state_refresh", "Shell state cleared", payload: [
            "shell_count": 0,
            "stale_filtered_count": 0,
        ])
    }
}
