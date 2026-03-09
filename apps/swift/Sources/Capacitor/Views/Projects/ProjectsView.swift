import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Tracks previous row order without triggering view invalidation.
/// Reference-type mutation is invisible to SwiftUI's Observation, so z-indices
/// computed from previous state persist for the full duration of the spring animation.
private final class RowOrderTracker {
    private var indexByPath: [String: Int] = [:]

    /// Snapshot current paths and return a lookup of z-index directions.
    /// Moved up → +1 (on top), moved down → -1 (behind), unchanged/new → 0.
    /// Call once per body evaluation; O(n) total instead of O(n²) per-card lookups.
    func snapshotAndDirections(for currentPaths: [String]) -> [String: Double] {
        defer {
            indexByPath = Dictionary(uniqueKeysWithValues: currentPaths.enumerated().map { ($1, $0) })
        }

        guard !indexByPath.isEmpty else { return [:] }

        var directions: [String: Double] = [:]
        directions.reserveCapacity(currentPaths.count)
        for (currIdx, path) in currentPaths.enumerated() {
            guard let prevIdx = indexByPath[path] else { continue }
            if currIdx < prevIdx { directions[path] = 1 }
            else if currIdx > prevIdx { directions[path] = -1 }
        }
        return directions
    }
}

struct ProjectsView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    private let glassConfig = GlassConfig.shared
    @State private var pausedCollapsed = true
    @State private var draggedProject: ShellProjectCatalogEntry?
    @State private var rowOrderTracker = RowOrderTracker()

    private var projectListState: ProjectListState {
        appState.projectListState
    }

    private var nonPausedProjects: [ShellProjectCatalogEntry] {
        projectListState.visibleProjects(from: appState.projectWorkflowState.projectCatalog)
    }

    private var pausedProjects: [ShellProjectCatalogEntry] {
        projectListState.pausedProjects(from: appState.projectWorkflowState.projectCatalog)
    }

    var body: some View {
        // Bridge nested session-state updates into this view's observation graph.
        let _ = appState.sessionStateRevision
        // Snapshot session state directly so this body observes per-project changes.
        let sessionStates = appState.sessionStateManager.sessionStates
        #if DEBUG
            let renderedProjectsForDebug = debugRenderedProjects(sessionStates: sessionStates)
            let renderSummary = ProjectsViewRenderTelemetry.summary(
                for: renderedProjectsForDebug,
                sessionStates: sessionStates,
            )
            let _ = ProjectsViewRenderTelemetry.logIfChanged(renderSummary)
        #endif

        // Capture layout values once at body evaluation to avoid constraint loops
        // (same pattern as DockLayoutView crash fix)
        let cardListSpacing = glassConfig.cardListSpacingRounded
        let listHorizontalPadding = glassConfig.listHorizontalPaddingRounded
        let contentTopPadding: CGFloat = floatingMode ? 44 : 12
        let contentBottomPadding: CGFloat = floatingMode ? 64 : 8
        let edgeFadeHeight: CGFloat = floatingMode ? 24 : 0
        let topFade = contentTopPadding + edgeFadeHeight
        let bottomFade = contentBottomPadding + edgeFadeHeight

        let preferredScrollbarWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        let expandedScrollbarWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let maskScrollbarWidth = ScrollMaskLayout.scrollbarMaskWidth(
            preferredWidth: preferredScrollbarWidth,
            expandedWidth: expandedScrollbarWidth,
        )
        let contentTrailingPadding = ScrollMaskLayout.contentTrailingPadding(
            basePadding: listHorizontalPadding,
            scrollbarMaskWidth: maskScrollbarWidth,
        )
        let scrollbarInset = floatingMode ? WindowCornerRadius.value(floatingMode: floatingMode) : 0

        // Empty state: uses ScrollView with gradient mask for visual
        // consistency with the project list. Content flows naturally
        // (no .frame(maxHeight: .infinity) to avoid layout oscillation).
        if !appState.dashboardState.isLoading, appState.projectWorkflowState.projectCatalog.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    if let diagnostic = appState.setupActionState.hookDiagnostic, diagnostic.shouldShowSetupCard {
                        SetupStatusCard(
                            diagnostic: diagnostic,
                            onFix: { appState.setupActionState.fixHooks() },
                            onTest: { appState.setupActionState.testHooks() },
                        )
                        .padding(.horizontal, listHorizontalPadding)
                        .padding(.bottom, 4)
                    }
                    EmptyProjectsView()
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, contentTopPadding)
                .padding(.bottom, contentBottomPadding)
            }
            .projectListScrollChrome(
                maskScrollbarWidth: maskScrollbarWidth,
                topFade: topFade,
                bottomFade: bottomFade,
                scrollbarInset: scrollbarInset,
                floatingMode: floatingMode,
            )
        } else {
            ScrollView {
                ScrollViewReader { scrollProxy in
                    LazyVStack(spacing: cardListSpacing) {
                        // Setup status card - show regardless of project state
                        if let diagnostic = appState.setupActionState.hookDiagnostic, diagnostic.shouldShowSetupCard {
                            SetupStatusCard(
                                diagnostic: diagnostic,
                                onFix: { appState.setupActionState.fixHooks() },
                                onTest: { appState.setupActionState.testHooks() },
                            )
                            .padding(.bottom, 4)
                        }

                        if appState.dashboardState.isLoading {
                            VStack(spacing: 8) {
                                SkeletonCard()
                                SkeletonCard()
                                SkeletonCard()
                            }
                            .padding(.top, 8)
                        } else {
                            let grouped = projectListState.orderedGroupedProjects(
                                nonPausedProjects,
                                sessionStates: sessionStates,
                            )
                            let activePaths = Set(grouped.active.map(\.path))
                            let rows = grouped.active + grouped.idle
                            let reorderDirections = rowOrderTracker.snapshotAndDirections(for: rows.map(\.path))
                            let hasVisibleProjects = !grouped.active.isEmpty || !grouped.idle.isEmpty

                            if appState.isProjectCreationEnabled {
                                ActivityPanel()
                            }

                            if hasVisibleProjects {
                                if !grouped.active.isEmpty {
                                    SectionHeader(
                                        title: "In Progress",
                                        count: grouped.active.count,
                                    )
                                    .padding(.top, 4)
                                    .transition(.opacity)
                                }

                                ForEach(Array(rows.enumerated()), id: \.element.path) { index, project in
                                    if index == grouped.active.count, !grouped.idle.isEmpty {
                                        SectionHeader(
                                            title: "Idle",
                                            count: grouped.idle.count,
                                        )
                                        .padding(.top, grouped.active.isEmpty ? 4 : 10)
                                        .id("idle-section-header")
                                        .transition(.opacity)
                                    }

                                    let sessionState = ProjectOrdering.sessionState(for: project.path, sessionStates: sessionStates)
                                    let projectStatus = appState.projectStatusCacheState.statuses[project.path]
                                    let flashState = appState.sessionStateManager.isFlashing(project)
                                    let isStale = SessionStaleness.isReadyStale(
                                        state: sessionState?.state,
                                        stateChangedAt: sessionState?.stateChangedAt,
                                    )
                                    let group: ActivityGroup = activePaths.contains(project.path) ? .active : .idle
                                    let groupProjects = group == .active ? grouped.active : grouped.idle
                                    activeProjectCard(
                                        project: project,
                                        sessionState: sessionState,
                                        projectStatus: projectStatus,
                                        flashState: flashState,
                                        isStale: isStale,
                                        index: index,
                                        group: group,
                                        groupProjects: groupProjects,
                                        reorderZIndex: reorderDirections[project.path] ?? 0,
                                    )
                                }
                            }

                            if !pausedProjects.isEmpty {
                                PausedSectionHeader(
                                    count: pausedProjects.count,
                                    isCollapsed: pausedCollapsed,
                                    onToggle: {
                                        let expanding = pausedCollapsed
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            pausedCollapsed.toggle()
                                        }
                                        if expanding {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                                    scrollProxy.scrollTo("scroll-end", anchor: .bottom)
                                                }
                                            }
                                        }
                                    },
                                )
                                .padding(.top, hasVisibleProjects ? 12 : 4)
                                .transition(.opacity)

                                if !pausedCollapsed {
                                    VStack(spacing: 0) {
                                        ForEach(Array(pausedProjects.enumerated()), id: \.element.path) { index, project in
                                            pausedProjectCard(project: project, index: index)
                                        }
                                        // Anchor inside the eager VStack so it's always materialized
                                        // when the section is expanded (LazyVStack won't defer it)
                                        Color.clear.frame(height: 1).id("scroll-end")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.leading, listHorizontalPadding)
                    .padding(.trailing, contentTrailingPadding)
                    .padding(.top, contentTopPadding)
                    .padding(.bottom, contentBottomPadding)
                    .onChange(of: pausedProjects.count) { oldCount, newCount in
                        if newCount > oldCount, pausedCollapsed {
                            withAnimation(.spring(response: glassConfig.sectionToggleSpringResponse, dampingFraction: 0.85)) {
                                pausedCollapsed = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                withAnimation(.spring(response: glassConfig.sectionToggleSpringResponse, dampingFraction: 0.85)) {
                                    scrollProxy.scrollTo("scroll-end", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .projectListScrollChrome(
                maskScrollbarWidth: maskScrollbarWidth,
                topFade: topFade,
                bottomFade: bottomFade,
                scrollbarInset: scrollbarInset,
                floatingMode: floatingMode,
            )
        }
    }

    @ViewBuilder
    private func activeProjectCard(
        project: ShellProjectCatalogEntry,
        sessionState: ProjectSessionState?,
        projectStatus: ProjectStatus?,
        flashState: SessionState?,
        isStale: Bool,
        index: Int,
        group: ActivityGroup,
        groupProjects: [ShellProjectCatalogEntry],
        reorderZIndex: Double,
    ) -> some View {
        let canShowDetails = appState.isProjectDetailsEnabled
        let canCaptureIdeas = appState.isIdeaCaptureEnabled

        ProjectCardView(
            project: project,
            sessionState: sessionState,
            projectStatus: projectStatus,
            flashState: flashState,
            isStale: isStale,
            isActive: appState.activeProjectTrackingState.activeProjectPath == project.path,
            onTap: {
                appState.projectActivationCoordinator.activate(project)
            },
            onInfoTap: canShowDetails ? { appState.navigationState.showProjectDetail(project.shellProjectReference) } : nil,
            onMoveToDormant: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    projectListState.moveToDormant(project)
                }
            },
            onCaptureIdea: canCaptureIdeas ? { frame in appState.projectPresentationState.showIdeaCaptureModal(for: project, from: frame) } : nil,
            onRemove: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    appState.projectActionState.removeProject(path: project.path)
                }
            },
            onDragStarted: {
                draggedProject = project
                return NSItemProvider(object: project.path as NSString)
            },
            isDragging: draggedProject?.path == project.path,
        )
        .activeProjectCardModifiers(
            project: project,
            sessionState: sessionState,
            index: index,
            groupProjects: groupProjects,
            group: group,
            draggedProject: $draggedProject,
            appState: appState,
            glassConfig: glassConfig,
            reorderZIndex: reorderZIndex,
        )
    }

    private func pausedProjectCard(project: ShellProjectCatalogEntry, index: Int) -> some View {
        CompactProjectCardView(
            project: project,
            onTap: {
                appState.projectActivationCoordinator.activate(project)
            },
            onInfoTap: appState.isProjectDetailsEnabled ? { appState.navigationState.showProjectDetail(project.shellProjectReference) } : nil,
            onMoveToRecent: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    projectListState.moveToRecent(project)
                }
            },
            onRemove: {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    appState.projectActionState.removeProject(path: project.path)
                }
            },
            showSeparator: index < pausedProjects.count - 1,
        )
        .pausedProjectCardModifiers(
            project: project,
            index: index,
            glassConfig: glassConfig,
        )
    }

    #if DEBUG
        private func debugRenderedProjects(sessionStates: [String: ProjectSessionState]) -> [ShellProjectCatalogEntry] {
            guard !appState.dashboardState.isLoading, !appState.projectWorkflowState.projectCatalog.isEmpty else {
                return []
            }

            let grouped = projectListState.orderedGroupedProjects(
                nonPausedProjects,
                sessionStates: sessionStates,
            )
            return grouped.active + grouped.idle
        }
    #endif
}

