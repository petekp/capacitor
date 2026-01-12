import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @State private var pausedCollapsed = true

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
            LazyVStack(spacing: 8) {
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
                            count: activeProjects.count,
                            showNewIdea: true,
                            onNewIdea: { appState.showNewIdea() }
                        )
                            .padding(.top, 4)
                            .transition(.opacity)

                        ForEach(activeProjects, id: \.path) { project in
                            let index = activeProjects.firstIndex(where: { $0.path == project.path }) ?? 0

                            ProjectCardView(
                                project: project,
                                sessionState: appState.getSessionState(for: project),
                                projectStatus: appState.getProjectStatus(for: project),
                                flashState: appState.isFlashing(project),
                                devServerPort: appState.getDevServerPort(for: project),
                                isStale: isStale(project),
                                todoStatus: appState.todosManager.getCompletionStatus(for: project.path),
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
                                onOpenBrowser: {
                                    appState.openInBrowser(project)
                                },
                                onRemove: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        appState.removeProject(project.path)
                                    }
                                }
                            )
                            .id("active-\(project.path)")
                            .draggable(project.path) {
                                ProjectCardDragPreview(project: project)
                            }
                            .dropDestination(for: String.self) { items, location in
                                guard let droppedPath = items.first,
                                      let fromIndex = activeProjects.firstIndex(where: { $0.path == droppedPath }),
                                      fromIndex != index else { return false }

                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    appState.moveProject(
                                        from: IndexSet(integer: fromIndex),
                                        to: fromIndex < index ? index + 1 : index,
                                        in: activeProjects
                                    )
                                }
                                return true
                            }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
    var showNewIdea: Bool = false
    var onNewIdea: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            if count > 1 {
                Text("(\(count))")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white.opacity(0.3))
            }

            Spacer()

            if showNewIdea {
                Button(action: { onNewIdea?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 10))
                        Text("New Idea")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(isHovered ? .hudAccent : .white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(isHovered ? 0.1 : 0.05))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }
            }
        }
    }
}

struct PausedSectionHeader: View {
    let count: Int
    @Binding var isCollapsed: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isCollapsed.toggle()
            }
        }) {
            HStack(spacing: 6) {
                Text("Paused")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                if count > 1 {
                    Text("(\(count))")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.white.opacity(0.3))
                }

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 0.5 : 0.3))

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct EmptyProjectsView: View {
    @EnvironmentObject var appState: AppState
    @State private var appeared = false
    @State private var isButtonHovered = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.hudAccent.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .blur(radius: 20)
                    .scaleEffect(appeared ? 1.0 : 0.5)
                    .opacity(appeared ? 1 : 0)

                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .scaleEffect(appeared ? 1.0 : 0.8)
                    .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: 6) {
                Text("No projects yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Text("Pin your first project to start tracking")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)

            Button(action: { appState.showAddProject() }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add Project")
                        .font(.system(size: 12, weight: .semibold))
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
                .shadow(color: Color.hudAccent.opacity(isButtonHovered ? 0.4 : 0.2), radius: isButtonHovered ? 10 : 4, y: 2)
                .scaleEffect(isButtonHovered ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    isButtonHovered = hovering
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 15)
        }
        .padding(.top, 50)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
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
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
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
