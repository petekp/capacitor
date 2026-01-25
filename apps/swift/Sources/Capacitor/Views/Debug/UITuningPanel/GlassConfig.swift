import SwiftUI

extension EnvironmentValues {
    @Entry var glassConfig: GlassConfig = .shared
}

struct TunableColor {
    var hue: Double
    var saturation: Double
    var brightness: Double

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    static let ready = TunableColor(hue: 145 / 360, saturation: 0.75, brightness: 0.70)
    static let working = TunableColor(hue: 45 / 360, saturation: 0.65, brightness: 0.75)
    static let waiting = TunableColor(hue: 85 / 360, saturation: 0.70, brightness: 0.80)
    static let compacting = TunableColor(hue: 55 / 360, saturation: 0.55, brightness: 0.70)
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

@Observable
class GlassConfig {
    static let shared = GlassConfig()

    private(set) var refreshCounter: Int = 0

    init() {}

    static let materialNames = ["HUD Window", "Popover", "Menu", "Sidebar", "Full Screen UI"]

    var cardConfigHash: Int {
        var hasher = Hasher()
        hasher.combine(cardTintOpacity)
        hasher.combine(cardCornerRadius)
        hasher.combine(cardBorderOpacity)
        hasher.combine(cardHighlightOpacity)
        hasher.combine(cardHoverBorderOpacity)
        hasher.combine(cardHoverHighlightOpacity)
        hasher.combine(cardMaterialType)
        hasher.combine(cardBlendingMode)
        hasher.combine(cardEmphasized)
        hasher.combine(cardForceDarkAppearance)
        hasher.combine(cardSwiftUIBlendMode)
        hasher.combine(statusReadyHue)
        hasher.combine(statusWorkingHue)
        return hasher.finalize()
    }

    // Panel background
    var panelTintOpacity: Double = 0.46
    var panelCornerRadius: Double = 13.99
    var panelBorderOpacity: Double = 0.20
    var panelHighlightOpacity: Double = 0.03
    var panelTopHighlightOpacity: Double = 0.13
    var panelShadowOpacity: Double = 0.00
    var panelShadowRadius: Double = 0
    var panelShadowY: Double = 0

    // Card background
    var cardTintOpacity: Double = 0.74
    var cardCornerRadius: Double = 15.15
    var cardBorderOpacity: Double = 0.19
    var cardHighlightOpacity: Double = 0.00
    var cardHoverBorderOpacity: Double = 0.47
    var cardHoverHighlightOpacity: Double = 0.00

    // Card material settings (NSVisualEffectView)
    var cardMaterialType: Int = 1 // 0=hudWindow, 1=popover, 2=menu, 3=sidebar, 4=fullScreenUI
    var cardBlendingMode: Int = 0 // 0=behindWindow, 1=withinWindow
    var cardEmphasized: Bool = true
    var cardForceDarkAppearance: Bool = true

    /// Card SwiftUI blend mode for highlight overlay
    var cardSwiftUIBlendMode: Int = 3 // 0=normal, 1=plusLighter, 2=softLight, 3=overlay, 4=screen, 5=multiply

    /// Material settings
    var useEmphasizedMaterial: Bool = true {
        didSet { refreshCounter += 1 }
    }

    var materialType: Int = 0 { // 0=hudWindow, 1=popover, 2=menu, 3=sidebar, 4=fullScreenUI
        didSet { refreshCounter += 1 }
    }

    // MARK: - Logo Settings

    var logoScale: Double = 0.84
    var logoOpacity: Double = 0.22

    // Logo vibrancy (NSVisualEffectView)
    var logoUseVibrancy: Bool = true
    var logoMaterialType: Int = 2 // 0=hudWindow, 1=popover, 2=menu, 3=sidebar, 4=fullScreenUI
    var logoBlendingMode: Int = 0 // 0=behindWindow, 1=withinWindow
    var logoEmphasized: Bool = false
    var logoForceDarkAppearance: Bool = true

    /// Logo SwiftUI blend mode
    var logoSwiftUIBlendMode: Int = 3 // 0=normal, 1=plusLighter, 2=softLight, 3=overlay, 4=screen, 5=multiply, 6=difference

    // Status Colors - Ready (brand green, P3 approx in HSB)
    var statusReadyHue: Double = 0.369
    var statusReadySaturation: Double = 0.70
    var statusReadyBrightness: Double = 1.00

    // Status Colors - Working (yellow/orange)
    var statusWorkingHue: Double = 0.103
    var statusWorkingSaturation: Double = 1.00
    var statusWorkingBrightness: Double = 1.00

    // Status Colors - Waiting (coral/salmon)
    var statusWaitingHue: Double = 0.026
    var statusWaitingSaturation: Double = 0.58
    var statusWaitingBrightness: Double = 1.00

    // Status Colors - Compacting (purple/lavender)
    var statusCompactingHue: Double = 0.670
    var statusCompactingSaturation: Double = 0.50
    var statusCompactingBrightness: Double = 1.00

    /// Status Colors - Idle (gray)
    var statusIdleOpacity: Double = 0.40

    // Ready ripple effect (continuous)
    var rippleSpeed: Double = 7.13
    var rippleCount: Int = 3
    var rippleMaxOpacity: Double = 1.00
    var rippleLineWidth: Double = 60.00
    var rippleBlurAmount: Double = 35.73
    var rippleOriginX: Double = 0.05
    var rippleOriginY: Double = 0.00
    var rippleFadeInZone: Double = 0.20
    var rippleFadeOutPower: Double = 2.37

