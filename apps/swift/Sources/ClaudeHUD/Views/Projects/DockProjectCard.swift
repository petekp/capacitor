import SwiftUI

struct DockProjectCard: View {
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

    // Ideas support (shared with ProjectCardView)
    var ideas: [Idea] = []
    var ideasRemainingCount: Int = 0
    var generatingTitleIds: Set<String> = []
    var onShowMoreIdeas: (() -> Void)?
    var onWorkOnIdea: ((Idea) -> Void)?
    var onDismissIdea: ((Idea) -> Void)?

    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
    @ObservedObject private var glassConfig = GlassConfig.shared
    #endif

    @State private var isHovered = false
    @State private var flashOpacity: Double = 0
    @State private var previousState: SessionState?
    @State private var lastChimeTime: Date?
    @State private var lastKnownSummary: String?
    @State private var summaryHighlighted = false
    @State private var showIdeasPopover = false

    private let cornerRadius: CGFloat = 10
    private let chimeCooldown: TimeInterval = 3.0

    private var totalIdeasCount: Int {
        ideas.count + ideasRemainingCount
    }

    private var currentState: SessionState? {
        sessionState?.state
    }

    private var isReady: Bool {
        currentState == .ready
    }

    private var displaySummary: String? {
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

    var body: some View {
        cardContent
            .frame(width: 262, height: 126)
            .cardStyling(
                isHovered: isHovered,
                isReady: isReady,
                isActive: isActive,
                flashState: flashState,
                flashOpacity: flashOpacity,
                floatingMode: floatingMode,
                floatingCardBackground: floatingCardBackground,
                solidCardBackground: solidCardBackground,
                animationSeed: project.path,
                cornerRadius: cornerRadius,
                layoutMode: .dock
            )
            .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
            .animation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture(perform: onTap)
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
            .contextMenu {
                ProjectContextMenu(
                    project: project,
                    devServerPort: devServerPort,
                    onTap: onTap,
                    onInfoTap: onInfoTap,
                    onMoveToDormant: onMoveToDormant,
                    onOpenBrowser: onOpenBrowser,
                    onCaptureIdea: onCaptureIdea,
                    onRemove: onRemove
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project.name)
            .accessibilityValue(statusDescription)
            .onChange(of: sessionState?.workingOn) { oldValue, newValue in
                if let summary = newValue, !summary.isEmpty {
                    lastKnownSummary = summary
                    if oldValue != newValue {
                        summaryHighlighted = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            summaryHighlighted = false
                        }
                    }
                }
            }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(AppTypography.sectionTitle.monospaced())
                    .tracking(-0.5)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

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
                            onAddIdea: onCaptureIdea,
                            onShowMore: onShowMoreIdeas,
                            onWorkOnIdea: onWorkOnIdea,
                            onDismissIdea: onDismissIdea
                        )
                    }
                }

                Spacer(minLength: 0)
            }

            if let state = currentState {
                StatusIndicator(state: state)
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)

            if let summary = displaySummary, !summary.isEmpty {
                Text(summary)
                    .font(AppTypography.body)
                    .foregroundColor(.white.opacity(summaryHighlighted ? 0.9 : 0.55))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(reduceMotion ? .identity : .interpolate)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: displaySummary)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: summaryHighlighted)
            }

            if projectStatus?.blocker != nil || isStale {
                HStack(spacing: 6) {
                    if let blocker = projectStatus?.blocker, !blocker.isEmpty {
                        BlockerBadge(style: .compact)
                    }
                    if isStale {
                        StaleBadge(style: .compact)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
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

    private var statusDescription: String {
        guard let state = currentState else { return "No active session" }
        switch state {
        case .ready: return "Ready for input"
        case .working: return "Working"
        case .waiting: return "Waiting for user action"
        case .compacting: return "Compacting history"
        case .idle: return "Idle"
        }
    }
}

// Note: DockStatusIndicator, DockBlockerBadge, DockStaleBadge have been replaced
// with shared components from ProjectCardComponents.swift:
// - StatusIndicator(state:, style: .compact)
// - BlockerBadge(style: .compact)
// - StaleBadge(style: .compact)
