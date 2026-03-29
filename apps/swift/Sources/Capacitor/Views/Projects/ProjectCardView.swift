import SwiftUI

// MARK: - Main Card View

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let delegationState: RuntimeDelegationState?
    let activeRunState: RuntimeRunState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
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
        if let runState = runVisualState.sessionState {
            return runState
        }
        return sessionState?.state ?? .idle
    }

    private var runVisualState: RunVisualState {
        ProjectRunVisualStateResolver.visualState(for: activeRunState)
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
                state: currentState,
                source: "ProjectCardView",
            )
        #endif

        let styledCard = cardContent
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
            .accessibilityHint(accessibilityHintText)
            .accessibilityAction(named: primaryAccessibilityActionName, onTap)
            .applyIf(onInfoTap) { view, action in
                view.accessibilityAction(named: "View Details", action)
            }
            .accessibilityAction(named: "Hide", onMoveToDormant)
    }

    // MARK: - Computed View Helpers

    private var delegationStatus: String? {
        delegationState?.status
    }

    private var runContextText: String? {
        switch runVisualState {
        case let .completed(statusMessage):
            if let methodName = activeRunState?.methodName {
                return "\(methodName) completed"
            }
            return statusMessage ?? "Run completed"
        case let .failed(statusMessage):
            return statusMessage ?? "Run failed"
        default:
            return runVisualState.statusMessage
        }
    }

    private var delegationContextText: String? {
        guard let delegationState else { return nil }

        if let workingOn = projectStatus?.workingOn?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !workingOn.isEmpty
        {
            return workingOn
        }

        let milestoneID = delegationState.currentReview?.milestoneId ?? delegationState.submittedMilestoneId

        switch delegationState.status {
        case "review_needed":
            if let milestoneID, !milestoneID.isEmpty {
                return "Milestone \(milestoneID) awaiting review"
            }
            return "Review ready"
        case "resume_pending":
            if let milestoneID, !milestoneID.isEmpty {
                return "Resuming milestone \(milestoneID)"
            }
            return "Delegation is resuming"
        case "resume_failed":
            if let milestoneID, !milestoneID.isEmpty {
                return "Resume failed for milestone \(milestoneID)"
            }
            return "Resume failed"
        default:
            if let milestoneID, !milestoneID.isEmpty {
                return "Milestone \(milestoneID) in progress"
            }
            return "Delegation in progress"
        }
    }

    private var hasOpenDelegationReview: Bool {
        guard let delegationState else { return false }
        return delegationState.currentReview != nil
            && (delegationState.status == "review_needed" || delegationState.status == "resume_failed")
    }

    private var accessibilityStatusDescription: String {
        if let runState = runVisualState.sessionState {
            return switch runState {
            case .ready: "Ready for input"
            case .working: "Working"
            case .waiting: "Waiting for user action"
            case .compacting: "Compacting history"
            case .idle: "Idle"
            }
        }
        if delegationStatus == "review_needed", delegationState?.currentReview != nil {
            return "Delegation review needed"
        }
        if delegationStatus == "resume_pending" {
            return "Worker resuming after review feedback"
        }
        if delegationStatus == "resume_failed", delegationState?.currentReview != nil {
            return "Worker resume failed and review is ready to retry"
        }
        if delegationStatus == "resume_failed" {
            return "Worker resume failed"
        }
        return switch currentState {
        case .ready: "Ready for input"
        case .working: "Working"
        case .waiting: "Waiting for user action"
        case .compacting: "Compacting history"
        case .idle: "Idle"
        }
    }

    private var primaryAccessibilityActionName: String {
        if hasOpenDelegationReview {
            if delegationStatus == "resume_failed" {
                return "Retry Review"
            }
            return "Open Review"
        }
        if delegationStatus == "resume_pending" {
            return "Open in Terminal While Resuming"
        }
        return "Open in Terminal"
    }

    private var accessibilityHintText: String {
        if delegationStatus == "review_needed", delegationState?.currentReview != nil {
            return "Double-tap to review the delegated work. Use actions menu for more options."
        }
        if delegationStatus == "resume_pending" {
            return "Double-tap to open in terminal while the worker resumes in the background. Use actions menu for more options."
        }
        if delegationStatus == "resume_failed", delegationState?.currentReview != nil {
            return "Double-tap to reopen the review and retry resuming the worker. Use actions menu for more options."
        }
        if delegationStatus == "resume_failed" {
            return "Double-tap to open in terminal and inspect the failed resume. Use actions menu for more options."
        }
        return "Double-tap to open in terminal. Use actions menu for more options."
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

    private var paddingTop: CGFloat {
        #if DEBUG
            glassConfig.cardPaddingTopRounded
        #else
            14
        #endif
    }

    private var paddingBottom: CGFloat {
        #if DEBUG
            glassConfig.cardPaddingBottomRounded
        #else
            8
        #endif
    }

    private var paddingLeading: CGFloat {
        #if DEBUG
            glassConfig.cardPaddingLeadingRounded
        #else
            12
        #endif
    }

    private var paddingTrailing: CGFloat {
        #if DEBUG
            glassConfig.cardPaddingTrailingRounded
        #else
            12
        #endif
    }

    // MARK: - Card Content

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ProjectCardHeader(
                    project: project,
                    nameColor: nameColor,
                    sessionState: sessionState,
                    delegationState: delegationState,
                    activeRunState: activeRunState,
                )

                ProjectCardContent(
                    contextLine: runContextText ?? {
                        if runVisualState == .none {
                            return delegationContextText
                        }
                        return nil
                    }(),
                    isMissing: project.isMissing,
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, paddingTop)
            .padding(.bottom, paddingBottom)
            .padding(.leading, paddingLeading)
            .padding(.trailing, paddingTrailing)

            ProjectCardActionBar(
                isCardHovered: isHovered,
                onCaptureIdea: onCaptureIdea,
                onDetails: onInfoTap,
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    let sessionState: ProjectSessionState?
    let delegationState: RuntimeDelegationState?
    let activeRunState: RuntimeRunState?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if project.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.orange)
            }

            Text(project.name)
                .font(AppTypography.cardTitle.monospaced())
                .foregroundStyle(nameColor)
                .strikethrough(project.isMissing, color: .white.opacity(0.3))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            StatusChipsRow(
                sessionState: sessionState,
                delegationState: delegationState,
                activeRunState: activeRunState,
            )
        }
    }
}