    // Ready border glow effect
    var borderGlowInnerWidth: Double = 2.00
    var borderGlowOuterWidth: Double = 1.73
    var borderGlowInnerBlur: Double = 3.01
    var borderGlowOuterBlur: Double = 0.00
    var borderGlowBaseOpacity: Double = 0.74
    var borderGlowPulseIntensity: Double = 1.00
    var borderGlowRotationMultiplier: Double = 0.50

    // MARK: - Waiting Pulse Effect

    var waitingCycleLength: Double = 1.68
    var waitingFirstPulseDuration: Double = 0.17
    var waitingFirstPulseFadeOut: Double = 0.17
    var waitingSecondPulseDelay: Double = 0.00
    var waitingSecondPulseDuration: Double = 0.17
    var waitingSecondPulseFadeOut: Double = 0.48
    var waitingFirstPulseIntensity: Double = 0.34
    var waitingSecondPulseIntensity: Double = 0.47
    var waitingMaxOpacity: Double = 0.34
    var waitingBlurAmount: Double = 0.0
    var waitingPulseScale: Double = 2.22
    var waitingScaleAmount: Double = 0.30
    var waitingSpringDamping: Double = 1.69
    var waitingSpringOmega: Double = 3.3
    var waitingOriginX: Double = 1.00
    var waitingOriginY: Double = 0.00

    // Waiting border glow
    var waitingBorderBaseOpacity: Double = 0.12
    var waitingBorderPulseOpacity: Double = 0.37
    var waitingBorderInnerWidth: Double = 0.50
    var waitingBorderOuterWidth: Double = 1.86
    var waitingBorderOuterBlur: Double = 0.8

    // MARK: - Working Stripe Effect (tuned defaults)

    var workingStripeWidth: Double = 24.0
    var workingStripeSpacing: Double = 44.91
    var workingStripeAngle: Double = 38.02
    var workingScrollSpeed: Double = 3.68
    var workingStripeOpacity: Double = 0.83
    var workingGlowIntensity: Double = 3.00
    var workingGlowBlurRadius: Double = 30.00
    var workingCoreBrightness: Double = 0.56
    var workingGradientFalloff: Double = 0.39
    var workingVignetteInnerRadius: Double = 0.03
    var workingVignetteOuterRadius: Double = 0.00
    var workingVignetteCenterOpacity: Double = 0.05
    /// Derived from HSB values below so tuning panel changes propagate to the renderer
    var workingVignetteColor: Color {
        Color(hue: workingVignetteColorHue, saturation: workingVignetteColorSaturation, brightness: workingVignetteColorBrightness)
    }

    var workingVignetteColorIntensity: Double = 0.60
    var workingVignetteBlendMode: BlendMode = .plusLighter
    var workingVignetteColorHue: Double = 0.06
    var workingVignetteColorSaturation: Double = 0.92
    var workingVignetteColorBrightness: Double = 0.33

    // Working border glow (tuned defaults)
    var workingBorderWidth: Double = 2.05
    var workingBorderBaseOpacity: Double = 0.34
    var workingBorderPulseIntensity: Double = 0.50
    var workingBorderPulseSpeed: Double = 2.21
    var workingBorderBlurAmount: Double = 8.0

    // MARK: - Empty State Border Glow

    var emptyGlowSpeed: Double = 3.21
    var emptyGlowPulseCount: Int = 4
    var emptyGlowBaseOpacity: Double = 0.09
    var emptyGlowPulseRange: Double = 0.59
    var emptyGlowInnerWidth: Double = 0.91
    var emptyGlowOuterWidth: Double = 1.21
    var emptyGlowInnerBlur: Double = 0.27
    var emptyGlowOuterBlur: Double = 4.19
    var emptyGlowFadeInZone: Double = 0.15
    var emptyGlowFadeOutPower: Double = 1.0

    // MARK: - Card Interaction (Per-Pointer-Event, tuned)

    // Idle state
    var cardIdleScale: Double = 1.0
    var cardIdleShadowOpacity: Double = 0.17
    var cardIdleShadowRadius: Double = 8.07
    var cardIdleShadowY: Double = 3.89

    // Hover state
    var cardHoverScale: Double = 1.01
    var cardHoverSpringResponse: Double = 0.16
    var cardHoverSpringDamping: Double = 0.68
    var cardHoverShadowOpacity: Double = 0.2
    var cardHoverShadowRadius: Double = 12.0
    var cardHoverShadowY: Double = 4.0

    // Pressed state
    var cardPressedScale: Double = 1.00
    var cardPressedSpringResponse: Double = 0.09
    var cardPressedSpringDamping: Double = 0.34
    var cardPressedShadowOpacity: Double = 0.12
    var cardPressedShadowRadius: Double = 2.0
    var cardPressedShadowY: Double = 1.0

    // Press tilt & ripple (positional click feedback)
    var cardPressTiltHorizontal: Double = 1.86
    var cardPressTiltVertical: Double = 5.87
    var cardPressRippleOpacity: Double = 1.70
    var cardPressDistortion: Double = 0.0

    // MARK: - Metal Highlight Parameters (GPU shader)

