import AppKit
import SwiftUI

enum AppLaunchOverrides {
    static func shouldSkipSetupValidation(info: [String: Any]) -> Bool {
        guard let raw = info["CapacitorSkipSetupValidation"] else { return false }
        switch raw {
        case let value as String:
            return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
        case let value as NSNumber:
            return value.intValue != 0
        default:
            return false
        }
    }
}

protocol StartupSetupRuntime: AnyObject, HookRuntimeInstalling {
    func checkSetupStatus() throws -> SetupStatus
    func capacitorDir() -> String
}

extension CoreRuntime: StartupSetupRuntime {}

struct StartupSetupValidationHooks {
    let shouldSkipSetupValidation: () -> Bool
    let makeRuntime: () throws -> any StartupSetupRuntime
    let writeStartupLog: (DebugLog.StartupEvent) -> Void
    let setSetupComplete: (Bool) -> Void
    let isSetupComplete: () -> Bool
    let attemptAutoRepair: (any StartupSetupRuntime) -> Bool
    let installShellIntegrationIfNeeded: () -> Void
    let persistSetupMarker: (String) -> Void

    static func live() -> StartupSetupValidationHooks {
        StartupSetupValidationHooks(
            shouldSkipSetupValidation: {
                AppLaunchOverrides.shouldSkipSetupValidation(info: Bundle.main.infoDictionary ?? [:])
            },
            makeRuntime: { try CoreRuntime() },
            writeStartupLog: { DebugLog.write(startup: $0) },
            setSetupComplete: { UserDefaults.standard.set($0, forKey: "setupComplete") },
            isSetupComplete: { UserDefaults.standard.bool(forKey: "setupComplete") },
            attemptAutoRepair: { engine in
                if let hookInstallError = HookInstaller.ensureHooksInstalled(using: engine) {
                    DebugLog.write(startup: .hooksAutoRepairFailed(error: hookInstallError))
                    return false
                }

                return true
            },
            installShellIntegrationIfNeeded: {
                let shellType = ShellType.current
                if shellType != .unsupported, !shellType.isSnippetInstalled {
                    switch shellType.installSnippet() {
                    case .success:
                        DebugLog.write(startup: .shellIntegrationInstalled(configFile: shellType.configFile))
                    case let .failure(error):
                        // Non-blocking — shell integration is optional
                        DebugLog.write(startup: .shellIntegrationSkipped(reason: error.localizedDescription))
                    }
                }
            },
            persistSetupMarker: { AppDelegate.persistSetupMarker(capacitorRootPath: $0) },
        )
    }
}

enum StartupSetupValidator {
    static func validate(using hooks: StartupSetupValidationHooks = .live()) {
        if hooks.shouldSkipSetupValidation() {
            hooks.setSetupComplete(true)
            return
        }

        let engine: any StartupSetupRuntime
        do {
            engine = try hooks.makeRuntime()
        } catch {
            DebugLog.write("StartupSetupValidator: makeRuntime failed: \(error)")
            return
        }

        let setupStatus: SetupStatus
        do {
            setupStatus = try engine.checkSetupStatus()
        } catch {
            DebugLog.write("StartupSetupValidator: checkSetupStatus failed: \(error)")
            return
        }
        // Rust owns the readiness classification (SetupStatus.readiness); Swift
        // owns which side-effect each variant triggers.
        switch setupStatus.readiness {
        case .ready:
            break
        case .needsUserAction(reason: .claudeMissing):
            hooks.writeStartupLog(.claudeMissing)
            hooks.setSetupComplete(false)
            return
        case let .needsUserAction(reason: .policyBlocked(reason)):
            hooks.writeStartupLog(.hooksBlockedByPolicy(reason: reason))
            hooks.setSetupComplete(false)
            return
        case let .autoRepairable(status):
            hooks.writeStartupLog(.hooksNeedAutoRepair(status: status))
            if hooks.attemptAutoRepair(engine) {
                hooks.writeStartupLog(.hooksAutoRepairSucceeded)
            } else {
                // Repair failed — do NOT mark setup complete.
                // The user will see WelcomeView and can retry manually.
                return
            }
        }

        hooks.installShellIntegrationIfNeeded()
        hooks.persistSetupMarker(engine.capacitorDir())
        if !hooks.isSetupComplete() {
            hooks.writeStartupLog(.autoSetupComplete)
            hooks.setSetupComplete(true)
        }
    }
}

