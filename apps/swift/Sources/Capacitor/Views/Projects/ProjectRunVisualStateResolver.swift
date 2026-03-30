import Foundation

enum RunVisualState: Equatable {
    case working(statusMessage: String?)
    case waiting(statusMessage: String?)
    case completed(statusMessage: String?)
    case failed(statusMessage: String?)
    case none

    var sessionState: SessionState? {
        switch self {
        case .working:
            .working
        case .waiting:
            .waiting
        case .completed, .failed, .none:
            nil
        }
    }

    var statusMessage: String? {
        switch self {
        case let .working(statusMessage),
             let .waiting(statusMessage),
             let .completed(statusMessage),
             let .failed(statusMessage):
            statusMessage
        case .none:
            nil
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            true
        case .working, .waiting, .none:
            false
        }
    }
}

struct ProjectRunVisualResolution: Equatable {
    let run: RuntimeRunState?
    let visualState: RunVisualState
}

enum ProjectRunVisualStateResolver {
    static func resolve(
        projectPath: String,
        runsByID: [RuntimeRunKey: RuntimeRunState],
        now: Date = Date(),
    ) -> ProjectRunVisualResolution {
        let normalizedProjectPath = PathNormalizer.normalize(projectPath)
        let selectedRun = runsByID.values
            .filter { PathNormalizer.normalize($0.projectPath) == normalizedProjectPath }
            .compactMap { run -> (priority: Int, run: RuntimeRunState)? in
                guard let priority = priority(for: run, now: now) else { return nil }
                return (priority, run)
            }
            .sorted(by: candidatePrecedes)
            .first?
            .run

        return ProjectRunVisualResolution(
            run: selectedRun,
            visualState: visualState(for: selectedRun, now: now),
        )
    }

    static func visualState(
        for run: RuntimeRunState?,
        now: Date = Date(),
    ) -> RunVisualState {
        guard let run else { return .none }

        let statusMessage = PhaseStepFormatter.format(
            phases: run.phases,
            currentPhaseIndex: run.currentPhaseIndex,
            runStatus: run.status,
            statusMessage: cleanedStatusMessage(run.statusMessage),
        )
        if run.status == "paused",
           run.activeCheckpoint != nil,
           !SessionStaleness.isPausedCheckpointStale(
               updatedAt: run.updatedAt,
               now: now,
           )
        {
            return .waiting(statusMessage: statusMessage)
        }
        if run.status == "active",
           !SessionStaleness.isWorkingStale(
               state: .working,
               updatedAt: run.updatedAt,
               now: now,
           )
        {
            return .working(statusMessage: statusMessage)
        }
        if run.status == "completed",
           !isTerminalStale(updatedAt: run.updatedAt, now: now)
        {
            return .completed(statusMessage: statusMessage)
        }
        if run.status == "failed" || run.status == "cancelled",
           !isTerminalStale(updatedAt: run.updatedAt, now: now)
        {
            return .failed(statusMessage: statusMessage)
        }
        return .none
    }

    private static func priority(for run: RuntimeRunState, now: Date) -> Int? {
        if run.status == "paused",
           run.activeCheckpoint != nil,
           !SessionStaleness.isPausedCheckpointStale(
               updatedAt: run.updatedAt,
               now: now,
           )
        {
            return 3
        }
        if run.status == "active" {
            return 2
        }
        if run.status == "completed",
           !isTerminalStale(updatedAt: run.updatedAt, now: now)
        {
            return 1
        }
        if run.status == "failed" || run.status == "cancelled",
           !isTerminalStale(updatedAt: run.updatedAt, now: now)
        {
            return 1
        }
        if run.status == "created" {
            return 0
        }
        return nil
    }

    private static func isTerminalStale(updatedAt: String, now: Date) -> Bool {
        guard let updatedDate = parseISO8601Date(updatedAt) else { return true }
        let terminalVisibilityWindow: TimeInterval = 60 * 60
        return now.timeIntervalSince(updatedDate) > terminalVisibilityWindow
    }

    private static func candidatePrecedes(
        _ lhs: (priority: Int, run: RuntimeRunState),
        _ rhs: (priority: Int, run: RuntimeRunState),
    ) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }

        let updatedComparison = compareTimestamps(lhs.run.updatedAt, rhs.run.updatedAt)
        if updatedComparison != .orderedSame {
            return updatedComparison == .orderedDescending
        }

        let createdComparison = compareTimestamps(lhs.run.createdAt, rhs.run.createdAt)
        if createdComparison != .orderedSame {
            return createdComparison == .orderedDescending
        }

        if lhs.run.id != rhs.run.id {
            return lhs.run.id < rhs.run.id
        }

        return PathNormalizer.normalize(lhs.run.projectPath) < PathNormalizer.normalize(rhs.run.projectPath)
    }

    private static func compareTimestamps(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsDate = parseISO8601Date(lhs)
        let rhsDate = parseISO8601Date(rhs)

        switch (lhsDate, rhsDate) {
        case let (.some(lhsDate), .some(rhsDate)):
            if lhsDate > rhsDate {
                return .orderedDescending
            }
            if lhsDate < rhsDate {
                return .orderedAscending
            }
        case (.some, .none):
            return .orderedDescending
        case (.none, .some):
            return .orderedAscending
        case (.none, .none):
            break
        }

        if lhs > rhs {
            return .orderedDescending
        }
        if lhs < rhs {
            return .orderedAscending
        }
        return .orderedSame
    }

    private static func cleanedStatusMessage(_ statusMessage: String?) -> String? {
        guard let trimmed = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
