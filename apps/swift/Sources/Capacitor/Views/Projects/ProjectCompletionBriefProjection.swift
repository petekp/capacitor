import Foundation

struct ProjectCompletionBriefProjection: Equatable {
    let projectName: String
    let runID: String
    let methodName: String
    let headline: String
    let outcome: String
    let readyFor: String
    let confidence: String
    let evidence: [String]
    let residualRisks: [String]

    var attentionReason: String {
        "Ready for final review: \(workTitle)"
    }

    var recommendedAction: String {
        Self.operatorRecommendedAction
    }

    private let workTitle: String

    static let operatorRecommendedAction = "Review / archive / follow up"

    static func make(
        project: Project,
        run: RuntimeRunState,
        timeline: RunCheckpointTimelineProjection?,
    ) -> ProjectCompletionBriefProjection? {
        guard run.status == .completed else { return nil }

        let title = workTitle(for: run)
        let entries = timeline?.entries ?? []
        let risks = residualRisks(run: run, entries: entries)
        let evidence = evidenceLines(run: run, entries: entries)

        return ProjectCompletionBriefProjection(
            projectName: project.name,
            runID: run.id,
            methodName: run.methodName,
            headline: "Completed: \(title)",
            outcome: cleaned(run.statusMessage) ?? "\(run.methodName) finished.",
            readyFor: "Final review / archive / follow-up",
            confidence: confidence(evidence: evidence, residualRisks: risks),
            evidence: evidence,
            residualRisks: risks,
            workTitle: title,
        )
    }

    static func attentionReason(for run: RuntimeRunState) -> String {
        "Ready for final review: \(workTitle(for: run))"
    }

    static func workTitle(for run: RuntimeRunState) -> String {
        cleaned(run.ideaTitle)
            ?? cleaned(run.methodName)
            ?? "Completed run"
    }

    private static func evidenceLines(
        run: RuntimeRunState,
        entries: [RunCheckpointTimelineProjection.Entry],
    ) -> [String] {
        var lines = [String]()

        if entries.isEmpty {
            lines.append("No checkpoint history recorded.")
        } else {
            lines.append("\(entries.count) checkpoint \(entries.count == 1 ? "entry" : "entries") recorded.")
        }

        if let latestDecision = latestRecordedDecision(from: entries) {
            lines.append("Latest decision: \(decisionLabel(for: latestDecision.decisionState)) - \(latestDecision.title)")
        }

        let artifactCount = run.pastCheckpoints.reduce(0) { count, checkpoint in
            count
                + checkpoint.mediaArtifacts.count
                + (checkpoint.briefPath == nil ? 0 : 1)
                + (checkpoint.manifestPath == nil ? 0 : 1)
        }
        if artifactCount > 0 {
            lines.append("\(artifactCount) checkpoint \(artifactCount == 1 ? "artifact" : "artifacts") recorded.")
        }

        return unique(lines, fallback: "Checkpoint history recorded.")
    }

    private static func residualRisks(
        run: RuntimeRunState,
        entries: [RunCheckpointTimelineProjection.Entry],
    ) -> [String] {
        var risks = [String]()

        if let outstandingRequest = latestOutstandingRequest(from: entries) {
            risks.append("Prior change request may need final confirmation: \(outstandingRequest)")
        }

        for checkpoint in run.pastCheckpoints {
            if case let .failed(reason) = checkpoint.captureStatus {
                risks.append("Checkpoint capture failed: \(reason)")
            }
        }

        if entries.isEmpty {
            risks.append("No checkpoint evidence recorded for final review.")
        } else if !entries.contains(where: \.decisionState.isPositiveClosure) {
            risks.append("No explicit approve decision recorded in checkpoint history.")
        }

        return unique(risks, fallback: "No open risks surfaced from runtime facts.")
    }

    private static func latestRecordedDecision(
        from entries: [RunCheckpointTimelineProjection.Entry],
    ) -> RunCheckpointTimelineProjection.Entry? {
        entries
            .filter(\.decisionState.isRecordedDecision)
            .sorted(by: latestEventFirst)
            .first
    }

    private static func latestOutstandingRequest(
        from entries: [RunCheckpointTimelineProjection.Entry],
    ) -> String? {
        var latestRequestByPhaseID = [String: RunCheckpointTimelineProjection.Entry]()

        for entry in entries {
            switch entry.decisionState {
            case .changesRequested:
                if cleaned(entry.decisionNote) != nil {
                    latestRequestByPhaseID[entry.phaseID] = entry
                }
            case .approved, .decided:
                latestRequestByPhaseID[entry.phaseID] = nil
            case .awaitingReview, .unknown:
                break
            }
        }

        return latestRequestByPhaseID.values
            .sorted(by: latestEventFirst)
            .first
            .flatMap { cleaned($0.decisionNote) }
    }

    private static func confidence(
        evidence: [String],
        residualRisks: [String],
    ) -> String {
        if residualRisks == ["No open risks surfaced from runtime facts."],
           !evidence.isEmpty
        {
            return "medium"
        }
        return "low"
    }

    private static func decisionLabel(
        for decisionState: RunCheckpointTimelineProjection.Entry.DecisionState,
    ) -> String {
        switch decisionState {
        case .approved:
            "Approved"
        case .changesRequested:
            "Changes requested"
        case .decided:
            "Decided"
        case let .unknown(value):
            value
        case .awaitingReview:
            "Awaiting review"
        }
    }

    private static func latestEventFirst(
        _ lhs: RunCheckpointTimelineProjection.Entry,
        _ rhs: RunCheckpointTimelineProjection.Entry,
    ) -> Bool {
        compareEventTimestamps(lhs.eventTimestamp, rhs.eventTimestamp) == .orderedDescending
    }

    private static func compareEventTimestamps(_ lhs: String, _ rhs: String) -> ComparisonResult {
        switch (parseISO8601Date(lhs), parseISO8601Date(rhs)) {
        case let (.some(lhsDate), .some(rhsDate)):
            if lhsDate > rhsDate { return .orderedDescending }
            if lhsDate < rhsDate { return .orderedAscending }
            return .orderedSame
        case (.some, .none):
            return .orderedDescending
        case (.none, .some):
            return .orderedAscending
        case (.none, .none):
            if lhs > rhs { return .orderedDescending }
            if lhs < rhs { return .orderedAscending }
            return .orderedSame
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func unique(_ values: [String], fallback: String) -> [String] {
        var seen = Set<String>()
        let cleanedValues = values.compactMap(cleaned).filter { value in
            if seen.contains(value) {
                return false
            }
            seen.insert(value)
            return true
        }
        return cleanedValues.isEmpty ? [fallback] : cleanedValues
    }
}

private extension RunCheckpointTimelineProjection.Entry.DecisionState {
    var isRecordedDecision: Bool {
        switch self {
        case .approved, .changesRequested, .decided, .unknown:
            true
        case .awaitingReview:
            false
        }
    }

    var isPositiveClosure: Bool {
        switch self {
        case .approved, .decided:
            true
        case .changesRequested, .unknown, .awaitingReview:
            false
        }
    }
}
