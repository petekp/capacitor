import SwiftUI

#if DEBUG

// MARK: - Logo Letterpress

struct LogoLetterpressSection: View {
    @ObservedObject var config: GlassConfig

    var body: some View {
        Group(content: {
            StickySection(title: "Typography", onReset: resetTypography) {
                HStack {
                    Text("Preview:")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    CapacitorLogo()
                    Spacer()
                }
                .padding(.bottom, 4)

                TuningRow(label: "Font Size", value: $config.logoFontSize, range: 8...24)
                TuningRow(label: "Tracking", value: $config.logoTracking, range: 0...5)
                TuningRow(label: "Base Opacity", value: $config.logoBaseOpacity, range: 0...1)
            }

            StickySection(title: "Inner Shadow", onReset: resetShadow) {
                TuningRow(label: "Opacity", value: $config.logoShadowOpacity, range: 0...1)
                TuningRow(label: "Offset X", value: $config.logoShadowOffsetX, range: -3...3)
                TuningRow(label: "Offset Y", value: $config.logoShadowOffsetY, range: -3...3)
                TuningRow(label: "Blur", value: $config.logoShadowBlur, range: 0...4)

                TuningBlendModeRow(
                    label: "Blend Mode",
                    selection: $config.logoShadowBlendMode,
                    options: BlendModeOption.shadowModes
                )
            }

            StickySection(title: "Inner Highlight", onReset: resetHighlight) {
                TuningRow(label: "Opacity", value: $config.logoHighlightOpacity, range: 0...1)
                TuningRow(label: "Offset X", value: $config.logoHighlightOffsetX, range: -3...3)
                TuningRow(label: "Offset Y", value: $config.logoHighlightOffsetY, range: -3...3)
                TuningRow(label: "Blur", value: $config.logoHighlightBlur, range: 0...4)

                TuningBlendModeRow(
                    label: "Blend Mode",
                    selection: $config.logoHighlightBlendMode,
                    options: BlendModeOption.highlightModes
                )
            }
        })
    }

    private func resetTypography() {
        config.logoFontSize = 14.55
        config.logoTracking = 2.61
        config.logoBaseOpacity = 0.9
    }

    private func resetShadow() {
        config.logoShadowOpacity = 0.01
        config.logoShadowOffsetX = -2.96
        config.logoShadowOffsetY = -2.93
        config.logoShadowBlur = 0.04
        config.logoShadowBlendMode = .colorBurn
    }

    private func resetHighlight() {
        config.logoHighlightOpacity = 0.01
        config.logoHighlightOffsetX = -2.95
        config.logoHighlightOffsetY = -2.95
        config.logoHighlightBlur = 0.0
        config.logoHighlightBlendMode = .softLight
    }
}

// MARK: - Logo Glass Shader

struct LogoMetalShaderSection: View {
    @ObservedObject var config: GlassConfig
    @State private var animationTime: Double = 0
    private let timer = Timer.publish(every: 1/60, on: .main, in: .common).autoconnect()

    private var metalStatus: (loaded: Bool, message: String) {
        if MetalShaders.library != nil {
            return (true, "Metal shader loaded")
        } else {
            return (false, "Using SwiftUI fallback")
        }
    }

    init(config: GlassConfig) {
        self.config = config
        MetalShaders.initialize()
    }

