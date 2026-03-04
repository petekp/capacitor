import AppKit
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "TerminalAppActivator")

private func debugLog(_ message: String) {
    DebugLog.write("[TerminalAppActivator] \(message)")
}

/// Terminal.app-specific activation via in-process AppleScript.
/// Enumerates windows/tabs, matches by TTY, and selects the target tab.
@MainActor
struct TerminalAppActivator: TerminalActivator {
    let appName = "Terminal"
    let bundleId = "com.apple.Terminal"

    func focusSession(sessionName _: String, projectPath _: String, tty: String?) async -> Bool {
        guard TerminalActivation.isRunning(bundleId: bundleId) else {
            debugLog("focusSession: Terminal.app not running")
            return false
        }

        // Try TTY-based matching first (most precise)
        if let tty, !tty.isEmpty, await focusByTty(tty) {
            debugLog("focusSession: matched by TTY=\(tty)")
            return true
        }

        // Fallback: activate app generically
        debugLog("focusSession: no TTY match, falling back to app activation")
        return TerminalActivation.activateApp(bundleId: bundleId)
    }

    /// Use in-process NSAppleScript to find and select the Terminal.app tab matching the given TTY.
    private func focusByTty(_ tty: String) async -> Bool {
        // Terminal.app AppleScript model: Application > Windows > Tabs
        // Each tab has a `tty` property (e.g., "/dev/ttys003").
        let source = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escapeForAppleScript(tty))" then
                        set selected tab of w to t
                        set index of w to 1
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """

        return runInProcessAppleScript(source)
    }

    /// Run AppleScript in-process via NSAppleScript (20-30ms faster than osascript subprocess).
    private func runInProcessAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)

        if let error {
            let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            logger.warning("AppleScript failed: \(errorMsg)")
            debugLog("runInProcessAppleScript failed: \(errorMsg)")
            return false
        }

        return result?.booleanValue ?? false
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
