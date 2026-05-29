import Foundation

struct ProjectCaseFileProjection: Equatable {
    enum CurrentStateKind: Equatable {
        case needsDecision
        case running
        case completed
        case failed
        case recorded
    }

    struct CurrentState: Equatable {
        let kind: CurrentStateKind
        let title: String
        let detail: String
    }

    struct RecentDecision: Identifiable, Equatable {
        let id: String
        let label: String
        let title: String
        let note: String?
        let decidedAt: String
    }

    struct SinceLastLooked: Equatable {
        let lastSeenAt: Date?
        let changedCheckpointCount: Int
        let summary: String
    }

    let projectName: String
    let runID: String
    let methodName: String
    let currentState: CurrentState
    let sinceLastLooked: SinceLastLooked
    let recentDecisions: [RecentDecision]
    let openRisks: [String]

    static func make(
        project: Project,
        run: RuntimeRunState,
        timeline: RunCheckpointTimelineProjection,
        viewState: OperatorViewStateStore.Snapshot,
    ) -> ProjectCaseFileProjection {
        ProjectCaseFileProjection(
            projectName: project.name,
            runID: run.id,
            methodName: run.methodName,
            currentState: currentState(for: run),
            sinceLastLooked: sinceLastLooked(
                projectPath: project.path,
                run: run,
                entries: timeline.entries,
                viewState: viewState,
            ),
            recentDecisions: recentDecisions(from: timeline.entries),
            openRisks: openRisks(run: run, entries: timeline.entries),
        )
    }

    private static func currentState(for run: RuntimeRunState) -> CurrentState {
        let statusDetail = cleaned(run.statusMessage)
            ?? PhaseStepFormatter.format(
                phases: run.phases,
                currentPhaseIndex: run.currentPhaseIndex,
                runStatus: run.status,
                statusMessage: nil,
            )

        if run.status == .paused,
           let checkpoint = run.activeCheckpoint
        {
            return CurrentState(
                kind: .needsDecision,
                title: "Needs decision",
                detail: "Checkpoint ready: \(checkpoint.title)",
            )
        }

        switch run.status {
        case .active:
            return CurrentState(
                kind: .running,
                title: "Running",
                detail: statusDetail ?? "Worker is active.",
            )
        case .completed:
            return CurrentState(
                kind: .completed,
                title: "Completed",
                detail: statusDetail ?? "Run completed with checkpoint history.",
            )
        case .failed, .cancelled:
            return CurrentState(
                kind: .failed,
                title: run.status == .cancelled ? "Cancelled" : "Failed",
                detail: statusDetail ?? "Run ended before completion.",
            )
        // `.paused` without an active checkpoint, and `.created`, fall through to
        // the "Recorded" baseline below — matching the prior if-ladder default.
        case .paused, .created:
            return CurrentState(
                kind: .recorded,
                title: "Recorded",
                detail: statusDetail ?? "Latest checkpoint history is available.",
            )
        }
    }

    private static func sinceLastLooked(
        projectPath: String,
        run: RuntimeRunState,
        entries: [RunCheckpointTimelineProjection.Entry],
        viewState: OperatorViewStateStore.Snapshot,
    ) -> SinceLastLooked {
        let normalizedProjectPath = PathNormalizer.normalize(projectPath)
        let lastSeenAt = latestDate([
            viewState.lastSeenProjects[normalizedProjectPath],
            viewState.lastSeenRuns[run.id],
        ] + entries.compactMap { viewState.lastSeenCheckpoints[$0.checkpointID] })

        guard let lastSeenAt else {
            return SinceLastLooked(
                lastSeenAt: nil,
                changedCheckpointCount: entries.count,
                summary: "First recorded look at this run.",
            )
        }

        let changedCount = entries.count(where: { entry in
            guard let eventDate = parseISO8601Date(entry.eventTimestamp) else {
                return entry.eventTimestamp > formatISO8601Timestamp(lastSeenAt)
            }
            return eventDate > lastSeenAt
        })

        return SinceLastLooked(
            lastSeenAt: lastSeenAt,
            changedCheckpointCount: changedCount,
            summary: changedSummary(changedCount),
        )
    }

    private static func changedSummary(_ count: Int) -> String {
        if count == 0 {
            return "Nothing new since you last looked."
        }
        return "\(count) checkpoint \(count == 1 ? "update" : "updates") since you last looked."
    }

    private static func recentDecisions(
        from entries: [RunCheckpointTimelineProjection.Entry],
    ) -> [RecentDecision] {
        entries
            .filter(\.decisionState.isRecordedDecision)
            .sorted(by: latestEventFirst)
            .prefix(3)
            .map { entry in
                RecentDecision(
                    id: entry.id,
                    label: entry.decisionState.caseFileLabel,
                    title: entry.title,
                    note: cleaned(entry.decisionNote),
                    decidedAt: entry.eventTimestamp,
                )
            }
    }

    private static func openRisks(
        run: RuntimeRunState,
        entries: [RunCheckpointTimelineProjection.Entry],
    ) -> [String] {
        var risks = [String]()

        if run.status == .failed || run.status == .cancelled {
            let detail = cleaned(run.statusMessage) ?? "Run ended with status \(run.status.wireValue)."
            risks.append(detail)
        }

        if run.status == .paused,
           let checkpoint = run.activeCheckpoint
        {
            risks.append("Decision needed before work can continue: \(checkpoint.title)")

            switch checkpoint.captureStatus {
            case let .failed(reason):
                risks.append("Checkpoint capture failed: \(reason)")
            case .pending, .inProgress:
                risks.append("Checkpoint capture is still in progress.")
            case .completed, .notRequested:
                break
            }
        }

        if let activeEntry = entries.last(where: { $0.decisionState == .awaitingReview }),
           let relationship = activeEntry.revisionRelationship
        {
            risks.append("Verify revision against round \(relationship.priorPhaseRoundNumber): \(relationship.priorDecisionNote)")
        } else if let outstandingRequest = latestOutstandingRequest(from: entries) {
            risks.append("Revision requested: \(outstandingRequest)")
        }

        return unique(risks, fallback: "No open risks surfaced from runtime facts.")
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

    private static func latestDate(_ dates: [Date?]) -> Date? {
        dates.compactMap(\.self).max()
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

    var caseFileLabel: String {
        switch self {
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
}
