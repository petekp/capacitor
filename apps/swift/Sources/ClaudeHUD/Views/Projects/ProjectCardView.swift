import SwiftUI

// MARK: - Main Card View

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let devServerPort: UInt16?
    let isStale: Bool
    let todoStatus: (completed: Int, total: Int)?
    let isActive: Bool
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToDormant: () -> Void
    let onOpenBrowser: () -> Void
    var onCaptureIdea: (() -> Void)?
    var onRemove: (() -> Void)?
    var onDragStarted: (() -> NSItemProvider)?

    @Environment(\.floatingMode) private var floatingMode
    #if DEBUG
    @ObservedObject private var glassConfig = GlassConfig.shared
    #endif

    @State private var isHovered = false
    @State private var flashOpacity: Double = 0
    @State private var isInfoHovered = false
    @State private var isBrowserHovered = false
    @State private var previousState: SessionState?
    @State private var lastChimeTime: Date?
    @State private var lastKnownSummary: String?

    private let chimeCooldown: TimeInterval = 3.0

    // MARK: - Computed Properties

    private var currentState: SessionState? {
        #if DEBUG
        switch glassConfig.previewState {
        case .none: return sessionState?.state
        case .ready: return .ready
        case .working: return .working
        case .waiting: return .waiting
        case .compacting: return .compacting
        case .idle: return .idle
        }
        #else
        return sessionState?.state
        #endif
    }

    private var isReady: Bool {
        currentState == .ready
    }

    private var nameColor: Color {
        project.isMissing ? .white.opacity(0.5) : .white.opacity(0.9)
    }

    private var displaySummary: String? {
        // If there's a current summary, use it. Otherwise fall back to last known summary.
        if let current = sessionState?.workingOn, !current.isEmpty {
            return current
        }
        return lastKnownSummary
    }

    #if DEBUG
    private var glassConfigForHandlers: GlassConfig? {
        glassConfig
    }
    #else
    private var glassConfigForHandlers: Any? {
        nil
    }
    #endif

    // MARK: - Body

    var body: some View {
        WindowDragDisabled {
            cardContent
                .cardStyling(
                    isHovered: isHovered,
                    isReady: isReady,
                    isActive: isActive,
                    flashState: flashState,
                    flashOpacity: flashOpacity,
                    floatingMode: floatingMode,
                    floatingCardBackground: floatingCardBackground,
                    solidCardBackground: solidCardBackground,
                    animationSeed: project.path
                )
                .cardInteractions(
                    isHovered: $isHovered,
                    onTap: onTap,
                    onDragStarted: onDragStarted
                )
                .cardLifecycleHandlers(
                    flashState: flashState,
                    sessionState: sessionState,
                    currentState: currentState,
                    previousState: $previousState,
                    lastChimeTime: $lastChimeTime,
                    flashOpacity: $flashOpacity,
                    chimeCooldown: chimeCooldown,
                    glassConfig: glassConfigForHandlers
                )
                .contextMenu { cardContextMenu }
                .onChange(of: sessionState?.workingOn) { _, newValue in
                    // Store the last known summary when it changes
                    if let summary = newValue, !summary.isEmpty {
                        lastKnownSummary = summary
                    }
                }
        }
    }

    // MARK: - Card Content

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProjectCardHeader(
                project: project,
                isStale: isStale,
                todoStatus: todoStatus,
                devServerPort: devServerPort,
                currentState: currentState,
                nameColor: nameColor,
                isHovered: isHovered,
                isInfoHovered: $isInfoHovered,
                isBrowserHovered: $isBrowserHovered,
                onInfoTap: onInfoTap,
                onOpenBrowser: onOpenBrowser
            )

            ProjectCardContent(
                workingOn: displaySummary,
                blocker: projectStatus?.blocker,
                isWorking: currentState == .working
            )
        }
        .padding(12)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: displaySummary)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: projectStatus?.blocker)
    }

    // MARK: - Context Menu

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
            if let onCaptureIdea = onCaptureIdea {
                Button(action: onCaptureIdea) {
                    Label("Capture Idea...", systemImage: "lightbulb")
                }
            }
            Divider()
            Button(action: onMoveToDormant) {
                Label("Move to Paused", systemImage: "moon.zzz")
            }
        }
    }

    // MARK: - Background Styles

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

