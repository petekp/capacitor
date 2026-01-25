import Foundation

enum QuickFeedbackFunnelPayloadBuilder {
    static func opened(
        sessionID: String,
        preferences: QuickFeedbackPreferences,
    ) -> [String: Any] {
        basePayload(
            sessionID: sessionID,
            draft: .defaults,
            preferences: preferences,
            completionCount: 0,
        )
    }

    static func fieldCompleted(
        sessionID: String,
        field: String,
        draft: QuickFeedbackDraft,
        preferences: QuickFeedbackPreferences,
        completionCount: Int,
    ) -> [String: Any] {
        var payload = basePayload(
            sessionID: sessionID,
            draft: draft,
            preferences: preferences,
            completionCount: completionCount,
        )
        payload["field"] = field
        return payload
    }

    static func submitAttempt(
        sessionID: String,
        draft: QuickFeedbackDraft,
        preferences: QuickFeedbackPreferences,
    ) -> [String: Any] {
        basePayload(
            sessionID: sessionID,
            draft: draft,
            preferences: preferences,
            completionCount: draft.completionCount,
        )
    }

    static func submitResult(
        sessionID: String,
        feedbackID: String,
        draft: QuickFeedbackDraft,
        preferences: QuickFeedbackPreferences,
        issueRequested: Bool,
        issueOpened: Bool,
        endpointAttempted: Bool,
        endpointSucceeded: Bool,
    ) -> [String: Any] {
        var payload = basePayload(
            sessionID: sessionID,
            draft: draft,
            preferences: preferences,
            completionCount: draft.completionCount,
        )
        payload["feedback_id"] = feedbackID
        payload["issue_requested"] = issueRequested
        payload["issue_opened"] = issueOpened
        payload["endpoint_attempted"] = endpointAttempted
        payload["endpoint_succeeded"] = endpointSucceeded
        return payload
    }

    static func abandoned(
        sessionID: String,
        draft: QuickFeedbackDraft,
        preferences: QuickFeedbackPreferences,
        completionCount: Int,
    ) -> [String: Any] {
        basePayload(
            sessionID: sessionID,
            draft: draft,
            preferences: preferences,
            completionCount: completionCount,
        )
    }

    private static func basePayload(
        sessionID: String,
        draft: QuickFeedbackDraft,
        preferences: QuickFeedbackPreferences,
        completionCount: Int,
    ) -> [String: Any] {
        let normalized = draft.normalized()
        return [
            "form_session_id": sessionID,
            "category": normalized.category.rawValue,
            "impact": normalized.impact.rawValue,
            "reproducibility": normalized.reproducibility.rawValue,
            "summary_length": normalized.summaryLength,
            "completion_count": completionCount,
            "telemetry_enabled": preferences.includeTelemetry,
            "project_paths_enabled": preferences.includeProjectPaths,
        ]
    }
}

enum QuickFeedbackFunnel {
    static func makeSessionID() -> String {
        "qf-\(UUID().uuidString.lowercased())"
    }

    static func emitOpened(
        sessionID: String,
        preferences: QuickFeedbackPreferences,
    ) {
        Telemetry.emit(
            "quick_feedback_opened",
            "Quick feedback form opened",
            payload: QuickFeedbackFunnelPayloadBuilder.opened(sessionID: sessionID, preferences: preferences),
        )
    }

    static func emitFieldCompleted(
        sessionID: String,
        field: String,
        draft: QuickFeedbackDraft,
        preferences: QuickFeedbackPreferences,
        completionCount: Int,
    ) {
        Telemetry.emit(
            "quick_feedback_field_completed",
            "Quick feedback field completed",
            payload: QuickFeedbackFunnelPayloadBuilder.fieldCompleted(
                sessionID: sessionID,
                field: field,
                draft: draft,
                preferences: preferences,
                completionCount: completionCount,
            ),
        )
    }

    static func emitSubmitAttempt(
        sessionID: String,
        draft: QuickFeedbackDraft,
        preferences: QuickFeedbackPreferences,
    ) {
        Telemetry.emit(
            "quick_feedback_submit_attempt",
            "Quick feedback submit attempted",
            payload: QuickFeedbackFunnelPayloadBuilder.submitAttempt(
                sessionID: sessionID,
                draft: draft,
                preferences: preferences,
            ),
        )
    }

    static func emitSubmitResult(
        sessionID: String?,
        feedbackID: String,
        draft: QuickFeedbackDraft,
        preferences: QuickFeedbackPreferences,
        issueRequested: Bool,
        issueOpened: Bool,
        endpointAttempted: Bool,
        endpointSucceeded: Bool,
    ) {
        guard let sessionID else { return }
        let payload = QuickFeedbackFunnelPayloadBuilder.submitResult(
            sessionID: sessionID,
            feedbackID: feedbackID,
            draft: draft,
            preferences: preferences,
            issueRequested: issueRequested,
            issueOpened: issueOpened,
            endpointAttempted: endpointAttempted,
            endpointSucceeded: endpointSucceeded,
        )

        if issueOpened {
            Telemetry.emit(
                "quick_feedback_submit_success",
                "Quick feedback submitted",
                payload: payload,
            )
        } else {
            Telemetry.emit(
                "quick_feedback_submit_failure",
                "Quick feedback submission failed",
                payload: payload,
            )
        }
    }

    static func emitAbandoned(
        sessionID: String,
        draft: QuickFeedbackDraft,
        preferences: QuickFeedbackPreferences,
        completionCount: Int,
    ) {
        Telemetry.emit(
            "quick_feedback_abandoned",
            "Quick feedback form abandoned",
            payload: QuickFeedbackFunnelPayloadBuilder.abandoned(
                sessionID: sessionID,
                draft: draft,
                preferences: preferences,
                completionCount: completionCount,
            ),
        )
    }
}
