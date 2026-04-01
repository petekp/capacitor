import Foundation

enum ActivationPolicyFallback {
    static func defaultTerminalApp() -> SupportedTerminalApp {
        SupportedTerminalApp.detectAvailable()
    }
}

enum ActivationPolicyTerminalAppSource: Equatable {
    case runtimeRoute
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
        projectPath _: String,
        clientTty _: String?,
        sessionName: String?,
        route: RuntimeRoutingView?,
        fallbackTerminalApp: () -> SupportedTerminalApp = { ActivationPolicyFallback.defaultTerminalApp() },
    ) -> ActivationPolicyIntent {
        let resolvedSessionName = normalized(sessionName) ?? resolvePreferredSessionName(route: route)
        let hostTty = resolvePreferredHostTty(route: route)
        let paneId = resolvePreferredTmuxPane(route: route)

        if let app = resolveRoutedTerminalApp(route: route) {
            return ActivationPolicyIntent(
                terminalApp: ActivationPolicyTerminalAppDecision(app: app, source: .runtimeRoute),
                sessionName: resolvedSessionName,
                hostTty: hostTty,
                paneId: paneId,
            )
        }

        if routeRequiresRuntimeTerminalApp(route: route) {
            return ActivationPolicyIntent(
                terminalApp: ActivationPolicyTerminalAppDecision(app: fallbackTerminalApp(), source: .fallback),
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

    private func resolvePreferredHostTty(route: RuntimeRoutingView?) -> String? {
        normalized(route?.target.hostTty)
    }

    private func resolvePreferredTmuxPane(route: RuntimeRoutingView?) -> String? {
        if let route,
           route.target.kind == "tmux_pane",
           let paneId = normalized(route.target.paneId)
        {
            return paneId
        }

        return nil
    }

    private func resolveRoutedTerminalApp(route: RuntimeRoutingView?) -> SupportedTerminalApp? {
        SupportedTerminalApp.from(parentApp: route?.target.terminalApp)
    }

    private func routeRequiresRuntimeTerminalApp(route: RuntimeRoutingView?) -> Bool {
        guard let route, route.status == "attached" else {
            return false
        }

        return route.target.kind == "tmux_pane" || route.target.kind == "tmux_session"
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