    var highlightRingFrequency: Double = 1.00
    var highlightRingSharpness: Double = 1.13
    var highlightFalloff: Double = 0.10
    var highlightSpecularTightness: Double = 8.60
    var highlightSpecularWeight: Double = 1.33
    var highlightRingWeight: Double = 0.84
    var highlightRippleSpeed: Double = 9.06
    var highlightRippleDuration: Double = 0.63
    /// Blend mode for the metallic highlight overlay.
    /// 0=normal, 1=plusLighter, 2=softLight, 3=overlay, 4=screen, 5=colorDodge, 6=hardLight
    var highlightBlendMode: Int = 3
    /// Whether the ripple uses vibrancy (NSVisualEffectView) as its base layer.
    var highlightUseVibrancy: Bool = false
    /// NSVisualEffectView material for the vibrancy base. Same as card material picker.
    var highlightVibrancyMaterial: Int = 4 // 0=hudWindow, 1=popover, 2=menu, 3=sidebar, 4=fullScreenUI

    // MARK: - Press Distortion Parameters (SwiftUI projectionEffect)

    var distortionMaxSkew: Double = 0.0
    var distortionScaleInset: Double = 0.0
    var distortionDirectionalScale: Double = 0.0
    var distortionAnchorOffset: Double = 0.07

    // MARK: - Compacting Text Animation

    var compactingCycleLength: Double = 1.8
    var compactingMinTracking: Double = 0.0
    var compactingMaxTracking: Double = 2.1
    var compactingCompressDuration: Double = 0.26
    var compactingHoldDuration: Double = 0.50
    var compactingExpandDuration: Double = 1.0
    // Spring parameters for compress phase
    var compactingCompressDamping: Double = 0.3
    var compactingCompressOmega: Double = 16.0
    // Spring parameters for expand phase
    var compactingExpandDamping: Double = 0.8
    var compactingExpandOmega: Double = 4.0

    // MARK: - State Transition Animations

    var stateTransitionDuration: Double = 0.35 // Duration for state change animations
    var glowFadeDuration: Double = 0.5 // Duration for glow effect cross-fade
    var glowBorderDelay: Double = 0.08 // Stagger delay for border glow after ambient
    var hoverTransitionDuration: Double = 0.12 // Duration for hover state changes
    var cardInsertStagger: Double = 0.04 // Per-card stagger delay on insert
    var cardRemovalDuration: Double = 0.15 // Duration for card removal animation
    var cardInsertSpringResponse: Double = 0.25 // Spring response for card insertion
    var cardInsertSpringDamping: Double = 0.8 // Spring damping for card insertion
    var pausedCardStagger: Double = 0.025 // Per-card stagger for paused section
    var sectionToggleSpringResponse: Double = 0.18 // Spring response for section collapse/expand
    var cardReorderSpringResponse: Double = 0.35 // Spring response for card position reorder
    var cardReorderSpringDamping: Double = 0.85 // Spring damping for card position reorder

    // MARK: - Layout Settings (Card List)

    var cardListSpacing: Double = 4.98 // Gap between cards in vertical list
    var cardPaddingHorizontal: Double = 15.07 // Horizontal internal padding for vertical cards
    var cardPaddingVertical: Double = 11.40 // Vertical internal padding for vertical cards
    var listHorizontalPadding: Double = 11.60 // Horizontal padding for list container

    // MARK: - Layout Settings (Dock)

    var dockCardSpacing: Double = 12.41 // Gap between cards in horizontal dock
    var dockCardPaddingHorizontal: Double = 14.85 // Horizontal internal padding for dock cards
    var dockCardPaddingVertical: Double = 13.79 // Vertical internal padding for dock cards
    var dockHorizontalPadding: Double = 10.25 // Horizontal padding for dock container
    var dockCardWidth: Double = 231.03 // Fixed width of each dock card
    var dockCardMinHeight: Double = 43.20 // Minimum height (0 = auto)
    var dockCardMaxHeight: Double = 141.23 // Maximum height (0 = no limit)
    var dockCardCornerRadius: Double = 8.61 // Independent corner radius (0 = derive from card)
    var dockVerticalPadding: Double = 9.80 // Vertical padding for dock container
    var dockWindowMinHeight: Double = 110.50 // Minimum window height in dock mode
    var dockWindowMaxHeight: Double = 187.25 // Maximum window height in dock mode
    var dockPageIndicatorSpacing: Double = 8.0 // Spacing between cards and page dots
    var dockCardContentSpacing: Double = 10.0 // HStack spacing inside card
    var dockChipTopPadding: Double = 4.0 // Padding above status chips row

    // MARK: - Layout Rounded Accessors (whole pixels)

    var cardListSpacingRounded: CGFloat {
        round(cardListSpacing)
    }

    var cardPaddingH: CGFloat {
        round(cardPaddingHorizontal)
    }

    var cardPaddingV: CGFloat {
        round(cardPaddingVertical)
    }

    var listHorizontalPaddingRounded: CGFloat {
        round(listHorizontalPadding)
    }

    var dockCardSpacingRounded: CGFloat {
        round(dockCardSpacing)
    }

    var dockCardPaddingH: CGFloat {
        round(dockCardPaddingHorizontal)
    }

    var dockCardPaddingV: CGFloat {
        round(dockCardPaddingVertical)
    }

    var dockHorizontalPaddingRounded: CGFloat {
        round(dockHorizontalPadding)
    }

    var dockCardWidthRounded: CGFloat {
        round(dockCardWidth)
    }

    var dockCardMinHeightRounded: CGFloat {
        round(dockCardMinHeight)
    }

    var dockCardMaxHeightRounded: CGFloat {
        round(dockCardMaxHeight)
    }

    var dockCardCornerRadiusRounded: CGFloat {
        round(dockCardCornerRadius)
    }

    var dockVerticalPaddingRounded: CGFloat {
        round(dockVerticalPadding)
    }

