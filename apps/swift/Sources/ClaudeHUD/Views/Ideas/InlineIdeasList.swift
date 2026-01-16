import SwiftUI

struct InlineIdeasList: View {
    let ideas: [Idea]
    let remainingCount: Int
    let generatingTitleIds: Set<String>
    let onShowMore: () -> Void
    var onAddIdea: (() -> Void)?
    var onWorkOnIdea: ((Idea) -> Void)?
    var onDismissIdea: ((Idea) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ideas")
                    .font(AppTypography.labelMedium)
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                if let onAddIdea = onAddIdea {
                    Button(action: onAddIdea) {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(AppTypography.badge)
                            Text("Add")
                                .font(AppTypography.labelMedium)
                        }
                        .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        // Could add hover state here
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            ForEach(Array(ideas.enumerated()), id: \.element.id) { index, idea in
                IdeaCardView(
                    idea: idea,
                    isGeneratingTitle: generatingTitleIds.contains(idea.id),
                    onWorkOnThis: onWorkOnIdea.map { callback in { callback(idea) } },
                    onDismiss: onDismissIdea.map { callback in { callback(idea) } }
                )
                .padding(.horizontal, 4)

                if index < ideas.count - 1 {
                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.horizontal, 4)
                }
            }

            if remainingCount > 0 {
                Button(action: onShowMore) {
                    Text("+ \(remainingCount) more")
                        .font(AppTypography.labelMedium)
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
    }
}
