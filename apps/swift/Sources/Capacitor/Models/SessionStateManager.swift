import Foundation
import SwiftUI

/// Projects runtime service snapshot state into the UI-facing session model for projects.
///
/// Rust remains authoritative for hook ingest, reducer/query policy, and persisted runtime
/// artifact contents. This layer owns the deterministic Swift-side projection rules that turn
/// runtime service project states into view state:
/// - project/session matching and attribution
/// - stale-working normalization using the injected session clock
/// - empty-snapshot and idle-transition hysteresis
/// - visual change detection for animation triggers
@Observable
@MainActor
final class SessionStateManager {
    struct SessionAttribution: Equatable {
        enum Scope: Equatable {
            case direct
            case repoFallback
        }

        let scope: Scope
        let sourceProjectPath: String
        let sourceSessionId: String?
    }

    private struct MergeResult {
        let states: [String: ProjectSessionState]
        let attributions: [String: SessionAttribution]
        let latestSessionIds: [String: String]
    }

    private struct ProjectMatchInfo {
        let project: Project
        let normalizedPath: String
        let depth: Int
        let repoInfo: GitRepositoryInfo?
        let workspaceId: String
    }

    private struct StateMatchInfo {
        let state: RuntimeProjectState
        let normalizedPath: String
        let repoInfo: GitRepositoryInfo?
        let workspaceId: String
    }

    private enum MatchPriority: Int {
        case repoFallback = 0
        case direct = 1
    }

    private struct BestProjectState {
        let state: RuntimeProjectState
        let priority: MatchPriority
        let representativePid: UInt32?
        let isAlive: Bool?
    }

    private enum Constants {
        static let flashDurationSeconds: TimeInterval = 1.4
        static let emptySnapshotCommitThreshold = 2
        /// Consecutive idle snapshots required before committing an active→idle transition.
        /// At 2s polling, threshold of 2 means a 4s hold before showing idle.
        static let idleCommitThreshold = 2
        /// Consecutive Ready snapshots required before committing a Working→Ready transition.
        /// At 50ms long-poll, threshold of 2 means ~100ms hold before showing Ready.
        static let readyCommitThreshold = 2
    }

    @ObservationIgnored var onVisualStateChanged: (() -> Void)?

    private(set) var sessionStates: [String: ProjectSessionState] = [:] {
        didSet {
            guard sessionStates != oldValue else { return }
            onVisualStateChanged?()
        }
    }

    private(set) var flashingProjects: [String: SessionState] = [:] {
        didSet {
            guard flashingProjects != oldValue else { return }
            onVisualStateChanged?()
        }
    }

    private(set) var sessionAttributions: [String: SessionAttribution] = [:]
    private(set) var latestSessionIds: [String: String] = [:]

    private var previousSessionStates: [String: SessionState] = [:]
    private var consecutiveEmptySnapshotCount = 0
    /// Per-project consecutive idle snapshot count for hysteresis stabilization.
    private var consecutiveIdleCounts: [String: Int] = [:]
    /// Per-project consecutive Ready snapshot count for Working→Ready hysteresis.
    private var consecutiveReadyCounts: [String: Int] = [:]
    private var applyGeneration: UInt64 = 0
    private var refreshCorrelationCounter: UInt64 = 0
    private let clock: SessionClock
    private let checkProcessLiveness: ProcessLivenessChecker

    init(clock: SessionClock = .live, processLiveness: ProcessLivenessChecker? = nil) {
        self.clock = clock
        checkProcessLiveness = processLiveness ?? ProcessLiveness.checker
    }

    /// Applies runtime project states directly without initiating a network refresh.
    /// Used by the consolidated AppSnapshot tick in AppState.
    func applyRuntimeProjectStates(
        _ runtimeProjects: [RuntimeProjectState],
        sessions: [RuntimeSession] = [],
        for projects: [Project],
        correlationId: String? = nil,
    ) {
        applyGeneration &+= 1
        let cid = correlationId ?? nextRefreshCorrelationId()
        let sessionIndex = Dictionary(
            sessions.map { ($0.sessionId, $0) },
            uniquingKeysWith: { first, _ in first },
        )
        applyRuntimeProjectStatesInternal(
            runtimeProjects,
            sessionIndex: sessionIndex,
            projects: projects,
            correlationId: cid,
            requestGeneration: applyGeneration,
        )
    }

    private func nextRefreshCorrelationId() -> String {
        refreshCorrelationCounter &+= 1
        return "ssm-\(refreshCorrelationCounter)"
    }

