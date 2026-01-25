import SwiftUI

/// Displays the session status with staleness-based opacity.
/// Uses the existing StatusIndicator animations (ellipsis, compacting).
struct StatusChip: View {
    let state: SessionState?
    let stateChangedAt: String?
    var style: ChipStyle = .normal
    var staleOverride: Bool?

    @Environment(\.prefersReducedMotion) private var reduceMotion

    enum ChipStyle {
        case normal
        case compact
    }

    private var effectiveState: SessionState {
        state ?? .idle
    }

    private var isStale: Bool {
        if let staleOverride {
            return staleOverride
        }
        return SessionStaleness.isReadyStale(state: state, stateChangedAt: stateChangedAt)
    }

    private var chipOpacity: Double {
        if effectiveState == .idle || isStale {
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
    let isStale: Bool
    var style: StatusChip.ChipStyle = .normal

    var body: some View {
        HStack(spacing: 8) {
            StatusChip(
                state: sessionState?.state,
                stateChangedAt: sessionState?.stateChangedAt,
                style: style,
                staleOverride: isStale,
            )
            if isStale {
                StaleBadge(style: style == .compact ? .compact : .normal)
            }
        }
    }
}

#Preview("Status Chips") {
    VStack(alignment: .leading, spacing: 16) {
        Group {
            StatusChip(state: .ready, stateChangedAt: ISO8601DateFormatter.shared.string(from: Date().addingTimeInterval(-120)))
            StatusChip(state: .working, stateChangedAt: ISO8601DateFormatter.shared.string(from: Date().addingTimeInterval(-300)))
            StatusChip(state: .waiting, stateChangedAt: ISO8601DateFormatter.shared.string(from: Date().addingTimeInterval(-3600)))
            StatusChip(state: .idle, stateChangedAt: ISO8601DateFormatter.shared.string(from: Date().addingTimeInterval(-86400 * 3)))
            StatusChip(state: nil, stateChangedAt: nil)
        }

        Divider()

        Text("Compact Style").font(.caption).foregroundColor(.secondary)

        Group {
            StatusChip(state: .ready, stateChangedAt: ISO8601DateFormatter.shared.string(from: Date().addingTimeInterval(-120)), style: .compact)
            StatusChip(state: .working, stateChangedAt: ISO8601DateFormatter.shared.string(from: Date().addingTimeInterval(-300)), style: .compact)
        }
    }
    .padding()
    .background(Color.hudCard)
}
