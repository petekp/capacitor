import SwiftUI

struct ReadyAmbientGlow: View {
    var layoutMode: LayoutMode = .vertical
    @Environment(\.prefersReducedMotion) private var reduceMotion
    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    var body: some View {
        if reduceMotion {
            staticGlow
        } else {
            animatedGlow
        }
    }

    private var staticGlow: some View {
        GeometryReader { geometry in
            let originX = geometry.size.width * 0.89
            let originY: CGFloat = 0

            Circle()
                .fill(Color.statusReady.opacity(0.15))
                .frame(width: 60, height: 60)
                .blur(radius: 30)
                .position(x: originX, y: originY)
        }
        .allowsHitTesting(false)
    }

    private var animatedGlow: some View {
        TimelineView(.animation) { timeline in
            let params = glowParameters
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: params.speed) / params.speed

            GeometryReader { geometry in
                let originX = geometry.size.width * params.originXPercent
                let originY = geometry.size.height * params.originYPercent
                let maxRadius = max(geometry.size.width, geometry.size.height) * 1.8

                Canvas { context, _ in
                    for i in 0..<params.count {
                        let stagger = Double(i) / Double(params.count)
                        let ringPhase = (phase + stagger).truncatingRemainder(dividingBy: 1.0)
                        let radius = maxRadius * ringPhase

                        let fadeIn = params.fadeInZone > 0 ? smoothstep(min(ringPhase / params.fadeInZone, 1.0)) : 1.0
                        let fadeOut = pow(1.0 - ringPhase, params.fadeOutPower)
                        let opacity = params.maxOpacity * fadeIn * fadeOut

                        let lineWidthFadeIn = params.fadeInZone > 0 ? min(ringPhase / params.fadeInZone, 1.0) : 1.0
                        let effectiveLineWidth = params.lineWidth * smoothstep(lineWidthFadeIn)

                        if radius > 0 && opacity > 0.005 && effectiveLineWidth > 0.1 {
                            let rect = CGRect(
                                x: originX - radius,
                                y: originY - radius,
                                width: radius * 2,
                                height: radius * 2
                            )
                            let path = Circle().path(in: rect)
                            context.stroke(
                                path,
                                with: .color(Color.statusReady.opacity(opacity)),
                                lineWidth: effectiveLineWidth
                            )
                        }
                    }
                }
                .blur(radius: params.blurAmount)
            }
        }
        .allowsHitTesting(false)
    }

    private var glowParameters: GlowParameters {
        #if DEBUG
        GlowParameters(
            speed: config.rippleSpeed(for: layoutMode),
            count: config.rippleCount(for: layoutMode),
            maxOpacity: config.rippleMaxOpacity(for: layoutMode),
            lineWidth: config.rippleLineWidth(for: layoutMode),
            blurAmount: config.rippleBlurAmount(for: layoutMode),
            originXPercent: config.rippleOriginX(for: layoutMode),
            originYPercent: config.rippleOriginY(for: layoutMode),
            fadeInZone: config.rippleFadeInZone(for: layoutMode),
            fadeOutPower: config.rippleFadeOutPower(for: layoutMode)
        )
        #else
        GlowParameters(
            speed: layoutMode == .dock ? 7.2 : 4.9,
            count: layoutMode == .dock ? 6 : 4,
            maxOpacity: layoutMode == .dock ? 0.53 : 1.0,
            lineWidth: 30.0,
            blurAmount: layoutMode == .dock ? 29.3 : 41.5,
            originXPercent: layoutMode == .dock ? 0.20 : 0.89,
            originYPercent: 0.0,
            fadeInZone: layoutMode == .dock ? 0.17 : 0.10,
            fadeOutPower: layoutMode == .dock ? 2.9 : 4.0
        )
        #endif
    }

    private func smoothstep(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return clamped * clamped * (3 - 2 * clamped)
    }
}

struct GlowParameters {
    let speed: Double
    let count: Int
    let maxOpacity: Double
    let lineWidth: Double
    let blurAmount: Double
    let originXPercent: Double
    let originYPercent: Double
    let fadeInZone: Double
    let fadeOutPower: Double
}

struct ReadyBorderGlow: View {
    let seed: String
    var cornerRadius: CGFloat = 12
    var layoutMode: LayoutMode = .vertical
    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    private var timeOffset: Double {
        var hasher = Hasher()
        hasher.combine(seed)
        let hash = abs(hasher.finalize())
        return Double(hash % 10000) / 1000.0
    }

