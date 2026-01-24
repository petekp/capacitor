// VibrancyView.swift
//
// Bridges AppKit's NSVisualEffectView into SwiftUI for frosted glass effects.
// Used as a background layer under SwiftUI content via the .vibrancy() modifier.
//
// The key components:
// - VibrancyView: Raw NSViewRepresentable wrapper
// - .vibrancy() modifier: Applies VibrancyView as background
// - DarkFrostedGlass: Panel background with configurable material + overlays
// - DarkFrostedCard: Card background, lighter weight than panel version
//
// forceDarkAppearance ensures consistent look regardless of system theme.

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
}

struct DarkFrostedGlass: View {
    @ObservedObject private var config = GlassConfig.shared

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

    var body: some View {
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

        ZStack {
            VibrancyView(
                material: material,
                blendingMode: .behindWindow,
                isEmphasized: isEmphasized,
                forceDarkAppearance: true
            )
            .id("vibrancy-\(config.materialType)-\(isEmphasized)-\(config.refreshCounter)")

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

extension GlassConfig {
    var panelConfigHash: String {
        "panel-\(refreshCounter)-\(materialType)-\(panelTintOpacity)-\(panelCornerRadius)-\(panelBorderOpacity)-\(useEmphasizedMaterial)"
    }

    var solidCardConfigHash: String {
        "solid-\(cardTintOpacity)-\(cardCornerRadius)-\(cardBorderOpacity)-\(cardHighlightOpacity)-\(cardHoverBorderOpacity)-\(cardHoverHighlightOpacity)"
    }
}

struct DarkFrostedCard: View {
    var isHovered: Bool = false
    var tintOpacity: Double? = nil
    var config: GlassConfig? = nil
    private var effectiveConfig: GlassConfig { config ?? GlassConfig.shared }

    var body: some View {
        let cornerRadius = effectiveConfig.cardCornerRadius
        let baseTintOpacity = tintOpacity ?? effectiveConfig.cardTintOpacity
        let borderOpacity = isHovered ? effectiveConfig.cardHoverBorderOpacity : effectiveConfig.cardBorderOpacity
        let highlightOpacity = isHovered ? effectiveConfig.cardHoverHighlightOpacity : effectiveConfig.cardHighlightOpacity

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
