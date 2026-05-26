import SwiftUI

// MARK: - Main Card Views

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let delegationState: RuntimeDelegationState?
    let activeRunState: RuntimeRunState?
    let projectStatus: ProjectStatus?
    var workBatchSummary: String?
    var sessionSummary: String?
    let flashState: SessionState?
    let isActive: Bool
    let onTap: () -> Void
    let onInfoTap: (() -> Void)?
    let onMoveToDormant: () -> Void
    var onCaptureIdea: ((CGRect) -> Void)?
    let onRemove: () -> Void
    var onDragStarted: (() -> NSItemProvider)?
    var isDragging: Bool = false

    var body: some View {
        ProjectCard(
            layoutMode: .vertical,
            project: project,
            sessionState: sessionState,
            delegationState: delegationState,
            activeRunState: activeRunState,
            projectStatus: projectStatus,
            workBatchSummary: workBatchSummary,
            sessionSummary: sessionSummary,
            flashState: flashState,
            isActive: isActive,
            onTap: onTap,
            onInfoTap: onInfoTap,
            onMoveToDormant: onMoveToDormant,
            onCaptureIdea: onCaptureIdea,
            onRemove: onRemove,
            onDragStarted: onDragStarted,
            isDragging: isDragging,
        )
    }
}

struct ProjectCardInteractionState {
    var isHovered = false
    var isPressed = false
    var flashOpacity: Double = 0
    var cursorLocation: CGPoint = .zero
    var pressPoint: CGPoint = .zero
    var cardSize: CGSize = .zero
    var distortionIntensity: Double = 0
    var pressStartTime: Date?
    func cardScale(
        layoutMode: LayoutMode,
        reduceMotion: Bool,
        isDragging: Bool,
        config: GlassConfig = .shared,
    ) -> CGFloat {
        guard !reduceMotion else { return 1.0 }
        if isPressed || isDragging {
            return config.cardPressedScale(for: layoutMode)
        } else if isHovered {
            return config.cardHoverScale(for: layoutMode)
        }
        return config.cardIdleScale(for: layoutMode)
    }

    func cardAnimation(
        layoutMode: LayoutMode,
        reduceMotion: Bool,
        config: GlassConfig = .shared,
    ) -> Animation {
        guard !reduceMotion else { return AppMotion.reducedMotionFallback }
        if isPressed {
            return .spring(
                response: config.cardPressedSpringResponse(for: layoutMode),
                dampingFraction: config.cardPressedSpringDamping(for: layoutMode),
            )
        }
        return .spring(
            response: config.cardHoverSpringResponse(for: layoutMode),
            dampingFraction: config.cardHoverSpringDamping(for: layoutMode),
        )
    }

    func pressTiltX(reduceMotion: Bool, config: GlassConfig = .shared) -> Double {
        guard isPressed, !reduceMotion, cardSize.height > 0 else { return 0 }
        let normalizedY = (pressPoint.y / cardSize.height - 0.5) * 2
        return -normalizedY * config.cardPressTiltVertical
    }

    func pressTiltY(reduceMotion: Bool, config: GlassConfig = .shared) -> Double {
        guard isPressed, !reduceMotion, cardSize.width > 0 else { return 0 }
        let normalizedX = (pressPoint.x / cardSize.width - 0.5) * 2
        return normalizedX * config.cardPressTiltHorizontal
    }

    func tiltAnimation(reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return AppMotion.reducedMotionFallback }
        if isPressed {
            return .spring(response: 0.15, dampingFraction: 0.6)
        }
        return .spring(response: 0.35, dampingFraction: 0.75)
    }
}

struct ProjectCard: View {
    let layoutMode: LayoutMode
    let project: Project
    let sessionState: ProjectSessionState?
    let delegationState: RuntimeDelegationState?
    let activeRunState: RuntimeRunState?
    let projectStatus: ProjectStatus?
    var workBatchSummary: String?
    var sessionSummary: String?
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

