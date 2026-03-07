import Foundation

@MainActor
final class IdeaCaptureWorkflow {
    private let ideaGateway: any IdeaGateway

    var draft: ShellIdeaDraft = .empty
    private(set) var ideas: [ShellIdeaDraft] = []
    private(set) var lastError: Error?

    init(ideaGateway: any IdeaGateway) {
        self.ideaGateway = ideaGateway
    }

    func captureDraft() async {
        do {
            let captured = try await ideaGateway.capture(draft)
            ideas.insert(captured, at: 0)
            draft = .empty
            lastError = nil
        } catch {
            lastError = error
        }
    }

    func loadIdeas(for project: ShellProjectReference) async {
        do {
            ideas = try await ideaGateway.loadIdeas(for: project)
            lastError = nil
        } catch {
            lastError = error
        }
    }
}
