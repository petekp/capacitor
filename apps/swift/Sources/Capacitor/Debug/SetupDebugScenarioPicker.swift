import SwiftUI

#if DEBUG
    struct SetupDebugScenarioPicker: View {
        @Bindable var setupWorkflowState: SetupWorkflowState

        @State private var debugScenario: SetupPreviewScenario?

        var body: some View {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "ant.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))

                    Text("Setup State")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Picker("", selection: $debugScenario) {
                        Text("Live").tag(SetupPreviewScenario?.none)
                        Divider()
                        ForEach(SetupPreviewScenario.allCases) { scenario in
                            Text(scenario.rawValue).tag(Optional(scenario))
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.mini)
                    .frame(width: 140)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.top, 8)
            .onChange(of: debugScenario) { _, newValue in
                if let scenario = newValue {
                    setupWorkflowState.activatePreview(scenario)
                } else {
                    setupWorkflowState.restoreLive()
                }
            }
        }
    }
#else
    struct SetupDebugScenarioPicker: View {
        var setupWorkflowState: SetupWorkflowState

        var body: some View {
            EmptyView()
        }
    }
#endif
