import AppKit
import Foundation

enum GhosttyAppleScriptDelimiters {
    static let field = String(UnicodeScalar(31)!)
    static let row = String(UnicodeScalar(30)!)
}

enum GhosttyAutomationSupportStatus: Equatable {
    case supported(String)
    case unsupported(TerminalActivationFailureReason)
}

struct GhosttySurfaceConfigurationOptions: Equatable {
    let initialWorkingDirectory: String?
    let initialInput: String?
}

protocol GhosttyAutomationClient {
    func supportStatus() -> GhosttyAutomationSupportStatus
    func createWindow(configuration: GhosttySurfaceConfigurationOptions) -> Result<Void, TerminalActivationFailureReason>
    func createTab(inWindowID windowID: String, configuration: GhosttySurfaceConfigurationOptions) -> Result<Void, TerminalActivationFailureReason>
    func readSnapshot() -> Result<GhosttyAppSnapshot, TerminalActivationFailureReason>
    func selectTab(id: String, inWindowID windowID: String) -> Result<Void, TerminalActivationFailureReason>
    func focusTerminal(id: String) -> Result<Void, TerminalActivationFailureReason>
    func activateWindow(id: String) -> Result<Void, TerminalActivationFailureReason>
    func inputText(_ text: String, terminalID: String) -> Result<Void, TerminalActivationFailureReason>
    func sendKey(_ key: String, terminalID: String) -> Result<Void, TerminalActivationFailureReason>
}

struct GhosttyTerminalSnapshot: Equatable {
    let id: String
    let name: String?
    let workingDirectory: String?
}

struct GhosttyTabSnapshot: Equatable {
    let id: String
    let name: String?
    let index: Int
    let isSelected: Bool
    let terminals: [GhosttyTerminalSnapshot]
    let focusedTerminalID: String?
}

struct GhosttyWindowSnapshot: Equatable {
    let id: String
    let name: String?
    let isFront: Bool
    let tabs: [GhosttyTabSnapshot]
}

struct GhosttyAppSnapshot: Equatable {
    let windows: [GhosttyWindowSnapshot]
}

enum GhosttyRouteMatchSource: Equatable {
    case cachedTerminalID
    case terminalWorkingDirectory
    case terminalName
    case tabName
    case windowName
    case sessionHint
}

struct GhosttyRouteMatch: Equatable {
    let source: GhosttyRouteMatchSource
    let window: GhosttyWindowSnapshot
    let tab: GhosttyTabSnapshot?
    let terminal: GhosttyTerminalSnapshot?
}

private struct GhosttyRouteCandidate {
    let route: GhosttyRouteMatch
    let priority: Int
    let distance: Int
    let isSelected: Bool
    let isFront: Bool
    let tabIndex: Int
    let stableID: String
}

final class GhosttyAutomationSupportCache {
    static let shared = GhosttyAutomationSupportCache()

    private let lock = NSLock()
    private var cachedSupportedStatus: GhosttyAutomationSupportStatus?

    func status(resolve: () -> GhosttyAutomationSupportStatus) -> GhosttyAutomationSupportStatus {
        lock.lock()
        if let cachedSupportedStatus {
            lock.unlock()
            return cachedSupportedStatus
        }
        lock.unlock()

        let resolvedStatus = resolve()
        guard case .supported = resolvedStatus else {
            return resolvedStatus
        }

        lock.lock()
        if cachedSupportedStatus == nil {
            cachedSupportedStatus = resolvedStatus
        }
        let status = cachedSupportedStatus ?? resolvedStatus
        lock.unlock()
        return status
    }

    func clear() {
        lock.lock()
        cachedSupportedStatus = nil
        lock.unlock()
    }
}

struct DefaultGhosttyAutomationClient: GhosttyAutomationClient {
    private let appleScript: AppleScriptClient
    private let versionProvider: () -> String?
    private let supportCache: GhosttyAutomationSupportCache

    init(
        appleScript: AppleScriptClient,
        versionProvider: @escaping () -> String? = { DefaultGhosttyAutomationClient.installedGhosttyVersion() },
        supportCache: GhosttyAutomationSupportCache = .shared,
    ) {
        self.appleScript = appleScript
        self.versionProvider = versionProvider
        self.supportCache = supportCache
    }

