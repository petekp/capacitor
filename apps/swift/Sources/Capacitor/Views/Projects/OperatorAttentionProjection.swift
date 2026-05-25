import Foundation

struct OperatorAttentionSummary: Equatable {
    var needsYou: [OperatorAttentionItem] = []
    var runningNormally: [OperatorAttentionItem] = []
    var recentlyChanged: [OperatorAttentionItem] = []
    var dormant: [OperatorAttentionItem] = []
    var exceptions: [OperatorAttentionItem] = []
}

struct OperatorAttentionItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case checkpoint
        case delegationReview
        case completedRun
        case completedReceipt
        case failedRun
        case failedReceipt
        case runningRun
        case runningReceipt
        case runningSession
        case staleRun
        case staleSession
        case dormantProject
    }

    let id: String
    let kind: Kind
    let projectPath: String
    let title: String
    let reason: String
    let ageLabel: String?
    let recommendedAction: String?
    let lastChangedAt: Date?
    let target: OperatorAttentionTarget

    init(
        id: String,
        kind: Kind,
        projectPath: String,
        title: String,
        reason: String,
        ageLabel: String?,
        recommendedAction: String?,
        lastChangedAt: Date? = nil,
        target: OperatorAttentionTarget,
    ) {
        self.id = id
        self.kind = kind
        self.projectPath = projectPath
        self.title = title
        self.reason = reason
        self.ageLabel = ageLabel
        self.recommendedAction = recommendedAction
        self.lastChangedAt = lastChangedAt
        self.target = target
    }
}

enum OperatorAttentionTarget: Equatable {
    case project(path: String)
    case run(id: String, projectPath: String)
    case checkpoint(runID: String, checkpointID: String, projectPath: String)
    case receiptProof(runID: String, projectPath: String)
    case session(id: String?, projectPath: String)
}

enum OperatorAttentionProjection {
    static func build(
        projects: [Project],
        runsByID: [RuntimeRunKey: RuntimeRunState] = [:],
        delegationStatesByProjectPath: [String: RuntimeDelegationState] = [:],
        sessionStatesByProjectPath: [String: ProjectSessionState] = [:],
        receiptRunsByProjectPath: [String: ReceiptLoopRunState] = [:],
        dormantProjectPaths: Set<String> = [],
        now: Date = Date(),
    ) -> OperatorAttentionSummary {
        let normalizedSessionStates = Dictionary(
            sessionStatesByProjectPath.map {
                (PathNormalizer.normalize($0.key), $0.value)
            },
            uniquingKeysWith: { first, _ in first },
        )
        let normalizedDelegationStates = Dictionary(
            delegationStatesByProjectPath.map {
                (PathNormalizer.normalize($0.key), $0.value)
            },
            uniquingKeysWith: { first, _ in first },
        )
        let normalizedReceiptRuns = Dictionary(
            receiptRunsByProjectPath.map {
                (PathNormalizer.normalize($0.key), $0.value)
            },
            uniquingKeysWith: { first, _ in first },
        )
        let normalizedDormantPaths = Set(dormantProjectPaths.map(PathNormalizer.normalize))
        let runs = Array(runsByID.values)
        let latestReceiptProofRunID = latestReceiptProofRunID(
            in: Array(normalizedReceiptRuns.values),
            now: now,
        )

        let candidates = projects
            .filter { !$0.isMissing }
            .compactMap { project -> Candidate? in
                candidate(
                    for: project,
                    runs: runs,
                    delegationState: normalizedDelegationStates[PathNormalizer.normalize(project.path)],
                    sessionState: normalizedSessionStates[PathNormalizer.normalize(project.path)],
                    receiptRun: normalizedReceiptRuns[PathNormalizer.normalize(project.path)],
                    latestReceiptProofRunID: latestReceiptProofRunID,
                    dormantProjectPaths: normalizedDormantPaths,
                    now: now,
                )
            }

        return OperatorAttentionSummary(
            needsYou: sort(candidates, in: .needsYou).map(\.item),
            runningNormally: sort(candidates, in: .runningNormally).map(\.item),
            recentlyChanged: sort(candidates, in: .recentlyChanged).map(\.item),
            dormant: sort(candidates, in: .dormant).map(\.item),
            exceptions: sort(candidates, in: .exceptions).map(\.item),
        )
    }

    private enum Category {
        case needsYou
        case runningNormally
        case recentlyChanged
        case dormant
        case exceptions
    }

    private struct Candidate {
        let category: Category
        let item: OperatorAttentionItem
        let sortDate: Date?
        let newestFirst: Bool
    }

