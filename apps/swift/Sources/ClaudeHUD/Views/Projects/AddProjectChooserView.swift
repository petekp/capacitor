import SwiftUI

struct AddProjectChooserView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BackButton(title: "Projects") {
                    appState.showProjectList()
                }
                .keyboardShortcut("[", modifiers: .command)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()

            HStack(spacing: 16) {
                ChooserCard(
                    icon: "folder.badge.plus",
                    title: "Link Existing",
                    description: "Add a project folder you're already working on",
                    appeared: appeared,
                    delay: 0.1
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        appState.projectView = .addLink
                    }
                }

                ChooserCard(
                    icon: "sparkles",
                    title: "Create with Claude",
                    description: "Scaffold a new project from a description",
                    appeared: appeared,
                    delay: 0.2
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        appState.projectView = .newIdea
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .onAppear {
            if !reduceMotion {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                    appeared = true
                }
            } else {
                appeared = true
            }
        }
    }
}

private struct ChooserCard: View {
    let icon: String
    let title: String
    let description: String
    let appeared: Bool
    let delay: Double
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.floatingMode) private var floatingMode
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                .white.opacity(isHovered ? 0.9 : 0.6),
                                .white.opacity(isHovered ? 0.7 : 0.4)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                VStack(spacing: 6) {
                    Text(title)
                        .font(AppTypography.cardSubtitle.weight(.semibold))
                        .foregroundColor(.white.opacity(isHovered ? 0.95 : 0.85))

                    Text(description)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(isHovered ? 0.6 : 0.45))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 20)
            .background {
                if floatingMode {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial.opacity(isHovered ? 0.8 : 0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    Color.white.opacity(isHovered ? 0.2 : 0.1),
                                    lineWidth: 0.5
                                )
                        )
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.hudCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    Color.white.opacity(isHovered ? 0.15 : 0.08),
                                    lineWidth: 0.5
                                )
                        )
                }
            }
            .shadow(
                color: .black.opacity(isHovered ? 0.3 : 0.15),
                radius: isHovered ? 12 : 6,
                y: isHovered ? 4 : 2
            )
            .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .animation(
            reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8).delay(delay),
            value: appeared
        )
        .accessibilityLabel(title)
        .accessibilityHint(description)
    }
}

#Preview {
    AddProjectChooserView()
        .environmentObject(AppState())
        .frame(width: 500, height: 400)
        .preferredColorScheme(.dark)
}
