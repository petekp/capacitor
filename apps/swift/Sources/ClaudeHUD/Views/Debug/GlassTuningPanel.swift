import SwiftUI
import Combine

#if DEBUG

private struct GlassConfigKey: EnvironmentKey {
    static let defaultValue = GlassConfig.shared
}

extension EnvironmentValues {
    var glassConfig: GlassConfig {
        get { self[GlassConfigKey.self] }
        set { self[GlassConfigKey.self] = newValue }
    }
}

struct TunableColor {
    var hue: Double
    var saturation: Double
    var brightness: Double

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    static let ready = TunableColor(hue: 145/360, saturation: 0.75, brightness: 0.70)
    static let working = TunableColor(hue: 45/360, saturation: 0.65, brightness: 0.75)
    static let waiting = TunableColor(hue: 85/360, saturation: 0.70, brightness: 0.80)
    static let compacting = TunableColor(hue: 55/360, saturation: 0.55, brightness: 0.70)
    static let idle = TunableColor(hue: 0, saturation: 0, brightness: 0.5)
}

enum PreviewState: String, CaseIterable {
    case none = "None"
    case ready = "Ready"
    case working = "Working"
    case waiting = "Waiting"
    case compacting = "Compacting"
    case idle = "Idle"
}

class GlassConfig: ObservableObject {
    static let shared = GlassConfig()
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var refreshCounter: Int = 0

    init() {
        $useEmphasizedMaterial
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshCounter += 1
            }
            .store(in: &cancellables)