    func supportStatus() -> GhosttyAutomationSupportStatus {
        supportCache.status {
            computeSupportStatus()
        }
    }

    private func computeSupportStatus() -> GhosttyAutomationSupportStatus {
        let version = versionProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let version, !version.isEmpty else {
            return .unsupported(.ghosttyAutomationUnavailable("Ghostty.app could not be found."))
        }

        guard version.compare("1.3.0", options: .numeric) != .orderedAscending else {
            return .unsupported(.ghosttyUnsupportedVersion(version))
        }

        let probe = appleScript.runOutput(Self.supportProbeScript)
        guard probe.success else {
            return .unsupported(.ghosttyAutomationUnavailable(Self.cleanedError(probe.error)))
        }

        return .supported(version)
    }

    func createWindow(configuration: GhosttySurfaceConfigurationOptions) -> Result<Void, TerminalActivationFailureReason> {
        runAction(Self.makeCreateWindowScript(configuration: configuration))
    }

    func createTab(inWindowID windowID: String, configuration: GhosttySurfaceConfigurationOptions) -> Result<Void, TerminalActivationFailureReason> {
        runAction(Self.makeCreateTabScript(windowID: windowID, configuration: configuration))
    }

    func readSnapshot() -> Result<GhosttyAppSnapshot, TerminalActivationFailureReason> {
        switch supportStatus() {
        case let .unsupported(reason):
            return .failure(reason)
        case .supported:
            let result = appleScript.runOutput(Self.snapshotScript)
            guard result.success else {
                return .failure(.ghosttyAutomationUnavailable(Self.cleanedError(result.error)))
            }
            return .success(Self.parseSnapshotOutput(result.output ?? ""))
        }
    }

    func selectTab(id: String, inWindowID windowID: String) -> Result<Void, TerminalActivationFailureReason> {
        runAction(Self.makeSelectTabScript(tabID: id, windowID: windowID))
    }

    func focusTerminal(id: String) -> Result<Void, TerminalActivationFailureReason> {
        runAction(Self.makeFocusTerminalScript(terminalID: id))
    }

    func activateWindow(id: String) -> Result<Void, TerminalActivationFailureReason> {
        runAction(Self.makeActivateWindowScript(windowID: id))
    }

    func inputText(_ text: String, terminalID: String) -> Result<Void, TerminalActivationFailureReason> {
        runAction(Self.makeInputTextScript(text: text, terminalID: terminalID))
    }

    func sendKey(_ key: String, terminalID: String) -> Result<Void, TerminalActivationFailureReason> {
        runAction(Self.makeSendKeyScript(key: key, terminalID: terminalID))
    }

