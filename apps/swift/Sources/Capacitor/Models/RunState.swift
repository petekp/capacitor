import Foundation
import Observation

struct RuntimeRunKey: Hashable {
    let normalizedProjectPath: String
    let runID: String

    init(run: RuntimeRunState) {
        normalizedProjectPath = PathNormalizer.normalize(run.projectPath)
        runID = run.id
    }

    init(projectPath: String, runID: String) {
        normalizedProjectPath = PathNormalizer.normalize(projectPath)
        self.runID = runID
    }
}

/// Trims whitespace and clamps idea descriptions to 500 characters for run context.
func compactRunIdeaDescription(_ description: String?) -> String? {
    guard let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines),
          !desc.isEmpty
    else {
        return nil
    }
    if desc.count <= 500 {
        return desc
    }
    return String(desc.prefix(497)) + "..."
}

@Observable
@MainActor
final class RunStateStore {
    private(set) var delegationStates: [String: RuntimeDelegationState] = [:]
    private(set) var runStatesByID: [RuntimeRunKey: RuntimeRunState] = [:]

    func setDelegationState(
        _ state: RuntimeDelegationState,
        forNormalizedProjectPath normalizedProjectPath: String,
    ) {
        delegationStates[normalizedProjectPath] = state
    }

    func applyDelegationStates(
        _ delegations: [RuntimeDelegationState],
        enabled: Bool,
    ) {
        if enabled {
            let nextDelegations = Dictionary(
                uniqueKeysWithValues: delegations.map {
                    (PathNormalizer.normalize($0.projectPath), $0)
                },
            )
            if nextDelegations != delegationStates {
                delegationStates = nextDelegations
            }
        } else if !delegationStates.isEmpty {
            delegationStates = [:]
        }
    }

    func replaceRunStates(with runs: [RuntimeRunState]) -> [RuntimeRunKey: RuntimeRunState] {
        let nextRunsByID = Dictionary(
            runs.map { (RuntimeRunKey(run: $0), $0) },
            uniquingKeysWith: { existing, incoming in
                DebugLog.write(
                    "AppState.refreshSessionStates duplicate RuntimeRunKey for run=\(incoming.id) projectPath=\(incoming.projectPath) — keeping first",
                )
                return existing
            },
        )
        let previousRunsByID = runStatesByID
        if nextRunsByID != runStatesByID {
            runStatesByID = nextRunsByID
        }
        return previousRunsByID
    }

    func clearDelegationStates() {
        delegationStates = [:]
    }

    func runState(projectPath: String, runID: String) -> RuntimeRunState? {
        runStatesByID[RuntimeRunKey(projectPath: projectPath, runID: runID)]
    }

    var recentTerminalRuns: [RuntimeRunState] {
        let cutoff = Date().addingTimeInterval(-3600)
        let terminalStatuses: Set = ["completed", "failed", "cancelled"]
        return runStatesByID.values
            .filter { run in
                terminalStatuses.contains(run.status)
                    && (parseISO8601Date(run.updatedAt).map { $0 > cutoff } ?? false)
            }
            .sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
    }

    func activeRun(for idea: Idea, in project: Project) -> RuntimeRunState? {
        let normalizedProjectPath = PathNormalizer.normalize(project.path)
        let terminalStatuses: Set = ["completed", "failed", "cancelled"]

        return runStatesByID.values
            .filter {
                PathNormalizer.normalize($0.projectPath) == normalizedProjectPath
                    && $0.ideaId == idea.id
                    && !terminalStatuses.contains($0.status)
            }
            .sorted(by: activeIdeaRunPrecedes)
            .first
    }

    func activeRun(for project: Project) -> RuntimeRunState? {
        ProjectRunVisualStateResolver.resolve(
            projectPath: project.path,
            runsByID: runStatesByID,
        ).run
    }

    func checkpointTimelineRun(for project: Project) -> RuntimeRunState? {
        let normalizedProjectPath = PathNormalizer.normalize(project.path)
        return runStatesByID.values
            .filter {
                PathNormalizer.normalize($0.projectPath) == normalizedProjectPath
                    && hasCheckpointTimelineHistory($0)
            }
            .sorted(by: checkpointTimelineRunPrecedes)
            .first
    }

