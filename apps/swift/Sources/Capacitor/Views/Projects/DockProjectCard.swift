import SwiftUI

struct DockProjectCard: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let isStale: Bool
    let isActive: Bool
    let onTap: () -> Void
    let onInfoTap: (() -> Void)?
    let onMoveToDormant: () -> Void
    var onCaptureIdea: ((CGRect) -> Void)?
    let onRemove: () -> Void
    var onDragStarted: (() -> NSItemProvider)?
    var isDragging: Bool = false

    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion
    @AppStorage("playReadyChime") private var playReadyChime = true
    private let glassConfig = GlassConfig.shared

    @State private var isHovered = false
    @State private var isPressed = false
    @State private var flashOpacity: Double = 0

    // Positional press feedback
    @State private var cursorLocation: CGPoint = .zero
    @State private var pressPoint: CGPoint = .zero
    @State private var cardSize: CGSize = .zero
    @State private var distortionIntensity: Double = 0
    @State private var pressStartTime: Date?

    private var cornerRadius: CGFloat {
        GlassConfig.shared.cardCornerRadius(for: .dock)
    }

    private var currentState: SessionState {
        sessionState?.state ?? .idle
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
                dampingFraction: glassConfig.cardPressedSpringDamping(for: .dock),
            )
        }
        return .spring(
            response: glassConfig.cardHoverSpringResponse(for: .dock),
            dampingFraction: glassConfig.cardHoverSpringDamping(for: .dock),
        )
    }

    // MARK: - Press Tilt

    private var pressTiltX: Double {
        guard isPressed, !reduceMotion, cardSize.height > 0 else { return 0 }
        let normalizedY = (pressPoint.y / cardSize.height - 0.5) * 2
        return -normalizedY * glassConfig.cardPressTiltVertical
    }

    private var pressTiltY: Double {
        guard isPressed, !reduceMotion, cardSize.width > 0 else { return 0 }
        let normalizedX = (pressPoint.x / cardSize.width - 0.5) * 2
        return normalizedX * glassConfig.cardPressTiltHorizontal
    }

    private var tiltAnimation: Animation {
        guard !reduceMotion else { return AppMotion.reducedMotionFallback }
        if isPressed {
            return .spring(response: 0.15, dampingFraction: 0.6)
        }
        return .spring(response: 0.35, dampingFraction: 0.75)
    }

    private var pressRipple: some View {
        MetallicPressHighlight(
            pressPoint: pressPoint,
            cardSize: cardSize,
            cornerRadius: cornerRadius,
            intensity: glassConfig.cardPressRippleOpacity,
            pressStartTime: pressStartTime,
        )
    }

    private var rippleDuration: Double {
        #if DEBUG
            glassConfig.highlightRippleDuration
        #else
            0.63
        #endif
    }

    var body: some View {
        #if DEBUG
            let _ = DockProjectCardRenderTelemetry.logIfChanged(
                path: project.path,
                name: project.name,
                state: sessionState?.state,
            )
        #endif

        // Capture layout values once at body evaluation to avoid constraint loops
        let dockPaddingH = glassConfig.dockCardPaddingH
        let dockPaddingV = glassConfig.dockCardPaddingV

        let dockWidth = glassConfig.dockCardWidthRounded
        let dockMinHeight = glassConfig.dockCardMinHeightRounded
        let dockMaxHeight = glassConfig.dockCardMaxHeightRounded

        let styledCard = cardContent
            .padding(.horizontal, dockPaddingH)
            .padding(.vertical, dockPaddingV)
            .frame(width: dockWidth)
            .frame(
                minHeight: dockMinHeight > 0 ? dockMinHeight : nil,
                maxHeight: dockMaxHeight > 0 ? dockMaxHeight : nil,
            )
            .cardStyling(
                isHovered: isHovered,
                currentState: currentState,
                isActive: isActive,
                flashState: flashState,
                flashOpacity: flashOpacity,
                floatingMode: floatingMode,
                floatingCardBackground: floatingCardBackground,
                solidCardBackground: solidCardBackground,
                animationSeed: project.path,
                layoutMode: .dock,
                isPressed: isPressed,
            )
            .pressDistortion(
                pressPoint: pressPoint,
                cardSize: cardSize,
                intensity: distortionIntensity,
            )
            .overlay { pressRipple }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    cursorLocation = location
                case .ended:
                    break
                }
            }
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { cardSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in cardSize = newSize }
                }
            }

        styledCard
            .scaleEffect(cardScale)
            .rotation3DEffect(
                .degrees(pressTiltX),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.8,
            )
            .rotation3DEffect(
                .degrees(pressTiltY),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.8,
            )
            .animation(cardAnimation, value: cardScale)
            .animation(tiltAnimation, value: pressTiltX)
            .animation(tiltAnimation, value: pressTiltY)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                if pressing {
                    pressPoint = cursorLocation
                    pressStartTime = Date()
                }
                isPressed = pressing
                let target = pressing ? glassConfig.cardPressDistortion : 0
                withAnimation(pressing
                    ? .spring(response: 0.12, dampingFraction: 0.55)
                    : .spring(response: 0.4, dampingFraction: 0.8))
                {
                    distortionIntensity = target
                }
            }, perform: {})
            .task(id: pressStartTime) {
                guard pressStartTime != nil else { return }
                do {
                    try await _Concurrency.Task.sleep(for: .milliseconds(Int(rippleDuration * 1000)))
                } catch {
                    return
                }
                pressStartTime = nil
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture {
                if pressStartTime == nil {
                    pressPoint = cursorLocation
                    pressStartTime = Date()
                }
                onTap()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .accessibilityAction(named: "Open in Terminal", onTap)
            .applyIf(onInfoTap) { view, action in
                view.accessibilityAction(named: "View Details", action)
            }
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
                projectPath: project.path,
                flashState: flashState,
                currentState: currentState,
                flashOpacity: $flashOpacity,
                playReadyChime: playReadyChime,
            )
            .contextMenu {
                ProjectContextMenu(
                    project: project,
                    onTap: onTap,
                    onInfoTap: onInfoTap,
                    onMoveToDormant: onMoveToDormant,
                    onCaptureIdea: onCaptureIdea.map { action in { action(.zero) } },
                    onRemove: onRemove,
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityIdentifiers.projectCardIdentifier(for: project))
            .accessibilityLabel(project.name)
            .accessibilityValue(statusDescription)
    }

    private var cardContent: some View {
        HStack(spacing: glassConfig.dockCardContentSpacingRounded) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let onInfoTap {
                        ClickableProjectTitle(
                            name: project.name,
                            nameColor: .white.opacity(0.9),
                            isMissing: project.isMissing,
                            action: onInfoTap,
                            font: AppTypography.sectionTitle.monospaced(),
                            accessibilityIdentifier: AccessibilityIdentifiers.projectDetailsIdentifier(for: project),
                        )
                        .lineLimit(1)
                    } else {
                        Text(project.name)
                            .font(AppTypography.sectionTitle.monospaced())
                            .foregroundStyle(.white.opacity(0.9))
                            .strikethrough(project.isMissing, color: .white.opacity(0.3))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                StatusChipsRow(sessionState: sessionState, isStale: isStale, style: .compact)
                    .padding(.top, glassConfig.dockChipTopPaddingRounded)

                Spacer(minLength: 0)

                if let blocker = projectStatus?.blocker, !blocker.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(AppTypography.captionSmall)
                        Text(blocker)
                            .font(AppTypography.label)
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CardActionButtons(
                isCardHovered: isHovered,
                onCaptureIdea: onCaptureIdea,
                onDetails: onInfoTap,
                style: .compact,
            )
        }
    }

    private var floatingCardBackground: some View {
        DarkFrostedCard(isHovered: isHovered, layoutMode: .dock, config: glassConfig)
    }

    private var solidCardBackground: some View {
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

    private var statusDescription: String {
        switch currentState {
        case .ready: "Ready for input"
        case .working: "Working"
        case .waiting: "Waiting for user action"
        case .compacting: "Compacting history"
        case .idle: "Idle"
        }
    }
}

#if DEBUG
    @MainActor
    private enum DockProjectCardRenderTelemetry {
        private static var lastByPath: [String: String] = [:]

        static func logIfChanged(path: String, name: String, state: SessionState?) {
            let label = if let state {
                switch state {
                case .working: "Working"
                case .ready: "Ready"
                case .idle: "Idle"
                case .compacting: "Compacting"
                case .waiting: "Waiting"
                }
            } else {
                "nil"
            }

            let summary = "\(name):\(label)"
            guard lastByPath[path] != summary else { return }
            lastByPath[path] = summary
            DebugLog.write("[DEBUG][DockProjectCard][CardState] \(summary) path=\(path)")
        }
    }
#endif

private extension View {
    @ViewBuilder
    func applyIf<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

// Note: DockStatusIndicator, DockBlockerBadge, DockStaleBadge have been replaced
// with shared components from ProjectCardComponents.swift:
// - StatusIndicator(state:, style: .compact)
// - BlockerBadge(style: .compact)
// - StaleBadge(style: .compact)
