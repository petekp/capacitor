import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    let project: Project

    @State private var isLaunchHovered = false
    @State private var isLaunchPressed = false
    @State private var appeared = false

    private var devServerPort: UInt16? {
        appState.getDevServerPort(for: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    BackButton(title: "Projects") {
                        appState.showProjectList()
                    }
                    .keyboardShortcut("[", modifiers: .command)

                    Spacer()
                }

                Text(project.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)

                if let sessionState = appState.getSessionState(for: project) {
                    DetailCard {
                        VStack(alignment: .leading, spacing: 10) {
                            DetailSectionLabel(title: "STATUS")

                            StatusIndicatorView(state: sessionState.state)

                            if let workingOn = sessionState.workingOn {
                                Text(workingOn)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.7))
                                    .lineLimit(3)
                            }
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                }

                DetailCard {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailSectionLabel(title: "QUICK ACTIONS")

                        HStack(spacing: 8) {
                            ActionButton(icon: "terminal", title: "Terminal") {
                                appState.launchTerminal(for: project)
                            }

                            if let port = devServerPort {
                                ActionButton(icon: "globe", title: ":\(port)") {
                                    appState.openInBrowser(project)
                                }
                            }
                        }

                        if devServerPort != nil {
                            ActionButton(
                                icon: "play.fill",
                                title: "Launch Full Environment",
                                isAccent: true,
                                fullWidth: true
                            ) {
                                appState.launchFullEnvironment(for: project)
                            }
                            .help("Opens terminal and browser together")
                        }
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)

                let todos = appState.todosManager.getTodos(for: project.path)
                let todoFileId = appState.todosManager.getFileId(for: project.path)

                if !todos.isEmpty || todoFileId != nil {
                    DetailCard {
                        TodosSection(
                            todos: todos,
                            fileId: todoFileId,
                            onStatusChange: { fileId, todoId, newStatus in
                                appState.todosManager.updateTodoStatus(fileId: fileId, todoId: todoId, newStatus: newStatus)
                            },
                            onAddTodo: { fileId, content in
                                appState.todosManager.addTodo(fileId: fileId, content: content)
                            }
                        )
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)
                }

                let plans = appState.plansManager.allPlans

                if !plans.isEmpty {
                    DetailCard {
                        PlansSection(plans: plans)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 24)
                }

                let healthResult = ClaudeMdHealthScorer.score(content: project.claudeMdPreview)

                if healthResult.grade != .none && !healthResult.details.filter({ !$0.passed }).isEmpty {
                    DetailCard {
                        HealthCoachingSection(healthResult: healthResult)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 28)
                }

                DetailCard {
                    HooksSetupSection()
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 32)

                DetailCard {
                    PluginRecommendationSection(projectPath: project.path)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 36)

                DetailCard {
                    UsageInsightsSection(projectPath: project.path)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 40)

                Spacer()
            }
            .padding(16)
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }
}

struct DetailCard<Content: View>: View {
    @Environment(\.floatingMode) private var floatingMode
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if floatingMode {
                    floatingBackground
                } else {
                    solidBackground
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var floatingBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.1), .white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.2), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
    }

    private var solidBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.hudCard)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(0.05), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
    }
}

struct DetailSectionLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.sectionAccent.opacity(0.8))
                .frame(width: 4, height: 4)

            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(2)
                .foregroundColor(.white.opacity(0.45))
        }
    }
}