    static func parseSnapshotOutput(_ output: String) -> GhosttyAppSnapshot {
        let fieldSeparator = GhosttyAppleScriptDelimiters.field
        let rowSeparator = GhosttyAppleScriptDelimiters.row
        let rows = output.components(separatedBy: rowSeparator).filter { !$0.isEmpty }

        struct MutableTab {
            var id: String
            var name: String?
            var index: Int
            var isSelected: Bool
            var terminals: [GhosttyTerminalSnapshot]
            var focusedTerminalID: String?
        }

        struct MutableWindow {
            var id: String
            var name: String?
            var isFront: Bool
            var tabs: [MutableTab]
        }

        var windows: [MutableWindow] = []

        for row in rows {
            var fields = row.components(separatedBy: fieldSeparator)
            while fields.count < 11 {
                fields.append("")
            }

            let windowID = fields[0]
            let windowName = nilIfEmpty(fields[1])
            let isFront = fields[2].lowercased() == "true"
            let tabID = fields[3]
            let tabName = nilIfEmpty(fields[4])
            let tabIndex = Int(fields[5]) ?? 0
            let tabSelected = fields[6].lowercased() == "true"
            let terminalID = fields[7]
            let terminalName = nilIfEmpty(fields[8])
            let terminalWorkingDirectory = nilIfEmpty(fields[9])
            let focusedTerminalID = nilIfEmpty(fields[10])

            let windowIndex: Int
            if let existingIndex = windows.firstIndex(where: { $0.id == windowID }) {
                windowIndex = existingIndex
            } else {
                windows.append(MutableWindow(
                    id: windowID,
                    name: windowName,
                    isFront: isFront,
                    tabs: [],
                ))
                windowIndex = windows.count - 1
            }

            if windows[windowIndex].name == nil {
                windows[windowIndex].name = windowName
            }
            windows[windowIndex].isFront = windows[windowIndex].isFront || isFront

            guard !tabID.isEmpty else { continue }

            let tabIndexInWindow: Int
            if let existingTabIndex = windows[windowIndex].tabs.firstIndex(where: { $0.id == tabID }) {
                tabIndexInWindow = existingTabIndex
            } else {
                windows[windowIndex].tabs.append(MutableTab(
                    id: tabID,
                    name: tabName,
                    index: tabIndex,
                    isSelected: tabSelected,
                    terminals: [],
                    focusedTerminalID: focusedTerminalID,
                ))
                tabIndexInWindow = windows[windowIndex].tabs.count - 1
            }

            if windows[windowIndex].tabs[tabIndexInWindow].name == nil {
                windows[windowIndex].tabs[tabIndexInWindow].name = tabName
            }
            windows[windowIndex].tabs[tabIndexInWindow].isSelected = windows[windowIndex].tabs[tabIndexInWindow].isSelected || tabSelected
            if windows[windowIndex].tabs[tabIndexInWindow].focusedTerminalID == nil {
                windows[windowIndex].tabs[tabIndexInWindow].focusedTerminalID = focusedTerminalID
            }

            guard !terminalID.isEmpty else { continue }
            if windows[windowIndex].tabs[tabIndexInWindow].terminals.contains(where: { $0.id == terminalID }) {
                continue
            }

            windows[windowIndex].tabs[tabIndexInWindow].terminals.append(GhosttyTerminalSnapshot(
                id: terminalID,
                name: terminalName,
                workingDirectory: terminalWorkingDirectory,
            ))
        }

        return GhosttyAppSnapshot(
            windows: windows.map { window in
                GhosttyWindowSnapshot(
                    id: window.id,
                    name: window.name,
                    isFront: window.isFront,
                    tabs: window.tabs.map { tab in
                        GhosttyTabSnapshot(
                            id: tab.id,
                            name: tab.name,
                            index: tab.index,
                            isSelected: tab.isSelected,
                            terminals: tab.terminals,
                            focusedTerminalID: tab.focusedTerminalID,
                        )
                    },
                )
            },
        )
    }

    private func runAction(_ script: String) -> Result<Void, TerminalActivationFailureReason> {
        let result = appleScript.runOutput(script)
        guard result.success else {
            return .failure(.ghosttyAutomationUnavailable(Self.cleanedError(result.error)))
        }
        return .success(())
    }

    static func installedGhosttyVersion(
        bundleURLResolver: () -> URL? = { SupportedTerminalApp.ghostty.applicationURL() },
    ) -> String? {
        let bundle = bundleURLResolver().flatMap(Bundle.init(url:))

        return bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? bundle?.infoDictionary?["CFBundleVersion"] as? String
    }

