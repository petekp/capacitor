import AppKit

// MARK: - Protocol

protocol WindowBoundsProviding {
    func bounds(for windowID: CGWindowID) -> CGRect?
    func visibleTargetWindows() -> [(TargetWindowIdentity, CGRect)]
}

// MARK: - Live Implementation

@MainActor
final class WindowBoundsProvider: WindowBoundsProviding {
    static let defaultTargetNames: Set<String> = [
        "Ghostty", "Terminal", "iTerm2", "Alacritty", "WezTerm", "kitty",
    ]

    private let targetNames: Set<String>
    private let ownPID: pid_t

    init(targetNames: Set<String>? = nil) {
        self.targetNames = targetNames ?? Self.defaultTargetNames
        ownPID = ProcessInfo.processInfo.processIdentifier
    }

    // MARK: - Single Window Query

    nonisolated func bounds(for windowID: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID,
        ) as? [[String: Any]] else {
            return nil
        }

        guard let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
        else {
            return nil
        }

        let cgRect = cgRect(from: boundsDict)
        return cgRectToAppKit(cgRect)
    }

    // MARK: - Visible Target Windows

    nonisolated func visibleTargetWindows() -> [(TargetWindowIdentity, CGRect)] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID,
        ) as? [[String: Any]] else {
            return []
        }

        var results: [(TargetWindowIdentity, CGRect)] = []

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ownPID,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  targetNames.contains(ownerName),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else {
                continue
            }

            let cgRect = cgRect(from: boundsDict)
            guard cgRect.width >= 100,
                  cgRect.height >= 100
            else {
                continue
            }

            let windowName = info[kCGWindowName as String] as? String
            let identity = TargetWindowIdentity(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                windowName: windowName,
            )
            results.append((identity, cgRectToAppKit(cgRect)))
        }

        return results
    }

    // MARK: - Coordinate Conversion

    /// CG uses top-left origin; AppKit uses bottom-left origin.
    /// Conversion requires the primary screen height.
    nonisolated func cgRectToAppKit(_ rect: CGRect) -> CGRect {
        let screenHeight = primaryScreenHeight()
        return CGRect(
            x: rect.origin.x,
            y: screenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height,
        )
    }

    nonisolated func appKitRectToCG(_ rect: CGRect) -> CGRect {
        let screenHeight = primaryScreenHeight()
        return CGRect(
            x: rect.origin.x,
            y: screenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height,
        )
    }

    // MARK: - Helpers

    private nonisolated func primaryScreenHeight() -> CGFloat {
        // NSScreen.main can only be accessed on main thread in some contexts,
        // but .screens is safe. The primary screen is always index 0.
        NSScreen.screens.first?.frame.height ?? 1080
    }

    private nonisolated func cgRect(from dict: [String: CGFloat]) -> CGRect {
        CGRect(
            x: dict["X"] ?? 0,
            y: dict["Y"] ?? 0,
            width: dict["Width"] ?? 0,
            height: dict["Height"] ?? 0,
        )
    }
}