    func runCheckpointState(target: RunCheckpointWindowTarget) -> RuntimeCheckpointState? {
        runCheckpointState(
            target: target,
            runsByID: runStatesByID,
        )
    }

    func reconcileRunCheckpointWindowTarget(
        currentTarget: RunCheckpointWindowTarget?,
    ) -> RunCheckpointWindowTarget? {
        if let currentTarget,
           runCheckpointState(
               target: currentTarget,
               runsByID: runStatesByID,
           ) != nil
        {
            return currentTarget
        }

        let queuedTargets = runStatesByID.values
            .filter(isEligibleRunCheckpointCandidate)
            .sorted(by: runCheckpointCandidatePrecedes)
            .compactMap(runCheckpointTarget(for:))

        guard !queuedTargets.isEmpty else {
            return nil
        }

        let previousRunsByID = runStatesByID
        let newlySurfacedTargets = runStatesByID.values
            .filter(isEligibleRunCheckpointCandidate)
            .filter { run in
                isNewlySurfacedRunCheckpoint(
                    run,
                    previousRunsByID: previousRunsByID,
                )
            }
            .sorted(by: runCheckpointCandidatePrecedes)
            .compactMap(runCheckpointTarget(for:))

        if currentTarget != nil {
            return queuedTargets.first
        }
        return newlySurfacedTargets.first
    }

    func reconcileRunCheckpointWindowTarget(
        currentTarget: RunCheckpointWindowTarget?,
        previousRunsByID: [RuntimeRunKey: RuntimeRunState],
    ) -> RunCheckpointWindowTarget? {
        if let currentTarget,
           runCheckpointState(
               target: currentTarget,
               runsByID: runStatesByID,
           ) != nil
        {
            return currentTarget
        }

        let queuedTargets = runStatesByID.values
            .filter(isEligibleRunCheckpointCandidate)
            .sorted(by: runCheckpointCandidatePrecedes)
            .compactMap(runCheckpointTarget(for:))

        guard !queuedTargets.isEmpty else {
            return nil
        }

        let newlySurfacedTargets = runStatesByID.values
            .filter(isEligibleRunCheckpointCandidate)
            .filter { run in
                isNewlySurfacedRunCheckpoint(
                    run,
                    previousRunsByID: previousRunsByID,
                )
            }
            .sorted(by: runCheckpointCandidatePrecedes)
            .compactMap(runCheckpointTarget(for:))

        if currentTarget != nil {
            return queuedTargets.first
        }
        return newlySurfacedTargets.first
    }

    func applyAcceptedReviewDecisionLocally(
        _ delegation: RuntimeDelegationState,
        sessionId: String,
        submittedMilestoneId: String,
    ) {
        let normalizedProjectPath = PathNormalizer.normalize(delegation.projectPath)
        guard delegationStates[normalizedProjectPath] != nil else { return }

        setDelegationState(
            RuntimeDelegationState(
                projectPath: delegation.projectPath,
                workerId: delegation.workerId,
                ideaId: delegation.ideaId,
                worktreeName: delegation.worktreeName,
                worktreePath: delegation.worktreePath,
                sessionId: sessionId,
                status: "resume_pending",
                startedAt: delegation.startedAt,
                updatedAt: formatISO8601Timestamp(Date()),
                submittedMilestoneId: submittedMilestoneId,
                currentReview: delegation.currentReview,
            ),
            forNormalizedProjectPath: normalizedProjectPath,
        )
    }

    func delegationState(forPath projectPath: String) -> RuntimeDelegationState? {
        delegationStates[PathNormalizer.normalize(projectPath)]
    }

    private func isEligibleRunCheckpointCandidate(_ run: RuntimeRunState) -> Bool {
        run.status == "paused" && run.activeCheckpoint != nil
    }

    private func isNewlySurfacedRunCheckpoint(
        _ run: RuntimeRunState,
        previousRunsByID: [RuntimeRunKey: RuntimeRunState],
    ) -> Bool {
        guard let checkpoint = run.activeCheckpoint else { return false }
        guard let previousRun = previousRunsByID[RuntimeRunKey(run: run)] else { return true }
        guard previousRun.status == "paused",
              let previousCheckpoint = previousRun.activeCheckpoint
        else {
            return true
        }

        return previousCheckpoint.id != checkpoint.id
    }