    var body: some View {
        if reduceMotion {
            staticBorderGlow
        } else {
            animatedBorderGlow
        }
    }

    private var staticBorderGlow: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(Color.statusReady.opacity(0.3), lineWidth: 1)
            .allowsHitTesting(false)
    }

    private var animatedBorderGlow: some View {
        TimelineView(.animation) { timeline in
            #if DEBUG
            ReadyBorderGlowContent(date: timeline.date, config: config, timeOffset: timeOffset, cornerRadius: cornerRadius, layoutMode: layoutMode)
            #else
            ReadyBorderGlowContent(date: timeline.date, config: nil, timeOffset: timeOffset, cornerRadius: cornerRadius, layoutMode: layoutMode)
            #endif
        }
        .allowsHitTesting(false)
    }
}

struct ReadyBorderGlowContent: View {
    let date: Date
    let timeOffset: Double
    let cornerRadius: CGFloat
    let layoutMode: LayoutMode

    #if DEBUG
    let config: GlassConfig?

    init(date: Date, config: GlassConfig?, timeOffset: Double, cornerRadius: CGFloat = 12, layoutMode: LayoutMode = .vertical) {
        self.date = date
        self.config = config
        self.timeOffset = timeOffset
        self.cornerRadius = cornerRadius
        self.layoutMode = layoutMode
    }
    #else
    init(date: Date, config: Any?, timeOffset: Double, cornerRadius: CGFloat = 12, layoutMode: LayoutMode = .vertical) {
        self.date = date
        self.timeOffset = timeOffset
        self.cornerRadius = cornerRadius
        self.layoutMode = layoutMode
    }
    #endif

    var body: some View {
        let params = borderGlowParameters
        let time = date.timeIntervalSinceReferenceDate + timeOffset
        let phase = time.truncatingRemainder(dividingBy: params.speed) / params.speed
        let rotationPeriod = params.speed / params.rotationMult
        let rotationAngle = Angle(degrees: time.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod * 360)
        let combinedIntensity = computeIntensity(phase: phase, count: params.count, fadeInZone: params.fadeInZone, fadeOutPower: params.fadeOutPower)
        let baseOpacity = params.baseOp + combinedIntensity * params.pulseIntensity

        return borderGlowStack(
            baseOpacity: baseOpacity,
            rotationAngle: rotationAngle,
            innerWidth: params.innerWidth,
            outerWidth: params.outerWidth,
            innerBlur: params.innerBlur,
            outerBlur: params.outerBlur
        )
    }

    private var borderGlowParameters: BorderGlowParameters {
        #if DEBUG
        if let config = config {
            return BorderGlowParameters(
                speed: config.rippleSpeed(for: layoutMode),
                count: config.rippleCount(for: layoutMode),
                fadeInZone: config.rippleFadeInZone(for: layoutMode),
                fadeOutPower: config.rippleFadeOutPower(for: layoutMode),
                rotationMult: config.borderGlowRotationMultiplier(for: layoutMode),
                baseOp: config.borderGlowBaseOpacity(for: layoutMode),
                pulseIntensity: config.borderGlowPulseIntensity(for: layoutMode),
                innerWidth: config.borderGlowInnerWidth(for: layoutMode),
                outerWidth: config.borderGlowOuterWidth(for: layoutMode),
                innerBlur: config.borderGlowInnerBlur(for: layoutMode),
                outerBlur: config.borderGlowOuterBlur(for: layoutMode)
            )
        }
        #endif
        return BorderGlowParameters(
            speed: layoutMode == .dock ? 7.2 : 4.9,
            count: layoutMode == .dock ? 6 : 4,
            fadeInZone: layoutMode == .dock ? 0.17 : 0.10,
            fadeOutPower: layoutMode == .dock ? 2.9 : 4.0,
            rotationMult: 0.50,
            baseOp: layoutMode == .dock ? 0.48 : 0.30,
            pulseIntensity: layoutMode == .dock ? 0.38 : 0.50,
            innerWidth: layoutMode == .dock ? 1.55 : 0.49,
            outerWidth: layoutMode == .dock ? 1.93 : 2.88,
            innerBlur: layoutMode == .dock ? 0.3 : 0.5,
            outerBlur: layoutMode == .dock ? 3.1 : 1.5
        )
    }

