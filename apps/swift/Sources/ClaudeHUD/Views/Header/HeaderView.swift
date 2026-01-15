import SwiftUI
import AppKit

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.alwaysOnTop) private var alwaysOnTop
    @AppStorage("alwaysOnTop") private var alwaysOnTopStorage = false

    var body: some View {
        HStack(spacing: 16) {
            PinButton(isPinned: $alwaysOnTopStorage)

            Spacer()

            AddProjectButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.top, floatingMode ? 8 : 0)
        .background(floatingMode ? Color.clear : Color.hudBackground)
    }
}

struct PinButton: View {
    @Binding var isPinned: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: { isPinned.toggle() }) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isPinned ? .white : .white.opacity(isHovered ? 0.7 : 0.4))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0))
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(isHovered ? 0.15 : 0),
                            lineWidth: 0.5
                        )
                )
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin window (⌘⇧P)" : "Pin window to stay on top (⌘⇧P)")
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

struct AddProjectButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        Button(action: openFolderPicker) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .medium))

                Text("Add Project")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(isHovered ? 0.15 : 0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project folder to add"
        panel.prompt = "Add Project"

        if panel.runModal() == .OK, let url = panel.url {
            appState.addProject(url.path)
        }
    }
}

