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
        case .ready: return "Ready"
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .compacting: return "Compacting"
        case .idle: return "Idle"
        }
    }

    private var isActive: Bool {
        state != .idle
    }

    var body: some View {
        HStack(spacing: 0) {
            if state == .compacting {
                AnimatedCompactingText(color: statusColor)
            } else {
                Text(statusText.uppercased())
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .tracking(0.5)
                    .foregroundColor(isActive ? statusColor : statusColor.opacity(0.55))
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }

            if state == .working {
                AnimatedEllipsis(color: statusColor)
            }
        }
        .animation(reduceMotion ? AppMotion.reducedMotionFallback : .smooth(duration: 0.3), value: state)
        .accessibilityLabel("Status: \(statusText)")
        .accessibilityValue(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        switch state {
        case .ready: return "Ready for input"
        case .working: return "Currently working on a task"
        case .waiting: return "Waiting for user action"
        case .compacting: return "Compacting conversation history"
        case .idle: return "Session is idle"
        }
    }
}

// MARK: - Animated Ellipsis

/// Animated ellipsis that cycles through 0-3 dots with fixed width to prevent layout shift
struct AnimatedEllipsis: View {
    let color: Color

    @State private var dotCount = 0
    @Environment(\.prefersReducedMotion) private var reduceMotion

    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(repeating: ".", count: dotCount))
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .tracking(-1)
            .foregroundColor(color)
            .frame(width: 24, alignment: .leading)
            .onReceive(timer) { _ in
                guard !reduceMotion else { return }
                dotCount = (dotCount + 1) % 4
            }
            .onAppear {
                if reduceMotion {
                    dotCount = 3
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Animated Compacting Text

/// Animated "COMPACTING" text with tracking that compresses and expands
struct AnimatedCompactingText: View {
    let color: Color

    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
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
            .tracking(0.5)
            .foregroundColor(color)
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
                .foregroundColor(color)
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
            expandOmega: config.compactingExpandOmega
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
            expandOmega: 4.0
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
    let onInfoTap: () -> Void
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
        Button(action: onInfoTap) {
            Label("View Details", systemImage: "info.circle")
        }
        Divider()
        Button(role: .destructive, action: onRemove) {
            Label("Remove from HUD", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var normalProjectMenu: some View {
        Button(action: onTap) {
            Label("Open in Terminal", systemImage: "terminal")
        }
        Button(action: onInfoTap) {
            Label("View Details", systemImage: "info.circle")
        }
        if let onCaptureIdea = onCaptureIdea {
            Button(action: onCaptureIdea) {
                Label("Capture Idea...", systemImage: "lightbulb")
            }
        }
        Divider()
        Button(action: onMoveToDormant) {
            Label("Move to Paused", systemImage: "moon.zzz")
        }
        Button(role: .destructive, action: onRemove) {
            Label("Remove from HUD", systemImage: "trash")
        }
    }
}

// MARK: - Shared Card Background

/// Parameterized card background supporting both floating and solid modes
struct ProjectCardBackground: View {
    let isHovered: Bool
    var cornerRadius: CGFloat = 12

    @Environment(\.floatingMode) private var floatingMode

    #if DEBUG
    var config: GlassConfig?
    #endif

    var body: some View {
        if floatingMode {
            floatingBackground
        } else {
            solidBackground
        }
    }

    private var floatingBackground: some View {
        #if DEBUG
        if let config = config {
            DarkFrostedCard(isHovered: isHovered, config: config)
        } else {
            DarkFrostedCard(isHovered: isHovered)
        }
        #else
        DarkFrostedCard(isHovered: isHovered)
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
                    endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isHovered ? 0.18 : 0.1),
                            .white.opacity(isHovered ? 0.08 : 0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
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

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(name)
                    .font(font)
                    .foregroundColor(isHovered ? nameColor.opacity(1.0) : nameColor)
                    .strikethrough(isMissing, color: .white.opacity(0.3))

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(isHovered ? 0.6 : 0.35))
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
            .foregroundColor(.white.opacity(style == .compact ? 0.4 : 0.5))
            .padding(.horizontal, style == .compact ? 6 : 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(style == .compact ? 0.06 : 0.08))
            .clipShape(Capsule())
            .accessibilityLabel("Stale session")
            .accessibilityHint("This project has been ready for more than 24 hours without activity")
    }
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
            .foregroundColor(.orange)
    }
}