    private func computeIntensity(phase: Double, count: Int, fadeInZone: Double, fadeOutPower: Double) -> Double {
        var maxIntensity: Double = 0
        for i in 0..<count {
            let stagger = Double(i) / Double(count)
            let ringPhase = (phase + stagger).truncatingRemainder(dividingBy: 1.0)
            let fadeIn: Double = fadeInZone > 0 ? min(ringPhase / fadeInZone, 1.0) : 1.0
            let fadeOut = pow(1.0 - ringPhase, fadeOutPower)
            maxIntensity = max(maxIntensity, fadeIn * fadeOut)
        }
        return maxIntensity
    }

    private func borderGlowStack(baseOpacity: Double, rotationAngle: Angle, innerWidth: Double, outerWidth: Double, innerBlur: Double, outerBlur: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.3), location: 0.0),
                            .init(color: Color.statusReady.opacity(baseOpacity), location: 0.15),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.5), location: 0.25),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.2), location: 0.4),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.1), location: 0.5),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.2), location: 0.6),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.5), location: 0.75),
                            .init(color: Color.statusReady.opacity(baseOpacity), location: 0.85),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.3), location: 1.0)
                        ]),
                        center: .center,
                        angle: rotationAngle
                    ),
                    lineWidth: innerWidth
                )
                .blur(radius: innerBlur)

            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.2), location: 0.0),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.8), location: 0.15),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.3), location: 0.25),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.1), location: 0.5),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.3), location: 0.75),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.8), location: 0.85),
                            .init(color: Color.statusReady.opacity(baseOpacity * 0.2), location: 1.0)
                        ]),
                        center: .center,
                        angle: rotationAngle + Angle(degrees: 180)
                    ),
                    lineWidth: outerWidth
                )
                .blur(radius: outerBlur)
        }
        .blendMode(.plusLighter)
    }
}

struct BorderGlowParameters {
    let speed: Double
    let count: Int
    let fadeInZone: Double
    let fadeOutPower: Double
    let rotationMult: Double
    let baseOp: Double
    let pulseIntensity: Double
    let innerWidth: Double
    let outerWidth: Double
    let innerBlur: Double
    let outerBlur: Double
}

// MARK: - Waiting State Effects

/// Double-flash pulse effect for the Waiting state - extends beyond card bounds
struct WaitingAmbientPulse: View {
    var layoutMode: LayoutMode = .vertical
    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    var body: some View {
        if reduceMotion {
            staticGlow
        } else {
            animatedPulse
        }
    }