    private func applyRuntimeProjectStatesInternal(
        _ runtimeProjects: [RuntimeProjectState],
        sessionIndex: [String: RuntimeSession],
        projects: [Project],
        correlationId: String,
        requestGeneration: UInt64,
    ) {
        let mergeResult = mergeRuntimeProjectStates(runtimeProjects, sessionIndex: sessionIndex, projects: projects, now: clock.now(), processLiveness: checkProcessLiveness)
        let merged = mergeResult.states
        let emptyStabilized = stabilizeEmptyRuntimeSnapshotIfNeeded(merged)
        let idleStabilized = stabilizeIdleTransitions(emptyStabilized)
        let stabilized = stabilizeWorkingToReadyTransitions(idleStabilized)
        let heldPaths = Set(stabilized.keys.filter { stabilized[$0] != merged[$0] })
        var nextAttributions = mergeResult.attributions
        var nextLatestSessionIds = mergeResult.latestSessionIds
        for path in heldPaths {
            if let previousAttribution = sessionAttributions[path] {
                nextAttributions[path] = previousAttribution
            } else {
                nextAttributions.removeValue(forKey: path)
            }

            if let previousLatest = latestSessionIds[path] {
                nextLatestSessionIds[path] = previousLatest
            } else {
                nextLatestSessionIds.removeValue(forKey: path)
            }
        }
        DebugLog.write(
            "SessionStateManager.refresh cid=\(correlationId) action=fetch_success generation=\(requestGeneration) runtime_count=\(runtimeProjects.count)",
        )
        if !merged.isEmpty {
            let summary = merged
                .map { "\($0.key) state=\($0.value.state) updated=\($0.value.updatedAt ?? "nil") session=\($0.value.sessionId ?? "nil")" }
                .sorted()
                .joined(separator: " | ")
            DebugLog.write("SessionStateManager.merge cid=\(correlationId) summary=\(summary)")
        } else {
            DebugLog.write("SessionStateManager.merge cid=\(correlationId) summary=empty")
        }
        let didChange = stabilized != sessionStates
        if didChange {
            withAnimation(.spring(response: GlassConfig.shared.cardReorderSpringResponse, dampingFraction: GlassConfig.shared.cardReorderSpringDamping)) {
                self.sessionStates = stabilized
            }
        }
        sessionAttributions = nextAttributions.filter { stabilized[$0.key] != nil }
        latestSessionIds = nextLatestSessionIds.filter { stabilized[$0.key] != nil }
        pruneCachedStates()
        DiagnosticsSnapshotLogger.maybeCaptureStuckSessions(sessionStates: stabilized)
        if didChange {
            checkForStateChanges()
        }
    }

    private func stabilizeEmptyRuntimeSnapshotIfNeeded(
        _ merged: [String: ProjectSessionState],
    ) -> [String: ProjectSessionState] {
        if merged.isEmpty {
            guard !sessionStates.isEmpty else {
                consecutiveEmptySnapshotCount = 0
                logEmptySnapshotDecision(
                    decision: "commit_empty_no_existing_state",
                    mergedCount: merged.count,
                    stabilizedCount: merged.count,
                )
                return merged
            }

            consecutiveEmptySnapshotCount += 1
            if consecutiveEmptySnapshotCount < Constants.emptySnapshotCommitThreshold {
                logEmptySnapshotDecision(
                    decision: "hold_empty_snapshot",
                    mergedCount: merged.count,
                    stabilizedCount: sessionStates.count,
                )
                return sessionStates
            }

            logEmptySnapshotDecision(
                decision: "commit_empty_snapshot",
                mergedCount: merged.count,
                stabilizedCount: merged.count,
            )
            consecutiveEmptySnapshotCount = 0
            return merged
        }

        let hadPendingEmptyHold = consecutiveEmptySnapshotCount > 0
        consecutiveEmptySnapshotCount = 0
        if hadPendingEmptyHold {
            logEmptySnapshotDecision(
                decision: "commit_non_empty_reset_hold",
                mergedCount: merged.count,
                stabilizedCount: merged.count,
            )
        }
        return merged
    }