    private static func cleanedError(_ error: String?) -> String? {
        error?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func makeSelectTabScript(tabID: String, windowID: String) -> String {
        """
        tell application "Ghostty"
            set targetWindow to first window whose id is "\(appleScriptEscape(windowID))"
            select tab (first tab of targetWindow whose id is "\(appleScriptEscape(tabID))")
        end tell
        """
    }

    private static func makeFocusTerminalScript(terminalID: String) -> String {
        """
        tell application "Ghostty"
            focus terminal id "\(appleScriptEscape(terminalID))"
        end tell
        """
    }

    private static func makeActivateWindowScript(windowID: String) -> String {
        """
        tell application "Ghostty"
            activate window (first window whose id is "\(appleScriptEscape(windowID))")
        end tell
        """
    }

    private static func makeInputTextScript(text: String, terminalID: String) -> String {
        """
        tell application "Ghostty"
            input text "\(appleScriptEscape(text))" to terminal id "\(appleScriptEscape(terminalID))"
        end tell
        """
    }

    private static func makeSendKeyScript(key: String, terminalID: String) -> String {
        """
        tell application "Ghostty"
            send key "\(appleScriptEscape(key))" to terminal id "\(appleScriptEscape(terminalID))"
        end tell
        """
    }

    private static func makeCreateWindowScript(configuration: GhosttySurfaceConfigurationOptions) -> String {
        ghosttyCreateWindowAppleScript(configuration: configuration)
    }

    private static func makeCreateTabScript(windowID: String, configuration: GhosttySurfaceConfigurationOptions) -> String {
        ghosttyCreateTabAppleScript(windowID: windowID, configuration: configuration)
    }

    private static let supportProbeScript = """
    tell application "Ghostty"
        count of windows
    end tell
    """

    private static let snapshotScript = """
    tell application "Ghostty"
        set fieldSep to character id 31
        set rowSep to character id 30
        set rows to {}
        set frontWindowID to ""
        try
            set frontWindowID to id of front window
        end try

        repeat with w in windows
            set windowID to id of w as text
            set windowName to my safeText(name of w)
            set isFront to (windowID = frontWindowID) as text
            set windowTabs to tabs of w

            if (count of windowTabs) is 0 then
                set AppleScript's text item delimiters to fieldSep
                set end of rows to ({windowID, windowName, isFront, "", "", "", "", "", "", "", ""} as text)
            else
                repeat with t in windowTabs
                    set tabID to id of t as text
                    set tabName to my safeText(name of t)
                    set tabIndex to (index of t as text)
                    set tabSelected to (selected of t as text)
                    set focusedTerminalID to ""
                    try
                        set focusedTerminalID to id of focused terminal of t as text
                    end try

                    set tabTerminals to terminals of t
                    if (count of tabTerminals) is 0 then
                        set AppleScript's text item delimiters to fieldSep
                        set end of rows to ({windowID, windowName, isFront, tabID, tabName, tabIndex, tabSelected, "", "", "", focusedTerminalID} as text)
                    else
                        repeat with term in tabTerminals
                            set terminalID to id of term as text
                            set terminalName to my safeText(name of term)
                            set terminalCwd to my safeText(working directory of term)
                            set AppleScript's text item delimiters to fieldSep
                            set end of rows to ({windowID, windowName, isFront, tabID, tabName, tabIndex, tabSelected, terminalID, terminalName, terminalCwd, focusedTerminalID} as text)
                        end repeat
                    end if
                end repeat
            end if
        end repeat

        set AppleScript's text item delimiters to rowSep
        return rows as text
    end tell

    on safeText(valueToConvert)
        try
            if valueToConvert is missing value then
                return ""
            end if
            return valueToConvert as text
        on error
            return ""
        end try
    end safeText
    """
}

func ghosttyCreateWindowAppleScript(configuration: GhosttySurfaceConfigurationOptions) -> String {
    var lines = [
        "tell application \"Ghostty\"",
        "    set launchConfig to new surface configuration",
    ]

    if let workingDirectory = configuration.initialWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
       !workingDirectory.isEmpty
    {
        lines.append("    set initial working directory of launchConfig to \"\(appleScriptEscape(workingDirectory))\"")
    }

    if let initialInput = configuration.initialInput?.trimmingCharacters(in: .whitespacesAndNewlines),
       !initialInput.isEmpty
    {
        // `initial input` pastes text into the launched shell, so append a return
        // to preserve the current shell-first launch semantics.
        lines.append("    set initial input of launchConfig to \"\(appleScriptEscape(initialInput))\" & linefeed")
    }

    lines.append("    new window with configuration launchConfig")
    lines.append("end tell")

    return lines.joined(separator: "\n")
}

func ghosttyCreateReusableSurfaceAppleScript(configuration: GhosttySurfaceConfigurationOptions) -> String {
    var lines = [
        "tell application \"Ghostty\"",
        "    set launchConfig to new surface configuration",
    ]

    if let workingDirectory = configuration.initialWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
       !workingDirectory.isEmpty
    {
        lines.append("    set initial working directory of launchConfig to \"\(appleScriptEscape(workingDirectory))\"")
    }

    if let initialInput = configuration.initialInput?.trimmingCharacters(in: .whitespacesAndNewlines),
       !initialInput.isEmpty
    {
        lines.append("    set initial input of launchConfig to \"\(appleScriptEscape(initialInput))\" & linefeed")
    }

    lines.append("    if (count of windows) > 0 then")
    lines.append("        set targetWindow to front window")
    lines.append("        new tab in targetWindow with configuration launchConfig")
    lines.append("    else")
    lines.append("        new window with configuration launchConfig")
    lines.append("    end if")
    lines.append("end tell")

    return lines.joined(separator: "\n")
}

func ghosttyCreateTabAppleScript(windowID: String, configuration: GhosttySurfaceConfigurationOptions) -> String {
    var lines = [
        "tell application \"Ghostty\"",
        "    set launchConfig to new surface configuration",
    ]

    if let workingDirectory = configuration.initialWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
       !workingDirectory.isEmpty
    {
        lines.append("    set initial working directory of launchConfig to \"\(appleScriptEscape(workingDirectory))\"")
    }

    if let initialInput = configuration.initialInput?.trimmingCharacters(in: .whitespacesAndNewlines),
       !initialInput.isEmpty
    {
        lines.append("    set initial input of launchConfig to \"\(appleScriptEscape(initialInput))\" & linefeed")
    }

    lines.append("    set targetWindow to first window whose id is \"\(appleScriptEscape(windowID))\"")
    lines.append("    new tab in targetWindow with configuration launchConfig")
    lines.append("end tell")

    return lines.joined(separator: "\n")
}

func ghosttyCreateWindowShellScript(configuration: GhosttySurfaceConfigurationOptions) -> String {
    """
    osascript <<'APPLESCRIPT'
    \(ghosttyCreateWindowAppleScript(configuration: configuration))
    APPLESCRIPT
    """
}

func ghosttyCreateReusableSurfaceShellScript(configuration: GhosttySurfaceConfigurationOptions) -> String {
    """
    osascript <<'APPLESCRIPT'
    \(ghosttyCreateReusableSurfaceAppleScript(configuration: configuration))
    APPLESCRIPT
    """
}

func bestGhosttyRouteMatch(
    snapshot: GhosttyAppSnapshot,
    projectPath: String,
    homeDirectory: String = NSHomeDirectory(),
    tmuxSessionHint: String? = nil,
    preferredTerminalID: String? = nil,
) -> GhosttyRouteMatch? {
    if let preferredTerminalID {
        for window in snapshot.windows {
            for tab in window.tabs {
                if let terminal = tab.terminals.first(where: { $0.id == preferredTerminalID }) {
                    return GhosttyRouteMatch(
                        source: .cachedTerminalID,
                        window: window,
                        tab: tab,
                        terminal: terminal,
                    )
                }
            }
        }
    }

    let normalizedProjectPath = normalizeGhosttyPath(projectPath, homeDirectory: homeDirectory)
    let normalizedHome = normalizeGhosttyPath(homeDirectory, homeDirectory: homeDirectory)

    func best(_ lhs: GhosttyRouteCandidate, over rhs: GhosttyRouteCandidate) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        if lhs.distance != rhs.distance {
            return lhs.distance < rhs.distance
        }
        if lhs.isSelected != rhs.isSelected {
            return lhs.isSelected && !rhs.isSelected
        }
        if lhs.isFront != rhs.isFront {
            return lhs.isFront && !rhs.isFront
        }
        if lhs.tabIndex != rhs.tabIndex {
            return lhs.tabIndex < rhs.tabIndex
        }
        return lhs.stableID < rhs.stableID
    }

