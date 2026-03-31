import Foundation

/// Pure-function resolver for the project card context line.
///
/// The card displays a single context line beneath the project name. Three
/// signal sources compete for that slot, resolved by strict priority:
///
///   1. **Run context** — active orchestrator run status message
///   2. **Delegation context** — worker delegation status / workingOn
///   3. **Session description** — standalone `projectStatus.workingOn`
///
/// This resolver encapsulates the cascade so it can be unit-tested without
/// instantiating the SwiftUI view hierarchy.
enum ProjectCardContextLineResolver {
    struct Inputs {
        let runVisualState: RunVisualState
        let activeRunState: RuntimeRunState?
        let delegationState: RuntimeDelegationState?
        let projectStatus: ProjectStatus?
        /// Pre-selected summary variant from SessionSummarizer (best fit for card width).
        var sessionSummary: String?
    }

    /// Resolve the context line for a project card given all signal inputs.
    static func resolve(_ inputs: Inputs) -> String? {
        // Priority 1: Active run context text
        if let runText = runContextText(
            runVisualState: inputs.runVisualState,
            activeRunState: inputs.activeRunState,
        ) {
            return runText
        }

        // Only consult lower-priority sources when no run is visually active
        guard inputs.runVisualState == .none else { return nil }

        // Priority 2: Delegation context text
        if let delegationText = delegationContextText(
            delegationState: inputs.delegationState,
            projectStatus: inputs.projectStatus,
        ) {
            return delegationText
        }

        // Priority 3: Standalone session description — prefer width-fitted variant,
        // fall back to projectStatus.workingOn from hud-status.json
        return sessionDescriptionText(
            delegationState: inputs.delegationState,
            runVisualState: inputs.runVisualState,
            sessionSummary: inputs.sessionSummary,
            projectStatus: inputs.projectStatus,
        )
    }

    // MARK: - Run Context

    static func runContextText(
        runVisualState: RunVisualState,
        activeRunState: RuntimeRunState?,
    ) -> String? {
        let hasPhases = activeRunState.map { !$0.phases.isEmpty } ?? false

        switch runVisualState {
        case let .completed(statusMessage):
            if hasPhases { return statusMessage }
            if let methodName = activeRunState?.methodName {
                return "\(methodName) completed"
            }
            return statusMessage ?? "Run completed"
        case let .failed(statusMessage):
            if hasPhases { return statusMessage }
            return statusMessage ?? "Run failed"
        default:
            return runVisualState.statusMessage
        }
    }

    // MARK: - Delegation Context

    static func delegationContextText(
        delegationState: RuntimeDelegationState?,
        projectStatus: ProjectStatus?,
    ) -> String? {
        guard let delegationState else { return nil }

        if let workingOn = projectStatus?.workingOn?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !workingOn.isEmpty
        {
            return workingOn
        }

        let milestoneID = delegationState.currentReview?.milestoneId ?? delegationState.submittedMilestoneId

        switch delegationState.status {
        case "review_needed":
            if let milestoneID, !milestoneID.isEmpty {
                return "Milestone \(milestoneID) awaiting review"
            }
            return "Review ready"
        case "resume_pending":
            if let milestoneID, !milestoneID.isEmpty {
                return "Resuming milestone \(milestoneID)"
            }
            return "Delegation is resuming"
        case "resume_failed":
            if let milestoneID, !milestoneID.isEmpty {
                return "Resume failed for milestone \(milestoneID)"
            }
            return "Resume failed"
        default:
            if let milestoneID, !milestoneID.isEmpty {
                return "Milestone \(milestoneID) in progress"
            }
            return "Delegation in progress"
        }
    }

    // MARK: - Session Description

    static func sessionDescriptionText(
        delegationState: RuntimeDelegationState?,
        runVisualState: RunVisualState,
        sessionSummary: String?,
        projectStatus: ProjectStatus?,
    ) -> String? {
        guard delegationState == nil, runVisualState == .none else { return nil }

        // Prefer the width-fitted variant from SessionSummarizer
        if let summary = sessionSummary, !summary.isEmpty {
            return summary
        }

        // Fall back to hud-status.json working_on
        guard let workingOn = projectStatus?.workingOn?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !workingOn.isEmpty
        else { return nil }
        return workingOn
    }
}
