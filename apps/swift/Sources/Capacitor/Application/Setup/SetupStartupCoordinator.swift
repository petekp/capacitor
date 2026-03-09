import Foundation

struct SetupLaunchOutcome: Equatable {
    let shouldShowWelcome: Bool
    let startupEvents: [DebugLog.StartupEvent]
}

protocol SetupShellIntegrationInstalling {
    var shellType: ShellType { get }
    var isSnippetInstalled: Bool { get }
    func installSnippet() -> Result<Void, ShellInstallError>
}

struct LiveSetupShellIntegrationInstaller: SetupShellIntegrationInstalling {
    let shellType: ShellType

    init(shellType: ShellType = .current) {
        self.shellType = shellType
    }

    var isSnippetInstalled: Bool {
        shellType.isSnippetInstalled
    }

    func installSnippet() -> Result<Void, ShellInstallError> {
        shellType.installSnippet()
    }
}

struct SetupStartupCoordinator {
    private let setupGateway: any SetupGateway
    private let shellIntegrationInstaller: any SetupShellIntegrationInstalling

    init(
        setupGateway: any SetupGateway,
        shellIntegrationInstaller: any SetupShellIntegrationInstalling = LiveSetupShellIntegrationInstaller(),
    ) {
        self.setupGateway = setupGateway
        self.shellIntegrationInstaller = shellIntegrationInstaller
    }

    func resolveLaunch() -> SetupLaunchOutcome? {
        let startupDecision: StartupSetupDecision
        do {
            startupDecision = try setupGateway.fetchStartupDecision()
        } catch {
            return nil
        }

        switch startupDecision {
        case .ready:
            return readyOutcome(startupEvents: [])
        case let .showWelcome(event):
            return SetupLaunchOutcome(shouldShowWelcome: true, startupEvents: [event])
        case let .attemptHookRepair(event):
            if let error = setupGateway.attemptHookAutoRepair() {
                return SetupLaunchOutcome(
                    shouldShowWelcome: true,
                    startupEvents: [
                        event,
                        .hooksAutoRepairFailed(error: error),
                    ],
                )
            }

            return readyOutcome(
                startupEvents: [
                    event,
                    .hooksAutoRepairSucceeded,
                ],
            )
        }
    }

    private func readyOutcome(startupEvents: [DebugLog.StartupEvent]) -> SetupLaunchOutcome {
        var events = startupEvents
        let shellType = shellIntegrationInstaller.shellType

        if shellType != .unsupported, !shellIntegrationInstaller.isSnippetInstalled {
            switch shellIntegrationInstaller.installSnippet() {
            case .success:
                events.append(.shellIntegrationInstalled(configFile: shellType.configFile))
            case let .failure(error):
                events.append(.shellIntegrationSkipped(reason: error.localizedDescription))
            }
        }

        return SetupLaunchOutcome(
            shouldShowWelcome: false,
            startupEvents: events,
        )
    }
}
