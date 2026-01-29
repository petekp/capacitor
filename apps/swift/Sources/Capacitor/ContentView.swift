import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @AppStorage("alwaysOnTop") private var alwaysOnTopStorage = false
    @AppStorage("hasSeenDragDropTip") private var hasSeenDragDropTip = false

    @State private var isDragHovered = false
    @State private var showDragDropTip = false

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

                ToastContainer(toast: $appState.toast)

                TipTooltipContainer(
                    showTip: $showDragDropTip,
                    message: "Tip: Drag folders anywhere to add faster"
                )

                if isDragHovered {
                    dropOverlay
                }
            }
            .coordinateSpace(name: "contentView")
        }
        .onChange(of: appState.pendingDragDropTip) { _, pending in
            guard pending, !hasSeenDragDropTip else {
                appState.pendingDragDropTip = false
                return
            }
            // Wait for toast to dismiss, then show tip
            if appState.toast != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    showDragDropTip = true
                    hasSeenDragDropTip = true
                    appState.pendingDragDropTip = false
                }
            } else {
                showDragDropTip = true
                hasSeenDragDropTip = true
                appState.pendingDragDropTip = false
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDragHovered) { providers in
            handleDrop(providers)
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
        .overlay {
            // Larger resize handles for floating mode (no title bar = thin edges)
            if floatingMode {
                WindowResizeHandles(handleWidth: 10)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var verticalLayout: some View {
        ZStack {
            NavigationContainer()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                HeaderView()
                Spacer()
                FooterView(isPinned: $alwaysOnTopStorage)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: floatingMode ? 22 : 0))
    }

    private var dockLayout: some View {
        DockLayoutView()
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: floatingMode ? 22 : 0)
                .fill(Color.hudAccent.opacity(0.15))

            RoundedRectangle(cornerRadius: floatingMode ? 20 : 0)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .foregroundColor(Color.hudAccent.opacity(0.6))
                .padding(4)

            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.hudAccent.opacity(0.8))

                Text("Drop to add projects")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: isDragHovered)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }

            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                DispatchQueue.main.async {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                appState.addProjectsFromDrop(urls)
            }
        }

        return true
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