    /// Stabilizes active→idle transitions using asymmetric hysteresis.
    ///
    /// A project must show as idle for `idleCommitThreshold` consecutive snapshots
    /// before the idle state is committed to the UI. Transitions from idle back to
    /// active are instant (no hold). This prevents brief idle flickers caused by
    /// transient gaps in the hook event pipeline (e.g., SessionEnd → SessionStart).
    private func stabilizeIdleTransitions(
        _ incoming: [String: ProjectSessionState],
    ) -> [String: ProjectSessionState] {
        var result = incoming

        for (path, incomingState) in incoming {
            let isIncomingIdle = incomingState.state == .idle
            let wasActive = sessionStates[path].map { $0.state != .idle } ?? false

            if isIncomingIdle, wasActive {
                let count = (consecutiveIdleCounts[path] ?? 0) + 1
                consecutiveIdleCounts[path] = count

                if count < Constants.idleCommitThreshold {
                    // Hold previous active state
                    result[path] = sessionStates[path]!
                    DebugLog.write(
                        "SessionStateManager.idleStabilize action=hold project=\(path) count=\(count)/\(Constants.idleCommitThreshold)",
                    )
                } else {
                    // Threshold reached — commit the idle transition
                    consecutiveIdleCounts[path] = 0
                    DebugLog.write(
                        "SessionStateManager.idleStabilize action=commit project=\(path) count=\(count)",
                    )
                }
            } else {
                if consecutiveIdleCounts[path] != nil, consecutiveIdleCounts[path] != 0 {
                    DebugLog.write(
                        "SessionStateManager.idleStabilize action=reset project=\(path) (became \(incomingState.state))",
                    )
                }
                consecutiveIdleCounts[path] = 0
            }
        }

        // Prune counts for projects no longer in the snapshot
        consecutiveIdleCounts = consecutiveIdleCounts.filter { result[$0.key] != nil }

        return result
    }

    /// Stabilizes Working→Ready transitions using asymmetric hysteresis.
    ///
    /// A project must show as Ready for `readyCommitThreshold` consecutive snapshots
    /// before the Ready state is committed to the UI, but ONLY when the previous
    /// committed state was Working. Transitions from Ready back to Working are
    /// instant (no hold). This prevents brief Ready flickers caused by inter-tool
    /// gaps in agentic workflows.
    private func stabilizeWorkingToReadyTransitions(
        _ incoming: [String: ProjectSessionState],
    ) -> [String: ProjectSessionState] {
        var result = incoming

        for (path, incomingState) in incoming {
            let isIncomingReady = incomingState.state == .ready
            let wasWorking = sessionStates[path].map { $0.state == .working } ?? false

            if isIncomingReady, wasWorking {
                let count = (consecutiveReadyCounts[path] ?? 0) + 1
                consecutiveReadyCounts[path] = count

                if count < Constants.readyCommitThreshold {
                    // Hold previous Working state
                    result[path] = sessionStates[path]!
                    DebugLog.write(
                        "SessionStateManager.readyStabilize action=hold project=\(path) count=\(count)/\(Constants.readyCommitThreshold)",
                    )
                } else {
                    // Threshold reached — commit the Ready transition
                    consecutiveReadyCounts[path] = 0
                    DebugLog.write(
                        "SessionStateManager.readyStabilize action=commit project=\(path) count=\(count)",
                    )
                }
            } else {
                if consecutiveReadyCounts[path] != nil, consecutiveReadyCounts[path] != 0 {
                    DebugLog.write(
                        "SessionStateManager.readyStabilize action=reset project=\(path) (became \(incomingState.state))",
                    )
                }
                consecutiveReadyCounts[path] = 0
            }
        }

        // Prune counts for projects no longer in the snapshot
        consecutiveReadyCounts = consecutiveReadyCounts.filter { result[$0.key] != nil }

        return result
    }

    private func logEmptySnapshotDecision(
        decision: String,
        mergedCount: Int,
        stabilizedCount: Int,
    ) {
        let existingCount = sessionStates.count
        DebugLog.write(
            "SessionStateManager.emptySnapshot decision=\(decision) consecutiveEmpty=\(consecutiveEmptySnapshotCount) mergedCount=\(mergedCount) existingCount=\(existingCount) appliedCount=\(stabilizedCount)",
        )
        Telemetry.emit(
            "session_state_empty_snapshot",
            decision,
            payload: [
                "decision": decision,
                "consecutive_empty_count": consecutiveEmptySnapshotCount,
                "merged_count": mergedCount,
                "existing_count": existingCount,
                "applied_count": stabilizedCount,
            ],
        )
    }

    // MARK: - Flash Animation

    private func checkForStateChanges() {
        for (path, sessionState) in sessionStates {
            let current = sessionState.state
            if let previous = previousSessionStates[path], previous != current {
                triggerFlashIfNeeded(for: path, state: current)
            }
            previousSessionStates[path] = current
        }
    }

