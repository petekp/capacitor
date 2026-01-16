import SwiftUI

struct DockLayoutView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @State private var scrolledID: String?

    private let cardWidth: CGFloat = 262
    private let cardSpacing: CGFloat = 14
    private let horizontalPadding: CGFloat = 16

    private var activeProjects: [Project] {
        let ordered = appState.orderedProjects(appState.projects)
        return ordered.filter { project in
            !appState.isManuallyDormant(project)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let cardsPerPage = calculateCardsPerPage(width: geometry.size.width)
            let totalPages = max(1, Int(ceil(Double(activeProjects.count) / Double(cardsPerPage))))
            let currentPage = calculateCurrentPage(cardsPerPage: cardsPerPage)

            VStack(spacing: 8) {
                if activeProjects.isEmpty {
                    emptyState
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: cardSpacing) {
                            ForEach(activeProjects, id: \.path) { project in
                                projectCard(for: project)
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $scrolledID)

                    if totalPages > 1 {
                        PageIndicator(currentPage: currentPage, totalPages: totalPages)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project dock")
    }

    private var emptyState: some View {
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
        .frame(maxHeight: .infinity)
    }

    private func calculateCurrentPage(cardsPerPage: Int) -> Int {
        guard let scrolledID = scrolledID,
              let index = activeProjects.firstIndex(where: { $0.path == scrolledID }) else {
            return 0
        }
        return index / cardsPerPage
    }

    @ViewBuilder
    private func projectCard(for project: Project) -> some View {
        let sessionState = appState.getSessionState(for: project)
        let projectStatus = appState.getProjectStatus(for: project)
        let flashState = appState.isFlashing(project)
        let devServerPort = appState.getDevServerPort(for: project)
        let isStale = isProjectStale(project)
        let isActive = appState.activeProjectPath == project.path

        DockProjectCard(
            project: project,
            sessionState: sessionState,
            projectStatus: projectStatus,
            flashState: flashState,
            devServerPort: devServerPort,
            isStale: isStale,
            isActive: isActive,
            onTap: { appState.launchTerminal(for: project) },
            onInfoTap: { appState.showProjectDetail(project) },
            onMoveToDormant: { appState.moveToDormant(project) },
            onOpenBrowser: { appState.openInBrowser(project) },
            onCaptureIdea: { appState.showIdeaCaptureModal(for: project) },
            onRemove: project.isMissing ? { appState.removeProject(project.path) } : nil
        )
        .scrollTransition { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.8)
                .scaleEffect(phase.isIdentity ? 1 : 0.95)
        }
    }

    private func calculateCardsPerPage(width: CGFloat) -> Int {
        let availableWidth = width - (horizontalPadding * 2)
        let cardWithSpacing = cardWidth + cardSpacing
        return max(1, Int(availableWidth / cardWithSpacing))
    }

    private func isProjectStale(_ project: Project) -> Bool {
        guard let sessionState = appState.getSessionState(for: project),
              sessionState.state == .ready,
              let stateChangedAtStr = sessionState.stateChangedAt,
              let stateChangedAt = Double(stateChangedAtStr) else {
            return false
        }

        let staleThreshold: TimeInterval = 24 * 60 * 60
        return Date().timeIntervalSince1970 - stateChangedAt > staleThreshold
    }
}

private struct PageIndicator: View {
    let currentPage: Int
    let totalPages: Int
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalPages, id: \.self) { page in
                Circle()
                    .fill(page == currentPage ? Color.white.opacity(0.8) : Color.white.opacity(0.3))
                    .frame(width: page == currentPage ? 8 : 6, height: page == currentPage ? 8 : 6)
                    .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: currentPage)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentPage + 1) of \(totalPages)")
    }
}

#Preview {
    DockLayoutView()
        .environmentObject(AppState())
        .frame(width: 800, height: 150)
        .preferredColorScheme(.dark)
}
