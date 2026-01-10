import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 12) {
            TabButton(
                title: "Projects",
                count: appState.projects.count,
                isActive: appState.activeTab == .projects
            ) {
                appState.activeTab = .projects
            }

            TabButton(
                title: "Artifacts",
                count: appState.artifacts.count,
                isActive: appState.activeTab == .artifacts
            ) {
                appState.activeTab = .artifacts
            }

            Spacer()

            RelayStatusIndicator()
                .onTapGesture {
                    showingSettings.toggle()
                }
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    RelaySettingsView()
                        .environmentObject(appState)
                        .frame(width: 320)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.hudBackground)
    }
}

struct RelayStatusIndicator: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            if appState.relayClient.isConfigured {
                Circle()
                    .fill(appState.relayClient.isConnected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)

                if appState.isRemoteMode {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
        .contentShape(Rectangle())
    }
}

struct TabButton: View {
    let title: String
    let count: Int
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .medium))

                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isActive ? Color.hudAccent.opacity(0.2) : Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }
}