    var dockWindowMinHeightRounded: CGFloat {
        round(dockWindowMinHeight)
    }

    var dockWindowMaxHeightRounded: CGFloat {
        round(dockWindowMaxHeight)
    }

    var dockPageIndicatorSpacingRounded: CGFloat {
        round(dockPageIndicatorSpacing)
    }

    var dockCardContentSpacingRounded: CGFloat {
        round(dockCardContentSpacing)
    }

    var dockChipTopPaddingRounded: CGFloat {
        round(dockChipTopPadding)
    }

    /// State Preview
    var previewState: PreviewState = .none

    // MARK: - Layout-Aware Accessors (unified - layout param kept for API compatibility)

    func rippleSpeed(for _: LayoutMode) -> Double {
        rippleSpeed
    }

    func rippleCount(for _: LayoutMode) -> Int {
        rippleCount
    }

    func rippleMaxOpacity(for _: LayoutMode) -> Double {
        rippleMaxOpacity
    }

    func rippleLineWidth(for _: LayoutMode) -> Double {
        rippleLineWidth
    }

    func rippleBlurAmount(for _: LayoutMode) -> Double {
        rippleBlurAmount
    }

    func rippleOriginX(for _: LayoutMode) -> Double {
        rippleOriginX
    }

    func rippleOriginY(for _: LayoutMode) -> Double {
        rippleOriginY
    }

    func rippleFadeInZone(for _: LayoutMode) -> Double {
        rippleFadeInZone
    }

    func rippleFadeOutPower(for _: LayoutMode) -> Double {
        rippleFadeOutPower
    }

    func borderGlowInnerWidth(for _: LayoutMode) -> Double {
        borderGlowInnerWidth
    }

    func borderGlowOuterWidth(for _: LayoutMode) -> Double {
        borderGlowOuterWidth
    }

    func borderGlowInnerBlur(for _: LayoutMode) -> Double {
        borderGlowInnerBlur
    }

    func borderGlowOuterBlur(for _: LayoutMode) -> Double {
        borderGlowOuterBlur
    }

    func borderGlowBaseOpacity(for _: LayoutMode) -> Double {
        borderGlowBaseOpacity
    }

    func borderGlowPulseIntensity(for _: LayoutMode) -> Double {
        borderGlowPulseIntensity
    }

    func borderGlowRotationMultiplier(for _: LayoutMode) -> Double {
        borderGlowRotationMultiplier
    }

    // MARK: - Waiting Effect Accessors (unified)

    func waitingCycleLength(for _: LayoutMode) -> Double {
        waitingCycleLength
    }

    func waitingFirstPulseDuration(for _: LayoutMode) -> Double {
        waitingFirstPulseDuration
    }

    func waitingFirstPulseFadeOut(for _: LayoutMode) -> Double {
        waitingFirstPulseFadeOut
    }

    func waitingSecondPulseDelay(for _: LayoutMode) -> Double {
        waitingSecondPulseDelay
    }

    func waitingSecondPulseDuration(for _: LayoutMode) -> Double {
        waitingSecondPulseDuration
    }

    func waitingSecondPulseFadeOut(for _: LayoutMode) -> Double {
        waitingSecondPulseFadeOut
    }

    func waitingFirstPulseIntensity(for _: LayoutMode) -> Double {
        waitingFirstPulseIntensity
    }

    func waitingSecondPulseIntensity(for _: LayoutMode) -> Double {
        waitingSecondPulseIntensity
    }

    func waitingMaxOpacity(for _: LayoutMode) -> Double {
        waitingMaxOpacity
    }

    func waitingBlurAmount(for _: LayoutMode) -> Double {
        waitingBlurAmount
    }

    func waitingPulseScale(for _: LayoutMode) -> Double {
        waitingPulseScale
    }

    func waitingScaleAmount(for _: LayoutMode) -> Double {
        waitingScaleAmount
    }

    func waitingSpringDamping(for _: LayoutMode) -> Double {
        waitingSpringDamping
    }

    func waitingSpringOmega(for _: LayoutMode) -> Double {
        waitingSpringOmega
    }

    func waitingBorderBaseOpacity(for _: LayoutMode) -> Double {
        waitingBorderBaseOpacity
    }

    func waitingBorderPulseOpacity(for _: LayoutMode) -> Double {
        waitingBorderPulseOpacity
    }

    func waitingBorderInnerWidth(for _: LayoutMode) -> Double {
        waitingBorderInnerWidth
    }

    func waitingBorderOuterWidth(for _: LayoutMode) -> Double {
        waitingBorderOuterWidth
    }

    func waitingBorderOuterBlur(for _: LayoutMode) -> Double {
        waitingBorderOuterBlur
    }

    func waitingOriginX(for _: LayoutMode) -> Double {
        waitingOriginX
    }

    func waitingOriginY(for _: LayoutMode) -> Double {
        waitingOriginY
    }

    // MARK: - Working Effect Accessors (unified)

    func workingStripeWidth(for _: LayoutMode) -> Double {
        workingStripeWidth
    }

    func workingStripeSpacing(for _: LayoutMode) -> Double {
        workingStripeSpacing
    }

    func workingStripeAngle(for _: LayoutMode) -> Double {
        workingStripeAngle
    }

    func workingScrollSpeed(for _: LayoutMode) -> Double {
        workingScrollSpeed
    }

    func workingStripeOpacity(for _: LayoutMode) -> Double {
        workingStripeOpacity
    }