        $materialType
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshCounter += 1
            }
            .store(in: &cancellables)
    }

    static let materialNames = ["HUD Window", "Popover", "Menu", "Sidebar", "Full Screen UI"]

    var cardConfigHash: Int {
        var hasher = Hasher()
        hasher.combine(cardTintOpacity)
        hasher.combine(cardCornerRadius)
        hasher.combine(cardBorderOpacity)
        hasher.combine(cardHighlightOpacity)
        hasher.combine(cardHoverBorderOpacity)
        hasher.combine(cardHoverHighlightOpacity)
        hasher.combine(statusReadyHue)
        hasher.combine(statusWorkingHue)
        return hasher.finalize()
    }

    // Panel background
    @Published var panelTintOpacity: Double = 0.33
    @Published var panelCornerRadius: Double = 22
    @Published var panelBorderOpacity: Double = 0.36
    @Published var panelHighlightOpacity: Double = 0.07
    @Published var panelTopHighlightOpacity: Double = 0.14
    @Published var panelShadowOpacity: Double = 0.00
    @Published var panelShadowRadius: Double = 0
    @Published var panelShadowY: Double = 0

    // Card background
    @Published var cardTintOpacity: Double = 0.58
    @Published var cardCornerRadius: Double = 13
    @Published var cardBorderOpacity: Double = 0.28
    @Published var cardHighlightOpacity: Double = 0.14
    @Published var cardHoverBorderOpacity: Double = 0.37
    @Published var cardHoverHighlightOpacity: Double = 0.16

    // Material settings
    @Published var useEmphasizedMaterial: Bool = true
    @Published var materialType: Int = 0  // 0=hudWindow, 1=popover, 2=menu, 3=sidebar, 4=fullScreenUI

    // Status Colors - Ready (cyan-green)
    @Published var statusReadyHue: Double = 0.406
    @Published var statusReadySaturation: Double = 0.83
    @Published var statusReadyBrightness: Double = 1.00

    // Status Colors - Working (yellow/orange)
    @Published var statusWorkingHue: Double = 0.103
    @Published var statusWorkingSaturation: Double = 1.00
    @Published var statusWorkingBrightness: Double = 1.00

    // Status Colors - Waiting (coral/salmon)
    @Published var statusWaitingHue: Double = 0.026
    @Published var statusWaitingSaturation: Double = 0.58
    @Published var statusWaitingBrightness: Double = 1.00

    // Status Colors - Compacting (purple/lavender)
    @Published var statusCompactingHue: Double = 0.670
    @Published var statusCompactingSaturation: Double = 0.50
    @Published var statusCompactingBrightness: Double = 1.00

    // Status Colors - Idle (gray)
    @Published var statusIdleOpacity: Double = 0.40

    // Ready ripple effect (continuous)
    @Published var rippleSpeed: Double = 4.9
    @Published var rippleCount: Int = 4
    @Published var rippleMaxOpacity: Double = 1.00
    @Published var rippleLineWidth: Double = 30.0
    @Published var rippleBlurAmount: Double = 41.5
    @Published var rippleOriginX: Double = 0.89
    @Published var rippleOriginY: Double = 0.00
    @Published var rippleFadeInZone: Double = 0.10
    @Published var rippleFadeOutPower: Double = 4.0

    // Ready border glow effect
    @Published var borderGlowInnerWidth: Double = 0.49
    @Published var borderGlowOuterWidth: Double = 2.88
    @Published var borderGlowInnerBlur: Double = 0.5
    @Published var borderGlowOuterBlur: Double = 1.5
    @Published var borderGlowBaseOpacity: Double = 0.30
    @Published var borderGlowPulseIntensity: Double = 0.50
    @Published var borderGlowRotationMultiplier: Double = 0.50


    // MARK: - Waiting Pulse Effect
    @Published var waitingCycleLength: Double = 1.68
    @Published var waitingFirstPulseDuration: Double = 0.17
    @Published var waitingFirstPulseFadeOut: Double = 0.17
    @Published var waitingSecondPulseDelay: Double = 0.00
    @Published var waitingSecondPulseDuration: Double = 0.17
    @Published var waitingSecondPulseFadeOut: Double = 0.48
    @Published var waitingFirstPulseIntensity: Double = 0.34
    @Published var waitingSecondPulseIntensity: Double = 0.47
    @Published var waitingMaxOpacity: Double = 0.34
    @Published var waitingBlurAmount: Double = 0.0
    @Published var waitingPulseScale: Double = 2.22
    @Published var waitingScaleAmount: Double = 0.30
    @Published var waitingSpringDamping: Double = 1.69
    @Published var waitingSpringOmega: Double = 3.3
    @Published var waitingOriginX: Double = 1.00
    @Published var waitingOriginY: Double = 0.00

    // Waiting border glow
    @Published var waitingBorderBaseOpacity: Double = 0.12
    @Published var waitingBorderPulseOpacity: Double = 0.37
    @Published var waitingBorderInnerWidth: Double = 0.50
    @Published var waitingBorderOuterWidth: Double = 1.86
    @Published var waitingBorderOuterBlur: Double = 0.8

    // MARK: - Caustic Underglow Effect
    @Published var causticEnabled: Bool = false
    @Published var causticSpeed: Double = 0.3
    @Published var causticBlur: Double = 20.0
    @Published var causticOpacity: Double = 0.4
    @Published var causticBlendMode: BlendMode = .plusLighter
    @Published var causticCellSize: Double = 8.0
    @Published var causticThreshold: Double = 0.5
    @Published var causticPointScale: Double = 1.5
    @Published var causticScale1: Double = 40.0
    @Published var causticScale2: Double = 60.0
    @Published var causticScale3: Double = 80.0
    @Published var causticOriginX: Double = 0.5
    @Published var causticOriginY: Double = 0.5
    @Published var causticRadialFalloff: Double = 0.8
    @Published var causticConcentration: Double = 2.0
    @Published var causticColor: Color = .white
    @Published var causticRingCount: Int = 8
    @Published var causticWaveAmplitude: Double = 10.0
    @Published var causticRingOpacity: Double = 0.3
    @Published var causticRingWidth: Double = 2.0
    @Published var causticBrightCount: Int = 12
    @Published var causticBrightSize: Double = 30.0
    @Published var causticUseRings: Bool = true
    @Published var causticColorHue: Double = 0.0

    // MARK: - Card Interaction (Per-Pointer-Event)
    // Idle state (default)
    @Published var cardIdleScale: Double = 1.0
    @Published var cardIdleShadowOpacity: Double = 0.08
    @Published var cardIdleShadowRadius: Double = 4.0
    @Published var cardIdleShadowY: Double = 2.0

    // Hover state
    @Published var cardHoverScale: Double = 0.99
    @Published var cardHoverSpringResponse: Double = 0.2
    @Published var cardHoverSpringDamping: Double = 0.8
    @Published var cardHoverShadowOpacity: Double = 0.2
    @Published var cardHoverShadowRadius: Double = 12.0
    @Published var cardHoverShadowY: Double = 4.0

    // Pressed state
    @Published var cardPressedScale: Double = 0.97
    @Published var cardPressedSpringResponse: Double = 0.12
    @Published var cardPressedSpringDamping: Double = 0.6
    @Published var cardPressedShadowOpacity: Double = 0.12
    @Published var cardPressedShadowRadius: Double = 2.0
    @Published var cardPressedShadowY: Double = 1.0

    // MARK: - Compacting Text Animation
    @Published var compactingCycleLength: Double = 1.8
    @Published var compactingMinTracking: Double = 0.0
    @Published var compactingMaxTracking: Double = 2.1
    @Published var compactingCompressDuration: Double = 0.26
    @Published var compactingHoldDuration: Double = 0.50
    @Published var compactingExpandDuration: Double = 1.0
    // Spring parameters for compress phase
    @Published var compactingCompressDamping: Double = 0.3
    @Published var compactingCompressOmega: Double = 16.0
    // Spring parameters for expand phase
    @Published var compactingExpandDamping: Double = 0.8
    @Published var compactingExpandOmega: Double = 4.0

    // State Preview
    @Published var previewState: PreviewState = .none

    // Computed colors
    var statusReadyColor: Color {
        Color(hue: statusReadyHue, saturation: statusReadySaturation, brightness: statusReadyBrightness)
    }
    var statusWorkingColor: Color {
        Color(hue: statusWorkingHue, saturation: statusWorkingSaturation, brightness: statusWorkingBrightness)
    }
    var statusWaitingColor: Color {
        Color(hue: statusWaitingHue, saturation: statusWaitingSaturation, brightness: statusWaitingBrightness)
    }
    var statusCompactingColor: Color {
        Color(hue: statusCompactingHue, saturation: statusCompactingSaturation, brightness: statusCompactingBrightness)
    }
    var statusIdleColor: Color {
        Color.white.opacity(statusIdleOpacity)
    }

    func colorForState(_ state: PreviewState) -> Color {
        switch state {
        case .none: return .clear
        case .ready: return statusReadyColor
        case .working: return statusWorkingColor
        case .waiting: return statusWaitingColor
        case .compacting: return statusCompactingColor
        case .idle: return statusIdleColor
        }
    }

    // MARK: - Layout-Aware Accessors (unified - layout param kept for API compatibility)
    func rippleSpeed(for layout: LayoutMode) -> Double { rippleSpeed }
    func rippleCount(for layout: LayoutMode) -> Int { rippleCount }
    func rippleMaxOpacity(for layout: LayoutMode) -> Double { rippleMaxOpacity }
    func rippleLineWidth(for layout: LayoutMode) -> Double { rippleLineWidth }
    func rippleBlurAmount(for layout: LayoutMode) -> Double { rippleBlurAmount }
    func rippleOriginX(for layout: LayoutMode) -> Double { rippleOriginX }
    func rippleOriginY(for layout: LayoutMode) -> Double { rippleOriginY }
    func rippleFadeInZone(for layout: LayoutMode) -> Double { rippleFadeInZone }
    func rippleFadeOutPower(for layout: LayoutMode) -> Double { rippleFadeOutPower }

    func borderGlowInnerWidth(for layout: LayoutMode) -> Double { borderGlowInnerWidth }
    func borderGlowOuterWidth(for layout: LayoutMode) -> Double { borderGlowOuterWidth }
    func borderGlowInnerBlur(for layout: LayoutMode) -> Double { borderGlowInnerBlur }
    func borderGlowOuterBlur(for layout: LayoutMode) -> Double { borderGlowOuterBlur }
    func borderGlowBaseOpacity(for layout: LayoutMode) -> Double { borderGlowBaseOpacity }
    func borderGlowPulseIntensity(for layout: LayoutMode) -> Double { borderGlowPulseIntensity }
    func borderGlowRotationMultiplier(for layout: LayoutMode) -> Double { borderGlowRotationMultiplier }

    // MARK: - Waiting Effect Accessors (unified)
    func waitingCycleLength(for layout: LayoutMode) -> Double { waitingCycleLength }
    func waitingFirstPulseDuration(for layout: LayoutMode) -> Double { waitingFirstPulseDuration }
    func waitingFirstPulseFadeOut(for layout: LayoutMode) -> Double { waitingFirstPulseFadeOut }
    func waitingSecondPulseDelay(for layout: LayoutMode) -> Double { waitingSecondPulseDelay }
    func waitingSecondPulseDuration(for layout: LayoutMode) -> Double { waitingSecondPulseDuration }
    func waitingSecondPulseFadeOut(for layout: LayoutMode) -> Double { waitingSecondPulseFadeOut }
    func waitingFirstPulseIntensity(for layout: LayoutMode) -> Double { waitingFirstPulseIntensity }
    func waitingSecondPulseIntensity(for layout: LayoutMode) -> Double { waitingSecondPulseIntensity }
    func waitingMaxOpacity(for layout: LayoutMode) -> Double { waitingMaxOpacity }
    func waitingBlurAmount(for layout: LayoutMode) -> Double { waitingBlurAmount }
    func waitingPulseScale(for layout: LayoutMode) -> Double { waitingPulseScale }
    func waitingScaleAmount(for layout: LayoutMode) -> Double { waitingScaleAmount }
    func waitingSpringDamping(for layout: LayoutMode) -> Double { waitingSpringDamping }
    func waitingSpringOmega(for layout: LayoutMode) -> Double { waitingSpringOmega }
    func waitingBorderBaseOpacity(for layout: LayoutMode) -> Double { waitingBorderBaseOpacity }
    func waitingBorderPulseOpacity(for layout: LayoutMode) -> Double { waitingBorderPulseOpacity }
    func waitingBorderInnerWidth(for layout: LayoutMode) -> Double { waitingBorderInnerWidth }
    func waitingBorderOuterWidth(for layout: LayoutMode) -> Double { waitingBorderOuterWidth }
    func waitingBorderOuterBlur(for layout: LayoutMode) -> Double { waitingBorderOuterBlur }
    func waitingOriginX(for layout: LayoutMode) -> Double { waitingOriginX }
    func waitingOriginY(for layout: LayoutMode) -> Double { waitingOriginY }

    // MARK: - Card Interaction Accessors (unified)
    func cardIdleScale(for layout: LayoutMode) -> Double { cardIdleScale }
    func cardHoverScale(for layout: LayoutMode) -> Double { cardHoverScale }
    func cardHoverSpringResponse(for layout: LayoutMode) -> Double { cardHoverSpringResponse }
    func cardHoverSpringDamping(for layout: LayoutMode) -> Double { cardHoverSpringDamping }
    func cardPressedScale(for layout: LayoutMode) -> Double { cardPressedScale }
    func cardPressedSpringResponse(for layout: LayoutMode) -> Double { cardPressedSpringResponse }
    func cardPressedSpringDamping(for layout: LayoutMode) -> Double { cardPressedSpringDamping }

    func reset() {
        panelTintOpacity = 0.33
        panelCornerRadius = 22
        panelBorderOpacity = 0.36
        panelHighlightOpacity = 0.07
        panelTopHighlightOpacity = 0.14
        panelShadowOpacity = 0.00
        panelShadowRadius = 0
        panelShadowY = 0

        cardTintOpacity = 0.58
        cardCornerRadius = 13
        cardBorderOpacity = 0.28
        cardHighlightOpacity = 0.14
        cardHoverBorderOpacity = 0.37
        cardHoverHighlightOpacity = 0.16

        useEmphasizedMaterial = true
        materialType = 0

        statusReadyHue = 0.406
        statusReadySaturation = 0.83
        statusReadyBrightness = 1.00

        statusWorkingHue = 0.103
        statusWorkingSaturation = 1.00
        statusWorkingBrightness = 1.00

        statusWaitingHue = 0.026
        statusWaitingSaturation = 0.58
        statusWaitingBrightness = 1.00

        statusCompactingHue = 0.670
        statusCompactingSaturation = 0.50
        statusCompactingBrightness = 1.00

        statusIdleOpacity = 0.40

        rippleSpeed = 4.9
        rippleCount = 4
        rippleMaxOpacity = 1.00
        rippleLineWidth = 30.0
        rippleBlurAmount = 41.5
        rippleOriginX = 0.89
        rippleOriginY = 0.00
        rippleFadeInZone = 0.10
        rippleFadeOutPower = 4.0

        borderGlowInnerWidth = 0.49
        borderGlowOuterWidth = 2.88
        borderGlowInnerBlur = 0.5
        borderGlowOuterBlur = 1.5
        borderGlowBaseOpacity = 0.30
        borderGlowPulseIntensity = 0.50
        borderGlowRotationMultiplier = 0.50

        // Waiting effect
        waitingCycleLength = 1.68
        waitingFirstPulseDuration = 0.17
        waitingFirstPulseFadeOut = 0.17
        waitingSecondPulseDelay = 0.00
        waitingSecondPulseDuration = 0.17
        waitingSecondPulseFadeOut = 0.48
        waitingFirstPulseIntensity = 0.34
        waitingSecondPulseIntensity = 0.47
        waitingMaxOpacity = 0.34
        waitingBlurAmount = 0.0
        waitingPulseScale = 2.22
        waitingScaleAmount = 0.30
        waitingSpringDamping = 1.69
        waitingSpringOmega = 3.3
        waitingOriginX = 1.00
        waitingOriginY = 0.00
        waitingBorderBaseOpacity = 0.12
        waitingBorderPulseOpacity = 0.37
        waitingBorderInnerWidth = 0.50
        waitingBorderOuterWidth = 1.86
        waitingBorderOuterBlur = 0.8

        // Card interaction
        cardIdleScale = 1.0
        cardIdleShadowOpacity = 0.08
        cardIdleShadowRadius = 4.0
        cardIdleShadowY = 2.0
        cardHoverScale = 0.99
        cardHoverSpringResponse = 0.2
        cardHoverSpringDamping = 0.8
        cardHoverShadowOpacity = 0.2
        cardHoverShadowRadius = 12.0
        cardHoverShadowY = 4.0
        cardPressedScale = 0.97
        cardPressedSpringResponse = 0.12
        cardPressedSpringDamping = 0.6
        cardPressedShadowOpacity = 0.12
        cardPressedShadowRadius = 2.0
        cardPressedShadowY = 1.0

        // Compacting text animation
        compactingCycleLength = 1.8
        compactingMinTracking = 0.0
        compactingMaxTracking = 2.1
        compactingCompressDuration = 0.26
        compactingHoldDuration = 0.50
        compactingExpandDuration = 1.0
        compactingCompressDamping = 0.3
        compactingCompressOmega = 16.0
        compactingExpandDamping = 0.8
        compactingExpandOmega = 4.0

        previewState = .none
    }

    func exportForLLM() -> String {
        let allParams: [(String, String, Double, Double)] = [
            // Panel Background
            ("Panel", "panelTintOpacity", 0.33, panelTintOpacity),
            ("Panel", "panelCornerRadius", 22, panelCornerRadius),
            ("Panel", "panelBorderOpacity", 0.36, panelBorderOpacity),
            ("Panel", "panelHighlightOpacity", 0.07, panelHighlightOpacity),
            ("Panel", "panelTopHighlightOpacity", 0.14, panelTopHighlightOpacity),
            ("Panel", "panelShadowOpacity", 0.00, panelShadowOpacity),
            ("Panel", "panelShadowRadius", 0, panelShadowRadius),
            ("Panel", "panelShadowY", 0, panelShadowY),
            // Card Background
            ("Card", "cardTintOpacity", 0.58, cardTintOpacity),
            ("Card", "cardCornerRadius", 13, cardCornerRadius),
            ("Card", "cardBorderOpacity", 0.28, cardBorderOpacity),
            ("Card", "cardHighlightOpacity", 0.14, cardHighlightOpacity),
            ("Card", "cardHoverBorderOpacity", 0.37, cardHoverBorderOpacity),
            ("Card", "cardHoverHighlightOpacity", 0.16, cardHoverHighlightOpacity),
            // Status Colors - Ready
            ("Status Ready", "statusReadyHue", 0.406, statusReadyHue),
            ("Status Ready", "statusReadySaturation", 0.83, statusReadySaturation),
            ("Status Ready", "statusReadyBrightness", 1.00, statusReadyBrightness),
            // Status Colors - Working
            ("Status Working", "statusWorkingHue", 0.103, statusWorkingHue),
            ("Status Working", "statusWorkingSaturation", 1.00, statusWorkingSaturation),
            ("Status Working", "statusWorkingBrightness", 1.00, statusWorkingBrightness),
            // Status Colors - Waiting
            ("Status Waiting", "statusWaitingHue", 0.026, statusWaitingHue),
            ("Status Waiting", "statusWaitingSaturation", 0.58, statusWaitingSaturation),
            ("Status Waiting", "statusWaitingBrightness", 1.00, statusWaitingBrightness),
            // Status Colors - Compacting
            ("Status Compacting", "statusCompactingHue", 0.670, statusCompactingHue),
            ("Status Compacting", "statusCompactingSaturation", 0.50, statusCompactingSaturation),
            ("Status Compacting", "statusCompactingBrightness", 1.00, statusCompactingBrightness),
            // Status Colors - Idle
            ("Status Idle", "statusIdleOpacity", 0.40, statusIdleOpacity),
            // Ready Ripple
            ("Ready Ripple", "rippleSpeed", 4.9, rippleSpeed),
            ("Ready Ripple", "rippleCount", 4, Double(rippleCount)),
            ("Ready Ripple", "rippleMaxOpacity", 1.00, rippleMaxOpacity),
            ("Ready Ripple", "rippleLineWidth", 30.0, rippleLineWidth),
            ("Ready Ripple", "rippleBlurAmount", 41.5, rippleBlurAmount),
            ("Ready Ripple", "rippleOriginX", 0.89, rippleOriginX),
            ("Ready Ripple", "rippleOriginY", 0.00, rippleOriginY),
            ("Ready Ripple", "rippleFadeInZone", 0.10, rippleFadeInZone),
            ("Ready Ripple", "rippleFadeOutPower", 4.0, rippleFadeOutPower),
            // Border Glow
            ("Border Glow", "borderGlowInnerWidth", 0.49, borderGlowInnerWidth),
            ("Border Glow", "borderGlowOuterWidth", 2.88, borderGlowOuterWidth),
            ("Border Glow", "borderGlowInnerBlur", 0.5, borderGlowInnerBlur),
            ("Border Glow", "borderGlowOuterBlur", 1.5, borderGlowOuterBlur),
            ("Border Glow", "borderGlowBaseOpacity", 0.30, borderGlowBaseOpacity),
            ("Border Glow", "borderGlowPulseIntensity", 0.50, borderGlowPulseIntensity),
            ("Border Glow", "borderGlowRotationMultiplier", 0.50, borderGlowRotationMultiplier),
            // Waiting Pulse
            ("Waiting Pulse", "waitingCycleLength", 1.68, waitingCycleLength),
            ("Waiting Pulse", "waitingFirstPulseDuration", 0.17, waitingFirstPulseDuration),
            ("Waiting Pulse", "waitingFirstPulseFadeOut", 0.17, waitingFirstPulseFadeOut),
            ("Waiting Pulse", "waitingSecondPulseDelay", 0.00, waitingSecondPulseDelay),
            ("Waiting Pulse", "waitingSecondPulseDuration", 0.17, waitingSecondPulseDuration),
            ("Waiting Pulse", "waitingSecondPulseFadeOut", 0.48, waitingSecondPulseFadeOut),
            ("Waiting Pulse", "waitingFirstPulseIntensity", 0.34, waitingFirstPulseIntensity),
            ("Waiting Pulse", "waitingSecondPulseIntensity", 0.47, waitingSecondPulseIntensity),
            ("Waiting Pulse", "waitingMaxOpacity", 0.34, waitingMaxOpacity),
            ("Waiting Pulse", "waitingBlurAmount", 0.0, waitingBlurAmount),
            ("Waiting Pulse", "waitingPulseScale", 2.22, waitingPulseScale),
            ("Waiting Pulse", "waitingScaleAmount", 0.30, waitingScaleAmount),
            ("Waiting Pulse", "waitingSpringDamping", 1.69, waitingSpringDamping),
            ("Waiting Pulse", "waitingSpringOmega", 3.3, waitingSpringOmega),
            ("Waiting Pulse", "waitingOriginX", 1.00, waitingOriginX),
            ("Waiting Pulse", "waitingOriginY", 0.00, waitingOriginY),
            // Waiting Border
            ("Waiting Border", "waitingBorderBaseOpacity", 0.12, waitingBorderBaseOpacity),
            ("Waiting Border", "waitingBorderPulseOpacity", 0.37, waitingBorderPulseOpacity),
            ("Waiting Border", "waitingBorderInnerWidth", 0.50, waitingBorderInnerWidth),
            ("Waiting Border", "waitingBorderOuterWidth", 1.86, waitingBorderOuterWidth),
            ("Waiting Border", "waitingBorderOuterBlur", 0.8, waitingBorderOuterBlur),
            // Compacting Text
            ("Compacting Text", "compactingCycleLength", 1.8, compactingCycleLength),
            ("Compacting Text", "compactingMinTracking", 0.0, compactingMinTracking),
            ("Compacting Text", "compactingMaxTracking", 2.1, compactingMaxTracking),
            ("Compacting Text", "compactingCompressDuration", 0.26, compactingCompressDuration),
            ("Compacting Text", "compactingHoldDuration", 0.50, compactingHoldDuration),
            ("Compacting Text", "compactingExpandDuration", 1.0, compactingExpandDuration),
            ("Compacting Text", "compactingCompressDamping", 0.3, compactingCompressDamping),
            ("Compacting Text", "compactingCompressOmega", 16.0, compactingCompressOmega),
            ("Compacting Text", "compactingExpandDamping", 0.8, compactingExpandDamping),
            ("Compacting Text", "compactingExpandOmega", 4.0, compactingExpandOmega),
            // Card Interaction
            ("Card Idle", "cardIdleScale", 1.0, cardIdleScale),
            ("Card Idle", "cardIdleShadowOpacity", 0.08, cardIdleShadowOpacity),
            ("Card Idle", "cardIdleShadowRadius", 4.0, cardIdleShadowRadius),
            ("Card Idle", "cardIdleShadowY", 2.0, cardIdleShadowY),
            ("Card Hover", "cardHoverScale", 0.99, cardHoverScale),
            ("Card Hover", "cardHoverSpringResponse", 0.2, cardHoverSpringResponse),
            ("Card Hover", "cardHoverSpringDamping", 0.8, cardHoverSpringDamping),
            ("Card Hover", "cardHoverShadowOpacity", 0.2, cardHoverShadowOpacity),
            ("Card Hover", "cardHoverShadowRadius", 12.0, cardHoverShadowRadius),
            ("Card Hover", "cardHoverShadowY", 4.0, cardHoverShadowY),
            ("Card Pressed", "cardPressedScale", 0.97, cardPressedScale),
            ("Card Pressed", "cardPressedSpringResponse", 0.12, cardPressedSpringResponse),
            ("Card Pressed", "cardPressedSpringDamping", 0.6, cardPressedSpringDamping),
            ("Card Pressed", "cardPressedShadowOpacity", 0.12, cardPressedShadowOpacity),
            ("Card Pressed", "cardPressedShadowRadius", 2.0, cardPressedShadowRadius),
            ("Card Pressed", "cardPressedShadowY", 1.0, cardPressedShadowY),
        ]

        let changed = allParams.filter { abs($0.2 - $0.3) > 0.001 }

        if changed.isEmpty {
            return "## Visual Parameters\n\nNo changes from defaults."
        }

        var groupedChanges: [String: [(String, Double, Double)]] = [:]
        for (category, name, defaultVal, currentVal) in changed {
            if groupedChanges[category] == nil {
                groupedChanges[category] = []
            }
            groupedChanges[category]?.append((name, defaultVal, currentVal))
        }

        var output = "## Visual Parameters\n\n### Changed Values\n```swift\n"
        let sortedCategories = groupedChanges.keys.sorted()
        for category in sortedCategories {
            output += "// \(category)\n"
            for (name, defaultVal, currentVal) in groupedChanges[category]! {
                output += "\(name): \(String(format: "%.2f", defaultVal)) → \(String(format: "%.2f", currentVal))\n"
            }
        }
        output += "```"

        return output
    }
}

