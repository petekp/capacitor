import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    let project: Project

    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    BackButton(title: "Projects") {
                        appState.showProjectList()
                    }
                    .keyboardShortcut("[", modifiers: .command)

                    Spacer()
                }

                Text(project.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)

                DescriptionCard(
                    description: appState.getDescription(for: project),
                    isGenerating: appState.isGeneratingDescription(for: project),
                    onGenerate: { appState.generateDescription(for: project) }
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)

                IdeasListView(
                    ideas: appState.getIdeas(for: project),
                    isGeneratingTitle: { appState.isGeneratingTitle(for: $0) },
                    onWorkOn: { idea in appState.workOnIdea(idea, for: project) },
                    onDismiss: { idea in appState.dismissIdea(idea, for: project) }
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)

                Spacer()
            }
            .padding(16)
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }
}

struct DetailCard<Content: View>: View {
    @Environment(\.floatingMode) private var floatingMode
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if floatingMode {
                    floatingBackground
                } else {
                    solidBackground
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var floatingBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.1), .white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.2), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
    }

    private var solidBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.hudCard)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(0.05), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
    }
}

struct DetailSectionLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.sectionAccent.opacity(0.8))
                .frame(width: 4, height: 4)

            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(2)
                .foregroundColor(.white.opacity(0.45))
        }
    }
}

struct DescriptionCard: View {
    let description: String?
    let isGenerating: Bool
    let onGenerate: () -> Void

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 10) {
                DetailSectionLabel(title: "DESCRIPTION")

                ZStack(alignment: .leading) {
                    // Description text - fades in when ready
                    if let description = description {
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Loading shimmer - visible during generation
                    if isGenerating {
                        ShimmeringText(text: "Generating description...")
                    }

                    // Generate button - visible when no description and not generating
                    if description == nil && !isGenerating {
                        Button(action: onGenerate) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11))
                                Text("Generate Description")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.3), value: description != nil)
                .animation(.easeInOut(duration: 0.3), value: isGenerating)
            }
        }
    }
}
