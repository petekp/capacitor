import SwiftUI

struct IdeaCardView: View {
    let idea: Idea
    let isGeneratingTitle: Bool
    var onWorkOnThis: (() -> Void)?
    var onDismiss: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .trailing) {
            // Title display with crossfade between loading and final state
            // Using ZStack + opacity for smooth crossfade (not Group if/else which swaps views)
            ZStack(alignment: .leading) {
                // Final title - always rendered, fades in when ready
                Text(idea.title)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .opacity(isGeneratingTitle ? 0 : 1)

                // Loading shimmer - fades out when title is ready
                ShimmeringText(text: "Saving idea...")
                    .opacity(isGeneratingTitle ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.4), value: isGeneratingTitle)

            // Floating action bar with gradient backdrop
            if isHovered {
                HStack(spacing: 0) {
                    // Gradient fade from transparent to solid
                    LinearGradient(
                        colors: [
                            Color.hudBackground.opacity(0),
                            Color.hudBackground.opacity(0.9),
                            Color.hudBackground
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 40)

                    // Solid background behind buttons
                    HStack(spacing: 6) {
                        if let onWorkOnThis = onWorkOnThis {
                            Button(action: onWorkOnThis) {
                                Text("Work On This")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.blue)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }

                        if let onDismiss = onDismiss {
                            Button(action: onDismiss) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Color.green.opacity(0.8))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, 4)
                    .padding(.vertical, 8)
                    .background(Color.hudBackground)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct ShimmeringText: View {
    let text: String
    @State private var phase: CGFloat = -0.3

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.4))
            .overlay {
                GeometryReader { geometry in
                    // Use wider phase range (-0.3 to 1.3) so shimmer enters/exits smoothly
                    // When phase resets, the shimmer is off-screen so no visible jump
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: clampedLocation(phase - 0.15)),
                            .init(color: .white.opacity(0.5), location: clampedLocation(phase)),
                            .init(color: .clear, location: clampedLocation(phase + 0.15))
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .mask(
                        Text(text)
                            .font(.system(size: 12))
                    )
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
    }

    private func clampedLocation(_ value: CGFloat) -> CGFloat {
        min(1.0, max(0.0, value))
    }
}