struct GlassTuningPanel: View {
    @ObservedObject var config = GlassConfig.shared
    @Binding var isPresented: Bool
    @State private var copiedToClipboard = false
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            ScrollView {
                VStack(spacing: 10) {
                    switch selectedTab {
                    case 0: glassContent
                    case 1: statusColorsContent
                    case 2: effectsContent
                    case 3: previewContent
                    default: glassContent
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)
            actionsSection
                .padding(10)
        }
        .frame(width: 300, height: 580)
        .background(Color.hudBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.hudBorder, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(AppTypography.labelMedium)
                .foregroundColor(.hudAccent)

            Text("Visual Tuning")
                .font(AppTypography.cardTitle)
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            Text("DEBUG")
                .font(AppTypography.badge)
                .foregroundColor(.hudAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.hudAccent.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.hudCard.opacity(0.6))
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            TuningTab(title: "Glass", icon: "square.on.square", isSelected: selectedTab == 0) {
                selectedTab = 0
            }
            TuningTab(title: "Colors", icon: "paintpalette", isSelected: selectedTab == 1) {
                selectedTab = 1
            }
            TuningTab(title: "Effects", icon: "sparkles", isSelected: selectedTab == 2) {
                selectedTab = 2
            }
            TuningTab(title: "Preview", icon: "play.circle", isSelected: selectedTab == 3) {
                selectedTab = 3
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.25))
    }

