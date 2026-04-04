import Foundation
import Observation

enum AppFeatureError: LocalizedError {
    case ideaCaptureDisabled
    case projectDetailsDisabled

    var errorDescription: String? {
        switch self {
        case .ideaCaptureDisabled:
            "Idea capture is disabled for this build."
        case .projectDetailsDisabled:
            "Project details are disabled for this build."
        }
    }
}

@Observable
@MainActor
final class FeatureState {
    private(set) var channel: AppChannel = AppConfig.defaultChannel
    private(set) var profile: AppProfile = .stable
    private(set) var featureFlags: FeatureFlags = .defaults(for: .stable)
    private(set) var routingRollout: RuntimeRoutingRollout?

    var isIdeaCaptureEnabled: Bool {
        featureFlags.ideaCapture
    }

    var isProjectDetailsEnabled: Bool {
        featureFlags.projectDetails
    }

    var isProjectCreationEnabled: Bool {
        featureFlags.projectCreation
    }

    var isLlmFeaturesEnabled: Bool {
        featureFlags.llmFeatures && isProjectDetailsEnabled
    }

    var isDelegationLoopEnabled: Bool {
        featureFlags.delegationLoop && isProjectDetailsEnabled
    }

    var isMethodRunnerEnabled: Bool {
        featureFlags.methodRunner && isProjectDetailsEnabled
    }

    var isWindowAnchoringEnabled: Bool {
        featureFlags.windowAnchoring
    }

    func configure(with config: AppConfig) {
        channel = config.channel
        profile = config.profile
        featureFlags = config.featureFlags
    }

    func refreshRoutingRollout(with health: RuntimeHealth?) {
        routingRollout = health?.routing?.rollout
    }
}
