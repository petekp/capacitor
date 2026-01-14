import SwiftUI

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let devServerPort: UInt16?
    let isStale: Bool
    let todoStatus: (completed: Int, total: Int)?
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToDormant: () -> Void
    let onOpenBrowser: () -> Void
    var onRemove: (() -> Void)?

    @Environment(\.floatingMode) private var floatingMode
    #if DEBUG
    @ObservedObject private var glassConfig = GlassConfig.shared
    #endif
    @State private var isHovered = false
    @State private var isPressed = false
    @State private var flashOpacity: Double = 0
    @State private var isInfoHovered = false
    @State private var isBrowserHovered = false

    @State private var previousState: SessionState?
    @State private var lastChimeTime: Date?

    private let chimeCooldown: TimeInterval = 3.0

    private var nameColor: Color {
        project.isMissing ? .white.opacity(0.5) : .white.opacity(0.9)
    }

    #if DEBUG
    private var displayState: SessionState? {
        switch glassConfig.previewState {
        case .none:
            return sessionState?.state
        case .ready:
            return .ready
        case .working:
            return .working
        case .waiting:
            return .waiting
        case .compacting:
            return .compacting
        case .idle:
            return .idle
        }
    }
    #endif

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if project.isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }

                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(nameColor)
                        .strikethrough(project.isMissing, color: .white.opacity(0.3))

                    if isStale {
                        Text("stale")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }

                    if let status = todoStatus, status.total > 0 {
                        TodoBadge(completed: status.completed, total: status.total)
                    }

                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(isInfoHovered ? 0.7 : (isHovered ? 0.35 : 0.2)))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isInfoHovered = hovering
                        }
                    }
                    .help("View details")

                    Spacer()

                    if let port = devServerPort {
                        Button(action: onOpenBrowser) {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                    .font(.system(size: 11))
                                Text(":\(String(port))")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(.white.opacity(isBrowserHovered ? 0.85 : (isHovered ? 0.55 : 0.35)))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(isBrowserHovered ? 0.12 : (isHovered ? 0.06 : 0.03)))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(isBrowserHovered ? 0.15 : 0), lineWidth: 0.5)
                            )
                            .scaleEffect(isBrowserHovered ? 1.02 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                isBrowserHovered = hovering
                            }
                        }
                        .help("Open localhost:\(port) in browser")
                    }

                    #if DEBUG
                    if let state = displayState {
                        StatusIndicatorView(state: state)
                    }
                    #else
                    if let state = sessionState {
                        StatusIndicatorView(state: state.state)
                    }
                    #endif
                }

                if let workingOn = sessionState?.workingOn, !workingOn.isEmpty {
                    Text(workingOn)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }

                if let blocker = projectStatus?.blocker, !blocker.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(blocker)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
                }
            }
            .padding(12)
            .background {
                if floatingMode {
                    floatingCardBackground
                        #if DEBUG
                        .id(glassConfig.cardConfigHash)
                        #endif
                } else {
                    solidCardBackground
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(flashState.map { Color.flashColor(for: $0) } ?? .clear, lineWidth: 2)
                    .opacity(flashOpacity)
            )
            .overlay {
                #if DEBUG
                let isReady = displayState == .ready
                #else
                let isReady = sessionState?.state == .ready
                #endif

                if isReady {
                    ReadyAmbientGlow()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .overlay {
                #if DEBUG
                let isReady = displayState == .ready
                #else
                let isReady = sessionState?.state == .ready
                #endif

                if isReady {
                    ReadyBorderGlow()
                }
            }
            .shadow(
                color: floatingMode ? .black.opacity(0.25) : (isHovered ? .black.opacity(0.2) : .black.opacity(0.08)),
                radius: floatingMode ? 8 : (isHovered ? 12 : 4),
                y: floatingMode ? 3 : (isHovered ? 4 : 2)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.snappy(duration: 0.15), value: isPressed)
            .animation(.easeOut(duration: 0.2), value: isHovered)
        }
        .buttonStyle(PressableButtonStyle(isPressed: $isPressed))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onChange(of: flashState) { oldValue, newValue in
            if newValue != nil {
                withAnimation(.easeOut(duration: 0.1)) {
                    flashOpacity = 1.0
                }
                withAnimation(.easeOut(duration: 1.3).delay(0.1)) {
                    flashOpacity = 0
                }
            }
        }
        .onChange(of: sessionState?.state) { oldValue, newValue in
            #if DEBUG
            if glassConfig.previewState != .none { return }
            #endif
            if newValue == .ready && oldValue != .ready && oldValue != nil {
                let now = Date()
                let shouldPlayChime = lastChimeTime.map { now.timeIntervalSince($0) >= chimeCooldown } ?? true
                if shouldPlayChime {
                    lastChimeTime = now
                    ReadyChime.shared.play()
                }
            }
            previousState = newValue
        }
        #if DEBUG
        .onChange(of: glassConfig.previewState) { oldValue, newValue in
            if newValue == .ready && oldValue != .ready {
                ReadyChime.shared.play()
            }
        }
        #endif
        .onAppear {
            previousState = sessionState?.state
        }
        .contextMenu { cardContextMenu }
    }

    @ViewBuilder
    private var cardContextMenu: some View {
        if project.isMissing {
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            Divider()
            if let onRemove = onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Missing Project", systemImage: "trash")
                }
            }
        } else {
            Button(action: onTap) {
                Label("Open in Terminal", systemImage: "terminal")
            }
            if devServerPort != nil {
                Button(action: onOpenBrowser) {
                    Label("Open in Browser", systemImage: "globe")
                }
            }
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onMoveToDormant) {
                Label("Move to Paused", systemImage: "moon.zzz")
            }
        }
    }

    private var floatingCardBackground: some View {
        #if DEBUG
        DarkFrostedCard(isHovered: isHovered, config: glassConfig)
        #else
        DarkFrostedCard(isHovered: isHovered)
        #endif
    }

    private var solidCardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
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
            .clipShape(RoundedRectangle(cornerRadius: 12))

            RoundedRectangle(cornerRadius: 12)
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

