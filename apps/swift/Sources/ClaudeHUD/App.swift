import SwiftUI
import AppKit

@main
struct ClaudeHUDApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("transparentMode") private var transparentMode = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environment(\.transparentMode, transparentMode)
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 500,
                       minHeight: 400, idealHeight: 700, maxHeight: .infinity)
                .background {
                    if transparentMode {
                        VisualEffectBackground()
                            .ignoresSafeArea()
                    }
                }
        }
        .defaultSize(width: 360, height: 700)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appSettings) {
                Toggle("Transparent Mode", isOn: $transparentMode)
                    .keyboardShortcut("T", modifiers: [.command, .shift])
            }
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct TransparentModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var transparentMode: Bool {
        get { self[TransparentModeKey.self] }
        set { self[TransparentModeKey.self] = newValue }
    }
}
