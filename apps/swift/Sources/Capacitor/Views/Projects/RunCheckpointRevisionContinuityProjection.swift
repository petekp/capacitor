import Foundation

struct RunCheckpointRevisionContinuity: Equatable {
    let priorCheckpointID: String
    let priorDecisionAt: String?
    let youAsked: String
    let agentResponse: String
    let evidence: [String]
    let remainingRisks: [String]
}

enum RunCheckpointRevisionContinuityProjection {
    static func make(
        run: RuntimeRunState,
        checkpoint: RuntimeCheckpointState,
        operatorBrief: RunCheckpointOperatorBrief,
    ) -> RunCheckpointRevisionContinuity? {
        guard let prior = latestPriorCheckpointForContinuity(
            before: checkpoint,
            pastCheckpoints: run.pastCheckpoints,
        ),
            let note = cleaned(prior.decision?.note),
            isRequestChangesAction(prior.decision?.action)
        else {
            return nil
        }

        return RunCheckpointRevisionContinuity(
            priorCheckpointID: prior.id,
            priorDecisionAt: prior.decidedAt,
            youAsked: note,
            agentResponse: cleaned(checkpoint.summary)
                ?? cleaned(operatorBrief.claim)
                ?? "The worker returned a follow-up checkpoint.",
            evidence: usefulList(
                operatorBrief.evidence,
                fallback: "Review the checkpoint evidence before deciding.",
            ),
            remainingRisks: usefulList(
                operatorBrief.risks,
                fallback: "No explicit risks were reported.",
            ),
        )
    }

    private static func latestPriorCheckpointForContinuity(
        before checkpoint: RuntimeCheckpointState,
        pastCheckpoints: [RuntimeCheckpointState],
    ) -> RuntimeCheckpointState? {
        let samePhaseCheckpoints = pastCheckpoints.filter { prior in
            guard prior.phaseId == checkpoint.phaseId else { return false }

            if let priorOrdinal = prior.historyOrdinal,
               let checkpointOrdinal = checkpoint.historyOrdinal,
               priorOrdinal >= checkpointOrdinal
            {
                return false
            }

            return true
        }

        return samePhaseCheckpoints.sorted(by: checkpointPrecedes).last
    }

    private static func checkpointPrecedes(
        _ lhs: RuntimeCheckpointState,
        _ rhs: RuntimeCheckpointState,
    ) -> Bool {
        if let lhsOrdinal = lhs.historyOrdinal,
           let rhsOrdinal = rhs.historyOrdinal,
           lhsOrdinal != rhsOrdinal
        {
            return lhsOrdinal < rhsOrdinal
        }

        let eventComparison = compareTimestamps(
            eventTimestamp(for: lhs),
            eventTimestamp(for: rhs),
        )
        if eventComparison != .orderedSame {
            return eventComparison == .orderedAscending
        }

        return lhs.id < rhs.id
    }

    private static func eventTimestamp(for checkpoint: RuntimeCheckpointState) -> String {
        checkpoint.decidedAt ?? checkpoint.createdAt
    }

    private static func compareTimestamps(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsDate = parseISO8601Date(lhs)
        let rhsDate = parseISO8601Date(rhs)

        switch (lhsDate, rhsDate) {
        case let (.some(lhsDate), .some(rhsDate)):
            if lhsDate < rhsDate {
                return .orderedAscending
            }
            if lhsDate > rhsDate {
                return .orderedDescending
            }
            return .orderedSame
        case (.some, .none):
            return .orderedAscending
        case (.none, .some):
            return .orderedDescending
        case (.none, .none):
            return lhs.compare(rhs)
        }
    }

    private static func usefulList(_ values: [String], fallback: String) -> [String] {
        let cleanedValues = values.compactMap(cleaned)
        return cleanedValues.isEmpty ? [fallback] : cleanedValues
    }

    private static func isRequestChangesAction(_ action: String?) -> Bool {
        guard let normalized = cleaned(action)?.lowercased() else {
            return false
        }
        return normalized == "request_changes" || normalized == "rejected"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