    @State private var interactionState = ProjectCardInteractionState()
    @State private var trackedRunVisualState: RunVisualState
    private let glassConfig = GlassConfig.shared
    init(
        layoutMode: LayoutMode,
        project: Project,
        sessionState: ProjectSessionState?,
        delegationState: RuntimeDelegationState?,
        activeRunState: RuntimeRunState?,
        projectStatus: ProjectStatus?,
        workBatchSummary: String? = nil,
        sessionSummary: String? = nil,
        flashState: SessionState?,
        isActive: Bool,
        onTap: @escaping () -> Void,
        onInfoTap: (() -> Void)? = nil,
        onMoveToDormant: @escaping () -> Void,
        onCaptureIdea: ((CGRect) -> Void)? = nil,
        onRemove: @escaping () -> Void,
        onDragStarted: (() -> NSItemProvider)? = nil,
        isDragging: Bool = false,
    ) {
        self.layoutMode = layoutMode
        self.project = project
        self.sessionState = sessionState
        self.delegationState = delegationState
        self.activeRunState = activeRunState
        self.projectStatus = projectStatus
        self.workBatchSummary = workBatchSummary
        self.sessionSummary = sessionSummary
        self.flashState = flashState
        self.isActive = isActive
        self.onTap = onTap
        self.onInfoTap = onInfoTap
        self.onMoveToDormant = onMoveToDormant
        self.onCaptureIdea = onCaptureIdea
        self.onRemove = onRemove
        self.onDragStarted = onDragStarted
        self.isDragging = isDragging
        _trackedRunVisualState = State(
            initialValue: ProjectRunVisualStateResolver.visualState(for: activeRunState),
        )
    }

    private var rawRunVisualState: RunVisualState {
        ProjectRunVisualStateResolver.visualState(for: activeRunState)
    }

    private var visibleRunVisualState: RunVisualState {
        layoutMode == .dock ? trackedRunVisualState : rawRunVisualState
    }

    private var dockPresentation: DockProjectCardPresentation {
        DockProjectCardPresentation.resolve(
            sessionState: sessionState,
            trackedRunVisualState: trackedRunVisualState,
        )
    }

    private var currentState: SessionState {
        if layoutMode == .dock {
            return dockPresentation.currentState
        }
        return visibleRunVisualState.sessionState ?? sessionState?.state ?? .idle
    }

    private var nameColor: Color {
        project.isMissing ? .white.opacity(0.5) : .white.opacity(0.9)
    }

    private var cardScale: CGFloat {
        interactionState.cardScale(
            layoutMode: layoutMode,
            reduceMotion: reduceMotion,
            isDragging: isDragging,
            config: glassConfig,
        )
    }

    private var cardAnimation: Animation {
        interactionState.cardAnimation(
            layoutMode: layoutMode,
            reduceMotion: reduceMotion,
            config: glassConfig,
        )
    }

    private var tiltAnimation: Animation {
        interactionState.tiltAnimation(reduceMotion: reduceMotion)
    }

    private var pressTiltX: Double {
        interactionState.pressTiltX(reduceMotion: reduceMotion, config: glassConfig)
    }

    private var pressTiltY: Double {
        interactionState.pressTiltY(reduceMotion: reduceMotion, config: glassConfig)
    }

    private var cornerRadius: CGFloat {
        glassConfig.cardCornerRadius(for: layoutMode)
    }

    private var telemetrySource: String {
        layoutMode == .dock ? "DockProjectCard" : "ProjectCardView"
    }

    private var delegationStatus: String? {
        delegationState?.status
    }

    private var resolvedContextLine: String? {
        ProjectCardContextLineResolver.resolve(.init(
            runVisualState: visibleRunVisualState,
            activeRunState: activeRunState,
            delegationState: delegationState,
            projectStatus: projectStatus,
            workBatchSummary: workBatchSummary,
            sessionSummary: sessionSummary,
        ))
    }

    private var contextLine: String? {
        layoutMode == .dock ? dockPresentation.contextLine : resolvedContextLine
    }

    private var hasOpenDelegationReview: Bool {
        guard let delegationState else { return false }
        return delegationState.currentReview != nil
            && (delegationState.status == "review_needed" || delegationState.status == "resume_failed")
    }

