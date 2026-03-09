import Foundation

typealias ShellPreferredTerminalApp = TerminalLauncher.SupportedTerminalApp

@MainActor
protocol ShellProjectActivating: AnyObject {
    var preferredTerminalAppResolver: ((String?, String, String?) -> ShellPreferredTerminalApp?)? { get set }
    var onActivationResult: ((TerminalActivationResult) -> Void)? { get set }
    func activate(_ project: ShellProjectReference)
}

@MainActor
final class ShellActivationExecutor: ShellProjectActivating {
    private let terminalLauncher: TerminalLauncher

    var preferredTerminalAppResolver: ((String?, String, String?) -> ShellPreferredTerminalApp?)? {
        get { terminalLauncher.preferredTerminalAppResolver }
        set { terminalLauncher.preferredTerminalAppResolver = newValue }
    }

    var onActivationResult: ((TerminalActivationResult) -> Void)? {
        get { terminalLauncher.onActivationResult }
        set { terminalLauncher.onActivationResult = newValue }
    }

    init() {
        terminalLauncher = TerminalLauncher()
    }

    init(terminalLauncher: TerminalLauncher) {
        self.terminalLauncher = terminalLauncher
    }

    func activate(_ project: ShellProjectReference) {
        terminalLauncher.launchTerminal(for: project)
    }

    static func resolvePreferredTerminalApp(
        clientTty: String?,
        projectPath: String,
        sessionName: String?,
        shellState: ShellCwdState,
    ) -> ShellPreferredTerminalApp? {
        TerminalLauncher.resolvePreferredTerminalApp(
            clientTty: clientTty,
            projectPath: projectPath,
            sessionName: sessionName,
            shellState: shellState,
        )
    }
}
