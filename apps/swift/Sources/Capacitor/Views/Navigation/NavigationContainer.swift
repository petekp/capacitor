import SwiftUI

/// Position multiplier for navigation offsets.
/// -1 = off-screen left, 0 = visible, 1 = off-screen right
private enum SlidePosition: CGFloat {
    case left = -1
    case center = 0
    case right = 1
}

struct NavigationContainer: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.prefersReducedMotion) private var reduceMotion

    // Position multipliers instead of absolute pixel offsets
    // This ensures offsets scale correctly when window is resized
    @State private var listPosition: SlidePosition = .center
    @State private var detailPosition: SlidePosition = .right

    @State private var currentDetail: Project?
    @State private var showDetail = false

    @State private var listOpacity: Double = 1
    @State private var detailOpacity: Double = 0

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

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack {
                ProjectsView()
                    .frame(width: width)
                    .offset(x: reduceMotion ? 0 : listPosition.rawValue * width)
                    .opacity(reduceMotion ? listOpacity : 1)
                    .zIndex(isListActive ? 1 : 0)
                    .allowsHitTesting(isListActive)

                if appState.isProjectDetailsEnabled, showDetail, let project = currentDetail {
                    ProjectDetailView(project: project)
                        .frame(width: width)
                        .offset(x: reduceMotion ? 0 : detailPosition.rawValue * width)
                        .opacity(reduceMotion ? detailOpacity : 1)
                        .zIndex(isDetailActive ? 1 : 0)
                        .allowsHitTesting(isDetailActive)
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
                handleNavigation(from: oldValue, to: newValue)
            }
        }
    }

    private func handleNavigation(from _: ProjectView, to newValue: ProjectView) {
        switch newValue {
        case .list:
            withAnimation(navigationAnimation) {
                if reduceMotion {
                    listOpacity = 1
                    detailOpacity = 0
                } else {
                    listPosition = .center
                    detailPosition = .right
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .list = appState.projectView {
                    showDetail = false
                    currentDetail = nil
                }
            }

        case let .detail(project):
            guard appState.isProjectDetailsEnabled else {
                appState.showProjectList()
                return
            }
            currentDetail = project
            showDetail = true
            if reduceMotion {
                detailOpacity = 0
            } else {
                detailPosition = .right
            }

            DispatchQueue.main.async {
                withAnimation(navigationAnimation) {
                    if reduceMotion {
                        listOpacity = 0
                        detailOpacity = 1
                    } else {
                        listPosition = .left
                        detailPosition = .center
                    }
                }
            }
        }
    }
}
