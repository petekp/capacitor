import SwiftUI

/// Displays the session status using the existing StatusIndicator animations.
struct StatusChip: View {
    let state: SessionState?
    var style: ChipStyle = .normal

    @Environment(\.prefersReducedMotion) private var reduceMotion

    enum ChipStyle {
        case normal
        case compact
    }

    private var effectiveState: SessionState {
        state ?? .idle
    }

    private var chipOpacity: Double {
        if effectiveState == .idle {
            return 0.6
        }
        return 1.0
    }

    private var accessibilityLabelText: String {
        switch effectiveState {
        case .working: "Working"
        case .ready: "Ready"
        case .idle: "Idle"
        case .compacting: "Compacting"
        case .waiting: "Waiting"
        }
    }

    var body: some View {
        StatusIndicator(state: effectiveState)
            .scaleEffect(style == .compact ? 0.85 : 1.0, anchor: .leading)
            .opacity(chipOpacity)
            .animation(reduceMotion ? AppMotion.reducedMotionFallback : .smooth(duration: 0.3), value: effectiveState)
            .accessibilityLabel(Text(accessibilityLabelText))
    }
}

/// A row of status chips for project cards.
struct StatusChipsRow: View {
    let sessionState: ProjectSessionState?
    var delegationState: RuntimeDelegationState?
    var style: StatusChip.ChipStyle = .normal

    var body: some View {
        HStack(spacing: 8) {
            if delegationState?.status == "review_needed", delegationState?.currentReview != nil {
                DelegationReviewChip(style: style)
            }

            StatusChip(
                state: sessionState?.state,
                style: style,
            )
        }
    }
}

private struct DelegationReviewChip: View {
    let style: StatusChip.ChipStyle

    private var font: Font {
        .system(.callout, design: .monospaced).weight(.semibold)
    }

    var body: some View {
        Text("REVIEW")
            .font(font)
            .tracking(1.2)
            .foregroundStyle(Color.orange.opacity(0.95))
            .scaleEffect(style == .compact ? 0.85 : 1.0, anchor: .leading)
            .accessibilityLabel("Delegation review needed")
    }
}

#Preview("Status Chips") {
    VStack(alignment: .leading, spacing: 16) {
        Group {
            StatusChip(state: .ready)
            StatusChip(state: .working)
            StatusChip(state: .waiting)
            StatusChip(state: .idle)
            StatusChip(state: nil)
        }

        Divider()

        Text("Compact Style").font(.caption).foregroundColor(.secondary)

        Group {
            StatusChip(state: .ready, style: .compact)
            StatusChip(state: .working, style: .compact)
        }
    }
    .padding()
    .background(Color.hudCard)
}