    private var staticGlow: some View {
        GeometryReader { geometry in
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.statusWaiting.opacity(0.25), Color.statusWaiting.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: max(geometry.size.width, geometry.size.height) * 0.8
                    )
                )
                .frame(width: geometry.size.width * 2, height: geometry.size.height * 2)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private var animatedPulse: some View {
        TimelineView(.animation) { timeline in
            let params = pulseParameters
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: params.cycleLength) / params.cycleLength
            let (intensity, scale) = springPulseValues(phase: phase, params: params)

            GeometryReader { geometry in
                let baseSize = max(geometry.size.width, geometry.size.height) * params.pulseScale
                let pulseSize = baseSize * (1.0 + scale * params.scaleAmount)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.statusWaiting.opacity(params.maxOpacity * intensity),
                                Color.statusWaiting.opacity(params.maxOpacity * intensity * 0.4),
                                Color.statusWaiting.opacity(params.maxOpacity * intensity * 0.1),
                                Color.statusWaiting.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: pulseSize / 2
                        )
                    )
                    .frame(width: pulseSize, height: pulseSize)
                    .position(
                        x: geometry.size.width * params.originXPercent,
                        y: geometry.size.height * params.originYPercent
                    )
                    .blur(radius: params.blurAmount + intensity * 10)
            }
        }
        .allowsHitTesting(false)
    }

    private var pulseParameters: WaitingPulseParameters {
        #if DEBUG
        WaitingPulseParameters(
            cycleLength: config.waitingCycleLength(for: layoutMode),
            firstPulseDuration: config.waitingFirstPulseDuration(for: layoutMode),
            firstPulseFadeOut: config.waitingFirstPulseFadeOut(for: layoutMode),
            secondPulseDelay: config.waitingSecondPulseDelay(for: layoutMode),
            secondPulseDuration: config.waitingSecondPulseDuration(for: layoutMode),
            secondPulseFadeOut: config.waitingSecondPulseFadeOut(for: layoutMode),
            maxOpacity: config.waitingMaxOpacity(for: layoutMode),
            blurAmount: config.waitingBlurAmount(for: layoutMode),
            pulseScale: config.waitingPulseScale(for: layoutMode),
            scaleAmount: config.waitingScaleAmount(for: layoutMode),
            springDamping: config.waitingSpringDamping(for: layoutMode),
            springOmega: config.waitingSpringOmega(for: layoutMode),
            firstPulseIntensity: config.waitingFirstPulseIntensity(for: layoutMode),
            secondPulseIntensity: config.waitingSecondPulseIntensity(for: layoutMode),
            originXPercent: config.waitingOriginX(for: layoutMode),
            originYPercent: config.waitingOriginY(for: layoutMode)
        )
        #else
        WaitingPulseParameters(
            cycleLength: layoutMode == .dock ? 2.4 : 1.68,
            firstPulseDuration: layoutMode == .dock ? 0.15 : 0.17,
            firstPulseFadeOut: layoutMode == .dock ? 0.25 : 0.17,
            secondPulseDelay: layoutMode == .dock ? 0.12 : 0.00,
            secondPulseDuration: layoutMode == .dock ? 0.12 : 0.17,
            secondPulseFadeOut: layoutMode == .dock ? 0.20 : 0.48,
            maxOpacity: layoutMode == .dock ? 0.5 : 0.34,
            blurAmount: layoutMode == .dock ? 25 : 0.0,
            pulseScale: layoutMode == .dock ? 1.6 : 2.22,
            scaleAmount: layoutMode == .dock ? 0.4 : 0.30,
            springDamping: layoutMode == .dock ? 1.2 : 1.69,
            springOmega: layoutMode == .dock ? 8.0 : 3.3,
            firstPulseIntensity: layoutMode == .dock ? 1.0 : 0.34,
            secondPulseIntensity: layoutMode == .dock ? 0.6 : 0.47,
            originXPercent: layoutMode == .dock ? 0.5 : 1.00,
            originYPercent: layoutMode == .dock ? 0.5 : 0.00
        )
        #endif
    }

    private func springPulseValues(phase: Double, params: WaitingPulseParameters) -> (intensity: Double, scale: Double) {
        let firstEnd = params.firstPulseDuration
        let firstFadeEnd = firstEnd + params.firstPulseFadeOut
        let secondStart = firstFadeEnd + params.secondPulseDelay
        let secondEnd = secondStart + params.secondPulseDuration
        let secondFadeEnd = secondEnd + params.secondPulseFadeOut
        let firstIntensity = params.firstPulseIntensity
        let secondIntensity = params.secondPulseIntensity

        if phase < firstEnd {
            // First pulse attack - heavily damped spring
            let t = phase / firstEnd
            let intensity = dampedSpring(t: t, damping: params.springDamping, omega: params.springOmega) * firstIntensity
            return (intensity, intensity)
        } else if phase < firstFadeEnd {
            // First pulse fade out - smooth decay
            let t = (phase - firstEnd) / params.firstPulseFadeOut
            let intensity = dampedSpring(t: 1.0 - t, damping: params.springDamping * 0.75, omega: params.springOmega) * firstIntensity
            return (intensity, intensity)
        } else if phase >= secondStart && phase < secondEnd {
            // Second pulse attack - smaller, heavily damped
            let t = (phase - secondStart) / params.secondPulseDuration
            let intensity = dampedSpring(t: t, damping: params.springDamping * 1.1, omega: params.springOmega) * secondIntensity
            return (intensity, intensity * 0.8)
        } else if phase >= secondEnd && phase < secondFadeEnd {
            // Second pulse fade out
            let t = (phase - secondEnd) / params.secondPulseFadeOut
            let intensity = dampedSpring(t: 1.0 - t, damping: params.springDamping * 0.85, omega: params.springOmega) * secondIntensity
            return (intensity, intensity * 0.8)
        }
        return (0, 0)
    }

    private func dampedSpring(t: Double, damping: Double, omega: Double) -> Double {
        // Critically/over-damped spring - no oscillation, smooth settle
        // damping >= 1.0 means no overshoot
        let dampedT = t * omega

        if damping >= 1.0 {
            // Over-damped: smooth exponential approach
            let decay = exp(-damping * dampedT)
            return 1.0 - decay * (1.0 + damping * dampedT)
        } else {
            // Under-damped: slight oscillation
            let dampedOmega = omega * sqrt(1.0 - damping * damping)
            let decay = exp(-damping * omega * t)
            return 1.0 - decay * (cos(dampedOmega * t) + (damping * omega / dampedOmega) * sin(dampedOmega * t))
        }
    }
}