// MARK: - Card Content Component

private struct ProjectCardContent: View {
    let contextLine: String?
    let isMissing: Bool

    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        // Always render the text to reserve layout height; fade opacity to prevent
        // height jumps when the context line appears/disappears during state transitions.
        Text(contextLine ?? " ")
            .font(AppTypography.bodySecondary)
            .foregroundStyle(isMissing ? .white.opacity(0.4) : .white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(contextLine != nil ? 1 : 0)
            .animation(reduceMotion ? AppMotion.reducedMotionFallback : .easeInOut(duration: 0.25), value: contextLine != nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Action Bar

private enum ProjectCardActionMetrics {
    static var buttonMinHeight: CGFloat {
        #if DEBUG
            GlassConfig.shared.actionBarButtonHeight
        #else
            30.14
        #endif
    }
}

private struct ProjectCardActionBar: View {
    let isCardHovered: Bool
    var onCaptureIdea: ((CGRect) -> Void)?
    var onDetails: (() -> Void)?

    #if DEBUG
        private let config = GlassConfig.shared
    #endif

    private var separatorHeight: CGFloat {
        #if DEBUG
            CGFloat(config.actionBarSeparatorHeight)
        #else
            0.99
        #endif
    }

    private var topPadding: CGFloat {
        #if DEBUG
            config.actionBarTopPadding
        #else
            0
        #endif
    }

    private var bottomSpacing: CGFloat {
        #if DEBUG
            config.actionBarBottomSpacing
        #else
            0
        #endif
    }

    private var rowMarginTop: CGFloat {
        #if DEBUG
            config.actionBarRowMarginTop
        #else
            0
        #endif
    }

    private var rowMarginBottom: CGFloat {
        #if DEBUG
            config.actionBarRowMarginBottom
        #else
            6.52
        #endif
    }

    private var rowMarginLeading: CGFloat {
        #if DEBUG
            config.actionBarRowMarginLeading
        #else
            9.59
        #endif
    }

    private var rowMarginTrailing: CGFloat {
        #if DEBUG
            config.actionBarRowMarginTrailing
        #else
            9.76
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            ProjectCardActionButton(
                icon: "plus",
                title: "Idea",
                accessibilityLabel: "Capture idea for this project",
                action: onCaptureIdea,
            )

            Spacer(minLength: 0)

            ProjectCardActionButton(
                icon: "chevron.right",
                title: "Details",
                iconTrailing: true,
                accessibilityLabel: "View project details",
                action: onDetails.map { action in { _ in action() } },
            )
        }
        .opacity(isCardHovered ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isCardHovered)
        .padding(.top, topPadding + separatorHeight + bottomSpacing)
        .padding(.top, rowMarginTop)
        .padding(.bottom, rowMarginBottom)
        .padding(.leading, rowMarginLeading)
        .padding(.trailing, rowMarginTrailing)
        .contentShape(.rect)
        .onTapGesture {}
    }
}

private struct ProjectCardActionButton: View {
    let icon: String
    let title: String
    var iconTrailing: Bool = false
    let accessibilityLabel: String
    var action: ((CGRect) -> Void)?

    #if DEBUG
        private let config = GlassConfig.shared
    #endif

    @Environment(\.prefersReducedMotion) private var reduceMotion

    @State private var isHovered = false
    @State private var buttonFrame: CGRect = .zero

    private var isEnabled: Bool {
        action != nil
    }

    private var foregroundColor: Color {
        #if DEBUG
            guard isEnabled else { return .white.opacity(config.actionBarDisabledOpacity) }
            return .white.opacity(isHovered ? config.actionBarHoverOpacity : config.actionBarForegroundOpacity)
        #else
            guard isEnabled else { return .white.opacity(0.3) }
            return .white.opacity(isHovered ? 0.9 : 0.7)
        #endif
    }

    private var iconFont: Font {
        #if DEBUG
            .system(size: config.actionBarIconSize, weight: Self.fontWeight(from: config.actionBarIconFontWeight))
        #else
            .system(size: 11, weight: .semibold)
        #endif
    }

    private var labelFont: Font {
        #if DEBUG
            .system(size: config.actionBarFontSize, weight: Self.fontWeight(from: config.actionBarFontWeight))
        #else
            AppTypography.labelMedium
        #endif
    }

    private var paddingTop: CGFloat {
        #if DEBUG
            config.actionBarButtonPaddingTop
        #else
            0
        #endif
    }

    private var paddingBottom: CGFloat {
        #if DEBUG
            config.actionBarButtonPaddingBottom
        #else
            0
        #endif
    }

    private var paddingLeading: CGFloat {
        #if DEBUG
            config.actionBarButtonPaddingLeading
        #else
            0
        #endif
    }

    private var paddingTrailing: CGFloat {
        #if DEBUG
            config.actionBarButtonPaddingTrailing
        #else
            0
        #endif
    }

    private var hoverFillOpacity: Double {
        isEnabled && isHovered ? 0.14 : 0.0
    }

    private var hoverStrokeOpacity: Double {
        isEnabled && isHovered ? 0.24 : 0.0
    }

    private var hoverAnimation: Animation {
        reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.2, dampingFraction: 0.75)
    }

    private var labelContent: some View {
        Group {
            if iconTrailing {
                HStack(spacing: 6) {
                    Text(title)
                        .font(labelFont)

                    Image(systemName: icon)
                        .font(iconFont)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(iconFont)

                    Text(title)
                        .font(labelFont)
                }
            }
        }
        .foregroundStyle(foregroundColor)
        .padding(.top, 5 + paddingTop)
        .padding(.bottom, 5 + paddingBottom)
        .padding(.leading, 10 + paddingLeading)
        .padding(.trailing, 10 + paddingTrailing)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(hoverFillOpacity)),
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(hoverStrokeOpacity), lineWidth: 0.5),
        )
        .scaleEffect(isEnabled && isHovered && !reduceMotion ? 1.02 : 1.0)
    }

    var body: some View {
        Button(action: { action?(buttonFrame) }) {
            labelContent
                .frame(minHeight: ProjectCardActionMetrics.buttonMinHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ButtonFramePreferenceKey.self,
                    value: geo.frame(in: .named("contentView")),
                )
            },
        )
        .onPreferenceChange(ButtonFramePreferenceKey.self) { frame in
            buttonFrame = frame
        }
        .onHover { hovering in
            withAnimation(hoverAnimation) {
                isHovered = isEnabled && hovering
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private static func fontWeight(from value: Int) -> Font.Weight {
        switch value {
        case 1: .ultraLight
        case 2: .thin
        case 3: .light
        case 4: .regular
        case 5: .medium
        case 6: .semibold
        case 7: .bold
        case 8: .heavy
        case 9: .black
        default: .medium
        }
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

// Note: StatusIndicator is in ProjectCardComponents.swift

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
