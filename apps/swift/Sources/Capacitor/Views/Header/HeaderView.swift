import SwiftUI
import AppKit

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    private let progressiveBlurHeight: CGFloat = 30

    private var isOnListView: Bool {
        if case .list = appState.projectView { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header content
            HStack {
                // Keep BackButton in hierarchy but control visibility via opacity
                // This prevents layout thrashing that can cause Auto Layout recursion crashes
                BackButton(title: "Projects") {
                    appState.showProjectList()
                }
                .opacity(isOnListView ? 0 : 1)
                .animation(.easeInOut(duration: 0.15), value: isOnListView)
                .allowsHitTesting(!isOnListView)

                Spacer()

                AddProjectButton()
            }
            .padding(.horizontal, 12)
            .padding(.top, floatingMode ? 9 : 6)
            .padding(.bottom, 6)
            .background {
                if floatingMode {
                    // Double-click area for window compact cycling
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            WindowFrameStore.shared.cycleCompactState()
                        }
                        .background(
                            VibrancyView(
                                material: .hudWindow,
                                blendingMode: .behindWindow,
                                isEmphasized: false,
                                forceDarkAppearance: true
                            )
                        )
                } else {
                    Color.hudBackground
                }
            }

            // Progressive blur zone - fades content below into the header
            ProgressiveBlurView(
                direction: .down,
                height: progressiveBlurHeight,
                material: floatingMode ? .hudWindow : .windowBackground
            )
            .allowsHitTesting(false)
        }
    }
}