#if DEBUG
    @MainActor
    private enum ProjectsViewRenderTelemetry {
        private static var lastSummary: String?

        static func summary(
            for projects: [ShellProjectCatalogEntry],
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
                    return "\(project.displayName):\(stateLabel(sessionState?.state))"
                }
                .joined(separator: " | ")
        }

        static func logIfChanged(_ summary: String) {
            guard summary != lastSummary else { return }
            lastSummary = summary
            DebugLog.write("[DEBUG][ProjectsView][ResolvedCardStates] \(summary)")
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

// MARK: - Card Modifier Extensions (extracted for type-checker)

private extension View {
    func activeProjectCardModifiers(
        project: ShellProjectCatalogEntry,
        sessionState: ProjectSessionState?,
        index: Int,
        groupProjects: [ShellProjectCatalogEntry],
        group: ActivityGroup,
        draggedProject: Binding<ShellProjectCatalogEntry?>,
        appState: AppState,
        glassConfig: GlassConfig,
        reorderZIndex: Double,
    ) -> some View {
        preventWindowDrag()
            .zIndex(draggedProject.wrappedValue?.path == project.path ? 999 : reorderZIndex)
            .id(ProjectOrdering.cardIdentityKey(projectPath: project.path, sessionState: sessionState))
            .onDrop(
                of: [.text, .fileURL],
                delegate: ProjectCardDropDelegate(
                    project: project,
                    groupProjects: groupProjects,
                    group: group,
                    draggedProject: draggedProject,
                    appState: appState,
                ),
            )
            .transition(.asymmetric(
                insertion: .opacity
                    .combined(with: .scale(scale: 0.96))
                    .combined(with: .offset(y: -8))
                    .animation(.spring(response: glassConfig.cardInsertSpringResponse, dampingFraction: glassConfig.cardInsertSpringDamping).delay(Double(index) * glassConfig.cardInsertStagger)),
                removal: .opacity
                    .combined(with: .scale(scale: 0.94))
                    .animation(.easeOut(duration: glassConfig.cardRemovalDuration)),
            ))
    }

    func pausedProjectCardModifiers(
        project: ShellProjectCatalogEntry,
        index: Int,
        glassConfig: GlassConfig,
    ) -> some View {
        id("paused-\(project.path)")
            .transition(.asymmetric(
                insertion: .opacity
                    .combined(with: .scale(scale: 0.97))
                    .animation(.spring(response: glassConfig.cardInsertSpringResponse * 0.8, dampingFraction: glassConfig.cardInsertSpringDamping).delay(Double(index) * glassConfig.pausedCardStagger)),
                removal: .opacity
                    .combined(with: .scale(scale: 0.95))
                    .animation(.easeOut(duration: glassConfig.cardRemovalDuration * 0.8)),
            ))
    }

    func projectListScrollChrome(
        maskScrollbarWidth: CGFloat,
        topFade: CGFloat,
        bottomFade: CGFloat,
        scrollbarInset: CGFloat,
        floatingMode: Bool,
    ) -> some View {
        mask {
            GeometryReader { proxy in
                let sizes = ScrollMaskLayout.sizes(
                    totalWidth: proxy.size.width,
                    scrollbarWidth: maskScrollbarWidth,
                )

                HStack(spacing: 0) {
                    ScrollEdgeFadeMask(
                        topInset: 0,
                        bottomInset: 0,
                        topFade: topFade,
                        bottomFade: bottomFade,
                    )
                    .frame(width: sizes.content, height: proxy.size.height)

                    Color.white
                        .frame(width: sizes.scrollbar, height: proxy.size.height)
                }
            }
        }
        .background(
            ScrollViewScrollerInsetsConfigurator(
                topInset: scrollbarInset,
                bottomInset: scrollbarInset,
                hideTrack: true,
            ),
        )
        .background(floatingMode ? Color.clear : Color.hudBackground)
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(AppTypography.label.weight(.medium))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.45))

            if count > 1 {
                Text("(\(count))")
                    .font(AppTypography.badge)
                    .foregroundColor(.white.opacity(0.25))
            }

            Spacer()
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) section, \(count) \(count == 1 ? "project" : "projects")")
    }
}

