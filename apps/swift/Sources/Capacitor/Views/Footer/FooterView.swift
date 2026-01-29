import SwiftUI
import AppKit

// MARK: - First Mouse Click Support for Popovers

/// Enables click-through for inactive windows (fixes popover two-click issue).
/// Must be applied directly to buttons, not containers.
/// See: https://christiantietze.de/posts/2024/04/enable-swiftui-button-click-through-inactive-windows/
private struct ClickThroughBackdrop<Content: View>: NSViewRepresentable {
    final class Backdrop: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }
    }

    let content: Content

    init(_ content: Content) {
        self.content = content
    }

    func makeNSView(context: Context) -> Backdrop {
        let backdrop = Backdrop(rootView: content)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        return backdrop
    }

    func updateNSView(_ nsView: Backdrop, context: Context) {
        nsView.rootView = content
    }
}

extension View {
    /// Enables this view to receive clicks even when its window is inactive.
    fileprivate func acceptClickThrough() -> some View {
        ClickThroughBackdrop(self)
    }
}

// MARK: - Footer View

struct FooterView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Binding var isPinned: Bool

    private let progressiveBlurHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            // Progressive blur zone - fades content above into the footer
            ProgressiveBlurView(
                direction: .up,
                height: progressiveBlurHeight,
                material: floatingMode ? .hudWindow : .windowBackground
            )
            .allowsHitTesting(false)

            // Footer content
            ZStack {
                LogoView()

                HStack {
                    Spacer()
                    PinButton(isPinned: $isPinned)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .padding(.bottom, floatingMode ? 6 : 0)
            .background {
                if floatingMode {
                    // In floating mode, blend with the panel's frosted glass
                    VibrancyView(
                        material: .hudWindow,
                        blendingMode: .behindWindow,
                        isEmphasized: false,
                        forceDarkAppearance: true
                    )
                } else {
                    Color.hudBackground
                }
            }
        }
    }
}

struct LogoView: View {
    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    private let baseHeight: CGFloat = 14

    private var logoImage: NSImage? {
        guard let url = ResourceBundle.url(forResource: "logo", withExtension: "pdf") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    #if DEBUG
    private var selectedMaterial: NSVisualEffectView.Material {
        switch config.logoMaterialType {
        case 0: return .hudWindow
        case 1: return .popover
        case 2: return .menu
        case 3: return .sidebar
        case 4: return .fullScreenUI
        default: return .hudWindow
        }
    }

    private var selectedBlendingMode: NSVisualEffectView.BlendingMode {
        switch config.logoBlendingMode {
        case 0: return .behindWindow
        case 1: return .withinWindow
        default: return .behindWindow
        }
    }

    private var selectedSwiftUIBlendMode: BlendMode {
        switch config.logoSwiftUIBlendMode {
        case 0: return .normal
        case 1: return .plusLighter
        case 2: return .softLight
        case 3: return .overlay
        case 4: return .screen
        case 5: return .multiply
        case 6: return .difference
        case 7: return .colorDodge
        case 8: return .hardLight
        case 9: return .luminosity
        default: return .normal
        }
    }
    #endif

    var body: some View {
        if let nsImage = logoImage {
            #if DEBUG
            logoContent(nsImage: nsImage)
                .id(config.logoConfigHash)
            #else
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: baseHeight)
                .foregroundStyle(.white.opacity(0.7))
            #endif
        }
    }

    #if DEBUG
    @ViewBuilder
    private func logoContent(nsImage: NSImage) -> some View {
        if config.logoUseVibrancy {
            ZStack {
                VibrancyView(
                    material: selectedMaterial,
                    blendingMode: selectedBlendingMode,
                    isEmphasized: config.logoEmphasized,
                    forceDarkAppearance: config.logoForceDarkAppearance
                )

                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: baseHeight * config.logoScale)
                    .foregroundStyle(.white.opacity(config.logoOpacity))
                    .blendMode(selectedSwiftUIBlendMode)
            }
            .fixedSize()
        } else {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: baseHeight * config.logoScale)
                .foregroundStyle(.white.opacity(config.logoOpacity))
                .blendMode(selectedSwiftUIBlendMode)
        }
    }
    #endif
}

struct PinButton: View {
    @Binding var isPinned: Bool
    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: { isPinned.toggle() }) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(AppTypography.bodySecondary.weight(.medium))
                .foregroundColor(.white.opacity(isHovered ? 0.7 : 0.4))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
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
        Button {
            appState.connectProjectViaFileBrowser()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))

                Text("Connect Project")
                    .font(AppTypography.bodySecondary.weight(.medium))
            }
            .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    VibrancyView(
                        material: .hudWindow,
                        blendingMode: .behindWindow,
                        isEmphasized: true,
                        forceDarkAppearance: true
                    )

                    Color.black.opacity(isHovered ? 0.25 : 0.35)

                    LinearGradient(
                        colors: [
                            .white.opacity(isHovered ? 0.08 : 0.05),
                            .white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isHovered ? 0.25 : 0.15),
                                .white.opacity(isHovered ? 0.12 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .animation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Connect project")
        .accessibilityHint("Opens file browser to select a project folder")
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

