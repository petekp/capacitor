import AppKit
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "GhosttyActivator")

private func debugLog(_ message: String) {
    DebugLog.write("[GhosttyActivator] \(message)")
}

/// Ghostty-specific terminal activation via Accessibility (AX) APIs.
/// Delegates to GhosttyWindowReader for AX window/tab enumeration and focus.
@MainActor
struct GhosttyActivator: TerminalActivator {
    let appName = "Ghostty"
    let bundleId = "com.mitchellh.ghostty"

    private let windowReader: GhosttyWindowReader

    init(windowReader: (any GhosttyWindowReader)? = nil) {
        self.windowReader = windowReader ?? DefaultGhosttyAXReader()
    }

    func focusSession(sessionName: String, projectPath: String, tty: String?) async -> Bool {
        let resolvedTty = (tty?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let tmuxSessionHint: String? = sessionName.isEmpty ? nil : sessionName

        guard TerminalActivation.isRunning(bundleId: bundleId) else {
            logger.info("focusSession: Ghostty not running")
            debugLog("focusSession ghostty not running tty=\(resolvedTty ?? "<none>")")
            return false
        }

        // Retry-based title matching. Polls AX windows up to 5 times (200ms apart)
        // waiting for the tab title to propagate after tmux switch-client.
        let maxRetries = 5
        let retryDelayNanoseconds: UInt64 = 200_000_000 // 200ms

        for attempt in 0 ..< maxRetries {
            switch windowReader.readWindows() {
            case .unavailable:
                // Fail-open: when AX cannot be read (permissions/TCC/transient AX errors),
                // fall back to generic app activation so users can still reach Ghostty.
                logger.info("focusSession: AX unavailable, falling back to generic activation")
                debugLog("focusSession ax unavailable tty=\(resolvedTty ?? "<none>") path=\(projectPath)")
                return TerminalActivation.activateApp(bundleId: bundleId)

            case let .windows(windows):
                if windows.isEmpty {
                    if attempt < maxRetries - 1 {
                        do {
                            try await _Concurrency.Task.sleep(nanoseconds: retryDelayNanoseconds)
                        } catch {
                            return false
                        }
                        continue
                    }
                    logger.info("focusSession: no windows → returning false")
                    debugLog("focusSession windowCount=0 -> return false")
                    return false
                }

                let matchedTab = bestGhosttyTabMatch(
                    windows: windows,
                    projectPath: projectPath,
                    tmuxSessionHint: tmuxSessionHint,
                )

                let tabCount = windows.reduce(into: 0) { partialResult, window in
                    partialResult += window.tabs.count
                }

                // Proceed immediately if we matched a tab, have zero tabs
                // (stale TTY — retrying won't help), or exhausted retries.
                if matchedTab != nil || tabCount == 0 || attempt == maxRetries - 1 {
                    let allTabTitles = windows.flatMap { w in
                        w.tabs.map { t in "w\(w.index)t\(t.index)=\(t.title ?? "<nil>")" }
                    }.joined(separator: ", ")
                    let allWindowTitles = windows.map { w in "w\(w.index)=\(w.title ?? "<nil>")" }.joined(separator: ", ")
                    logger.info("focusSession: tty=\(resolvedTty ?? "<none>"), windowCount=\(windows.count), tabCount=\(tabCount)")
                    debugLog(
                        "focusSession tty=\(resolvedTty ?? "<none>") windowCount=\(windows.count) tabCount=\(tabCount) path=\(projectPath) sessionHint=\(tmuxSessionHint ?? "<none>") matchedTabIndex=\(matchedTab?.tab.index.description ?? "<none>") matchedTabTitle=\(matchedTab?.tab.title ?? "<none>") tabs=[\(allTabTitles)] windowTitles=[\(allWindowTitles)]",
                    )

                    if let route = Self.resolveAXRouting(
                        windows: windows,
                        projectPath: projectPath,
                        tmuxSessionHint: tmuxSessionHint,
                        windowReader: windowReader,
                    ) {
                        logger.info("focusSession: resolved route=\(route.rawValue)")
                        debugLog("focusSession route=\(route.rawValue) matchedTab=\(matchedTab?.tab.title ?? "<none>")")

                        // If routing only achieved window_raise without matching any tab,
                        // the client TTY is likely stale (terminal tab closed but tmux
                        // client lingers). Return false so the caller falls through to
                        // launching a new tab instead of silently doing nothing.
                        if route == .windowRaise, matchedTab == nil {
                            logger.info("focusSession: window_raise with no tab match → stale TTY")
                            debugLog("focusSession stale: window_raise but no matchedTab, returning false")
                            return false
                        }

                        return true
                    }

                    logger.info("focusSession: no deterministic tab/window route → generic activation")
                    debugLog("focusSession route=app_activate_fallback")
                    return TerminalActivation.activateApp(bundleId: bundleId)
                }

                // We didn't find a matching tab, and we have retries left.
                // Wait for the tab title to propagate after tmux switch-client.
                do {
                    try await _Concurrency.Task.sleep(nanoseconds: retryDelayNanoseconds)
                } catch {
                    return false
                }
            }
        }

        return false
    }

    // MARK: - AX Routing (testable static method)

    enum AXRoutingResolution: String, Equatable {
        case tabPress = "tab_press"
        case windowRaise = "window_raise"
    }

    static func resolveAXRouting(
        windows: [GhosttyWindowSnapshot],
        projectPath: String?,
        tmuxSessionHint: String? = nil,
        windowReader: GhosttyWindowReader,
    ) -> AXRoutingResolution? {
        if let projectPath,
           let tabMatch = bestGhosttyTabMatch(
               windows: windows,
               projectPath: projectPath,
               tmuxSessionHint: tmuxSessionHint,
           )
        {
            if windowReader.focusTab(tabMatch.tab, in: tabMatch.window.element) {
                return .tabPress
            }

            if windowReader.raiseWindow(tabMatch.window.element) {
                return .windowRaise
            }
        }

        if let fallbackWindow = bestGhosttyWindowForRaise(windows: windows),
           windowReader.raiseWindow(fallbackWindow.element)
        {
            return .windowRaise
        }

        return nil
    }
}
