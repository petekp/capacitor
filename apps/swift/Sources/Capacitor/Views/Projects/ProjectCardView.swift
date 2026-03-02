import SwiftUI

// MARK: - Main Card View

struct ProjectCardView: View {
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

    // MARK: - Computed Properties

    private var currentState: SessionState {
        sessionState?.state ?? .idle
    }

    private var nameColor: Color {
        project.isMissing ? .white.opacity(0.5) : .white.opacity(0.9)
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
                dampingFraction: glassConfig.cardPressedSpringDamping(for: .vertical),
            )
        }
        return .spring(
            response: glassConfig.cardHoverSpringResponse(for: .vertical),
            dampingFraction: glassConfig.cardHoverSpringDamping(for: .vertical),
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

    // MARK: - Body

    var body: some View {
        #if DEBUG
            let _ = ProjectCardRenderTelemetry.logIfChanged(
                path: project.path,
                name: project.name,
                state: sessionState?.state,
                source: "ProjectCardView",
            )
        #endif

        // Capture layout values once at body evaluation to avoid constraint loops
        let paddingH = glassConfig.cardPaddingH
        let paddingV = glassConfig.cardPaddingV

        let styledCard = cardContent
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
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
            .cardInteractions(
                isHovered: $isHovered,
                onTap: {
                    // Re-trigger ripple only if none is playing (avoids resetting
                    // the mouseDown ripple on mouseUp during a single click, while
                    // still firing on rapid clicks after the previous ripple expires)
                    if pressStartTime == nil {
                        pressPoint = cursorLocation
                        pressStartTime = Date()
                    }
                    onTap()
                },
                onDragStarted: onDragStarted,
            )
            .cardLifecycleHandlers(
                projectPath: project.path,
                flashState: flashState,
                currentState: currentState,
                flashOpacity: $flashOpacity,
                playReadyChime: playReadyChime,
            )
            .contextMenu { cardContextMenu }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityIdentifiers.projectCardIdentifier(for: project))
            .accessibilityLabel(project.name)
            .accessibilityValue(accessibilityStatusDescription)
            .accessibilityHint("Double-tap to open in terminal. Use actions menu for more options.")
            .accessibilityAction(named: "Open in Terminal", onTap)
            .applyIf(onInfoTap) { view, action in
                view.accessibilityAction(named: "View Details", action)
            }
            .accessibilityAction(named: "Hide", onMoveToDormant)
    }

    // MARK: - Computed View Helpers

    private var accessibilityStatusDescription: String {
        switch currentState {
        case .ready: "Ready for input"
        case .working: "Working"
        case .waiting: "Waiting for user action"
        case .compacting: "Compacting history"
        case .idle: "Idle"
        }
    }

    // MARK: - Press Highlight

    private var pressRipple: some View {
        MetallicPressHighlight(
            pressPoint: pressPoint,
            cardSize: cardSize,
            cornerRadius: glassConfig.cardCornerRadius(for: .vertical),
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

    // MARK: - Card Content

    private var cardContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ProjectCardHeader(
                    project: project,
                    nameColor: nameColor,
                    onInfoTap: onInfoTap,
                    detailsAccessibilityIdentifier: AccessibilityIdentifiers.projectDetailsIdentifier(for: project),
                )

                ProjectCardContent(
                    sessionState: sessionState,
                    blocker: projectStatus?.blocker,
                    isStale: isStale,
                )
            }

            CardActionButtons(
                isCardHovered: isHovered,
                onCaptureIdea: onCaptureIdea,
                onDetails: onInfoTap,
            )
        }
        .frame(minHeight: 40) // Match action button height for consistent card sizing
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: projectStatus?.blocker)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var cardContextMenu: some View {
        if project.isMissing {
            if let onInfoTap {
                Button(action: onInfoTap) {
                    Label("View Details", systemImage: "info.circle")
                }
                Divider()
            }
            Button(role: .destructive, action: onRemove) {
                Label("Disconnect", systemImage: "trash")
            }
        } else {
            Button(action: onTap) {
                Label("Open in Terminal", systemImage: "terminal")
            }
            if let onInfoTap {
                Button(action: onInfoTap) {
                    Label("View Details", systemImage: "info.circle")
                }
            }
            if let onCaptureIdea {
                Button(action: { onCaptureIdea(.zero) }) {
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

    // MARK: - Background Styles

    private var floatingCardBackground: some View {
        DarkFrostedCard(isHovered: isHovered, layoutMode: .vertical, config: glassConfig)
    }

    private var solidCardBackground: some View {
        let cornerRadius = GlassConfig.shared.cardCornerRadius(for: .vertical)
        return ZStack {
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

#if DEBUG
    @MainActor
    private enum ProjectCardRenderTelemetry {
        private static var lastByPath: [String: String] = [:]

        static func logIfChanged(path: String, name: String, state: SessionState?, source: String) {
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
            DebugLog.write("[DEBUG][\(source)][CardState] \(summary) path=\(path)")
        }
    }
#endif

// MARK: - Card Header Component

private struct ProjectCardHeader: View {
    let project: Project
    let nameColor: Color
    let onInfoTap: (() -> Void)?
    let detailsAccessibilityIdentifier: String

    var body: some View {
        HStack {
            if project.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.orange)
            }

            if let onInfoTap {
                ClickableProjectTitle(
                    name: project.name,
                    nameColor: nameColor,
                    isMissing: project.isMissing,
                    action: onInfoTap,
                    accessibilityIdentifier: detailsAccessibilityIdentifier,
                )
            } else {
                Text(project.name)
                    .font(AppTypography.cardTitle.monospaced())
                    .foregroundStyle(nameColor)
                    .strikethrough(project.isMissing, color: .white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
        }
    }
}

// MARK: - Card Content Component

private struct ProjectCardContent: View {
    let sessionState: ProjectSessionState?
    let blocker: String?
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusChipsRow(sessionState: sessionState, isStale: isStale)

            if let blocker, !blocker.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(AppTypography.captionSmall)
                    Text(blocker)
                        .font(AppTypography.label)
                        .lineLimit(1)
                }
                .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card Action Buttons

/// Container for action buttons that appear on card hover with staggered animation
struct CardActionButtons: View {
    let isCardHovered: Bool
    var onCaptureIdea: ((CGRect) -> Void)?
    var onDetails: (() -> Void)?
    var style: VibrancyActionButton.Style = .normal

    var body: some View {
        HStack(spacing: 0) {
            if let onCaptureIdea {
                VibrancyActionButton(
                    icon: "lightbulb",
                    action: { frame in onCaptureIdea(frame) },
                    isVisible: isCardHovered,
                    entranceDelay: 0,
                    style: style,
                )
                .help("Capture idea")
                .accessibilityLabel("Capture idea for this project")
            }

            if let onDetails {
                VibrancyActionButton(
                    icon: "chevron.right",
                    action: { _ in onDetails() },
                    isVisible: isCardHovered,
                    entranceDelay: 0.03,
                    style: style,
                )
                .help("View details")
                .accessibilityLabel("View project details")
            }
        }
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
                removal: .move(edge: .top).combined(with: .opacity),
            ))
            .overlay {
                if isShimmering {
                    ShimmerEffect()
                        .mask(
                            Text(text)
                                .font(AppTypography.body)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading),
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
        GeometryReader { _ in
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0), location: phase - 0.2),
                    .init(color: .white.opacity(0.4), location: phase),
                    .init(color: .white.opacity(0), location: phase + 0.2),
                    .init(color: .white.opacity(0), location: 1),
                ]),
                startPoint: .leading,
                endPoint: .trailing,
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

// Note: View modifiers and glow effects are in separate files:
// - ProjectCardModifiers.swift (cardStyling, cardInteractions, cardLifecycleHandlers)
// - ProjectCardGlow.swift (ReadyAmbientGlow, ReadyBorderGlow)

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
