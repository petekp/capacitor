import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    #if DEBUG
    @ObservedObject private var glassConfig = GlassConfig.shared
    #endif

    private var isCaptureModalOpen: Bool {
        appState.showCaptureModal && appState.captureModalProject != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let containerSize = geometry.size

            ZStack {
                Group {
                    switch appState.layoutMode {
                    case .vertical:
                        verticalLayout
                    case .dock:
                        dockLayout
                    }
                }
                .blur(radius: isCaptureModalOpen ? 8 : 0)
                .saturation(isCaptureModalOpen ? 0.8 : 1)
                .animation(.easeInOut(duration: 0.25), value: isCaptureModalOpen)

                if let project = appState.captureModalProject {
                    IdeaCaptureModalOverlay(
                        isPresented: $appState.showCaptureModal,
                        projectName: project.name,
                        originFrame: appState.captureModalOrigin,
                        containerSize: containerSize,
                        onCapture: { text in
                            appState.captureIdea(for: project, text: text)
                        }
                    )
                }
            }
            .coordinateSpace(name: "contentView")
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