    private var glassContent: some View {
        VStack(spacing: 12) {
            TuningSection(title: "Panel Background") {
                TuningSlider(label: "Tint Opacity", value: $config.panelTintOpacity, range: 0...1)
                TuningSlider(label: "Corner Radius", value: $config.panelCornerRadius, range: 0...30)
                TuningSlider(label: "Border Opacity", value: $config.panelBorderOpacity, range: 0...1)
                TuningSlider(label: "Highlight", value: $config.panelHighlightOpacity, range: 0...0.3)
                TuningSlider(label: "Top Highlight", value: $config.panelTopHighlightOpacity, range: 0...0.5)
                TuningSlider(label: "Shadow Opacity", value: $config.panelShadowOpacity, range: 0...1)
                TuningSlider(label: "Shadow Radius", value: $config.panelShadowRadius, range: 0...50)
                TuningSlider(label: "Shadow Y", value: $config.panelShadowY, range: 0...30)
            }

            TuningSection(title: "Card Background") {
                TuningSlider(label: "Tint Opacity", value: $config.cardTintOpacity, range: 0...1)
                TuningSlider(label: "Corner Radius", value: $config.cardCornerRadius, range: 0...24)
                TuningSlider(label: "Border Opacity", value: $config.cardBorderOpacity, range: 0...1)
                TuningSlider(label: "Highlight", value: $config.cardHighlightOpacity, range: 0...0.3)
                TuningSlider(label: "Hover Border", value: $config.cardHoverBorderOpacity, range: 0...1)
                TuningSlider(label: "Hover Highlight", value: $config.cardHoverHighlightOpacity, range: 0...0.5)
            }

            TuningSection(title: "Material", isExpanded: false) {
                Picker("Material", selection: $config.materialType) {
                    ForEach(0..<GlassConfig.materialNames.count, id: \.self) { index in
                        Text(GlassConfig.materialNames[index]).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .font(AppTypography.label)

                Text("isEmphasized only affects .selection material (for sidebars)")
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.4))
                    .italic()
            }
        }
    }