struct ReadyAmbientGlow: View {
    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    var body: some View {
        TimelineView(.animation) { timeline in
            #if DEBUG
            let speed = config.rippleSpeed
            let count = config.rippleCount
            let maxOpacity = config.rippleMaxOpacity
            let lineWidth = config.rippleLineWidth
            let blurAmount = config.rippleBlurAmount
            let originXPercent = config.rippleOriginX
            let originYPercent = config.rippleOriginY
            let fadeInZone = config.rippleFadeInZone
            let fadeOutPower = config.rippleFadeOutPower
            #else
            let speed: Double = 4.9
            let count: Int = 4
            let maxOpacity: Double = 1.00
            let lineWidth: Double = 30.0
            let blurAmount: Double = 41.5
            let originXPercent: Double = 0.89
            let originYPercent: Double = 0.00
            let fadeInZone: Double = 0.10
            let fadeOutPower: Double = 4.0
            #endif

            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: speed) / speed

            GeometryReader { geometry in
                let originX = geometry.size.width * originXPercent
                let originY = geometry.size.height * originYPercent
                let maxRadius = max(geometry.size.width, geometry.size.height) * 1.8

                Canvas { context, size in
                    for i in 0..<count {
                        let stagger = Double(i) / Double(count)
                        let ringPhase = (phase + stagger).truncatingRemainder(dividingBy: 1.0)
                        let radius = maxRadius * ringPhase

                        let fadeIn: Double
                        if fadeInZone > 0 {
                            let rawFadeIn = min(ringPhase / fadeInZone, 1.0)
                            fadeIn = smoothstep(rawFadeIn)
                        } else {
                            fadeIn = 1.0
                        }

                        let fadeOut = pow(1.0 - ringPhase, fadeOutPower)
                        let opacity = maxOpacity * fadeIn * fadeOut

                        let lineWidthFadeIn = fadeInZone > 0 ? min(ringPhase / fadeInZone, 1.0) : 1.0
                        let effectiveLineWidth = lineWidth * smoothstep(lineWidthFadeIn)

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
                .blur(radius: blurAmount)
            }
        }
        .allowsHitTesting(false)
    }

    private func smoothstep(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return clamped * clamped * (3 - 2 * clamped)
    }
}

struct ReadyBorderGlow: View {
    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    var body: some View {
        #if DEBUG
        TimelineView(.animation) { timeline in
            ReadyBorderGlowContent(date: timeline.date, config: config)
        }
        .allowsHitTesting(false)
        #else
        TimelineView(.animation) { timeline in
            ReadyBorderGlowContent(date: timeline.date)
        }
        .allowsHitTesting(false)
        #endif
    }
}

#if DEBUG
private struct ReadyBorderGlowContent: View {
    let date: Date
    let config: GlassConfig

