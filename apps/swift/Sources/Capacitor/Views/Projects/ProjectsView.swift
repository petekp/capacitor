import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @ObservedObject private var glassConfig = GlassConfig.shared
    @State private var pausedCollapsed = true
    @State private var draggedProject: Project?

    private var orderedProjects: [Project] {
        appState.orderedProjects(appState.projects)
    }

    private var activeProjects: [Project] {
        orderedProjects.filter { project in
            !appState.isManuallyDormant(project)
        }
    }

    private var pausedProjects: [Project] {
        orderedProjects.filter { project in
            appState.isManuallyDormant(project)
        }
    }

    private func isStale(_ project: Project) -> Bool {
        guard let state = appState.getSessionState(for: project),
              state.state == .ready,
              let stateChangedAt = state.stateChangedAt,
              let date = ISO8601DateFormatter().date(from: stateChangedAt) else {
            return false
        }
        return Date().timeIntervalSince(date) > 86400
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: glassConfig.cardListSpacingRounded) {
                // Setup status card - show regardless of project state
                if let diagnostic = appState.hookDiagnostic, !diagnostic.isHealthy {
                    SetupStatusCard(
                        diagnostic: diagnostic,
                        onFix: { appState.fixHooks() },
                        onRefresh: {
                            appState.checkHookDiagnostic()
                            appState.refreshSessionStates()
                        },
                        onTest: { appState.testHooks() }
                    )
                    .padding(.bottom, 4)
                }

                if appState.isLoading {
                    VStack(spacing: 8) {
                        SkeletonCard()
                        SkeletonCard()
                        SkeletonCard()
                    }
                    .padding(.top, 8)
                } else if appState.projects.isEmpty && appState.activeCreations.isEmpty {
                    EmptyProjectsView()
                } else {
                    ActivityPanel()

                    if !activeProjects.isEmpty {
                        SectionHeader(
                            title: "In Progress",
                            count: activeProjects.count
                        )
                            .padding(.top, 4)
                            .transition(.opacity)

                        ForEach(activeProjects, id: \.path) { project in
                            ProjectCardView(
                                project: project,
                                sessionState: appState.getSessionState(for: project),
                                projectStatus: appState.getProjectStatus(for: project),
                                flashState: appState.isFlashing(project),
                                isStale: isStale(project),
                                isActive: appState.activeProjectPath == project.path,
                                onTap: {
                                    appState.launchTerminal(for: project)
                                },
                                onInfoTap: {
                                    appState.showProjectDetail(project)
                                },
                                onMoveToDormant: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        appState.moveToDormant(project)
                                    }
                                },
                                onCaptureIdea: { frame in
                                    appState.showIdeaCaptureModal(for: project, from: frame)
                                },
                                onRemove: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        appState.removeProject(project.path)
                                    }
                                },
                                onDragStarted: {
                                    draggedProject = project
                                    return NSItemProvider(object: project.path as NSString)
                                },
                                isDragging: draggedProject?.path == project.path
                            )
                            .preventWindowDrag()
                            .zIndex(draggedProject?.path == project.path ? 999 : 0)
                            .id("active-\(project.path)")
                            .onDrop(
                                of: [.text],
                                delegate: ProjectDropDelegate(
                                    project: project,
                                    activeProjects: activeProjects,
                                    draggedProject: $draggedProject,
                                    appState: appState
                                )
                            )
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                        }
                    }

                    if !pausedProjects.isEmpty {
                        PausedSectionHeader(
                            count: pausedProjects.count,
                            isCollapsed: $pausedCollapsed
                        )
                        .padding(.top, activeProjects.isEmpty ? 4 : 12)
                        .transition(.opacity)

                        if !pausedCollapsed {
                            VStack(spacing: 0) {
                                ForEach(pausedProjects, id: \.path) { project in
                                    let index = pausedProjects.firstIndex(where: { $0.path == project.path }) ?? 0

                                    CompactProjectCardView(
                                        project: project,
                                        onTap: {
                                            appState.launchTerminal(for: project)
                                        },
                                        onInfoTap: {
                                            appState.showProjectDetail(project)
                                        },
                                        onMoveToRecent: {
                                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                                appState.moveToRecent(project)
                                            }
                                        },
                                        onRemove: {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                                appState.removeProject(project.path)
                                            }
                                        },
                                        showSeparator: index < pausedProjects.count - 1
                                    )
                                    .id("paused-\(project.path)")
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.95)),
                                        removal: .opacity.combined(with: .scale(scale: 0.9))
                                    ))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, glassConfig.listHorizontalPaddingRounded)
            .padding(.top, floatingMode ? 56 : 12)
            .padding(.bottom, floatingMode ? 64 : 8)
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .onChange(of: pausedProjects.count) { oldCount, newCount in
            if newCount > oldCount && pausedCollapsed {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    pausedCollapsed = false
                }
            }
        }
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
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) section, \(count) \(count == 1 ? "project" : "projects")")
    }
}

