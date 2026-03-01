import Foundation
import os.log

/// Lightweight telemetry emitter for local debug or remote ingest endpoints.
enum Telemetry {
    private static let logger = Logger(subsystem: "com.capacitor.app", category: "Telemetry")
    private static let throttleLock = NSLock()
    private static var recentIngestDiagnosticsBySignature: [String: Date] = [:]
    private static let ingestDiagnosticsThrottleWindowSeconds: TimeInterval = 2
    private static let throttledIngestDiagnosticsEventTypes: Set<String> = [
        "activation_decision",
        "activation_outcome",
        "runtime_transport_error",
        "routing_snapshot_refresh_error",
    ]
    private struct Config {
        let endpoint: URL?
        let redactPaths: Bool
        let ingestKey: String?
    }

    private static let config: Config = {
        let env = ProcessInfo.processInfo.environment
        if env["CAPACITOR_TELEMETRY_DISABLED"] == "1" {
            return Config(endpoint: nil, redactPaths: false, ingestKey: nil)
        }
        let rawURL = env["CAPACITOR_TELEMETRY_URL"] ?? "http://localhost:9133/telemetry"
        let endpoint = URL(string: rawURL)
        let ingestKey = env["CAPACITOR_INGEST_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIngestKey = ingestKey?.isEmpty == true ? nil : ingestKey
        let redactPaths = endpoint.map { TelemetryRedaction.shouldRedactPaths(environment: env, endpoint: $0) } ?? false
        return Config(endpoint: endpoint, redactPaths: redactPaths, ingestKey: normalizedIngestKey)
    }()

    static func emit(_ type: String, _ message: String, payload: [String: Any] = [:]) {
        guard let url = config.endpoint else { return }
        guard TelemetryRoutingPolicy.shouldSendEvent(type: type, endpoint: url) else {
            logger.debug("Telemetry event dropped by routing policy for type=\(type, privacy: .public)")
            return
        }
        let sanitizedMessage = config.redactPaths ? TelemetryRedaction.redactMessage(message) : message
        let sanitizedPayload = config.redactPaths ? TelemetryRedaction.redactPayload(payload) : payload
        if shouldDropDuplicateIngestDiagnosticsEvent(type: type, message: sanitizedMessage, endpoint: url) {
            logger.debug("Telemetry event duplicate-throttled for type=\(type, privacy: .public)")
            return
        }

        var body: [String: Any] = [
            "type": type,
            "message": sanitizedMessage,
            "timestamp": currentISO8601Timestamp(),
        ]
        if !sanitizedPayload.isEmpty {
            body["payload"] = sanitizedPayload
        }
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [])
        else {
            logger.debug("Telemetry payload not JSON encodable for type=\(type, privacy: .public)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ingestKey = config.ingestKey {
            request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    private static func shouldDropDuplicateIngestDiagnosticsEvent(type: String, message: String, endpoint: URL) -> Bool {
        let normalizedPath = endpoint.path.lowercased()
        guard normalizedPath == "/v1/telemetry" || normalizedPath == "/v1/telemetry/" else {
            return false
        }
        guard throttledIngestDiagnosticsEventTypes.contains(type) else {
            return false
        }

        let now = Date()
        let signature = "\(type)|\(message)"
        throttleLock.lock()
        defer { throttleLock.unlock() }

        recentIngestDiagnosticsBySignature = recentIngestDiagnosticsBySignature.filter { _, lastSeen in
            now.timeIntervalSince(lastSeen) <= ingestDiagnosticsThrottleWindowSeconds
        }
        if let lastSeen = recentIngestDiagnosticsBySignature[signature],
           now.timeIntervalSince(lastSeen) < ingestDiagnosticsThrottleWindowSeconds
        {
            return true
        }
        recentIngestDiagnosticsBySignature[signature] = now
        return false
    }
}
