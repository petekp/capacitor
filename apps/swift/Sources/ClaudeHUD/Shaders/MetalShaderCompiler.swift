import SwiftUI

#if DEBUG

enum MetalShaders {
    static func initialize() {
        _ = library
    }

    static var library: ShaderLibrary? = {
        print("🔍 MetalShaders: Bundle.module path = \(Bundle.module.bundlePath)")

        guard let url = Bundle.module.url(forResource: "debug", withExtension: "metallib") else {
            print("⚠️ MetalShaders: Could not find debug.metallib in bundle")
            print("   Available resources: \((try? FileManager.default.contentsOfDirectory(atPath: Bundle.module.bundlePath)) ?? [])")
            return nil
        }

        print("✅ MetalShaders: Loading from \(url.path)")
        let lib = ShaderLibrary(url: url)
        print("✅ MetalShaders: Library created successfully")
        return lib
    }()

    static func refractiveGlass(
        size: CGSize,
        time: Double,
        config: GlassConfig
    ) -> Shader? {
        library?[dynamicMember: "refractiveGlass"](
            .float2(size.width, size.height),
            .float(time),
            .float(config.logoGlassFresnelPower),
            .float(config.logoGlassFresnelIntensity),
            .float(config.logoGlassChromaticAmount),
            .float(config.logoGlassCausticScale),
            .float(config.logoGlassCausticSpeed),
            .float(config.logoGlassCausticIntensity),
            .float(config.logoGlassCausticAngle),
            .float(config.logoGlassClarity),
            .float(config.logoGlassHighlightSharpness),
            .float(config.logoGlassHighlightAngle),
            .float(config.logoGlassInternalReflection),
            .float(config.logoGlassInternalAngle)
        )
    }

    static func prismaticGlass(
        size: CGSize,
        time: Double,
        config: GlassConfig
    ) -> Shader? {
        library?[dynamicMember: "prismaticGlass"](
            .float2(size.width, size.height),
            .float(time),
            .float(config.logoGlassFresnelPower),
            .float(config.logoGlassFresnelIntensity),
            .float(config.logoGlassChromaticAmount),
            .float(config.logoGlassCausticScale),
            .float(config.logoGlassCausticSpeed),
            .float(config.logoGlassCausticIntensity),
            .float(config.logoGlassCausticAngle),
            .float(config.logoGlassClarity),
            .float(config.logoGlassHighlightSharpness),
            .float(config.logoGlassHighlightAngle),
            .float(config.logoGlassInternalReflection),
            .float(config.logoGlassInternalAngle),
            .float(config.logoGlassPrismAmount)
        )
    }
}

struct GlassShaderView: View {
    @ObservedObject var config: GlassConfig
    let time: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            if let shader = config.logoGlassPrismaticEnabled
                ? MetalShaders.prismaticGlass(size: size, time: time, config: config)
                : MetalShaders.refractiveGlass(size: size, time: time, config: config) {
                Rectangle()
                    .fill(.white)
                    .colorEffect(shader)
            } else {
                SwiftUIGlassFallback(size: size, time: time, config: config)
            }
        }
    }
}

struct SwiftUIGlassFallback: View {
    let size: CGSize
    let time: Double
    let config: GlassConfig

    var body: some View {
        let t = time * config.logoGlassCausticSpeed * 0.3

        ZStack {
            // Base glass clarity
            RadialGradient(
                colors: [
                    .white.opacity(config.logoGlassClarity),
                    .white.opacity(config.logoGlassClarity * 0.8)
                ],
                center: .center,
                startRadius: 0,
                endRadius: size.width * 0.6
            )

            // Fresnel edge effect
            RadialGradient(
                colors: [
                    .clear,
                    .white.opacity(config.logoGlassFresnelIntensity * 0.5)
                ],
                center: .center,
                startRadius: size.width * 0.3,
                endRadius: size.width * 0.6
            )
            .blendMode(.plusLighter)

            // Animated caustic shimmer
            causticLayer(time: t)

            // Specular highlight
            specularHighlight

            // Chromatic aberration hint at edges
            if config.logoGlassChromaticAmount > 0.1 {
                chromaticEdges
            }

            // Prismatic rainbow if enabled
            if config.logoGlassPrismaticEnabled {
                prismaticOverlay(time: t)
            }
        }
    }

    private func causticLayer(time: Double) -> some View {
        let phase = time * 2
        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                let offset = Double(i) * 0.33
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(config.logoGlassCausticIntensity * 0.3), location: 0.3 + sin(phase + offset) * 0.1),
                        .init(color: .clear, location: 0.5),
                        .init(color: .white.opacity(config.logoGlassCausticIntensity * 0.2), location: 0.7 + cos(phase + offset) * 0.1),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: UnitPoint(x: 0.2 + Double(i) * 0.2, y: 0),
                    endPoint: UnitPoint(x: 0.8 - Double(i) * 0.2, y: 1)
                )
                .blendMode(.plusLighter)
            }
        }
    }

    private var specularHighlight: some View {
        let highlightPos = UnitPoint(x: 0.3, y: 0.2)
        return RadialGradient(
            colors: [
                .white.opacity(0.8 / config.logoGlassHighlightSharpness),
                .clear
            ],
            center: highlightPos,
            startRadius: 0,
            endRadius: size.width * (0.15 / config.logoGlassHighlightSharpness)
        )
        .blendMode(.plusLighter)
    }

    private var chromaticEdges: some View {
        ZStack {
            // Red channel offset
            RadialGradient(
                colors: [.clear, .red.opacity(config.logoGlassChromaticAmount * 0.15)],
                center: UnitPoint(x: 0.48, y: 0.5),
                startRadius: size.width * 0.35,
                endRadius: size.width * 0.55
            )
            // Blue channel offset
            RadialGradient(
                colors: [.clear, .blue.opacity(config.logoGlassChromaticAmount * 0.15)],
                center: UnitPoint(x: 0.52, y: 0.5),
                startRadius: size.width * 0.35,
                endRadius: size.width * 0.55
            )
        }
        .blendMode(.plusLighter)
    }

    private func prismaticOverlay(time: Double) -> some View {
        let hue = (time * 0.05).truncatingRemainder(dividingBy: 1.0)
        return AngularGradient(
            stops: [
                .init(color: Color(hue: hue, saturation: 0.8, brightness: 1.0), location: 0.0),
                .init(color: Color(hue: (hue + 0.33).truncatingRemainder(dividingBy: 1.0), saturation: 0.8, brightness: 1.0), location: 0.33),
                .init(color: Color(hue: (hue + 0.66).truncatingRemainder(dividingBy: 1.0), saturation: 0.8, brightness: 1.0), location: 0.66),
                .init(color: Color(hue: hue, saturation: 0.8, brightness: 1.0), location: 1.0)
            ],
            center: .center
        )
        .opacity(config.logoGlassPrismAmount * 0.3)
        .blendMode(.overlay)
    }
}

#endif