struct PausedSectionHeader: View {
    let count: Int
    @Binding var isCollapsed: Bool
    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: {
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.3, dampingFraction: 0.8)) {
                isCollapsed.toggle()
            }
        }) {
            HStack(spacing: 6) {
                Text("PAUSED")
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
        .accessibilityLabel("Paused projects section, \(count) \(count == 1 ? "project" : "projects")")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Double-tap to expand" : "Double-tap to collapse")
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct EmptyProjectsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion
    @State private var appeared = false
    @State private var isButtonHovered = false

    var body: some View {
        contentView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // Draggable area behind content - won't block button clicks
                if floatingMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .windowDraggable()
                }
            }
    }

    private var contentView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.hudAccent.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .blur(radius: 20)
                    .scaleEffect(appeared || reduceMotion ? 1.0 : 0.5)
                    .opacity(appeared || reduceMotion ? 1 : 0)

                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .scaleEffect(appeared || reduceMotion ? 1.0 : 0.8)
                    .opacity(appeared || reduceMotion ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Drag folders here")
                    .font(AppTypography.cardSubtitle.weight(.semibold))
                    .foregroundColor(.white.opacity(0.7))

                Text("or use the button below to get started")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)

            Button(action: { appState.showAddProject() }) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(AppTypography.labelMedium.weight(.semibold))
                    Text("Link Project")
                        .font(AppTypography.bodySecondary.weight(.semibold))
                }
                .foregroundColor(.white.opacity(isButtonHovered ? 1 : 0.9))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [
                            Color.hudAccent.opacity(isButtonHovered ? 0.9 : 0.7),
                            Color.hudAccentDark.opacity(isButtonHovered ? 0.8 : 0.6)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isButtonHovered ? 0.2 : 0.1), lineWidth: 0.5)
                )
                .shadow(color: Color.hudAccent.opacity(isButtonHovered ? 0.4 : 0.2), radius: isButtonHovered && !reduceMotion ? 10 : 4, y: 2)
                .scaleEffect(isButtonHovered && !reduceMotion ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Link project")
            .accessibilityHint("Opens a folder picker to link an existing project directory")
            .onHover { hovering in
                withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.25, dampingFraction: 0.7)) {
                    isButtonHovered = hovering
                }
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 15)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.hudAccent.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .foregroundColor(Color.hudAccent.opacity(0.25))
        )
        .padding(.horizontal, 24)
        .padding(.top, 50)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop zone for project folders")
        .onAppear {
            if !reduceMotion {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                    appeared = true
                }
            } else {
                appeared = true
            }
        }
    }
}

struct ProjectCardDragPreview: View {
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(AppTypography.labelMedium)
                .foregroundColor(.white.opacity(0.5))
            Text(project.name)
                .font(AppTypography.bodyMedium)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.hudCard)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.hudAccent.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}

struct ProjectDropDelegate: DropDelegate {
    let project: Project
    let activeProjects: [Project]
    @Binding var draggedProject: Project?
    let appState: AppState

    func dropEntered(info: DropInfo) {
        guard let draggedProject = draggedProject,
              draggedProject.path != project.path,
              let fromIndex = activeProjects.firstIndex(where: { $0.path == draggedProject.path }),
              let toIndex = activeProjects.firstIndex(where: { $0.path == project.path })
        else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            appState.moveProject(
                from: IndexSet(integer: fromIndex),
                to: toIndex > fromIndex ? toIndex + 1 : toIndex,
                in: activeProjects
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedProject = nil
        return true
    }
}
