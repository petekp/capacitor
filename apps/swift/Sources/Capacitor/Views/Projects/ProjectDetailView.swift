import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    let project: Project

    @State private var appeared = false
    @State private var selectedIdea: Idea?
    @State private var selectedIdeaFrame: CGRect?
    @State private var methodSelectorIdea: Idea?

    private var isModalOpen: Bool {
        selectedIdea != nil || methodSelectorIdea != nil
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(project.name)
                        .font(AppTypography.pageTitle.monospaced())
                        .foregroundColor(.white)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)

                    if appState.isLlmFeaturesEnabled {
                        DescriptionSection(
                            description: appState.getDescription(for: project),
                            isGenerating: appState.isGeneratingDescription(for: project),
                            onGenerate: { appState.generateDescription(for: project) },
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                    }

                    if appState.isIdeaCaptureEnabled {
                        VStack(alignment: .leading, spacing: 12) {
                            DetailSectionLabel(title: "IDEA QUEUE")

                            let delegationState = appState.delegationState(for: project)
                            IdeaQueueView(
                                ideas: appState.getIdeas(for: project),
                                activityForIdea: { idea in
                                    IdeaQueueStatusResolver.resolve(
                                        idea: idea,
                                        isGeneratingTitle: appState.isGeneratingTitle(for: idea.id),
                                        delegationState: delegationState,
                                        runState: appState.activeRun(for: idea, in: project),
                                    )
                                },
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
                                },
                            )
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                    }

                    Button(action: {
                        appState.removeProject(project.path)
                        appState.showProjectList()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "minus.circle")
                            Text("Disconnect")
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
                .padding(.top, floatingMode ? 44 : 12)
                .padding(.bottom, floatingMode ? 64 : 16)
            }
            .blur(radius: isModalOpen ? 8 : 0)
            .saturation(isModalOpen ? 0.8 : 1)
            .animation(.easeInOut(duration: 0.25), value: isModalOpen)
            .background(floatingMode ? Color.clear : Color.hudBackground)

            if appState.isIdeaCaptureEnabled {
                IdeaDetailModalOverlay(
                    idea: selectedIdea,
                    anchorFrame: selectedIdeaFrame,
                    onDismiss: {
                        selectedIdea = nil
                        selectedIdeaFrame = nil
                    },
                    onDelegate: appState.isDelegationLoopEnabled ? { idea in
                        appState.delegateIdea(idea, for: project)
                        selectedIdea = nil
                        selectedIdeaFrame = nil
                    } : nil,
                    onRunMethod: appState.isMethodRunnerEnabled ? { idea in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            methodSelectorIdea = idea
                            selectedIdea = nil
                            selectedIdeaFrame = nil
                        }
                    } : nil,
                    onRemove: { idea in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            appState.dismissIdea(idea, for: project)
                        }
                        selectedIdea = nil
                        selectedIdeaFrame = nil
                    },
                )

                if let idea = methodSelectorIdea {
                    MethodSelectorModalOverlay(
                        methods: appState.listBuiltinMethods(),
                        onSelect: { method in
                            appState.runMethodOnIdea(idea, method: method, for: project)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                methodSelectorIdea = nil
                            }
                        },
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                methodSelectorIdea = nil
                            }
                        },
                    )
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
        .onExitCommand {
            appState.showProjectList()
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.projectDetailsIdentifier(for: project))
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
                .foregroundColor(.white.opacity(0.4))
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
            if let description {
                Text(description)
                    .font(AppTypography.body)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isGenerating {
                ShimmeringText(text: "Generating description...")
            }

            if description == nil, !isGenerating {
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
                            .fill(Color.white.opacity(isHovered ? 0.1 : 0)),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.15 : 0), lineWidth: 0.5),
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