    var body: some View {
        let speed = config.rippleSpeed
        let count = config.rippleCount
        let fadeInZone = config.rippleFadeInZone
        let fadeOutPower = config.rippleFadeOutPower
        let rotationMult = config.borderGlowRotationMultiplier
        let baseOp = config.borderGlowBaseOpacity
        let pulseIntensity = config.borderGlowPulseIntensity
        let innerWidth = config.borderGlowInnerWidth
        let outerWidth = config.borderGlowOuterWidth
        let innerBlur = config.borderGlowInnerBlur
        let outerBlur = config.borderGlowOuterBlur

        let time = date.timeIntervalSinceReferenceDate
        let phase = time.truncatingRemainder(dividingBy: speed) / speed
        let rotationPeriod = speed / rotationMult
        let rotationAngle = Angle(degrees: time.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod * 360)

        let combinedIntensity = computeIntensity(phase: phase, count: count, fadeInZone: fadeInZone, fadeOutPower: fadeOutPower)
        let baseOpacity = baseOp + combinedIntensity * pulseIntensity

        borderGlowStack(
            baseOpacity: baseOpacity,
            rotationAngle: rotationAngle,
            innerWidth: innerWidth,
            outerWidth: outerWidth,
            innerBlur: innerBlur,
            outerBlur: outerBlur
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
#else
private struct ReadyBorderGlowContent: View {
    let date: Date

    var body: some View {
        let speed: Double = 4.9
        let count: Int = 4
        let fadeInZone: Double = 0.10
        let fadeOutPower: Double = 4.0
        let rotationMult: Double = 0.50
        let baseOp: Double = 0.30
        let pulseIntensity: Double = 0.50
        let innerWidth: Double = 0.49
        let outerWidth: Double = 2.88
        let innerBlur: Double = 0.5
        let outerBlur: Double = 1.5

        let time = date.timeIntervalSinceReferenceDate
        let phase = time.truncatingRemainder(dividingBy: speed) / speed
        let rotationPeriod = speed / rotationMult
        let rotationAngle = Angle(degrees: time.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod * 360)

        let combinedIntensity = computeIntensity(phase: phase, count: count, fadeInZone: fadeInZone, fadeOutPower: fadeOutPower)
        let baseOpacity = baseOp + combinedIntensity * pulseIntensity

        borderGlowStack(
            baseOpacity: baseOpacity,
            rotationAngle: rotationAngle,
            innerWidth: innerWidth,
            outerWidth: outerWidth,
            innerBlur: innerBlur,
            outerBlur: outerBlur
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
#endif

struct StatusIndicatorView: View {
    let state: SessionState

    var statusColor: Color {
        Color.statusColor(for: state)
    }

    var statusText: String {
        switch state {
        case .ready: return "Ready"
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .compacting: return "Compacting"
        case .idle: return "Idle"
        }
    }

    var isActive: Bool {
        state != .idle
    }

    var body: some View {
        Text(statusText)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isActive ? statusColor : statusColor.opacity(0.55))
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.3), value: state)
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

struct HealthBadge: View {
    let project: Project
    @State private var showingPopover = false

    private var healthResult: HealthScoreResult {
        ClaudeMdHealthScorer.score(content: project.claudeMdPreview)
    }

    private var badgeColor: Color {
        switch healthResult.grade {
        case .a: return Color(hue: 0.35, saturation: 0.7, brightness: 0.75)
        case .b: return Color(hue: 0.28, saturation: 0.6, brightness: 0.8)
        case .c: return Color(hue: 0.12, saturation: 0.6, brightness: 0.85)
        case .d: return Color(hue: 0.06, saturation: 0.6, brightness: 0.85)
        case .f: return Color(hue: 0.0, saturation: 0.6, brightness: 0.75)
        case .none: return Color.white.opacity(0.3)
        }
    }

    var body: some View {
        if project.claudeMdPath != nil {
            Button(action: { showingPopover.toggle() }) {
                Text(healthResult.grade.rawValue)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(badgeColor)
                    .frame(width: 14, height: 14)
                    .background(badgeColor.opacity(0.15))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(badgeColor.opacity(0.3), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("CLAUDE.md health: \(healthResult.grade.rawValue) (\(healthResult.score)/100) - Click for details")
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                HealthDetailPopover(result: healthResult, projectPath: project.claudeMdPath ?? "")
            }
        }
    }
}

struct HealthDetailPopover: View {
    let result: HealthScoreResult
    let projectPath: String
    @State private var copiedTemplate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CLAUDE.md Health")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(result.score)/\(result.maxScore)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Divider()

            ForEach(result.details, id: \.name) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundColor(check.passed ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.name)
                            .font(.system(size: 11, weight: .medium))

                        if !check.passed, let suggestion = check.suggestion {
                            Text(suggestion)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        if !check.passed, let template = check.template {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(template, forType: .string)
                                copiedTemplate = check.name
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    if copiedTemplate == check.name {
                                        copiedTemplate = nil
                                    }
                                }
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: copiedTemplate == check.name ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9))
                                    Text(copiedTemplate == check.name ? "Copied!" : "Copy template")
                                        .font(.system(size: 9))
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    Text("+\(check.points)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(check.passed ? .green : .secondary.opacity(0.5))
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}

struct TodoBadge: View {
    let completed: Int
    let total: Int

    private var isAllDone: Bool {
        completed == total && total > 0
    }

    private var badgeColor: Color {
        if isAllDone {
            return Color(hue: 0.35, saturation: 0.6, brightness: 0.75)
        } else if completed > 0 {
            return Color(hue: 0.12, saturation: 0.5, brightness: 0.8)
        } else {
            return Color.white.opacity(0.4)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: isAllDone ? "checkmark.circle.fill" : "checklist")
                .font(.system(size: 8))
            Text("\(completed)/\(total)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(badgeColor.opacity(0.12))
        .clipShape(Capsule())
        .help("\(completed) of \(total) tasks completed")
    }
}
