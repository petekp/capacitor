import Foundation

enum ActivationPolicyFallback {
    static func defaultTerminalApp() -> SupportedTerminalApp {
        SupportedTerminalApp.detectAvailable()
    }
}

enum ActivationPolicyTerminalAppSource: Equatable {
    case runtimeRoute
    case shellEvidence
    case fallback
}

struct ActivationPolicyTerminalAppDecision: Equatable {
    let app: SupportedTerminalApp
    let source: ActivationPolicyTerminalAppSource
}

struct ActivationPolicyIntent: Equatable {
    let terminalApp: ActivationPolicyTerminalAppDecision
    let sessionName: String?
    let hostTty: String?
    let paneId: String?
}

@MainActor
struct ActivationPolicy {
    func resolveIntent(
        projectPath: String,
        clientTty: String?,
        sessionName: String?,
        route: RuntimeRoutingView?,
        shellState: ShellCwdState?,
        fallbackTerminalApp: () -> SupportedTerminalApp = { ActivationPolicyFallback.defaultTerminalApp() },
    ) -> ActivationPolicyIntent {
        let resolvedSessionName = normalized(sessionName) ?? resolvePreferredSessionName(route: route)
        let hostTty = resolvePreferredHostTty(route: route, sessionName: resolvedSessionName)
        let paneId = resolvePreferredTmuxPane(
            clientTty: clientTty,
            projectPath: projectPath,
            sessionName: resolvedSessionName,
            route: route,
            shellState: shellState,
        )

        if let app = resolveRoutedTerminalApp(route: route) {
            return ActivationPolicyIntent(
                terminalApp: ActivationPolicyTerminalAppDecision(app: app, source: .runtimeRoute),
                sessionName: resolvedSessionName,
                hostTty: hostTty,
                paneId: paneId,
            )
        }

        if let shellState,
           let app = preferredTerminalAppFromShellState(
               clientTty: clientTty,
               projectPath: projectPath,
               sessionName: resolvedSessionName,
               shellState: shellState,
           )
        {
            return ActivationPolicyIntent(
                terminalApp: ActivationPolicyTerminalAppDecision(app: app, source: .shellEvidence),
                sessionName: resolvedSessionName,
                hostTty: hostTty,
                paneId: paneId,
            )
        }

        return ActivationPolicyIntent(
            terminalApp: ActivationPolicyTerminalAppDecision(app: fallbackTerminalApp(), source: .fallback),
            sessionName: resolvedSessionName,
            hostTty: hostTty,
            paneId: paneId,
        )
    }

    private func resolvePreferredSessionName(route: RuntimeRoutingView?) -> String? {
        guard let route else {
            return nil
        }

        guard route.target.kind == "tmux_session" || route.target.kind == "tmux_pane" else {
            return nil
        }

        return normalized(route.target.sessionName)
    }

    private func resolvePreferredHostTty(route: RuntimeRoutingView?, sessionName: String?) -> String? {
        guard let route else {
            return nil
        }

        let resolvedSessionName = normalized(sessionName)
        guard resolvedSessionName == nil || normalized(route.target.sessionName) == resolvedSessionName else {
            return nil
        }

        return normalized(route.target.hostTty)
    }

    private func resolvePreferredTmuxPane(
        clientTty: String?,
        projectPath: String,
        sessionName: String?,
        route: RuntimeRoutingView?,
        shellState: ShellCwdState?,
    ) -> String? {
        let resolvedSessionName = normalized(sessionName)

        if let route,
           route.target.kind == "tmux_pane",
           let paneId = normalized(route.target.paneId),
           resolvedSessionName == nil || normalized(route.target.sessionName) == resolvedSessionName
        {
            return paneId
        }

        guard let shellState else {
            return nil
        }

        return preferredTmuxPaneFromShellState(
            clientTty: clientTty,
            projectPath: projectPath,
            sessionName: resolvedSessionName,
            shellState: shellState,
        )
    }

    private func resolveRoutedTerminalApp(route: RuntimeRoutingView?) -> SupportedTerminalApp? {
        SupportedTerminalApp.from(parentApp: route?.target.terminalApp)
    }

    private func preferredTerminalAppFromShellState(
        clientTty: String?,
        projectPath: String,
        sessionName: String?,
        shellState: ShellCwdState,
    ) -> SupportedTerminalApp? {
        let normalizedProjectPath = PathNormalizer.normalize(projectPath)
        let normalizedClientTty = normalized(clientTty)
        let normalizedSessionName = normalized(sessionName)

        var bestMatch: (rank: Int, updatedAt: Date, app: SupportedTerminalApp)?

        for entry in shellState.shells.values {
            guard let app = SupportedTerminalApp.from(parentApp: entry.parentApp) else {
                continue
            }

            let projectPathMatches = PathNormalizer.normalize(entry.cwd) == normalizedProjectPath
            let sessionMatches = if let normalizedSessionName {
                entry.tmuxSession == normalizedSessionName
            } else {
                false
            }

            let rank: Int? = if let normalizedClientTty, entry.tmuxClientTty == normalizedClientTty {
                4
            } else if let normalizedClientTty, entry.tty == normalizedClientTty {
                3
            } else if normalizedClientTty == nil, projectPathMatches, sessionMatches {
                3
            } else if normalizedClientTty == nil, projectPathMatches {
                2
            } else if sessionMatches {
                normalizedClientTty == nil ? 1 : 2
            } else if projectPathMatches {
                1
            } else {
                nil
            }

            guard let rank else { continue }

            if let currentBest = bestMatch {
                if rank < currentBest.rank {
                    continue
                }
                if rank == currentBest.rank, entry.updatedAt <= currentBest.updatedAt {
                    continue
                }
            }

            bestMatch = (rank, entry.updatedAt, app)
        }

        return bestMatch?.app
    }

    private func preferredTmuxPaneFromShellState(
        clientTty: String?,
        projectPath: String,
        sessionName: String?,
        shellState: ShellCwdState,
    ) -> String? {
        let normalizedProjectPath = PathNormalizer.normalize(projectPath)
        let normalizedClientTty = normalized(clientTty)
        let normalizedSessionName = normalized(sessionName)

        var bestMatch: (rank: Int, updatedAt: Date, pane: String)?

        for entry in shellState.shells.values {
            guard let pane = normalized(entry.tmuxPane) else {
                continue
            }

            let normalizedEntryPath = PathNormalizer.normalize(entry.cwd)

            let rank: Int? = if let normalizedClientTty,
                                entry.tmuxClientTty == normalizedClientTty,
                                let normalizedSessionName,
                                entry.tmuxSession == normalizedSessionName,
                                normalizedEntryPath == normalizedProjectPath
            {
                4
            } else if let normalizedSessionName,
                      entry.tmuxSession == normalizedSessionName,
                      normalizedEntryPath == normalizedProjectPath
            {
                3
            } else if let normalizedClientTty, entry.tmuxClientTty == normalizedClientTty {
                2
            } else if normalizedEntryPath == normalizedProjectPath {
                1
            } else {
                nil
            }

            guard let rank else { continue }

            if let currentBest = bestMatch {
                if rank < currentBest.rank {
                    continue
                }
                if rank == currentBest.rank, entry.updatedAt <= currentBest.updatedAt {
                    continue
                }
            }

            bestMatch = (rank, entry.updatedAt, pane)
        }

        return bestMatch?.pane
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }

        return value
    }
}
