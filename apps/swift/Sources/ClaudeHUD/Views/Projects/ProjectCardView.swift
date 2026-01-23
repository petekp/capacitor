import SwiftUI

// MARK: - Preference Key for Frame Tracking

private struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Main Card View

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let isStale: Bool
    let isActive: Bool
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToDormant: () -> Void
    var onCaptureIdea: ((CGRect) -> Void)?
    let onRemove: () -> Void
    var onDragStarted: (() -> NSItemProvider)?
    var isDragging: Bool = false

    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion
    @ObservedObject private var glassConfig = GlassConfig.shared

    @State private var isHovered = false
    @State private var isPressed = false
    @State private var flashOpacity: Double = 0
    @State private var previousState: SessionState?
    @State private var lastChimeTime: Date?
    @State private var lastKnownSummary: String?

    private let chimeCooldown: TimeInterval = 3.0

    // MARK: - Computed Properties

    private var currentState: SessionState? {
        switch glassConfig.previewState {
        case .none: return sessionState?.state
        case .ready: return .ready
        case .working: return .working
        case .waiting: return .waiting
        case .compacting: return .compacting
        case .idle: return .idle
        }
    }

    private var isReady: Bool {
        currentState == .ready
    }

    private var isWaiting: Bool {
        currentState == .waiting
    }

    private var isWorking: Bool {
        currentState == .working
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

    private var glassConfigForHandlers: GlassConfig? {
        glassConfig
    }

    private var cardScale: CGFloat {
        guard !reduceMotion else { return 1.0 }
        if isPressed || isDragging {
            return glassConfig.cardPressedScale(for: .vertical)
        } else if isHovered {
            return glassConfig.cardHoverScale(for: .vertical)
        }
        return glassConfig.cardIdleScale(for: .vertical)
    }

    private var cardAnimation: Animation {
        guard !reduceMotion else { return AppMotion.reducedMotionFallback }
        if isPressed {
            return .spring(
                response: glassConfig.cardPressedSpringResponse(for: .vertical),
                dampingFraction: glassConfig.cardPressedSpringDamping(for: .vertical)
            )
        }
        return .spring(
            response: glassConfig.cardHoverSpringResponse(for: .vertical),
            dampingFraction: glassConfig.cardHoverSpringDamping(for: .vertical)
        )
    }

    // MARK: - Body

    private var accessibilityStatusDescription: String {
        guard let state = currentState else { return "No active session" }
        switch state {
        case .ready: return "Ready for input"
        case .working: return "Working"
        case .waiting: return "Waiting for user action"
        case .compacting: return "Compacting history"
        case .idle: return "Idle"
        }
    }

    var body: some View {
        cardContent
            .cardStyling(
                isHovered: isHovered,
                isReady: isReady,
                isWaiting: isWaiting,
                isWorking: isWorking,
                isActive: isActive,
                flashState: flashState,
                flashOpacity: flashOpacity,
                floatingMode: floatingMode,
                floatingCardBackground: floatingCardBackground,
                solidCardBackground: solidCardBackground,
                animationSeed: project.path,
                isPressed: isPressed
            )
            .scaleEffect(cardScale)
            .animation(cardAnimation, value: cardScale)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                isPressed = pressing
            }, perform: {})
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.name)
            .accessibilityValue(accessibilityStatusDescription + (displaySummary.map { ". \($0)" } ?? ""))
            .accessibilityHint("Double-tap to open in terminal. Use actions menu for more options.")
            .accessibilityAction(named: "Open in Terminal", onTap)
            .accessibilityAction(named: "View Details", onInfoTap)
            .accessibilityAction(named: "Move to Paused", onMoveToDormant)
            .onChange(of: sessionState?.workingOn) { _, newValue in
                if let summary = newValue, !summary.isEmpty {
                    lastKnownSummary = summary
                }
            }
    }

    // MARK: - Card Content

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProjectCardHeader(
                project: project,
                isStale: isStale,
                currentState: currentState,
                nameColor: nameColor,
                onInfoTap: onInfoTap
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
        .overlay(alignment: .trailing) {
            if let onCaptureIdea = onCaptureIdea {
                PeekCaptureButton(isCardHovered: isHovered, action: onCaptureIdea)
                    .padding(.vertical, 7)
                    .padding(.trailing, 7)
            }
        }
        .clipped()
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var cardContextMenu: some View {
        if project.isMissing {
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label("Remove from HUD", systemImage: "trash")
            }
        } else {
            Button(action: onTap) {
                Label("Open in Terminal", systemImage: "terminal")
            }
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            if let onCaptureIdea = onCaptureIdea {
                Button(action: { onCaptureIdea(.zero) }) {
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

    // MARK: - Background Styles

    private var floatingCardBackground: some View {
        DarkFrostedCard(isHovered: isHovered, config: glassConfig)
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
    let currentState: SessionState?
    let nameColor: Color
    let onInfoTap: () -> Void

    var body: some View {
        HStack {
            if project.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.orange)
            }

            ClickableProjectTitle(
                name: project.name,
                nameColor: nameColor,
                isMissing: project.isMissing,
                action: onInfoTap
            )

            if isStale {
                StaleBadge()
            }

            Spacer()

            if let state = currentState {
                StatusIndicator(state: state)
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
            // Description - always visible
            if let workingOn = workingOn, !workingOn.isEmpty {
                TickerText(text: workingOn, isShimmering: isWorking)
            } else {
                Text("No recent activity")
                    .font(AppTypography.body)
                    .foregroundColor(.white.opacity(0.35))
            }

            if let blocker = blocker, !blocker.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(AppTypography.captionSmall)
                    Text(blocker)
                        .font(AppTypography.label)
                        .lineLimit(1)
                }
                .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Peek Capture Button

private struct PeekCaptureButton: View {
    let isCardHovered: Bool
    let action: (CGRect) -> Void

    @State private var isButtonHovered = false
    @State private var buttonFrame: CGRect = .zero
    @Environment(\.prefersReducedMotion) private var reduceMotion

    private var isVisible: Bool {
        isCardHovered || isButtonHovered
    }

    private var accentColor: Color {
        Color(hue: 0.13, saturation: 0.65, brightness: 0.95) // Warm amber
    }

    var body: some View {
        Button(action: { action(buttonFrame) }) {
            VStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isButtonHovered ? accentColor : .white.opacity(0.8))

                Text("idea")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(isButtonHovered ? 0.9 : 0.5))
            }
            .frame(width: 46)
            .frame(maxHeight: .infinity)
            .background(
                ZStack {
                    // Base material
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // Dark overlay for depth (more opaque for visibility)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(isButtonHovered ? 0.45 : 0.6))

                    // Hover highlight
                    if isButtonHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(accentColor.opacity(0.1))
                    }
                }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isButtonHovered ? 0.35 : 0.2),
                                .white.opacity(isButtonHovered ? 0.15 : 0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: FramePreferenceKey.self,
                    value: geo.frame(in: .named("contentView"))
                )
            }
        )
        .onPreferenceChange(FramePreferenceKey.self) { frame in
            buttonFrame = frame
        }
        .offset(x: isVisible ? 0 : 60)
        .animation(
            reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.3, dampingFraction: 0.8),
            value: isVisible
        )
        .onHover { hovering in
            isButtonHovered = hovering
        }
        .accessibilityLabel("Capture idea for this project")
    }
}

