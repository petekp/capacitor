import AppKit
import Foundation

enum SupportedTerminalApp: CaseIterable, Equatable {
    case ghostty
    case iTerm
    case terminal

    var processName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .iTerm: "iTerm2"
        case .terminal: "Terminal"
        }
    }

    var bundleId: String {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"
        case .iTerm: "com.googlecode.iterm2"
        case .terminal: "com.apple.Terminal"
        }
    }

    static func from(parentApp: String?) -> SupportedTerminalApp? {
        guard let normalized = parentApp?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else {
            return nil
        }

        switch normalized {
        case "ghostty":
            return .ghostty
        case "iterm", "iterm2":
            return .iTerm
        case "terminal", "terminal.app":
            return .terminal
        default:
            return nil
        }
    }

    static func detectAvailable() -> SupportedTerminalApp {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            SupportedTerminalApp.allCases.first(where: { $0.bundleId == app.bundleIdentifier })
        }
        if let running = runningApps.first {
            return running
        }
        if FileManager.default.fileExists(atPath: "/Applications/Ghostty.app") {
            return .ghostty
        }
        if FileManager.default.fileExists(atPath: "/Applications/iTerm.app") {
            return .iTerm
        }
        return .terminal
    }
}
