import Foundation

enum TelemetryRoutingPolicy {
    private static let allowedIngestEventTypes: Set<String> = [
        "quick_feedback_opened",
        "quick_feedback_field_completed",
        "quick_feedback_submit_attempt",
        "quick_feedback_submit_success",
        "quick_feedback_submit_failure",
        "quick_feedback_abandoned",
        "quick_feedback_submitted",
        "activation_decision",
        "activation_outcome",
        "runtime_transport_error",
        "routing_snapshot_refresh_error",
    ]

    static func shouldSendEvent(type: String, endpoint: URL) -> Bool {
        guard isIngestFeedbackEndpoint(endpoint) else {
            return true
        }

        return allowedIngestEventTypes.contains(type)
    }

    private static func isIngestFeedbackEndpoint(_ endpoint: URL) -> Bool {
        let path = endpoint.path.lowercased()
        return path == "/v1/telemetry" || path == "/v1/telemetry/"
    }
}
