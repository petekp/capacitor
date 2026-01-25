import SwiftUI

// MARK: - Shared Status Indicator

/// Unified status indicator with consistent uppercase monospaced treatment
struct StatusIndicator: View {
    let state: SessionState

    @Environment(\.prefersReducedMotion) private var reduceMotion

    private var statusColor: Color {
        Color.statusColor(for: state)
    }

    private var statusText: String {
        switch state {
        case .ready: "Ready"
        case .working: "Working"
        case .waiting: "Waiting"
        case .compacting: "Compacting"
        case .idle: "Idle"
        }
    }

    private var isActive: Bool {
        state != .idle
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if state == .compacting {
                    AnimatedCompactingText(color: statusColor)
                } else {
                    Text(statusText.uppercased())
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(isActive ? statusColor : statusColor.opacity(0.55))
                        .contentTransition(reduceMotion ? .identity : .numericText())
                }
            }
            .transition(.opacity)

            if state == .working {
                AnimatedEllipsis(color: statusColor)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? AppMotion.reducedMotionFallback : .smooth(duration: 0.3), value: state)
        .accessibilityLabel("Status: \(statusText)")
        .accessibilityValue(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        switch state {
        case .ready: "Ready for input"
        case .working: "Currently working on a task"
        case .waiting: "Waiting for user action"
        case .compacting: "Compacting conversation history"
        case .idle: "Session is idle"
        }
    }
}

// MARK: - Animated Ellipsis

/// Animated ellipsis that cycles through 0-3 dots with fixed width to prevent layout shift
struct AnimatedEllipsis: View {
    let color: Color

    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ellipsisText(dotCount: 3)
        } else {
            TimelineView(.animation) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate / 0.4
                let dotCount = Int(phase.truncatingRemainder(dividingBy: 4))
                ellipsisText(dotCount: dotCount)
            }
        }
    }

    private func ellipsisText(dotCount: Int) -> some View {
        Text(String(repeating: ".", count: dotCount))
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .tracking(-1)
            .foregroundStyle(color)
            .frame(width: 24, alignment: .leading)
            .accessibilityHidden(true)
    }
}

// MARK: - Animated Compacting Text

/// Animated "COMPACTING" text with tracking that compresses and expands
struct AnimatedCompactingText: View {
    let color: Color

    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
        private let config = GlassConfig.shared
    #endif

    var body: some View {
        if reduceMotion {
            staticText
        } else {
            animatedText
        }
    }

    private var staticText: some View {
        Text("COMPACTING")
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(color)
    }

    private var animatedText: some View {
        TimelineView(.animation) { timeline in
            let params = trackingParameters
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: params.cycleLength) / params.cycleLength
            let tracking = computeTracking(phase: phase, params: params)

            Text("COMPACTING")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .tracking(tracking)
                .foregroundStyle(color)
        }
    }

    private var trackingParameters: CompactingTrackingParameters {
        #if DEBUG
            CompactingTrackingParameters(
                cycleLength: config.compactingCycleLength,
                minTracking: config.compactingMinTracking,
                maxTracking: config.compactingMaxTracking,
                compressDuration: config.compactingCompressDuration,
                holdDuration: config.compactingHoldDuration,
                expandDuration: config.compactingExpandDuration,
                compressDamping: config.compactingCompressDamping,
                compressOmega: config.compactingCompressOmega,
                expandDamping: config.compactingExpandDamping,
                expandOmega: config.compactingExpandOmega,
            )
        #else
            CompactingTrackingParameters(
                cycleLength: 1.8,
                minTracking: 0.0,
                maxTracking: 2.1,
                compressDuration: 0.26,
                holdDuration: 0.50,
                expandDuration: 1.0,
                compressDamping: 0.3,
                compressOmega: 16.0,
                expandDamping: 0.8,
                expandOmega: 4.0,
            )
        #endif
    }

    private func computeTracking(phase: Double, params: CompactingTrackingParameters) -> Double {
        let compressEnd = params.compressDuration / params.cycleLength
        let holdEnd = compressEnd + params.holdDuration / params.cycleLength
        let expandEnd = holdEnd + params.expandDuration / params.cycleLength

        if phase < compressEnd {
            let t = phase / compressEnd
            let springValue = dampedSpring(t: t, damping: params.compressDamping, omega: params.compressOmega)
            return params.maxTracking + (params.minTracking - params.maxTracking) * springValue
        } else if phase < holdEnd {
            return params.minTracking
        } else if phase < expandEnd {
            let t = (phase - holdEnd) / (expandEnd - holdEnd)
            let springValue = dampedSpring(t: t, damping: params.expandDamping, omega: params.expandOmega)
            return params.minTracking + (params.maxTracking - params.minTracking) * springValue
        } else {
            return params.maxTracking
        }
    }

    private func dampedSpring(t: Double, damping: Double, omega: Double) -> Double {
        let dampedT = t * omega

        if damping >= 1.0 {
            // Over-damped: smooth exponential approach
            let decay = exp(-damping * dampedT)
            return 1.0 - decay * (1.0 + damping * dampedT)
        } else {
            // Under-damped: slight oscillation/bounce
            let dampedOmega = omega * sqrt(1.0 - damping * damping)
            let decay = exp(-damping * omega * t)
            return 1.0 - decay * (cos(dampedOmega * t) + (damping * omega / dampedOmega) * sin(dampedOmega * t))
        }
    }
}

