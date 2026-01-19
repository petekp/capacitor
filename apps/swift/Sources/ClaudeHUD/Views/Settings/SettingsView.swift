import SwiftUI

struct SettingsView: View {
    @ObservedObject var updaterController: UpdaterController
    @AppStorage("floatingMode") private var floatingMode = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @AppStorage("playReadyChime") private var playReadyChime = true

    private var lastCheckString: String {
        if let date = updaterController.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return "Never"
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Floating Mode", isOn: $floatingMode)
                    .accessibilityLabel("Floating mode")
                    .accessibilityHint("When enabled, the window has no title bar and can be positioned anywhere")

                Toggle("Always on Top", isOn: $alwaysOnTop)
                    .accessibilityLabel("Always on top")
                    .accessibilityHint("When enabled, the window stays above other windows")
            }

            Section("Notifications") {
                Toggle("Play Ready Chime", isOn: $playReadyChime)
                    .accessibilityLabel("Play ready chime")
                    .accessibilityHint("Play a sound when Claude finishes a task and is ready for input")
            }

            if updaterController.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $updaterController.automaticallyChecksForUpdates)
                        .accessibilityLabel("Automatic update checks")
                        .accessibilityHint("When enabled, Claude HUD will periodically check for new versions")

                    HStack {
                        LabeledContent("Last checked", value: lastCheckString)
                        Spacer()
                        Button("Check Now") {
                            updaterController.checkForUpdates()
                        }
                        .disabled(!updaterController.canCheckForUpdates)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .accessibilityLabel("Version")
                    .accessibilityValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")

                Link("Claude HUD on GitHub", destination: URL(string: "https://github.com/anthropics/claude-hud")!)
                    .accessibilityLabel("Open Claude HUD on GitHub")
            }

            Section("Keyboard Shortcuts") {
                KeyboardShortcutRow(label: "Toggle Floating Mode", shortcut: "⌘⇧T")
                KeyboardShortcutRow(label: "Toggle Always on Top", shortcut: "⌘⇧P")
                KeyboardShortcutRow(label: "Navigate Back", shortcut: "⌘[")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 420)
    }
}

struct KeyboardShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), keyboard shortcut \(shortcut)")
    }
}

#Preview {
    SettingsView(updaterController: UpdaterController())
}
