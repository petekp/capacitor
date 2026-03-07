import Foundation

struct SetupLaunchOutcome: Equatable {
    let shouldShowWelcome: Bool
    let startupEvents: [DebugLog.StartupEvent]
}

struct SetupStartupCoordinator {
    private let setupGateway: any SetupGateway

    init(setupGateway: any SetupGateway) {
        self.setupGateway = setupGateway
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
            return SetupLaunchOutcome(shouldShowWelcome: false, startupEvents: [])
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

            return SetupLaunchOutcome(
                shouldShowWelcome: false,
                startupEvents: [
                    event,
                    .hooksAutoRepairSucceeded,
                ],
            )
        }
    }
}
