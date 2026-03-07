import AppKit
import Foundation

@MainActor
final class QuickFeedbackWorkflow {
    typealias SubmitFeedback = (
        _ draft: QuickFeedbackDraft,
        _ context: QuickFeedbackContext,
        _ preferences: QuickFeedbackPreferences,
        _ openGitHubIssue: Bool,
    ) async -> QuickFeedbackSubmissionOutcome

    typealias ContextProvider = () -> QuickFeedbackContext
    typealias ToastWriter = (ToastMessage) -> Void
    typealias TelemetryEmitter = (_ event: String, _ message: String, _ payload: [String: Any]) -> Void
    typealias FunnelEmitter = (
        _ sessionID: String?,
        _ feedbackID: String,
        _ draft: QuickFeedbackDraft,
        _ preferences: QuickFeedbackPreferences,
        _ issueRequested: Bool,
        _ issueOpened: Bool,
        _ endpointAttempted: Bool,
        _ endpointSucceeded: Bool,
    ) -> Void

    private let submitFeedback: SubmitFeedback
    private let contextProvider: ContextProvider
    private let writeToast: ToastWriter
    private let emitTelemetry: TelemetryEmitter
    private let emitSubmitResult: FunnelEmitter

    init(
        submitFeedback: @escaping SubmitFeedback = QuickFeedbackWorkflow.liveSubmitFeedback,
        contextProvider: @escaping ContextProvider,
        writeToast: @escaping ToastWriter,
        emitTelemetry: @escaping TelemetryEmitter = { event, message, payload in
            Telemetry.emit(event, message, payload: payload)
        },
        emitSubmitResult: @escaping FunnelEmitter = { sessionID, feedbackID, draft, preferences, issueRequested, issueOpened, endpointAttempted, endpointSucceeded in
            QuickFeedbackFunnel.emitSubmitResult(
                sessionID: sessionID,
                feedbackID: feedbackID,
                draft: draft,
                preferences: preferences,
                issueRequested: issueRequested,
                issueOpened: issueOpened,
                endpointAttempted: endpointAttempted,
                endpointSucceeded: endpointSucceeded,
            )
        },
    ) {
        self.submitFeedback = submitFeedback
        self.contextProvider = contextProvider
        self.writeToast = writeToast
        self.emitTelemetry = emitTelemetry
        self.emitSubmitResult = emitSubmitResult
    }

    func submit(
        _ draft: QuickFeedbackDraft,
        preferences overridePreferences: QuickFeedbackPreferences? = nil,
        formSessionID: String? = nil,
        openGitHubIssue: Bool = true,
    ) {
        let normalizedDraft = draft.normalized()
        let preferences = overridePreferences ?? QuickFeedbackPreferences.load()
        let context = contextProvider()

        _Concurrency.Task { [submitFeedback, writeToast, emitTelemetry, emitSubmitResult] in
            let outcome = await submitFeedback(
                normalizedDraft,
                context,
                preferences,
                openGitHubIssue,
            )

            await MainActor.run {
                if openGitHubIssue {
                    if outcome.issueOpened {
                        if outcome.endpointAttempted, outcome.endpointSucceeded {
                            writeToast(ToastMessage("Opened GitHub issue and sent telemetry"))
                        } else if outcome.endpointAttempted {
                            writeToast(ToastMessage("Opened GitHub issue (endpoint send failed)"))
                        } else {
                            writeToast(ToastMessage("Opened GitHub issue"))
                        }
                    } else {
                        writeToast(.error("Couldn’t open GitHub issue"))
                    }
                } else {
                    if outcome.endpointAttempted, outcome.endpointSucceeded {
                        writeToast(ToastMessage("Shared feedback"))
                    } else if outcome.endpointAttempted {
                        writeToast(.error("Couldn’t share feedback"))
                    } else {
                        writeToast(.error("Couldn’t share feedback (no endpoint configured)"))
                    }
                }

                emitTelemetry("quick_feedback_submitted", "Quick feedback submitted", [
                    "feedback_id": outcome.feedbackID,
                    "issue_requested": openGitHubIssue,
                    "issue_opened": outcome.issueOpened,
                    "endpoint_attempted": outcome.endpointAttempted,
                    "endpoint_succeeded": outcome.endpointSucceeded,
                    "category": normalizedDraft.category.rawValue,
                    "impact": normalizedDraft.impact.rawValue,
                    "reproducibility": normalizedDraft.reproducibility.rawValue,
                    "completion_count": normalizedDraft.completionCount,
                    "telemetry_enabled": preferences.includeTelemetry,
                    "project_paths_enabled": preferences.includeProjectPaths,
                    "session_count": context.sessionStates.count,
                    "project_count": context.projectCount,
                    "active_source": context.activeSource,
                ])

                emitSubmitResult(
                    formSessionID,
                    outcome.feedbackID,
                    normalizedDraft,
                    preferences,
                    openGitHubIssue,
                    outcome.issueOpened,
                    outcome.endpointAttempted,
                    outcome.endpointSucceeded,
                )
            }
        }
    }

    private static func liveSubmitFeedback(
        draft: QuickFeedbackDraft,
        context: QuickFeedbackContext,
        preferences: QuickFeedbackPreferences,
        openGitHubIssue: Bool,
    ) async -> QuickFeedbackSubmissionOutcome {
        let submitter = QuickFeedbackSubmitter(
            openURL: { url in
                NSWorkspace.shared.open(url)
            },
            sendRequest: { request in
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(httpResponse.statusCode)
                {
                    throw URLError(.badServerResponse)
                }
            },
        )

        return await submitter.submit(
            draft: draft,
            context: context,
            preferences: preferences,
            openGitHubIssue: openGitHubIssue,
        )
    }
}
