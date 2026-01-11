import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @State private var draggingProject: Project?
    @State private var pausedCollapsed = true

    private var orderedProjects: [Project] {
        appState.orderedProjects(appState.projects)
    }

    private var needsInputProjects: [Project] {
        orderedProjects.filter { project in
            guard !appState.isManuallyDormant(project) else { return false }
            let state = appState.getSessionState(for: project)
            return state?.state == .ready
        }
    }

    private var inProgressProjects: [Project] {
        orderedProjects.filter { project in
            guard !appState.isManuallyDormant(project) else { return false }
            let state = appState.getSessionState(for: project)
            guard let s = state?.state else { return false }
            return s == .working || s == .compacting || s == .waiting
        }
    }

    private var pausedProjects: [Project] {
        orderedProjects.filter { project in
            let isNeedsInput = needsInputProjects.contains { $0.path == project.path }
            let isInProgress = inProgressProjects.contains { $0.path == project.path }
            return !isNeedsInput && !isInProgress
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
                } else if appState.projects.isEmpty {
                    EmptyProjectsView()
                } else {
                    SummaryBar(
                        needsInput: needsInputProjects.count,
                        inProgress: inProgressProjects.count,
                        paused: pausedProjects.count
                    )
                    .padding(.top, 4)

                    if !needsInputProjects.isEmpty {
                        SectionHeader(title: "NEEDS INPUT")
                            .padding(.top, 8)
                            .transition(.opacity)

                        ForEach(Array(needsInputProjects.enumerated()), id: \.element.path) { index, project in
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
                                }
                            )
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                        }
                    }

                    if !inProgressProjects.isEmpty {
                        SectionHeader(title: "IN PROGRESS")
                            .padding(.top, needsInputProjects.isEmpty ? 8 : 12)
                            .transition(.opacity)

                        ForEach(Array(inProgressProjects.enumerated()), id: \.element.path) { index, project in
                            ProjectCardView(
                                project: project,
                                sessionState: appState.getSessionState(for: project),
                                projectStatus: appState.getProjectStatus(for: project),
                                flashState: appState.isFlashing(project),
                                devServerPort: appState.getDevServerPort(for: project),
                                isStale: false,
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
                                }
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
                        .padding(.top, (needsInputProjects.isEmpty && inProgressProjects.isEmpty) ? 8 : 12)
                        .transition(.opacity)

                        if !pausedCollapsed {
                            ForEach(Array(pausedProjects.enumerated()), id: \.element.path) { index, project in
                                CompactProjectCardView(
                                    project: project,
                                    sessionState: appState.getSessionState(for: project),
                                    projectStatus: appState.getProjectStatus(for: project),
                                    isManuallyDormant: appState.isManuallyDormant(project),
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
                                    }
                                )
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
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .tracking(0.5)
            .foregroundColor(.white.opacity(0.4))
    }
}

struct SummaryBar: View {
    let needsInput: Int
    let inProgress: Int
    let paused: Int

    var body: some View {
        HStack(spacing: 12) {
            if needsInput > 0 {
                SummaryItem(count: needsInput, label: "need input", color: .statusReady)
            }
            if inProgress > 0 {
                SummaryItem(count: inProgress, label: "working", color: .statusWorking)
            }
            if paused > 0 {
                SummaryItem(count: paused, label: "paused", color: .white.opacity(0.4))
            }
        }
        .font(.system(size: 11))
    }
}

struct SummaryItem: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .fontWeight(.semibold)
                .foregroundColor(color)
            Text(label)
                .foregroundColor(.white.opacity(0.5))
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
                Text("PAUSED")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.5)
                    .foregroundColor(.white.opacity(0.4))

                Text("(\(count))")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white.opacity(0.3))

                Spacer()

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 0.5 : 0.3))
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
