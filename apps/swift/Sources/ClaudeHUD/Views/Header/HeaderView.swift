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

// MARK: - Header View

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    private let headerBlurHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                CapacitorLogo()

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
                ZStack {
                    // Within-window blur - blurs the content scrolling underneath
                    VibrancyView(
                        material: .hudWindow,
                        blendingMode: .withinWindow,
                        isEmphasized: true,
                        forceDarkAppearance: true
                    )

                    // Behind-window blur - blurs the desktop/apps behind
                    VibrancyView(
                        material: .hudWindow,
                        blendingMode: .behindWindow,
                        isEmphasized: true,
                        forceDarkAppearance: true
                    )
                    .opacity(0.5)

                    Color.black.opacity(0.15)
                }
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
        Menu {
            Button {
                appState.showAddLink()
            } label: {
                Label("Link Existing", systemImage: "folder.badge.plus")
            }

            Button {
                appState.showNewIdea()
            } label: {
                Label("Create with Claude", systemImage: "sparkles")
            }
        } label: {
            HStack(spacing: 4) {
                Text("Add Project")
                    .font(AppTypography.bodySecondary.weight(.medium))

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(isHovered ? 0.1 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(isHovered ? 0.15 : 0), lineWidth: 0.5)
            )
            .animation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15), value: isHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Add project")
        .accessibilityHint("Opens options to link an existing project or create a new one")
        .background(
            HoverTrackingView { hovering in
                isHovered = hovering
            }
        )
    }
}

/// Uses NSTrackingArea for reliable hover detection that works with SwiftUI Menu
private struct HoverTrackingView: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHover = onHover
    }
}

private class HoverTrackingNSView: NSView {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

private struct AddProjectMenuLabel: View {
    let isHovered: Bool
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Text("Add Project")
                .font(AppTypography.bodySecondary.weight(.medium))

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.red : Color.clear) // DEBUG: red on hover
        )
        .animation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15), value: isHovered)
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

struct CapacitorLogo: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    private let logoText = "CAPACITOR"

    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    @State private var shaderTime: Double = 0
    private let timer = Timer.publish(every: 1/60, on: .main, in: .common).autoconnect()
    #endif

    private var fontSize: CGFloat {
        #if DEBUG
        CGFloat(config.logoFontSize)
        #else
        13.0
        #endif
    }

    private var tracking: CGFloat {
        #if DEBUG
        CGFloat(config.logoTracking)
        #else
        1.5
        #endif
    }

    private var baseOpacity: Double {
        #if DEBUG
        config.logoBaseOpacity
        #else
        0.25
        #endif
    }

    private var shadowOpacity: Double {
        #if DEBUG
        config.logoShadowOpacity
        #else
        0.6
        #endif
    }

    private var shadowOffset: CGSize {
        #if DEBUG
        CGSize(width: config.logoShadowOffsetX, height: config.logoShadowOffsetY)
        #else
        CGSize(width: 0.8, height: 0.8)
        #endif
    }

    private var shadowBlur: CGFloat {
        #if DEBUG
        CGFloat(config.logoShadowBlur)
        #else
        0.8
        #endif
    }

    private var highlightOpacity: Double {
        #if DEBUG
        config.logoHighlightOpacity
        #else
        0.3
        #endif
    }

    private var highlightOffset: CGSize {
        #if DEBUG
        CGSize(width: config.logoHighlightOffsetX, height: config.logoHighlightOffsetY)
        #else
        CGSize(width: -0.5, height: -0.5)
        #endif
    }

    private var highlightBlur: CGFloat {
        #if DEBUG
        CGFloat(config.logoHighlightBlur)
        #else
        0.5
        #endif
    }

    private var shadowBlendMode: BlendMode {
        #if DEBUG
        config.logoShadowBlendMode
        #else
        .multiply
        #endif
    }

    private var highlightBlendMode: BlendMode {
        #if DEBUG
        config.logoHighlightBlendMode
        #else
        .plusLighter
        #endif
    }

    private var logoFont: Font {
        .system(size: fontSize, weight: .black, design: .monospaced)
    }

    private func baseText(_ color: Color = .white) -> some View {
        Text(logoText)
            .font(logoFont)
            .tracking(tracking)
            .foregroundColor(color)
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                appState.showProjectList()
            }
        } label: {
            logoContent
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1.0 : 0.85)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Return to project list")
    }

    @ViewBuilder
    private var logoContent: some View {
        #if DEBUG
        if config.logoShaderEnabled {
            shaderLogo
                .onReceive(timer) { _ in
                    shaderTime += 1/60
                }
        } else {
            letterpressLogo
        }
        #else
        letterpressLogo
        #endif
    }

    private var letterpressLogo: some View {
        baseText(.white.opacity(baseOpacity))
            .overlay {
                baseText(.black)
                    .blur(radius: shadowBlur)
                    .offset(x: shadowOffset.width, y: shadowOffset.height)
                    .mask(baseText(.white))
                    .opacity(shadowOpacity)
                    .blendMode(shadowBlendMode)
            }
            .overlay {
                baseText(.white)
                    .blur(radius: highlightBlur)
                    .offset(x: highlightOffset.width, y: highlightOffset.height)
                    .mask(baseText(.white))
                    .opacity(highlightOpacity)
                    .blendMode(highlightBlendMode)
            }
    }

    #if DEBUG
    @ViewBuilder
    private var shaderLogo: some View {
        let shaderContent: some View = baseText(.white)
            .hidden()
            .overlay {
                GlassShaderView(config: config, time: shaderTime)
                    .mask(baseText(.white))
            }

        if config.logoShaderVibrancyEnabled {
            ZStack {
                // Vibrancy glow layer - extends slightly beyond text
                VibrancyView(
                    material: .hudWindow,
                    blendingMode: .withinWindow,
                    isEmphasized: true,
                    forceDarkAppearance: true
                )
                .mask(
                    baseText(.white)
                        .blur(radius: config.logoShaderVibrancyBlur)
                )
                .blendMode(.plusLighter)

                // Shader content on top
                shaderContent
                    .opacity(config.logoShaderOpacity)
                    .blendMode(config.logoShaderBlendMode)
            }
            .fixedSize()
        } else {
            shaderContent
                .opacity(config.logoShaderOpacity)
                .blendMode(config.logoShaderBlendMode)
        }
    }
    #endif
}

private struct PopoverOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button {
            print("🟢 PopoverOptionButton '\(title)' CLICKED")
            action()
        } label: {
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
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(isHovered ? 0.1 : 0))
            )
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

