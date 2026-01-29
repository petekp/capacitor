import Foundation
import AppKit

/// Tracks window compact state for double-click behavior
enum WindowCompactState {
    case normal
    case compact
    case topLeft
}

final class WindowFrameStore {
    static let shared = WindowFrameStore()

    private let userDefaults = UserDefaults.standard
    private let verticalFrameKey = "windowFrame.vertical"
    private let dockFrameKey = "windowFrame.dock"

    /// Tracks the current compact state for double-click cycling
    private(set) var compactState: WindowCompactState = .normal

    /// Stores the frame before compacting so we can restore it
    private var frameBeforeCompact: NSRect?

    /// Minimum window size when compacted
    private let compactSize = NSSize(width: 280, height: 400)

    private init() {}

    func saveFrame(_ frame: NSRect, for layoutMode: LayoutMode) {
        let key = frameKey(for: layoutMode)
        let frameDict: [String: CGFloat] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.size.width,
            "height": frame.size.height
        ]
        userDefaults.set(frameDict, forKey: key)
    }

    func loadFrame(for layoutMode: LayoutMode) -> NSRect? {
        let key = frameKey(for: layoutMode)
        guard let frameDict = userDefaults.dictionary(forKey: key) as? [String: CGFloat],
              let x = frameDict["x"],
              let y = frameDict["y"],
              let width = frameDict["width"],
              let height = frameDict["height"] else {
            return nil
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func frameKey(for layoutMode: LayoutMode) -> String {
        switch layoutMode {
        case .vertical:
            return verticalFrameKey
        case .dock:
            return dockFrameKey
        }
    }

    // MARK: - Double-Click Compact Behavior

    /// Cycles through compact states on double-click:
    /// normal → compact (shrink to fit) → topLeft (move to top-left corner)
    /// Then resets to normal on next double-click
    func cycleCompactState() {
        guard let window = NSApp.mainWindow else { return }

        switch compactState {
        case .normal:
            // Save current frame and shrink to compact size
            frameBeforeCompact = window.frame
            let newFrame = NSRect(
                x: window.frame.origin.x,
                y: window.frame.origin.y + window.frame.height - compactSize.height,
                width: compactSize.width,
                height: compactSize.height
            )
            window.setFrame(newFrame, display: true, animate: true)
            compactState = .compact

        case .compact:
            // Move to top-left of current screen
            if let screen = window.screen ?? NSScreen.main {
                let visibleFrame = screen.visibleFrame
                let topLeftFrame = NSRect(
                    x: visibleFrame.origin.x + 20,
                    y: visibleFrame.origin.y + visibleFrame.height - compactSize.height - 20,
                    width: compactSize.width,
                    height: compactSize.height
                )
                window.setFrame(topLeftFrame, display: true, animate: true)
            }
            compactState = .topLeft

        case .topLeft:
            // Restore to original frame
            if let originalFrame = frameBeforeCompact {
                window.setFrame(originalFrame, display: true, animate: true)
            }
            compactState = .normal
            frameBeforeCompact = nil
        }
    }

    /// Resets compact state when window is manually resized
    func resetCompactState() {
        compactState = .normal
        frameBeforeCompact = nil
    }
}