    private func pruneCachedStates() {
        let active = Set(sessionStates.keys)
        previousSessionStates = previousSessionStates.filter { active.contains($0.key) }
        flashingProjects = flashingProjects.filter { active.contains($0.key) }
        sessionAttributions = sessionAttributions.filter { active.contains($0.key) }
        latestSessionIds = latestSessionIds.filter { active.contains($0.key) }
    }

    private func triggerFlashIfNeeded(for path: String, state: SessionState) {
        switch state {
        case .ready, .waiting, .compacting:
            flashingProjects[path] = state
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.flashDurationSeconds) { [weak self] in
                self?.flashingProjects.removeValue(forKey: path)
            }
        case .working, .idle:
            break
        }
    }

    func isFlashing(_ project: Project) -> SessionState? {
        flashingProjects[project.path]
    }

    // MARK: - State Retrieval

    func getSessionState(for project: Project) -> ProjectSessionState? {
        if let direct = sessionStates[project.path] {
            return direct
        }

        let normalizedPath = PathNormalizer.normalize(project.path)
        return sessionStates.first(where: { PathNormalizer.normalize($0.key) == normalizedPath })?.value
    }

    func getPreferredSessionId(for project: Project) -> String? {
        if let direct = latestSessionIds[project.path] {
            return direct
        }

        let normalizedPath = PathNormalizer.normalize(project.path)
        if let fallback = latestSessionIds.first(where: { PathNormalizer.normalize($0.key) == normalizedPath })?.value {
            return fallback
        }

        return getSessionState(for: project)?.sessionId
    }

    private nonisolated func mergeRuntimeProjectStates(
        _ states: [RuntimeProjectState],
        sessionIndex: [String: RuntimeSession],
        projects: [Project],
        now: Date,
        processLiveness: ProcessLivenessChecker,
    ) -> MergeResult {
        let homeNormalized = PathNormalizer.normalize(NSHomeDirectory())
        var projectInfos: [ProjectMatchInfo] = []
        var seen: Set<String> = []

        for project in projects {
            let normalized = PathNormalizer.normalize(project.path)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            let depth = normalized.split(separator: "/").count
            let repoInfo = GitRepositoryInfo.resolve(for: project.path)
            let workspaceId = repoInfo.map { WorkspaceIdentity.fromGitInfo($0) }
                ?? WorkspaceIdentity.fromPath(project.path)
            projectInfos.append(
                ProjectMatchInfo(
                    project: project,
                    normalizedPath: normalized,
                    depth: depth,
                    repoInfo: repoInfo,
                    workspaceId: workspaceId,
                ),
            )
        }

        let sortedProjects = projectInfos.sorted { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.normalizedPath > rhs.normalizedPath
            }
            return lhs.depth > rhs.depth
        }

        // Index pinned projects by repo identity so we can map runtime activity anywhere in a repo
        // onto pinned workspaces within that repo (common monorepo + worktree case).
        //
        // We prefer the git common dir when available so that different worktrees of the same repo
        // are treated as the same logical project (end-user mental model: "this is the same repo").
        var pinnedProjectsByRepoKey: [String: [ProjectMatchInfo]] = [:]
        for info in projectInfos {
            guard let repoInfo = info.repoInfo else { continue }
            let repoKey = repoInfo.commonDir ?? repoInfo.repoRoot
            pinnedProjectsByRepoKey[repoKey, default: []].append(info)
        }

        var bestStates: [String: BestProjectState] = [:]
        var unmatched: [RuntimeProjectState] = []

        for state in states {
            let normalizedStatePath = PathNormalizer.normalize(state.projectPath)
            let stateRepoInfo = GitRepositoryInfo.resolve(for: state.projectPath)
            let stateWorkspaceId = state.workspaceId
                ?? stateRepoInfo.map { WorkspaceIdentity.fromGitInfo($0) }
                ?? WorkspaceIdentity.fromPath(state.projectPath)
            let stateInfo = StateMatchInfo(
                state: state,
                normalizedPath: normalizedStatePath,
                repoInfo: stateRepoInfo,
                workspaceId: stateWorkspaceId,
            )
            guard let match = sortedProjects.first(where: { info in
                matchesProject(
                    info,
                    state: stateInfo,
                    homeNormalized: homeNormalized,
                )
            }) else {
                // If runtime state reports activity for a different workspace within the same repo,
                // apply that state to pinned workspaces that share a parent-child path relationship
                // with the state's project path. This prevents sibling packages in a monorepo
                // (e.g. /monorepo/packages/api vs /monorepo/packages/web) from cross-pollinating.
                if let repoInfo = stateInfo.repoInfo,
                   let candidates = pinnedProjectsByRepoKey[repoInfo.commonDir ?? repoInfo.repoRoot]
                {
                    for candidate in candidates {
                        // Only apply repo fallback when the state's project is an ancestor
                        // of the candidate (session ran at a broader scope) or the candidate
                        // is an ancestor of the state (session ran inside this project's tree).
                        let candidateNormalized = candidate.normalizedPath
                        guard isParentOrSelfExcludingHome(
                            parent: stateInfo.normalizedPath,
                            child: candidateNormalized,
                            homeNormalized: homeNormalized,
                        ) || isParentOrSelfExcludingHome(
                            parent: candidateNormalized,
                            child: stateInfo.normalizedPath,
                            homeNormalized: homeNormalized,
                        ) else { continue }
                        let projectPath = candidate.project.path
                        let representativeSession = state.sessionId.flatMap { sessionIndex[$0] }
                        let candidateBest = BestProjectState(state: state, priority: .repoFallback, representativePid: representativeSession?.pid, isAlive: representativeSession?.isAlive)
                        if let existing = bestStates[projectPath] {
                            if shouldReplace(existing: existing, with: candidateBest, now: now, processLiveness: processLiveness) {
                                bestStates[projectPath] = candidateBest
                            }
                        } else {
                            bestStates[projectPath] = candidateBest
                        }
                    }
                    continue
                }

                unmatched.append(state)
                continue
            }

            let projectPath = match.project.path
            let representativeSession = state.sessionId.flatMap { sessionIndex[$0] }
            let candidateBest = BestProjectState(state: state, priority: .direct, representativePid: representativeSession?.pid, isAlive: representativeSession?.isAlive)
            if let existing = bestStates[projectPath] {
                if shouldReplace(existing: existing, with: candidateBest, now: now, processLiveness: processLiveness) {
                    bestStates[projectPath] = candidateBest
                }
            } else {
                bestStates[projectPath] = candidateBest
            }
        }

        if !unmatched.isEmpty {
            let sample = unmatched.prefix(3).map { "\($0.projectPath) [\($0.state)]" }.joined(separator: ", ")
            DebugLog.write("SessionStateManager.mergeRuntimeProjectStates unmatched=\(unmatched.count) sample=\(sample)")
        }

        var merged: [String: ProjectSessionState] = [:]
        var attributions: [String: SessionAttribution] = [:]
        var latestSessionIds: [String: String] = [:]
        for (projectPath, best) in bestStates {
            let state = best.state
            let mappedState = normalizedRuntimeState(state, pid: best.representativePid, isAlive: best.isAlive, now: now, processLiveness: processLiveness)
            let sessionState = ProjectSessionState(
                state: mappedState,
                stateChangedAt: state.stateChangedAt,
                updatedAt: state.updatedAt,
                sessionId: state.sessionId,
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: state.hasSession,
            )
            merged[projectPath] = sessionState
            attributions[projectPath] = SessionAttribution(
                scope: best.priority == .direct ? .direct : .repoFallback,
                sourceProjectPath: state.projectPath,
                sourceSessionId: state.sessionId,
            )
            if let latestId = state.latestSessionId ?? state.sessionId {
                latestSessionIds[projectPath] = latestId
            }
        }

        return MergeResult(states: merged, attributions: attributions, latestSessionIds: latestSessionIds)
    }

    private nonisolated func matchesProject(
        _ project: ProjectMatchInfo,
        state: StateMatchInfo,
        homeNormalized: String,
    ) -> Bool {
        if project.workspaceId == state.workspaceId {
            return true
        }

        if isParentOrSelfExcludingHome(
            parent: project.normalizedPath,
            child: state.normalizedPath,
            homeNormalized: homeNormalized,
        ) {
            return true
        }

        guard
            let projectInfo = project.repoInfo,
            let stateInfo = state.repoInfo,
            let projectCommon = projectInfo.commonDir,
            let stateCommon = stateInfo.commonDir,
            projectCommon == stateCommon
        else {
            return false
        }

        let projectRel = projectInfo.relativePath
        let stateRel = stateInfo.relativePath
        if projectRel.isEmpty {
            return true
        }
        if projectRel == stateRel {
            return true
        }
        return stateRel.hasPrefix(projectRel + "/")
    }

    private nonisolated func isParentOrSelfExcludingHome(parent: String, child: String, homeNormalized: String) -> Bool {
        if parent == child {
            return true
        }
        if parent == homeNormalized {
            return false
        }
        return child.hasPrefix(parent + "/")
    }

    private nonisolated func isMoreRecent(_ candidate: RuntimeProjectState, than existing: RuntimeProjectState) -> Bool {
        let candidateTime = parseISO8601Date(candidate.updatedAt) ?? parseISO8601Date(candidate.stateChangedAt)
        let existingTime = parseISO8601Date(existing.updatedAt) ?? parseISO8601Date(existing.stateChangedAt)

        switch (candidateTime, existingTime) {
        case let (candidate?, existing?):
            return candidate > existing
        case (_?, nil):
            return true
        default:
            return false
        }
    }

    private nonisolated func shouldReplace(existing: BestProjectState, with candidate: BestProjectState, now: Date, processLiveness: ProcessLivenessChecker) -> Bool {
        if candidate.priority != existing.priority {
            return candidate.priority.rawValue > existing.priority.rawValue
        }

        // Activity (PID-aware) before recency: an alive working session beats
        // a more-recent ready session. When PID liveness normalizes both to the
        // same activity level, recency breaks the tie as before.
        if candidate.priority == .direct {
            let candidateActivity = stateActivityPriority(candidate.state, pid: candidate.representativePid, isAlive: candidate.isAlive, now: now, processLiveness: processLiveness)
            let existingActivity = stateActivityPriority(existing.state, pid: existing.representativePid, isAlive: existing.isAlive, now: now, processLiveness: processLiveness)
            if candidateActivity != existingActivity {
                return candidateActivity > existingActivity
            }
        }

        let candidateMoreRecent = isMoreRecent(candidate.state, than: existing.state)
        let existingMoreRecent = isMoreRecent(existing.state, than: candidate.state)
        if candidateMoreRecent != existingMoreRecent {
            return candidateMoreRecent
        }

        return false
    }

    private nonisolated func stateActivityPriority(_ state: RuntimeProjectState, pid: UInt32?, isAlive: Bool?, now: Date, processLiveness: ProcessLivenessChecker) -> Int {
        switch normalizedRuntimeState(state, pid: pid, isAlive: isAlive, now: now, processLiveness: processLiveness) {
        case .working, .waiting, .compacting:
            1
        case .ready, .idle:
            0
        }
    }

    private nonisolated func normalizedRuntimeState(_ state: RuntimeProjectState, pid: UInt32?, isAlive: Bool?, now: Date, processLiveness: ProcessLivenessChecker) -> SessionState {
        var mappedState = mapRuntimeState(state.state)
        // Use Rust-computed is_alive (shell corroboration) as the primary liveness signal.
        // Falls back to Swift-side PID check + timestamp staleness when is_alive is nil
        // (runtime service path or pre-migration snapshots).
        if SessionStaleness.isSessionEffectivelyDead(isAlive: isAlive, state: mappedState, updatedAt: state.updatedAt, now: now) {
            // When isAlive is non-nil, isSessionEffectivelyDead only returns true
            // if isAlive==false, so we can downgrade unconditionally.
            // When isAlive is nil (runtime service path), fall back to PID check.
            if isAlive != nil {
                mappedState = .ready
            } else {
                let processAlive = pid.map { processLiveness($0) } ?? false
                if !processAlive {
                    mappedState = .ready
                }
            }
        }
        return mappedState
    }

    private nonisolated func mapRuntimeState(_ state: String) -> SessionState {
        switch state.lowercased() {
        case "working":
            .working
        case "ready":
            .ready
        case "compacting":
            .compacting
        case "waiting":
            .waiting
        case "idle":
            .idle
        default:
            .idle
        }
    }

    func clearRuntimeProjectStates() {
        applyGeneration &+= 1
        consecutiveEmptySnapshotCount = 0
        consecutiveReadyCounts = [:]
        sessionStates = [:]
        sessionAttributions = [:]
        latestSessionIds = [:]
        pruneCachedStates()
        checkForStateChanges()
    }

    #if DEBUG
        /// Test-only helper for deterministic session resolution.
        func setSessionStatesForTesting(_ states: [String: ProjectSessionState]) {
            sessionStates = states
            sessionAttributions = [:]
            latestSessionIds = states.compactMapValues(\.sessionId)
            pruneCachedStates()
            checkForStateChanges()
        }
    #endif
}