struct PausedSectionHeader: View {
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void
    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text("HIDDEN")
                    .font(AppTypography.label.weight(.medium))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.45))

                if count > 1 {
                    Text("(\(count))")
                        .font(AppTypography.badge)
                        .foregroundColor(.white.opacity(0.25))
                }

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(AppTypography.captionSmall.weight(.semibold))
                    .foregroundColor(.white.opacity(isHovered ? 0.45 : 0.25))

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hidden projects section, \(count) \(count == 1 ? "project" : "projects")")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Double-tap to expand" : "Double-tap to collapse")
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Empty State Border Glow

struct EmptyStateBorderGlow: View {
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion

    #if DEBUG
        private let config = GlassConfig.shared
    #endif

    private var cornerRadius: CGFloat {
        WindowCornerRadius.value(floatingMode: floatingMode)
    }

    /// Tunable parameters — reads GlassConfig in DEBUG, constants in RELEASE
    private var speed: Double {
        #if DEBUG
            config.emptyGlowSpeed
        #else
            3.21
        #endif
    }

    private var pulseCount: Int {
        #if DEBUG
            config.emptyGlowPulseCount
        #else
            4
        #endif
    }

    private var glowBaseOpacity: Double {
        #if DEBUG
            config.emptyGlowBaseOpacity
        #else
            0.11
        #endif
    }

