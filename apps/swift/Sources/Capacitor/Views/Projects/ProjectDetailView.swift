import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.openWindow) private var openWindow
    let project: Project

    @State private var appeared = false
    @State private var selectedIdea: Idea?
    @State private var selectedIdeaFrame: CGRect?
    @State private var methodSelectorIdea: Idea?
    @State private var openReceiptWindowAfterCapture = false

    private var isModalOpen: Bool {
        selectedIdea != nil || methodSelectorIdea != nil
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(project.name)
                        .font(AppTypography.pageTitle.monospaced())
                        .foregroundColor(.white)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)

                    if appState.featureState.isLlmFeaturesEnabled {
                        DescriptionSection(
                            description: appState.getDescription(for: project),
                            isGenerating: appState.isGeneratingDescription(for: project),
                            onGenerate: { appState.generateDescription(for: project) },
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                    }

                    if appState.featureState.isIdeaCaptureEnabled {
                        WorkBatchListSection(
                            batches: appState.workBatches(for: project),
                            checkpointFocusTarget: checkpointFocusTargetForProject,
                            onOpen: { batch in
                                appState.openWorkBatch(
                                    batch,
                                    for: project,
                                    source: batch.pendingCheckpoints.isEmpty ? .workBatchCard : .checkpointRow,
                                )
                            },
                            onOpenCockpit: { batch in
                                appState.openWorkBatchCockpit(batch, source: .terminalIcon)
                            },
                            onUnresolve: { batch, task in
                                appState.unresolveWorkBatchTask(task, in: batch, for: project)
                            },
                            onCheckpointResponse: { batch, checkpoint, response in
                                appState.submitWorkBatchCheckpointResponse(
                                    checkpoint,
                                    in: batch,
                                    for: project,
                                    response: response,
                                )
                            },
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 14)

                        VStack(alignment: .leading, spacing: 12) {
                            let ideas = appState.getIdeas(for: project)
                            DetailSectionLabel(
                                title: "TASKS",
                                count: IdeaQueueMetrics.queuedCount(in: ideas),
                                countAccessibilityLabel: "\(IdeaQueueMetrics.queuedCount(in: ideas)) queued tasks",
                            )

                            let delegationState = appState.delegationState(for: project)
                            IdeaQueueView(
                                ideas: ideas,
                                activityForIdea: { idea in
                                    IdeaQueueStatusResolver.resolve(
                                        idea: idea,
                                        isGeneratingTitle: appState.isGeneratingTitle(for: idea.id),
                                        delegationState: delegationState,
                                        runState: appState.activeRun(for: idea, in: project),
                                    )
                                },
                                onTapIdea: { idea, frame in
                                    selectedIdea = idea
                                    selectedIdeaFrame = frame
                                },
                                onReorder: { reorderedIdeas in
                                    appState.reorderIdeas(reorderedIdeas, for: project)
                                },
                                onRemove: { idea in
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        appState.dismissIdea(idea, for: project)
                                    }
                                },
                            )
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                    }

                    if appState.featureState.isMethodRunnerEnabled {
                        let timelineRun = appState.checkpointTimelineRun(for: project)
                        let timelineProjection = timelineRun.flatMap { RunCheckpointTimelineProjection(run: $0) }

                        if let completionRun = completionBriefRun(
                            timelineRun: timelineRun,
                            visibleRun: appState.activeRun(for: project),
                        ),
                            let completionBrief = ProjectCompletionBriefProjection.make(
                                project: project,
                                run: completionRun,
                                timeline: completionTimeline(
                                    for: completionRun,
                                    timelineRun: timelineRun,
                                    timelineProjection: timelineProjection,
                                ),
                            )
                        {
                            ProjectCompletionBriefSection(projection: completionBrief)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 18)
                        }

                        if let run = timelineRun,
                           let projection = timelineProjection
                        {
                            ProjectCaseFileSection(projection: ProjectCaseFileProjection.make(
                                project: project,
                                run: run,
                                timeline: projection,
                                viewState: appState.operatorViewStateSnapshot,
                            ))
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 18)

                            RunCheckpointTimelineSection(projection: projection)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 20)
                        }
                    }

                    Button(action: {
                        appState.removeProject(project.path)
                        appState.showProjectList()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "minus.circle")
                            Text("Disconnect")
                        }
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, floatingMode ? 44 : 12)
                .padding(.bottom, floatingMode ? 64 : 16)
            }
            .blur(radius: isModalOpen ? 8 : 0)
            .saturation(isModalOpen ? 0.8 : 1)
            .animation(.easeInOut(duration: 0.25), value: isModalOpen)
            .background(floatingMode ? Color.clear : Color.hudBackground)

            if appState.featureState.isIdeaCaptureEnabled {
                IdeaDetailModalOverlay(
                    idea: selectedIdea,
                    anchorFrame: selectedIdeaFrame,
                    orchestrationActivity: selectedIdea.flatMap { ideaActivity(for: $0) },
                    onDismiss: {
                        dismissIdeaDetail()
                    },
                    onReview: reviewHandlerForSelectedIdea(),
                    onDelegate: appState.featureState.isDelegationLoopEnabled ? { idea in
                        appState.delegateIdea(idea, for: project)
                        dismissIdeaDetail()
                    } : nil,
                    onRunMethod: appState.featureState.isMethodRunnerEnabled ? { idea in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            methodSelectorIdea = idea
                            dismissIdeaDetail()
                        }
                    } : nil,
                    onRemove: { idea in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            appState.dismissIdea(idea, for: project)
                        }
                        dismissIdeaDetail()
                    },
                )

                if let idea = methodSelectorIdea {
                    MethodSelectorModalOverlay(
                        methods: appState.listBuiltinMethods(),
                        runIntent: IdeaRunIntent.project(idea),
                        onSelect: { method in
                            if CircuitReceiptGoalPacketMethod.isReceiptGoalPacket(method) {
                                openReceiptWindowAfterCapture = true
                            }
                            appState.runMethodOnIdea(idea, method: method, for: project)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                methodSelectorIdea = nil
                            }
                        },
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                methodSelectorIdea = nil
                            }
                        },
                    )
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
        .task(id: caseFileSeenIdentity) {
            markCaseFileSeen()
        }
        .onExitCommand {
            appState.showProjectList()
        }
        .onReceive(NotificationCenter.default.publisher(for: .circuitFirstSliceDidCapture)) { _ in
            guard openReceiptWindowAfterCapture else { return }
            openReceiptWindowAfterCapture = false
            openWindow(id: CircuitFirstSliceWindowID.claudeReceiptRendering)
        }
        .onReceive(NotificationCenter.default.publisher(for: .circuitFirstSliceDidFail)) { _ in
            openReceiptWindowAfterCapture = false
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.projectDetailViewIdentifier(for: project))
    }

    private func ideaActivity(for idea: Idea) -> IdeaQueueActivity? {
        IdeaQueueStatusResolver.resolve(
            idea: idea,
            isGeneratingTitle: appState.isGeneratingTitle(for: idea.id),
            delegationState: appState.delegationState(for: project),
            runState: appState.activeRun(for: idea, in: project),
        )
    }

    private func reviewHandlerForSelectedIdea() -> ((Idea) -> Void)? {
        guard let selectedIdea, canOpenReview(for: selectedIdea) else { return nil }
        return { idea in
            openReview(for: idea)
        }
    }

    private func canOpenReview(for idea: Idea) -> Bool {
        if hasDelegationReview(for: idea) {
            return true
        }

        if let run = appState.activeRun(for: idea, in: project),
           run.status == "paused",
           run.activeCheckpoint != nil
        {
            return true
        }

        return false
    }

    private func hasDelegationReview(for idea: Idea) -> Bool {
        guard let delegation = appState.delegationState(for: project),
              delegation.ideaId == idea.id,
              delegation.currentReview != nil
        else {
            return false
        }
        return delegation.status == "review_needed" || delegation.status == "resume_failed"
    }

    private func openReview(for idea: Idea) {
        if hasDelegationReview(for: idea) {
            appState.showDelegationReview(project)
            openWindow(id: "delegation-review")
            dismissIdeaDetail()
            return
        }

        if let run = appState.activeRun(for: idea, in: project),
           run.status == "paused",
           run.activeCheckpoint != nil
        {
            appState.showRunCheckpointReview(for: run)
            openWindow(id: "run-checkpoint-review")
            dismissIdeaDetail()
            return
        }
    }

    private func dismissIdeaDetail() {
        selectedIdea = nil
        selectedIdeaFrame = nil
    }

    private func completionBriefRun(
        timelineRun: RuntimeRunState?,
        visibleRun: RuntimeRunState?,
    ) -> RuntimeRunState? {
        if let visibleRun {
            return visibleRun.status == "completed" ? visibleRun : nil
        }

        if timelineRun?.status == "completed" {
            return timelineRun
        }

        return nil
    }

    private func completionTimeline(
        for run: RuntimeRunState,
        timelineRun: RuntimeRunState?,
        timelineProjection: RunCheckpointTimelineProjection?,
    ) -> RunCheckpointTimelineProjection? {
        guard timelineRun?.id == run.id else { return nil }
        return timelineProjection
    }

    private var caseFileSeenIdentity: String {
        guard let run = appState.checkpointTimelineRun(for: project) else {
            return "project:\(PathNormalizer.normalize(project.path))"
        }

        return ([
            "project:\(PathNormalizer.normalize(project.path))",
            "run:\(run.id)",
        ] + checkpointIDs(for: run).map { "checkpoint:\($0)" })
            .joined(separator: "#")
    }

    private func markCaseFileSeen() {
        let run = appState.checkpointTimelineRun(for: project)
        appState.markProjectCaseFileSeen(
            projectPath: project.path,
            runID: run?.id,
            checkpointIDs: run.map(checkpointIDs(for:)) ?? [],
        )
    }

    private func checkpointIDs(for run: RuntimeRunState) -> [String] {
        run.pastCheckpoints.map(\.id) + [run.activeCheckpoint?.id].compactMap(\.self)
    }

    private var checkpointFocusTargetForProject: WorkBatchCheckpointFocusTarget? {
        guard let target = appState.uiState.workBatchCheckpointFocusTarget,
              target.projectPath == project.path
        else {
            return nil
        }

        return target
    }
}