    private static func candidate(
        for project: Project,
        runs: [RuntimeRunState],
        delegationState: RuntimeDelegationState?,
        sessionState: ProjectSessionState?,
        receiptRun: ReceiptLoopRunState?,
        latestReceiptProofRunID: String?,
        dormantProjectPaths: Set<String>,
        now: Date,
    ) -> Candidate? {
        let normalizedProjectPath = PathNormalizer.normalize(project.path)
        let projectRuns = runs.filter {
            PathNormalizer.normalize($0.projectPath) == normalizedProjectPath
        }

        if let checkpointRun = oldestPausedCheckpointRun(projectRuns),
           let checkpoint = checkpointRun.activeCheckpoint
        {
            let lastChangedAt = parseISO8601Date(checkpoint.createdAt)
            return Candidate(
                category: .needsYou,
                item: OperatorAttentionItem(
                    id: "checkpoint:\(normalizedProjectPath):\(checkpointRun.id):\(checkpoint.id)",
                    kind: .checkpoint,
                    projectPath: project.path,
                    title: checkpoint.title,
                    reason: cleaned(checkpoint.summary) ?? "Agent needs direction before continuing",
                    ageLabel: nil,
                    recommendedAction: "Review brief",
                    lastChangedAt: lastChangedAt,
                    target: .checkpoint(
                        runID: checkpointRun.id,
                        checkpointID: checkpoint.id,
                        projectPath: project.path,
                    ),
                ),
                sortDate: lastChangedAt,
                newestFirst: false,
            )
        }

        if let delegationState,
           delegationState.currentReview != nil,
           delegationState.status == "review_needed" || delegationState.status == "resume_failed"
        {
            let lastChangedAt = delegationState.currentReview.flatMap { parseISO8601Date($0.requestedAt) }
                ?? parseISO8601Date(delegationState.updatedAt)
            return Candidate(
                category: .needsYou,
                item: OperatorAttentionItem(
                    id: "delegation-review:\(normalizedProjectPath):\(delegationState.workerId)",
                    kind: .delegationReview,
                    projectPath: project.path,
                    title: project.name,
                    reason: delegationState.status == "resume_failed"
                        ? "Worker resume failed and review is ready to retry"
                        : "Worker needs a decision before continuing",
                    ageLabel: nil,
                    recommendedAction: delegationState.status == "resume_failed" ? "Retry review" : "Review brief",
                    lastChangedAt: lastChangedAt,
                    target: .project(path: project.path),
                ),
                sortDate: lastChangedAt,
                newestFirst: false,
            )
        }

        if let failedRun = selectedRun(
            in: projectRuns,
            matching: { visualState, _ in
                if case .failed = visualState { return true }
                return false
            },
            now: now,
        ) {
            return runCandidate(
                category: .exceptions,
                kind: .failedRun,
                project: project,
                run: failedRun.run,
                visualState: failedRun.visualState,
                fallbackReason: "Run failed",
                recommendedAction: "Inspect run",
                newestFirst: true,
            )
        }

        if let receiptRun,
           receiptRun.status == .failed,
           isReceiptTerminalVisible(receiptRun, now: now)
        {
            return receiptCandidate(
                category: .exceptions,
                kind: .failedReceipt,
                project: project,
                receiptRun: receiptRun,
                recommendedAction: "Inspect terminal",
                opensReceiptProof: false,
                newestFirst: true,
            )
        }

        if let staleRun = projectRuns
            .filter({ $0.status == "active" && SessionStaleness.isRunFreshnessExpired(updatedAt: $0.updatedAt, now: now) })
            .sorted(by: runPrecedesByUpdatedDescending)
            .first
        {
            let lastChangedAt = parseISO8601Date(staleRun.updatedAt)
            return Candidate(
                category: .exceptions,
                item: OperatorAttentionItem(
                    id: "stale-run:\(normalizedProjectPath):\(staleRun.id)",
                    kind: .staleRun,
                    projectPath: project.path,
                    title: project.name,
                    reason: "Run marked active with no recent update",
                    ageLabel: nil,
                    recommendedAction: "Inspect terminal",
                    lastChangedAt: lastChangedAt,
                    target: .run(id: staleRun.id, projectPath: project.path),
                ),
                sortDate: lastChangedAt,
                newestFirst: false,
            )
        }

        if let sessionState,
           SessionStaleness.isSessionEffectivelyDead(
               isAlive: nil,
               state: sessionState.state,
               updatedAt: sessionState.updatedAt,
               now: now,
           )
        {
            let lastChangedAt = sessionState.updatedAt.flatMap(parseISO8601Date)
            return Candidate(
                category: .exceptions,
                item: OperatorAttentionItem(
                    id: "stale-session:\(normalizedProjectPath):\(sessionState.sessionId ?? "unknown")",
                    kind: .staleSession,
                    projectPath: project.path,
                    title: project.name,
                    reason: "Session looks stale",
                    ageLabel: nil,
                    recommendedAction: "Inspect terminal",
                    lastChangedAt: lastChangedAt,
                    target: .session(id: sessionState.sessionId, projectPath: project.path),
                ),
                sortDate: lastChangedAt,
                newestFirst: false,
            )
        }

        let visualResolution = ProjectRunVisualStateResolver.resolve(
            projectPath: project.path,
            runsByID: Dictionary(
                projectRuns.map { (RuntimeRunKey(run: $0), $0) },
                uniquingKeysWith: { first, _ in first },
            ),
            now: now,
        )

        if case .working = visualResolution.visualState,
           let run = visualResolution.run
        {
            return runCandidate(
                category: .runningNormally,
                kind: .runningRun,
                project: project,
                run: run,
                visualState: visualResolution.visualState,
                fallbackReason: "Run is active",
                recommendedAction: nil,
                newestFirst: true,
            )
        }

        if let receiptRun, receiptRun.status == .running {
            return receiptCandidate(
                category: .runningNormally,
                kind: .runningReceipt,
                project: project,
                receiptRun: receiptRun,
                recommendedAction: nil,
                opensReceiptProof: false,
                newestFirst: true,
            )
        }

        if let sessionState,
           sessionState.hasSession,
           isHealthyRunningSession(sessionState)
        {
            let lastChangedAt = sessionState.updatedAt.flatMap(parseISO8601Date)
            return Candidate(
                category: .runningNormally,
                item: OperatorAttentionItem(
                    id: "running-session:\(normalizedProjectPath):\(sessionState.sessionId ?? "unknown")",
                    kind: .runningSession,
                    projectPath: project.path,
                    title: project.name,
                    reason: cleaned(sessionState.workingOn) ?? "Session is active",
                    ageLabel: nil,
                    recommendedAction: nil,
                    lastChangedAt: lastChangedAt,
                    target: .session(id: sessionState.sessionId, projectPath: project.path),
                ),
                sortDate: lastChangedAt,
                newestFirst: true,
            )
        }

        if case .completed = visualResolution.visualState,
           let run = visualResolution.run
        {
            return runCandidate(
                category: .recentlyChanged,
                kind: .completedRun,
                project: project,
                run: run,
                visualState: visualResolution.visualState,
                fallbackReason: ProjectCompletionBriefProjection.attentionReason(for: run),
                recommendedAction: ProjectCompletionBriefProjection.operatorRecommendedAction,
                newestFirst: true,
            )
        }

        if let receiptRun,
           receiptRun.status == .completed,
           isReceiptTerminalVisible(receiptRun, now: now)
        {
            return receiptCandidate(
                category: .recentlyChanged,
                kind: .completedReceipt,
                project: project,
                receiptRun: receiptRun,
                recommendedAction: receiptRun.id == latestReceiptProofRunID ? "Show receipt" : nil,
                opensReceiptProof: receiptRun.id == latestReceiptProofRunID,
                newestFirst: true,
            )
        }

        return Candidate(
            category: .dormant,
            item: OperatorAttentionItem(
                id: "dormant:\(normalizedProjectPath)",
                kind: .dormantProject,
                projectPath: project.path,
                title: project.name,
                reason: dormantProjectPaths.contains(normalizedProjectPath)
                    ? "Dormant"
                    : "No active run or session",
                ageLabel: nil,
                recommendedAction: nil,
                lastChangedAt: nil,
                target: .project(path: project.path),
            ),
            sortDate: nil,
            newestFirst: false,
        )
    }

