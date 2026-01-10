import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.transparentMode) private var transparentMode

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            Divider()
                .opacity(transparentMode ? 0.5 : 1)

            ZStack {
                switch appState.activeTab {
                case .projects:
                    NavigationContainer()
                case .artifacts:
                    ArtifactsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(transparentMode ? Color.clear : Color.hudBackground)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