    var bestCandidate: GhosttyRouteCandidate?

    for window in snapshot.windows {
        if let windowCandidate = ghosttyWindowTitleCandidate(
            window: window,
            projectPath: normalizedProjectPath,
            homeDirectory: normalizedHome,
            tmuxSessionHint: tmuxSessionHint,
        ) {
            if let currentBest = bestCandidate {
                if best(windowCandidate, over: currentBest) {
                    bestCandidate = windowCandidate
                }
            } else {
                bestCandidate = windowCandidate
            }
        }

        for tab in window.tabs {
            for terminal in tab.terminals {
                guard let candidate = ghosttyTerminalCandidate(
                    window: window,
                    tab: tab,
                    terminal: terminal,
                    projectPath: normalizedProjectPath,
                    homeDirectory: normalizedHome,
                    tmuxSessionHint: tmuxSessionHint,
                ) else {
                    continue
                }

                if let currentBest = bestCandidate {
                    if best(candidate, over: currentBest) {
                        bestCandidate = candidate
                    }
                } else {
                    bestCandidate = candidate
                }
            }
        }
    }

    return bestCandidate?.route
}

private func ghosttyTerminalCandidate(
    window: GhosttyWindowSnapshot,
    tab: GhosttyTabSnapshot,
    terminal: GhosttyTerminalSnapshot,
    projectPath: String,
    homeDirectory: String,
    tmuxSessionHint: String?,
) -> GhosttyRouteCandidate? {
    func candidate(
        source: GhosttyRouteMatchSource,
        priority: Int,
        distance: Int,
    ) -> GhosttyRouteCandidate {
        GhosttyRouteCandidate(
            route: GhosttyRouteMatch(source: source, window: window, tab: tab, terminal: terminal),
            priority: priority,
            distance: distance,
            isSelected: tab.isSelected,
            isFront: window.isFront,
            tabIndex: tab.index,
            stableID: terminal.id,
        )
    }

    if let workingDirectory = terminal.workingDirectory {
        let normalizedWorkingDirectory = normalizeGhosttyPath(workingDirectory, homeDirectory: homeDirectory)
        if let pathMatch = ghosttyPathRankAndDistance(
            shellPath: normalizedWorkingDirectory,
            projectPath: projectPath,
            homeDir: homeDirectory,
        ) {
            let priority = switch pathMatch.rank {
            case 2: 920
            case 1: 910
            default: 900
            }
            return candidate(source: .terminalWorkingDirectory, priority: priority, distance: pathMatch.distance)
        }
    }

    if let terminalName = terminal.name,
       let titleMatch = ghosttyTitleCandidate(
           title: terminalName,
           source: .terminalName,
           pathBase: 330,
           sessionTitleBase: 320,
           sessionHintBase: 30,
           projectPath: projectPath,
           homeDirectory: homeDirectory,
           tmuxSessionHint: tmuxSessionHint,
       )
    {
        return candidate(source: titleMatch.source, priority: titleMatch.priority, distance: titleMatch.distance)
    }

    if let tabName = tab.name,
       let titleMatch = ghosttyTitleCandidate(
           title: tabName,
           source: .tabName,
           pathBase: 230,
           sessionTitleBase: 220,
           sessionHintBase: 20,
           projectPath: projectPath,
           homeDirectory: homeDirectory,
           tmuxSessionHint: tmuxSessionHint,
       )
    {
        let matchedTerminal = tab.terminals.first(where: { $0.id == tab.focusedTerminalID }) ?? terminal
        return GhosttyRouteCandidate(
            route: GhosttyRouteMatch(source: titleMatch.source, window: window, tab: tab, terminal: matchedTerminal),
            priority: titleMatch.priority,
            distance: titleMatch.distance,
            isSelected: tab.isSelected,
            isFront: window.isFront,
            tabIndex: tab.index,
            stableID: matchedTerminal.id,
        )
    }

    return nil
}