    func workingGlowIntensity(for _: LayoutMode) -> Double {
        workingGlowIntensity
    }

    func workingGlowBlurRadius(for _: LayoutMode) -> Double {
        workingGlowBlurRadius
    }

    func workingCoreBrightness(for _: LayoutMode) -> Double {
        workingCoreBrightness
    }

    func workingGradientFalloff(for _: LayoutMode) -> Double {
        workingGradientFalloff
    }

    func workingVignetteInnerRadius(for _: LayoutMode) -> Double {
        workingVignetteInnerRadius
    }

    func workingVignetteOuterRadius(for _: LayoutMode) -> Double {
        workingVignetteOuterRadius
    }

    func workingVignetteCenterOpacity(for _: LayoutMode) -> Double {
        workingVignetteCenterOpacity
    }

    func workingVignetteColorIntensity(for _: LayoutMode) -> Double {
        workingVignetteColorIntensity
    }

    func workingBorderWidth(for _: LayoutMode) -> Double {
        workingBorderWidth
    }

    func workingBorderBaseOpacity(for _: LayoutMode) -> Double {
        workingBorderBaseOpacity
    }

    func workingBorderPulseIntensity(for _: LayoutMode) -> Double {
        workingBorderPulseIntensity
    }

    func workingBorderPulseSpeed(for _: LayoutMode) -> Double {
        workingBorderPulseSpeed
    }

    func workingBorderBlurAmount(for _: LayoutMode) -> Double {
        workingBorderBlurAmount
    }

    // MARK: - Card Interaction Accessors (unified)

    func cardIdleScale(for _: LayoutMode) -> Double {
        cardIdleScale
    }

    func cardHoverScale(for _: LayoutMode) -> Double {
        cardHoverScale
    }

    func cardHoverSpringResponse(for _: LayoutMode) -> Double {
        cardHoverSpringResponse
    }

    func cardHoverSpringDamping(for _: LayoutMode) -> Double {
        cardHoverSpringDamping
    }

    func cardPressedScale(for _: LayoutMode) -> Double {
        cardPressedScale
    }

    func cardPressedSpringResponse(for _: LayoutMode) -> Double {
        cardPressedSpringResponse
    }

    func cardPressedSpringDamping(for _: LayoutMode) -> Double {
        cardPressedSpringDamping
    }

    // MARK: - Corner Radius Accessors

    /// Returns the card corner radius for the given layout mode.
    /// Dock mode uses a slightly smaller radius for the more compact cards.
    func cardCornerRadius(for layout: LayoutMode) -> CGFloat {
        switch layout {
        case .vertical:
            cardCornerRadius
        case .dock:
            // Use independent dock radius when set, otherwise derive proportionally
            if dockCardCornerRadius > 0 {
                dockCardCornerRadius
            } else {
                max(8, cardCornerRadius * 0.58)
            }
        }
    }

    /// Computes the inner corner radius for nested elements.
    /// Use this when an element is inset from the card edge.
    /// Formula: innerRadius = max(0, outerRadius - inset)
    func cardInsetCornerRadius(for layout: LayoutMode, inset: CGFloat) -> CGFloat {
        max(0, cardCornerRadius(for: layout) - inset)
    }

