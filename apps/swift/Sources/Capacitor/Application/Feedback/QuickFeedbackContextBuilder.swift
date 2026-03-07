import Foundation

@MainActor
enum QuickFeedbackContextBuilder {
    static func make(
        channel: AppChannel,
        runtimeStatus: RuntimeStatus?,
        activeProjectPath: String?,
        activeSource: ActiveSource,
        projectCount: Int,
        sessionStates: [String: ProjectSessionState],
        activationTrace: String?,
    ) -> QuickFeedbackContext {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "unknown"

        return QuickFeedbackContext(
            appVersion: appVersion,
            buildNumber: buildNumber,
            channel: channel,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            runtimeStatus: runtimeStatus,
            activeProjectPath: activeProjectPath,
            activeSource: String(describing: activeSource),
            projectCount: projectCount,
            sessionStates: sessionStates,
            activationTrace: activationTrace,
        )
    }
}
