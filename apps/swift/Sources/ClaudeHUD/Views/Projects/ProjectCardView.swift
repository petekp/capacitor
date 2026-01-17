import SwiftUI

// MARK: - Main Card View

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let devServerPort: UInt16?
    let isStale: Bool
    let isActive: Bool
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToDormant: () -> Void
    let onOpenBrowser: () -> Void
    var onCaptureIdea: (() -> Void)?
    let onRemove: () -> Void
    var onDragStarted: (() -> NSItemProvider)?

    // Ideas support
    var ideas: [Idea] = []
    var ideasRemainingCount: Int = 0
    var generatingTitleIds: Set<String> = []
    var onShowMoreIdeas: (() -> Void)?
    var onWorkOnIdea: ((Idea) -> Void)?
    var onDismissIdea: ((Idea) -> Void)?

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
    @State private var showIdeasPopover = false

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
                devServerPort: devServerPort,
                currentState: currentState,
                nameColor: nameColor,
                isHovered: isHovered,
                isInfoHovered: $isInfoHovered,
                isBrowserHovered: $isBrowserHovered,
                showIdeasPopover: $showIdeasPopover,
                onInfoTap: onInfoTap,
                onOpenBrowser: onOpenBrowser,
                ideas: ideas,
                ideasRemainingCount: ideasRemainingCount,
                generatingTitleIds: generatingTitleIds,
                onAddIdea: onCaptureIdea,
                onShowMoreIdeas: onShowMoreIdeas,
                onWorkOnIdea: onWorkOnIdea,
                onDismissIdea: onDismissIdea
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
            Button(role: .destructive, action: onRemove) {
                Label("Remove from HUD", systemImage: "trash")
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
            Button(role: .destructive, action: onRemove) {
                Label("Remove from HUD", systemImage: "trash")
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
    let devServerPort: UInt16?
    let currentState: SessionState?
    let nameColor: Color
    let isHovered: Bool
    @Binding var isInfoHovered: Bool
    @Binding var isBrowserHovered: Bool
    @Binding var showIdeasPopover: Bool
    let onInfoTap: () -> Void
    let onOpenBrowser: () -> Void

    // Ideas support
    var ideas: [Idea] = []
    var ideasRemainingCount: Int = 0
    var generatingTitleIds: Set<String> = []
    var onAddIdea: (() -> Void)?
    var onShowMoreIdeas: (() -> Void)?
    var onWorkOnIdea: ((Idea) -> Void)?
    var onDismissIdea: ((Idea) -> Void)?

    private var totalIdeasCount: Int {
        ideas.count + ideasRemainingCount
    }

    var body: some View {
        HStack {
            if project.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.orange)
            }

            Text(project.name)
                .font(AppTypography.cardTitle.monospaced())
                .foregroundColor(nameColor)
                .strikethrough(project.isMissing, color: .white.opacity(0.3))

            if isStale {
                StaleBadge()
            }

            if totalIdeasCount > 0 {
                IdeasBadge(
                    count: totalIdeasCount,
                    isCardHovered: isHovered,
                    showPopover: $showIdeasPopover
                )
                .popover(isPresented: $showIdeasPopover, arrowEdge: .bottom) {
                    IdeasPopoverContent(
                        ideas: ideas,
                        remainingCount: ideasRemainingCount,
                        generatingTitleIds: generatingTitleIds,
                        onAddIdea: onAddIdea,
                        onShowMore: onShowMoreIdeas,
                        onWorkOnIdea: onWorkOnIdea,
                        onDismissIdea: onDismissIdea
                    )
                }
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
            if let workingOn = workingOn, !workingOn.isEmpty {
                TickerText(text: workingOn, isShimmering: isWorking)
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

// MARK: - Ticker Text Component

private struct TickerText: View {
    let text: String
    let isShimmering: Bool

    var body: some View {
        Text(text)
            .font(AppTypography.bodySecondary)
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
                                .font(AppTypography.bodySecondary)
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
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(AppTypography.body)
                .foregroundColor(.white.opacity(isInfoHovered ? 0.7 : (isHovered ? 0.35 : 0.2)))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isInfoHovered = hovering
            }
        }
        .help("View details")
        .accessibilityLabel("View project details")
        .accessibilityHint("Shows description, ideas, and other project information")
    }
}

private struct DevServerButton: View {
    let port: UInt16
    let isHovered: Bool
    @Binding var isBrowserHovered: Bool
    let action: () -> Void
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(AppTypography.caption)
                Text(":\(String(port))")
                    .font(AppTypography.monoCaption.weight(.medium))
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
            .scaleEffect(isBrowserHovered && !reduceMotion ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.2, dampingFraction: 0.7)) {
                isBrowserHovered = hovering
            }
        }
        .help("Open localhost:\(port) in browser")
        .accessibilityLabel("Open development server in browser")
        .accessibilityValue("Port \(port)")
        .accessibilityHint("Opens localhost:\(port) in your default browser")
    }
}

// Note: StaleBadge, IdeasBadge, IdeasPopoverContent, IdeaRow, and StatusIndicator
// are now in ProjectCardComponents.swift for sharing across card types

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
