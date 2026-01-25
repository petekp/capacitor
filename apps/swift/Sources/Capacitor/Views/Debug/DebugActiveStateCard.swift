import SwiftUI

#if DEBUG
    struct DebugActiveStateCard: View {
        @Environment(AppState.self) var appState: AppState

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Debug: Active Resolver")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))

                Text("activeProject=\(appState.activeProjectPath ?? "nil")")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))

                Text("activeSource=\(String(describing: appState.activeSource))")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(10)
            .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1),
            )
        }
    }
#endif
