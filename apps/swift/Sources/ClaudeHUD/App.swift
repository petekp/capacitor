import SwiftUI
import AppKit

@main
struct ClaudeHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var updaterController = UpdaterController()
    @AppStorage("floatingMode") private var floatingMode = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @AppStorage("layoutMode") private var layoutMode = "vertical"
    @AppStorage("setupComplete") private var setupComplete = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                if setupComplete {
                    ContentView()
                        .environmentObject(appState)
                        .environment(\.floatingMode, floatingMode)
                        .environment(\.alwaysOnTop, alwaysOnTop)
                        .readReduceMotion()
                        .modifier(LayoutModeFrameModifier(layoutMode: appState.layoutMode))
                        .background(FloatingWindowConfigurator(enabled: floatingMode, alwaysOnTop: alwaysOnTop))
                        .background(WindowFrameConfigurator(layoutMode: appState.layoutMode))
                        .onAppear {
                            if let mode = LayoutMode(rawValue: layoutMode) {
                                appState.layoutMode = mode
                            }
                        }
                        .onChange(of: layoutMode) { _, newValue in
                            if let mode = LayoutMode(rawValue: newValue) {
                                appState.layoutMode = mode
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .identity
                        ))
                } else {
                    WelcomeView(onComplete: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            setupComplete = true
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if floatingMode {
                            DarkFrostedGlass()
                        } else {
                            Color.hudBackground
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: floatingMode ? 22 : 0))
                    .background(FloatingWindowConfigurator(enabled: floatingMode, alwaysOnTop: alwaysOnTop))
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }
            }
        }
        .defaultSize(width: 360, height: 700)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .appInfo) {
                if updaterController.isAvailable {
                    Button("Check for Updates...") {
                        updaterController.checkForUpdates()
                    }
                    .disabled(!updaterController.canCheckForUpdates)
                }
            }

            CommandMenu("View") {
                Section("Layout") {
                    Button("Vertical Layout") {
                        layoutMode = "vertical"
                        appState.layoutMode = .vertical
                    }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(layoutMode == "vertical")

                    Button("Dock Layout") {
                        layoutMode = "dock"
                        appState.layoutMode = .dock
                    }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(layoutMode == "dock")
                }

                Divider()

                Toggle("Floating Mode", isOn: $floatingMode)
                    .keyboardShortcut("T", modifiers: [.command, .shift])

                Toggle("Always on Top", isOn: $alwaysOnTop)
                    .keyboardShortcut("P", modifiers: [.command, .shift])

                #if DEBUG
                Divider()
                UITuningPanelMenuButton()

                Button("Show Welcome Screen") {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        setupComplete = false
                    }
                }
                .keyboardShortcut("W", modifiers: [.command, .shift, .option])

                Button("Reset Onboarding (Full)") {
                    resetOnboardingFully()
                }
                .keyboardShortcut("R", modifiers: [.command, .shift, .option])
                #endif
            }

            CommandGroup(replacing: .help) {
                Link("Claude HUD Help", destination: URL(string: "https://github.com/anthropics/claude-hud#readme")!)
                    .keyboardShortcut("?", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(updaterController: updaterController)
        }

        #if DEBUG
        Window("UI Tuning", id: "ui-tuning-panel") {
            UITuningPanel()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .defaultSize(width: 580, height: 720)
        #endif
    }

    #if DEBUG
    private static let onboardingBackupPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".capacitor-onboarding-backup")

    private func resetOnboardingFully() {
        _Concurrency.Task {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let capacitorPath = home.appendingPathComponent(".capacitor")
            let backupPath = Self.onboardingBackupPath

            // 1. Preserve user data to temporary backup location
            let userDataFiles = ["projects.json", "creations.json"]
            try? fm.removeItem(at: backupPath)
            try? fm.createDirectory(at: backupPath, withIntermediateDirectories: true)

            for filename in userDataFiles {
                let sourcePath = capacitorPath.appendingPathComponent(filename)
                let destPath = backupPath.appendingPathComponent(filename)
                if fm.fileExists(atPath: sourcePath.path) {
                    try? fm.copyItem(at: sourcePath, to: destPath)
                    print("[Debug] Backed up \(filename)")
                }
            }

            // 2. Remove entire ~/.capacitor directory (truly empty now)
            try? fm.removeItem(at: capacitorPath)
            print("[Debug] Removed ~/.capacitor/")

            // 3. Remove hooks from settings.json (best effort)
            // Note: We don't remove the binary (~/.local/bin/hud-hook) - user may want it
            await removeHooksFromSettings()

            // 4. Reset the setup complete flag and show welcome screen
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.4)) {
                    setupComplete = false
                }
            }

            print("[Debug] Onboarding reset complete (user data backed up to ~/.capacitor-onboarding-backup/)")
        }
    }

    static func restoreOnboardingBackup() {
        let fm = FileManager.default
        let capacitorPath = fm.homeDirectoryForCurrentUser.appendingPathComponent(".capacitor")
        let backupPath = onboardingBackupPath

        guard fm.fileExists(atPath: backupPath.path) else { return }

        let userDataFiles = ["projects.json", "creations.json"]
        for filename in userDataFiles {
            let sourcePath = backupPath.appendingPathComponent(filename)
            let destPath = capacitorPath.appendingPathComponent(filename)
            if fm.fileExists(atPath: sourcePath.path) {
                try? fm.copyItem(at: sourcePath, to: destPath)
                print("[Debug] Restored \(filename) from backup")
            }
        }

        // Clean up backup directory
        try? fm.removeItem(at: backupPath)
        print("[Debug] Cleaned up onboarding backup")
    }

    private func removeHooksFromSettings() async {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return }

        do {
            let data = try Data(contentsOf: settingsPath)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var hooks = json["hooks"] as? [String: Any] else { return }

            // Remove any hook configs that contain our hud-hook (binary) or hud-state-tracker (legacy)
            for (eventType, eventHooks) in hooks {
                guard var hookArray = eventHooks as? [[String: Any]] else { continue }

                hookArray.removeAll { hookConfig in
                    guard let innerHooks = hookConfig["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.contains { hook in
                        guard let command = hook["command"] as? String else { return false }
                        return command.contains("hud-hook") || command.contains("hud-state-tracker")
                    }
                }

                if hookArray.isEmpty {
                    hooks.removeValue(forKey: eventType)
                } else {
                    hooks[eventType] = hookArray
                }
            }

            json["hooks"] = hooks.isEmpty ? nil : hooks

            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: settingsPath)
            print("[Debug] Removed HUD hooks from settings.json")
        } catch {
            print("[Debug] Failed to remove hooks: \(error)")
        }
    }
    #endif
}