    private var glowPulseRange: Double {
        #if DEBUG
            config.emptyGlowPulseRange
        #else
            0.59
        #endif
    }

    private var innerWidth: Double {
        #if DEBUG
            config.emptyGlowInnerWidth
        #else
            0.91
        #endif
    }

    private var outerWidth: Double {
        #if DEBUG
            config.emptyGlowOuterWidth
        #else
            1.21
        #endif
    }

    private var innerBlur: Double {
        #if DEBUG
            config.emptyGlowInnerBlur
        #else
            0.27
        #endif
    }

    private var outerBlur: Double {
        #if DEBUG
            config.emptyGlowOuterBlur
        #else
            4.19
        #endif
    }

    private var fadeInZone: Double {
        #if DEBUG
            config.emptyGlowFadeInZone
        #else
            0.15
        #endif
    }

    private var fadeOutPower: Double {
        #if DEBUG
            config.emptyGlowFadeOutPower
        #else
            1.0
        #endif
    }

    var body: some View {
        if reduceMotion {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.brand.opacity(0.2), lineWidth: 1)
                .allowsHitTesting(false)
        } else {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let phase = time.truncatingRemainder(dividingBy: speed) / speed
                let rotationAngle = Angle(degrees: time.truncatingRemainder(dividingBy: speed * 2) / (speed * 2) * 360)
                let intensity = peakIntensity(phase: phase, count: pulseCount)
                let opacity = glowBaseOpacity + intensity * glowPulseRange

                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.brand.opacity(opacity * 0.3), location: 0.0),
                                    .init(color: Color.brand.opacity(opacity), location: 0.15),
                                    .init(color: Color.brand.opacity(opacity * 0.5), location: 0.25),
                                    .init(color: Color.brand.opacity(opacity * 0.2), location: 0.4),
                                    .init(color: Color.brand.opacity(opacity * 0.1), location: 0.5),
                                    .init(color: Color.brand.opacity(opacity * 0.2), location: 0.6),
                                    .init(color: Color.brand.opacity(opacity * 0.5), location: 0.75),
                                    .init(color: Color.brand.opacity(opacity), location: 0.85),
                                    .init(color: Color.brand.opacity(opacity * 0.3), location: 1.0),
                                ]),
                                center: .center,
                                angle: rotationAngle,
                            ),
                            lineWidth: innerWidth,
                        )
                        .blur(radius: innerBlur)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.brand.opacity(opacity * 0.2), location: 0.0),
                                    .init(color: Color.brand.opacity(opacity * 0.8), location: 0.15),
                                    .init(color: Color.brand.opacity(opacity * 0.3), location: 0.25),
                                    .init(color: Color.brand.opacity(opacity * 0.1), location: 0.5),
                                    .init(color: Color.brand.opacity(opacity * 0.3), location: 0.75),
                                    .init(color: Color.brand.opacity(opacity * 0.8), location: 0.85),
                                    .init(color: Color.brand.opacity(opacity * 0.2), location: 1.0),
                                ]),
                                center: .center,
                                angle: rotationAngle + Angle(degrees: 180),
                            ),
                            lineWidth: outerWidth,
                        )
                        .blur(radius: outerBlur)
                }
                .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
        }
    }

    private func peakIntensity(phase: Double, count: Int) -> Double {
        var peak: Double = 0
        for i in 0 ..< count {
            let stagger = Double(i) / Double(count)
            let ringPhase = (phase + stagger).truncatingRemainder(dividingBy: 1.0)
            let fadeIn = min(ringPhase / fadeInZone, 1.0)
            let fadeOut = pow(1.0 - ringPhase, fadeOutPower)
            peak = max(peak, fadeIn * fadeOut)
        }
        return peak
    }
}

