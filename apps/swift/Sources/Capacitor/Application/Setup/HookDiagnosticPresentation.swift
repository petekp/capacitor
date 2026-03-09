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
        HookPresentationPolicy.setupCardHeader(for: primaryIssue, isFirstRun: isFirstRun)
    }

    var setupCardGuidanceMessage: String? {
        HookPresentationPolicy.setupCardGuidance(for: primaryIssue, isFirstRun: isFirstRun)
    }
}
