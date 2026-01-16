import SwiftUI

struct IdeasListView: View {
    let ideas: [Idea]
    let isGeneratingTitle: (String) -> Bool
    var onWorkOn: ((Idea) -> Void)?
    var onDismiss: ((Idea) -> Void)?

    @State private var isDoneCollapsed = true

    private var openIdeas: [Idea] {
        ideas.filter { $0.status == "open" }
    }

    private var inProgressIdeas: [Idea] {
        ideas.filter { $0.status == "in-progress" }
    }

    private var doneIdeas: [Idea] {
        ideas.filter { $0.status == "done" }
    }

    private var hasAnyIdeas: Bool {
        !ideas.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasAnyIdeas {
                if !openIdeas.isEmpty {
                    IdeaSection(
                        title: "OPEN",
                        ideas: openIdeas,
                        isGeneratingTitle: isGeneratingTitle,
                        onWorkOn: onWorkOn,
                        onDismiss: onDismiss
                    )
                }

                if !inProgressIdeas.isEmpty {
                    IdeaSection(
                        title: "IN PROGRESS",
                        ideas: inProgressIdeas,
                        isGeneratingTitle: isGeneratingTitle,
                        onWorkOn: nil,
                        onDismiss: onDismiss
                    )
                }

                if !doneIdeas.isEmpty {
                    CollapsibleIdeaSection(
                        title: "DONE",
                        count: doneIdeas.count,
                        isCollapsed: $isDoneCollapsed,
                        ideas: doneIdeas,
                        isGeneratingTitle: isGeneratingTitle
                    )
                }
            } else {
                EmptyIdeasView()
            }
        }
    }
}

private struct IdeaSection: View {
    let title: String
    let ideas: [Idea]
    let isGeneratingTitle: (String) -> Bool
    var onWorkOn: ((Idea) -> Void)?
    var onDismiss: ((Idea) -> Void)?

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 8) {
                DetailSectionLabel(title: title)

                ForEach(ideas, id: \.id) { idea in
                    IdeaCardView(
                        idea: idea,
                        isGeneratingTitle: isGeneratingTitle(idea.id),
                        onWorkOnThis: onWorkOn != nil ? { onWorkOn?(idea) } : nil,
                        onDismiss: onDismiss != nil ? { onDismiss?(idea) } : nil
                    )

                    if idea.id != ideas.last?.id {
                        Divider()
                            .background(Color.white.opacity(0.1))
                    }
                }
            }
        }
    }
}

private struct CollapsibleIdeaSection: View {
    let title: String
    let count: Int
    @Binding var isCollapsed: Bool
    let ideas: [Idea]
    let isGeneratingTitle: (String) -> Bool

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(AppTypography.badge)
                            .foregroundColor(.white.opacity(0.45))
                            .frame(width: 10)

                        DetailSectionLabel(title: title)

                        Text("(\(count))")
                            .font(AppTypography.labelMedium)
                            .foregroundColor(.white.opacity(0.35))

                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if !isCollapsed {
                    ForEach(ideas, id: \.id) { idea in
                        IdeaCardView(
                            idea: idea,
                            isGeneratingTitle: isGeneratingTitle(idea.id),
                            onWorkOnThis: nil,
                            onDismiss: nil
                        )
                        .opacity(0.6)

                        if idea.id != ideas.last?.id {
                            Divider()
                                .background(Color.white.opacity(0.1))
                        }
                    }
                }
            }
        }
    }
}

private struct EmptyIdeasView: View {
    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 8) {
                DetailSectionLabel(title: "IDEAS")

                Text("No ideas captured yet")
                    .font(AppTypography.body)
                    .foregroundColor(.white.opacity(0.5))

                Text("Use the lightbulb button on the project card to capture ideas")
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }
}
