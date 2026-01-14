import SwiftUI

struct BreathingDot: View {
    let color: Color
    var showGlow: Bool = true
    var syncWithRipple: Bool = false

    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    var body: some View {
        #if DEBUG
        TimelineView(.animation) { context in
            BreathingDotContentDebug(
                color: color,
                showGlow: showGlow,
                syncWithRipple: syncWithRipple,
                date: context.date,
                config: config
            )
        }
        .id(config.breathingConfigHash)
        #else
        TimelineView(.animation) { context in
            BreathingDotContentRelease(
                color: color,
                showGlow: showGlow,
                syncWithRipple: syncWithRipple,
                date: context.date
            )
        }
        #endif
    }
}

#if DEBUG
private struct BreathingDotContentDebug: View {
    let color: Color
    let showGlow: Bool
    let syncWithRipple: Bool
    let date: Date
    let config: GlassConfig

    var body: some View {
        let dotSize = config.breathingDotSize
        let dotShadowRadius = config.breathingDotShadowRadius
        let glowSize = config.breathingGlowSize
        let glowBlur = config.breathingGlowBlur
        let baseSpeed = config.breathingSpeed
        let minScale = config.breathingMinScale
        let minOpacity = config.breathingMinOpacity
        let glowMinOpacity = config.breathingGlowMinOpacity
        let glowMaxOpacity = config.breathingGlowMaxOpacity
        let glowMinScale = config.breathingGlowMinScale
        let glowMaxScale = config.breathingGlowMaxScale
        let rippleSpeed = config.rippleSpeed
        let phaseOffset = syncWithRipple ? config.breathingPhaseOffset : 0.0

        BreathingDotRenderer(
            color: color,
            showGlow: showGlow,
            date: date,
            speed: syncWithRipple ? rippleSpeed : baseSpeed,
            phaseOffset: phaseOffset,
            dotSize: dotSize,
            dotShadowRadius: dotShadowRadius,
            glowSize: glowSize,
            glowBlur: glowBlur,
            minScale: minScale,
            minOpacity: minOpacity,
            glowMinOpacity: glowMinOpacity,
            glowMaxOpacity: glowMaxOpacity,
            glowMinScale: glowMinScale,
            glowMaxScale: glowMaxScale
        )
    }
}
#endif

private struct BreathingDotContentRelease: View {
    let color: Color
    let showGlow: Bool
    let syncWithRipple: Bool
    let date: Date

    var body: some View {
        let dotSize: CGFloat = 12
        let dotShadowRadius: CGFloat = 0
        let glowSize: CGFloat = 8
        let glowBlur: CGFloat = 5
        let baseSpeed: Double = 3.00
        let minScale: Double = 0.52
        let minOpacity: Double = 0.7
        let glowMinOpacity: Double = 0.25
        let glowMaxOpacity: Double = 0.5
        let glowMinScale: Double = 0.80
        let glowMaxScale: Double = 1.46
        let rippleSpeed: Double = 4.9

        BreathingDotRenderer(
            color: color,
            showGlow: showGlow,
            date: date,
            speed: syncWithRipple ? rippleSpeed : baseSpeed,
            phaseOffset: 0.0,
            dotSize: dotSize,
            dotShadowRadius: dotShadowRadius,
            glowSize: glowSize,
            glowBlur: glowBlur,
            minScale: minScale,
            minOpacity: minOpacity,
            glowMinOpacity: glowMinOpacity,
            glowMaxOpacity: glowMaxOpacity,
            glowMinScale: glowMinScale,
            glowMaxScale: glowMaxScale
        )
    }
}

private struct BreathingDotRenderer: View {
    let color: Color
    let showGlow: Bool
    let date: Date
    let speed: Double
    let phaseOffset: Double
    let dotSize: Double
    let dotShadowRadius: Double
    let glowSize: Double
    let glowBlur: Double
    let minScale: Double
    let minOpacity: Double
    let glowMinOpacity: Double
    let glowMaxOpacity: Double
    let glowMinScale: Double
    let glowMaxScale: Double

    var body: some View {
        let time = date.timeIntervalSinceReferenceDate
        let rawCyclePhase = time.truncatingRemainder(dividingBy: speed) / speed
        let cyclePhase = (rawCyclePhase + phaseOffset).truncatingRemainder(dividingBy: 1.0)
        let breathPhase = cyclePhase < 0.5 ? cyclePhase * 2 : (1.0 - cyclePhase) * 2
        let easedPhase = easeInOut(breathPhase)

        let dotScale = 1.0 - (1.0 - minScale) * easedPhase
        let dotOpacity = 1.0 - (1.0 - minOpacity) * easedPhase
        let currentGlowScale = glowMinScale + (glowMaxScale - glowMinScale) * easedPhase
        let currentGlowOpacity = glowMaxOpacity - (glowMaxOpacity - glowMinOpacity) * easedPhase

        ZStack {
            if showGlow {
                Circle()
                    .fill(color.opacity(0.5))
                    .frame(width: glowSize, height: glowSize)
                    .blur(radius: glowBlur)
                    .scaleEffect(currentGlowScale)
                    .opacity(currentGlowOpacity)
            }

            Circle()
                .fill(color)
                .frame(width: dotSize, height: dotSize)
                .shadow(color: dotShadowRadius > 0 ? color.opacity(0.6) : .clear, radius: dotShadowRadius, x: 0, y: 0)
                .scaleEffect(dotScale)
                .opacity(dotOpacity)
        }
    }

    private func easeInOut(_ t: Double) -> Double {
        if t < 0.5 {
            return 2 * t * t
        } else {
            return 1 - pow(-2 * t + 2, 2) / 2
        }
    }
}

#if DEBUG
extension GlassConfig {
    var breathingConfigHash: Int {
        var hasher = Hasher()
        hasher.combine(breathingDotSize)
        hasher.combine(breathingDotShadowRadius)
        hasher.combine(breathingGlowSize)
        hasher.combine(breathingGlowBlur)
        hasher.combine(breathingSpeed)
        hasher.combine(breathingMinScale)
        hasher.combine(breathingMinOpacity)
        hasher.combine(breathingGlowMinScale)
        hasher.combine(breathingGlowMaxScale)
        hasher.combine(breathingGlowMinOpacity)
        hasher.combine(breathingGlowMaxOpacity)
        hasher.combine(breathingPhaseOffset)
        hasher.combine(rippleSpeed)
        return hasher.finalize()
    }
}
#endif