/// Synchronized border pulse for the Waiting state with spring animation
struct WaitingBorderPulse: View {
    let seed: String
    var cornerRadius: CGFloat = 12
    var layoutMode: LayoutMode = .vertical
    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    var body: some View {
        if reduceMotion {
            staticBorder
        } else {
            animatedBorder
        }
    }

    private var staticBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(Color.statusWaiting.opacity(0.5), lineWidth: 2)
            .allowsHitTesting(false)
    }

    private var animatedBorder: some View {
        TimelineView(.animation) { timeline in
            let params = pulseParameters
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: params.cycleLength) / params.cycleLength
            let intensity = springPulseIntensity(phase: phase, params: params)

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color.statusWaiting.opacity(params.baseOpacity + intensity * params.pulseOpacity),
                        lineWidth: params.innerWidth + intensity * 1.5
                    )

                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color.statusWaiting.opacity((params.baseOpacity + intensity * params.pulseOpacity) * 0.5),
                        lineWidth: params.outerWidth + intensity * 4
                    )
                    .blur(radius: params.outerBlur + intensity * 6)
            }
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    private var pulseParameters: WaitingPulseParameters {
        #if DEBUG
        WaitingPulseParameters(
            cycleLength: config.waitingCycleLength(for: layoutMode),
            firstPulseDuration: config.waitingFirstPulseDuration(for: layoutMode),
            firstPulseFadeOut: config.waitingFirstPulseFadeOut(for: layoutMode),
            secondPulseDelay: config.waitingSecondPulseDelay(for: layoutMode),
            secondPulseDuration: config.waitingSecondPulseDuration(for: layoutMode),
            secondPulseFadeOut: config.waitingSecondPulseFadeOut(for: layoutMode),
            maxOpacity: config.waitingMaxOpacity(for: layoutMode),
            blurAmount: 0,
            springDamping: config.waitingSpringDamping(for: layoutMode),
            springOmega: config.waitingSpringOmega(for: layoutMode),
            firstPulseIntensity: config.waitingFirstPulseIntensity(for: layoutMode),
            secondPulseIntensity: config.waitingSecondPulseIntensity(for: layoutMode),
            baseOpacity: config.waitingBorderBaseOpacity(for: layoutMode),
            pulseOpacity: config.waitingBorderPulseOpacity(for: layoutMode),
            innerWidth: config.waitingBorderInnerWidth(for: layoutMode),
            outerWidth: config.waitingBorderOuterWidth(for: layoutMode),
            innerBlur: 0,
            outerBlur: config.waitingBorderOuterBlur(for: layoutMode)
        )
        #else
        WaitingPulseParameters(
            cycleLength: layoutMode == .dock ? 2.4 : 1.68,
            firstPulseDuration: layoutMode == .dock ? 0.15 : 0.17,
            firstPulseFadeOut: layoutMode == .dock ? 0.25 : 0.17,
            secondPulseDelay: layoutMode == .dock ? 0.12 : 0.00,
            secondPulseDuration: layoutMode == .dock ? 0.12 : 0.17,
            secondPulseFadeOut: layoutMode == .dock ? 0.20 : 0.48,
            maxOpacity: layoutMode == .dock ? 0.5 : 0.34,
            blurAmount: 0,
            springDamping: layoutMode == .dock ? 1.2 : 1.69,
            springOmega: layoutMode == .dock ? 8.0 : 3.3,
            firstPulseIntensity: layoutMode == .dock ? 1.0 : 0.34,
            secondPulseIntensity: layoutMode == .dock ? 0.6 : 0.47,
            baseOpacity: layoutMode == .dock ? 0.2 : 0.12,
            pulseOpacity: layoutMode == .dock ? 0.6 : 0.37,
            innerWidth: layoutMode == .dock ? 1.5 : 0.50,
            outerWidth: layoutMode == .dock ? 3.0 : 1.86,
            innerBlur: 0,
            outerBlur: layoutMode == .dock ? 4.0 : 0.8
        )
        #endif
    }

    private func springPulseIntensity(phase: Double, params: WaitingPulseParameters) -> Double {
        let firstEnd = params.firstPulseDuration
        let firstFadeEnd = firstEnd + params.firstPulseFadeOut
        let secondStart = firstFadeEnd + params.secondPulseDelay
        let secondEnd = secondStart + params.secondPulseDuration
        let secondFadeEnd = secondEnd + params.secondPulseFadeOut
        let firstIntensity = params.firstPulseIntensity
        let secondIntensity = params.secondPulseIntensity

        if phase < firstEnd {
            let t = phase / firstEnd
            return dampedSpring(t: t, damping: params.springDamping, omega: params.springOmega) * firstIntensity
        } else if phase < firstFadeEnd {
            let t = (phase - firstEnd) / params.firstPulseFadeOut
            return dampedSpring(t: 1.0 - t, damping: params.springDamping * 0.75, omega: params.springOmega) * firstIntensity
        } else if phase >= secondStart && phase < secondEnd {
            let t = (phase - secondStart) / params.secondPulseDuration
            return dampedSpring(t: t, damping: params.springDamping * 1.1, omega: params.springOmega) * secondIntensity
        } else if phase >= secondEnd && phase < secondFadeEnd {
            let t = (phase - secondEnd) / params.secondPulseFadeOut
            return dampedSpring(t: 1.0 - t, damping: params.springDamping * 0.85, omega: params.springOmega) * secondIntensity
        }
        return 0
    }

    private func dampedSpring(t: Double, damping: Double, omega: Double) -> Double {
        let dampedT = t * omega

        if damping >= 1.0 {
            let decay = exp(-damping * dampedT)
            return 1.0 - decay * (1.0 + damping * dampedT)
        } else {
            let dampedOmega = omega * sqrt(1.0 - damping * damping)
            let decay = exp(-damping * omega * t)
            return 1.0 - decay * (cos(dampedOmega * t) + (damping * omega / dampedOmega) * sin(dampedOmega * t))
        }
    }
}