// MARK: - Ticker Text Component

private struct TickerText: View {
    let text: String
    let isShimmering: Bool

    var body: some View {
        Text(text)
            .font(AppTypography.body)
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
                                .font(AppTypography.body)
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

// Note: StaleBadge and StatusIndicator are in ProjectCardComponents.swift

// View modifiers and glow effects are now in separate files:
// - ProjectCardModifiers.swift (cardStyling, cardInteractions, cardLifecycleHandlers)
// - ProjectCardGlow.swift (ReadyAmbientGlow, ReadyBorderGlow)

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
                    .font(AppTypography.badge)
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
                    .font(AppTypography.cardTitle)
                Spacer()
                Text("\(result.score)/\(result.maxScore)")
                    .font(AppTypography.mono.weight(.medium))
                    .foregroundColor(.secondary)
            }

            Divider()

            ForEach(result.details, id: \.name) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "circle")
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(check.passed ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.name)
                            .font(AppTypography.cardSubtitle)

                        if !check.passed, let suggestion = check.suggestion {
                            Text(suggestion)
                                .font(AppTypography.label)
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
                                        .font(AppTypography.captionSmall)
                                    Text(copiedTemplate == check.name ? "Copied!" : "Copy template")
                                        .font(AppTypography.captionSmall)
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    Text("+\(check.points)")
                        .font(AppTypography.monoCaption.weight(.medium))
                        .foregroundColor(check.passed ? .green : .secondary.opacity(0.5))
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