    var body: some View {
        Group {
            StickySection(title: "Preview", onReset: nil) {
                VStack(alignment: .leading, spacing: 8) {
                    GlassShaderLogoPreview(config: config, time: animationTime)
                        .frame(height: 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onReceive(timer) { _ in
                            if config.logoShaderEnabled {
                                animationTime += 1/60
                            }
                        }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(metalStatus.loaded ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(metalStatus.message)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    TuningToggleRow(label: "Enable Shader", isOn: $config.logoShaderEnabled)
                    TuningToggleRow(label: "Mask to Text", isOn: $config.logoShaderMaskToText)
                }
            }

            StickySection(title: "Fresnel & Edges", onReset: resetFresnel) {
                TuningRow(label: "Fresnel Power", value: $config.logoGlassFresnelPower, range: 0.5...5.0)
                TuningRow(label: "Fresnel Intensity", value: $config.logoGlassFresnelIntensity, range: 0...2.0)
                TuningRow(label: "Chromatic Aberration", value: $config.logoGlassChromaticAmount, range: 0...2.0)
            }

            StickySection(title: "Caustics", onReset: resetCaustics) {
                TuningRow(label: "Scale", value: $config.logoGlassCausticScale, range: 1.0...10.0)
                TuningRow(label: "Speed", value: $config.logoGlassCausticSpeed, range: 0.1...3.0)
                TuningRow(label: "Intensity", value: $config.logoGlassCausticIntensity, range: 0...1.0)
                TuningRow(label: "Angle", value: $config.logoGlassCausticAngle, range: 0...360, format: "%.0f°")
            }

            StickySection(title: "Specular Highlight", onReset: resetHighlight) {
                TuningRow(label: "Sharpness", value: $config.logoGlassHighlightSharpness, range: 1.0...8.0)
                TuningRow(label: "Angle", value: $config.logoGlassHighlightAngle, range: 0...360, format: "%.0f°")
            }

            StickySection(title: "Glass Properties", onReset: resetGlass) {
                TuningRow(label: "Clarity", value: $config.logoGlassClarity, range: 0.2...1.0)
                TuningRow(label: "Internal Reflection", value: $config.logoGlassInternalReflection, range: 0...1.0)
                TuningRow(label: "Internal Angle", value: $config.logoGlassInternalAngle, range: 0...360, format: "%.0f°")
            }

            StickySection(title: "Prismatic Effect", onReset: resetPrismatic) {
                TuningToggleRow(label: "Enable Prismatic", isOn: $config.logoGlassPrismaticEnabled)
                TuningRow(label: "Prism Amount", value: $config.logoGlassPrismAmount, range: 0...1.0)
            }

            StickySection(title: "Compositing", onReset: resetCompositing) {
                TuningRow(label: "Opacity", value: $config.logoShaderOpacity, range: 0...1.0)

                TuningBlendModeRow(
                    label: "Blend Mode",
                    selection: $config.logoShaderBlendMode,
                    options: BlendModeOption.compositingModes
                )

                SectionDivider()

                TuningToggleRow(label: "Enable Vibrancy", isOn: $config.logoShaderVibrancyEnabled)
                TuningRow(label: "Vibrancy Blur", value: $config.logoShaderVibrancyBlur, range: 0...20)
            }
        }
    }

    private func resetFresnel() {
        config.logoGlassFresnelPower = 4.02
        config.logoGlassFresnelIntensity = 1.88
        config.logoGlassChromaticAmount = 1.32
    }

    private func resetCaustics() {
        config.logoGlassCausticScale = 1.24
        config.logoGlassCausticSpeed = 1.30
        config.logoGlassCausticIntensity = 0.99
        config.logoGlassCausticAngle = 81.31
    }

    private func resetHighlight() {
        config.logoGlassHighlightSharpness = 7.91
        config.logoGlassHighlightAngle = 355.43
    }

    private func resetGlass() {
        config.logoGlassClarity = 0.34
        config.logoGlassInternalReflection = 0.44
        config.logoGlassInternalAngle = 75.18
    }

    private func resetPrismatic() {
        config.logoGlassPrismaticEnabled = true
        config.logoGlassPrismAmount = 0.12
    }

    private func resetCompositing() {
        config.logoShaderOpacity = 0.63
        config.logoShaderBlendMode = .overlay
        config.logoShaderVibrancyEnabled = true
        config.logoShaderVibrancyBlur = 0.03
    }
}

struct GlassShaderLogoPreview: View {
    @ObservedObject var config: GlassConfig
    let time: Double

    private let logoText = "CAPACITOR"

    var body: some View {
        let baseView = Text(logoText)
            .font(.system(size: 13, weight: .black, design: .monospaced))
            .tracking(0.5)
            .foregroundColor(.white)

        if config.logoShaderEnabled {
            let shaderContent: some View = Group {
                if config.logoShaderMaskToText {
                    GlassShaderView(config: config, time: time)
                        .mask(baseView)
                } else {
                    baseView
                        .background {
                            GlassShaderView(config: config, time: time)
                        }
                }
            }

            shaderContent
                .opacity(config.logoShaderOpacity)
                .blendMode(config.logoShaderBlendMode)
        } else {
            baseView.opacity(0.5)
        }
    }
}

// MARK: - Card Appearance

struct CardAppearanceSection: View {
    @ObservedObject var config: GlassConfig

    var body: some View {
        Group(content: {
            StickySection(title: "Background", onReset: resetBackground) {
                TuningRow(label: "Tint Opacity", value: $config.cardTintOpacity, range: 0...1)
                TuningRow(label: "Corner Radius", value: $config.cardCornerRadius, range: 4...24)
            }

            StickySection(title: "Border & Highlight", onReset: resetBorder) {
                TuningRow(label: "Border Opacity", value: $config.cardBorderOpacity, range: 0...1)
                TuningRow(label: "Highlight Opacity", value: $config.cardHighlightOpacity, range: 0...0.5)

                SectionDivider()

                Text("Hover State")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Hover Border", value: $config.cardHoverBorderOpacity, range: 0...1)
                TuningRow(label: "Hover Highlight", value: $config.cardHoverHighlightOpacity, range: 0...0.5)
            }
        })
    }

    private func resetBackground() {
        config.cardTintOpacity = 0.58
        config.cardCornerRadius = 13
    }

    private func resetBorder() {
        config.cardBorderOpacity = 0.28
        config.cardHighlightOpacity = 0.14
        config.cardHoverBorderOpacity = 0.37
        config.cardHoverHighlightOpacity = 0.16
    }
}

// MARK: - Card Interactions

struct CardInteractionsSection: View {
    @ObservedObject var config: GlassConfig

    var body: some View {
        Group(content: {
            StickySection(title: "Idle State", onReset: resetIdle) {
                TuningRow(label: "Scale", value: $config.cardIdleScale, range: 0.9...1.1)
                TuningRow(label: "Shadow Opacity", value: $config.cardIdleShadowOpacity, range: 0...0.5)
                TuningRow(label: "Shadow Radius", value: $config.cardIdleShadowRadius, range: 0...20)
                TuningRow(label: "Shadow Y", value: $config.cardIdleShadowY, range: 0...10)
            }

            StickySection(title: "Hover State", onReset: resetHover) {
                TuningRow(label: "Scale", value: $config.cardHoverScale, range: 0.9...1.1)

                SectionDivider()

                Text("Spring Animation")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Response", value: $config.cardHoverSpringResponse, range: 0.05...0.5)
                TuningRow(label: "Damping", value: $config.cardHoverSpringDamping, range: 0.3...1.0)

                SectionDivider()

                Text("Shadow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Shadow Opacity", value: $config.cardHoverShadowOpacity, range: 0...0.5)
                TuningRow(label: "Shadow Radius", value: $config.cardHoverShadowRadius, range: 0...30)
                TuningRow(label: "Shadow Y", value: $config.cardHoverShadowY, range: 0...15)
            }

            StickySection(title: "Pressed State", onReset: resetPressed) {
                TuningRow(label: "Scale", value: $config.cardPressedScale, range: 0.85...1.0)

                SectionDivider()

                Text("Spring Animation")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Response", value: $config.cardPressedSpringResponse, range: 0.05...0.3)
                TuningRow(label: "Damping", value: $config.cardPressedSpringDamping, range: 0.3...1.0)

                SectionDivider()

                Text("Shadow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Shadow Opacity", value: $config.cardPressedShadowOpacity, range: 0...0.3)
                TuningRow(label: "Shadow Radius", value: $config.cardPressedShadowRadius, range: 0...10)
                TuningRow(label: "Shadow Y", value: $config.cardPressedShadowY, range: 0...5)
            }
        })
    }

    private func resetIdle() {
        config.cardIdleScale = 1.0
        config.cardIdleShadowOpacity = 0.17
        config.cardIdleShadowRadius = 8.07
        config.cardIdleShadowY = 3.89
    }

    private func resetHover() {
        config.cardHoverScale = 1.01
        config.cardHoverSpringResponse = 0.26
        config.cardHoverSpringDamping = 0.90
        config.cardHoverShadowOpacity = 0.2
        config.cardHoverShadowRadius = 12.0
        config.cardHoverShadowY = 4.0
    }

    private func resetPressed() {
        config.cardPressedScale = 1.00
        config.cardPressedSpringResponse = 0.06
        config.cardPressedSpringDamping = 0.48
        config.cardPressedShadowOpacity = 0.12
        config.cardPressedShadowRadius = 2.0
        config.cardPressedShadowY = 1.0
    }
}

// MARK: - Card State Effects

struct CardStateEffectsSection: View {
    @ObservedObject var config: GlassConfig

    @ViewBuilder
    var body: some View {
        StickySection(title: "Ready — Ripple", onReset: resetReady) {
                TuningRow(label: "Speed", value: $config.rippleSpeed, range: 1...10)
                TuningRow(label: "Count", value: .init(get: { Double(config.rippleCount) }, set: { config.rippleCount = Int($0) }), range: 1...8, format: "%.0f")
                TuningRow(label: "Max Opacity", value: $config.rippleMaxOpacity, range: 0...1)
                TuningRow(label: "Line Width", value: $config.rippleLineWidth, range: 5...60)
                TuningRow(label: "Blur Amount", value: $config.rippleBlurAmount, range: 0...60)
                TuningRow(label: "Origin X", value: $config.rippleOriginX, range: 0...1)
                TuningRow(label: "Origin Y", value: $config.rippleOriginY, range: 0...1)
                TuningRow(label: "Fade In Zone", value: $config.rippleFadeInZone, range: 0...0.5)
                TuningRow(label: "Fade Out Power", value: $config.rippleFadeOutPower, range: 1...10)

                SectionDivider()

                Text("Border Glow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Inner Width", value: $config.borderGlowInnerWidth, range: 0.1...2)
                TuningRow(label: "Outer Width", value: $config.borderGlowOuterWidth, range: 0.5...6)
                TuningRow(label: "Inner Blur", value: $config.borderGlowInnerBlur, range: 0...4)
                TuningRow(label: "Outer Blur", value: $config.borderGlowOuterBlur, range: 0...8)
                TuningRow(label: "Base Opacity", value: $config.borderGlowBaseOpacity, range: 0...1)
                TuningRow(label: "Pulse Intensity", value: $config.borderGlowPulseIntensity, range: 0...1)
            }

            StickySection(title: "Working — Stripes", onReset: resetWorkingStripes) {
                TuningRow(label: "Stripe Width", value: $config.workingStripeWidth, range: 8...48)
                TuningRow(label: "Stripe Spacing", value: $config.workingStripeSpacing, range: 12...80)
                TuningRow(label: "Stripe Angle", value: $config.workingStripeAngle, range: 20...70)
                TuningRow(label: "Scroll Speed", value: $config.workingScrollSpeed, range: 1...10)
                TuningRow(label: "Stripe Opacity", value: $config.workingStripeOpacity, range: 0...1)

                SectionDivider()

                Text("Emissive Glow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Glow Intensity", value: $config.workingGlowIntensity, range: 0...3)
                TuningRow(label: "Glow Blur", value: $config.workingGlowBlurRadius, range: 0...30)
                TuningRow(label: "Core Brightness", value: $config.workingCoreBrightness, range: 0...2)
                TuningRow(label: "Gradient Falloff", value: $config.workingGradientFalloff, range: 0...1)

                SectionDivider()

                Text("Vignette")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Inner Radius", value: $config.workingVignetteInnerRadius, range: 0...0.8)
                TuningRow(label: "Outer Radius", value: $config.workingVignetteOuterRadius, range: 0...2)
                TuningRow(label: "Center Opacity", value: $config.workingVignetteCenterOpacity, range: 0...0.5)

                SectionDivider()

                Text("Vignette Color")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                HStack {
                    Circle()
                        .fill(Color(hue: config.workingVignetteColorHue, saturation: config.workingVignetteColorSaturation, brightness: config.workingVignetteColorBrightness))
                        .frame(width: 14, height: 14)
                        .shadow(color: Color(hue: config.workingVignetteColorHue, saturation: config.workingVignetteColorSaturation, brightness: config.workingVignetteColorBrightness).opacity(0.5), radius: 4)
                    Spacer()
                }

                TuningRow(label: "Hue", value: $config.workingVignetteColorHue, range: 0...1)
                TuningRow(label: "Saturation", value: $config.workingVignetteColorSaturation, range: 0...1)
                TuningRow(label: "Brightness", value: $config.workingVignetteColorBrightness, range: 0...1)
                TuningRow(label: "Intensity", value: $config.workingVignetteColorIntensity, range: 0...1)
            }

            StickySection(title: "Working — Border", onReset: resetWorkingBorder) {
                TuningRow(label: "Border Width", value: $config.workingBorderWidth, range: 0.5...4)
                TuningRow(label: "Base Opacity", value: $config.workingBorderBaseOpacity, range: 0...0.6)
                TuningRow(label: "Pulse Intensity", value: $config.workingBorderPulseIntensity, range: 0...0.5)
                TuningRow(label: "Pulse Speed", value: $config.workingBorderPulseSpeed, range: 0.5...5)
                TuningRow(label: "Blur Amount", value: $config.workingBorderBlurAmount, range: 0...12)
            }

            StickySection(title: "Waiting — Pulse", onReset: resetWaiting) {
                TuningRow(label: "Cycle Length", value: $config.waitingCycleLength, range: 1...5)
                TuningRow(label: "1st Pulse Duration", value: $config.waitingFirstPulseDuration, range: 0.05...0.5)
                TuningRow(label: "1st Pulse Fade", value: $config.waitingFirstPulseFadeOut, range: 0.1...0.6)
                TuningRow(label: "2nd Pulse Delay", value: $config.waitingSecondPulseDelay, range: 0...0.5)
                TuningRow(label: "2nd Pulse Duration", value: $config.waitingSecondPulseDuration, range: 0.05...0.5)
                TuningRow(label: "2nd Pulse Fade", value: $config.waitingSecondPulseFadeOut, range: 0.1...0.6)
                TuningRow(label: "1st Pulse Intensity", value: $config.waitingFirstPulseIntensity, range: 0...1)
                TuningRow(label: "2nd Pulse Intensity", value: $config.waitingSecondPulseIntensity, range: 0...1)
                TuningRow(label: "Max Opacity", value: $config.waitingMaxOpacity, range: 0...1)
                TuningRow(label: "Blur Amount", value: $config.waitingBlurAmount, range: 0...60)
                TuningRow(label: "Pulse Scale", value: $config.waitingPulseScale, range: 1...3)
                TuningRow(label: "Scale Amount", value: $config.waitingScaleAmount, range: 0...1)
                TuningRow(label: "Origin X", value: $config.waitingOriginX, range: 0...1)
                TuningRow(label: "Origin Y", value: $config.waitingOriginY, range: 0...1)
            }

            StickySection(title: "Waiting — Border", onReset: resetWaitingBorder) {
                TuningRow(label: "Base Opacity", value: $config.waitingBorderBaseOpacity, range: 0...0.5)
                TuningRow(label: "Pulse Opacity", value: $config.waitingBorderPulseOpacity, range: 0...1)
                TuningRow(label: "Inner Width", value: $config.waitingBorderInnerWidth, range: 0.5...4)
                TuningRow(label: "Outer Width", value: $config.waitingBorderOuterWidth, range: 1...8)
                TuningRow(label: "Outer Blur", value: $config.waitingBorderOuterBlur, range: 0...12)
            }
    }

    private func resetReady() {
        config.rippleSpeed = 4.9
        config.rippleCount = 4
        config.rippleMaxOpacity = 1.00
        config.rippleLineWidth = 30.0
        config.rippleBlurAmount = 41.5
        config.rippleOriginX = 0.89
        config.rippleOriginY = 0.00
        config.rippleFadeInZone = 0.10
        config.rippleFadeOutPower = 4.0
        config.borderGlowInnerWidth = 0.49
        config.borderGlowOuterWidth = 2.88
        config.borderGlowInnerBlur = 0.5
        config.borderGlowOuterBlur = 1.5
        config.borderGlowBaseOpacity = 0.30
        config.borderGlowPulseIntensity = 0.50
    }

    private func resetWorkingStripes() {
        config.workingStripeWidth = 24.0
        config.workingStripeSpacing = 38.49
        config.workingStripeAngle = 41.30
        config.workingScrollSpeed = 4.81
        config.workingStripeOpacity = 0.50
        config.workingGlowIntensity = 1.50
        config.workingGlowBlurRadius = 11.46
        config.workingCoreBrightness = 0.71
        config.workingGradientFalloff = 0.32
        config.workingVignetteInnerRadius = 0.02
        config.workingVignetteOuterRadius = 0.48
        config.workingVignetteCenterOpacity = 0.03
        config.workingVignetteColorHue = 0.05
        config.workingVignetteColorSaturation = 0.67
        config.workingVignetteColorBrightness = 0.39
        config.workingVignetteColorIntensity = 0.47
    }

    private func resetWorkingBorder() {
        config.workingBorderWidth = 1.0
        config.workingBorderBaseOpacity = 0.35
        config.workingBorderPulseIntensity = 0.50
        config.workingBorderPulseSpeed = 2.21
        config.workingBorderBlurAmount = 8.0
    }

    private func resetWaiting() {
        config.waitingCycleLength = 1.68
        config.waitingFirstPulseDuration = 0.17
        config.waitingFirstPulseFadeOut = 0.17
        config.waitingSecondPulseDelay = 0.00
        config.waitingSecondPulseDuration = 0.17
        config.waitingSecondPulseFadeOut = 0.48
        config.waitingFirstPulseIntensity = 0.34
        config.waitingSecondPulseIntensity = 0.47
        config.waitingMaxOpacity = 0.34
        config.waitingBlurAmount = 0.0
        config.waitingPulseScale = 2.22
        config.waitingScaleAmount = 0.30
        config.waitingOriginX = 1.00
        config.waitingOriginY = 0.00
    }

    private func resetWaitingBorder() {
        config.waitingBorderBaseOpacity = 0.12
        config.waitingBorderPulseOpacity = 0.37
        config.waitingBorderInnerWidth = 0.50
        config.waitingBorderOuterWidth = 1.86
        config.waitingBorderOuterBlur = 0.8
    }
}

// MARK: - Panel Background

struct PanelBackgroundSection: View {
    @ObservedObject var config: GlassConfig

    var body: some View {
        Group(content: {
            StickySection(title: "Panel Glass", onReset: resetPanel) {
                TuningRow(label: "Tint Opacity", value: $config.panelTintOpacity, range: 0...1)
                TuningRow(label: "Corner Radius", value: $config.panelCornerRadius, range: 8...32)
                TuningRow(label: "Border Opacity", value: $config.panelBorderOpacity, range: 0...1)
                TuningRow(label: "Highlight Opacity", value: $config.panelHighlightOpacity, range: 0...0.3)
                TuningRow(label: "Top Highlight", value: $config.panelTopHighlightOpacity, range: 0...0.5)

                SectionDivider()

                Text("Shadow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                TuningRow(label: "Shadow Opacity", value: $config.panelShadowOpacity, range: 0...0.5)
                TuningRow(label: "Shadow Radius", value: $config.panelShadowRadius, range: 0...30)
                TuningRow(label: "Shadow Y", value: $config.panelShadowY, range: 0...15)
            }
        })
    }

    private func resetPanel() {
        config.panelTintOpacity = 0.33
        config.panelCornerRadius = 22
        config.panelBorderOpacity = 0.36
        config.panelHighlightOpacity = 0.07
        config.panelTopHighlightOpacity = 0.14
        config.panelShadowOpacity = 0.00
        config.panelShadowRadius = 0
        config.panelShadowY = 0
    }
}

// MARK: - Panel Material

struct PanelMaterialSection: View {
    @ObservedObject var config: GlassConfig

    var body: some View {
        Group(content: {
            StickySection(title: "Material Settings", onReset: resetMaterial) {
                TuningToggleRow(label: "Emphasized Material", isOn: $config.useEmphasizedMaterial)

                TuningPickerRow(
                    label: "Material Type",
                    selection: $config.materialType,
                    options: [
                        ("HUD Window", 0),
                        ("Popover", 1),
                        ("Menu", 2),
                        ("Sidebar", 3),
                        ("Full Screen UI", 4)
                    ]
                )
            }
        })
    }

    private func resetMaterial() {
        config.useEmphasizedMaterial = true
        config.materialType = 0
    }
}

// MARK: - Status Colors

struct StatusColorsSection: View {
    @ObservedObject var config: GlassConfig

    var body: some View {
        Group(content: {
            StickySection(title: "Ready", onReset: resetReady) {
                TuningColorRow(
                    label: "Ready Color",
                    hue: $config.statusReadyHue,
                    saturation: $config.statusReadySaturation,
                    brightness: $config.statusReadyBrightness
                )
            }

            StickySection(title: "Working", onReset: resetWorking) {
                TuningColorRow(
                    label: "Working Color",
                    hue: $config.statusWorkingHue,
                    saturation: $config.statusWorkingSaturation,
                    brightness: $config.statusWorkingBrightness
                )
            }

            StickySection(title: "Waiting", onReset: resetWaiting) {
                TuningColorRow(
                    label: "Waiting Color",
                    hue: $config.statusWaitingHue,
                    saturation: $config.statusWaitingSaturation,
                    brightness: $config.statusWaitingBrightness
                )
            }

            StickySection(title: "Compacting", onReset: resetCompacting) {
                TuningColorRow(
                    label: "Compacting Color",
                    hue: $config.statusCompactingHue,
                    saturation: $config.statusCompactingSaturation,
                    brightness: $config.statusCompactingBrightness
                )
            }

            StickySection(title: "Idle", onReset: resetIdle) {
                TuningRow(label: "Opacity", value: $config.statusIdleOpacity, range: 0...1)
            }
        })
    }

    private func resetReady() {
        config.statusReadyHue = 0.406
        config.statusReadySaturation = 0.83
        config.statusReadyBrightness = 1.00
    }

    private func resetWorking() {
        config.statusWorkingHue = 0.103
        config.statusWorkingSaturation = 1.00
        config.statusWorkingBrightness = 1.00
    }

    private func resetWaiting() {
        config.statusWaitingHue = 0.026
        config.statusWaitingSaturation = 0.58
        config.statusWaitingBrightness = 1.00
    }

    private func resetCompacting() {
        config.statusCompactingHue = 0.670
        config.statusCompactingSaturation = 0.50
        config.statusCompactingBrightness = 1.00
    }

    private func resetIdle() {
        config.statusIdleOpacity = 0.40
    }
}

#endif
