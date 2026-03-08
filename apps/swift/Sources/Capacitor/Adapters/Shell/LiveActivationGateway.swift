import Foundation

@MainActor
final class LiveActivationGateway: ActivationGateway {
    private let terminalLauncher: TerminalLauncher

    init() {
        terminalLauncher = TerminalLauncher()
    }

    init(terminalLauncher: TerminalLauncher) {
        self.terminalLauncher = terminalLauncher
    }

    func activate(_ request: ShellActivationRequest) async throws -> ShellActivationDecision {
        terminalLauncher.launchTerminal(for: request.project)

        return ShellActivationDecision(
            disposition: .launched,
            project: request.project,
            reason: "Delegated to TerminalLauncher",
        )
    }
}
