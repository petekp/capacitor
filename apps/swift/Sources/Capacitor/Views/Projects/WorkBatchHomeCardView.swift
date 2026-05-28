import SwiftUI

struct WorkBatchHomeCardView: View {
    let project: Project
    let batch: WorkBatchProjection
    let isActive: Bool
    let flashState: SessionState?
    let onOpenCockpit: () -> Void
    let onOpenPreview: (() -> Void)?
    let onUnresolve: (WorkBatchTaskRecord) -> Void
    let onCheckpointResponse: (WorkBatchCheckpointRecord, String) -> Void

    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion
    @AppStorage("playReadyChime") private var playReadyChime = true

    @State private var interactionState = ProjectCardInteractionState()
    @State private var isTaskPopoverPresented = false

    private let glassConfig = GlassConfig.shared

    private var currentState: SessionState {
        if !batch.pendingCheckpoints.isEmpty {
            return .waiting
        }
        return batch.status.sessionState
    }

    private var cardScale: CGFloat {
        interactionState.cardScale(
            layoutMode: .vertical,
            reduceMotion: reduceMotion,
            isDragging: false,
            config: glassConfig,
        )
    }

    private var cardAnimation: Animation {
        interactionState.cardAnimation(
            layoutMode: .vertical,
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
        glassConfig.cardCornerRadius(for: .vertical)
    }

    private var rippleDuration: Double {
        #if DEBUG
            glassConfig.highlightRippleDuration
        #else
            0.63
        #endif
    }

    var body: some View {
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
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(batch.name)
            .accessibilityValue("\(batch.status.label), \(batch.queuedTaskCount) queued tasks")
            .accessibilityAction(named: "Open Claude Code Session", onOpenCockpit)
            .accessibilityAction(named: "Show Tasks") {
                isTaskPopoverPresented = true
            }
            .applyIf(onOpenPreview) { view, action in
                view.accessibilityAction(named: batch.preview?.actionLabel ?? "Open Preview", action)
            }
            .onHover(perform: updateHover)
            .cardLifecycleHandlers(
                projectPath: "\(project.path)#\(batch.id)",
                flashState: flashState,
                currentState: currentState,
                flashOpacity: $interactionState.flashOpacity,
                playReadyChime: playReadyChime,
            )
            .contextMenu { cardContextMenu }
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

    private var styledCard: some View {
        cardContent
            .cardStyling(
                isHovered: interactionState.isHovered,
                currentState: currentState,
                isActive: isActive,
                flashState: flashState,
                flashOpacity: interactionState.flashOpacity,
                floatingMode: floatingMode,
                floatingCardBackground: floatingCardBackground,
                solidCardBackground: solidCardBackground,
                animationSeed: "\(project.path)#\(batch.id)",
                layoutMode: .vertical,
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

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(batch.name)
                        .font(AppTypography.cardTitle.monospaced())
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    StatusChip(state: currentState)
                }

                Text(batch.currentActivitySummary)
                    .font(AppTypography.bodySecondary)
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(verticalContentPadding)

            WorkBatchHomeActionBar(
                isCardHovered: interactionState.isHovered,
                batch: batch,
                onShowTasks: { isTaskPopoverPresented = true },
                onOpenPreview: onOpenPreview,
            )
            .popover(isPresented: $isTaskPopoverPresented, arrowEdge: .trailing) {
                WorkBatchHomeTaskPopover(
                    batch: batch,
                    onUnresolve: onUnresolve,
                    onCheckpointResponse: onCheckpointResponse,
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var pressRipple: some View {
        MetallicPressHighlight(
            pressPoint: interactionState.pressPoint,
            cardSize: interactionState.cardSize,
            cornerRadius: cornerRadius,
            intensity: glassConfig.cardPressRippleOpacity,
            pressStartTime: interactionState.pressStartTime,
        )
    }

    private var floatingCardBackground: some View {
        DarkFrostedCard(isHovered: interactionState.isHovered, layoutMode: .vertical, config: glassConfig)
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

    private var cardContextMenu: some View {
        Group {
            Button(action: onOpenCockpit) {
                Label("Open Claude Code Session", systemImage: "terminal")
            }
            Button(action: { isTaskPopoverPresented = true }) {
                Label("Show Tasks", systemImage: "list.bullet")
            }
            if let onOpenPreview {
                Button(action: onOpenPreview) {
                    Label(batch.preview?.actionLabel ?? "Open Preview", systemImage: batch.preview?.homeSymbolName ?? "eye")
                }
                .disabled(batch.preview?.isActionEnabled == false)
            }
        }
    }

    private func handleTap() {
        if interactionState.pressStartTime == nil {
            interactionState.pressPoint = interactionState.cursorLocation
            interactionState.pressStartTime = Date()
        }
        onOpenCockpit()
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
}

private struct WorkBatchHomeActionBar: View {
    let isCardHovered: Bool
    let batch: WorkBatchProjection
    let onShowTasks: () -> Void
    let onOpenPreview: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onShowTasks) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .semibold))
                    Text(taskButtonTitle)
                        .font(AppTypography.labelMedium)
                }
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show \(taskButtonTitle)")

            if let preview = batch.preview {
                Button(action: { onOpenPreview?() }) {
                    Image(systemName: preview.homeSymbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(preview.homeIconColor)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .disabled(!preview.isActionEnabled || onOpenPreview == nil)
                .accessibilityLabel(preview.actionLabel)
                .help(preview.reason ?? preview.actionLabel)
            }

            Spacer(minLength: 0)

            if let preview = batch.preview {
                HStack(spacing: 6) {
                    Circle()
                        .fill(preview.homeIconColor)
                        .frame(width: 5, height: 5)

                    Text(preview.label)
                        .font(AppTypography.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
        }
        .opacity(isCardHovered ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isCardHovered)
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
        .contentShape(.rect)
        .onTapGesture {}
    }

    private var taskButtonTitle: String {
        let count = batch.tasks.count
        return "\(count) \(count == 1 ? "Task" : "Tasks")"
    }
}

private struct WorkBatchHomeTaskPopover: View {
    let batch: WorkBatchProjection
    let onUnresolve: (WorkBatchTaskRecord) -> Void
    let onCheckpointResponse: (WorkBatchCheckpointRecord, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(batch.name)
                    .font(AppTypography.sectionTitle.monospaced())
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 0)

                StatusChip(state: batch.pendingCheckpoints.isEmpty ? batch.status.sessionState : .waiting, style: .compact)
            }

            if !batch.pendingCheckpoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Needs You")
                        .font(AppTypography.label.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.orange.opacity(0.82))

                    ForEach(batch.pendingCheckpoints) { checkpoint in
                        WorkBatchHomeCheckpointCard(
                            checkpoint: checkpoint,
                            onSubmit: { response in
                                onCheckpointResponse(checkpoint, response)
                            },
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Tasks")
                    .font(AppTypography.label.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.45))

                if batch.tasks.isEmpty {
                    Text("No Tasks yet")
                        .font(AppTypography.bodySecondary)
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    ForEach(batch.tasks) { task in
                        WorkBatchHomeTaskRow(task: task, onUnresolve: { onUnresolve(task) })
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(Color.hudCard)
    }
}

private struct WorkBatchHomeTaskRow: View {
    let task: WorkBatchTaskRecord
    let onUnresolve: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(task.status.homeDotColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayTitle)
                    .font(AppTypography.bodySecondary)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)

                Text(task.status.homeLabel)
                    .font(AppTypography.captionSmall.weight(.semibold))
                    .foregroundStyle(task.status.homeDotColor)
            }

            Spacer(minLength: 8)

            if task.status == .done {
                Button(action: onUnresolve) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reopen \(task.displayTitle)")
                .help("Reopen Task")
            }
        }
    }
}

private struct WorkBatchHomeCheckpointCard: View {
    let checkpoint: WorkBatchCheckpointRecord
    let onSubmit: (String) -> Void

    @State private var response = ""

    private var trimmedResponse: String {
        response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(checkpoint.question)
                .font(AppTypography.bodySecondary.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)

            let reason = checkpoint.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty {
                Text(reason)
                    .font(AppTypography.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .center, spacing: 8) {
                TextField("Answer", text: $response, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppTypography.bodySecondary)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1 ... 3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button(action: {
                    onSubmit(trimmedResponse)
                    response = ""
                }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(trimmedResponse.isEmpty ? .white.opacity(0.25) : .white.opacity(0.82))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(trimmedResponse.isEmpty)
                .accessibilityLabel("Answer checkpoint")
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1),
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension WorkBatchPreviewProjection {
    var homeSymbolName: String {
        switch status {
        case .previewAvailable:
            "play.rectangle"
        case .previewUnavailable:
            label == "Preview already open" ? "exclamationmark.triangle" : "eye.slash"
        case .previewBuilding:
            "hourglass"
        case .readyToInspect:
            "eye"
        case .previewFailed:
            "exclamationmark.triangle"
        }
    }

    var homeIconColor: Color {
        switch status {
        case .previewAvailable:
            .white.opacity(0.66)
        case .previewUnavailable:
            .white.opacity(0.38)
        case .previewBuilding:
            .blue.opacity(0.85)
        case .readyToInspect:
            .green.opacity(0.78)
        case .previewFailed:
            .orange.opacity(0.85)
        }
    }
}

private extension WorkBatchTaskStatus {
    var homeLabel: String {
        switch self {
        case .queued:
            "Queued"
        case .working:
            "Working"
        case .needsYou:
            "Needs You"
        case .done:
            "Done"
        }
    }

    var homeDotColor: Color {
        switch self {
        case .queued:
            .white.opacity(0.45)
        case .working:
            .blue.opacity(0.85)
        case .needsYou:
            .orange.opacity(0.9)
        case .done:
            .green.opacity(0.75)
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
}
