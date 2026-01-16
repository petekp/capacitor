import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    #if DEBUG
    @ObservedObject private var glassConfig = GlassConfig.shared
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            ZStack {
                switch appState.activeTab {
                case .projects:
                    NavigationContainer()
                case .artifacts:
                    ArtifactsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            BottomTabBar()
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
}

struct BottomTabBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    var body: some View {
        HStack(spacing: 0) {
            BottomTab(
                icon: "folder.fill",
                title: "Projects",
                count: appState.projects.count,
                isActive: appState.activeTab == .projects
            ) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    appState.activeTab = .projects
                }
            }

            BottomTab(
                icon: "sparkles",
                title: "Artifacts",
                count: appState.artifacts.count,
                isActive: appState.activeTab == .artifacts
            ) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    appState.activeTab = .artifacts
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.bottom, floatingMode ? 8 : 0)
        .background {
            if !floatingMode {
                Rectangle()
                    .fill(Color.hudBackground)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 0.5)
                    }
            }
        }
    }
}

struct BottomTab: View {
    let icon: String
    let title: String
    let count: Int
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(isActive ? .white : .white.opacity(isHovered ? 0.6 : 0.4))

                    if count > 0 {
                        Text("\(count)")
                            .font(AppTypography.badge)
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(isActive ? Color.hudAccent : Color.white.opacity(0.3))
                            )
                            .offset(x: 12, y: -8)
                    }
                }

                Text(title)
                    .font(AppTypography.tabLabel.weight(isActive ? .semibold : .medium))
                    .foregroundColor(isActive ? .white : .white.opacity(isHovered ? 0.6 : 0.4))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) tab")
        .accessibilityValue(count > 0 ? "\(count) items" : "No items")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(isActive ? "Currently selected" : "Double-tap to switch to \(title)")
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