@main
struct CapacitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var updaterController = UpdaterController()
    @AppStorage("floatingMode") private var floatingMode = true
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @AppStorage("layoutMode") private var layoutMode = "vertical"
    @AppStorage("setupComplete") private var setupComplete = false

    private var shouldSkipSetupValidation: Bool {
        AppLaunchOverrides.shouldSkipSetupValidation(info: Bundle.main.infoDictionary ?? [:])
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if setupComplete || shouldSkipSetupValidation {
                    ContentView()
                        .environment(appState)
                        .environment(\.floatingMode, floatingMode)
                        .environment(\.alwaysOnTop, alwaysOnTop)
                        .readReduceMotion()
                        .modifier(LayoutModeFrameModifier(layoutMode: appState.uiState.layoutMode))
                        .background(FloatingWindowConfigurator(enabled: floatingMode, alwaysOnTop: alwaysOnTop, anchoringOwnsLevel: appState.anchoringController.state.isAnchored))
                        .background(WindowFrameConfigurator(layoutMode: appState.uiState.layoutMode))
                        .background(AnchoringConfigurator(controller: appState.anchoringController, enabled: appState.featureState.isWindowAnchoringEnabled))
                        .onAppear {
                            if let mode = LayoutMode(rawValue: layoutMode) {
                                appState.uiState.layoutMode = mode
                            }
                            // Refresh diagnostic after WelcomeView completes (hooks may have just been installed)
                            appState.checkHookDiagnostic()
                        }
                        .onChange(of: layoutMode) { _, newValue in
                            if let mode = LayoutMode(rawValue: newValue) {
                                appState.uiState.layoutMode = mode
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .identity,
                        ))
                } else {
                    WelcomeView(onComplete: {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            setupComplete = true
                        }
                        AppDelegate.persistSetupMarker()
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if floatingMode {
                            DarkFrostedGlass()
                        } else {
                            Color.hudBackground
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: WindowCornerRadius.value(floatingMode: floatingMode)))
                    .overlay { EmptyStateBorderGlow() }
                    .environment(\.floatingMode, floatingMode)
                    .background(FloatingWindowConfigurator(enabled: floatingMode, alwaysOnTop: alwaysOnTop))
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .move(edge: .leading).combined(with: .opacity),
                    ))
                }
            }
            .onAppear {
                appDelegate.appState = appState
            }
            // In floating mode the window keeps `.titled` (for keyability), which
            // makes SwiftUI reserve a title-bar safe area and inset the content —
            // leaving the titlebar region visible as a lighter strip with a top
            // edge highlight. Extend the content under it so it fills to the
            // window's top edge, matching the old borderless look. Docked mode
            // keeps its inset so content stays below the real title bar.
            .ignoresSafeArea(.container, edges: floatingMode ? .top : [])
        }
        .defaultSize(width: 360, height: 700)
        .windowResizability(.contentSize)
        // Hidden title bar at the SwiftUI level so the window never draws a
        // title bar strip in floating mode. The window keeps `.titled` under
        // the hood, so it stays keyable for idea-capture text input. Runtime
        // styleMask mutation alone wasn't authoritative — SwiftUI re-applied
        // its own title bar styling and the strip kept showing.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // MARK: - Capacitor (app menu)

            CommandGroup(replacing: .appInfo) {
                Button("About Capacitor") {
                    appDelegate.showAboutPanel()
                }
            }

            CommandGroup(after: .appInfo) {
                if updaterController.isAvailable {
                    Button("Check for Updates...") {
                        updaterController.checkForUpdates()
                    }
                    .disabled(!updaterController.canCheckForUpdates)
                }
            }

            // MARK: - File menu

            CommandGroup(replacing: .newItem) {
                Button("Connect Project...") {
                    appState.connectProjectViaFileBrowser()
                }
                .keyboardShortcut("O", modifiers: .command)
            }

            CircuitFirstSliceCommands(appState: appState)

            // MARK: - Remove Edit menu

            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .textEditing) {}

            // MARK: - View menu (layout + appearance)

            CommandGroup(replacing: .toolbar) {
                Button("Vertical Layout") {
                    layoutMode = "vertical"
                    appState.uiState.layoutMode = .vertical
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(layoutMode == "vertical")

                Button("Dock Layout") {
                    layoutMode = "dock"
                    appState.uiState.layoutMode = .dock
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(layoutMode == "dock")

                Divider()

                Toggle("Floating Mode", isOn: $floatingMode)
                    .keyboardShortcut("T", modifiers: [.command, .shift])

                Toggle("Always on Top", isOn: $alwaysOnTop)
                    .keyboardShortcut("P", modifiers: [.command, .shift])
            }

            // MARK: - Help menu

            CommandGroup(replacing: .help) {
                Link("Capacitor Help", destination: URL(string: "https://github.com/petekp/capacitor#readme")!)
                    .keyboardShortcut("?", modifiers: [.command, .shift])
                Link("Report a Bug...", destination: URL(string: "https://github.com/petekp/capacitor/issues/new")!)
            }

            // MARK: - Debug menu (DEBUG only)

            #if DEBUG
                AppDebugCommands(appState: appState, setupComplete: $setupComplete)
            #endif
        }

        Settings {
            SettingsView(updaterController: updaterController)
        }

        Window("Delegation Review", id: "delegation-review") {
            DelegationReviewWindow()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 900, height: 650)
        .windowResizability(.contentMinSize)
        .suppressedFromWindowMenu()

        Window("Run Checkpoint", id: "run-checkpoint-review") {
            RunCheckpointReviewWindow()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 900, height: 650)
        .windowResizability(.contentMinSize)
        .suppressedFromWindowMenu()

        Window("Circuit Receipt", id: CircuitFirstSliceWindowID.receiptRendering) {
            ReceiptProofRenderingWindow()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultPosition(.topTrailing)
        .defaultSize(width: 760, height: 620)

        Window("Claude Circuit Receipt", id: CircuitFirstSliceWindowID.claudeReceiptRendering) {
            let paths = CircuitReceiptProductLoopPaths()
            ReceiptProofRenderingWindow(
                store: ReceiptProofRenderingStore(
                    resultURL: ReceiptFirstProofArtifacts(proofDirectoryURL: paths.nativeSessionDirectory).resultURL,
                    agentEventURL: paths.agentEventURL,
                ),
            )
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultPosition(.topTrailing)
        .defaultSize(width: 760, height: 620)

        #if DEBUG
            AppDebugWindows(appState: appState)
        #endif
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: NSObjectProtocol?
    weak var appState: AppState?

    func applicationDidFinishLaunching(_: Notification) {
        // Ensure the app can be activated and receive focus
        NSApp.setActivationPolicy(.regular)

        // Re-validate hook setup on every launch.
        // Only Claude-missing and policy-blocked states should still gate startup.
        validateHookSetup()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil,
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil,
        )

        // Lift subsidiary windows (Settings, About, Sparkle) above the main window
        // when always-on-top is active, so they aren't hidden behind it
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main,
        ) { notification in
            let window = notification.object as? NSWindow
            Self.liftSubsidiaryWindowIfNeeded(window)
            if let window {
                WindowAXDiagnostics.log(context: "didBecomeKey", window: window)
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        appState?.shutdown()
    }

    @MainActor
    @objc func systemWillSleep(_ notification: Notification) {
        _ = notification
        guard let client = appState?.systemPowerRuntimeClient else { return }
        _Concurrency.Task {
            try? await client.reportSleep()
        }
    }

    @MainActor
    @objc func systemDidWake(_ notification: Notification) {
        _ = notification
        guard let client = appState?.systemPowerRuntimeClient else { return }
        _Concurrency.Task {
            try? await client.reportWake()
        }
    }

    /// Shows a custom About panel with the app icon and version info
    @objc func showAboutPanel() {
        // Use the app icon so About stays aligned with the current branded iconset.
        let aboutIcon = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage

        // Get version from multiple sources (release builds have correct Info.plist, dev builds don't)
        let version = Self.getAppVersion()

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Capacitor",
            .applicationVersion: version,
        ]

        options[.applicationIcon] = aboutIcon

        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    /// Gets the app version from the best available source:
    /// 1. Info.plist (correct in release builds)
    /// 2. VERSION file in project root (works in dev builds)
    /// 3. Hardcoded fallback (updated by bump-version.sh)
    private static func getAppVersion() -> String {
        // Try Info.plist first (correct in release builds, set by build-distribution.sh)
        if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           bundleVersion != "1.0"
        {
            return bundleVersion
        }

        // Dev build fallback: read VERSION file from project root
        // This works because dev builds typically run from the project directory
        if let versionData = FileManager.default.contents(atPath: "VERSION"),
           let version = String(data: versionData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            return version
        }

        // Ultimate fallback (kept in sync by bump-version.sh)
        return "0.2.0-alpha.3"
    }

    /// Attempt silent auto-setup on every launch.
    /// Only shows WelcomeView if something genuinely needs user attention
    /// (e.g. Claude CLI not installed or policy blocked).
    private func validateHookSetup() {
        StartupSetupValidator.validate()
    }

    fileprivate static func persistSetupMarker(capacitorRootPath: String? = nil) {
        let capacitorRootURL = capacitorRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? CapacitorProjectPaths.capacitorRoot()
        let markerURL = capacitorRootURL.appendingPathComponent("setup_complete")

        do {
            try FileManager.default.createDirectory(
                at: capacitorRootURL,
                withIntermediateDirectories: true,
            )
            try Data("complete".utf8).write(to: markerURL, options: .atomic)
        } catch {
            DebugLog.write("[Startup] Failed to persist setup marker: \(error.localizedDescription)")
        }
    }

    /// When always-on-top is active, subsidiary windows (Settings, About, Sparkle
    /// update dialogs) are created at `.normal` level and get hidden behind the
    /// `.floating` main window. This lifts them one level above so they stay visible.
    private static func liftSubsidiaryWindowIfNeeded(_ window: NSWindow?) {
        guard let window else { return }

        let alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        guard alwaysOnTop else { return }

        // Find the main content window — it's the one we set to .floating
        let mainWindow = NSApp.windows.first { $0.level == .floating }
        guard window !== mainWindow else { return }

        // Lift this subsidiary window above the main floating window
        window.level = NSWindow.Level(NSWindow.Level.floating.rawValue + 1)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }

    func applicationDidBecomeActive(_: Notification) {
        // Ensure window becomes key when app activates
        WindowAXDiagnostics.logApplicationDidBecomeActive(windowCount: NSApp.windows.count)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            WindowAXDiagnostics.log(context: "applicationDidBecomeActive", window: window)
        }
    }
}

struct FloatingWindowConfigurator: NSViewRepresentable {
    let enabled: Bool
    let alwaysOnTop: Bool
    var anchoringOwnsLevel: Bool = false

    static func floatingStyleMask(from styleMask: NSWindow.StyleMask) -> NSWindow.StyleMask {
        var styleMask = styleMask
        // New floating behavior: keep `.titled` so the standard SwiftUI window
        // remains keyable for text input. The legacy path removed it, which made
        // idea capture intermittently impossible to focus in floating mode.
        styleMask.insert(.titled)
        styleMask.insert(.fullSizeContentView)
        return styleMask
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(view.window, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(nsView.window, context: context)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previousFloatingMode: Bool?
    }

    private func configureWindow(_ window: NSWindow?, context: Context) {
        guard let window else { return }

        let coordinator = context.coordinator
        // Only clear backgrounds when explicitly transitioning from non-floating to floating
        // Not on initial setup (nil) or when staying in floating mode (true -> true)
        let isTransitioningToFloating = coordinator.previousFloatingMode == false && enabled
        coordinator.previousFloatingMode = enabled

        // Set window level based on alwaysOnTop preference — unless anchoring owns it
        if !anchoringOwnsLevel {
            window.level = alwaysOnTop ? .floating : .normal
        }

        if enabled {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask = Self.floatingStyleMask(from: window.styleMask)
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

struct AnchoringConfigurator: NSViewRepresentable {
    let controller: WindowAnchoringController
    let enabled: Bool

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        if enabled {
            DispatchQueue.main.async {
                if let window = view.window {
                    controller.configure(hudWindow: window)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        if enabled {
            DispatchQueue.main.async {
                if let window = nsView.window {
                    controller.configure(hudWindow: window)
                }
            }
        } else {
            controller.detach()
        }
    }
}

struct LayoutModeFrameModifier: ViewModifier {
    let layoutMode: LayoutMode
    private let glassConfig = GlassConfig.shared

    func body(content: Content) -> some View {
        switch layoutMode {
        case .vertical:
            content
                .frame(minWidth: 200, maxWidth: 380,
                       minHeight: 400, maxHeight: .infinity)
        case .dock:
            content
                .frame(minWidth: 500, maxWidth: 1600,
                       minHeight: glassConfig.dockWindowMinHeightRounded,
                       maxHeight: glassConfig.dockWindowMaxHeightRounded)
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
                restoreFrame(for: window, mode: layoutMode, coordinator: context.coordinator)
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
                restoreFrame(for: window, mode: layoutMode, coordinator: coordinator)
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
        private var terminationObserver: NSObjectProtocol?

        init() {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                self?.persistCurrentFrame()
            }
        }

        deinit {
            if let observer = terminationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func updateFrame(_ frame: NSRect) {
            lastKnownFrame = frame
            persistCurrentFrame()
        }

        private func persistCurrentFrame() {
            guard let mode = currentLayoutMode, let frame = lastKnownFrame else { return }
            WindowFrameStore.shared.saveFrame(frame, for: mode)
        }
    }

    private func saveFrame(for window: NSWindow, mode: LayoutMode) {
        WindowFrameStore.shared.saveFrame(window.frame, for: mode)
    }

    private func restoreFrame(for window: NSWindow, mode: LayoutMode, coordinator _: Coordinator) {
        if let savedFrame = WindowFrameStore.shared.loadFrame(for: mode) {
            // Find the screen where the frame was saved (coordinates encode which monitor)
            let targetScreen = screen(for: savedFrame) ?? window.screen ?? NSScreen.main
            let screenFrame = targetScreen?.visibleFrame ?? .zero
            let clampedFrame = clampFrame(savedFrame, to: screenFrame, for: mode)
            window.setFrame(clampedFrame, display: true, animate: false)
        } else {
            // No saved frame — place on whichever screen the window is currently on
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let defaultFrame = defaultFrame(for: mode, in: screenFrame, currentFrame: window.frame)
            window.setFrame(defaultFrame, display: true, animate: false)
        }
    }

    /// Find the screen whose frame contains the center of the given rect.
    /// Returns nil if no screen matches (e.g. the monitor was disconnected).
    private func screen(for frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
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

        let glassConfig = GlassConfig.shared
        let (minW, maxW, minH, maxH): (CGFloat, CGFloat, CGFloat, CGFloat) = switch mode {
        case .vertical: (280, 500, 400, screenFrame.height)
        case .dock: (400, 1200, glassConfig.dockWindowMinHeightRounded, glassConfig.dockWindowMaxHeightRounded)
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

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        removeObservers()

        guard let window else { return }

        coordinator?.lastKnownFrame = window.frame

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main,
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.coordinator?.updateFrame(window.frame)
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main,
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

extension EnvironmentValues {
    @Entry var floatingMode: Bool = false

    @Entry var alwaysOnTop: Bool = false
}

extension Scene {
    /// Hides this Window from the auto-generated Window menu on macOS 15+.
    /// On macOS 14 this is a no-op (the entry remains in the Window menu).
    func suppressedFromWindowMenu() -> some Scene {
        if #available(macOS 15.0, *) {
            return defaultLaunchBehavior(.suppressed)
        } else {
            return self
        }
    }
}
