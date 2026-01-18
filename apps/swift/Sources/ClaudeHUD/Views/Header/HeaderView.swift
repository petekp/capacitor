import SwiftUI
import AppKit

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.alwaysOnTop) private var alwaysOnTop
    @AppStorage("alwaysOnTop") private var alwaysOnTopStorage = false

    private let headerBlurHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                PinButton(isPinned: $alwaysOnTopStorage)

                Spacer()

                AddProjectButton()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .padding(.top, floatingMode ? 8 : 0)

            if floatingMode {
                Spacer()
                    .frame(height: headerBlurHeight - 52)
            }
        }
        .frame(height: floatingMode ? headerBlurHeight : nil)
        .background {
            if floatingMode {
                VibrancyView(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    isEmphasized: true,
                    forceDarkAppearance: true
                )
                .overlay(Color.black.opacity(0.15))
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.55),
                            .init(color: .white.opacity(0.8), location: 0.7),
                            .init(color: .white.opacity(0.4), location: 0.85),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            } else {
                Color.hudBackground
            }
        }
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
    @State private var showingPopover = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: { showingPopover = true }) {
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
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            AddProjectPopover(
                onLinkExisting: {
                    showingPopover = false
                    appState.showAddLink()
                },
                onCreateNew: {
                    showingPopover = false
                    appState.showNewIdea()
                }
            )
        }
    }
}

struct AddProjectPopover: View {
    let onLinkExisting: () -> Void
    let onCreateNew: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            PopoverOptionButton(
                icon: "folder.badge.plus",
                title: "Link Existing",
                subtitle: "Add a project folder",
                action: onLinkExisting
            )

            PopoverOptionButton(
                icon: "sparkles",
                title: "Create with Claude",
                subtitle: "Scaffold a new project",
                action: onCreateNew
            )
        }
        .padding(8)
    }
}

private struct PopoverOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTypography.bodySecondary.weight(.medium))
                        .foregroundColor(.white.opacity(0.9))

                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(isHovered ? 0.1 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

