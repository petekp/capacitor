import SwiftUI
import UniformTypeIdentifiers

struct DockLayoutView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.openWindow) private var openWindow
    private let glassConfig = GlassConfig.shared
    @State private var scrolledID: String?
    @State private var draggedProject: Project?
    @State private var showPageIndicator = false
    @State private var pageIndicatorHideTask: _Concurrency.Task<Void, Never>?

    private var cardWidth: CGFloat {
        glassConfig.dockCardWidthRounded
    }

    private var nonPausedProjects: [Project] {
        appState.projectState.projects.filter { !appState.isManuallyDormant($0) }
    }

    var body: some View {
        // Bridge nested session-state updates into this view's observation graph.
        let _ = appState.sessionStateRevision
        // Snapshot session state directly so this body observes per-project changes.
        let sessionStates = appState.sessionStateManager.sessionStates

        // Capture layout values once at body evaluation to avoid constraint loops
        let cardSpacing = glassConfig.dockCardSpacingRounded
        let horizontalPadding = glassConfig.dockHorizontalPaddingRounded
        let verticalPadding = glassConfig.dockVerticalPaddingRounded
        let pageIndicatorSpacing = glassConfig.dockPageIndicatorSpacingRounded
        let grouped = ProjectOrdering.orderedGroupedProjects(
            nonPausedProjects,
            order: appState.projectState.projectOrder,
            sessionStates: sessionStates,
        )
        let activePaths = Set(grouped.active.map(\.path))
        let allProjects = grouped.active + grouped.idle
        #if DEBUG
            let renderSummary = DockLayoutRenderTelemetry.summary(
                for: allProjects,
                sessionStates: sessionStates,
            )
            let _ = DockLayoutRenderTelemetry.logIfChanged(renderSummary)
        #endif

        GeometryReader { geometry in
            let cardsPerPage = calculateCardsPerPage(width: geometry.size.width, cardSpacing: cardSpacing, horizontalPadding: horizontalPadding)
            let totalPages = max(1, Int(ceil(Double(allProjects.count) / Double(cardsPerPage))))
            let currentPage = calculateCurrentPage(cardsPerPage: cardsPerPage, in: allProjects)

            ZStack(alignment: .bottom) {
                if allProjects.isEmpty {
                    emptyState
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: cardSpacing) {
                            ForEach(allProjects, id: \.path) { project in
                                let sessionState = ProjectOrdering.sessionState(for: project.path, sessionStates: sessionStates)
                                let projectStatus = appState.getProjectStatus(for: project)
                                let flashState = appState.isFlashing(project)
                                projectCard(
                                    for: project,
                                    sessionState: sessionState,
                                    projectStatus: projectStatus,
                                    flashState: flashState,
                                    activePaths: activePaths,
                                    grouped: grouped,
                                )
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .scrollTargetLayout()
                    }
                    .scrollClipDisabled()
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $scrolledID)
                    .onChange(of: scrolledID) {
                        // Cancel any pending hide — show instantly
                        pageIndicatorHideTask?.cancel()
                        showPageIndicator = true

                        // Schedule hide after 3 seconds of inactivity
                        pageIndicatorHideTask = _Concurrency.Task { @MainActor in
                            do {
                                try await _Concurrency.Task.sleep(for: .seconds(3))
                            } catch {
                                return
                            }
                            withAnimation(.easeOut(duration: 0.4)) {
                                showPageIndicator = false
                            }
                        }
                    }

                    if totalPages > 1 {
                        PageIndicator(currentPage: currentPage, totalPages: totalPages)
                            .opacity(showPageIndicator ? 1 : 0)
                            .padding(.bottom, pageIndicatorSpacing)
                    }
                }
            }
            .padding(.vertical, verticalPadding > 0 ? verticalPadding : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project dock")
        .onChange(of: appState.uiState.reviewWindowTarget?.workerID) { oldValue, newValue in
            if oldValue == nil, newValue != nil {
                openWindow(id: "delegation-review")
            }
        }
        .onChange(of: appState.uiState.runCheckpointWindowTarget?.checkpointID) { oldValue, newValue in
            if oldValue == nil, newValue != nil {
                openWindow(id: "run-checkpoint-review")
            }
        }
    }

    private var emptyState: some View {
        ZStack {
            if floatingMode {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .windowDraggable()
            }

            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.4))
                    Text("No active projects")
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func calculateCurrentPage(cardsPerPage: Int, in projects: [Project]) -> Int {
        guard let scrolledID,
              let index = projects.firstIndex(where: { $0.path == scrolledID })
        else {
            return 0
        }
        return index / cardsPerPage
    }

    @ViewBuilder
    private func projectCard(
        for project: Project,
        sessionState: ProjectSessionState?,
        projectStatus: ProjectStatus?,
        flashState: SessionState?,
        activePaths: Set<String>,
        grouped: (active: [Project], idle: [Project]),
    ) -> some View {
        let isActive = appState.activeProjectPath == project.path
        let canShowDetails = appState.featureState.isProjectDetailsEnabled
        let canCaptureIdeas = appState.featureState.isIdeaCaptureEnabled
        let group: ActivityGroup = activePaths.contains(project.path) ? .active : .idle
        let groupProjects = group == .active ? grouped.active : grouped.idle
        let activeRunState = appState.activeRun(for: project)

        DockProjectCard(
            project: project,
            sessionState: sessionState,
            delegationState: appState.delegationState(for: project),
            activeRunState: activeRunState,
            projectStatus: projectStatus,
            flashState: flashState,
            isActive: isActive,
            onTap: {
                appState.handlePrimaryProjectAction(for: project, source: .dockCard)
            },
            onInfoTap: canShowDetails ? { appState.showProjectDetail(project) } : nil,
            onMoveToDormant: { appState.moveToDormant(project) },
            onCaptureIdea: canCaptureIdeas ? { frame in appState.showIdeaCaptureModal(for: project, from: frame) } : nil,
            onRemove: { appState.removeProject(project.path) },
            onDragStarted: {
                draggedProject = project
                return NSItemProvider(object: project.path as NSString)
            },
            isDragging: draggedProject?.path == project.path,
        )
        .preventWindowDrag()
        .id(ProjectOrdering.cardIdentityKey(projectPath: project.path, sessionState: sessionState))
        .zIndex(draggedProject?.path == project.path ? 999 : 0)
        .onDrop(
            of: [.text, .fileURL],
            delegate: ProjectCardDropDelegate(
                project: project,
                groupProjects: groupProjects,
                group: group,
                draggedProject: $draggedProject,
                appState: appState,
            ),
        )
    }

    private func calculateCardsPerPage(width: CGFloat, cardSpacing: CGFloat, horizontalPadding: CGFloat) -> Int {
        let availableWidth = width - (horizontalPadding * 2)
        let cardWithSpacing = cardWidth + cardSpacing
        return max(1, Int(availableWidth / cardWithSpacing))
    }
}

