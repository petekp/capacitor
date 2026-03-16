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

    @State private var currentSecondaryView: ProjectView?
    @State private var showSecondary = false

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
        if case .delegationReview = appState.projectView { return true }
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

                if showSecondary, let currentSecondaryView {
                    secondaryView(currentSecondaryView)
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
                    showSecondary = false
                    currentSecondaryView = nil
                }
            }

        case let .detail(project):
            guard appState.isProjectDetailsEnabled else {
                appState.showProjectList()
                return
            }
            currentSecondaryView = .detail(project)
            showSecondary = true
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

        case let .delegationReview(project):
            guard appState.isDelegationLoopEnabled else {
                appState.showProjectList()
                return
            }
            currentSecondaryView = .delegationReview(project)
            showSecondary = true
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

    @ViewBuilder
    private func secondaryView(_ projectView: ProjectView) -> some View {
        switch projectView {
        case let .detail(project):
            if appState.isProjectDetailsEnabled {
                ProjectDetailView(project: project)
            }
        case let .delegationReview(project):
            if appState.isDelegationLoopEnabled {
                DelegationReviewView(project: project)
            }
        case .list:
            EmptyView()
        }
    }
}
