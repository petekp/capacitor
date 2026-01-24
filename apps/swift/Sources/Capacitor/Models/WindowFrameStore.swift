import Foundation
import AppKit

final class WindowFrameStore {
    static let shared = WindowFrameStore()

    private let userDefaults = UserDefaults.standard
    private let verticalFrameKey = "windowFrame.vertical"
    private let dockFrameKey = "windowFrame.dock"

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
}
