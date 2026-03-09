import AppKit
import Foundation

@MainActor
protocol GhosttyWindowReader {
    func readWindows() -> GhosttyWindowReadResult
    func raiseWindow(_ window: AXUIElement) -> Bool
    func focusTab(_ tab: GhosttyTabSnapshot, in window: AXUIElement) -> Bool
}

enum GhosttyWindowReadResult {
    case unavailable
    case windows([GhosttyWindowSnapshot])
}

struct GhosttyTabSnapshot {
    let element: AXUIElement
    let title: String?
    let index: Int
    let isSelected: Bool
}

struct GhosttyWindowSnapshot {
    let element: AXUIElement
    let index: Int
    let tabs: [GhosttyTabSnapshot]
    let isMain: Bool
    let title: String?

    init(element: AXUIElement, index: Int, tabs: [GhosttyTabSnapshot], isMain: Bool, title: String? = nil) {
        self.element = element
        self.index = index
        self.tabs = tabs
        self.isMain = isMain
        self.title = title
    }
}

struct DefaultGhosttyAXReader: GhosttyWindowReader {
    func readWindows() -> GhosttyWindowReadResult {
        guard let ghosttyApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }) else {
            return .windows([])
        }

        let appElement = AXUIElementCreateApplication(ghosttyApp.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return .unavailable
        }

        let snapshots = windows.enumerated().map { index, window in
            GhosttyWindowSnapshot(
                element: window,
                index: index,
                tabs: readWindowTabs(window),
                isMain: readBool(window, attribute: kAXMainAttribute as CFString) ?? false,
                title: readTitle(window),
            )
        }

        return .windows(snapshots)
    }

    func raiseWindow(_ window: AXUIElement) -> Bool {
        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard raiseResult == .success else {
            return false
        }

        activateOwningApplication(for: window)
        return true
    }

    func focusTab(_ tab: GhosttyTabSnapshot, in window: AXUIElement) -> Bool {
        // Ghostty can revert tab selection when a window is raised *after* AXPress.
        // Raise first, then press the tab to keep the intended selection.
        _ = raiseWindow(window)

        let pressResult = AXUIElementPerformAction(tab.element, kAXPressAction as CFString)
        return pressResult == .success
    }

    private func readWindowTabs(_ window: AXUIElement) -> [GhosttyTabSnapshot] {
        let tabElements = readTabs(from: window)

        return tabElements.enumerated().map { index, tabElement in
            GhosttyTabSnapshot(
                element: tabElement,
                title: readTitle(tabElement),
                index: index,
                isSelected: readTabSelection(tabElement),
            )
        }
    }

    private func readTabs(from window: AXUIElement) -> [AXUIElement] {
        if let tabs = copyAttribute(window, attribute: kAXTabsAttribute as CFString) as? [AXUIElement], !tabs.isEmpty {
            return tabs
        }

        guard let children = copyAttribute(window, attribute: kAXChildrenAttribute as CFString) as? [AXUIElement] else {
            return []
        }

        for child in children {
            if let role = readString(child, attribute: kAXRoleAttribute as CFString), role == "AXTabGroup",
               let tabs = copyAttribute(child, attribute: kAXTabsAttribute as CFString) as? [AXUIElement], !tabs.isEmpty
            {
                return tabs
            }
        }

        return []
    }

    private func readTabSelection(_ tabElement: AXUIElement) -> Bool {
        if let boolValue = readBool(tabElement, attribute: kAXSelectedAttribute as CFString) {
            return boolValue
        }

        if let value = copyAttribute(tabElement, attribute: kAXValueAttribute as CFString) as? NSNumber {
            return value.intValue == 1
        }

        return false
    }

    private func readTitle(_ element: AXUIElement) -> String? {
        readString(element, attribute: kAXTitleAttribute as CFString)
    }

    private func readString(_ element: AXUIElement, attribute: CFString) -> String? {
        copyAttribute(element, attribute: attribute) as? String
    }

    private func readBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
        guard let value = copyAttribute(element, attribute: attribute) as? NSNumber else {
            return nil
        }
        return value.boolValue
    }

    private func copyAttribute(_ element: AXUIElement, attribute: CFString) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }

        return value as AnyObject?
    }

    private func activateOwningApplication(for element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return
        }

        if #available(macOS 14.0, *) {
            _ = app.activate()
        } else {
            _ = app.activate(options: .activateIgnoringOtherApps)
        }
    }
}

