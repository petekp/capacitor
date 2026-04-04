import AppKit
import Foundation

extension AppState {
    func submitQuickFeedback(
        _ draft: QuickFeedbackDraft,
        preferences overridePreferences: QuickFeedbackPreferences? = nil,
        formSessionID: String? = nil,
        openGitHubIssue: Bool = true,
    ) {
        let normalizedDraft = draft.normalized()
        let preferences = overridePreferences ?? QuickFeedbackPreferences.load()
        let context = quickFeedbackContext()
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

        _Concurrency.Task { [weak self] in
            let outcome = await submitter.submit(
                draft: normalizedDraft,
                context: context,
                preferences: preferences,
                openGitHubIssue: openGitHubIssue,
            )

            await MainActor.run {
                guard let self else { return }

                if openGitHubIssue {
                    if outcome.issueOpened {
                        if outcome.endpointAttempted, outcome.endpointSucceeded {
                            self.uiState.toast = ToastMessage("Opened GitHub issue and sent telemetry")
                        } else if outcome.endpointAttempted {
                            self.uiState.toast = ToastMessage("Opened GitHub issue (endpoint send failed)")
                        } else {
                            self.uiState.toast = ToastMessage("Opened GitHub issue")
                        }
                    } else {
                        self.uiState.toast = .error("Couldn’t open GitHub issue")
                    }
                } else {
                    if outcome.endpointAttempted, outcome.endpointSucceeded {
                        self.uiState.toast = ToastMessage("Shared feedback")
                    } else if outcome.endpointAttempted {
                        self.uiState.toast = .error("Couldn’t share feedback")
                    } else {
                        self.uiState.toast = .error("Couldn’t share feedback (no endpoint configured)")
                    }
                }

                Telemetry.emit("quick_feedback_submitted", "Quick feedback submitted", payload: [
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

                QuickFeedbackFunnel.emitSubmitResult(
                    sessionID: formSessionID,
                    feedbackID: outcome.feedbackID,
                    draft: normalizedDraft,
                    preferences: preferences,
                    issueRequested: openGitHubIssue,
                    issueOpened: outcome.issueOpened,
                    endpointAttempted: outcome.endpointAttempted,
                    endpointSucceeded: outcome.endpointSucceeded,
                )
            }
        }
    }

    func quickFeedbackContext() -> QuickFeedbackContext {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "unknown"

        return QuickFeedbackContext(
            appVersion: appVersion,
            buildNumber: buildNumber,
            channel: featureState.channel,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            runtimeStatus: uiState.runtimeStatus,
            activeProjectPath: activeProjectPath,
            activeSource: String(describing: activeSource),
            projectCount: projectState.projects.count,
            sessionStates: sessionStateManager.sessionStates,
            activationTrace: uiState.activationTrace,
        )
    }
}
