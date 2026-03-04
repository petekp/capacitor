import AppKit

// MARK: - Terminal Activator Protocol

/// Focuses the correct tab/session within an already-activated terminal app.
/// Each terminal requires a different automation channel:
///   - Ghostty: AX (no AppleScript dictionary)
///   - iTerm2: AppleScript (AX doesn't expose individual tabs)
///   - Terminal.app: AppleScript (TTY-based tab matching)
@MainActor
protocol TerminalActivator {
    /// The display name of the terminal app (e.g., "Ghostty", "iTerm2", "Terminal").
    var appName: String { get }

    /// The bundle identifier used for process lookup (e.g., "com.mitchellh.ghostty").
    var bundleId: String { get }

    /// Focus the tab/session matching the given context.
    /// Returns true if the terminal was successfully focused (including fallback activation),
    /// false only when the terminal is unreachable or the TTY is stale (triggering relaunch).
    func focusSession(sessionName: String, projectPath: String, tty: String?) async -> Bool
}

// MARK: - Factory

enum TerminalActivatorFactory {
    /// Returns an activator for the given ParentApp, or nil for unsupported terminals.
    @MainActor
    static func activator(for parentApp: ParentApp) -> (any TerminalActivator)? {
        switch parentApp {
        case .ghostty: GhosttyActivator()
        case .iTerm: ITermActivator()
        case .terminal: TerminalAppActivator()
        default: nil // Unsupported terminal — app-level activation only
        }
    }

    /// Bundle IDs for supported terminals, used for NSWorkspace detection fallback.
    static let knownBundleIds: [(bundleId: String, parentApp: ParentApp)] = [
        ("com.mitchellh.ghostty", .ghostty),
        ("com.googlecode.iterm2", .iTerm),
        ("com.apple.Terminal", .terminal),
    ]

    /// Detect the frontmost supported terminal from running applications.
    @MainActor
    static func detectFromRunningApps() -> (any TerminalActivator)? {
        for (bundleId, parentApp) in knownBundleIds {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleId }) {
                return activator(for: parentApp)
            }
        }
        return nil
    }

    /// Known terminal app names and their install paths, in priority order.
    private static let knownAppPaths: [(app: String, path: String)] = [
        ("Ghostty", "/Applications/Ghostty.app"),
        ("iTerm2", "/Applications/iTerm.app"),
        ("Terminal", "/Applications/Utilities/Terminal.app"),
    ]

    /// Detect the best terminal app name from what's installed, in priority order.
    static func detectTerminalAppName() -> String {
        for (app, path) in knownAppPaths {
            if FileManager.default.fileExists(atPath: path) {
                return app
            }
        }
        return "Terminal" // macOS always has Terminal.app
    }
}

// MARK: - Universal Activation Helpers

/// Shared utilities for terminal activation that work identically across all terminals.
enum TerminalActivation {
    /// Check if an app with the given bundle ID is currently running.
    static func isRunning(bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleId
        }
    }

    /// Activate (bring to front) the app with the given bundle ID.
    /// Uses NSRunningApplication.activate() which is ~5ms vs 300-2100ms for AppleScript.
    @discardableResult
    static func activateApp(bundleId: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleId
        }) else {
            return false
        }

        if #available(macOS 14.0, *) {
            return app.activate()
        } else {
            return app.activate(options: .activateIgnoringOtherApps)
        }
    }
}
