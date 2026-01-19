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

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack {
                ProjectsView()
                    .frame(width: width)
                    .offset(x: reduceMotion ? 0 : listOffset)
                    .opacity(reduceMotion ? listOpacity : 1)

                if showDetail, let project = currentDetail {
                    ProjectDetailView(project: project)
                        .frame(width: width)
                        .offset(x: reduceMotion ? 0 : detailOffset)
                        .opacity(reduceMotion ? detailOpacity : 1)
                }

                if showAddLink {
                    AddProjectView()
                        .frame(width: width)
                        .offset(x: reduceMotion ? 0 : addLinkOffset)
                        .opacity(reduceMotion ? addLinkOpacity : 1)
                }

                if showNewIdea {
                    NewIdeaView()
                        .frame(width: width)
                        .offset(x: reduceMotion ? 0 : newIdeaOffset)
                        .opacity(reduceMotion ? newIdeaOpacity : 1)
                }
            }
            .clipped()
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
                withAnimation(navigationAnimation) {
                    if reduceMotion {
                        listOpacity = 0
                        detailOpacity = 1
                    } else {
                        listOffset = -width
                        detailOffset = 0
                    }
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
                withAnimation(navigationAnimation) {
                    if reduceMotion {
                        listOpacity = 0
                        addLinkOpacity = 1
                    } else {
                        listOffset = -width
                        addLinkOffset = 0
                    }
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
                withAnimation(navigationAnimation) {
                    if reduceMotion {
                        listOpacity = 0
                        newIdeaOpacity = 1
                    } else {
                        listOffset = -width
                        newIdeaOffset = 0
                    }
                }
            }
        }
    }
}
