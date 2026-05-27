import Foundation

struct RunCheckpointTimelineProjection: Equatable {
    struct Entry: Identifiable, Equatable {
        enum Source: Equatable {
            case archived
            case active
        }

        enum DecisionState: Equatable {
            case awaitingReview
            case approved
            case changesRequested
            case decided
            case unknown(String)
        }

        enum TimestampRole: Equatable {
            case created
            case decided
            case recorded
        }

        struct RevisionRelationship: Equatable {
            let priorEntryID: String
            let priorCheckpointID: String
            let priorPhaseRoundNumber: Int
            let priorDecisionNote: String
        }

        let id: String
        let checkpointID: String
        let source: Source
        let phaseID: String
        let phaseName: String
        let phaseRoundNumber: Int
        let kindLabel: String
        let title: String
        let summary: String?
        let decisionState: DecisionState
        let decisionNote: String?
        let revisionRelationship: RevisionRelationship?
        let createdAt: String
        let decidedAt: String?
        let timestampRole: TimestampRole

        var eventTimestamp: String {
            switch timestampRole {
            case .created, .recorded:
                createdAt
            case .decided:
                decidedAt ?? createdAt
            }
        }
    }

    let runID: String
    let methodName: String
    let entries: [Entry]

    init?(run: RuntimeRunState) {
        let checkpointRecords = Self.checkpointRecords(for: run)
        guard !checkpointRecords.isEmpty else { return nil }

        runID = run.id
        methodName = run.methodName
        entries = Self.entries(
            checkpointRecords: checkpointRecords,
            phases: run.phases,
        )
    }

    private struct CheckpointRecord: Equatable {
        let checkpoint: RuntimeCheckpointState
        let source: Entry.Source
        let sourceOrder: Int
        let inputOrder: Int
    }

    private static func checkpointRecords(for run: RuntimeRunState) -> [CheckpointRecord] {
        var records = run.pastCheckpoints.enumerated().map { index, checkpoint in
            CheckpointRecord(
                checkpoint: checkpoint,
                source: .archived,
                sourceOrder: 0,
                inputOrder: index,
            )
        }

        if let activeCheckpoint = run.activeCheckpoint {
            records.append(CheckpointRecord(
                checkpoint: activeCheckpoint,
                source: .active,
                sourceOrder: 1,
                inputOrder: run.pastCheckpoints.count,
            ))
        }

        return records.sorted(by: checkpointRecordPrecedes)
    }

    private static func entries(
        checkpointRecords: [CheckpointRecord],
        phases: [RuntimePhaseInstance],
    ) -> [Entry] {
        let phaseNamesByID = Dictionary(
            uniqueKeysWithValues: phases.map { ($0.id, $0.name) },
        )
        var roundNumbersByPhaseID: [String: Int] = [:]
        var latestRequestByPhaseID: [String: Entry.RevisionRelationship] = [:]

        return checkpointRecords.enumerated().map { ordinal, record in
            let checkpoint = record.checkpoint
            let roundNumber = (roundNumbersByPhaseID[checkpoint.phaseId] ?? 0) + 1
            roundNumbersByPhaseID[checkpoint.phaseId] = roundNumber
            let entryID = entryID(for: record, fallbackOrdinal: ordinal)
            let decisionState = decisionState(for: checkpoint, source: record.source)
            let decisionNote = checkpoint.decision?.note

            let entry = Entry(
                id: entryID,
                checkpointID: checkpoint.id,
                source: record.source,
                phaseID: checkpoint.phaseId,
                phaseName: phaseNamesByID[checkpoint.phaseId] ?? checkpoint.phaseId,
                phaseRoundNumber: roundNumber,
                kindLabel: kindLabel(for: checkpoint.kind),
                title: checkpoint.title,
                summary: checkpoint.summary,
                decisionState: decisionState,
                decisionNote: decisionNote,
                revisionRelationship: latestRequestByPhaseID[checkpoint.phaseId],
                createdAt: checkpoint.createdAt,
                decidedAt: checkpoint.decidedAt,
                timestampRole: timestampRole(for: checkpoint, source: record.source),
            )

            if record.source == .archived {
                if decisionState == .changesRequested,
                   let note = cleaned(decisionNote)
                {
                    latestRequestByPhaseID[checkpoint.phaseId] = Entry.RevisionRelationship(
                        priorEntryID: entryID,
                        priorCheckpointID: checkpoint.id,
                        priorPhaseRoundNumber: roundNumber,
                        priorDecisionNote: note,
                    )
                } else {
                    latestRequestByPhaseID[checkpoint.phaseId] = nil
                }
            }

            return entry
        }
    }

    private static func checkpointRecordPrecedes(
        _ lhs: CheckpointRecord,
        _ rhs: CheckpointRecord,
    ) -> Bool {
        if lhs.checkpoint.historyOrdinal != nil || rhs.checkpoint.historyOrdinal != nil {
            let lhsOrdinal = lhs.checkpoint.historyOrdinal ?? UInt64(lhs.inputOrder)
            let rhsOrdinal = rhs.checkpoint.historyOrdinal ?? UInt64(rhs.inputOrder)
            if lhsOrdinal != rhsOrdinal {
                return lhsOrdinal < rhsOrdinal
            }
        }

        let eventComparison = compareTimestamps(
            eventTimestamp(for: lhs.checkpoint, source: lhs.source),
            eventTimestamp(for: rhs.checkpoint, source: rhs.source),
        )
        if eventComparison != .orderedSame {
            return eventComparison == .orderedAscending
        }

        if lhs.sourceOrder != rhs.sourceOrder {
            return lhs.sourceOrder < rhs.sourceOrder
        }

        if lhs.inputOrder != rhs.inputOrder {
            return lhs.inputOrder < rhs.inputOrder
        }

        return lhs.checkpoint.id < rhs.checkpoint.id
    }

    private static func entryID(for record: CheckpointRecord, fallbackOrdinal: Int) -> String {
        if let historyOrdinal = record.checkpoint.historyOrdinal {
            return "\(record.checkpoint.id)#history-\(historyOrdinal)"
        }
        return "\(record.checkpoint.id)#\(fallbackOrdinal)"
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

    private static func decisionState(
        for checkpoint: RuntimeCheckpointState,
        source: Entry.Source,
    ) -> Entry.DecisionState {
        if source == .active {
            return .awaitingReview
        }

        guard let action = checkpoint.decision?.action else {
            return checkpoint.status == "decided" ? .decided : .unknown(checkpoint.status)
        }

        switch action {
        case "approve", "approved":
            return .approved
        case "request_changes", "rejected":
            return .changesRequested
        default:
            return .unknown(action)
        }
    }

    private static func eventTimestamp(
        for checkpoint: RuntimeCheckpointState,
        source: Entry.Source,
    ) -> String {
        switch timestampRole(for: checkpoint, source: source) {
        case .created, .recorded:
            checkpoint.createdAt
        case .decided:
            checkpoint.decidedAt ?? checkpoint.createdAt
        }
    }

    private static func timestampRole(
        for checkpoint: RuntimeCheckpointState,
        source: Entry.Source,
    ) -> Entry.TimestampRole {
        switch source {
        case .active:
            .created
        case .archived:
            checkpoint.decidedAt == nil ? .recorded : .decided
        }
    }

    private static func kindLabel(for kind: RuntimeCheckpointKind) -> String {
        switch kind {
        case .proposal:
            "Proposal"
        case .implementationMilestone:
            "Implementation"
        case .alignmentReview:
            "Alignment"
        case let .custom(label):
            label
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
}
