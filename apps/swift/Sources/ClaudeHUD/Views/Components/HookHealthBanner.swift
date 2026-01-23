import SwiftUI

struct HookHealthBanner: View {
    let health: HookHealthReport
    let onRetry: () -> Void

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        switch health.status {
        case .healthy, .unknown:
            EmptyView()

        case .stale(let lastSeenSecs):
            warningBanner(
                icon: "exclamationmark.triangle.fill",
                message: "Hooks stopped responding \(formatAge(lastSeenSecs)) ago",
                showRetry: true
            )

        case .unreadable(let reason):
            warningBanner(
                icon: "exclamationmark.triangle.fill",
                message: "Can't check hook health: \(reason)",
                showRetry: false
            )
        }
    }

    private func warningBanner(icon: String, message: String, showRetry: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.orange)

            Text(message)
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            if showRetry {
                Button(action: onRetry) {
                    Text("Refresh")
                        .font(AppTypography.caption.weight(.medium))
                        .foregroundColor(.orange.opacity(isHovered ? 1.0 : 0.8))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(message)")
        .accessibilityHint(showRetry ? Text("Double tap to refresh hook status") : Text(""))
    }

    private func formatAge(_ secs: UInt64) -> String {
        if secs < 120 {
            return "\(secs)s"
        }
        let mins = secs / 60
        if mins < 60 {
            return "\(mins)m"
        }
        let hours = mins / 60
        return "\(hours)h"
    }
}
