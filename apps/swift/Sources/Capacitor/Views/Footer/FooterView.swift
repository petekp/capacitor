import AppKit
import SwiftUI

// MARK: - First Mouse Click Support for Popovers

/// Enables click-through for inactive windows (fixes popover two-click issue).
/// Must be applied directly to buttons, not containers.
/// See: https://christiantietze.de/posts/2024/04/enable-swiftui-button-click-through-inactive-windows/
private struct ClickThroughBackdrop<Content: View>: NSViewRepresentable {
    final class Backdrop: NSHostingView<Content> {
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
        }
    }

    let content: Content

    init(_ content: Content) {
        self.content = content
    }

    func makeNSView(context _: Context) -> Backdrop {
        let backdrop = Backdrop(rootView: content)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        return backdrop
    }

    func updateNSView(_ nsView: Backdrop, context _: Context) {
        nsView.rootView = content
    }
}

private extension View {
    /// Enables this view to receive clicks even when its window is inactive.
    func acceptClickThrough() -> some View {
        ClickThroughBackdrop(self)
    }
}

// MARK: - Footer View

struct FooterView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion
    @Binding var isPinned: Bool
    @State private var footerWidth: CGFloat = .infinity
    @State private var logoHidden = false

    /// Hysteresis thresholds to prevent logo flicker during live resize.
    private let logoHideThreshold: CGFloat = 205
    private let logoShowThreshold: CGFloat = 220

    private enum FooterMode: Equatable {
        case normal
        case browse
        case connectCTA
    }

    private var mode: FooterMode {
        if !appState.selectedSuggestedPaths.isEmpty {
            return .connectCTA
        }
        if !appState.isLoading, appState.projects.isEmpty {
            return .browse
        }
        return .normal
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Default footer content — pin, logo, add button
                defaultContent
                    .opacity(mode == .normal ? 1 : 0)
                    .offset(y: mode == .normal ? 0 : 8)

                // Browse CTA — shown in empty state before any suggestions are selected
                browseContent
                    .opacity(mode == .browse ? 1 : 0)
                    .offset(y: mode == .browse ? 0 : 8)

                // Connect CTA — shown when suggestions are selected
                ctaContent
                    .opacity(mode == .connectCTA ? 1 : 0)
                    .offset(y: mode == .connectCTA ? 0 : 8)
            }
            .animation(
                reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.35, dampingFraction: 0.8),
                value: mode,
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .padding(.bottom, floatingMode ? 6 : 0)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            footerWidth = geo.size.width
                            logoHidden = footerWidth < logoHideThreshold
                        }
                        .onChange(of: geo.size.width) { _, newWidth in
                            footerWidth = newWidth
                            if !logoHidden, newWidth < logoHideThreshold {
                                logoHidden = true
                            } else if logoHidden, newWidth > logoShowThreshold {
                                logoHidden = false
                            }
                        }
                }
            }
            .background {
                floatingMode ? Color.clear : Color.hudBackground
            }
        }
    }

    private var defaultContent: some View {
        ZStack {
            HStack {
                PinButton(isPinned: $isPinned)
                Spacer()
            }
            LogoView()
                .padding(.horizontal, logoHidden ? -7 : 0)
                .opacity(logoHidden ? 0 : 1)
                .scaleEffect(logoHidden ? 0.9 : 1)
                .blur(radius: logoHidden ? 4 : 0)
                .animation(.linear(duration: 0.09), value: logoHidden)
            HStack {
                Spacer()
                AddProjectPillButton()
            }
        }
    }

    private var browseContent: some View {
        HStack {
            PinButton(isPinned: $isPinned)
            Spacer()
            BrowseProjectsButton {
                appState.connectProjectViaFileBrowser()
            }
            Spacer()
            AddProjectPillButton()
        }
    }

    private var ctaContent: some View {
        HStack {
            Spacer()
            ConnectProjectsCTAButton(count: appState.selectedSuggestedPaths.count) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    appState.connectSelectedSuggestions()
                }
            }
            Spacer()
        }
    }
}

private struct BrowseProjectsButton: View {
    @Environment(\.prefersReducedMotion) private var reduceMotion

    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Browse")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.55))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0.05)),
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(isHovered ? 0.2 : 0.1), lineWidth: 0.5),
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
        .animation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Browse folders to connect a project")
    }
}

private struct ConnectProjectsCTAButton: View {
    @Environment(\.prefersReducedMotion) private var reduceMotion