// MARK: - Empty Projects View

struct EmptyProjectsView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion
    @State private var appeared = false
    @State private var hoveredPath: String?

    @State private var browseHovered = false

    var body: some View {
        VStack(spacing: OnboardingStyle.headerToContentSpacing) {
            VStack(spacing: OnboardingStyle.logoToHeadingSpacing) {
                BrandLogomark(size: OnboardingStyle.logomarkSize)

                Text("Connect your projects")
                    .font(AppTypography.onboardingHeading)
                    .foregroundColor(OnboardingStyle.headingColor)

                instructionText
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 8)

            if !appState.projectWorkflowState.suggestedProjectCatalog.isEmpty {
                suggestedProjectsList
                    .opacity(appeared || reduceMotion ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 10)
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
        .background {
            if floatingMode {
                Color.clear
                    .contentShape(Rectangle())
                    .windowDraggable()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop zone for project folders")
        .onAppear {
            if appState.projectWorkflowState.suggestedProjectCatalog.isEmpty {
                appState.projectWorkflowState.refreshSuggestedProjects()
            }
            if !reduceMotion {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    appeared = true
                }
            } else {
                appeared = true
            }
        }
    }

    private var instructionText: some View {
        HStack(spacing: 0) {
            Text("Drop a project folder here, or ")
                .foregroundColor(OnboardingStyle.subtitleColor)

            Text("browse")
                .foregroundColor(browseHovered ? OnboardingStyle.headingColor : OnboardingStyle.subtitleEmphasisColor)
                .underline(browseHovered, color: OnboardingStyle.subtitleColor)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.1)) {
                        browseHovered = hovering
                    }
                }
                .onTapGesture {
                    appState.projectImportCoordinator.connectViaFileBrowser()
                }
        }
        .font(AppTypography.onboardingSubtitle)
    }

    private var suggestedProjectsList: some View {
        VStack(spacing: 2) {
            ForEach(appState.projectWorkflowState.suggestedProjectCatalog, id: \.path) { suggestion in
                suggestionRow(suggestion)
            }
        }
        .frame(maxWidth: 320)
    }

    private func suggestionRow(_ suggestion: ShellSuggestedProjectCandidate) -> some View {
        let workflowState = appState.projectWorkflowState
        let isSelected = workflowState.isSuggestedProjectSelected(path: suggestion.path)
        let isHovered = hoveredPath == suggestion.path
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                workflowState.toggleSuggestedProjectSelection(path: suggestion.path)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(
                        isSelected
                            ? Color.hudAccent.opacity(0.8)
                            : .white.opacity(isHovered ? 0.3 : 0.15),
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(isSelected ? 0.9 : isHovered ? 0.7 : 0.55))

                    Text(suggestion.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(isSelected ? 0.4 : isHovered ? 0.3 : 0.25))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? Color.hudAccent.opacity(0.08)
                            : isHovered ? Color.white.opacity(0.03) : Color.clear,
                    ),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredPath = hovering ? suggestion.path : nil
            }
        }
    }
}
