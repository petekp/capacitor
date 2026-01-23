import SwiftUI

struct DockProjectCard: View {
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
    @State private var summaryHighlighted = false

    private let cornerRadius: CGFloat = 10
    private let chimeCooldown: TimeInterval = 3.0

    private var currentState: SessionState? {
        sessionState?.state
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

    private var displaySummary: String? {
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
            return glassConfig.cardPressedScale(for: .dock)
        } else if isHovered {
            return glassConfig.cardHoverScale(for: .dock)
        }
        return glassConfig.cardIdleScale(for: .dock)
    }

    private var cardAnimation: Animation {
        guard !reduceMotion else { return AppMotion.reducedMotionFallback }
        if isPressed {
            return .spring(
                response: glassConfig.cardPressedSpringResponse(for: .dock),
                dampingFraction: glassConfig.cardPressedSpringDamping(for: .dock)
            )
        }
        return .spring(
            response: glassConfig.cardHoverSpringResponse(for: .dock),
            dampingFraction: glassConfig.cardHoverSpringDamping(for: .dock)
        )
    }

    var body: some View {
        cardContent
            .frame(width: 262)
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
                cornerRadius: cornerRadius,
                layoutMode: .dock,
                isPressed: isPressed
            )
            .scaleEffect(cardScale)
            .animation(cardAnimation, value: cardScale)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                isPressed = pressing
            }, perform: {})
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture(perform: onTap)
            .onDrag {
                onDragStarted?() ?? NSItemProvider(object: project.path as NSString)
            } preview: {
                Text(project.name)
                    .font(AppTypography.sectionTitle.monospaced())
                    .padding(8)
                    .background(Color.hudCard.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
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
                    onTap: onTap,
                    onInfoTap: onInfoTap,
                    onMoveToDormant: onMoveToDormant,
                    onCaptureIdea: onCaptureIdea.map { action in { action(.zero) } },
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
                ClickableProjectTitle(
                    name: project.name,
                    nameColor: .white.opacity(0.9),
                    isMissing: project.isMissing,
                    action: onInfoTap,
                    font: AppTypography.sectionTitle.monospaced()
                )
                .lineLimit(1)

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
                    .lineLimit(2)
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
        DarkFrostedCard(isHovered: isHovered, config: glassConfig)
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
