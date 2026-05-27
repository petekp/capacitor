import Foundation

enum RunCheckpointDecision: String, Equatable {
    case approve
    case requestChanges = "request_changes"

    var isPrimary: Bool {
        self == .approve
    }
}

struct RunCheckpointFollowThroughSubmission: Equatable {
    let target: RunCheckpointWindowTarget
    let decision: RunCheckpointDecision
    let submittedAt: Date
}

struct RunCheckpointFollowThroughProjection: Equatable {
    enum State: Equatable {
        case decisionAccepted
        case runResumed
        case revisionExpected
        case resumeSuspicious
        case resumeFailed
    }

    static let suspiciousResumeDelay: TimeInterval = 30

    let state: State
    let title: String
    let message: String
    let detail: String
    let iconName: String
    let tintName: String
    let recommendedAction: String?

    static func make(
        submission: RunCheckpointFollowThroughSubmission,
        run: RuntimeRunState?,
        now: Date = Date(),
        suspiciousDelay: TimeInterval = suspiciousResumeDelay,
    ) -> RunCheckpointFollowThroughProjection {
        let elapsed = now.timeIntervalSince(submission.submittedAt)

        guard let run else {
            return accepted(
                decision: submission.decision,
                detail: "Waiting for the next runtime snapshot for this run.",
            )
        }

        if run.status == "failed" || run.status == "cancelled" {
            return failed(run: run)
        }

        if run.activeCheckpoint?.id == submission.target.checkpointID {
            if elapsed >= suspiciousDelay {
                return suspicious
            }
            return accepted(
                decision: submission.decision,
                detail: "Waiting for the runtime snapshot to clear this checkpoint.",
            )
        }

        switch submission.decision {
        case .approve:
            if run.status == "active" || run.status == "completed" {
                return resumed(run: run)
            }
            if elapsed >= suspiciousDelay {
                return suspicious
            }
            return accepted(
                decision: submission.decision,
                detail: "Waiting for the run to resume.",
            )
        case .requestChanges:
            return revisionExpected
        }
    }

    private static func accepted(
        decision: RunCheckpointDecision,
        detail: String,
    ) -> RunCheckpointFollowThroughProjection {
        RunCheckpointFollowThroughProjection(
            state: .decisionAccepted,
            title: "Decision accepted",
            message: decision == .approve
                ? "Waiting for the run to resume."
                : "Feedback was delivered to the worker.",
            detail: detail,
            iconName: "paperplane.circle.fill",
            tintName: "blue",
            recommendedAction: nil,
        )
    }

    private static func resumed(run: RuntimeRunState) -> RunCheckpointFollowThroughProjection {
        RunCheckpointFollowThroughProjection(
            state: .runResumed,
            title: run.status == "completed" ? "Decision accepted. Run completed." : "Decision accepted. Run resumed.",
            message: run.status == "completed"
                ? "The run finished after your approval."
                : "Next expected signal: next checkpoint or completion.",
            detail: cleaned(run.statusMessage) ?? "The checkpoint cleared from the active run snapshot.",
            iconName: "checkmark.circle.fill",
            tintName: "green",
            recommendedAction: nil,
        )
    }

    private static var revisionExpected: RunCheckpointFollowThroughProjection {
        RunCheckpointFollowThroughProjection(
            state: .revisionExpected,
            title: "Feedback delivered. Worker is revising.",
            message: "Next expected signal: revision checkpoint addressing your note.",
            detail: "Capacitor will surface the next checkpoint when it needs your direction.",
            iconName: "arrow.triangle.2.circlepath.circle.fill",
            tintName: "orange",
            recommendedAction: nil,
        )
    }

    private static var suspicious: RunCheckpointFollowThroughProjection {
        RunCheckpointFollowThroughProjection(
            state: .resumeSuspicious,
            title: "Decision accepted, but the worker did not resume.",
            message: "The runtime snapshot still shows the same checkpoint.",
            detail: "Safe action: inspect the terminal before retrying anything.",
            iconName: "exclamationmark.triangle.fill",
            tintName: "red",
            recommendedAction: "Inspect terminal",
        )
    }

    private static func failed(run: RuntimeRunState) -> RunCheckpointFollowThroughProjection {
        RunCheckpointFollowThroughProjection(
            state: .resumeFailed,
            title: "Decision accepted, but the run failed.",
            message: cleaned(run.statusMessage) ?? "The run entered a terminal failure state after your decision.",
            detail: "Safe action: inspect the terminal.",
            iconName: "xmark.octagon.fill",
            tintName: "red",
            recommendedAction: "Inspect terminal",
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
