import SwiftUI

struct ReadyAmbientGlow: View {
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
            speed: config.rippleSpeed,
            count: config.rippleCount,
            maxOpacity: config.rippleMaxOpacity,
            lineWidth: config.rippleLineWidth,
            blurAmount: config.rippleBlurAmount,
            originXPercent: config.rippleOriginX,
            originYPercent: config.rippleOriginY,
            fadeInZone: config.rippleFadeInZone,
            fadeOutPower: config.rippleFadeOutPower
        )
        #else
        GlowParameters(
            speed: 4.9,
            count: 4,
            maxOpacity: 1.0,
            lineWidth: 30.0,
            blurAmount: 41.5,
            originXPercent: 0.89,
            originYPercent: 0.0,
            fadeInZone: 0.10,
            fadeOutPower: 4.0
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
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.statusReady.opacity(0.3), lineWidth: 1)
            .allowsHitTesting(false)
    }

    private var animatedBorderGlow: some View {
        TimelineView(.animation) { timeline in
            #if DEBUG
            ReadyBorderGlowContent(date: timeline.date, config: config, timeOffset: timeOffset)
            #else
            ReadyBorderGlowContent(date: timeline.date, config: nil, timeOffset: timeOffset)
            #endif
        }
        .allowsHitTesting(false)
    }
}

struct ReadyBorderGlowContent: View {
    let date: Date
    let timeOffset: Double

    #if DEBUG
    let config: GlassConfig?

    init(date: Date, config: GlassConfig?, timeOffset: Double) {
        self.date = date
        self.config = config
        self.timeOffset = timeOffset
    }
    #else
    init(date: Date, config: Any?, timeOffset: Double) {
        self.date = date
        self.timeOffset = timeOffset
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
                speed: config.rippleSpeed,
                count: config.rippleCount,
                fadeInZone: config.rippleFadeInZone,
                fadeOutPower: config.rippleFadeOutPower,
                rotationMult: config.borderGlowRotationMultiplier,
                baseOp: config.borderGlowBaseOpacity,
                pulseIntensity: config.borderGlowPulseIntensity,
                innerWidth: config.borderGlowInnerWidth,
                outerWidth: config.borderGlowOuterWidth,
                innerBlur: config.borderGlowInnerBlur,
                outerBlur: config.borderGlowOuterBlur
            )
        }
        #endif
        return BorderGlowParameters(
            speed: 4.9,
            count: 4,
            fadeInZone: 0.10,
            fadeOutPower: 4.0,
            rotationMult: 0.50,
            baseOp: 0.30,
            pulseIntensity: 0.50,
            innerWidth: 0.49,
            outerWidth: 2.88,
            innerBlur: 0.5,
            outerBlur: 1.5
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
            RoundedRectangle(cornerRadius: 12)
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

            RoundedRectangle(cornerRadius: 12)
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
