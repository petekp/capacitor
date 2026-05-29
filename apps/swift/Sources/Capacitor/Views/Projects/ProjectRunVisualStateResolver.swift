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
        return classify(run, now: now).visualState(statusMessage: statusMessage)
    }

    private static func priority(for run: RuntimeRunState, now: Date) -> Int? {
        classify(run, now: now).priority
    }

    /// Single exhaustive classification of a run's status, computed once and
    /// consumed by both `visualState(for:)` and `priority(for:)`.
    ///
    /// This merges the two previously-separate `RunStatus` ladders so a given
    /// status has exactly one meaning across selection and rendering, fixing the
    /// confirmed drift where `priority` treated `.created` as a selectable
    /// candidate (priority 0) while `visualState` silently fell through to
    /// `.none`.
    ///
    /// Canonical meaning of `.created`: the run exists but has not started any
    /// visible work. It remains selectable at the lowest priority (0) — so a
    /// freshly created run can win selection when nothing else qualifies — but
    /// renders no visual band of its own. This preserves both prior behaviors
    /// (`priority` == 0 and `visualState` == `.none`) and gives `.created` one
    /// consistent definition.
    ///
    /// `.active` is preserved exactly: it is always a selection candidate at
    /// priority 2, but only renders the `.working` band when the run is fresh.
    /// A stale-active run stays selected yet renders `.none`, matching the
    /// pre-decomplect behavior.
    private struct RunClassification {
        let priority: Int?
        private let band: RunVisualState

        func visualState(statusMessage: String?) -> RunVisualState {
            switch band {
            case .waiting: .waiting(statusMessage: statusMessage)
            case .working: .working(statusMessage: statusMessage)
            case .completed: .completed(statusMessage: statusMessage)
            case .failed: .failed(statusMessage: statusMessage)
            case .none: .none
            }
        }

        init(priority: Int?, band: RunVisualState) {
            self.priority = priority
            self.band = band
        }
    }

    private static func classify(_ run: RuntimeRunState, now: Date) -> RunClassification {
        switch run.status {
        case .paused:
            if SessionStaleness.isPausedCheckpointStale(updatedAt: run.updatedAt, now: now) {
                return RunClassification(priority: nil, band: .none)
            }
            return RunClassification(priority: 3, band: .waiting(statusMessage: nil))
        case .active:
            // Always a selection candidate (priority 2); only renders `.working`
            // while fresh, otherwise selected-but-no-visual.
            let band: RunVisualState = SessionStaleness.isRunFreshnessExpired(updatedAt: run.updatedAt, now: now)
                ? .none
                : .working(statusMessage: nil)
            return RunClassification(priority: 2, band: band)
        case .completed:
            if isTerminalStale(updatedAt: run.updatedAt, now: now) {
                return RunClassification(priority: nil, band: .none)
            }
            return RunClassification(priority: 1, band: .completed(statusMessage: nil))
        case .failed, .cancelled:
            if isTerminalStale(updatedAt: run.updatedAt, now: now) {
                return RunClassification(priority: nil, band: .none)
            }
            return RunClassification(priority: 1, band: .failed(statusMessage: nil))
        case .created:
            // Selectable at lowest priority, no visual band.
            return RunClassification(priority: 0, band: .none)
        }
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
