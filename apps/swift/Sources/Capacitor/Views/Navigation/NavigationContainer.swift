import SwiftUI

struct NavigationContainer: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.prefersReducedMotion) private var reduceMotion
    @Environment(\.floatingMode) private var floatingMode

    @State private var listOffset: CGFloat = 0
    @State private var detailOffset: CGFloat = 1000
    @State private var addLinkOffset: CGFloat = 1000
    @State private var newIdeaOffset: CGFloat = 1000
    @State private var currentDetail: Project?
    @State private var showDetail = false
    @State private var showAddLink = false
    @State private var showNewIdea = false

    @State private var listOpacity: Double = 1
    @State private var detailOpacity: Double = 0
    @State private var addLinkOpacity: Double = 0
    @State private var newIdeaOpacity: Double = 0

    private let animationDuration: Double = 0.35
    private let springResponse: Double = 0.35
    private let springDamping: Double = 0.86

    private var navigationAnimation: Animation {
        reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: springResponse, dampingFraction: springDamping)
    }

    private var isListActive: Bool {
        if case .list = appState.projectView { return true }
        return false
    }

    private var isDetailActive: Bool {
        if case .detail = appState.projectView { return true }
        return false
    }

    private var isAddLinkActive: Bool {
        if case .addLink = appState.projectView { return true }
        return false
    }

    private var isNewIdeaActive: Bool {
        if case .newIdea = appState.projectView { return true }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack {
                ProjectsView()
                    .frame(width: width)
                    .offset(x: reduceMotion ? 0 : listOffset)
                    .opacity(reduceMotion ? listOpacity : 1)
                    .zIndex(isListActive ? 1 : 0)
                    .allowsHitTesting(isListActive)

                if showDetail, let project = currentDetail {
                    ProjectDetailView(project: project)
                        .frame(width: width)
                        .offset(x: reduceMotion ? 0 : detailOffset)
                        .opacity(reduceMotion ? detailOpacity : 1)
                        .zIndex(isDetailActive ? 1 : 0)
                        .allowsHitTesting(isDetailActive)
                }

                if showAddLink {
                    AddProjectView()
                        .frame(width: width)
                        .offset(x: reduceMotion ? 0 : addLinkOffset)
                        .opacity(reduceMotion ? addLinkOpacity : 1)
                        .zIndex(isAddLinkActive ? 1 : 0)
                        .allowsHitTesting(isAddLinkActive)
                }

                if showNewIdea {
                    NewIdeaView()
                        .frame(width: width)
                        .offset(x: reduceMotion ? 0 : newIdeaOffset)
                        .opacity(reduceMotion ? newIdeaOpacity : 1)
                        .zIndex(isNewIdeaActive ? 1 : 0)
                        .allowsHitTesting(isNewIdeaActive)
                }
            }
            .clipped()
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.escape) {
                if !isListActive {
                    appState.showProjectList()
                    return .handled
                }
                return .ignored
            }
            .onChange(of: appState.projectView) { oldValue, newValue in
                handleNavigation(from: oldValue, to: newValue, width: width)
            }
        }
    }

    private func handleNavigation(from oldValue: ProjectView, to newValue: ProjectView, width: CGFloat) {
        switch newValue {
        case .list:
            withAnimation(navigationAnimation) {
                if reduceMotion {
                    listOpacity = 1
                    detailOpacity = 0
                    addLinkOpacity = 0
                    newIdeaOpacity = 0
                } else {
                    listOffset = 0
                    detailOffset = width
                    addLinkOffset = width
                    newIdeaOffset = width
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .list = appState.projectView {
                    showDetail = false
                    showAddLink = false
                    showNewIdea = false
                    currentDetail = nil
                }
            }

        case .detail(let project):
            currentDetail = project
            showDetail = true
            if reduceMotion {
                detailOpacity = 0
            } else {
                detailOffset = width
            }

            DispatchQueue.main.async {
                withAnimation(self.navigationAnimation) {
                    if self.reduceMotion {
                        self.listOpacity = 0
                        self.detailOpacity = 1
                        self.addLinkOpacity = 0
                        self.newIdeaOpacity = 0
                    } else {
                        self.listOffset = -width
                        self.detailOffset = 0
                        self.addLinkOffset = width
                        self.newIdeaOffset = width
                    }
                }
            }

            // Clean up other views after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .detail = self.appState.projectView {
                    self.showAddLink = false
                    self.showNewIdea = false
                }
            }

        case .addLink:
            showAddLink = true
            if reduceMotion {
                addLinkOpacity = 0
            } else {
                addLinkOffset = width
            }

            DispatchQueue.main.async {
                withAnimation(self.navigationAnimation) {
                    if self.reduceMotion {
                        self.listOpacity = 0
                        self.detailOpacity = 0
                        self.addLinkOpacity = 1
                        self.newIdeaOpacity = 0
                    } else {
                        self.listOffset = -width
                        self.detailOffset = width
                        self.addLinkOffset = 0
                        self.newIdeaOffset = width
                    }
                }
            }

            // Clean up other views after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .addLink = self.appState.projectView {
                    self.showDetail = false
                    self.showNewIdea = false
                    self.currentDetail = nil
                }
            }

        case .newIdea:
            showNewIdea = true
            if reduceMotion {
                newIdeaOpacity = 0
            } else {
                newIdeaOffset = width
            }

            DispatchQueue.main.async {
                withAnimation(self.navigationAnimation) {
                    if self.reduceMotion {
                        self.listOpacity = 0
                        self.detailOpacity = 0
                        self.addLinkOpacity = 0
                        self.newIdeaOpacity = 1
                    } else {
                        self.listOffset = -width
                        self.detailOffset = width
                        self.addLinkOffset = width
                        self.newIdeaOffset = 0
                    }
                }
            }

            // Clean up other views after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .newIdea = self.appState.projectView {
                    self.showDetail = false
                    self.showAddLink = false
                    self.currentDetail = nil
                }
            }
        }
    }
}
