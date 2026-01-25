import AppKit
import SwiftUI

#if DEBUG
    struct DebugActivationTraceCard: View {
        @Environment(AppState.self) var appState: AppState

        private func copyTrace(_ trace: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(trace, forType: .string)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Debug: Activation Trace")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))

                    Spacer()

                    if let trace = appState.activationTrace, !trace.isEmpty {
                        Button("Copy") {
                            copyTrace(trace)
                        }
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                        .buttonStyle(.plain)

                        Button("Clear") {
                            appState.activationTrace = nil
                        }
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                        .buttonStyle(.plain)
                    }
                }

                if let trace = appState.activationTrace, !trace.isEmpty {
                    ScrollView(.vertical) {
                        Text(trace)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                } else {
                    Text("No activation trace yet (debug-only). Set CAPACITOR_ACTIVATION_TRACE=1 and launch a project to capture one.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.35))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1),
            )
        }
    }
#endif