    private var statusColorsContent: some View {
        VStack(spacing: 12) {
            StatusColorSection(
                title: "Ready",
                hue: $config.statusReadyHue,
                saturation: $config.statusReadySaturation,
                brightness: $config.statusReadyBrightness,
                color: config.statusReadyColor
            )

            StatusColorSection(
                title: "Working",
                hue: $config.statusWorkingHue,
                saturation: $config.statusWorkingSaturation,
                brightness: $config.statusWorkingBrightness,
                color: config.statusWorkingColor
            )

            StatusColorSection(
                title: "Waiting",
                hue: $config.statusWaitingHue,
                saturation: $config.statusWaitingSaturation,
                brightness: $config.statusWaitingBrightness,
                color: config.statusWaitingColor
            )

            StatusColorSection(
                title: "Compacting",
                hue: $config.statusCompactingHue,
                saturation: $config.statusCompactingSaturation,
                brightness: $config.statusCompactingBrightness,
                color: config.statusCompactingColor
            )

            TuningSection(title: "Idle") {
                HStack {
                    Circle()
                        .fill(config.statusIdleColor)
                        .frame(width: 12, height: 12)
                    Spacer()
                }
                TuningSlider(label: "Opacity", value: $config.statusIdleOpacity, range: 0...1)
            }
        }
    }

