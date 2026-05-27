import Foundation

enum AccessibilityIdentifiers {
    static let backProjectsIdentifier = "ax.nav.back-projects"
    static let ideaDetailIdentifier = "ax.idea-detail"
    static let ideaDetailDismissIdentifier = "ax.idea-detail.dismiss"
    static let ideaDetailDelegateIdentifier = "ax.idea-detail.delegate"
    static let ideaDetailReviewIdentifier = "ax.idea-detail.review"
    static let ideaDetailRemoveIdentifier = "ax.idea-detail.remove"
    static let delegationReviewIdentifier = "ax.delegation-review"
    static let delegationReviewApproveIdentifier = "ax.delegation-review.approve"
    static let delegationReviewRequestChangesIdentifier = "ax.delegation-review.request-changes"
    static let delegationReviewNotesIdentifier = "ax.delegation-review.notes"
    static let runCheckpointReviewIdentifier = "ax.run-checkpoint-review"
    static let runCheckpointApproveIdentifier = "ax.run-checkpoint-review.approve"
    static let runCheckpointRequestChangesIdentifier = "ax.run-checkpoint-review.request-changes"
    static let runCheckpointNotesIdentifier = "ax.run-checkpoint-review.notes"
    static let runCheckpointTimelineIdentifier = "ax.run-checkpoint-timeline"
    static let receiptProofRenderingIdentifier = "ax.receipt-proof-rendering"
    static let returnBriefIdentifier = "ax.return-brief"
    static let endOfDayClosureIdentifier = "ax.end-of-day-closure"

    static let ideaCaptureOverlayIdentifier = "ax.idea-capture-overlay"
    static let ideaCaptureTextAreaIdentifier = "ax.idea-capture-textarea"

    static let methodSelectorIdentifier = "ax.method-selector"
    static let methodSelectorDismissIdentifier = "ax.method-selector.dismiss"
    static func methodCardIdentifier(for methodId: String) -> String {
        "ax.method-card.\(methodId)"
    }

    static let runCompletionIdentifier = "ax.run-completion"
    static let ideaDetailRunMethodIdentifier = "ax.idea-detail.run-method"
    static let ideaQueueFirstRowIdentifier = "ax.idea-queue-first"

    static func projectCardIdentifier(for project: Project) -> String {
        "ax.project-card.\(slug(for: project))"
    }

    /// Identifier for the clickable project title in the dock card (navigation trigger).
    static func projectDetailsIdentifier(for project: Project) -> String {
        "ax.project-details.\(slug(for: project))"
    }

    /// Identifier for the project detail view (destination screen).
    static func projectDetailViewIdentifier(for project: Project) -> String {
        "ax.project-detail-view.\(slug(for: project))"
    }

    static func slug(for project: Project) -> String {
        let candidate = URL(fileURLWithPath: project.path).lastPathComponent
        let source = candidate.isEmpty ? project.name : candidate

        let slug = source
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        return slug.isEmpty ? "project" : slug
    }
}