    private var accessibilityStatusDescription: String {
        guard layoutMode == .vertical else { return currentState.accessibilityStatusDescription }

        if let runState = visibleRunVisualState.sessionState {
            return runState.accessibilityStatusDescription
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
        return currentState.accessibilityStatusDescription
    }

    private var primaryAccessibilityActionName: String {
        guard layoutMode == .vertical else { return "Open in Terminal" }

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

    private var accessibilityHintText: String? {
        guard layoutMode == .vertical else { return nil }

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

    private var rippleDuration: Double {
        #if DEBUG
            glassConfig.highlightRippleDuration
        #else
            0.63
        #endif
    }

    private var verticalContentPadding: EdgeInsets {
        #if DEBUG
            EdgeInsets(
                top: glassConfig.cardPaddingTopRounded,
                leading: glassConfig.cardPaddingLeadingRounded,
                bottom: glassConfig.cardPaddingBottomRounded,
                trailing: glassConfig.cardPaddingTrailingRounded,
            )
        #else
            EdgeInsets(top: 14, leading: 12, bottom: 8, trailing: 12)
        #endif
    }

    @ViewBuilder
    private var cardBodyContent: some View {
        switch layoutMode {
        case .vertical:
            verticalCardContent
        case .dock:
            dockWrappedContent
        }
    }

    private var verticalCardContent: some View {
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
                    contextLine: contextLine,
                    isMissing: project.isMissing,
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(verticalContentPadding)

            ProjectCardActionBar(
                isCardHovered: interactionState.isHovered,
                onCaptureIdea: onCaptureIdea,
                onDetails: onInfoTap,
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dockWrappedContent: some View {
        let dockWidth = glassConfig.dockCardWidthRounded
        let dockMinHeight = glassConfig.dockCardMinHeightRounded
        let dockMaxHeight = glassConfig.dockCardMaxHeightRounded

        return dockCardContent
            .padding(.horizontal, glassConfig.dockCardPaddingH)
            .padding(.vertical, glassConfig.dockCardPaddingV)
            .frame(width: dockWidth)
            .frame(
                minHeight: dockMinHeight > 0 ? dockMinHeight : nil,
                maxHeight: dockMaxHeight > 0 ? dockMaxHeight : nil,
            )
    }

    private var dockCardContent: some View {
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

                StatusChipsRow(
                    sessionState: sessionState,
                    delegationState: delegationState,
                    activeRunState: activeRunState,
                    style: .compact,
                )
                .padding(.top, glassConfig.dockChipTopPaddingRounded)

                HStack(spacing: 4) {
                    Text(contextLine ?? " ")
                        .font(AppTypography.bodySecondary)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(contextLine)
                        .transition(reduceMotion ? .opacity : .push(from: .bottom))
                }
                .opacity(contextLine != nil ? 1 : 0)
                .clipped()
                .animation(
                    reduceMotion ? AppMotion.reducedMotionFallback : .smooth(duration: 0.3),
                    value: contextLine,
                )
                .padding(.top, 4)

                Spacer(minLength: 0)

                if delegationState?.status == "review_needed", delegationState?.currentReview != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "text.badge.star")
                            .font(AppTypography.captionSmall)
                        Text("Review brief ready")
                            .font(AppTypography.label)
                            .lineLimit(1)
                    }
                    .foregroundColor(.orange.opacity(0.9))
                    .padding(.top, 4)
                }

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
                isCardHovered: interactionState.isHovered,
                onCaptureIdea: onCaptureIdea,
                onDetails: onInfoTap,
                style: .compact,
            )
        }
    }

