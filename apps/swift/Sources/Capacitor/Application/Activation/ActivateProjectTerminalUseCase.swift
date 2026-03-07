import Foundation

struct ActivateProjectTerminalUseCase {
    private let activationGateway: any ActivationGateway

    init(activationGateway: any ActivationGateway) {
        self.activationGateway = activationGateway
    }

    func execute(
        project: ShellProjectReference,
        preferredSessionName: String? = nil,
        source: String = "swiftui",
    ) async throws -> ShellActivationDecision {
        try await activationGateway.activate(
            ShellActivationRequest(
                project: project,
                preferredSessionName: preferredSessionName,
                source: source,
            ),
        )
    }
}