struct CompactingTrackingParameters {
    let cycleLength: Double
    let minTracking: Double
    let maxTracking: Double
    let compressDuration: Double
    let holdDuration: Double
    let expandDuration: Double
    let compressDamping: Double
    let compressOmega: Double
    let expandDamping: Double
    let expandOmega: Double
}

// MARK: - Shared Context Menu

/// Builds the standard context menu for project cards
struct ProjectContextMenu: View {
    let project: Project
    let onTap: () -> Void
    let onInfoTap: (() -> Void)?
    let onMoveToDormant: () -> Void
    var onCaptureIdea: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        if project.isMissing {
            missingProjectMenu
        } else {
            normalProjectMenu
        }
    }

    @ViewBuilder
    private var missingProjectMenu: some View {
        if let onInfoTap {
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            Divider()
        }
        Button(role: .destructive, action: onRemove) {
            Label("Disconnect", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var normalProjectMenu: some View {
        Button(action: onTap) {
            Label("Open in Terminal", systemImage: "terminal")
        }
        if let onInfoTap {
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
        }
        if let onCaptureIdea {
            Button(action: onCaptureIdea) {
                Label("Capture Idea...", systemImage: "lightbulb")
            }
        }
        Divider()
        Button(action: onMoveToDormant) {
            Label("Hide", systemImage: "eye.slash")
        }
        Button(role: .destructive, action: onRemove) {
            Label("Disconnect", systemImage: "trash")
        }
    }
}

// MARK: - Shared Card Background

/// Parameterized card background supporting both floating and solid modes
struct ProjectCardBackground: View {
    let isHovered: Bool
    var layoutMode: LayoutMode = .vertical

    @Environment(\.floatingMode) private var floatingMode

    #if DEBUG
        var config: GlassConfig?
    #endif

    private var cornerRadius: CGFloat {
        GlassConfig.shared.cardCornerRadius(for: layoutMode)
    }

    var body: some View {
        if floatingMode {
            floatingBackground
        } else {
            solidBackground
        }
    }

    private var floatingBackground: some View {
        #if DEBUG
            if let config {
                DarkFrostedCard(isHovered: isHovered, layoutMode: layoutMode, config: config)
            } else {
                DarkFrostedCard(isHovered: isHovered, layoutMode: layoutMode)
            }
        #else
            DarkFrostedCard(isHovered: isHovered, layoutMode: layoutMode)
        #endif
    }

    private var solidBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.hudCard)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(isHovered ? 0.08 : 0.04), .clear],
                    startPoint: .top,
                    endPoint: .bottom,
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Clickable Project Title

struct ClickableProjectTitle: View {
    let name: String
    let nameColor: Color
    var isMissing: Bool = false
    let action: () -> Void

    var font: Font = AppTypography.cardTitle.monospaced()
    var accessibilityIdentifier: String?

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(name)
                    .font(font)
                    .foregroundStyle(isHovered ? nameColor.opacity(1.0) : nameColor)
                    .strikethrough(isMissing, color: .white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHovered ? 0.6 : 0.35))
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : -4)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
        .help("View project details")
        .accessibilityLabel("View \(name) details")
        .accessibilityHint("Shows description, ideas, and other project information")
    }

    var body: some View {
        if let accessibilityIdentifier {
            button.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            button
        }
    }
}

