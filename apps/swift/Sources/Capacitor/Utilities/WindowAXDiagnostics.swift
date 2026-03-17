import AppKit

enum WindowAXDiagnostics {
    struct State: Equatable {
        let title: String
        let windowNumber: Int
        let level: Int
        let isVisible: Bool
        let isKey: Bool
        let isMain: Bool
        let canBecomeKey: Bool
        let canBecomeMain: Bool
        let isOpaque: Bool
        let hasShadow: Bool
        let styleMask: String
        let titleVisibility: String
        let titlebarAppearsTransparent: Bool
        let isMovableByWindowBackground: Bool
    }

    static func logApplicationDidBecomeActive(windowCount: Int) {
        DebugLog.write("[WindowAX] applicationDidBecomeActive appWindowCount=\(windowCount)")
    }

    static func log(context: String, window: NSWindow) {
        DebugLog.write(render(context: context, state: snapshot(for: window)))
    }

    static func render(context: String, state: State) -> String {
        [
            "[WindowAX] context=\(context)",
            "title=\(sanitize(state.title))",
            "windowNumber=\(state.windowNumber)",
            "level=\(state.level)",
            "isVisible=\(state.isVisible)",
            "isKey=\(state.isKey)",
            "isMain=\(state.isMain)",
            "canBecomeKey=\(state.canBecomeKey)",
            "canBecomeMain=\(state.canBecomeMain)",
            "isOpaque=\(state.isOpaque)",
            "hasShadow=\(state.hasShadow)",
            "styleMask=\(state.styleMask)",
            "titleVisibility=\(state.titleVisibility)",
            "titlebarAppearsTransparent=\(state.titlebarAppearsTransparent)",
            "isMovableByWindowBackground=\(state.isMovableByWindowBackground)",
        ].joined(separator: " ")
    }

    static func snapshot(for window: NSWindow) -> State {
        State(
            title: window.title,
            windowNumber: window.windowNumber,
            level: window.level.rawValue,
            isVisible: window.isVisible,
            isKey: window.isKeyWindow,
            isMain: window.isMainWindow,
            canBecomeKey: window.canBecomeKey,
            canBecomeMain: window.canBecomeMain,
            isOpaque: window.isOpaque,
            hasShadow: window.hasShadow,
            styleMask: describeStyleMask(window.styleMask),
            titleVisibility: describeTitleVisibility(window.titleVisibility),
            titlebarAppearsTransparent: window.titlebarAppearsTransparent,
            isMovableByWindowBackground: window.isMovableByWindowBackground,
        )
    }

    private static func describeTitleVisibility(_ visibility: NSWindow.TitleVisibility) -> String {
        switch visibility {
        case .hidden:
            "hidden"
        case .visible:
            "visible"
        @unknown default:
            "unknown"
        }
    }

    private static func describeStyleMask(_ styleMask: NSWindow.StyleMask) -> String {
        let orderedFlags: [(NSWindow.StyleMask, String)] = [
            (.borderless, "borderless"),
            (.titled, "titled"),
            (.closable, "closable"),
            (.miniaturizable, "miniaturizable"),
            (.resizable, "resizable"),
            (.utilityWindow, "utilityWindow"),
            (.docModalWindow, "docModalWindow"),
            (.nonactivatingPanel, "nonactivatingPanel"),
            (.hudWindow, "hudWindow"),
            (.fullScreen, "fullScreen"),
            (.fullSizeContentView, "fullSizeContentView"),
        ]

        let labels = orderedFlags.compactMap { flag, label in
            styleMask.contains(flag) ? label : nil
        }

        return "[\(labels.joined(separator: ","))]"
    }

    private static func sanitize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "<untitled>"
        }
        return trimmed.replacingOccurrences(of: " ", with: "_")
    }
}