private func ghosttyWindowTitleCandidate(
    window: GhosttyWindowSnapshot,
    projectPath: String,
    homeDirectory: String,
    tmuxSessionHint: String?,
) -> GhosttyRouteCandidate? {
    guard let windowName = window.name,
          let titleMatch = ghosttyTitleCandidate(
              title: windowName,
              source: .windowName,
              pathBase: 130,
              sessionTitleBase: 120,
              sessionHintBase: 10,
              projectPath: projectPath,
              homeDirectory: homeDirectory,
              tmuxSessionHint: tmuxSessionHint,
          )
    else {
        return nil
    }

    let selectedTab = window.tabs.first(where: \.isSelected)
    return GhosttyRouteCandidate(
        route: GhosttyRouteMatch(source: titleMatch.source, window: window, tab: nil, terminal: nil),
        priority: titleMatch.priority,
        distance: titleMatch.distance,
        isSelected: selectedTab?.isSelected ?? false,
        isFront: window.isFront,
        tabIndex: selectedTab?.index ?? .max,
        stableID: window.id,
    )
}

private struct GhosttyTitleMatch {
    let source: GhosttyRouteMatchSource
    let priority: Int
    let distance: Int
}

private func ghosttyTitleCandidate(
    title: String,
    source: GhosttyRouteMatchSource,
    pathBase: Int,
    sessionTitleBase: Int,
    sessionHintBase: Int,
    projectPath: String,
    homeDirectory: String,
    tmuxSessionHint: String?,
) -> GhosttyTitleMatch? {
    let normalizedTitle = normalizeGhosttyPath(title, homeDirectory: homeDirectory).lowercased()
    let caseInsensitiveProjectPath = projectPath.lowercased()
    let caseInsensitiveHomeDirectory = homeDirectory.lowercased()
    if let pathMatch = ghosttyPathRankAndDistance(
        shellPath: normalizedTitle,
        projectPath: caseInsensitiveProjectPath,
        homeDir: caseInsensitiveHomeDirectory,
    ) {
        return GhosttyTitleMatch(
            source: source,
            priority: pathBase + pathMatch.rank,
            distance: pathMatch.distance,
        )
    }

    if let sessionTitleMatch = ghosttySessionTitleRankAndDistance(tabTitle: title, projectPath: projectPath) {
        return GhosttyTitleMatch(
            source: source,
            priority: sessionTitleBase + sessionTitleMatch.rank,
            distance: sessionTitleMatch.distance,
        )
    }

    if let sessionHintMatch = ghosttySessionHintRankAndDistance(tabTitle: title, sessionHint: tmuxSessionHint) {
        return GhosttyTitleMatch(
            source: .sessionHint,
            priority: sessionHintBase + sessionHintMatch.rank,
            distance: sessionHintMatch.distance,
        )
    }

    return nil
}

