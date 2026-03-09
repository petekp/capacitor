import CryptoKit
import Foundation

enum QuickFeedbackPreferenceKeys {
    static let includeTelemetry = "quickFeedback.includeTelemetry"
    static let includeProjectPaths = "quickFeedback.includeProjectPaths"
}

struct QuickFeedbackPreferences: Equatable {
    var includeTelemetry: Bool
    var includeProjectPaths: Bool

    static let defaults = QuickFeedbackPreferences(
        includeTelemetry: true,
        includeProjectPaths: false,
    )

    static func load(from defaultsStore: UserDefaults = .standard) -> QuickFeedbackPreferences {
        let includeTelemetry = value(
            forKey: QuickFeedbackPreferenceKeys.includeTelemetry,
            defaultValue: defaults.includeTelemetry,
            store: defaultsStore,
        )
        let includeProjectPaths = value(
            forKey: QuickFeedbackPreferenceKeys.includeProjectPaths,
            defaultValue: defaults.includeProjectPaths,
            store: defaultsStore,
        )

        if !includeTelemetry {
            return QuickFeedbackPreferences(includeTelemetry: false, includeProjectPaths: false)
        }

        return QuickFeedbackPreferences(
            includeTelemetry: includeTelemetry,
            includeProjectPaths: includeProjectPaths,
        )
    }

    private static func value(forKey key: String, defaultValue: Bool, store: UserDefaults) -> Bool {
        guard store.object(forKey: key) != nil else {
            return defaultValue
        }
        return store.bool(forKey: key)
    }
}

enum QuickFeedbackCategory: String, Codable, CaseIterable {
    case bug
    case ux
    case feature
    case question
    case other

    var title: String {
        switch self {
        case .bug:
            "Bug report"
        case .ux:
            "UX friction"
        case .feature:
            "Feature request"
        case .question:
            "Question"
        case .other:
            "Other"
        }
    }
}

enum QuickFeedbackImpact: String, Codable, CaseIterable {
    case blocking
    case high
    case medium
    case low

    var title: String {
        switch self {
        case .blocking:
            "Blocking"
        case .high:
            "High"
        case .medium:
            "Medium"
        case .low:
            "Low"
        }
    }
}

enum QuickFeedbackReproducibility: String, Codable, CaseIterable {
    case always
    case often
    case sometimes
    case once
    case unsure
    case notApplicable = "not_applicable"

    var title: String {
        switch self {
        case .always:
            "Always"
        case .often:
            "Often"
        case .sometimes:
            "Sometimes"
        case .once:
            "Once"
        case .unsure:
            "Unsure"
        case .notApplicable:
            "Not applicable"
        }
    }
}

struct QuickFeedbackDraft: Equatable {
    var category: QuickFeedbackCategory
    var impact: QuickFeedbackImpact
    var reproducibility: QuickFeedbackReproducibility
    var summary: String
    var details: String
    var expectedBehavior: String
    var stepsToReproduce: String

    static let defaults = QuickFeedbackDraft(
        category: .other,
        impact: .medium,
        reproducibility: .notApplicable,
        summary: "",
        details: "",
        expectedBehavior: "",
        stepsToReproduce: "",
    )

    static func messageOnly(_ message: String) -> QuickFeedbackDraft {
        QuickFeedbackDraft(
            category: .other,
            impact: .medium,
            reproducibility: .notApplicable,
            summary: message,
            details: "",
            expectedBehavior: "",
            stepsToReproduce: "",
        )
    }

    var canSubmit: Bool {
        !normalized().summary.isEmpty
    }

    var completionCount: Int {
        let normalized = normalized()
        var count = 0
        if !normalized.summary.isEmpty { count += 1 }
        if !normalized.details.isEmpty { count += 1 }
        if !normalized.expectedBehavior.isEmpty { count += 1 }
        if !normalized.stepsToReproduce.isEmpty { count += 1 }
        return count
    }

    var hasAnyContent: Bool {
        completionCount > 0
    }

    var summaryLength: Int {
        normalized().summary.count
    }

    func normalized() -> QuickFeedbackDraft {
        QuickFeedbackDraft(
            category: category,
            impact: impact,
            reproducibility: reproducibility,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            expectedBehavior: expectedBehavior.trimmingCharacters(in: .whitespacesAndNewlines),
            stepsToReproduce: stepsToReproduce.trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }
}

struct QuickFeedbackContext: Equatable {
    let appVersion: String
    let buildNumber: String
    let channel: AppChannel
    let osVersion: String
    let runtimeStatus: RuntimeStatus?
    let activeProjectPath: String?
    let activeSource: String
    let projectCount: Int
    let sessionStates: [String: ProjectSessionState]
    let activationTrace: String?

