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

    // Logo letterpress effect (tuned)
    @Published var logoFontSize: Double = 14.55
    @Published var logoTracking: Double = 2.61
    @Published var logoBaseOpacity: Double = 0.9
    @Published var logoShadowOpacity: Double = 0.01
    @Published var logoShadowOffsetX: Double = -2.96
    @Published var logoShadowOffsetY: Double = -2.93
    @Published var logoShadowBlur: Double = 0.04
    @Published var logoHighlightOpacity: Double = 0.01
    @Published var logoHighlightOffsetX: Double = -2.95
    @Published var logoHighlightOffsetY: Double = -2.95
    @Published var logoHighlightBlur: Double = 0.0
    @Published var logoShadowBlendMode: BlendMode = .colorBurn
    @Published var logoHighlightBlendMode: BlendMode = .softLight

    // Logo Glass Shader (tuned)
    @Published var logoShaderEnabled: Bool = true
    @Published var logoShaderMaskToText: Bool = true
    @Published var logoGlassFresnelPower: Double = 4.02
    @Published var logoGlassFresnelIntensity: Double = 1.88
    @Published var logoGlassChromaticAmount: Double = 1.32
    @Published var logoGlassCausticScale: Double = 1.24
    @Published var logoGlassCausticSpeed: Double = 1.30
    @Published var logoGlassCausticIntensity: Double = 0.99
    @Published var logoGlassCausticAngle: Double = 81.31
    @Published var logoGlassClarity: Double = 0.34
    @Published var logoGlassHighlightSharpness: Double = 7.91
    @Published var logoGlassHighlightAngle: Double = 355.43
    @Published var logoGlassInternalReflection: Double = 0.44
    @Published var logoGlassInternalAngle: Double = 75.18
    @Published var logoGlassPrismaticEnabled: Bool = true
    @Published var logoGlassPrismAmount: Double = 0.12

    // Logo Shader Compositing (tuned)
    @Published var logoShaderOpacity: Double = 0.63
    @Published var logoShaderBlendMode: BlendMode = .overlay
    @Published var logoShaderVibrancyEnabled: Bool = true
    @Published var logoShaderVibrancyBlur: Double = 0.03

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

    // MARK: - Working Stripe Effect (tuned defaults)
    @Published var workingStripeWidth: Double = 24.0
    @Published var workingStripeSpacing: Double = 38.49
    @Published var workingStripeAngle: Double = 41.30
    @Published var workingScrollSpeed: Double = 4.81
    @Published var workingStripeOpacity: Double = 0.50
    @Published var workingDarkStripeOpacity: Double = 0.15
    @Published var workingGlowIntensity: Double = 1.50
    @Published var workingGlowBlurRadius: Double = 11.46
    @Published var workingCoreBrightness: Double = 0.71
    @Published var workingGradientFalloff: Double = 0.32
    @Published var workingVignetteInnerRadius: Double = 0.02
    @Published var workingVignetteOuterRadius: Double = 0.48
    @Published var workingVignetteCenterOpacity: Double = 0.03
    // Note: Cannot use .statusWorking here as it would cause circular initialization
    @Published var workingVignetteColor: Color = Color(hue: 0.05, saturation: 0.67, brightness: 0.39)
    @Published var workingVignetteColorIntensity: Double = 0.47
    @Published var workingVignetteBlendMode: BlendMode = .plusLighter
    @Published var workingVignetteColorHue: Double = 0.05
    @Published var workingVignetteColorSaturation: Double = 0.67
    @Published var workingVignetteColorBrightness: Double = 0.39

    // Working border glow (tuned defaults)
    @Published var workingBorderWidth: Double = 1.0
    @Published var workingBorderBaseOpacity: Double = 0.35
    @Published var workingBorderPulseIntensity: Double = 0.50
    @Published var workingBorderPulseSpeed: Double = 2.21
    @Published var workingBorderBlurAmount: Double = 8.0

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

    // MARK: - Card Interaction (Per-Pointer-Event, tuned)
    // Idle state
    @Published var cardIdleScale: Double = 1.0
    @Published var cardIdleShadowOpacity: Double = 0.17
    @Published var cardIdleShadowRadius: Double = 8.07
    @Published var cardIdleShadowY: Double = 3.89

    // Hover state
    @Published var cardHoverScale: Double = 1.01
    @Published var cardHoverSpringResponse: Double = 0.26
    @Published var cardHoverSpringDamping: Double = 0.90
    @Published var cardHoverShadowOpacity: Double = 0.2
    @Published var cardHoverShadowRadius: Double = 12.0
    @Published var cardHoverShadowY: Double = 4.0

    // Pressed state
    @Published var cardPressedScale: Double = 1.00
    @Published var cardPressedSpringResponse: Double = 0.06
    @Published var cardPressedSpringDamping: Double = 0.48
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

    // MARK: - Working Effect Accessors (unified)
    func workingStripeWidth(for layout: LayoutMode) -> Double { workingStripeWidth }
    func workingStripeSpacing(for layout: LayoutMode) -> Double { workingStripeSpacing }
    func workingStripeAngle(for layout: LayoutMode) -> Double { workingStripeAngle }
    func workingScrollSpeed(for layout: LayoutMode) -> Double { workingScrollSpeed }
    func workingStripeOpacity(for layout: LayoutMode) -> Double { workingStripeOpacity }
    func workingDarkStripeOpacity(for layout: LayoutMode) -> Double { workingDarkStripeOpacity }
    func workingGlowIntensity(for layout: LayoutMode) -> Double { workingGlowIntensity }
    func workingGlowBlurRadius(for layout: LayoutMode) -> Double { workingGlowBlurRadius }
    func workingCoreBrightness(for layout: LayoutMode) -> Double { workingCoreBrightness }
    func workingGradientFalloff(for layout: LayoutMode) -> Double { workingGradientFalloff }
    func workingVignetteInnerRadius(for layout: LayoutMode) -> Double { workingVignetteInnerRadius }
    func workingVignetteOuterRadius(for layout: LayoutMode) -> Double { workingVignetteOuterRadius }
    func workingVignetteCenterOpacity(for layout: LayoutMode) -> Double { workingVignetteCenterOpacity }
    func workingVignetteColorIntensity(for layout: LayoutMode) -> Double { workingVignetteColorIntensity }
    func workingBorderWidth(for layout: LayoutMode) -> Double { workingBorderWidth }
    func workingBorderBaseOpacity(for layout: LayoutMode) -> Double { workingBorderBaseOpacity }
    func workingBorderPulseIntensity(for layout: LayoutMode) -> Double { workingBorderPulseIntensity }
    func workingBorderPulseSpeed(for layout: LayoutMode) -> Double { workingBorderPulseSpeed }
    func workingBorderBlurAmount(for layout: LayoutMode) -> Double { workingBorderBlurAmount }

    // MARK: - Card Interaction Accessors (unified)
    func cardIdleScale(for layout: LayoutMode) -> Double { cardIdleScale }
    func cardHoverScale(for layout: LayoutMode) -> Double { cardHoverScale }
    func cardHoverSpringResponse(for layout: LayoutMode) -> Double { cardHoverSpringResponse }
    func cardHoverSpringDamping(for layout: LayoutMode) -> Double { cardHoverSpringDamping }
    func cardPressedScale(for layout: LayoutMode) -> Double { cardPressedScale }
    func cardPressedSpringResponse(for layout: LayoutMode) -> Double { cardPressedSpringResponse }
    func cardPressedSpringDamping(for layout: LayoutMode) -> Double { cardPressedSpringDamping }

    func reset() {
        // Logo letterpress (tuned)
        logoFontSize = 14.55
        logoTracking = 2.61
        logoBaseOpacity = 0.9
        logoShadowOpacity = 0.01
        logoShadowOffsetX = -2.96
        logoShadowOffsetY = -2.93
        logoShadowBlur = 0.04
        logoHighlightOpacity = 0.01
        logoHighlightOffsetX = -2.95
        logoHighlightOffsetY = -2.95
        logoHighlightBlur = 0.0
        logoShadowBlendMode = .colorBurn
        logoHighlightBlendMode = .softLight

        // Logo glass shader (tuned)
        logoShaderEnabled = true
        logoShaderMaskToText = true
        logoGlassFresnelPower = 4.02
        logoGlassFresnelIntensity = 1.88
        logoGlassChromaticAmount = 1.32
        logoGlassCausticScale = 1.24
        logoGlassCausticSpeed = 1.30
        logoGlassCausticIntensity = 0.99
        logoGlassCausticAngle = 81.31
        logoGlassClarity = 0.34
        logoGlassHighlightSharpness = 7.91
        logoGlassHighlightAngle = 355.43
        logoGlassInternalReflection = 0.44
        logoGlassInternalAngle = 75.18
        logoGlassPrismaticEnabled = true
        logoGlassPrismAmount = 0.12

        // Logo shader compositing (tuned)
        logoShaderOpacity = 0.63
        logoShaderBlendMode = .overlay
        logoShaderVibrancyEnabled = true
        logoShaderVibrancyBlur = 0.03

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
        cardIdleShadowOpacity = 0.17
        cardIdleShadowRadius = 8.07
        cardIdleShadowY = 3.89
        cardHoverScale = 1.01
        cardHoverSpringResponse = 0.26
        cardHoverSpringDamping = 0.90
        cardHoverShadowOpacity = 0.2
        cardHoverShadowRadius = 12.0
        cardHoverShadowY = 4.0
        cardPressedScale = 1.00
        cardPressedSpringResponse = 0.06
        cardPressedSpringDamping = 0.48
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
            // Logo Letterpress (tuned)
            ("Logo Letterpress", "logoFontSize", 14.55, logoFontSize),
            ("Logo Letterpress", "logoTracking", 2.61, logoTracking),
            ("Logo Letterpress", "logoBaseOpacity", 0.9, logoBaseOpacity),
            ("Logo Letterpress", "logoShadowOpacity", 0.01, logoShadowOpacity),
            ("Logo Letterpress", "logoShadowOffsetX", -2.96, logoShadowOffsetX),
            ("Logo Letterpress", "logoShadowOffsetY", -2.93, logoShadowOffsetY),
            ("Logo Letterpress", "logoShadowBlur", 0.04, logoShadowBlur),
            ("Logo Letterpress", "logoHighlightOpacity", 0.01, logoHighlightOpacity),
            ("Logo Letterpress", "logoHighlightOffsetX", -2.95, logoHighlightOffsetX),
            ("Logo Letterpress", "logoHighlightOffsetY", -2.95, logoHighlightOffsetY),
            ("Logo Letterpress", "logoHighlightBlur", 0.0, logoHighlightBlur),
            // Logo Glass Shader (tuned defaults)
            ("Logo Glass", "logoGlassFresnelPower", 4.02, logoGlassFresnelPower),
            ("Logo Glass", "logoGlassFresnelIntensity", 1.88, logoGlassFresnelIntensity),
            ("Logo Glass", "logoGlassChromaticAmount", 1.32, logoGlassChromaticAmount),
            ("Logo Glass", "logoGlassCausticScale", 1.24, logoGlassCausticScale),
            ("Logo Glass", "logoGlassCausticSpeed", 1.30, logoGlassCausticSpeed),
            ("Logo Glass", "logoGlassCausticIntensity", 0.99, logoGlassCausticIntensity),
            ("Logo Glass", "logoGlassCausticAngle", 81.31, logoGlassCausticAngle),
            ("Logo Glass", "logoGlassClarity", 0.34, logoGlassClarity),
            ("Logo Glass", "logoGlassHighlightSharpness", 7.91, logoGlassHighlightSharpness),
            ("Logo Glass", "logoGlassHighlightAngle", 355.43, logoGlassHighlightAngle),
            ("Logo Glass", "logoGlassInternalReflection", 0.44, logoGlassInternalReflection),
            ("Logo Glass", "logoGlassInternalAngle", 75.18, logoGlassInternalAngle),
            ("Logo Glass", "logoGlassPrismAmount", 0.12, logoGlassPrismAmount),
            // Logo Compositing (tuned defaults)
            ("Logo Compositing", "logoShaderOpacity", 0.63, logoShaderOpacity),
            ("Logo Compositing", "logoShaderVibrancyBlur", 0.03, logoShaderVibrancyBlur),
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
            // Card Interaction (tuned defaults)
            ("Card Idle", "cardIdleScale", 1.0, cardIdleScale),
            ("Card Idle", "cardIdleShadowOpacity", 0.17, cardIdleShadowOpacity),
            ("Card Idle", "cardIdleShadowRadius", 8.07, cardIdleShadowRadius),
            ("Card Idle", "cardIdleShadowY", 3.89, cardIdleShadowY),
            ("Card Hover", "cardHoverScale", 1.01, cardHoverScale),
            ("Card Hover", "cardHoverSpringResponse", 0.26, cardHoverSpringResponse),
            ("Card Hover", "cardHoverSpringDamping", 0.90, cardHoverSpringDamping),
            ("Card Hover", "cardHoverShadowOpacity", 0.2, cardHoverShadowOpacity),
            ("Card Hover", "cardHoverShadowRadius", 12.0, cardHoverShadowRadius),
            ("Card Hover", "cardHoverShadowY", 4.0, cardHoverShadowY),
            ("Card Pressed", "cardPressedScale", 1.00, cardPressedScale),
            ("Card Pressed", "cardPressedSpringResponse", 0.06, cardPressedSpringResponse),
            ("Card Pressed", "cardPressedSpringDamping", 0.48, cardPressedSpringDamping),
            ("Card Pressed", "cardPressedShadowOpacity", 0.12, cardPressedShadowOpacity),
            ("Card Pressed", "cardPressedShadowRadius", 2.0, cardPressedShadowRadius),
            ("Card Pressed", "cardPressedShadowY", 1.0, cardPressedShadowY),
        ]

        let changed = allParams.filter { abs($0.2 - $0.3) > 0.001 }

        // Blend mode params: (category, name, default, current) - tuned defaults
        let blendModeParams: [(String, String, BlendMode, BlendMode)] = [
            ("Logo Letterpress", "logoShadowBlendMode", .colorBurn, logoShadowBlendMode),
            ("Logo Letterpress", "logoHighlightBlendMode", .softLight, logoHighlightBlendMode),
            ("Logo Compositing", "logoShaderBlendMode", .overlay, logoShaderBlendMode),
        ]
        let changedBlendModes = blendModeParams.filter { $0.2 != $0.3 }

        // Boolean params: (category, name, default, current)
        let boolParams: [(String, String, Bool, Bool)] = [
            ("Logo Glass", "logoShaderEnabled", true, logoShaderEnabled),
            ("Logo Glass", "logoShaderMaskToText", true, logoShaderMaskToText),
            ("Logo Glass", "logoGlassPrismaticEnabled", true, logoGlassPrismaticEnabled),
            ("Logo Compositing", "logoShaderVibrancyEnabled", true, logoShaderVibrancyEnabled),
        ]
        let changedBools = boolParams.filter { $0.2 != $0.3 }

        if changed.isEmpty && changedBlendModes.isEmpty && changedBools.isEmpty {
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

        // Add blend mode changes
        if !changedBlendModes.isEmpty {
            output += "// Blend Modes\n"
            for (_, name, defaultVal, currentVal) in changedBlendModes {
                output += "\(name): .\(blendModeName(defaultVal)) → .\(blendModeName(currentVal))\n"
            }
        }

        // Add boolean changes
        if !changedBools.isEmpty {
            output += "// Toggles\n"
            for (_, name, defaultVal, currentVal) in changedBools {
                output += "\(name): \(defaultVal) → \(currentVal)\n"
            }
        }

        output += "```"

        return output
    }

    private func blendModeName(_ mode: BlendMode) -> String {
        switch mode {
        case .normal: return "normal"
        case .multiply: return "multiply"
        case .screen: return "screen"
        case .overlay: return "overlay"
        case .plusLighter: return "plusLighter"
        case .softLight: return "softLight"
        case .hardLight: return "hardLight"
        case .colorBurn: return "colorBurn"
        case .colorDodge: return "colorDodge"
        case .luminosity: return "luminosity"
        default: return "unknown"
        }
    }
}

#endif
