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
        let project = Project(
            name: request.project.displayName,
            path: request.project.path,
            displayPath: request.project.path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )

        terminalLauncher.launchTerminal(for: project)

        return ShellActivationDecision(
            disposition: .launched,
            project: request.project,
            reason: "Delegated to TerminalLauncher",
        )
    }
}