    func reset() {
        panelTintOpacity = 0.46
        panelCornerRadius = 13.99
        panelBorderOpacity = 0.20
        panelHighlightOpacity = 0.03
        panelTopHighlightOpacity = 0.13
        panelShadowOpacity = 0.00
        panelShadowRadius = 0
        panelShadowY = 0

        cardTintOpacity = 0.74
        cardCornerRadius = 15.15
        cardBorderOpacity = 0.19
        cardHighlightOpacity = 0.00
        cardHoverBorderOpacity = 0.47
        cardHoverHighlightOpacity = 0.00

        cardMaterialType = 1
        cardBlendingMode = 0
        cardEmphasized = true
        cardForceDarkAppearance = true
        cardSwiftUIBlendMode = 3

        useEmphasizedMaterial = true
        materialType = 0

        logoScale = 0.84
        logoOpacity = 0.22
        logoUseVibrancy = true
        logoMaterialType = 2
        logoBlendingMode = 0
        logoEmphasized = false
        logoForceDarkAppearance = true
        logoSwiftUIBlendMode = 3

        statusReadyHue = 0.369
        statusReadySaturation = 0.70
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

        rippleSpeed = 7.13
        rippleCount = 3
        rippleMaxOpacity = 1.00
        rippleLineWidth = 60.00
        rippleBlurAmount = 35.73
        rippleOriginX = 0.05
        rippleOriginY = 0.00
        rippleFadeInZone = 0.20
        rippleFadeOutPower = 2.37

        borderGlowInnerWidth = 2.00
        borderGlowOuterWidth = 1.73
        borderGlowInnerBlur = 3.01
        borderGlowOuterBlur = 0.00
        borderGlowBaseOpacity = 0.74
        borderGlowPulseIntensity = 1.00
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

        // Empty state border glow
        emptyGlowSpeed = 3.21
        emptyGlowPulseCount = 4
        emptyGlowBaseOpacity = 0.09
        emptyGlowPulseRange = 0.59
        emptyGlowInnerWidth = 0.91
        emptyGlowOuterWidth = 1.21
        emptyGlowInnerBlur = 0.27
        emptyGlowOuterBlur = 4.19
        emptyGlowFadeInZone = 0.15
        emptyGlowFadeOutPower = 1.0

        // Card interaction
        cardIdleScale = 1.0
        cardIdleShadowOpacity = 0.17
        cardIdleShadowRadius = 8.07
        cardIdleShadowY = 3.89
        cardHoverScale = 1.01
        cardHoverSpringResponse = 0.16
        cardHoverSpringDamping = 0.68
        cardHoverShadowOpacity = 0.2
        cardHoverShadowRadius = 12.0
        cardHoverShadowY = 4.0
        cardPressedScale = 1.00
        cardPressedSpringResponse = 0.09
        cardPressedSpringDamping = 0.34
        cardPressedShadowOpacity = 0.12
        cardPressedShadowRadius = 2.0
        cardPressedShadowY = 1.0
        cardPressTiltHorizontal = 1.86
        cardPressTiltVertical = 5.87
        cardPressRippleOpacity = 1.70
        cardPressDistortion = 0.0

        // Metal highlight
        highlightRingFrequency = 1.00
        highlightRingSharpness = 1.13
        highlightFalloff = 0.10
        highlightSpecularTightness = 8.60
        highlightSpecularWeight = 1.33
        highlightRingWeight = 0.84
        highlightRippleSpeed = 9.06
        highlightRippleDuration = 0.63
        highlightBlendMode = 3
        highlightUseVibrancy = false
        highlightVibrancyMaterial = 4

        // Press distortion
        distortionMaxSkew = 0.0
        distortionScaleInset = 0.0
        distortionDirectionalScale = 0.0
        distortionAnchorOffset = 0.07

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

        // State Transition Animations
        stateTransitionDuration = 0.35
        glowFadeDuration = 0.5
        glowBorderDelay = 0.08
        hoverTransitionDuration = 0.12
        cardInsertStagger = 0.04
        cardRemovalDuration = 0.15
        cardInsertSpringResponse = 0.25
        cardInsertSpringDamping = 0.8
        pausedCardStagger = 0.025
        sectionToggleSpringResponse = 0.18
        cardReorderSpringResponse = 0.35
        cardReorderSpringDamping = 0.85

        // Layout
        cardListSpacing = 4.98
        cardPaddingHorizontal = 15.07
        cardPaddingVertical = 11.40
        listHorizontalPadding = 11.60
        dockCardSpacing = 12.41
        dockCardPaddingHorizontal = 14.85
        dockCardPaddingVertical = 13.79
        dockHorizontalPadding = 10.25
        dockCardWidth = 231.03
        dockCardMinHeight = 43.20
        dockCardMaxHeight = 141.23
        dockCardCornerRadius = 8.61
        dockVerticalPadding = 9.80
        dockWindowMinHeight = 110.50
        dockWindowMaxHeight = 187.25
        dockPageIndicatorSpacing = 8.0
        dockCardContentSpacing = 10.0
        dockChipTopPadding = 4.0

        previewState = .none
    }