    static let empty = QuickFeedbackContext(
        appVersion: "unknown",
        buildNumber: "unknown",
        channel: .prod,
        osVersion: "unknown",
        runtimeStatus: nil,
        activeProjectPath: nil,
        activeSource: "none",
        projectCount: 0,
        sessionStates: [:],
        activationTrace: nil,
    )
}

struct QuickFeedbackPayload: Codable, Equatable {
    struct AppSnapshot: Codable, Equatable {
        let version: String
        let buildNumber: String
        let channel: String
        let osVersion: String
    }

    struct PrivacySnapshot: Codable, Equatable {
        let includeTelemetry: Bool
        let includeProjectPaths: Bool
    }

    struct RuntimeSnapshot: Codable, Equatable {
        let enabled: Bool
        let healthy: Bool
        let message: String
        let pid: Int?
        let version: String?
    }

    struct SessionSummary: Codable, Equatable {
        let total: Int
        let working: Int
        let ready: Int
        let waiting: Int
        let compacting: Int
        let idle: Int
        let withAttachedSession: Int
        let thinking: Int
    }

    struct ProjectSessionSnapshot: Codable, Equatable {
        let path: String
        let state: String
        let hasSession: Bool
        let thinking: Bool
        let sessionIdPresent: Bool
        let updatedAt: String?
    }

    struct ProjectContext: Codable, Equatable {
        let activeProjectPath: String?
        let activeSource: String
        let projectCount: Int
        let sessionSummary: SessionSummary
        let projects: [ProjectSessionSnapshot]
        let omittedProjectCount: Int
    }

    struct ActivationSignal: Codable, Equatable {
        let hasTrace: Bool
        let traceDigest: String?
    }

    struct FormSnapshot: Codable, Equatable {
        let category: String
        let impact: String
        let reproducibility: String
        let summary: String
        let details: String?
        let expectedBehavior: String?
        let stepsToReproduce: String?
    }

    let feedbackID: String
    let feedback: String
    let form: FormSnapshot
    let submittedAt: String
    let app: AppSnapshot
    let privacy: PrivacySnapshot
    let runtime: RuntimeSnapshot?
    let projectContext: ProjectContext
    let activationSignal: ActivationSignal

    enum CodingKeys: String, CodingKey {
        case feedbackID = "feedback_id"
        case feedback
        case form
        case submittedAt
        case app
        case privacy
        case runtime
        case projectContext
        case activationSignal
    }
}

enum QuickFeedbackPayloadBuilder {
    private enum Constants {
        static let maxProjectSnapshots = 12
    }

