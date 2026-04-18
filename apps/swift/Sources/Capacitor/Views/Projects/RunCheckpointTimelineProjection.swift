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
        let createdAt: String
        let decidedAt: String?

        var eventTimestamp: String {
            decidedAt ?? createdAt
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
    }

    private static func checkpointRecords(for run: RuntimeRunState) -> [CheckpointRecord] {
        var records = run.pastCheckpoints.map {
            CheckpointRecord(
                checkpoint: $0,
                source: .archived,
                sourceOrder: 0,
            )
        }

        if let activeCheckpoint = run.activeCheckpoint {
            records.append(CheckpointRecord(
                checkpoint: activeCheckpoint,
                source: .active,
                sourceOrder: 1,
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

        return checkpointRecords.enumerated().map { ordinal, record in
            let checkpoint = record.checkpoint
            let roundNumber = (roundNumbersByPhaseID[checkpoint.phaseId] ?? 0) + 1
            roundNumbersByPhaseID[checkpoint.phaseId] = roundNumber

            return Entry(
                id: "\(checkpoint.id)#\(ordinal)",
                checkpointID: checkpoint.id,
                source: record.source,
                phaseID: checkpoint.phaseId,
                phaseName: phaseNamesByID[checkpoint.phaseId] ?? checkpoint.phaseId,
                phaseRoundNumber: roundNumber,
                kindLabel: kindLabel(for: checkpoint.kind),
                title: checkpoint.title,
                summary: checkpoint.summary,
                decisionState: decisionState(for: checkpoint, source: record.source),
                decisionNote: checkpoint.decision?.note,
                createdAt: checkpoint.createdAt,
                decidedAt: checkpoint.decidedAt,
            )
        }
    }

    private static func checkpointRecordPrecedes(
        _ lhs: CheckpointRecord,
        _ rhs: CheckpointRecord,
    ) -> Bool {
        let createdComparison = compareTimestamps(lhs.checkpoint.createdAt, rhs.checkpoint.createdAt)
        if createdComparison != .orderedSame {
            return createdComparison == .orderedAscending
        }

        let decidedComparison = compareOptionalTimestamps(lhs.checkpoint.decidedAt, rhs.checkpoint.decidedAt)
        if decidedComparison != .orderedSame {
            return decidedComparison == .orderedAscending
        }

        if lhs.sourceOrder != rhs.sourceOrder {
            return lhs.sourceOrder < rhs.sourceOrder
        }

        return lhs.checkpoint.id < rhs.checkpoint.id
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

    private static func compareOptionalTimestamps(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            compareTimestamps(lhs, rhs)
        case (.some, .none):
            .orderedAscending
        case (.none, .some):
            .orderedDescending
        case (.none, .none):
            .orderedSame
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
}
