import AppKit
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "ITermActivator")

private func debugLog(_ message: String) {
    DebugLog.write("[ITermActivator] \(message)")
}

/// iTerm2-specific terminal activation via in-process AppleScript.
/// Enumerates windows/tabs/sessions, matches by TTY, and selects the target tab.
@MainActor
struct ITermActivator: TerminalActivator {
    let appName = "iTerm2"
    let bundleId = "com.googlecode.iterm2"

    func focusSession(sessionName _: String, projectPath _: String, tty: String?) async -> Bool {
        guard TerminalActivation.isRunning(bundleId: bundleId) else {
            debugLog("focusSession: iTerm2 not running")
            return false
        }

        // Try TTY-based matching first (most precise)
        if let tty, !tty.isEmpty, await focusByTty(tty) {
            debugLog("focusSession: matched by TTY=\(tty)")
            return true
        }

        // Fallback: activate app generically (brings iTerm2 to front, may show wrong tab)
        debugLog("focusSession: no TTY match, falling back to app activation")
        return TerminalActivation.activateApp(bundleId: bundleId)
    }

    /// Use in-process NSAppleScript to find and select the iTerm2 session matching the given TTY.
    private func focusByTty(_ tty: String) async -> Bool {
        // iTerm2 AppleScript model: Application > Windows > Tabs > Sessions
        // Each session has a `tty` property (e.g., "/dev/ttys003").
        let source = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escapeForAppleScript(tty))" then
                            select t
                            set index of w to 1
                            return true
                        end if
                    end repeat
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