// MARK: - Shared Badges

/// Stale session badge
struct StaleBadge: View {
    var style: BadgeStyle = .normal

    enum BadgeStyle {
        case normal
        case compact
    }

    var body: some View {
        Text("stale")
            .font(style == .compact ? AppTypography.label : AppTypography.captionSmall.weight(.medium))
            .foregroundStyle(.white.opacity(style == .compact ? 0.4 : 0.5))
            .padding(.horizontal, style == .compact ? 6 : 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(style == .compact ? 0.06 : 0.08))
            .clipShape(Capsule())
            .accessibilityLabel("Stale session")
            .accessibilityHint("This project has been ready for more than 24 hours without activity")
    }
}

// MARK: - Metallic Press Highlight (Metal Shader)

/// GPU-computed metallic specular highlight at press point.
/// Rings propagate outward from the click position as animated ripples.
/// Uses a Metal shader for per-pixel concentric rings, 8-fold anisotropy,
/// and warm→cool chromatic shift — effects that can't be done with SwiftUI gradients.
///
/// **Fire-and-forget**: the ripple fires on click and decays over `duration`.
/// It does NOT depend on press/hold state — mouseUp doesn't affect it.
///
/// **Vibrancy mode**: When enabled, the shader output masks a `VibrancyView` so the
/// ripple is "made of" frosted glass — desktop content bleeds through the pattern.
struct MetallicPressHighlight: View {
    let pressPoint: CGPoint
    let cardSize: CGSize
    let cornerRadius: CGFloat
    let intensity: Double
    /// Reference date when the press began (drives ripple animation).
    let pressStartTime: Date?

    #if DEBUG
        private let config = GlassConfig.shared
    #endif

    private var blendMode: BlendMode {
        #if DEBUG
            Self.blendModeFromInt(config.highlightBlendMode)
        #else
            .overlay
        #endif
    }

    #if DEBUG
        private var useVibrancy: Bool {
            config.highlightUseVibrancy
        }

        private var vibrancyMaterial: NSVisualEffectView.Material {
            switch config.highlightVibrancyMaterial {
            case 0: .hudWindow
            case 1: .popover
            case 2: .menu
            case 3: .sidebar
            case 4: .fullScreenUI
            default: .popover
            }
        }
    #endif

    static func blendModeFromInt(_ value: Int) -> BlendMode {
        switch value {
        case 0: .normal
        case 1: .plusLighter
        case 2: .softLight
        case 3: .overlay
        case 4: .screen
        case 5: .colorDodge
        case 6: .hardLight
        default: .overlay
        }
    }