    static func build(
        feedbackID: String,
        draft: QuickFeedbackDraft,
        context: QuickFeedbackContext,
        preferences: QuickFeedbackPreferences,
        now: Date = Date(),
    ) -> QuickFeedbackPayload {
        let normalizedDraft = draft.normalized()
        let sortedStates = context.sessionStates.sorted { $0.key < $1.key }

        var working = 0
        var ready = 0
        var waiting = 0
        var compacting = 0
        var idle = 0
        var withAttachedSession = 0
        var thinking = 0

        for (_, sessionState) in sortedStates {
            switch sessionState.state {
            case .working:
                working += 1
            case .ready:
                ready += 1
            case .waiting:
                waiting += 1
            case .compacting:
                compacting += 1
            case .idle:
                idle += 1
            }

            if sessionState.hasSession {
                withAttachedSession += 1
            }
            if sessionState.thinking == true {
                thinking += 1
            }
        }

        let projectSnapshots = sortedStates.prefix(Constants.maxProjectSnapshots).map { path, sessionState in
            QuickFeedbackPayload.ProjectSessionSnapshot(
                path: sanitizedPath(path, preferences: preferences),
                state: stateLabel(sessionState.state),
                hasSession: sessionState.hasSession,
                thinking: sessionState.thinking == true,
                sessionIdPresent: sessionState.sessionId != nil,
                updatedAt: sessionState.updatedAt,
            )
        }

        let runtime = context.runtimeStatus.map {
            QuickFeedbackPayload.RuntimeSnapshot(
                enabled: $0.isEnabled,
                healthy: $0.isHealthy,
                message: $0.message,
                pid: $0.pid,
                version: $0.version,
            )
        }

        let trace = context.activationTrace?.trimmingCharacters(in: .whitespacesAndNewlines)

        return QuickFeedbackPayload(
            feedbackID: feedbackID,
            feedback: normalizedDraft.summary,
            form: QuickFeedbackPayload.FormSnapshot(
                category: normalizedDraft.category.rawValue,
                impact: normalizedDraft.impact.rawValue,
                reproducibility: normalizedDraft.reproducibility.rawValue,
                summary: normalizedDraft.summary,
                details: optionalValue(normalizedDraft.details),
                expectedBehavior: optionalValue(normalizedDraft.expectedBehavior),
                stepsToReproduce: optionalValue(normalizedDraft.stepsToReproduce),
            ),
            submittedAt: formatISO8601Timestamp(now),
            app: QuickFeedbackPayload.AppSnapshot(
                version: context.appVersion,
                buildNumber: context.buildNumber,
                channel: context.channel.rawValue,
                osVersion: context.osVersion,
            ),
            privacy: QuickFeedbackPayload.PrivacySnapshot(
                includeTelemetry: preferences.includeTelemetry,
                includeProjectPaths: preferences.includeProjectPaths,
            ),
            runtime: runtime,
            projectContext: QuickFeedbackPayload.ProjectContext(
                activeProjectPath: context.activeProjectPath.map { sanitizedPath($0, preferences: preferences) },
                activeSource: context.activeSource,
                projectCount: context.projectCount,
                sessionSummary: QuickFeedbackPayload.SessionSummary(
                    total: sortedStates.count,
                    working: working,
                    ready: ready,
                    waiting: waiting,
                    compacting: compacting,
                    idle: idle,
                    withAttachedSession: withAttachedSession,
                    thinking: thinking,
                ),
                projects: Array(projectSnapshots),
                omittedProjectCount: max(0, sortedStates.count - projectSnapshots.count),
            ),
            activationSignal: QuickFeedbackPayload.ActivationSignal(
                hasTrace: !(trace?.isEmpty ?? true),
                traceDigest: trace.flatMap(digestHex),
            ),
        )
    }

    private static func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .working:
            "working"
        case .ready:
            "ready"
        case .idle:
            "idle"
        case .compacting:
            "compacting"
        case .waiting:
            "waiting"
        }
    }

    private static func sanitizedPath(_ path: String, preferences: QuickFeedbackPreferences) -> String {
        guard !preferences.includeProjectPaths else {
            return path
        }
        return "project#\(digestHex(path).prefix(12))"
    }

    private static func digestHex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func optionalValue(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }
}

struct QuickFeedbackSubmissionOutcome: Equatable {
    let feedbackID: String
    let issueURL: URL
    let issueOpened: Bool
    let endpointAttempted: Bool
    let endpointSucceeded: Bool
    let endpointError: String?
}

struct QuickFeedbackSubmitter {
    typealias OpenURLAction = (URL) -> Bool
    typealias RequestSender = (URLRequest) async throws -> Void