struct WaitingPulseParameters {
    let cycleLength: Double
    let firstPulseDuration: Double
    let firstPulseFadeOut: Double
    let secondPulseDelay: Double
    let secondPulseDuration: Double
    let secondPulseFadeOut: Double
    let maxOpacity: Double
    let blurAmount: Double
    var pulseScale: Double = 1.6
    var scaleAmount: Double = 0.4
    var springDamping: Double = 1.2
    var springOmega: Double = 8.0
    var firstPulseIntensity: Double = 1.0
    var secondPulseIntensity: Double = 0.6
    var baseOpacity: Double = 0.2
    var pulseOpacity: Double = 0.5
    var innerWidth: Double = 1.0
    var outerWidth: Double = 2.0
    var innerBlur: Double = 0.3
    var outerBlur: Double = 3.0
    var originXPercent: Double = 0.5
    var originYPercent: Double = 0.5
}

// MARK: - Working State Effects

struct WorkingStripeParameters {
    let stripeWidth: Double
    let stripeSpacing: Double
    let stripeAngle: Double
    let scrollSpeed: Double
    let stripeOpacity: Double
    let darkStripeOpacity: Double
    // Emissive glow parameters
    let glowIntensity: Double
    let glowBlurRadius: Double
    let coreBrightness: Double
    let gradientFalloff: Double
    // Vignette mask parameters
    let vignetteInnerRadius: Double
    let vignetteOuterRadius: Double
    let vignetteCenterOpacity: Double
    // Vignette color tint
    let vignetteColor: Color
    let vignetteColorIntensity: Double
    let vignetteBlendMode: BlendMode
}

struct WorkingStripeOverlay: View {
    var layoutMode: LayoutMode = .vertical
    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    var body: some View {
        if reduceMotion {
            staticStripes
        } else {
            animatedStripes
        }
    }

    private var staticStripes: some View {
        let params = stripeParameters
        return ZStack {
            // Colored background that shows through in the center
            vignetteBackground(params: params)

            // Stripe layers masked to show at edges
            ZStack {
                GeometryReader { _ in
                    Canvas { context, size in
                        drawGlowStripes(context: context, size: size, phase: 0, params: params)
                    }
                }
                .blur(radius: params.glowBlurRadius)
                .opacity(params.glowIntensity)
                .blendMode(.plusLighter)

                GeometryReader { _ in
                    Canvas { context, size in
                        drawCoreStripes(context: context, size: size, phase: 0, params: params)
                    }
                }
                .blendMode(.plusLighter)
            }
            .mask(vignetteMask(params: params))
        }
        .allowsHitTesting(false)
    }

