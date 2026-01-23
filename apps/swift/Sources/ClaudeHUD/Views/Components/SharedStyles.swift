import SwiftUI

struct BackButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .offset(x: isHovered ? -2 : 0)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(isHovered ? 0.95 : 0.55))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0))

                    if isHovered {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct SkeletonView: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.08),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .offset(x: isAnimating ? geometry.size.width : -geometry.size.width)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.5)
                .repeatForever(autoreverses: false)
            ) {
                isAnimating = true
            }
        }
    }
}

struct SkeletonCard: View {
    @Environment(\.floatingMode) private var floatingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SkeletonView()
                    .frame(width: 120, height: 14)

                Spacer()

                SkeletonView()
                    .frame(width: 60, height: 20)
                    .clipShape(Capsule())
            }

            SkeletonView()
                .frame(height: 12)

            SkeletonView()
                .frame(width: 180, height: 12)
        }
        .padding(12)
        .background {
            if floatingMode {
                DarkFrostedCard(tintOpacity: 0.15)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.hudCard)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }
}