    private static func receiptCandidate(
        category: Category,
        kind: OperatorAttentionItem.Kind,
        project: Project,
        receiptRun: ReceiptLoopRunState,
        recommendedAction: String?,
        opensReceiptProof: Bool,
        newestFirst: Bool,
    ) -> Candidate {
        let lastChangedAt = parseISO8601Date(receiptRun.updatedAt)
        return Candidate(
            category: category,
            item: OperatorAttentionItem(
                id: "\(kind):\(PathNormalizer.normalize(project.path)):\(receiptRun.id)",
                kind: kind,
                projectPath: project.path,
                title: project.name,
                reason: receiptRun.attentionReason,
                ageLabel: nil,
                recommendedAction: recommendedAction,
                lastChangedAt: lastChangedAt,
                target: opensReceiptProof
                    ? .receiptProof(runID: receiptRun.id, projectPath: project.path)
                    : .run(id: receiptRun.id, projectPath: project.path),
            ),
            sortDate: lastChangedAt,
            newestFirst: newestFirst,
        )
    }

    private static func latestReceiptProofRunID(
        in receiptRuns: [ReceiptLoopRunState],
        now: Date,
    ) -> String? {
        receiptRuns
            .filter { $0.status == .completed && isReceiptTerminalVisible($0, now: now) }
            .sorted { lhs, rhs in
                let comparison = compareTimestamps(lhs.updatedAt, rhs.updatedAt)
                if comparison != .orderedSame {
                    return comparison == .orderedDescending
                }
                return lhs.id < rhs.id
            }
            .first?
            .id
    }

