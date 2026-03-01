enum StartupSetupDecision: Equatable {
    case ready
    case showWelcome(logMessage: String)
    case attemptHookRepair(logMessage: String)
}

enum SetupReadinessCoordinator {
    static func startupDecision(from setupStatus: SetupStatus) -> StartupSetupDecision {
        if isRequiredDependencyMissing(named: "claude", in: setupStatus.dependencies) {
            return .showWelcome(logMessage: "[Startup] Claude CLI not found, showing WelcomeView")
        }

        switch setupStatus.hooks {
        case .installed:
            return .ready
        case let .policyBlocked(reason):
            return .showWelcome(logMessage: "[Startup] \(HookPresentationPolicy.startupPolicyBlockedMessage(reason: reason))")
        case .notInstalled, .binaryBroken, .symlinkBroken:
            return .attemptHookRepair(logMessage: "[Startup] \(HookPresentationPolicy.startupNeedsRepairMessage(for: setupStatus.hooks))")
        }
    }

    private static func isRequiredDependencyMissing(named dependencyName: String, in dependencies: [DependencyStatus]) -> Bool {
        dependencies.contains { dep in
            dep.name == dependencyName && dep.required && !dep.found
        }
    }
}
