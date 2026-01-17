import SwiftUI

struct NavigationContainer: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.prefersReducedMotion) private var reduceMotion

    @State private var listOffset: CGFloat = 0
    @State private var detailOffset: CGFloat = 1000
    @State private var addOffset: CGFloat = 1000
    @State private var addLinkOffset: CGFloat = 1000
    @State private var newIdeaOffset: CGFloat = 1000
    @State private var currentDetail: Project?
    @State private var showDetail = false
    @State private var showAdd = false
    @State private var showAddLink = false
    @State private var showNewIdea = false

    @State private var listOpacity: Double = 1
    @State private var detailOpacity: Double = 0
    @State private var addOpacity: Double = 0
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

                if showAdd {
                    AddProjectChooserView()
                        .frame(width: width)
                        .offset(x: reduceMotion ? 0 : addOffset)
                        .opacity(reduceMotion ? addOpacity : 1)
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
                    addOpacity = 0
                    addLinkOpacity = 0
                    newIdeaOpacity = 0
                } else {
                    listOffset = 0
                    detailOffset = width
                    addOffset = width
                    addLinkOffset = width
                    newIdeaOffset = width
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .list = appState.projectView {
                    showDetail = false
                    showAdd = false
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

        case .add:
            // Coming back from addLink or newIdea, or fresh from list
            let comingFromSubView = oldValue == .addLink || oldValue == .newIdea

            showAdd = true
            if reduceMotion {
                addOpacity = 0
            } else {
                // If coming from sub-view, chooser slides in from left; otherwise from right
                addOffset = comingFromSubView ? -width : width
            }

            DispatchQueue.main.async {
                withAnimation(navigationAnimation) {
                    if reduceMotion {
                        listOpacity = 0
                        addOpacity = 1
                        addLinkOpacity = 0
                        newIdeaOpacity = 0
                    } else {
                        listOffset = -width
                        addOffset = 0
                        // Slide sub-views out to the right
                        addLinkOffset = width
                        newIdeaOffset = width
                    }
                }
            }

            // Clean up sub-views after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .add = appState.projectView {
                    showAddLink = false
                    showNewIdea = false
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
                        addOpacity = 0
                        addLinkOpacity = 1
                    } else {
                        listOffset = -width
                        // Slide chooser out to the left
                        addOffset = -width
                        addLinkOffset = 0
                    }
                }
            }

            // Clean up chooser after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .addLink = appState.projectView {
                    showAdd = false
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
                        addOpacity = 0
                        newIdeaOpacity = 1
                    } else {
                        listOffset = -width
                        // Slide chooser out to the left
                        addOffset = -width
                        newIdeaOffset = 0
                    }
                }
            }

            // Clean up chooser after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .newIdea = appState.projectView {
                    showAdd = false
                }
            }
        }
    }
}