#if DEBUG
struct UITuningPanelMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("UI Tuning Panel") {
            openWindow(id: "ui-tuning-panel")
        }
        .keyboardShortcut("U", modifiers: [.command, .shift])
    }
}

#endif

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app can be activated and receive focus
        NSApp.setActivationPolicy(.regular)

        // Re-validate hook setup on every launch
        // If hooks aren't configured, reset setupComplete to show WelcomeView
        validateHookSetup()
    }

    private func validateHookSetup() {
        guard let engine = try? HudEngine() else { return }

        let hookStatus = engine.getHookStatus()
        if case .notInstalled = hookStatus {
            UserDefaults.standard.set(false, forKey: "setupComplete")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Ensure window becomes key when app activates
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct FloatingWindowConfigurator: NSViewRepresentable {
    let enabled: Bool
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.configureWindow(view.window, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.configureWindow(nsView.window, context: context)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previousFloatingMode: Bool?
    }

    private func configureWindow(_ window: NSWindow?, context: Context) {
        guard let window = window else { return }

        let coordinator = context.coordinator
        // Only clear backgrounds when explicitly transitioning from non-floating to floating
        // Not on initial setup (nil) or when staying in floating mode (true -> true)
        let isTransitioningToFloating = coordinator.previousFloatingMode == false && enabled
        coordinator.previousFloatingMode = enabled

        // Set window level based on alwaysOnTop preference
        if alwaysOnTop {
            window.level = .floating
        } else {
            window.level = .normal
        }

        if enabled {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.titled)
            window.isMovableByWindowBackground = true
            window.titlebarSeparatorStyle = .none

            // Hide traffic light buttons
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            // Only clear backgrounds when transitioning INTO floating mode
            // Not on every window reconfiguration (e.g., alwaysOnTop changes)
            if isTransitioningToFloating, let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = .clear

                // Also clear any SwiftUI hosting view backgrounds
                clearBackgrounds(of: contentView)
            }
        } else {
            window.styleMask.insert(.titled)
            window.isOpaque = true
            window.backgroundColor = NSColor(Color.hudBackground)
            window.hasShadow = true
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.styleMask.remove(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.titlebarSeparatorStyle = .automatic

            // Show traffic light buttons
            window.standardWindowButton(.closeButton)?.isHidden = false
            window.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window.standardWindowButton(.zoomButton)?.isHidden = false
        }
    }

    private func clearBackgrounds(of view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear

        for subview in view.subviews {
            clearBackgrounds(of: subview)
        }
    }
}

struct LayoutModeFrameModifier: ViewModifier {
    let layoutMode: LayoutMode

    func body(content: Content) -> some View {
        switch layoutMode {
        case .vertical:
            content
                .frame(minWidth: 280, maxWidth: 500,
                       minHeight: 400, maxHeight: .infinity)
        case .dock:
            content
                .frame(minWidth: 500, maxWidth: 1600,
                       minHeight: 158, maxHeight: 195)
        }
    }
}

struct WindowFrameConfigurator: NSViewRepresentable {
    let layoutMode: LayoutMode

    func makeNSView(context: Context) -> NSView {
        let view = WindowFrameTrackingView(coordinator: context.coordinator)
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.currentWindow = window
                context.coordinator.lastKnownFrame = window.frame
                context.coordinator.currentLayoutMode = layoutMode
                self.restoreFrame(for: window, mode: layoutMode, coordinator: context.coordinator)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator

        if let previousMode = coordinator.currentLayoutMode, previousMode != layoutMode {
            if let lastFrame = coordinator.lastKnownFrame {
                WindowFrameStore.shared.saveFrame(lastFrame, for: previousMode)
            }

            coordinator.currentLayoutMode = layoutMode

            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                self.restoreFrame(for: window, mode: layoutMode, coordinator: coordinator)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var currentLayoutMode: LayoutMode?
        var lastKnownFrame: NSRect?
        weak var currentWindow: NSWindow?

        func updateFrame(_ frame: NSRect) {
            lastKnownFrame = frame
        }
    }

    private func saveFrame(for window: NSWindow, mode: LayoutMode) {
        WindowFrameStore.shared.saveFrame(window.frame, for: mode)
    }

    private func restoreFrame(for window: NSWindow, mode: LayoutMode, coordinator: Coordinator) {
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        if let savedFrame = WindowFrameStore.shared.loadFrame(for: mode) {
            let clampedFrame = clampFrame(savedFrame, to: screenFrame, for: mode)
            window.setFrame(clampedFrame, display: true, animate: false)
        } else {
            let defaultFrame = defaultFrame(for: mode, in: screenFrame, currentFrame: window.frame)
            window.setFrame(defaultFrame, display: true, animate: false)
        }
    }

    private func defaultFrame(for mode: LayoutMode, in screenFrame: NSRect, currentFrame: NSRect) -> NSRect {
        switch mode {
        case .vertical:
            let width: CGFloat = 360
            let height: CGFloat = 700
            let x = currentFrame.origin.x
            let y = currentFrame.origin.y + currentFrame.height - height
            return NSRect(x: x, y: max(screenFrame.origin.y, y), width: width, height: height)
        case .dock:
            let width: CGFloat = 960
            let height: CGFloat = 175
            let x = screenFrame.origin.x + (screenFrame.width - width) / 2
            let y = screenFrame.origin.y + 20
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }

    private func clampFrame(_ frame: NSRect, to screenFrame: NSRect, for mode: LayoutMode) -> NSRect {
        var result = frame

        let (minW, maxW, minH, maxH): (CGFloat, CGFloat, CGFloat, CGFloat) = switch mode {
        case .vertical: (280, 500, 400, screenFrame.height)
        case .dock: (400, 1200, 120, 180)
        }

        result.size.width = min(max(result.size.width, minW), maxW)
        result.size.height = min(max(result.size.height, minH), maxH)

        if result.origin.x < screenFrame.origin.x {
            result.origin.x = screenFrame.origin.x
        }
        if result.origin.x + result.size.width > screenFrame.maxX {
            result.origin.x = screenFrame.maxX - result.size.width
        }
        if result.origin.y < screenFrame.origin.y {
            result.origin.y = screenFrame.origin.y
        }
        if result.origin.y + result.size.height > screenFrame.maxY {
            result.origin.y = screenFrame.maxY - result.size.height
        }

        return result
    }
}

private class WindowFrameTrackingView: NSView {
    weak var coordinator: WindowFrameConfigurator.Coordinator?
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?

    init(coordinator: WindowFrameConfigurator.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        removeObservers()

        guard let window = window else { return }

        coordinator?.lastKnownFrame = window.frame

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.coordinator?.updateFrame(window.frame)
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.coordinator?.updateFrame(window.frame)
        }
    }

    private func removeObservers() {
        if let observer = resizeObserver {
            NotificationCenter.default.removeObserver(observer)
            resizeObserver = nil
        }
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }
    }

    deinit {
        removeObservers()
    }
}

private struct FloatingModeKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AlwaysOnTopKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var floatingMode: Bool {
        get { self[FloatingModeKey.self] }
        set { self[FloatingModeKey.self] = newValue }
    }

    var alwaysOnTop: Bool {
        get { self[AlwaysOnTopKey.self] }
        set { self[AlwaysOnTopKey.self] = newValue }
    }
}
