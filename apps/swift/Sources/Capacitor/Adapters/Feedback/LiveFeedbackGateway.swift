import Foundation

struct LiveFeedbackGateway: FeedbackGateway {
    func submit(_ draft: ShellFeedbackDraft) async throws -> ShellFeedbackReceipt {
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = summary.isEmpty ? "Shell scaffold only" : "Shell scaffold only: \(summary)"
        return ShellFeedbackReceipt(
            feedbackID: UUID().uuidString.lowercased(),
            status: .deferred,
            note: note,
        )
    }
}