#if DEBUG
    @MainActor
    private enum DockLayoutRenderTelemetry {
        private static var lastSummary: String?

        static func summary(
            for projects: [Project],
            sessionStates: [String: ProjectSessionState],
        ) -> String {
            if projects.isEmpty {
                return "<no-cards>"
            }

            return projects
                .map { project in
                    let sessionState = ProjectOrdering.sessionState(
                        for: project.path,
                        sessionStates: sessionStates,
                    )
                    return "\(project.name):\(stateLabel(sessionState?.state))"
                }
                .joined(separator: " | ")
        }

        static func logIfChanged(_ summary: String) {
            guard summary != lastSummary else { return }
            lastSummary = summary
            DebugLog.write("[DEBUG][DockLayoutView][ResolvedCardStates] \(summary)")
        }

        private static func stateLabel(_ state: SessionState?) -> String {
            guard let state else { return "nil" }

            switch state {
            case .working:
                return "Working"
            case .ready:
                return "Ready"
            case .idle:
                return "Idle"
            case .compacting:
                return "Compacting"
            case .waiting:
                return "Waiting"
            }
        }
    }
#endif

private struct PageIndicator: View {
    let currentPage: Int
    let totalPages: Int
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< totalPages, id: \.self) { page in
                Circle()
                    .fill(page == currentPage ? Color.white.opacity(0.8) : Color.white.opacity(0.3))
                    .frame(width: page == currentPage ? 8 : 6, height: page == currentPage ? 8 : 6)
                    .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: currentPage)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.black.opacity(0.35))
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial),
                )
                .clipShape(Capsule()),
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentPage + 1) of \(totalPages)")
    }
}

#Preview {
    DockLayoutView()
        .environment(AppState())
        .frame(width: 800, height: 150)
        .preferredColorScheme(.dark)
}