private func nilIfEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func normalizeGhosttyPath(_ path: String, homeDirectory: String) -> String {
    let trimmed = extractPathCandidate(fromTitle: path).trimmingCharacters(in: .whitespacesAndNewlines)
    let expandedHome = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)

    let expanded: String = if trimmed == "~" {
        expandedHome
    } else if trimmed.hasPrefix("~/") {
        expandedHome + String(trimmed.dropFirst())
    } else {
        trimmed
    }

    if expanded == "/" {
        return "/"
    }

    var normalized = expanded
    while normalized.hasSuffix("/"), normalized != "/" {
        normalized.removeLast()
    }

    if normalized.isEmpty {
        return "/"
    }

    return normalized
}

private func extractPathCandidate(fromTitle title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("~/") || trimmed == "~" || trimmed.hasPrefix("/") {
        return trimmed
    }

    if let ellipsisRange = trimmed.range(of: "…/") {
        return "/" + trimmed[ellipsisRange.upperBound...]
    }
    if let dotsRange = trimmed.range(of: ".../") {
        return "/" + trimmed[dotsRange.upperBound...]
    }

    if let suffixAfterColon = trimmed.split(separator: ":", omittingEmptySubsequences: false).last {
        let candidate = String(suffixAfterColon).trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("~/") || candidate == "~" || candidate.hasPrefix("/") {
            return candidate
        }
    }

    if let slashRange = trimmed.range(of: "~/", options: .backwards) {
        return String(trimmed[slashRange.lowerBound...])
    }
    if let slashRange = trimmed.range(of: "/", options: .backwards) {
        let candidate = String(trimmed[slashRange.lowerBound...])
        if candidate.count > 1 {
            return candidate
        }
    }

    return trimmed
}

