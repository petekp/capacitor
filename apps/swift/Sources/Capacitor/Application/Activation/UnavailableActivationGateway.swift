import Foundation

struct UnavailableActivationGateway: ActivationGateway {
    func activate(_ request: ShellActivationRequest) async throws -> ShellActivationDecision {
        ShellActivationDecision(
            disposition: .unavailable,
            project: request.project,
            reason: "Activation gateway not composed",
        )
    }
}