    private static func isReceiptTerminalVisible(
        _ receiptRun: ReceiptLoopRunState,
        now: Date,
    ) -> Bool {
        switch receiptRun.status {
        case .running:
            return true
        case .completed, .failed:
            guard let updatedAt = parseISO8601Date(receiptRun.updatedAt) else { return false }
            return now.timeIntervalSince(updatedAt) <= 60 * 60
        }
    }

    private static func oldestPausedCheckpointRun(_ runs: [RuntimeRunState]) -> RuntimeRunState? {
        runs
            .filter { $0.status == "paused" && $0.activeCheckpoint != nil }
            .sorted { lhs, rhs in
                let comparison = compareTimestamps(
                    lhs.activeCheckpoint?.createdAt ?? lhs.updatedAt,
                    rhs.activeCheckpoint?.createdAt ?? rhs.updatedAt,
                )
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                return lhs.id < rhs.id
            }
            .first
    }

    private static func selectedRun(
        in runs: [RuntimeRunState],
        matching predicate: (RunVisualState, RuntimeRunState) -> Bool,
        now: Date,
    ) -> (run: RuntimeRunState, visualState: RunVisualState)? {
        runs
            .compactMap { run -> (run: RuntimeRunState, visualState: RunVisualState)? in
                let visualState = ProjectRunVisualStateResolver.visualState(for: run, now: now)
                guard predicate(visualState, run) else { return nil }
                return (run, visualState)
            }
            .sorted { lhs, rhs in
                runPrecedesByUpdatedDescending(lhs.run, rhs.run)
            }
            .first
    }

    private static func runCandidate(
        category: Category,
        kind: OperatorAttentionItem.Kind,
        project: Project,
        run: RuntimeRunState,
        visualState: RunVisualState,
        fallbackReason: String,
        recommendedAction: String?,
        newestFirst: Bool,
    ) -> Candidate {
        let lastChangedAt = parseISO8601Date(run.updatedAt)
        return Candidate(
            category: category,
            item: OperatorAttentionItem(
                id: "\(kind):\(PathNormalizer.normalize(project.path)):\(run.id)",
                kind: kind,
                projectPath: project.path,
                title: project.name,
                reason: ProjectCardContextLineResolver.runContextText(
                    runVisualState: visualState,
                    activeRunState: run,
                ) ?? fallbackReason,
                ageLabel: nil,
                recommendedAction: recommendedAction,
                lastChangedAt: lastChangedAt,
                target: .run(id: run.id, projectPath: project.path),
            ),
            sortDate: lastChangedAt,
            newestFirst: newestFirst,
        )
    }

    private static func sort(
        _ candidates: [Candidate],
        in category: Category,
    ) -> [Candidate] {
        candidates
            .filter { $0.category == category }
            .sorted { lhs, rhs in
                if lhs.newestFirst != rhs.newestFirst {
                    return !lhs.newestFirst
                }

                switch (lhs.sortDate, rhs.sortDate) {
                case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
                    return lhs.newestFirst ? lhsDate > rhsDate : lhsDate < rhsDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    if lhs.item.title != rhs.item.title {
                        return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
                    }
                    return lhs.item.id < rhs.item.id
                }
            }
    }

    private static func isHealthyRunningSession(_ sessionState: ProjectSessionState) -> Bool {
        switch sessionState.state {
        case .working, .waiting, .compacting:
            true
        case .ready, .idle:
            false
        }
    }

    private static func runPrecedesByUpdatedDescending(
        _ lhs: RuntimeRunState,
        _ rhs: RuntimeRunState,
    ) -> Bool {
        let comparison = compareTimestamps(lhs.updatedAt, rhs.updatedAt)
        if comparison != .orderedSame {
            return comparison == .orderedDescending
        }
        return lhs.id < rhs.id
    }

    private static func compareTimestamps(_ lhs: String, _ rhs: String) -> ComparisonResult {
        switch (parseISO8601Date(lhs), parseISO8601Date(rhs)) {
        case let (.some(lhsDate), .some(rhsDate)):
            if lhsDate < rhsDate {
                return .orderedAscending
            }
            if lhsDate > rhsDate {
                return .orderedDescending
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

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
