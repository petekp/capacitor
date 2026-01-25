extension HookDiagnosticReport {
    var shouldShowSetupCard: Bool {
        guard !isHealthy else { return false }
        if case .notFiring? = primaryIssue { return false }
        return true
    }

    var setupCardIsPolicyBlocked: Bool {
        if case .policyBlocked? = primaryIssue {
            return true
        }
        return false
    }

    var setupCardHeaderMessage: String {
        if isFirstRun {
            return "Let's get you set up"
        }

        switch primaryIssue {
        case .policyBlocked:
            return "Hooks disabled by policy"
        case .binaryMissing:
            return "Hook binary missing"
        case .binaryBroken:
            return "Hook binary failed to run"
        case .symlinkBroken:
            return "Hook link is broken"
        case .configMissing:
            return "Claude hooks not configured"
        case .notFiring:
            return "Hooks installed but not responding"
        case nil:
            return "Session tracking unavailable"
        }
    }

    var setupCardGuidanceMessage: String? {
        if isFirstRun {
            return "Install hooks, then run one Claude action to confirm shell integration."
        }

        guard let issue = primaryIssue else {
            return nil
        }

        switch issue {
        case let .policyBlocked(reason):
            return "\(reason) Remove this setting to enable session tracking."
        case .binaryMissing:
            return "Install hooks to place `hud-hook` at `~/.local/bin/hud-hook`."
        case let .binaryBroken(reason):
            return "Reinstall hooks, then retry Test Hooks. Details: \(reason)"
        case let .symlinkBroken(target, reason):
            return "Hook symlink target is unavailable (`\(target)`). Reinstall hooks. Details: \(reason)"
        case .configMissing:
            return "Install/update Claude hooks in `~/.claude/settings.json`."
        case let .notFiring(lastSeenSecs):
            if let lastSeenSecs {
                return "No recent hook heartbeat (last seen \(lastSeenSecs)s ago). Trigger a Claude event, then run Test Hooks."
            }
            return "No hook heartbeat detected yet. Start a Claude session and trigger one event, then run Test Hooks."
        }
    }
}