// MARK: - Card Header Component

private struct ProjectCardHeader: View {
    let project: Project
    let isStale: Bool
    let todoStatus: (completed: Int, total: Int)?
    let devServerPort: UInt16?
    let currentState: SessionState?
    let nameColor: Color
    let isHovered: Bool
    @Binding var isInfoHovered: Bool
    @Binding var isBrowserHovered: Bool
    let onInfoTap: () -> Void
    let onOpenBrowser: () -> Void

    var body: some View {
        HStack {
            if project.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }

            Text(project.name)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(nameColor)
                .strikethrough(project.isMissing, color: .white.opacity(0.3))

            if isStale {
                StaleBadge()
            }

            if let status = todoStatus, status.total > 0 {
                TodoBadge(completed: status.completed, total: status.total)
            }

            InfoButton(
                isHovered: isHovered,
                isInfoHovered: $isInfoHovered,
                action: onInfoTap
            )

            Spacer()

            if let port = devServerPort {
                DevServerButton(
                    port: port,
                    isHovered: isHovered,
                    isBrowserHovered: $isBrowserHovered,
                    action: onOpenBrowser
                )
            }

            if let state = currentState {
                StatusIndicatorView(state: state)
            }
        }
    }
}

// MARK: - Card Content Component

private struct ProjectCardContent: View {
    let workingOn: String?
    let blocker: String?
    let isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let workingOn = workingOn, !workingOn.isEmpty {
                TickerText(text: workingOn, isShimmering: isWorking)
            }

            if let blocker = blocker, !blocker.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(blocker)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Ticker Text Component

private struct TickerText: View {
    let text: String
    let isShimmering: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(.white.opacity(0.6))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
            .overlay {
                if isShimmering {
                    ShimmerEffect()
                        .mask(
                            Text(text)
                                .font(.system(size: 12, weight: .regular))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        )
                }
            }
            .id(text)
    }
}

// MARK: - Shimmer Effect

private struct ShimmerEffect: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0), location: phase - 0.2),
                    .init(color: .white.opacity(0.4), location: phase),
                    .init(color: .white.opacity(0), location: phase + 0.2),
                    .init(color: .white.opacity(0), location: 1)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .onAppear {
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
        }
    }
}

// MARK: - Reusable Button Components

private struct InfoButton: View {
    let isHovered: Bool
    @Binding var isInfoHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
    }
}

private struct DevServerButton: View {
    let port: UInt16
    let isHovered: Bool
    @Binding var isBrowserHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
}

private struct StaleBadge: View {
    var body: some View {
        Text("stale")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white.opacity(0.5))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
    }
}

// MARK: - View Modifiers

