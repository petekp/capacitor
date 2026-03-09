import Foundation

@MainActor
final class LiveActivationGateway: ActivationGateway {
    private let shellProjectActivator: any ShellProjectActivating

    init() {
        shellProjectActivator = ShellActivationExecutor()
    }

    init(shellProjectActivator: any ShellProjectActivating) {
        self.shellProjectActivator = shellProjectActivator
    }

    func activate(_ request: ShellActivationRequest) async throws -> ShellActivationDecision {
        shellProjectActivator.activate(request.project)

        return ShellActivationDecision(
            disposition: .launched,
            project: request.project,
            reason: "Delegated to shell activation executor",
        )
    }
}
