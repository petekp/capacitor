import Foundation

struct WorkBatchGhosttySessionWaker {
    private let automationClient: GhosttyAutomationClient
    private let homeDirectory: String

    init(
        automationClient: GhosttyAutomationClient = DefaultGhosttyAutomationClient(
            appleScript: DefaultAppleScriptClient(),
        ),
        homeDirectory: String = NSHomeDirectory(),
    ) {
        self.automationClient = automationClient
        self.homeDirectory = homeDirectory
    }

    func wake(
        worktreePath: String,
        batchName: String?,
        prompt: String,
    ) -> Bool {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        guard case let .success(snapshot) = automationClient.readSnapshot(),
              let route = bestGhosttyRouteMatch(
                  snapshot: snapshot,
                  projectPath: worktreePath,
                  homeDirectory: homeDirectory,
                  tmuxSessionHint: batchName,
              ),
              let terminal = route.terminal
        else {
            return false
        }

        if let tab = route.tab,
           !tab.isSelected,
           case .failure = automationClient.selectTab(id: tab.id, inWindowID: route.window.id)
        {
            return false
        }

        if case .failure = automationClient.focusTerminal(id: terminal.id) {
            return false
        }

        if case .failure = automationClient.inputText(prompt, terminalID: terminal.id) {
            return false
        }

        if case .failure = automationClient.sendKey("enter", terminalID: terminal.id) {
            return false
        }

        return true
    }
}