    let count: Int
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(count > 1 ? "Connect \(count) Projects" : "Connect Project")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.9))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.hudAccent.opacity(isHovered ? 0.6 : 0.45)),
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.hudAccent.opacity(isHovered ? 0.4 : 0.2), lineWidth: 0.5),
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
        .animation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Connect \(count) selected project\(count == 1 ? "" : "s")")
    }
}

private struct AddProjectPillButton: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.prefersReducedMotion) private var reduceMotion

    @State private var isHovered = false

    var body: some View {
        Button {
            appState.connectProjectViaFileBrowser()
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(isHovered ? 0.7 : 0.4))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0)),
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(isHovered ? 0.15 : 0),
                            lineWidth: 0.5,
                        ),
                )
        }
        .buttonStyle(.plain)
        .help("Connect a project")
        .accessibilityLabel("Browse folders to connect a project")
        .accessibilityHint("Opens file browser to select a project folder")
        .scaleEffect(isHovered && !reduceMotion ? 1.05 : 1.0)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

struct LogoView: View {
    #if DEBUG
        private let config = GlassConfig.shared
    #endif

    private let baseHeight: CGFloat = 14
    #if !DEBUG
        private let releaseLogoScale: CGFloat = 0.84
        private let releaseLogoOpacity: Double = 0.22
        private let releaseLogoBlendMode: BlendMode = .overlay
    #endif

    private static let cachedLogoImage: NSImage? = {
        guard let url = ResourceBundle.url(forResource: "logo-small", withExtension: "pdf") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    private var logoImage: NSImage? {
        Self.cachedLogoImage
    }

    #if DEBUG
        private var selectedMaterial: NSVisualEffectView.Material {
            switch config.logoMaterialType {
            case 0: .hudWindow
            case 1: .popover
            case 2: .menu
            case 3: .sidebar
            case 4: .fullScreenUI
            default: .hudWindow
            }
        }

        private var selectedBlendingMode: NSVisualEffectView.BlendingMode {
            switch config.logoBlendingMode {
            case 0: .behindWindow
            case 1: .withinWindow
            default: .behindWindow
            }
        }

        private var selectedSwiftUIBlendMode: BlendMode {
            switch config.logoSwiftUIBlendMode {
            case 0: .normal
            case 1: .plusLighter
            case 2: .softLight
            case 3: .overlay
            case 4: .screen
            case 5: .multiply
            case 6: .difference
            case 7: .colorDodge
            case 8: .hardLight
            case 9: .luminosity
            default: .normal
            }
        }
    #endif

    var body: some View {
        if let nsImage = logoImage {
            #if DEBUG
                logoContent(nsImage: nsImage)
                    .id(config.logoConfigHash)
            #else
                releaseLogoContent(nsImage: nsImage)
            #endif
        }
    }

    #if DEBUG
        @ViewBuilder
        private func logoContent(nsImage: NSImage) -> some View {
            if config.logoUseVibrancy {
                let logoShape = Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: baseHeight * config.logoScale)

                ZStack {
                    VibrancyView(
                        material: selectedMaterial,
                        blendingMode: selectedBlendingMode,
                        isEmphasized: config.logoEmphasized,
                        forceDarkAppearance: config.logoForceDarkAppearance,
                    )
                    .mask(logoShape)

                    logoShape
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

    #if !DEBUG
        private func releaseLogoContent(nsImage: NSImage) -> some View {
            let logoShape = Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: baseHeight * releaseLogoScale)

            return ZStack {
                VibrancyView(
                    material: .menu,
                    blendingMode: .behindWindow,
                    isEmphasized: false,
                    forceDarkAppearance: true,
                )
                .mask(logoShape)

                logoShape
                    .foregroundStyle(.white.opacity(releaseLogoOpacity))
                    .blendMode(releaseLogoBlendMode)
            }
            .fixedSize()
        }
    #endif
}

struct PinButton: View {
    @Environment(\.prefersReducedMotion) private var reduceMotion

    @Binding var isPinned: Bool

    @State private var isHovered = false

    var body: some View {
        Button(action: { isPinned.toggle() }) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(AppTypography.bodySecondary.weight(.medium))
                .foregroundColor(.white.opacity(isHovered ? 0.7 : 0.4))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0)),
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(isHovered ? 0.15 : 0),
                            lineWidth: 0.5,
                        ),
                )
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin from top (⌘⇧P)" : "Pin to top (⌘⇧P)")
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
