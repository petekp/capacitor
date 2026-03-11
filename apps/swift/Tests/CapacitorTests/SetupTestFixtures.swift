@testable import Capacitor

enum SetupTestFixtures {
    static let defaultClaudePath = "/opt/homebrew/bin/claude"

    static func claudeDependency(
        found: Bool,
        required: Bool = true,
        path: String = defaultClaudePath,
        installHint: String? = nil,
    ) -> DependencyStatus {
        DependencyStatus(
            name: "claude",
            required: required,
            found: found,
            path: found ? path : nil,
            installHint: installHint,
        )
    }

    static func setupStatus(
        dependencies: [DependencyStatus],
        hooks: HookStatus,
        storageReady: Bool = true,
        allReady: Bool = true,
        blockingReason: String? = nil,
    ) -> SetupStatus {
        SetupStatus(
            dependencies: dependencies,
            hooks: hooks,
            storageReady: storageReady,
            allReady: allReady,
            blockingReason: blockingReason,
        )
    }

    static func hookDiagnosticReport(
        primaryIssue: HookIssue?,
        isHealthy: Bool = false,
        canAutoFix: Bool = true,
        isFirstRun: Bool = false,
        binaryOk: Bool = true,
        configOk: Bool = false,
        firingOk: Bool = false,
        symlinkPath: String = "/tmp/hud-hook",
        symlinkTarget: String? = nil,
        lastHookEventAgeSecs: UInt64? = nil,
    ) -> HookDiagnosticReport {
        HookDiagnosticReport(
            isHealthy: isHealthy,
            primaryIssue: primaryIssue,
            canAutoFix: canAutoFix,
            isFirstRun: isFirstRun,
            binaryOk: binaryOk,
            configOk: configOk,
            firingOk: firingOk,
            symlinkPath: symlinkPath,
            symlinkTarget: symlinkTarget,
            lastHookEventAgeSecs: lastHookEventAgeSecs,
        )
    }
}