    func exportForLLM() -> String {
        let allParams: [(String, String, Double, Double)] = [
            // Panel Background
            ("Panel", "panelTintOpacity", 0.46, panelTintOpacity),
            ("Panel", "panelCornerRadius", 13.99, panelCornerRadius),
            ("Panel", "panelBorderOpacity", 0.20, panelBorderOpacity),
            ("Panel", "panelHighlightOpacity", 0.03, panelHighlightOpacity),
            ("Panel", "panelTopHighlightOpacity", 0.13, panelTopHighlightOpacity),
            ("Panel", "panelShadowOpacity", 0.00, panelShadowOpacity),
            ("Panel", "panelShadowRadius", 0, panelShadowRadius),
            ("Panel", "panelShadowY", 0, panelShadowY),
            // Card Background
            ("Card", "cardTintOpacity", 0.74, cardTintOpacity),
            ("Card", "cardCornerRadius", 15.15, cardCornerRadius),
            ("Card", "cardBorderOpacity", 0.19, cardBorderOpacity),
            ("Card", "cardHighlightOpacity", 0.00, cardHighlightOpacity),
            ("Card", "cardHoverBorderOpacity", 0.47, cardHoverBorderOpacity),
            ("Card", "cardHoverHighlightOpacity", 0.00, cardHoverHighlightOpacity),
            // Card Material
            ("Card Material", "cardMaterialType", 1, Double(cardMaterialType)),
            ("Card Material", "cardBlendingMode", 0, Double(cardBlendingMode)),
            ("Card Material", "cardEmphasized", 1, cardEmphasized ? 1.0 : 0.0),
            ("Card Material", "cardForceDarkAppearance", 1.0, cardForceDarkAppearance ? 1.0 : 0.0),
            ("Card Material", "cardSwiftUIBlendMode", 3, Double(cardSwiftUIBlendMode)),
            // Logo
            ("Logo", "logoScale", 0.84, logoScale),
            ("Logo", "logoOpacity", 0.22, logoOpacity),
            ("Logo", "logoUseVibrancy", 1.0, logoUseVibrancy ? 1.0 : 0.0),
            ("Logo", "logoMaterialType", 2.0, Double(logoMaterialType)),
            ("Logo", "logoBlendingMode", 0.0, Double(logoBlendingMode)),
            ("Logo", "logoEmphasized", 0, logoEmphasized ? 1.0 : 0.0),
            ("Logo", "logoForceDarkAppearance", 1.0, logoForceDarkAppearance ? 1.0 : 0.0),
            ("Logo", "logoSwiftUIBlendMode", 3.0, Double(logoSwiftUIBlendMode)),
            // Status Colors - Ready
            ("Status Ready", "statusReadyHue", 0.369, statusReadyHue),
            ("Status Ready", "statusReadySaturation", 0.70, statusReadySaturation),
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
            ("Ready Ripple", "rippleSpeed", 7.13, rippleSpeed),
            ("Ready Ripple", "rippleCount", 3, Double(rippleCount)),
            ("Ready Ripple", "rippleMaxOpacity", 1.00, rippleMaxOpacity),
            ("Ready Ripple", "rippleLineWidth", 60.00, rippleLineWidth),
            ("Ready Ripple", "rippleBlurAmount", 35.73, rippleBlurAmount),
            ("Ready Ripple", "rippleOriginX", 0.05, rippleOriginX),
            ("Ready Ripple", "rippleOriginY", 0.00, rippleOriginY),
            ("Ready Ripple", "rippleFadeInZone", 0.20, rippleFadeInZone),
            ("Ready Ripple", "rippleFadeOutPower", 2.37, rippleFadeOutPower),
            // Border Glow
            ("Border Glow", "borderGlowInnerWidth", 2.00, borderGlowInnerWidth),
            ("Border Glow", "borderGlowOuterWidth", 1.73, borderGlowOuterWidth),
            ("Border Glow", "borderGlowInnerBlur", 3.01, borderGlowInnerBlur),
            ("Border Glow", "borderGlowOuterBlur", 0.00, borderGlowOuterBlur),
            ("Border Glow", "borderGlowBaseOpacity", 0.74, borderGlowBaseOpacity),
            ("Border Glow", "borderGlowPulseIntensity", 1.00, borderGlowPulseIntensity),
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
            // Working Stripes
            ("Working Stripes", "workingStripeWidth", 24.0, workingStripeWidth),
            ("Working Stripes", "workingStripeSpacing", 44.91, workingStripeSpacing),
            ("Working Stripes", "workingStripeAngle", 38.02, workingStripeAngle),
            ("Working Stripes", "workingScrollSpeed", 3.68, workingScrollSpeed),
            ("Working Stripes", "workingStripeOpacity", 0.83, workingStripeOpacity),
            ("Working Stripes", "workingGlowIntensity", 3.00, workingGlowIntensity),
            ("Working Stripes", "workingGlowBlurRadius", 30.00, workingGlowBlurRadius),
            ("Working Stripes", "workingCoreBrightness", 0.56, workingCoreBrightness),
            ("Working Stripes", "workingGradientFalloff", 0.39, workingGradientFalloff),
            ("Working Stripes", "workingVignetteInnerRadius", 0.03, workingVignetteInnerRadius),
            ("Working Stripes", "workingVignetteOuterRadius", 0.00, workingVignetteOuterRadius),
            ("Working Stripes", "workingVignetteCenterOpacity", 0.05, workingVignetteCenterOpacity),
            ("Working Stripes", "workingVignetteColorHue", 0.06, workingVignetteColorHue),
            ("Working Stripes", "workingVignetteColorSaturation", 0.92, workingVignetteColorSaturation),
            ("Working Stripes", "workingVignetteColorBrightness", 0.33, workingVignetteColorBrightness),
            ("Working Stripes", "workingVignetteColorIntensity", 0.60, workingVignetteColorIntensity),
            // Working Border
            ("Working Border", "workingBorderWidth", 2.05, workingBorderWidth),
            ("Working Border", "workingBorderBaseOpacity", 0.34, workingBorderBaseOpacity),
            ("Working Border", "workingBorderPulseIntensity", 0.50, workingBorderPulseIntensity),
            ("Working Border", "workingBorderPulseSpeed", 2.21, workingBorderPulseSpeed),
            ("Working Border", "workingBorderBlurAmount", 8.0, workingBorderBlurAmount),
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
            // Empty State Glow
            ("Empty Glow", "emptyGlowSpeed", 3.21, emptyGlowSpeed),
            ("Empty Glow", "emptyGlowPulseCount", 4, Double(emptyGlowPulseCount)),
            ("Empty Glow", "emptyGlowBaseOpacity", 0.09, emptyGlowBaseOpacity),
            ("Empty Glow", "emptyGlowPulseRange", 0.59, emptyGlowPulseRange),
            ("Empty Glow", "emptyGlowInnerWidth", 0.91, emptyGlowInnerWidth),
            ("Empty Glow", "emptyGlowOuterWidth", 1.21, emptyGlowOuterWidth),
            ("Empty Glow", "emptyGlowInnerBlur", 0.27, emptyGlowInnerBlur),
            ("Empty Glow", "emptyGlowOuterBlur", 4.19, emptyGlowOuterBlur),
            ("Empty Glow", "emptyGlowFadeInZone", 0.15, emptyGlowFadeInZone),
            ("Empty Glow", "emptyGlowFadeOutPower", 1.0, emptyGlowFadeOutPower),
            // Card Interaction (tuned defaults)
            ("Card Idle", "cardIdleScale", 1.0, cardIdleScale),
            ("Card Idle", "cardIdleShadowOpacity", 0.17, cardIdleShadowOpacity),
            ("Card Idle", "cardIdleShadowRadius", 8.07, cardIdleShadowRadius),
            ("Card Idle", "cardIdleShadowY", 3.89, cardIdleShadowY),
            ("Card Hover", "cardHoverScale", 1.01, cardHoverScale),
            ("Card Hover", "cardHoverSpringResponse", 0.16, cardHoverSpringResponse),
            ("Card Hover", "cardHoverSpringDamping", 0.68, cardHoverSpringDamping),
            ("Card Hover", "cardHoverShadowOpacity", 0.2, cardHoverShadowOpacity),
            ("Card Hover", "cardHoverShadowRadius", 12.0, cardHoverShadowRadius),
            ("Card Hover", "cardHoverShadowY", 4.0, cardHoverShadowY),
            ("Card Pressed", "cardPressedScale", 1.00, cardPressedScale),
            ("Card Pressed", "cardPressedSpringResponse", 0.09, cardPressedSpringResponse),
            ("Card Pressed", "cardPressedSpringDamping", 0.34, cardPressedSpringDamping),
            ("Card Pressed", "cardPressedShadowOpacity", 0.12, cardPressedShadowOpacity),
            ("Card Pressed", "cardPressedShadowRadius", 2.0, cardPressedShadowRadius),
            ("Card Pressed", "cardPressedShadowY", 1.0, cardPressedShadowY),
            ("Card Pressed", "cardPressTiltHorizontal", 1.86, cardPressTiltHorizontal),
            ("Card Pressed", "cardPressTiltVertical", 5.87, cardPressTiltVertical),
            ("Card Pressed", "cardPressRippleOpacity", 1.70, cardPressRippleOpacity),
            ("Card Pressed", "cardPressDistortion", 0.0, cardPressDistortion),
            // Metal Highlight
            ("Metal Highlight", "highlightRingFrequency", 1.00, highlightRingFrequency),
            ("Metal Highlight", "highlightRingSharpness", 1.13, highlightRingSharpness),
            ("Metal Highlight", "highlightFalloff", 0.10, highlightFalloff),
            ("Metal Highlight", "highlightSpecularTightness", 8.60, highlightSpecularTightness),
            ("Metal Highlight", "highlightSpecularWeight", 1.33, highlightSpecularWeight),
            ("Metal Highlight", "highlightRingWeight", 0.84, highlightRingWeight),
            ("Metal Highlight", "highlightRippleSpeed", 9.06, highlightRippleSpeed),
            ("Metal Highlight", "highlightRippleDuration", 0.63, highlightRippleDuration),
            ("Metal Highlight", "highlightBlendMode", 3, Double(highlightBlendMode)),
            ("Metal Highlight", "highlightUseVibrancy", 0.0, highlightUseVibrancy ? 1.0 : 0.0),
            ("Metal Highlight", "highlightVibrancyMaterial", 4, Double(highlightVibrancyMaterial)),
            // Press Distortion
            ("Press Distortion", "distortionMaxSkew", 0.0, distortionMaxSkew),
            ("Press Distortion", "distortionScaleInset", 0.0, distortionScaleInset),
            ("Press Distortion", "distortionDirectionalScale", 0.0, distortionDirectionalScale),
            ("Press Distortion", "distortionAnchorOffset", 0.07, distortionAnchorOffset),
            // State Transitions
            ("State Transitions", "stateTransitionDuration", 0.35, stateTransitionDuration),
            ("State Transitions", "glowFadeDuration", 0.5, glowFadeDuration),
            ("State Transitions", "glowBorderDelay", 0.08, glowBorderDelay),
            ("State Transitions", "hoverTransitionDuration", 0.12, hoverTransitionDuration),
            ("State Transitions", "cardInsertStagger", 0.04, cardInsertStagger),
            ("State Transitions", "cardRemovalDuration", 0.15, cardRemovalDuration),
            ("State Transitions", "cardInsertSpringResponse", 0.25, cardInsertSpringResponse),
            ("State Transitions", "cardInsertSpringDamping", 0.8, cardInsertSpringDamping),
            ("State Transitions", "pausedCardStagger", 0.025, pausedCardStagger),
            ("State Transitions", "sectionToggleSpringResponse", 0.18, sectionToggleSpringResponse),
            // Layout - List
            ("Layout List", "cardListSpacing", 4.98, cardListSpacing),
            ("Layout List", "cardPaddingHorizontal", 15.07, cardPaddingHorizontal),
            ("Layout List", "cardPaddingVertical", 11.40, cardPaddingVertical),
            ("Layout List", "listHorizontalPadding", 11.60, listHorizontalPadding),
            // Layout - Dock
            ("Layout Dock", "dockCardSpacing", 12.41, dockCardSpacing),
            ("Layout Dock", "dockCardPaddingHorizontal", 14.85, dockCardPaddingHorizontal),
            ("Layout Dock", "dockCardPaddingVertical", 13.79, dockCardPaddingVertical),
            ("Layout Dock", "dockHorizontalPadding", 10.25, dockHorizontalPadding),
            ("Layout Dock", "dockCardWidth", 231.03, dockCardWidth),
            ("Layout Dock", "dockCardMinHeight", 43.20, dockCardMinHeight),
            ("Layout Dock", "dockCardMaxHeight", 141.23, dockCardMaxHeight),
            ("Layout Dock", "dockCardCornerRadius", 8.61, dockCardCornerRadius),
            ("Layout Dock", "dockVerticalPadding", 9.80, dockVerticalPadding),
            ("Layout Dock", "dockWindowMinHeight", 110.50, dockWindowMinHeight),
            ("Layout Dock", "dockWindowMaxHeight", 187.25, dockWindowMaxHeight),
            ("Layout Dock", "dockPageIndicatorSpacing", 8.0, dockPageIndicatorSpacing),
            ("Layout Dock", "dockCardContentSpacing", 10.0, dockCardContentSpacing),
            ("Layout Dock", "dockChipTopPadding", 4.0, dockChipTopPadding),
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
