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
    var activeRunState: RuntimeRunState?
    var workBatchState: SessionState?
    var style: StatusChip.ChipStyle = .normal

    enum Presentation: Equatable {
        case delegationReview
        case delegationResuming
        case delegationResumeFailed
        case session(SessionState?)
    }

    static func presentation(
        sessionState: ProjectSessionState?,
        delegationState: RuntimeDelegationState?,
        activeRunState: RuntimeRunState?,
        workBatchState: SessionState? = nil,
    ) -> Presentation {
        // Runs win over delegation chips because a paused or active method run is the
        // most urgent project-level state the card can surface.
        if let runState = ProjectRunVisualStateResolver.visualState(for: activeRunState).sessionState {
            return .session(runState)
        }
        if delegationState?.status == "review_needed", delegationState?.currentReview != nil {
            return .delegationReview
        }
        if delegationState?.status == "resume_pending" {
            return .delegationResuming
        }
        if delegationState?.status == "resume_failed" {
            return .delegationResumeFailed
        }
        // New Work Batch behavior: Capacitor-managed checkpoint/queue state should
        // be visible on the project card instead of leaving the card looking Idle.
        if let workBatchState {
            return .session(workBatchState)
        }
        return .session(sessionState?.state)
    }

    @Environment(\.prefersReducedMotion) private var reduceMotion

    private var currentPresentation: Presentation {
        Self.presentation(
            sessionState: sessionState,
            delegationState: delegationState,
            activeRunState: activeRunState,
            workBatchState: workBatchState,
        )
    }

    var body: some View {
        Group {
            switch currentPresentation {
            case .delegationReview:
                DelegationReviewChip(style: style)
                    .transition(.opacity)
            case .delegationResuming:
                DelegationResumingChip(style: style)
                    .transition(.opacity)
            case .delegationResumeFailed:
                DelegationResumeFailedChip(style: style)
                    .transition(.opacity)
            case let .session(state):
                StatusChip(
                    state: state,
                    style: style,
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? AppMotion.reducedMotionFallback : .smooth(duration: 0.3), value: currentPresentation)
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
            .scaleEffect(style == .compact ? 0.85 : 1.0, anchor: .trailing)
            .accessibilityLabel("Delegation review needed")
    }
}

private struct DelegationResumingChip: View {
    let style: StatusChip.ChipStyle

    private var font: Font {
        .system(.callout, design: .monospaced).weight(.semibold)
    }

    var body: some View {
        Text("RESUMING")
            .font(font)
            .tracking(1.2)
            .foregroundStyle(Color.blue.opacity(0.75))
            .scaleEffect(style == .compact ? 0.85 : 1.0, anchor: .trailing)
            .accessibilityLabel("Delegation resuming")
    }
}

private struct DelegationResumeFailedChip: View {
    let style: StatusChip.ChipStyle

    private var font: Font {
        .system(.callout, design: .monospaced).weight(.semibold)
    }

    var body: some View {
        Text("RESUME FAILED")
            .font(font)
            .tracking(1.2)
            .foregroundStyle(Color.red.opacity(0.85))
            .scaleEffect(style == .compact ? 0.85 : 1.0, anchor: .trailing)
            .accessibilityLabel("Delegation resume failed")
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
