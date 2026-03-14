import AppKit
import Foundation

enum SupportedTerminalApp: CaseIterable, Equatable {
    case ghostty
    case iTerm
    case terminal

    private var fallbackApplicationPaths: [String] {
        let homeApplications = NSHomeDirectory() + "/Applications"

        switch self {
        case .ghostty:
            return [
                homeApplications + "/Ghostty.app",
                "/Applications/Ghostty.app",
            ]
        case .iTerm:
            return [
                homeApplications + "/iTerm.app",
                "/Applications/iTerm.app",
            ]
        case .terminal:
            return [
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Utilities/Terminal.app",
                "/Applications/Terminal.app",
            ]
        }
    }

    var processName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .iTerm: "iTerm2"
        case .terminal: "Terminal"
        }
    }

    var displayName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .iTerm: "iTerm"
        case .terminal: "Terminal.app"
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

    func applicationURL(
        runningApplicationURLsByBundleIdentifier: [String: URL] = Self.runningApplicationURLsByBundleIdentifier(),
        workspaceURLResolver: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        fileExistsAtPath: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    ) -> URL? {
        if let runningURL = runningApplicationURLsByBundleIdentifier[bundleId] {
            return runningURL
        }

        if let workspaceURL = workspaceURLResolver(bundleId) {
            return workspaceURL
        }

        for path in fallbackApplicationPaths where fileExistsAtPath(path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    static func detectAvailable(
        runningBundleIdentifiers: [String] = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier),
        installationURLResolver: (SupportedTerminalApp) -> URL? = { $0.applicationURL() },
    ) -> SupportedTerminalApp {
        for app in SupportedTerminalApp.allCases where runningBundleIdentifiers.contains(app.bundleId) {
            return app
        }

        for app in SupportedTerminalApp.allCases where installationURLResolver(app) != nil {
            return app
        }

        return .terminal
    }

    private static func runningApplicationURLsByBundleIdentifier() -> [String: URL] {
        var applicationURLs: [String: URL] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = app.bundleIdentifier,
                  let bundleURL = app.bundleURL
            else {
                continue
            }

            applicationURLs[bundleIdentifier] = bundleURL
        }

        return applicationURLs
    }
}