func bestGhosttyTabMatch(
    windows: [GhosttyWindowSnapshot],
    projectPath: String,
    homeDirectory: String = NSHomeDirectory(),
    tmuxSessionHint: String? = nil,
) -> (window: GhosttyWindowSnapshot, tab: GhosttyTabSnapshot)? {
    let normalizedProjectPath = normalizeGhosttyPath(projectPath, homeDirectory: homeDirectory)
    let normalizedHome = normalizeGhosttyPath(homeDirectory, homeDirectory: homeDirectory)

    struct Candidate {
        let window: GhosttyWindowSnapshot
        let tab: GhosttyTabSnapshot
        let rank: Int
        let distance: Int
    }

    var bestCandidate: Candidate?

    for window in windows {
        for tab in window.tabs {
            guard let rawTitle = tab.title,
                  !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }

            let normalizedTabPath = normalizeGhosttyPath(rawTitle, homeDirectory: homeDirectory)
            let pathMatch = ghosttyPathRankAndDistance(
                shellPath: normalizedTabPath,
                projectPath: normalizedProjectPath,
                homeDir: normalizedHome,
            )
            let sessionTitleMatch = ghosttySessionTitleRankAndDistance(
                tabTitle: rawTitle,
                projectPath: normalizedProjectPath,
            )
            let sessionHintMatch = ghosttySessionHintRankAndDistance(
                tabTitle: rawTitle,
                sessionHint: tmuxSessionHint,
            )
            let allMatches = [pathMatch, sessionTitleMatch, sessionHintMatch].compactMap(\.self)
            guard let (rank, distance) = allMatches.max(by: { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.distance > rhs.distance
            }) else {
                continue
            }

            let candidate = Candidate(window: window, tab: tab, rank: rank, distance: distance)
            if let best = bestCandidate {
                if candidate.rank > best.rank ||
                    (candidate.rank == best.rank && candidate.distance < best.distance) ||
                    (candidate.rank == best.rank && candidate.distance == best.distance && candidate.tab.isSelected && !best.tab.isSelected) ||
                    (candidate.rank == best.rank && candidate.distance == best.distance && candidate.tab.isSelected == best.tab.isSelected && candidate.window.isMain && !best.window.isMain) ||
                    (candidate.rank == best.rank && candidate.distance == best.distance && candidate.tab.isSelected == best.tab.isSelected && candidate.window.isMain == best.window.isMain && candidate.tab.index < best.tab.index) ||
                    (candidate.rank == best.rank && candidate.distance == best.distance && candidate.tab.isSelected == best.tab.isSelected && candidate.window.isMain == best.window.isMain && candidate.tab.index == best.tab.index && candidate.window.index < best.window.index)
                {
                    bestCandidate = candidate
                }
            } else {
                bestCandidate = candidate
            }
        }
    }

    guard let bestCandidate else {
        return nil
    }

    return (window: bestCandidate.window, tab: bestCandidate.tab)
}

func bestGhosttyWindowForRaise(windows: [GhosttyWindowSnapshot]) -> GhosttyWindowSnapshot? {
    windows.sorted { lhs, rhs in
        if lhs.isMain != rhs.isMain {
            return lhs.isMain && !rhs.isMain
        }
        return lhs.index < rhs.index
    }.first
}

/// Check if any Ghostty window's title matches the given session/project.
/// Used as a fallback signal when tabs aren't enumerable (tabCount == 0) — the
/// window title reflects the active tab's title, so it can serve as a proxy for
/// tab-level matching. Reuses the same matching logic as `bestGhosttyTabMatch`.
func ghosttyWindowTitleMatchesSession(
    windows: [GhosttyWindowSnapshot],
    projectPath: String,
    homeDirectory: String = NSHomeDirectory(),
    tmuxSessionHint: String? = nil,
) -> Bool {
    let normalizedProjectPath = normalizeGhosttyPath(projectPath, homeDirectory: homeDirectory)
    let normalizedHome = normalizeGhosttyPath(homeDirectory, homeDirectory: homeDirectory)

    for window in windows {
        guard let title = window.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            continue
        }

        let normalizedTitle = normalizeGhosttyPath(title, homeDirectory: homeDirectory)
        if ghosttyPathRankAndDistance(shellPath: normalizedTitle, projectPath: normalizedProjectPath, homeDir: normalizedHome) != nil {
            return true
        }
        if ghosttySessionTitleRankAndDistance(tabTitle: title, projectPath: normalizedProjectPath) != nil {
            return true
        }
        if ghosttySessionHintRankAndDistance(tabTitle: title, sessionHint: tmuxSessionHint) != nil {
            return true
        }
    }
    return false
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

    return normalized.lowercased()
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

    // Require at least two matching components to avoid single-segment false positives.
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
        // Treat direct session-prefix matches as strong candidates, on par with path-scoped matches.
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
        // A resolver-provided tmux session name is authoritative for detached/reattach flows.
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
