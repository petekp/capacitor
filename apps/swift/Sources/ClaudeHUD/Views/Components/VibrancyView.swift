import SwiftUI
import AppKit

struct VibrancyView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let isEmphasized: Bool
    let forceDarkAppearance: Bool

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        isEmphasized: Bool = false,
        forceDarkAppearance: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.isEmphasized = isEmphasized
        self.forceDarkAppearance = forceDarkAppearance
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = isEmphasized
        if forceDarkAppearance {
            view.appearance = NSAppearance(named: .darkAqua)
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
        if forceDarkAppearance {
            nsView.appearance = NSAppearance(named: .darkAqua)
        } else {
            nsView.appearance = nil
        }
        nsView.needsDisplay = true
        nsView.displayIfNeeded()
    }
}

class VibrantHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool { true }
}

struct VibrantContentView<Content: View>: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let content: Content

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        @ViewBuilder content: () -> Content
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.content = content()
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = material
        effectView.blendingMode = blendingMode
        effectView.state = .active

        let hostingView = VibrantHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])

        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode

        if let hostingView = nsView.subviews.first as? VibrantHostingView<Content> {
            hostingView.rootView = content
        }
    }
}

extension View {
    func vibrancy(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        isEmphasized: Bool = false,
        forceDarkAppearance: Bool = false
    ) -> some View {
        self.background(
            VibrancyView(
                material: material,
                blendingMode: blendingMode,
                isEmphasized: isEmphasized,
                forceDarkAppearance: forceDarkAppearance
            )
        )
    }

    func vibrantContent(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> some View {
        VibrantContentView(material: material, blendingMode: blendingMode) {
            self
        }
    }
}

struct DarkFrostedGlass: View {
    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    #if DEBUG
    private var selectedMaterial: NSVisualEffectView.Material {
        switch config.materialType {
        case 0: return .hudWindow
        case 1: return .popover
        case 2: return .menu
        case 3: return .sidebar
        case 4: return .fullScreenUI
        default: return .hudWindow
        }
    }
    #endif

    var body: some View {
        #if DEBUG
        let cornerRadius = config.panelCornerRadius
        let tintOpacity = config.panelTintOpacity
        let borderOpacity = config.panelBorderOpacity
        let highlightOpacity = config.panelHighlightOpacity
        let topHighlightOpacity = config.panelTopHighlightOpacity
        let shadowOpacity = config.panelShadowOpacity
        let shadowRadius = config.panelShadowRadius
        let shadowY = config.panelShadowY
        let isEmphasized = config.useEmphasizedMaterial
        let material = selectedMaterial
        #else
        let cornerRadius: CGFloat = 22
        let tintOpacity: Double = 0.33
        let borderOpacity: Double = 0.36
        let highlightOpacity: Double = 0.07
        let topHighlightOpacity: Double = 0.14
        let shadowOpacity: Double = 0.00
        let shadowRadius: CGFloat = 0
        let shadowY: CGFloat = 0
        let isEmphasized = true
        let material: NSVisualEffectView.Material = .hudWindow
        #endif

        ZStack {
            VibrancyView(
                material: material,
                blendingMode: .behindWindow,
                isEmphasized: isEmphasized,
                forceDarkAppearance: true
            )
            #if DEBUG
            .id("vibrancy-\(config.materialType)-\(isEmphasized)-\(config.refreshCounter)")
            #endif

            Color.black.opacity(tintOpacity)

            LinearGradient(
                colors: [
                    .white.opacity(highlightOpacity),
                    .white.opacity(highlightOpacity * 0.25),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(topHighlightOpacity), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(borderOpacity),
                            .white.opacity(borderOpacity * 0.4),
                            .white.opacity(borderOpacity * 0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(shadowOpacity * 0.8), radius: 1, y: 1)
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
    }
}

#if DEBUG
extension GlassConfig {
    var panelConfigHash: String {
        "panel-\(refreshCounter)-\(materialType)-\(panelTintOpacity)-\(panelCornerRadius)-\(panelBorderOpacity)-\(useEmphasizedMaterial)"
    }

    var solidCardConfigHash: String {
        "solid-\(cardTintOpacity)-\(cardCornerRadius)-\(cardBorderOpacity)-\(cardHighlightOpacity)-\(cardHoverBorderOpacity)-\(cardHoverHighlightOpacity)"
    }
}
#endif

struct DarkFrostedCard: View {
    var isHovered: Bool = false
    var tintOpacity: Double? = nil

    #if DEBUG
    var config: GlassConfig? = nil
    private var effectiveConfig: GlassConfig { config ?? GlassConfig.shared }
    #endif

    var body: some View {
        #if DEBUG
        let cornerRadius = effectiveConfig.cardCornerRadius
        let baseTintOpacity = tintOpacity ?? effectiveConfig.cardTintOpacity
        let borderOpacity = isHovered ? effectiveConfig.cardHoverBorderOpacity : effectiveConfig.cardBorderOpacity
        let highlightOpacity = isHovered ? effectiveConfig.cardHoverHighlightOpacity : effectiveConfig.cardHighlightOpacity
        #else
        let cornerRadius: CGFloat = 13
        let baseTintOpacity = tintOpacity ?? 0.58
        let borderOpacity = isHovered ? 0.37 : 0.28
        let highlightOpacity = isHovered ? 0.16 : 0.14
        #endif

        let effectiveTintOpacity = isHovered ? baseTintOpacity * 0.8 : baseTintOpacity

        ZStack {
            VibrancyView(
                material: .hudWindow,
                blendingMode: .behindWindow,
                isEmphasized: false,
                forceDarkAppearance: true
            )

            Color.black.opacity(effectiveTintOpacity)

            LinearGradient(
                colors: [
                    .white.opacity(highlightOpacity),
                    .white.opacity(highlightOpacity * 0.33)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(borderOpacity),
                            .white.opacity(borderOpacity * 0.4)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }
}