private func ghosttyPathRankAndDistance(shellPath: String, projectPath: String, homeDir: String) -> (rank: Int, distance: Int)? {
    if shellPath == projectPath {
        return (2, 0)
    }

    if !ghosttyPathsShareManagedWorktree(shellPath, projectPath) {
        return nil
    }

    let (shorter, longer) = shellPath.count < projectPath.count
        ? (shellPath, projectPath)
        : (projectPath, shellPath)

    if shorter == homeDir {
        return nil
    }

    guard longer.hasPrefix(shorter + "/") else {
        if let suffixDistance = ghosttySuffixPathDistance(shellPath: shellPath, projectPath: projectPath) {
            return (1, suffixDistance)
        }
        return nil
    }

    let rank = shorter == projectPath ? 1 : 0
    let distance = abs(ghosttyPathComponentCount(shellPath) - ghosttyPathComponentCount(projectPath))
    return (rank, distance)
}

private func ghosttySuffixPathDistance(shellPath: String, projectPath: String) -> Int? {
    let shellComponents = shellPath.split(separator: "/", omittingEmptySubsequences: true)
    let projectComponents = projectPath.split(separator: "/", omittingEmptySubsequences: true)

    guard !shellComponents.isEmpty, !projectComponents.isEmpty else {
        return nil
    }

    var suffixMatches = 0
    let maxChecks = min(shellComponents.count, projectComponents.count)
    while suffixMatches < maxChecks {
        let shellIndex = shellComponents.count - 1 - suffixMatches
        let projectIndex = projectComponents.count - 1 - suffixMatches
        if shellComponents[shellIndex] != projectComponents[projectIndex] {
            break
        }
        suffixMatches += 1
    }

    guard suffixMatches >= 2 else {
        return nil
    }

    return abs(shellComponents.count - projectComponents.count)
}

private func ghosttySessionTitleRankAndDistance(tabTitle: String, projectPath: String) -> (rank: Int, distance: Int)? {
    let projectName = projectPath.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)?.lowercased()
    guard let projectName,
          let sessionName = normalizedGhosttySessionName(fromTitle: tabTitle),
          !projectName.isEmpty,
          !sessionName.isEmpty
    else {
        return nil
    }

    if sessionName == projectName || projectName.hasPrefix(sessionName + "-") {
        return (1, 0)
    }

    return nil
}

private func ghosttySessionHintRankAndDistance(tabTitle: String, sessionHint: String?) -> (rank: Int, distance: Int)? {
    guard let sessionHint = sessionHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          let sessionName = normalizedGhosttySessionName(fromTitle: tabTitle),
          !sessionHint.isEmpty,
          !sessionName.isEmpty
    else {
        return nil
    }

    if sessionName == sessionHint {
        return (3, 0)
    }
    return nil
}

private func normalizedGhosttySessionName(fromTitle tabTitle: String) -> String? {
    let trimmed = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else {
        return nil
    }
    let leading = trimmed.drop(while: { !$0.isLetter && !$0.isNumber })
    guard !leading.isEmpty else {
        return nil
    }
    return leading.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
}

private let managedWorktreesMarker = "/.capacitor/worktrees/"

private func ghosttyPathsShareManagedWorktree(_ first: String, _ second: String) -> Bool {
    switch (ghosttyManagedWorktreeRoot(first), ghosttyManagedWorktreeRoot(second)) {
    case (nil, nil):
        true
    case let (lhs?, rhs?):
        lhs == rhs
    default:
        false
    }
}

private func ghosttyManagedWorktreeRoot(_ path: String) -> String? {
    guard let markerRange = path.range(of: managedWorktreesMarker) else {
        return nil
    }

    let worktreeNameStart = markerRange.upperBound
    guard worktreeNameStart < path.endIndex else {
        return nil
    }

    let suffix = path[worktreeNameStart...]
    let nextSlash = suffix.firstIndex(of: "/") ?? path.endIndex
    guard nextSlash > worktreeNameStart else {
        return nil
    }

    return String(path[..<nextSlash])
}

private func ghosttyPathComponentCount(_ path: String) -> Int {
    path.split(separator: "/", omittingEmptySubsequences: true).count
}
