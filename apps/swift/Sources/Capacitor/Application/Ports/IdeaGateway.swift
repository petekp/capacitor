import Foundation

protocol IdeaGateway {
    func capture(_ draft: ShellIdeaDraft) async throws -> ShellIdeaDraft
    func loadIdeas(for project: ShellProjectReference) async throws -> [ShellIdeaDraft]
}
