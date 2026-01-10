import SwiftUI

struct AddProjectView: View {
    @EnvironmentObject var appState: AppState

    @State private var isBackHovered = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button(action: { appState.showProjectList() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Projects")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(isBackHovered ? 0.9 : 0.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(isBackHovered ? 0.08 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isBackHovered = hovering
                    }
                }
                .keyboardShortcut("[", modifiers: .command)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.3))

                Text("Add Project")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))

                Text("Coming soon")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.3))
            }

            Spacer()
        }
        .background(Color.hudBackground)
    }
}
