import SwiftUI

#if DEBUG

struct CausticUnderglow: View {
    let size: CGSize

    @ObservedObject private var config = GlassConfig.shared
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !config.causticEnabled)) { timeline in
            Canvas { context, canvasSize in
                let time = timeline.date.timeIntervalSinceReferenceDate * config.causticSpeed
                drawCaustics(context: context, size: canvasSize, time: time)
            }
        }
        .blur(radius: config.causticBlur)
        .opacity(config.causticOpacity)
        .blendMode(config.causticBlendMode)
        .allowsHitTesting(false)
    }

    private func drawCaustics(context: GraphicsContext, size: CGSize, time: Double) {
        let cellSize = config.causticCellSize
        let cols = Int(size.width / cellSize) + 2
        let rows = Int(size.height / cellSize) + 2

        for row in 0..<rows {
            for col in 0..<cols {
                let baseX = Double(col) * cellSize
                let baseY = Double(row) * cellSize

                let intensity = causticIntensity(
                    x: baseX,
                    y: baseY,
                    time: time,
                    size: size
                )

                if intensity > config.causticThreshold {
                    let normalizedIntensity = (intensity - config.causticThreshold) / (1.0 - config.causticThreshold)
                    let color = causticColor(intensity: normalizedIntensity)

                    let pointSize = cellSize * (0.5 + normalizedIntensity * config.causticPointScale)
                    let rect = CGRect(
                        x: baseX - pointSize / 2,
                        y: baseY - pointSize / 2,
                        width: pointSize,
                        height: pointSize
                    )

                    context.fill(
                        Ellipse().path(in: rect),
                        with: .color(color)
                    )
                }
            }
        }
    }

    private func causticIntensity(x: Double, y: Double, time: Double, size: CGSize) -> Double {
        let scale1 = config.causticScale1
        let scale2 = config.causticScale2
        let scale3 = config.causticScale3

        let wave1 = sin(x / scale1 + time * 1.0) * cos(y / scale1 + time * 0.7)
        let wave2 = sin(x / scale2 - time * 0.8 + y / scale2) * cos(y / scale2 + time * 1.1)
        let wave3 = sin((x + y) / scale3 + time * 0.5) * cos((x - y) / scale3 - time * 0.6)

        let radialX = (x - size.width * config.causticOriginX) / (size.width * 0.5)
        let radialY = (y - size.height * config.causticOriginY) / (size.height * 0.5)
        let radialDist = sqrt(radialX * radialX + radialY * radialY)
        let radialFade = max(0, 1.0 - radialDist * config.causticRadialFalloff)

        let combined = (wave1 + wave2 + wave3) / 3.0
        let normalized = (combined + 1.0) / 2.0

        return pow(normalized, config.causticConcentration) * radialFade
    }

    private func causticColor(intensity: Double) -> Color {
        let baseColor = config.causticColor
        return baseColor.opacity(intensity * intensity)
    }
}

struct CausticUnderglowMesh: View {
    let size: CGSize

    @ObservedObject private var config = GlassConfig.shared
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !config.causticEnabled)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate * config.causticSpeed

            Canvas { context, canvasSize in
                drawRipples(context: context, size: canvasSize, time: time)
            }
        }
        .blur(radius: config.causticBlur)
        .opacity(config.causticOpacity)
        .blendMode(config.causticBlendMode)
        .allowsHitTesting(false)
    }

    private func drawRipples(context: GraphicsContext, size: CGSize, time: Double) {
        let originX = size.width * config.causticOriginX
        let originY = size.height * config.causticOriginY

        let ringCount = config.causticRingCount
        let maxRadius = max(size.width, size.height) * 1.2

        for i in 0..<ringCount {
            let baseProgress = Double(i) / Double(ringCount)
            let animatedProgress = fmod(baseProgress + time * 0.1, 1.0)
            let radius = animatedProgress * maxRadius

            let waveOffset = sin(time * 2.0 + Double(i) * 0.5) * config.causticWaveAmplitude
            let adjustedRadius = radius + waveOffset

            guard adjustedRadius > 0 else { continue }

            let fadeIn = min(1.0, animatedProgress * 5.0)
            let fadeOut = max(0.0, 1.0 - animatedProgress)
            let ringOpacity = fadeIn * fadeOut * config.causticRingOpacity

            let rect = CGRect(
                x: originX - adjustedRadius,
                y: originY - adjustedRadius,
                width: adjustedRadius * 2,
                height: adjustedRadius * 2
            )

            let lineWidth = config.causticRingWidth * (1.0 - animatedProgress * 0.5)

            context.stroke(
                Ellipse().path(in: rect),
                with: .color(config.causticColor.opacity(ringOpacity)),
                lineWidth: lineWidth
            )
        }

        drawCausticBrights(context: context, size: size, time: time, originX: originX, originY: originY)
    }

    private func drawCausticBrights(context: GraphicsContext, size: CGSize, time: Double, originX: Double, originY: Double) {
        let brightCount = config.causticBrightCount

        for i in 0..<brightCount {
            let angle = Double(i) / Double(brightCount) * .pi * 2 + time * 0.3
            let radiusOffset = sin(time * 1.5 + Double(i)) * 20
            let radius = 50 + radiusOffset + Double(i % 3) * 30

            let x = originX + cos(angle) * radius
            let y = originY + sin(angle) * radius

            let pulsePhase = sin(time * 2.0 + Double(i) * 0.7)
            let brightness = 0.3 + pulsePhase * 0.2
            let pointSize = config.causticBrightSize * (0.8 + pulsePhase * 0.4)

            let gradient = Gradient(colors: [
                config.causticColor.opacity(brightness),
                config.causticColor.opacity(0)
            ])

            let rect = CGRect(
                x: x - pointSize / 2,
                y: y - pointSize / 2,
                width: pointSize,
                height: pointSize
            )

            context.fill(
                Ellipse().path(in: rect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: pointSize / 2
                )
            )
        }
    }
}

#endif