    var body: some View {
        if pressStartTime != nil {
            TimelineView(.animation(minimumInterval: nil, paused: false)) { timeline in
                let library = ShaderCache.library
                let elapsed = pressStartTime.map { timeline.date.timeIntervalSince($0) } ?? 0

                #if DEBUG
                    let ringFreq = config.highlightRingFrequency
                    let ringSharp = config.highlightRingSharpness
                    let falloff = config.highlightFalloff
                    let specTight = config.highlightSpecularTightness
                    let specWeight = config.highlightSpecularWeight
                    let ringWeight = config.highlightRingWeight
                    let speed = config.highlightRippleSpeed
                    let duration = config.highlightRippleDuration
                #else
                    let ringFreq = 1.00
                    let ringSharp = 1.13
                    let falloff = 0.10
                    let specTight = 8.60
                    let specWeight = 1.33
                    let ringWeight = 0.84
                    let speed = 9.06
                    let duration = 0.63
                #endif

                let fade = max(0, 1.0 - elapsed / max(duration, 0.01))
                let effectiveIntensity = intensity * fade

                let shaderMask = Color.white
                    .colorEffect(
                        library.metallicPress(
                            .float2(pressPoint.x, pressPoint.y),
                            .float2(cardSize.width, cardSize.height),
                            .float(effectiveIntensity),
                            .float(ringFreq),
                            .float(ringSharp),
                            .float(falloff),
                            .float(specTight),
                            .float(specWeight),
                            .float(ringWeight),
                            .float(max(elapsed, 0)),
                            .float(speed),
                        ),
                    )
                    .opacity(fade)

                #if DEBUG
                    if useVibrancy {
                        VibrancyView(
                            material: vibrancyMaterial,
                            blendingMode: .behindWindow,
                            isEmphasized: false,
                            forceDarkAppearance: true,
                        )
                        .mask { shaderMask }
                    } else {
                        shaderMask
                    }
                #else
                    shaderMask
                #endif
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .blendMode(blendMode)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Press Distortion Modifier

/// Simulates a physical surface flex at the press point using SwiftUI geometry transforms.
/// Metal layerEffect/distortionEffect don't work from custom metallibs (SPM or bundle) —
/// SwiftUI renders the effect but overlays a yellow error indicator regardless of loading path.
/// Pure SwiftUI projectionEffect achieves the same visual without the limitation.
struct PressDistortionModifier: ViewModifier {
    let pressPoint: CGPoint
    let cardSize: CGSize
    let intensity: Double

    #if DEBUG
        private let config = GlassConfig.shared
    #endif

    func body(content: Content) -> some View {
        if intensity > 0, cardSize.width > 0, cardSize.height > 0 {
            #if DEBUG
                let skewMult = config.distortionMaxSkew
                let insetMult = config.distortionScaleInset
                let dirScale = config.distortionDirectionalScale
                let anchorOff = config.distortionAnchorOffset
            #else
                let skewMult = 0.0
                let insetMult = 0.0
                let dirScale = 0.0
                let anchorOff = 0.07
            #endif

            let nx = (pressPoint.x / cardSize.width - 0.5) * 2
            let ny = (pressPoint.y / cardSize.height - 0.5) * 2

            let maxSkew: CGFloat = skewMult * intensity
            let scaleInset: CGFloat = 1.0 - insetMult * intensity

            content
                .scaleEffect(
                    x: 1.0 + (1.0 - abs(nx)) * dirScale * intensity,
                    y: 1.0 + (1.0 - abs(ny)) * dirScale * intensity,
                    anchor: UnitPoint(
                        x: 0.5 + nx * anchorOff,
                        y: 0.5 + ny * anchorOff,
                    ),
                )
                .projectionEffect(ProjectionTransform(CGAffineTransform(
                    a: scaleInset, b: ny * maxSkew,
                    c: nx * maxSkew, d: scaleInset,
                    tx: 0, ty: 0,
                )))
        } else {
            content
        }
    }
}

extension View {
    func pressDistortion(pressPoint: CGPoint, cardSize: CGSize, intensity: Double) -> some View {
        modifier(PressDistortionModifier(pressPoint: pressPoint, cardSize: cardSize, intensity: intensity))
    }
}

// MARK: - Shader Cache

/// Pre-compiled Metal shader library loaded via ShaderLibrary.bundle().
/// restart-app.sh compiles Shaders/*.metal → Resources/Shaders/default.metallib.
/// Using .bundle() (not .url()) because .url() breaks layerEffect/distortionEffect
/// at runtime — SwiftUI shows yellow/not-allowed even when the effect renders.
/// .bundle() uses the same code path as Xcode-compiled shaders.
enum ShaderCache {
    static let library: ShaderLibrary = {
        let bundle = ResourceBundle.bundle ?? Bundle.main
        return .bundle(bundle)
    }()
}

/// Blocker indicator badge
struct BlockerBadge: View {
    var style: BadgeStyle = .normal

    enum BadgeStyle {
        case normal
        case compact
    }

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(style == .compact ? AppTypography.label : AppTypography.captionSmall)
            .foregroundStyle(.orange)
    }
}
