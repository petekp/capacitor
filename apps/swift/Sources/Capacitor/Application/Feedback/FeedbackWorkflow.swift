import Foundation

@MainActor
final class FeedbackWorkflow {
    private let feedbackGateway: any FeedbackGateway

    var draft: ShellFeedbackDraft = .empty
    private(set) var receipt: ShellFeedbackReceipt?
    private(set) var lastError: Error?

    init(feedbackGateway: any FeedbackGateway) {
        self.feedbackGateway = feedbackGateway
    }

    func submit() async {
        do {
            receipt = try await feedbackGateway.submit(draft)
            lastError = nil
        } catch {
            lastError = error
        }
    }
}
