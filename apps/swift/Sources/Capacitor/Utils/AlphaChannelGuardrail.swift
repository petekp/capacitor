import Darwin
import Foundation

enum AlphaChannelGuardrail {
    static let canonicalRestartCommand = "./scripts/dev/restart-current.sh"

    static func violationMessage(
        channel: AppChannel,
        environment: [String: String],
        isDebugBuild: Bool = _isDebugAssertConfiguration(),
    ) -> String? {
        guard isDebugBuild else { return nil }
        guard channel != .alpha else { return nil }
        guard environment["CAPACITOR_ALLOW_NON_ALPHA"] != "1" else { return nil }

        return """
        Capacitor blocked startup because resolved channel was '\(channel.rawValue)' but DEBUG workflows are alpha-only.
        Expected channel: alpha
        Canonical restart: \(canonicalRestartCommand)
        Intentional override: CAPACITOR_ALLOW_NON_ALPHA=1 ./scripts/dev/restart-app.sh --channel \(channel.rawValue) --profile stable
        """
    }

    static func enforceOrExit(
        channel: AppChannel,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) {
        guard let message = violationMessage(channel: channel, environment: environment) else { return }
        let rendered = "ERROR: \(message)"
        DebugLog.write(rendered.replacingOccurrences(of: "\n", with: " | "))
        fputs("\(rendered)\n", stderr)
        fflush(stderr)
        Darwin.exit(78)
    }
}