    private var animatedStripes: some View {
        TimelineView(.animation) { timeline in
            let params = stripeParameters
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: params.scrollSpeed) / params.scrollSpeed

            ZStack {
                // Colored background that shows through in the center
                vignetteBackground(params: params)

                // Stripe layers masked to show at edges
                ZStack {
                    GeometryReader { _ in
                        Canvas { context, size in
                            drawGlowStripes(context: context, size: size, phase: phase, params: params)
                        }
                    }
                    .blur(radius: params.glowBlurRadius)
                    .opacity(params.glowIntensity)
                    .blendMode(.plusLighter)

                    GeometryReader { _ in
                        Canvas { context, size in
                            drawCoreStripes(context: context, size: size, phase: phase, params: params)
                        }
                    }
                    .blendMode(.plusLighter)
                }
                .mask(vignetteMask(params: params))
            }
        }
        .allowsHitTesting(false)
    }

    private func vignetteMask(params: WorkingStripeParameters) -> some View {
        GeometryReader { geometry in
            let cornerRadius: CGFloat = layoutMode == .dock ? 10 : 12
            let frameWidth = params.vignetteInnerRadius * min(geometry.size.width, geometry.size.height)
            let blurAmount = frameWidth * params.vignetteOuterRadius

            ZStack {
                // Low opacity center (stripes barely visible here)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.white.opacity(params.vignetteCenterOpacity))

                // Bright frame at edges (stripes fully visible here)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white, lineWidth: frameWidth)
                    .blur(radius: blurAmount)

                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white, lineWidth: frameWidth * 0.5)
            }
            .compositingGroup()
        }
    }

    private func vignetteBackground(params: WorkingStripeParameters) -> some View {
        GeometryReader { geometry in
            let cornerRadius: CGFloat = layoutMode == .dock ? 10 : 12

            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(params.vignetteColor)
                .opacity(params.vignetteColorIntensity)
                .blendMode(params.vignetteBlendMode)
        }
    }

    private func drawGlowStripes(context: GraphicsContext, size: CGSize, phase: Double, params: WorkingStripeParameters) {
        let stripeWidth = params.stripeWidth * 1.5
        let patternWidth = params.stripeSpacing
        let angle = params.stripeAngle * .pi / 180

        let diagonal = sqrt(size.width * size.width + size.height * size.height)
        let offset = phase * patternWidth

        var stripeContext = context
        stripeContext.translateBy(x: size.width / 2, y: size.height / 2)
        stripeContext.rotate(by: Angle(radians: angle))
        stripeContext.translateBy(x: -diagonal / 2 - offset, y: -diagonal / 2)

        let stripeCount = Int(ceil(diagonal * 2 / patternWidth)) + 2
        let glowColor = Color.statusWorking

        for i in 0..<stripeCount {
            let x = Double(i) * patternWidth
            let stripeRect = CGRect(x: x, y: 0, width: stripeWidth, height: diagonal * 2)
            let stripePath = Path(stripeRect)
            stripeContext.fill(stripePath, with: .color(glowColor.opacity(params.stripeOpacity * 1.5)))
        }
    }

    private func drawCoreStripes(context: GraphicsContext, size: CGSize, phase: Double, params: WorkingStripeParameters) {
        let stripeWidth = params.stripeWidth
        let patternWidth = params.stripeSpacing
        let angle = params.stripeAngle * .pi / 180

        let diagonal = sqrt(size.width * size.width + size.height * size.height)
        let offset = phase * patternWidth

        var stripeContext = context
        stripeContext.translateBy(x: size.width / 2, y: size.height / 2)
        stripeContext.rotate(by: Angle(radians: angle))
        stripeContext.translateBy(x: -diagonal / 2 - offset, y: -diagonal / 2)

        let stripeCount = Int(ceil(diagonal * 2 / patternWidth)) + 2

        for i in 0..<stripeCount {
            let x = Double(i) * patternWidth

            // Gradient stripe: bright core fading to edges (neon tube effect)
            let gradientRect = CGRect(x: x, y: 0, width: stripeWidth, height: diagonal * 2)

            let gradient = Gradient(stops: [
                .init(color: Color.statusWorking.opacity(params.stripeOpacity * 0.3), location: 0.0),
                .init(color: Color.white.opacity(params.coreBrightness), location: 0.5 - params.gradientFalloff),
                .init(color: Color.white.opacity(params.coreBrightness), location: 0.5 + params.gradientFalloff),
                .init(color: Color.statusWorking.opacity(params.stripeOpacity * 0.3), location: 1.0)
            ])

            let stripePath = Path(gradientRect)
            stripeContext.fill(
                stripePath,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: x, y: 0),
                    endPoint: CGPoint(x: x + stripeWidth, y: 0)
                )
            )
        }
    }

    private var stripeParameters: WorkingStripeParameters {
        #if DEBUG
        WorkingStripeParameters(
            stripeWidth: config.workingStripeWidth(for: layoutMode),
            stripeSpacing: config.workingStripeSpacing(for: layoutMode),
            stripeAngle: config.workingStripeAngle(for: layoutMode),
            scrollSpeed: config.workingScrollSpeed(for: layoutMode),
            stripeOpacity: config.workingStripeOpacity(for: layoutMode),
            darkStripeOpacity: config.workingDarkStripeOpacity(for: layoutMode),
            glowIntensity: config.workingGlowIntensity(for: layoutMode),
            glowBlurRadius: config.workingGlowBlurRadius(for: layoutMode),
            coreBrightness: config.workingCoreBrightness(for: layoutMode),
            gradientFalloff: config.workingGradientFalloff(for: layoutMode),
            vignetteInnerRadius: config.workingVignetteInnerRadius(for: layoutMode),
            vignetteOuterRadius: config.workingVignetteOuterRadius(for: layoutMode),
            vignetteCenterOpacity: config.workingVignetteCenterOpacity(for: layoutMode),
            vignetteColor: config.workingVignetteColor,
            vignetteColorIntensity: config.workingVignetteColorIntensity(for: layoutMode),
            vignetteBlendMode: config.workingVignetteBlendMode
        )
        #else
        WorkingStripeParameters(
            stripeWidth: 24.0,
            stripeSpacing: 38.49,
            stripeAngle: 41.30,
            scrollSpeed: 4.81,
            stripeOpacity: 0.50,
            darkStripeOpacity: 0.0,
            glowIntensity: 1.50,
            glowBlurRadius: 11.46,
            coreBrightness: 0.71,
            gradientFalloff: 0.32,
            vignetteInnerRadius: 0.02,
            vignetteOuterRadius: 0.48,
            vignetteCenterOpacity: 0.03,
            vignetteColor: Color(hue: 0.05, saturation: 0.67, brightness: 0.39),
            vignetteColorIntensity: 0.47,
            vignetteBlendMode: .plusLighter
        )
        #endif
    }
}