    private var styledCard: some View {
        cardBodyContent
            .cardStyling(
                isHovered: interactionState.isHovered,
                currentState: currentState,
                isActive: isActive,
                flashState: flashState,
                flashOpacity: interactionState.flashOpacity,
                floatingMode: floatingMode,
                floatingCardBackground: floatingCardBackground,
                solidCardBackground: solidCardBackground,
                animationSeed: project.path,
                layoutMode: layoutMode,
                isPressed: interactionState.isPressed,
            )
            .pressDistortion(
                pressPoint: interactionState.pressPoint,
                cardSize: interactionState.cardSize,
                intensity: interactionState.distortionIntensity,
            )
            .overlay { pressRipple }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    interactionState.cursorLocation = location
                case .ended:
                    break
                }
            }
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { interactionState.cardSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in interactionState.cardSize = newSize }
                }
            }
    }

    private var interactiveCard: some View {
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
            .onChange(of: rawRunVisualState) { _, newValue in
                guard layoutMode == .dock else { return }
                withAnimation(.easeInOut(duration: glassConfig.stateTransitionDuration)) {
                    trackedRunVisualState = newValue
                }
            }
            .onLongPressGesture(minimumDuration: .infinity, pressing: updatePressedState, perform: {})
            .task(id: interactionState.pressStartTime) {
                guard interactionState.pressStartTime != nil else { return }
                do {
                    try await _Concurrency.Task.sleep(for: .milliseconds(Int(rippleDuration * 1000)))
                } catch {
                    return
                }
                interactionState.pressStartTime = nil
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: handleTap)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .onHover(perform: updateHover)
            .onDrag { dragItemProvider() } preview: { dragPreview }
            .cardLifecycleHandlers(
                projectPath: project.path,
                flashState: flashState,
                currentState: currentState,
                flashOpacity: $interactionState.flashOpacity,
                playReadyChime: playReadyChime,
            )
            .contextMenu { cardContextMenu }
            .applyIf(layoutMode == .vertical) { view in
                view
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.return) {
                        handleTap()
                        return .handled
                    }
                    .onKeyPress(.space) {
                        handleTap()
                        return .handled
                    }
            }
    }

    var body: some View {
        #if DEBUG
            let _ = ProjectCardRenderTelemetry.logIfChanged(
                path: project.path,
                name: project.name,
                state: currentState,
                source: telemetrySource,
            )
        #endif

        interactiveCard
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityIdentifiers.projectCardIdentifier(for: project))
            .accessibilityLabel(project.name)
            .accessibilityValue(accessibilityStatusDescription)
            .accessibilityAction(named: primaryAccessibilityActionName, onTap)
            .applyIf(onInfoTap) { view, action in
                view.accessibilityAction(named: "View Details", action)
            }
            .applyIf(accessibilityHintText) { view, hint in
                view.accessibilityHint(hint)
            }
            .applyIf(layoutMode == .vertical ? onMoveToDormant : nil) { view, action in
                view.accessibilityAction(named: "Hide", action)
            }
    }

    private var pressRipple: some View {
        MetallicPressHighlight(
            pressPoint: interactionState.pressPoint,
            cardSize: interactionState.cardSize,
            cornerRadius: cornerRadius,
            intensity: glassConfig.cardPressRippleOpacity,
            pressStartTime: interactionState.pressStartTime,
        )
    }

    private var cardContextMenu: some View {
        ProjectContextMenu(
            project: project,
            onTap: onTap,
            onInfoTap: onInfoTap,
            onMoveToDormant: onMoveToDormant,
            onCaptureIdea: onCaptureIdea.map { action in { action(.zero) } },
            onRemove: onRemove,
        )
    }

    private var floatingCardBackground: some View {
        DarkFrostedCard(isHovered: interactionState.isHovered, layoutMode: layoutMode, config: glassConfig)
    }

    private var solidCardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.hudCard)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(interactionState.isHovered ? 0.08 : 0.04), .clear],
                    startPoint: .top,
                    endPoint: .bottom,
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    private var dragPreview: some View {
        if layoutMode == .dock {
            Text(project.name)
                .font(AppTypography.sectionTitle.monospaced())
                .padding(8)
                .background(Color.hudCard.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func handleTap() {
        if interactionState.pressStartTime == nil {
            interactionState.pressPoint = interactionState.cursorLocation
            interactionState.pressStartTime = Date()
        }
        onTap()
    }

    private func updateHover(_ hovering: Bool) {
        withAnimation(.easeOut(duration: glassConfig.hoverTransitionDuration)) {
            interactionState.isHovered = hovering
        }
    }

    private func updatePressedState(_ pressing: Bool) {
        if pressing {
            interactionState.pressPoint = interactionState.cursorLocation
            interactionState.pressStartTime = Date()
        }
        interactionState.isPressed = pressing
        let target = pressing ? glassConfig.cardPressDistortion : 0
        withAnimation(pressing
            ? .spring(response: 0.12, dampingFraction: 0.55)
            : .spring(response: 0.4, dampingFraction: 0.8))
        {
            interactionState.distortionIntensity = target
        }
    }

    private func dragItemProvider() -> NSItemProvider {
        _ = onDragStarted?()
        if layoutMode == .dock {
            return NSItemProvider(object: project.path as NSString)
        }
        return NSItemProvider(object: "" as NSString)
    }
}

#if DEBUG
    @MainActor
    private enum ProjectCardRenderTelemetry {
        private static var lastByPath: [String: String] = [:]

        static func logIfChanged(path: String, name: String, state: SessionState?, source: String) {
            let label = state.map(\.telemetryLabel) ?? "nil"
            let summary = "\(name):\(label)"
            guard lastByPath[path] != summary else { return }
            lastByPath[path] = summary
            DebugLog.write("[DEBUG][\(source)][CardState] \(summary) path=\(path)")
        }
    }
#endif

private extension SessionState {
    var accessibilityStatusDescription: String {
        switch self {
        case .ready: "Ready for input"
        case .working: "Working"
        case .waiting: "Waiting for user action"
        case .compacting: "Compacting history"
        case .idle: "Idle"
        }
    }

    var telemetryLabel: String {
        switch self {
        case .working: "Working"
        case .ready: "Ready"
        case .idle: "Idle"
        case .compacting: "Compacting"
        case .waiting: "Waiting"
        }
    }
}

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
    @State private var displayedLine: String?
    /// Pending commit task — cancelled if the value changes again before the
    /// stabilization window elapses, preventing animated flicker from transient
    /// nil/non-nil run-status wobble.
    @State private var pendingCommit: _Concurrency.Task<Void, Never>?

    /// How long a new context line value must persist before committing to the UI.
    /// Covers one polling cycle worth of transient state wobble.
    private static let stabilizationDelay: Duration = .milliseconds(400)

    var body: some View {
        VStack(spacing: 0) {
            Text(displayedLine ?? " ")
                .font(AppTypography.bodySecondary)
                .foregroundStyle(isMissing ? .white.opacity(0.4) : .white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
                .id(displayedLine)
                .transition(reduceMotion ? .opacity : .push(from: .bottom).combined(with: .opacity))
                .opacity(displayedLine != nil ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
        .onAppear { displayedLine = contextLine }
        .onChange(of: contextLine) { _, newValue in
            guard newValue != displayedLine else {
                pendingCommit?.cancel()
                pendingCommit = nil
                return
            }
            pendingCommit?.cancel()
            if reduceMotion {
                displayedLine = newValue
                pendingCommit = nil
            } else {
                pendingCommit = _Concurrency.Task { @MainActor in
                    try? await _Concurrency.Task.sleep(for: Self.stabilizationDelay)
                    guard !_Concurrency.Task.isCancelled else { return }
                    withAnimation(.smooth(duration: 0.35)) {
                        displayedLine = newValue
                    }
                    pendingCommit = nil
                }
            }
        }
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
                title: TaskCaptureSurfaceCopy.cardActionTitle,
                accessibilityLabel: TaskCaptureSurfaceCopy.cardActionAccessibilityLabel,
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
                .help(TaskCaptureSurfaceCopy.cardActionHelp)
                .accessibilityLabel(TaskCaptureSurfaceCopy.cardActionAccessibilityLabel)
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

private extension View {
    @ViewBuilder
    func applyIf<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }

    @ViewBuilder
    func applyIf(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