extension View {
    func cardStyling(
        isHovered: Bool,
        isReady: Bool,
        isActive: Bool,
        flashState: SessionState?,
        flashOpacity: Double,
        floatingMode: Bool,
        floatingCardBackground: some View,
        solidCardBackground: some View,
        animationSeed: String
    ) -> some View {
        self
            .background {
                if floatingMode {
                    floatingCardBackground
                        #if DEBUG
                        .id(GlassConfig.shared.cardConfigHash)
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
                // Active project border with vibrancy
                if isActive {
                    ZStack {
                        // Outer glow for vibrancy
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                Color.white.opacity(0.3),
                                lineWidth: 3
                            )
                            .blur(radius: 4)

                        // Sharp inner border
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                Color.white.opacity(0.8),
                                lineWidth: 1.5
                            )
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
            .overlay {
                if isReady {
                    ReadyAmbientGlow()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .overlay {
                if isReady {
                    ReadyBorderGlow(seed: animationSeed)
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .shadow(
                color: floatingMode ? .black.opacity(0.25) : (isHovered ? .black.opacity(0.2) : .black.opacity(0.08)),
                radius: floatingMode ? 8 : (isHovered ? 12 : 4),
                y: floatingMode ? 3 : (isHovered ? 4 : 2)
            )
            .scaleEffect(isHovered ? 0.99 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovered)
    }

    func cardInteractions(
        isHovered: Binding<Bool>,
        onTap: @escaping () -> Void,
        onDragStarted: (() -> NSItemProvider)?
    ) -> some View {
        self
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.2)) {
                    isHovered.wrappedValue = hovering
                }
            }
            .onDrag {
                _ = onDragStarted?()
                return NSItemProvider(object: "" as NSString)
            } preview: {
                Color.clear.frame(width: 1, height: 1)
            }
    }

    #if DEBUG
    func cardLifecycleHandlers(
        flashState: SessionState?,
        sessionState: ProjectSessionState?,
        currentState: SessionState?,
        previousState: Binding<SessionState?>,
        lastChimeTime: Binding<Date?>,
        flashOpacity: Binding<Double>,
        chimeCooldown: TimeInterval,
        glassConfig: GlassConfig?
    ) -> some View {
        self
            .animation(.easeInOut(duration: 0.4), value: sessionState?.state)
            .onChange(of: flashState) { _, newValue in
                guard newValue != nil else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    flashOpacity.wrappedValue = 1.0
                }
                withAnimation(.easeOut(duration: 1.3).delay(0.1)) {
                    flashOpacity.wrappedValue = 0
                }
            }
            .onChange(of: sessionState?.state) { oldValue, newValue in
                if glassConfig?.previewState != .none { return }

                if newValue == .ready && oldValue != .ready && oldValue != nil {
                    let now = Date()
                    let shouldPlayChime = lastChimeTime.wrappedValue.map { now.timeIntervalSince($0) >= chimeCooldown } ?? true
                    if shouldPlayChime {
                        lastChimeTime.wrappedValue = now
                        ReadyChime.shared.play()
                    }
                }
                previousState.wrappedValue = newValue
            }
            .onChange(of: glassConfig?.previewState) { oldValue, newValue in
                if newValue == .ready && oldValue != .ready {
                    ReadyChime.shared.play()
                }
            }
            .onAppear {
                previousState.wrappedValue = sessionState?.state
            }
    }
    #else
    func cardLifecycleHandlers(
        flashState: SessionState?,
        sessionState: ProjectSessionState?,
        currentState: SessionState?,
        previousState: Binding<SessionState?>,
        lastChimeTime: Binding<Date?>,
        flashOpacity: Binding<Double>,
        chimeCooldown: TimeInterval,
        glassConfig: Any?
    ) -> some View {
        self
            .animation(.easeInOut(duration: 0.4), value: sessionState?.state)
            .onChange(of: flashState) { _, newValue in
                guard newValue != nil else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    flashOpacity.wrappedValue = 1.0
                }
                withAnimation(.easeOut(duration: 1.3).delay(0.1)) {
                    flashOpacity.wrappedValue = 0
                }
            }
            .onChange(of: sessionState?.state) { oldValue, newValue in
                if newValue == .ready && oldValue != .ready && oldValue != nil {
                    let now = Date()
                    let shouldPlayChime = lastChimeTime.wrappedValue.map { now.timeIntervalSince($0) >= chimeCooldown } ?? true
                    if shouldPlayChime {
                        lastChimeTime.wrappedValue = now
                        ReadyChime.shared.play()
                    }
                }
                previousState.wrappedValue = newValue
            }
            .onAppear {
                previousState.wrappedValue = sessionState?.state
            }
    }
    #endif
}

// MARK: - Ready State Glow Effects

struct ReadyAmbientGlow: View {
    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    var body: some View {
        TimelineView(.animation) { timeline in
            let params = glowParameters
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: params.speed) / params.speed

            GeometryReader { geometry in
                let originX = geometry.size.width * params.originXPercent
                let originY = geometry.size.height * params.originYPercent
                let maxRadius = max(geometry.size.width, geometry.size.height) * 1.8

                Canvas { context, size in
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

private struct GlowParameters {
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

    #if DEBUG
    @ObservedObject private var config = GlassConfig.shared
    #endif

    private var timeOffset: Double {
        // Generate a stable random offset from the seed (0 to 10 seconds)
        var hasher = Hasher()
        hasher.combine(seed)
        let hash = abs(hasher.finalize())
        return Double(hash % 10000) / 1000.0
    }

    var body: some View {
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

private struct ReadyBorderGlowContent: View {
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

private struct BorderGlowParameters {
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

// MARK: - Status Indicator

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

// MARK: - Badge Components

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

// MARK: - Unused Legacy Components (kept for compatibility)

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