    private let environment: [String: String]
    private let openURL: OpenURLAction
    private let sendRequest: RequestSender
    private let now: () -> Date
    private let repository: String
    private let feedbackIDProvider: () -> String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openURL: @escaping OpenURLAction,
        sendRequest: @escaping RequestSender,
        now: @escaping () -> Date = Date.init,
        repository: String = QuickFeedbackIssueComposer.defaultRepository,
        feedbackIDProvider: @escaping () -> String = QuickFeedbackID.generate,
    ) {
        self.environment = environment
        self.openURL = openURL
        self.sendRequest = sendRequest
        self.now = now
        self.repository = repository
        self.feedbackIDProvider = feedbackIDProvider
    }

    func submit(
        draft: QuickFeedbackDraft,
        context: QuickFeedbackContext,
        preferences: QuickFeedbackPreferences,
        openGitHubIssue: Bool = true,
    ) async -> QuickFeedbackSubmissionOutcome {
        let normalizedDraft = draft.normalized()
        let feedbackID = feedbackIDProvider()
        let payload = QuickFeedbackPayloadBuilder.build(
            feedbackID: feedbackID,
            draft: normalizedDraft,
            context: context,
            preferences: preferences,
            now: now(),
        )

        var endpointAttempted = false
        var endpointSucceeded = false
        var endpointError: String?

        if preferences.includeTelemetry,
           let endpointURL = endpointURL()
        {
            endpointAttempted = true
            do {
                let request = try endpointRequest(endpointURL: endpointURL, payload: payload)
                try await sendRequest(request)
                endpointSucceeded = true
            } catch {
                endpointError = String(describing: error)
            }
        }

        let issueURL = QuickFeedbackIssueComposer.issueURL(payload: payload, repository: repository)
        let issueOpened = openGitHubIssue ? openURL(issueURL) : false

        return QuickFeedbackSubmissionOutcome(
            feedbackID: feedbackID,
            issueURL: issueURL,
            issueOpened: issueOpened,
            endpointAttempted: endpointAttempted,
            endpointSucceeded: endpointSucceeded,
            endpointError: endpointError,
        )
    }

    func submit(
        message: String,
        context: QuickFeedbackContext,
        preferences: QuickFeedbackPreferences,
        openGitHubIssue: Bool = true,
    ) async -> QuickFeedbackSubmissionOutcome {
        await submit(
            draft: QuickFeedbackDraft.messageOnly(message),
            context: context,
            preferences: preferences,
            openGitHubIssue: openGitHubIssue,
        )
    }

    private func endpointURL() -> URL? {
        guard let raw = environment["CAPACITOR_FEEDBACK_API_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        return URL(string: raw)
    }

    private func endpointRequest(endpointURL: URL, payload: QuickFeedbackPayload) throws -> URLRequest {
        let data = try JSONEncoder().encode(payload)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ingestKey = environment["CAPACITOR_INGEST_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ingestKey.isEmpty
        {
            request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

enum QuickFeedbackIssueComposer {
    static let defaultRepository = "petekp/capacitor"

    static func issueURL(payload: QuickFeedbackPayload, repository: String = defaultRepository) -> URL {
        let repositoryPath = normalizedRepositoryPath(repository)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repositoryPath)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: issueTitle(for: payload)),
            URLQueryItem(name: "labels", value: "alpha-feedback"),
            URLQueryItem(name: "body", value: issueBody(for: payload)),
        ]

        return components.url
            ?? URL(string: "https://github.com/\(defaultRepository)/issues/new")
            ?? URL(fileURLWithPath: "/")
    }

    private static func issueTitle(for payload: QuickFeedbackPayload) -> String {
        let trimmed = payload.form.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Alpha feedback [\(payload.feedbackID)]"
        }
        let snippet = String(trimmed.prefix(70))
        return "Alpha feedback [\(payload.feedbackID)]: \(snippet)"
    }

    private static func issueBody(for payload: QuickFeedbackPayload) -> String {
        var sections: [String] = [
            "<!-- capacitor_feedback_id: \(payload.feedbackID) -->",
            "",
            "## Report",
            "- Feedback ID: \(payload.feedbackID)",
            "",
            "## Summary",
            payload.form.summary,
            "",
        ]

        if let details = payload.form.details {
            sections.append(contentsOf: [
                "## What happened",
                details,
                "",
            ])
        }

        if let expected = payload.form.expectedBehavior {
            sections.append(contentsOf: [
                "## Expected behavior",
                expected,
                "",
            ])
        }

        if let steps = payload.form.stepsToReproduce {
            sections.append(contentsOf: [
                "## Steps to reproduce",
                steps,
                "",
            ])
        }

        sections.append(contentsOf: [
            "## Privacy",
            "- Include technical telemetry: \(payload.privacy.includeTelemetry ? "yes" : "no")",
            "- Include project paths: \(payload.privacy.includeProjectPaths ? "yes" : "no")",
            "",
        ])

        if payload.privacy.includeTelemetry {
            sections.append(contentsOf: [
                "## Telemetry Context",
                "```json",
                payloadJSONString(payload),
                "```",
            ])
        } else {
            sections.append("Telemetry sharing is disabled for this report.")
        }

        return sections.joined(separator: "\n")
    }

    private static func payloadJSONString(_ payload: QuickFeedbackPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func normalizedRepositoryPath(_ repository: String) -> String {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return defaultRepository
        }
        return "\(parts[0])/\(parts[1])"
    }
}

enum QuickFeedbackID {
    static func generate() -> String {
        "fb-\(UUID().uuidString.lowercased())"
    }
}
