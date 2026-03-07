import Foundation

protocol FeedbackGateway {
    func submit(_ draft: ShellFeedbackDraft) async throws -> ShellFeedbackReceipt
}
