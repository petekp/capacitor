import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @AppStorage("alwaysOnTop") private var alwaysOnTopStorage = false
    @AppStorage("hasSeenDragDropTip") private var hasSeenDragDropTip = false

    @State private var isDragHovered = false
    @State private var showDragDropTip = false

    #if DEBUG
        private let glassConfig = GlassConfig.shared
    #endif

    private var isCaptureModalOpen: Bool {
        appState.isIdeaCaptureEnabled &&
            appState.showCaptureModal &&
            appState.captureModalProject != nil
    }

    var body: some View {
        @Bindable var appState = appState

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

                if appState.isIdeaCaptureEnabled,
                   let project = appState.captureModalProject
                {
                    IdeaCaptureModalOverlay(
                        isPresented: $appState.showCaptureModal,
                        projectName: project.displayName,
                        originFrame: appState.captureModalOrigin,
                        containerSize: containerSize,
                        onCapture: { text in
                            appState.projectFeatureCoordinator.captureIdea(for: project, text: text)
                        },
                    )
                }

                if !appState.dashboardState.isLoading, appState.projectWorkflowState.projectCatalog.isEmpty, !isDragHovered, !appState.isFileDragOverCard {
                    EmptyStateBorderGlow()
                        .transition(.opacity)
                }

                AnchorEdgeGlow(controller: appState.anchoringController)

                ToastContainer(toast: $appState.toast)

                TipTooltipContainer(
                    showTip: $showDragDropTip,
                    message: "Tip: Drag folders anywhere to connect faster",
                )

                Group {
                    if isDragHovered || appState.isFileDragOverCard {
                        dropOverlay
                    }
                }
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isDragHovered)
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: appState.isFileDragOverCard)
            }
            .coordinateSpace(name: "contentView")
        }
        .onChange(of: appState.projectActionState.pendingDragDropTip) { _, pending in
            guard pending, !hasSeenDragDropTip else {
                appState.projectActionState.pendingDragDropTip = false
                return
            }
            // Wait for toast to dismiss, then show tip
            if appState.toast != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    showDragDropTip = true
                    hasSeenDragDropTip = true
                    appState.projectActionState.pendingDragDropTip = false
                }
            } else {
                showDragDropTip = true
                hasSeenDragDropTip = true
                appState.projectActionState.pendingDragDropTip = false
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
        .preferredColorScheme(.dark)
    }

    private var verticalLayout: some View {
        let cornerRadius = WindowCornerRadius.value(floatingMode: floatingMode)
        return ZStack {
            NavigationContainer()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                HeaderView()
                Spacer()
                FooterView(isPinned: $alwaysOnTopStorage)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var dockLayout: some View {
        DockLayoutView()
    }

    private var dropOverlay: some View {
        let cornerRadius = WindowCornerRadius.value(floatingMode: floatingMode)
        let innerCornerRadius = max(cornerRadius - 2, 0)
        return ZStack {
            // Frosted glass backdrop
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)

            // Brand tint over the blur
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.brand.opacity(0.08))

            MarchingAntsBorder(cornerRadius: innerCornerRadius)

            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.brand.opacity(0.8))

                Text("Drop to connect projects")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        appState.projectImportCoordinator.handleFileURLDrop(providers)
        return true
    }
}

// MARK: - Marching Ants Border

/// Self-contained animated dashed border that uses SwiftUI's animation
/// system instead of TimelineView to avoid per-frame re-evaluation of
/// the parent view hierarchy (which can overwhelm WindowServer when
/// combined with material blur).
private struct MarchingAntsBorder: View {
    let cornerRadius: CGFloat
    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 1, dash: [6, 4], dashPhase: phase),
            )
            .foregroundStyle(Color.brand.opacity(0.5))
            .padding(4)
            .onAppear {
                withAnimation(.linear(duration: 0.35).repeatForever(autoreverses: false)) {
                    phase = 10
                }
            }
    }
}

#Preview {
    ContentView()
        .environment(AppShellContainer.live().appState)
}
