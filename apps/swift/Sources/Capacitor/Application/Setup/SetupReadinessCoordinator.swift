enum StartupSetupDecision: Equatable {
    case ready
    case showWelcome(event: DebugLog.StartupEvent)
    case attemptHookRepair(event: DebugLog.StartupEvent)
}

enum SetupReadinessCoordinator {
    static func startupDecision(from setupStatus: SetupStatus) -> StartupSetupDecision {
        if isRequiredDependencyMissing(named: "claude", in: setupStatus.dependencies) {
            return .showWelcome(event: .claudeMissing)
        }

        switch setupStatus.hooks {
        case .installed:
            return .ready
        case let .policyBlocked(reason):
            return .showWelcome(event: .hooksBlockedByPolicy(reason: reason))
        case .notInstalled, .binaryBroken, .symlinkBroken:
            return .attemptHookRepair(event: .hooksNeedAutoRepair(status: setupStatus.hooks))
        }
    }

    private static func isRequiredDependencyMissing(named dependencyName: String, in dependencies: [DependencyStatus]) -> Bool {
        dependencies.contains { dep in
            dep.name == dependencyName && dep.required && !dep.found
        }
    }
}
