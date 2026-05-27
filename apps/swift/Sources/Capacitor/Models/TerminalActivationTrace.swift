import Foundation

enum TerminalActivationTrace {
    enum Surface: String {
        case projectCard = "project_card"
        case workBatchCard = "work_batch_card"
        case checkpointRow = "checkpoint_row"
        case terminalIcon = "terminal_icon"
        case activityPanel = "activity_panel"
        case dockCard = "dock_card"
        case activationFlow = "activation_flow"
        case directFocus = "direct_focus"
        case workBatchSession = "work_batch_session"
    }

    static func log(
        surface: Surface,
        route: String,
        projectPath: String? = nil,
        projectName: String? = nil,
        batchID: String? = nil,
        batchName: String? = nil,
        sessionName: String? = nil,
        evidence: [String] = [],
        action: String,
        outcome: String,
        reason: String? = nil,
    ) {
        var fields: [(String, String)] = [
            ("surface", surface.rawValue),
            ("route", route),
            ("action", action),
            ("outcome", outcome),
        ]

        if let projectPath {
            fields.append(("project_path", projectPath))
        }
        if let projectName {
            fields.append(("project", projectName))
        }
        if let batchID {
            fields.append(("batch_id", batchID))
        }
        if let batchName {
            fields.append(("batch", batchName))
        }
        if let sessionName {
            fields.append(("session", sessionName))
        }
        if !evidence.isEmpty {
            fields.append(("evidence", evidence.joined(separator: ",")))
        }
        if let reason {
            fields.append(("reason", reason))
        }

        DebugLog.write("[TerminalActivation] \(fields.map(formatField).joined(separator: " "))")
    }

    private static func formatField(_ field: (String, String)) -> String {
        "\(field.0)=\"\(escaped(field.1))\""
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

extension TerminalActivationCoordinator.TerminalFocusResult {
    var traceOutcome: String {
        switch self {
        case .focused:
            "focused"
        case .alreadySelected:
            "already_selected"
        case .relaunchNeeded:
            "relaunch_needed"
        case .failed:
            "failed"
        }
    }

    var traceFailureReason: String? {
        switch self {
        case let .failed(reason):
            reason.map { String(describing: $0) } ?? "unknown"
        case .focused, .alreadySelected, .relaunchNeeded:
            nil
        }
    }
}
