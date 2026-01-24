import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    let project: Project

    @State private var appeared = false
    @State private var selectedIdea: Idea?
    @State private var selectedIdeaFrame: CGRect?

    private var isModalOpen: Bool {
        selectedIdea != nil
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        BackButton(title: "Projects") {
                            appState.showProjectList()
                        }

                        Spacer()
                    }

                    Text(project.name)
                        .font(AppTypography.pageTitle.monospaced())
                        .foregroundColor(.white)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)

                    DescriptionSection(
                        description: appState.getDescription(for: project),
                        isGenerating: appState.isGeneratingDescription(for: project),
                        onGenerate: { appState.generateDescription(for: project) }
                    )
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)

                    VStack(alignment: .leading, spacing: 12) {
                        DetailSectionLabel(title: "IDEA QUEUE")

                        IdeaQueueView(
                            ideas: appState.getIdeas(for: project),
                            isGeneratingTitle: { appState.isGeneratingTitle(for: $0) },
                            onTapIdea: { idea, frame in
                                selectedIdea = idea
                                selectedIdeaFrame = frame
                            },
                            onReorder: { reorderedIdeas in
                                appState.reorderIdeas(reorderedIdeas, for: project)
                            },
                            onRemove: { idea in
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    appState.dismissIdea(idea, for: project)
                                }
                            }
                        )
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)

                    Button(action: {
                        appState.removeProject(project.path)
                        appState.showProjectList()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "minus.circle")
                            Text("Remove from HUD")
                        }
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, floatingMode ? 64 : 16)
                .padding(.bottom, 16)
            }
            .blur(radius: isModalOpen ? 8 : 0)
            .saturation(isModalOpen ? 0.8 : 1)
            .animation(.easeInOut(duration: 0.25), value: isModalOpen)
            .background(floatingMode ? Color.clear : Color.hudBackground)

            IdeaDetailModalOverlay(
                idea: selectedIdea,
                anchorFrame: selectedIdeaFrame,
                onDismiss: {
                    selectedIdea = nil
                    selectedIdeaFrame = nil
                },
                onRemove: { idea in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        appState.dismissIdea(idea, for: project)
                    }
                    selectedIdea = nil
                    selectedIdeaFrame = nil
                }
            )
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
        .onExitCommand {
            appState.showProjectList()
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
                .font(AppTypography.label.weight(.bold))
                .tracking(2)
                .foregroundColor(.white.opacity(0.45))
        }
    }
}

struct DescriptionSection: View {
    let description: String?
    let isGenerating: Bool
    let onGenerate: () -> Void

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if let description = description {
                Text(description)
                    .font(AppTypography.body)
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isGenerating {
                ShimmeringText(text: "Generating description...")
            }

            if description == nil && !isGenerating {
                Button(action: onGenerate) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(AppTypography.cardTitle)
                        Text("Generate Description")
                            .font(AppTypography.bodySecondary.weight(.medium))
                    }
                    .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(isHovered ? 0.1 : 0))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.15 : 0), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
                .onHover { hovering in
                    withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.2, dampingFraction: 0.7)) {
                        isHovered = hovering
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: description != nil)
        .animation(.easeInOut(duration: 0.3), value: isGenerating)
    }
}