    private var effectsContent: some View {
        VStack(spacing: 12) {
            TuningSection(title: "Compacting Text") {
                TuningSlider(label: "Cycle Length", value: $config.compactingCycleLength, range: 0.5...4)
                TuningSlider(label: "Min Tracking", value: $config.compactingMinTracking, range: -6...3)
                TuningSlider(label: "Max Tracking", value: $config.compactingMaxTracking, range: -3...6)
                TuningSlider(label: "Compress Time", value: $config.compactingCompressDuration, range: 0.1...1)
                TuningSlider(label: "Compress Damping", value: $config.compactingCompressDamping, range: 0.3...2)
                TuningSlider(label: "Compress Omega", value: $config.compactingCompressOmega, range: 2...20)
                TuningSlider(label: "Hold Time", value: $config.compactingHoldDuration, range: 0...1)
                TuningSlider(label: "Expand Time", value: $config.compactingExpandDuration, range: 0.1...2)
                TuningSlider(label: "Expand Damping", value: $config.compactingExpandDamping, range: 0.3...2)
                TuningSlider(label: "Expand Omega", value: $config.compactingExpandOmega, range: 2...20)
            }

            TuningSection(title: "Ready Ripple") {
                TuningSlider(label: "Speed (seconds)", value: $config.rippleSpeed, range: 1...10)
                TuningSlider(label: "Ring Count", value: Binding(
                    get: { Double(config.rippleCount) },
                    set: { config.rippleCount = Int($0) }
                ), range: 1...6)
                TuningSlider(label: "Max Opacity", value: $config.rippleMaxOpacity, range: 0...1)
                TuningSlider(label: "Line Width", value: $config.rippleLineWidth, range: 0.5...30)
                TuningSlider(label: "Blur Amount", value: $config.rippleBlurAmount, range: 0...60)
                TuningSlider(label: "Fade In Zone", value: $config.rippleFadeInZone, range: 0...0.5)
                TuningSlider(label: "Fade Out Power", value: $config.rippleFadeOutPower, range: 0.5...4)
                TuningSlider(label: "Origin X", value: $config.rippleOriginX, range: 0...1)
                TuningSlider(label: "Origin Y", value: $config.rippleOriginY, range: 0...1)
            }

            TuningSection(title: "Border Glow") {
                TuningSlider(label: "Inner Width", value: $config.borderGlowInnerWidth, range: 0.25...3)
                TuningSlider(label: "Outer Width", value: $config.borderGlowOuterWidth, range: 0.5...5)
                TuningSlider(label: "Inner Blur", value: $config.borderGlowInnerBlur, range: 0...3)
                TuningSlider(label: "Outer Blur", value: $config.borderGlowOuterBlur, range: 0...8)
                TuningSlider(label: "Base Opacity", value: $config.borderGlowBaseOpacity, range: 0...1)
                TuningSlider(label: "Pulse Intensity", value: $config.borderGlowPulseIntensity, range: 0...1)
                TuningSlider(label: "Rotation Speed", value: $config.borderGlowRotationMultiplier, range: 0...2)
            }

            TuningSection(title: "Waiting Pulse", isExpanded: false) {
                TuningSlider(label: "Cycle Length", value: $config.waitingCycleLength, range: 1...5)
                TuningSlider(label: "1st Pulse Duration", value: $config.waitingFirstPulseDuration, range: 0.05...0.5)
                TuningSlider(label: "1st Pulse Fade", value: $config.waitingFirstPulseFadeOut, range: 0.1...0.6)
                TuningSlider(label: "2nd Pulse Delay", value: $config.waitingSecondPulseDelay, range: 0...0.5)
                TuningSlider(label: "2nd Pulse Duration", value: $config.waitingSecondPulseDuration, range: 0.05...0.5)
                TuningSlider(label: "2nd Pulse Fade", value: $config.waitingSecondPulseFadeOut, range: 0.1...0.6)
                TuningSlider(label: "1st Pulse Intensity", value: $config.waitingFirstPulseIntensity, range: 0...1)
                TuningSlider(label: "2nd Pulse Intensity", value: $config.waitingSecondPulseIntensity, range: 0...1)
                TuningSlider(label: "Max Opacity", value: $config.waitingMaxOpacity, range: 0...1)
                TuningSlider(label: "Blur Amount", value: $config.waitingBlurAmount, range: 0...60)
                TuningSlider(label: "Pulse Scale", value: $config.waitingPulseScale, range: 1...3)
                TuningSlider(label: "Scale Amount", value: $config.waitingScaleAmount, range: 0...1)
                TuningSlider(label: "Spring Damping", value: $config.waitingSpringDamping, range: 0.5...2)
                TuningSlider(label: "Spring Omega", value: $config.waitingSpringOmega, range: 2...20)
                TuningSlider(label: "Origin X", value: $config.waitingOriginX, range: 0...1)
                TuningSlider(label: "Origin Y", value: $config.waitingOriginY, range: 0...1)
            }

            TuningSection(title: "Waiting Border", isExpanded: false) {
                TuningSlider(label: "Base Opacity", value: $config.waitingBorderBaseOpacity, range: 0...0.5)
                TuningSlider(label: "Pulse Opacity", value: $config.waitingBorderPulseOpacity, range: 0...1)
                TuningSlider(label: "Inner Width", value: $config.waitingBorderInnerWidth, range: 0.5...4)
                TuningSlider(label: "Outer Width", value: $config.waitingBorderOuterWidth, range: 1...8)
                TuningSlider(label: "Outer Blur", value: $config.waitingBorderOuterBlur, range: 0...12)
            }
        }
    }