    private func runCheckpointTarget(for run: RuntimeRunState) -> RunCheckpointWindowTarget? {
        guard let checkpoint = run.activeCheckpoint else { return nil }
        return RunCheckpointWindowTarget(
            projectPath: run.projectPath,
            runID: run.id,
            checkpointID: checkpoint.id,
        )
    }

    private func runCheckpointCandidatePrecedes(
        _ lhs: RuntimeRunState,
        _ rhs: RuntimeRunState,
    ) -> Bool {
        let lhsCreatedAt = lhs.activeCheckpoint?.createdAt ?? lhs.createdAt
        let rhsCreatedAt = rhs.activeCheckpoint?.createdAt ?? rhs.createdAt

        switch (parseISO8601Date(lhsCreatedAt), parseISO8601Date(rhsCreatedAt)) {
        case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhsCreatedAt != rhsCreatedAt {
                return lhsCreatedAt < rhsCreatedAt
            }
        }

        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }

        return PathNormalizer.normalize(lhs.projectPath) < PathNormalizer.normalize(rhs.projectPath)
    }

    private func activeIdeaRunPrecedes(
        _ lhs: RuntimeRunState,
        _ rhs: RuntimeRunState,
    ) -> Bool {
        switch (parseISO8601Date(lhs.updatedAt), parseISO8601Date(rhs.updatedAt)) {
        case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
        }

        switch (parseISO8601Date(lhs.createdAt), parseISO8601Date(rhs.createdAt)) {
        case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
        }

        return lhs.id < rhs.id
    }

    private func hasCheckpointTimelineHistory(_ run: RuntimeRunState) -> Bool {
        !run.pastCheckpoints.isEmpty || run.activeCheckpoint != nil
    }

    private func checkpointTimelineRunPrecedes(
        _ lhs: RuntimeRunState,
        _ rhs: RuntimeRunState,
    ) -> Bool {
        let lhsEventTimestamp = latestCheckpointEventTimestamp(for: lhs)
        let rhsEventTimestamp = latestCheckpointEventTimestamp(for: rhs)
        let eventComparison = compareOptionalRunTimestamps(lhsEventTimestamp, rhsEventTimestamp)
        if eventComparison != .orderedSame {
            return eventComparison == .orderedDescending
        }

        let updatedComparison = compareRunTimestamps(lhs.updatedAt, rhs.updatedAt)
        if updatedComparison != .orderedSame {
            return updatedComparison == .orderedDescending
        }

        let createdComparison = compareRunTimestamps(lhs.createdAt, rhs.createdAt)
        if createdComparison != .orderedSame {
            return createdComparison == .orderedDescending
        }

        return lhs.id < rhs.id
    }

    private func latestCheckpointEventTimestamp(for run: RuntimeRunState) -> String? {
        let archivedTimestamps = run.pastCheckpoints.map { $0.decidedAt ?? $0.createdAt }
        let activeTimestamp = run.activeCheckpoint?.createdAt
        return (archivedTimestamps + [activeTimestamp].compactMap { $0 })
            .max(by: { compareRunTimestamps($0, $1) == .orderedAscending })
    }

    private func compareOptionalRunTimestamps(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            compareRunTimestamps(lhs, rhs)
        case (.some, .none):
            .orderedDescending
        case (.none, .some):
            .orderedAscending
        case (.none, .none):
            .orderedSame
        }
    }

    private func compareRunTimestamps(_ lhs: String, _ rhs: String) -> ComparisonResult {
        switch (parseISO8601Date(lhs), parseISO8601Date(rhs)) {
        case let (.some(lhsDate), .some(rhsDate)):
            if lhsDate > rhsDate {
                return .orderedDescending
            }
            if lhsDate < rhsDate {
                return .orderedAscending
            }
            return .orderedSame
        case (.some, .none):
            return .orderedDescending
        case (.none, .some):
            return .orderedAscending
        case (.none, .none):
            return lhs.compare(rhs)
        }
    }

    private func runCheckpointState(
        target: RunCheckpointWindowTarget,
        runsByID: [RuntimeRunKey: RuntimeRunState],
    ) -> RuntimeCheckpointState? {
        guard let run = runsByID[RuntimeRunKey(projectPath: target.projectPath, runID: target.runID)],
              run.status == "paused",
              let checkpoint = run.activeCheckpoint,
              checkpoint.id == target.checkpointID
        else {
            return nil
        }

        return checkpoint
    }
}
