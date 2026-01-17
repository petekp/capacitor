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
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: { isPinned.toggle() }) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(AppTypography.bodySecondary.weight(.medium))
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
        .accessibilityLabel(isPinned ? "Unpin window" : "Pin window to stay on top")
        .accessibilityHint("Press Command Shift P to toggle")
        .accessibilityAddTraits(isPinned ? .isSelected : [])
        .scaleEffect(isHovered && !reduceMotion ? 1.05 : 1.0)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

struct AddProjectButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: { appState.showAddProject() }) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(AppTypography.cardTitle)

                Text("Add Project")
                    .font(AppTypography.bodySecondary.weight(.medium))
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
        .accessibilityLabel("Add project")
        .accessibilityHint("Opens options to link an existing project or create a new one")
        .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