struct WorkingBorderGlow: View {
    let seed: String
    var cornerRadius: CGFloat = 12
    var layoutMode: LayoutMode = .vertical
    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    private var timeOffset: Double {
        var hasher = Hasher()
        hasher.combine(seed)
        let hash = abs(hasher.finalize())
        return Double(hash % 10000) / 1000.0
    }

    var body: some View {
        if reduceMotion {
            staticBorder
        } else {
            animatedBorder
        }
    }

    private var staticBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(Color.statusWorking.opacity(0.4), lineWidth: 1.5)
            .allowsHitTesting(false)
    }

    private var animatedBorder: some View {
        TimelineView(.animation) { timeline in
            let params = borderParameters
            let time = timeline.date.timeIntervalSinceReferenceDate + timeOffset
            let phase = sin(time * 2 * .pi / params.pulseSpeed)
            let opacity = params.baseOpacity + (phase + 1) / 2 * params.pulseIntensity

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color.statusWorking.opacity(opacity),
                        lineWidth: params.borderWidth
                    )

                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color.statusWorking.opacity(opacity * 0.5),
                        lineWidth: params.borderWidth * 2
                    )
                    .blur(radius: params.blurAmount)
            }
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    private var borderParameters: WorkingBorderParameters {
        #if DEBUG
        WorkingBorderParameters(
            borderWidth: config.workingBorderWidth(for: layoutMode),
            baseOpacity: config.workingBorderBaseOpacity(for: layoutMode),
            pulseIntensity: config.workingBorderPulseIntensity(for: layoutMode),
            pulseSpeed: config.workingBorderPulseSpeed(for: layoutMode),
            blurAmount: config.workingBorderBlurAmount(for: layoutMode)
        )
        #else
        WorkingBorderParameters(
            borderWidth: 1.0,
            baseOpacity: 0.35,
            pulseIntensity: 0.50,
            pulseSpeed: 2.21,
            blurAmount: 8.0
        )
        #endif
    }
}

struct WorkingBorderParameters {
    let borderWidth: Double
    let baseOpacity: Double
    let pulseIntensity: Double
    let pulseSpeed: Double
    let blurAmount: Double
}
