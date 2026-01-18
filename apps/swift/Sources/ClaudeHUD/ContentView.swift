import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    #if DEBUG
    @ObservedObject private var glassConfig = GlassConfig.shared
    #endif

    var body: some View {
        Group {
            switch appState.layoutMode {
            case .vertical:
                verticalLayout
            case .dock:
                dockLayout
            }
        }
        .background {
            if floatingMode {
                #if DEBUG
                DarkFrostedGlass()
                    .id(glassConfig.panelConfigHash)
                #else
                DarkFrostedGlass()
                #endif
            } else {
                Color.hudBackground
            }
        }
        .preferredColorScheme(.dark)
    }

    private var verticalLayout: some View {
        ZStack(alignment: .top) {
            NavigationContainer()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HeaderView()
        }
        .clipShape(RoundedRectangle(cornerRadius: floatingMode ? 22 : 0))
    }

    private var dockLayout: some View {
        DockLayoutView()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
