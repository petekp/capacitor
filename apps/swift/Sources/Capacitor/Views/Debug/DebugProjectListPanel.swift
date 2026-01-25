import SwiftUI

#if DEBUG
    @MainActor
    struct DebugProjectListPanel: View {
        @Environment(AppState.self) var appState: AppState
        @AppStorage("debugShowProjectListDiagnostics") private var debugShowProjectListDiagnostics = true
        @State private var panelSize = CGSize(width: 360, height: 520)

        private let cornerRadius: CGFloat = 12

        var body: some View {
            VStack(spacing: 0) {
                header

                Divider()
                    .background(Color.white.opacity(0.08))

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let status = appState.runtimeStatus, status.isEnabled {
                            RuntimeStatusBadge(status: status)
                                .padding(.bottom, 2)
                            if let rollout = appState.routingRollout {
                                RoutingRolloutBadge(rollout: rollout)
                                    .padding(.bottom, 2)
                            }
                        }

                        DebugActiveStateCard()
                        DebugSessionStateCard()
                        DebugShellStateCard()
                        DebugActivationTraceCard()
                    }
                    .padding(12)
                }
            }
            .frame(width: panelSize.width, height: panelSize.height)
            .background {
                DarkFrostedGlass()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background(TuningPanelWindowConfigurator())
        }

        private var header: some View {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project Diagnostics")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("Debug build")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }

                Spacer()

                Toggle("Show in List", isOn: $debugShowProjectListDiagnostics)
                    .toggleStyle(.switch)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(12)
        }
    }
#endif
