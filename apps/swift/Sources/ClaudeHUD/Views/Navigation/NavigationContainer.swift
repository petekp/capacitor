import SwiftUI

struct NavigationContainer: View {
    @EnvironmentObject var appState: AppState

    @State private var listOffset: CGFloat = 0
    @State private var detailOffset: CGFloat = 1000
    @State private var addOffset: CGFloat = 1000
    @State private var currentDetail: Project?
    @State private var showDetail = false
    @State private var showAdd = false

    private let animationDuration: Double = 0.35
    private let springResponse: Double = 0.35
    private let springDamping: Double = 0.86

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack {
                ProjectsView()
                    .frame(width: width)
                    .offset(x: listOffset)

                if showDetail, let project = currentDetail {
                    ProjectDetailView(project: project)
                        .frame(width: width)
                        .offset(x: detailOffset)
                }

                if showAdd {
                    AddProjectView()
                        .frame(width: width)
                        .offset(x: addOffset)
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
            // Animate back to list
            withAnimation(.spring(response: springResponse, dampingFraction: springDamping)) {
                listOffset = 0
                detailOffset = width
                addOffset = width
            }
            // Clean up after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.1) {
                if case .list = appState.projectView {
                    showDetail = false
                    showAdd = false
                    currentDetail = nil
                }
            }

        case .detail(let project):
            // Prepare detail view off-screen
            currentDetail = project
            showDetail = true
            detailOffset = width

            // Animate in
            DispatchQueue.main.async {
                withAnimation(.spring(response: springResponse, dampingFraction: springDamping)) {
                    listOffset = -width
                    detailOffset = 0
                }
            }

        case .add:
            // Prepare add view off-screen
            showAdd = true
            addOffset = width

            // Animate in
            DispatchQueue.main.async {
                withAnimation(.spring(response: springResponse, dampingFraction: springDamping)) {
                    listOffset = -width
                    addOffset = 0
                }
            }
        }
    }
}