struct DetailSectionLabel: View {
    let title: String
    var count: Int?
    var countAccessibilityLabel: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.sectionAccent.opacity(0.8))
                .frame(width: 4, height: 4)

            Text(title)
                .font(AppTypography.label.weight(.bold))
                .tracking(2)
                .foregroundColor(.white.opacity(0.4))

            if let count {
                Text("\(count)")
                    .font(AppTypography.badge)
                    .foregroundColor(.white.opacity(0.58))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .accessibilityLabel(countAccessibilityLabel ?? "\(count) queued tasks")
            }
        }
    }
}

struct DescriptionSection: View {
    let description: String?
    let isGenerating: Bool
    let onGenerate: () -> Void

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if let description {
                Text(description)
                    .font(AppTypography.body)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isGenerating {
                ShimmeringText(text: "Generating description...")
            }

            if description == nil, !isGenerating {
                Button(action: onGenerate) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(AppTypography.cardTitle)
                        Text("Generate Description")
                            .font(AppTypography.bodySecondary.weight(.medium))
                    }
                    .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(isHovered ? 0.1 : 0)),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.15 : 0), lineWidth: 0.5),
                    )
                }
                .buttonStyle(.plain)
                .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
                .onHover { hovering in
                    withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.2, dampingFraction: 0.7)) {
                        isHovered = hovering
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: description != nil)
        .animation(.easeInOut(duration: 0.3), value: isGenerating)
    }
}