    private var previewContent: some View {
        VStack(spacing: 16) {
            TuningSection(title: "Trigger State Preview") {
                Text("Click a state to preview it on all project cards")
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 4)

                ForEach(PreviewState.allCases, id: \.self) { state in
                    StatePreviewButton(
                        state: state,
                        isSelected: config.previewState == state,
                        color: config.colorForState(state)
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            config.previewState = state
                        }
                    }
                }
            }

            TuningSection(title: "Live Preview") {
                VStack(spacing: 12) {
                    ForEach([PreviewState.ready, .working, .waiting, .compacting, .idle], id: \.self) { state in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(config.colorForState(state))
                                .frame(width: 10, height: 10)
                                .shadow(color: config.colorForState(state).opacity(0.6), radius: 4)
                            Text(state.rawValue)
                                .font(AppTypography.labelMedium)
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 8) {
            Button(action: { config.reset() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(AppTypography.label.weight(.semibold))
                    Text("Reset")
                        .font(AppTypography.labelMedium)
                }
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.hudCard)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: copyToClipboard) {
                HStack(spacing: 4) {
                    Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                        .font(AppTypography.label.weight(.semibold))
                    Text(copiedToClipboard ? "Copied!" : "Export")
                        .font(AppTypography.labelMedium)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    LinearGradient(
                        colors: [Color.hudAccent, Color.hudAccentDark],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(config.exportForLLM(), forType: .string)

        withAnimation(.spring(response: 0.3)) {
            copiedToClipboard = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.3)) {
                copiedToClipboard = false
            }
        }
    }
}

struct TuningTab: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(AppTypography.caption)
                Text(title)
                    .font(AppTypography.captionSmall.weight(.medium))
            }
            .foregroundColor(isSelected ? .hudAccent : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(isSelected ? Color.hudAccent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

struct StatusColorSection: View {
    let title: String
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    let color: Color

    var body: some View {
        TuningSection(title: title) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .shadow(color: color.opacity(0.5), radius: 4)
                Text(title)
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
            }
            TuningSlider(label: "Hue", value: $hue, range: 0...1)
            TuningSlider(label: "Saturation", value: $saturation, range: 0...1)
            TuningSlider(label: "Brightness", value: $brightness, range: 0...1)
        }
    }
}

struct StatePreviewButton: View {
    let state: PreviewState
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if state != .none {
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                        .shadow(color: color.opacity(0.4), radius: 3)
                }
                Text(state.rawValue)
                    .font(isSelected ? AppTypography.labelMedium : AppTypography.label)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(AppTypography.captionSmall.weight(.bold))
                        .foregroundColor(.hudAccent)
                }
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.hudAccent.opacity(0.15) : Color.hudCard.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.hudAccent.opacity(0.3) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

struct TuningSection<Content: View>: View {
    let title: String
    let content: () -> Content
    @State private var isExpanded: Bool

    init(title: String, isExpanded: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = State(initialValue: isExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.spring(response: 0.25)) { isExpanded.toggle() } }) {
                HStack {
                    Text(title.uppercased())
                        .font(AppTypography.captionSmall.weight(.bold))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.4))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(AppTypography.captionSmall.weight(.semibold))
                        .foregroundColor(.white.opacity(0.25))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 8) {
                    content()
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.hudCard.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.04), lineWidth: 0.5)
        )
    }
}

struct TuningSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var displayValue: String {
        if range.upperBound <= 1 {
            return String(format: "%.2f", value)
        } else if range.upperBound <= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.0f", value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.55))

                Spacer()

                Text(displayValue)
                    .font(AppTypography.monoSmall.weight(.medium))
                    .foregroundColor(.hudAccent)
            }

            Slider(value: $value, in: range)
                .controlSize(.mini)
                .tint(.hudAccent)
        }
    }
}

#endif
