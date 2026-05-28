import Foundation

struct DelegationClaudeLaunchRequest: Equatable {
    let workingDirectory: String
    let prompt: String
    let resumeSessionID: String?

    var arguments: [String] {
        Self.arguments(prompt: prompt, resumeSessionID: resumeSessionID)
    }

    static func arguments(prompt _: String, resumeSessionID: String?) -> [String] {
        var arguments = [
            "-p",
            "--output-format",
            "stream-json",
            "--permission-mode",
            "bypassPermissions",
            "--disable-slash-commands",
            "--disallowedTools",
            "Agent",
        ]
        if let resumeSessionID {
            arguments.append(contentsOf: ["--resume", resumeSessionID])
        }
        return arguments
    }
}

struct DelegationSessionDiscovery {
    let fileManager: FileManager
    let claudeProjectsDirectory: URL

    func mostRecentSessionID(for workingDirectory: String) -> String? {
        guard let sessionDirectory = sessionDirectory(for: workingDirectory),
              let files = try? fileManager.contentsOfDirectory(
                  at: sessionDirectory,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles],
              )
        else {
            return nil
        }

        return files
            .filter { $0.pathExtension == "jsonl" }
            .sorted(by: compareSessionFiles)
            .first?
            .deletingPathExtension()
            .lastPathComponent
    }

    static func sessionID(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }

        return string(in: object, preferredKeys: ["session_id", "sessionId"])
    }

    private func sessionDirectory(for workingDirectory: String) -> URL? {
        let expectedName = encodedSessionDirectoryName(for: workingDirectory)
        let exactMatch = claudeProjectsDirectory.appendingPathComponent(expectedName, isDirectory: true)
        if fileManager.fileExists(atPath: exactMatch.path) {
            return exactMatch
        }

        let normalizedName = expectedName.lowercased()
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: claudeProjectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        ) else {
            return nil
        }

        return candidates.first { $0.lastPathComponent.lowercased() == normalizedName }
    }

    private func encodedSessionDirectoryName(for workingDirectory: String) -> String {
        String(
            canonicalWorkingDirectory(workingDirectory).map { character in
                if character.isLetter || character.isNumber || character == "-" || character == "_" {
                    return character
                }
                return "-"
            },
        )
    }

    private func canonicalWorkingDirectory(_ workingDirectory: String) -> String {
        let standardized = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        guard fileManager.fileExists(atPath: standardized) else {
            return standardized
        }
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }

    private func compareSessionFiles(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsModified = modificationDate(for: lhs) ?? .distantPast
        let rhsModified = modificationDate(for: rhs) ?? .distantPast

        if lhsModified != rhsModified {
            return lhsModified > rhsModified
        }

        return lhs.lastPathComponent > rhs.lastPathComponent
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func string(in object: Any, preferredKeys: [String]) -> String? {
        switch object {
        case let dictionary as [String: Any]:
            for key in preferredKeys {
                if let value = dictionary[key] as? String, !value.isEmpty {
                    return value
                }
            }

            for value in dictionary.values {
                if let nested = string(in: value, preferredKeys: preferredKeys) {
                    return nested
                }
            }
            return nil

        case let array as [Any]:
            for value in array {
                if let nested = string(in: value, preferredKeys: preferredKeys) {
                    return nested
                }
            }
            return nil

        default:
            return nil
        }
    }
}

actor DelegationProcessLineBuffer {
    private let limit: Int
    private var lines: [String] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    func joined(separator: String = " | ") -> String {
        lines.joined(separator: separator)
    }
}

enum DelegationLoopError: Error {
    case startupPreparation(underlying: Error)
    case workerLaunch(underlying: Error)
    case missingReviewSession
    case reviewResume(underlying: Error)
}

enum DelegationUserFacingMessage {
    static func startFailure(for error: Error) -> String {
        switch error as? DelegationLoopError {
        case .some(.startupPreparation):
            "Couldn't prepare the delegation worktree. Try delegating again."
        case .some(.workerLaunch):
            "Couldn't launch the Claude worker. Try delegating again."
        default:
            "Couldn't start delegation. Try again."
        }
    }

    static func reviewFailure(for error: Error) -> String {
        switch error as? DelegationLoopError {
        case .some(.missingReviewSession):
            "Couldn't continue the review because the worker session is missing. Retry once the worker reconnects."
        case .some(.reviewResume):
            "Couldn't resume the worker. The review stayed pending, your decision wasn't lost, and you can retry."
        default:
            "Couldn't continue the delegation review. Try again."
        }
    }
}

actor DelegationLoopManager {
    enum ReviewDecision: String {
        case approve
        case requestChanges = "request_changes"
    }

    typealias DelegationMutator = @Sendable (RuntimeDelegationMutationRequest) async throws -> Void
    typealias TmuxSessionKiller = @Sendable (String) async -> Bool
    typealias ClaudeLauncher = @Sendable (
        DelegationClaudeLaunchRequest,
        @escaping @Sendable (String) async throws -> Void,
    ) async throws -> Void

    private struct ReviewDecisionPayload: Encodable {
        let version: Int
        let decision: String
        let note: String?
        let submittedAt: String

        enum CodingKeys: String, CodingKey {
            case version
            case decision
            case note
            case submittedAt = "submitted_at"
        }
    }

    struct AcceptedReviewDecisionContext {
        let projectName: String
        let projectPath: String
        let workerId: String
        let ideaId: String?
        let worktreeName: String
        let worktreePath: String
        let sessionId: String
        let decision: ReviewDecision
        let note: String
        let milestonesRoot: URL
        let statusPath: URL
        let completionMarkerPath: URL
        let resumePromptPath: URL
        let currentReviewMilestoneId: String
        let currentReviewBriefPath: String
        let currentReviewManifestPath: String
        let currentReviewDecisionJSONPath: URL
        let currentReviewDecisionMarkdownPath: URL
        let currentReviewPendingDecisionPath: URL
        let submittedMilestoneId: String
    }

    private struct WorkerRootPaths {
        let workerRoot: URL
        let milestonesRoot: URL
        let statusPath: URL
        let completionMarkerPath: URL
        let launchPromptPath: URL
        let resumePromptPath: URL
    }

    private struct MilestonePaths {
        let directory: URL
        let briefPath: URL
        let manifestPath: URL
        let decisionJSONPath: URL
        let decisionMarkdownPath: URL
        let pendingDecisionPath: URL
        let sentinelPath: URL
    }

    private struct AttachedSessionKey: Hashable {
        let normalizedProjectPath: String
        let workerID: String
    }

    private let runtimeMutation: DelegationMutator
    private let claudeLauncher: ClaudeLauncher
    private let sessionDiscovery: DelegationSessionDiscovery
    private let worktreeService: WorktreeService
    private let fileManager: FileManager
    private let tmuxSessionKiller: TmuxSessionKiller
    private var lastAttachedSessionIDs: [AttachedSessionKey: String] = [:]
    private static let defaultClaudeProjectsDirectoryProvider: @Sendable () -> URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private static let defaultClaudePathResolver: @Sendable () async -> String? = {
        await ClaudeCliResolver.shared.resolveClaudePath()
    }

    init(
        runtimeClient: RuntimeClient,
        worktreeService: WorktreeService = WorktreeService(),
        fileManager: FileManager = .default,
        claudeLauncher: ClaudeLauncher? = nil,
    ) {
        runtimeMutation = Self.makeDelegationMutator(runtimeClient: runtimeClient)
        self.claudeLauncher = claudeLauncher ?? Self.makeClaudeLauncher(
            claudePathResolver: Self.defaultClaudePathResolver,
        )
        sessionDiscovery = Self.makeSessionDiscovery(
            fileManager: fileManager,
            claudeProjectsDirectoryProvider: Self.defaultClaudeProjectsDirectoryProvider,
        )
        self.worktreeService = worktreeService
        self.fileManager = fileManager
        tmuxSessionKiller = Self.makeTmuxSessionKiller()
    }

    init(
        runtimeClient: RuntimeClient,
        worktreeService: WorktreeService = WorktreeService(),
        fileManager: FileManager = .default,
        claudeProjectsDirectoryProvider: @escaping @Sendable () -> URL,
        claudePathResolver: @escaping @Sendable () async -> String?,
        claudeLauncher: ClaudeLauncher? = nil,
    ) {
        runtimeMutation = Self.makeDelegationMutator(runtimeClient: runtimeClient)
        self.claudeLauncher = claudeLauncher ?? Self.makeClaudeLauncher(claudePathResolver: claudePathResolver)
        sessionDiscovery = Self.makeSessionDiscovery(
            fileManager: fileManager,
            claudeProjectsDirectoryProvider: claudeProjectsDirectoryProvider,
        )
        self.worktreeService = worktreeService
        self.fileManager = fileManager
        tmuxSessionKiller = Self.makeTmuxSessionKiller()
    }

    init(
        mutateDelegation: @escaping DelegationMutator,
        worktreeService: WorktreeService = WorktreeService(),
        fileManager: FileManager = .default,
        sessionDiscovery: DelegationSessionDiscovery,
        claudeLauncher: @escaping ClaudeLauncher,
        tmuxSessionKiller: TmuxSessionKiller? = nil,
    ) {
        runtimeMutation = mutateDelegation
        self.claudeLauncher = claudeLauncher
        self.sessionDiscovery = sessionDiscovery
        self.worktreeService = worktreeService
        self.fileManager = fileManager
        self.tmuxSessionKiller = tmuxSessionKiller ?? Self.makeTmuxSessionKiller()
    }

    private static func makeClaudeLauncher(
        claudePathResolver: @escaping @Sendable () async -> String?,
    ) -> ClaudeLauncher {
        { request, onSessionID in
            try await Self.launchClaudePrint(
                request: request,
                claudePathResolver: claudePathResolver,
                onSessionID: onSessionID,
            )
        }
    }

    private static func makeDelegationMutator(runtimeClient: RuntimeClient) -> DelegationMutator {
        { request in
            try await runtimeClient.mutateDelegation(request)
        }
    }

    private static func makeTmuxSessionKiller() -> TmuxSessionKiller {
        { sessionName in
            await TmuxRouter(
                runScript: { await TerminalLauncher.runBashScriptWithResult($0) },
            ).killSession(sessionName: sessionName)
        }
    }

    private static func makeSessionDiscovery(
        fileManager: FileManager,
        claudeProjectsDirectoryProvider: () -> URL,
    ) -> DelegationSessionDiscovery {
        DelegationSessionDiscovery(
            fileManager: fileManager,
            claudeProjectsDirectory: claudeProjectsDirectoryProvider(),
        )
    }

    func startDelegation(project: Project, idea: Idea) async throws {
        let workerID = UUID().uuidString.lowercased()
        let worktreeName = "delegation-\(workerID.prefix(8))"
        let branchName = "pkp/\(worktreeName)"
        let rootPaths = workerRootPaths(projectPath: project.path, workerID: workerID)
        let milestone = milestonePaths(milestonesRoot: rootPaths.milestonesRoot, milestoneID: "01")
        clearAttachedSessions(forProjectPath: project.path)

        let worktree: WorktreeService.Worktree
        do {
            worktree = try worktreeService.createManagedWorktree(
                in: project.path,
                name: worktreeName,
                branchName: branchName,
            )
        } catch {
            DebugLog.write(
                "DelegationLoopManager.start failure stage=worktree_prepare worker=\(workerID) error=\(error.localizedDescription)",
            )
            throw DelegationLoopError.startupPreparation(underlying: error)
        }

        do {
            try createWorkerDirectories(rootPaths: rootPaths, milestonePaths: milestone)
            let prompt = buildInitialPrompt(
                project: project,
                idea: idea,
                workerID: workerID,
                worktreePath: worktree.path,
                rootPaths: rootPaths,
                milestonePaths: milestone,
            )
            try prompt.write(to: rootPaths.launchPromptPath, atomically: true, encoding: .utf8)

            try await mutateDelegationLogged(
                RuntimeDelegationMutationRequest(
                    kind: "start",
                    projectPath: project.path,
                    workerId: workerID,
                    ideaId: idea.id,
                    worktreeName: worktreeName,
                    worktreePath: worktree.path,
                    sessionId: nil,
                    milestoneId: nil,
                    briefPath: nil,
                    manifestPath: nil,
                    reviewDecision: nil,
                    note: nil,
                ),
                context: "start worker=\(workerID) project=\(project.path)",
            )

            do {
                try await claudeLauncher(
                    DelegationClaudeLaunchRequest(
                        workingDirectory: worktree.path,
                        prompt: prompt,
                        resumeSessionID: nil,
                    ),
                ) { [self] sessionID in
                    DebugLog.write(
                        "DelegationLoopManager.session discovered source=stream worker=\(workerID) session=\(sessionID)",
                    )
                    try await attachSessionIfNeeded(
                        projectPath: project.path,
                        workerID: workerID,
                        ideaID: idea.id,
                        worktreeName: worktreeName,
                        worktreePath: worktree.path,
                        sessionID: sessionID,
                        runtimeSessionID: nil,
                        context: "attach_session source=stream worker=\(workerID)",
                    )
                }
            } catch {
                DebugLog.write(
                    "DelegationLoopManager.start failure stage=worker_launch worker=\(workerID) error=\(error.localizedDescription)",
                )
                await cleanupFailedStart(
                    projectPath: project.path,
                    workerID: workerID,
                    ideaID: idea.id,
                    worktreeName: worktreeName,
                    worktreePath: worktree.path,
                )
                throw DelegationLoopError.workerLaunch(underlying: error)
            }
        } catch {
            if let delegationError = error as? DelegationLoopError {
                throw delegationError
            }

            DebugLog.write(
                "DelegationLoopManager.start failure stage=startup worker=\(workerID) error=\(error.localizedDescription)",
            )
            await cleanupFailedStart(
                projectPath: project.path,
                workerID: workerID,
                ideaID: idea.id,
                worktreeName: worktreeName,
                worktreePath: worktree.path,
            )
            throw DelegationLoopError.startupPreparation(underlying: error)
        }
    }

    func submitReviewDecision(
        project: Project,
        delegation: RuntimeDelegationState,
        decision: ReviewDecision,
        note: String,
    ) async throws {
        let accepted = try await acceptReviewDecision(
            project: project,
            delegation: delegation,
            decision: decision,
            note: note,
        )
        try await performResumeLaunch(context: accepted)
    }

    func acceptReviewDecision(
        project: Project,
        delegation: RuntimeDelegationState,
        decision: ReviewDecision,
        note: String,
    ) async throws -> AcceptedReviewDecisionContext {
        let discoveredSessionID = delegation.sessionId ?? sessionDiscovery.mostRecentSessionID(for: delegation.worktreePath)
        guard let sessionID = discoveredSessionID else {
            DebugLog.write(
                "DelegationLoopManager.review failure stage=missing_session worker=\(delegation.workerId)",
            )
            throw DelegationLoopError.missingReviewSession
        }

        guard let currentReview = delegation.currentReview else {
            throw NSError(
                domain: "Capacitor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Delegation review context is missing"],
            )
        }

        if delegation.sessionId == nil {
            try await attachSessionIfNeeded(
                projectPath: project.path,
                workerID: delegation.workerId,
                ideaID: delegation.ideaId,
                worktreeName: delegation.worktreeName,
                worktreePath: delegation.worktreePath,
                sessionID: sessionID,
                runtimeSessionID: delegation.sessionId,
                context: "attach_session source=review_action worker=\(delegation.workerId)",
            )
        }

        let rootPaths = workerRootPaths(projectPath: project.path, workerID: delegation.workerId)
        let currentMilestone = milestonePaths(
            milestonesRoot: rootPaths.milestonesRoot,
            milestoneID: currentReview.milestoneId,
        )
        try createWorkerDirectories(rootPaths: rootPaths, milestonePaths: currentMilestone)

        try writeReviewDecision(decision: decision, note: note, to: currentMilestone, staged: true)

        do {
            try await mutateDelegationLogged(
                RuntimeDelegationMutationRequest(
                    kind: "submit_review",
                    projectPath: project.path,
                    workerId: delegation.workerId,
                    ideaId: delegation.ideaId,
                    worktreeName: delegation.worktreeName,
                    worktreePath: delegation.worktreePath,
                    sessionId: sessionID,
                    milestoneId: currentReview.milestoneId,
                    briefPath: currentReview.briefPath,
                    manifestPath: currentReview.manifestPath,
                    reviewDecision: decision.rawValue,
                    note: normalizedReviewNote(note),
                ),
                context: "submit_review worker=\(delegation.workerId) decision=\(decision.rawValue)",
            )
        } catch {
            cleanupDecisionArtifacts(
                pendingDecisionPath: currentMilestone.pendingDecisionPath,
                decisionMarkdownPath: currentMilestone.decisionMarkdownPath,
            )
            throw error
        }

        return AcceptedReviewDecisionContext(
            projectName: project.name,
            projectPath: project.path,
            workerId: delegation.workerId,
            ideaId: delegation.ideaId,
            worktreeName: delegation.worktreeName,
            worktreePath: delegation.worktreePath,
            sessionId: sessionID,
            decision: decision,
            note: note,
            milestonesRoot: rootPaths.milestonesRoot,
            statusPath: rootPaths.statusPath,
            completionMarkerPath: rootPaths.completionMarkerPath,
            resumePromptPath: rootPaths.resumePromptPath,
            currentReviewMilestoneId: currentReview.milestoneId,
            currentReviewBriefPath: currentReview.briefPath,
            currentReviewManifestPath: currentReview.manifestPath,
            currentReviewDecisionJSONPath: currentMilestone.decisionJSONPath,
            currentReviewDecisionMarkdownPath: currentMilestone.decisionMarkdownPath,
            currentReviewPendingDecisionPath: currentMilestone.pendingDecisionPath,
            submittedMilestoneId: currentReview.milestoneId,
        )
    }

    func launchResumeInBackground(_ context: AcceptedReviewDecisionContext) {
        _Concurrency.Task.detached { [self, context] in
            do {
                try await performResumeLaunch(context: context)
            } catch {
                DebugLog.write(
                    "DelegationLoopManager.review background_failure worker=\(context.workerId) error=\(error.localizedDescription)",
                )
            }
        }
    }

    private func performResumeLaunch(context: AcceptedReviewDecisionContext) async throws {
        let rootPaths = WorkerRootPaths(
            workerRoot: context.milestonesRoot.deletingLastPathComponent(),
            milestonesRoot: context.milestonesRoot,
            statusPath: context.statusPath,
            completionMarkerPath: context.completionMarkerPath,
            launchPromptPath: context.resumePromptPath.deletingLastPathComponent().appendingPathComponent("launch-prompt.md"),
            resumePromptPath: context.resumePromptPath,
        )
        let currentMilestone = milestonePaths(
            milestonesRoot: context.milestonesRoot,
            milestoneID: context.currentReviewMilestoneId,
        )
        let nextMilestone: String? = context.decision == .requestChanges
            ? nextMilestoneID(milestonesRoot: context.milestonesRoot)
            : nil
        let prompt = buildResumePrompt(
            projectName: context.projectName,
            decision: context.decision,
            note: context.note,
            rootPaths: rootPaths,
            currentMilestonePaths: currentMilestone,
            nextMilestoneID: nextMilestone,
        )

        do {
            try ensurePendingDecisionArtifacts(
                for: context,
                currentMilestone: currentMilestone,
            )
            try prompt.write(to: context.resumePromptPath, atomically: true, encoding: .utf8)
            try await claudeLauncher(
                DelegationClaudeLaunchRequest(
                    workingDirectory: context.worktreePath,
                    prompt: prompt,
                    resumeSessionID: context.sessionId,
                ),
            ) { _ in }
        } catch {
            await handleResumeLaunchFailure(context: context, error: error)
            throw DelegationLoopError.reviewResume(underlying: error)
        }

        // Post-launch: send resume mutation. If this fails, the runtime is still
        // resume_pending, so roll back via handleResumeLaunchFailure.
        do {
            try await mutateDelegationLogged(
                RuntimeDelegationMutationRequest(
                    kind: "resume",
                    projectPath: context.projectPath,
                    workerId: context.workerId,
                    ideaId: context.ideaId,
                    worktreeName: context.worktreeName,
                    worktreePath: context.worktreePath,
                    sessionId: context.sessionId,
                    milestoneId: context.currentReviewMilestoneId,
                    briefPath: context.currentReviewBriefPath,
                    manifestPath: context.currentReviewManifestPath,
                    reviewDecision: nil,
                    note: nil,
                ),
                context: "resume worker=\(context.workerId)",
            )
        } catch {
            DebugLog.write(
                "DelegationLoopManager.review resume_mutation_failed worker=\(context.workerId) error=\(error.localizedDescription)",
            )
            await handleResumeLaunchFailure(context: context, error: error)
            throw error
        }

        // Resume mutation succeeded — runtime is now Working. Promote the
        // pending decision artifact. If this fails, do NOT roll back the
        // runtime state (the worker is genuinely resumed). Just log it.
        do {
            try promotePendingDecision(
                pendingDecisionPath: context.currentReviewPendingDecisionPath,
                decisionJSONPath: context.currentReviewDecisionJSONPath,
            )
        } catch {
            DebugLog.write(
                "DelegationLoopManager.review artifact_promotion_failed worker=\(context.workerId) error=\(error.localizedDescription) — runtime is Working, not rolling back",
            )
        }
    }

    private func handleResumeLaunchFailure(
        context: AcceptedReviewDecisionContext,
        error: Error,
    ) async {
        await mutateDelegationLoggedIgnoringFailure(
            RuntimeDelegationMutationRequest(
                kind: "resume_failed",
                projectPath: context.projectPath,
                workerId: context.workerId,
                ideaId: context.ideaId,
                worktreeName: context.worktreeName,
                worktreePath: context.worktreePath,
                sessionId: context.sessionId,
                milestoneId: context.currentReviewMilestoneId,
                briefPath: context.currentReviewBriefPath,
                manifestPath: context.currentReviewManifestPath,
                reviewDecision: nil,
                note: nil,
            ),
            context: "resume_failed worker=\(context.workerId)",
        )

        cleanupDecisionArtifacts(
            pendingDecisionPath: context.currentReviewPendingDecisionPath,
            decisionMarkdownPath: context.currentReviewDecisionMarkdownPath,
        )

        if fileManager.fileExists(atPath: context.completionMarkerPath.path) {
            do {
                try await completeDelegation(
                    projectPath: context.projectPath,
                    workerID: context.workerId,
                    ideaID: context.ideaId,
                    worktreeName: context.worktreeName,
                    worktreePath: context.worktreePath,
                    sessionID: context.sessionId,
                    context: "complete_after_resume_failure worker=\(context.workerId)",
                )
            } catch {}
        } else if let newerMilestoneID = activeMilestoneID(
            milestonesRoot: context.milestonesRoot,
            submittedMilestoneID: context.submittedMilestoneId,
        ) {
            let newerMilestone = milestonePaths(
                milestonesRoot: context.milestonesRoot,
                milestoneID: newerMilestoneID,
            )
            await mutateDelegationLoggedIgnoringFailure(
                RuntimeDelegationMutationRequest(
                    kind: "review_ready",
                    projectPath: context.projectPath,
                    workerId: context.workerId,
                    ideaId: context.ideaId,
                    worktreeName: context.worktreeName,
                    worktreePath: context.worktreePath,
                    sessionId: context.sessionId,
                    milestoneId: newerMilestoneID,
                    briefPath: newerMilestone.briefPath.path,
                    manifestPath: newerMilestone.manifestPath.path,
                    reviewDecision: nil,
                    note: nil,
                ),
                context: "review_ready_after_resume_failure worker=\(context.workerId) milestone=\(newerMilestoneID)",
            )
        } else {
            await mutateDelegationLoggedIgnoringFailure(
                RuntimeDelegationMutationRequest(
                    kind: "review_ready",
                    projectPath: context.projectPath,
                    workerId: context.workerId,
                    ideaId: context.ideaId,
                    worktreeName: context.worktreeName,
                    worktreePath: context.worktreePath,
                    sessionId: context.sessionId,
                    milestoneId: context.currentReviewMilestoneId,
                    briefPath: context.currentReviewBriefPath,
                    manifestPath: context.currentReviewManifestPath,
                    reviewDecision: nil,
                    note: nil,
                ),
                context: "restore_review_ready_after_resume_failure worker=\(context.workerId)",
            )
        }

        DebugLog.write(
            "DelegationLoopManager.review failure stage=resume_launch worker=\(context.workerId) error=\(error.localizedDescription)",
        )
    }

    func reconcile(delegations: [RuntimeDelegationState]) async {
        for delegation in delegations {
            await reconcile(delegation: delegation)
        }
    }

    private func reconcile(delegation: RuntimeDelegationState) async {
        let rootPaths = workerRootPaths(projectPath: delegation.projectPath, workerID: delegation.workerId)
        let discoveredSessionID = sessionDiscovery.mostRecentSessionID(for: delegation.worktreePath)
        let effectiveSessionID = discoveredSessionID ?? delegation.sessionId

        if let discoveredSessionID {
            _ = await attachSessionIfNeededIgnoringFailure(
                projectPath: delegation.projectPath,
                workerID: delegation.workerId,
                ideaID: delegation.ideaId,
                worktreeName: delegation.worktreeName,
                worktreePath: delegation.worktreePath,
                sessionID: discoveredSessionID,
                runtimeSessionID: delegation.sessionId,
                context: "attach_session source=reconcile worker=\(delegation.workerId)",
            )
        }

        let shouldScanForReview = delegation.status == .working || delegation.status == .resumePending
        guard shouldScanForReview else { return }

        if fileManager.fileExists(atPath: rootPaths.completionMarkerPath.path) {
            do {
                try await completeDelegation(
                    projectPath: delegation.projectPath,
                    workerID: delegation.workerId,
                    ideaID: delegation.ideaId,
                    worktreeName: delegation.worktreeName,
                    worktreePath: delegation.worktreePath,
                    sessionID: effectiveSessionID,
                    context: "complete source=reconcile worker=\(delegation.workerId)",
                )
            } catch {}
            return
        }

        guard let activeID = activeMilestoneID(
            milestonesRoot: rootPaths.milestonesRoot,
            submittedMilestoneID: delegation.submittedMilestoneId,
        ) else {
            return
        }
        let activeMilestone = milestonePaths(milestonesRoot: rootPaths.milestonesRoot, milestoneID: activeID)

        await mutateDelegationLoggedIgnoringFailure(
            RuntimeDelegationMutationRequest(
                kind: "review_ready",
                projectPath: delegation.projectPath,
                workerId: delegation.workerId,
                ideaId: delegation.ideaId,
                worktreeName: delegation.worktreeName,
                worktreePath: delegation.worktreePath,
                sessionId: effectiveSessionID,
                milestoneId: activeID,
                briefPath: activeMilestone.briefPath.path,
                manifestPath: activeMilestone.manifestPath.path,
                reviewDecision: nil,
                note: nil,
            ),
            context: "review_ready source=reconcile worker=\(delegation.workerId)",
        )
    }

    private func mutateDelegationLogged(
        _ request: RuntimeDelegationMutationRequest,
        context: String,
    ) async throws {
        DebugLog.write(
            "DelegationLoopManager.mutation start kind=\(request.kind) worker=\(request.workerId) session=\(request.sessionId ?? "nil") context=\(context)",
        )
        do {
            try await runtimeMutation(request)
            applyMutationSideEffects(request)
            DebugLog.write(
                "DelegationLoopManager.mutation success kind=\(request.kind) worker=\(request.workerId) session=\(request.sessionId ?? "nil") context=\(context)",
            )
        } catch {
            DebugLog.write(
                "DelegationLoopManager.mutation failure kind=\(request.kind) worker=\(request.workerId) session=\(request.sessionId ?? "nil") context=\(context) error=\(error.localizedDescription)",
            )
            throw error
        }
    }

    private func mutateDelegationLoggedIgnoringFailure(
        _ request: RuntimeDelegationMutationRequest,
        context: String,
    ) async {
        do {
            try await mutateDelegationLogged(request, context: context)
        } catch {}
    }

    @discardableResult
    private func attachSessionIfNeeded(
        projectPath: String,
        workerID: String,
        ideaID: String?,
        worktreeName: String?,
        worktreePath: String?,
        sessionID: String,
        runtimeSessionID: String?,
        context: String,
    ) async throws -> Bool {
        let cacheKey = attachedSessionKey(projectPath: projectPath, workerID: workerID)

        if runtimeSessionID == sessionID {
            logAttachSkipped(
                projectPath: projectPath,
                workerID: workerID,
                sessionID: sessionID,
                context: context,
                reason: "runtime_already_attached",
            )
            return false
        }

        if lastAttachedSessionIDs[cacheKey] == sessionID {
            logAttachSkipped(
                projectPath: projectPath,
                workerID: workerID,
                sessionID: sessionID,
                context: context,
                reason: "cache_already_attached",
            )
            return false
        }

        try await mutateDelegationLogged(
            RuntimeDelegationMutationRequest(
                kind: "attach_session",
                projectPath: projectPath,
                workerId: workerID,
                ideaId: ideaID,
                worktreeName: worktreeName,
                worktreePath: worktreePath,
                sessionId: sessionID,
                milestoneId: nil,
                briefPath: nil,
                manifestPath: nil,
                reviewDecision: nil,
                note: nil,
            ),
            context: context,
        )
        return true
    }

    @discardableResult
    private func attachSessionIfNeededIgnoringFailure(
        projectPath: String,
        workerID: String,
        ideaID: String?,
        worktreeName: String?,
        worktreePath: String?,
        sessionID: String,
        runtimeSessionID: String?,
        context: String,
    ) async -> Bool {
        do {
            return try await attachSessionIfNeeded(
                projectPath: projectPath,
                workerID: workerID,
                ideaID: ideaID,
                worktreeName: worktreeName,
                worktreePath: worktreePath,
                sessionID: sessionID,
                runtimeSessionID: runtimeSessionID,
                context: context,
            )
        } catch {
            return false
        }
    }

    private func completeDelegation(
        projectPath: String,
        workerID: String,
        ideaID: String?,
        worktreeName: String,
        worktreePath: String,
        sessionID: String?,
        context: String,
    ) async throws {
        try await mutateDelegationLogged(
            RuntimeDelegationMutationRequest(
                kind: "complete",
                projectPath: projectPath,
                workerId: workerID,
                ideaId: ideaID,
                worktreeName: worktreeName,
                worktreePath: worktreePath,
                sessionId: sessionID,
                milestoneId: nil,
                briefPath: nil,
                manifestPath: nil,
                reviewDecision: nil,
                note: nil,
            ),
            context: context,
        )

        await cleanupCompletedDelegation(
            workerID: workerID,
            projectPath: projectPath,
            worktreeName: worktreeName,
        )
    }

    private func cleanupFailedStart(
        projectPath: String,
        workerID: String,
        ideaID: String,
        worktreeName: String,
        worktreePath: String,
    ) async {
        clearAttachedSession(projectPath: projectPath, workerID: workerID)

        try? worktreeService.removeManagedWorktree(
            in: projectPath,
            name: worktreeName,
            force: true,
        )

        await mutateDelegationLoggedIgnoringFailure(
            RuntimeDelegationMutationRequest(
                kind: "complete",
                projectPath: projectPath,
                workerId: workerID,
                ideaId: ideaID,
                worktreeName: worktreeName,
                worktreePath: worktreePath,
                sessionId: nil,
                milestoneId: nil,
                briefPath: nil,
                manifestPath: nil,
                reviewDecision: nil,
                note: nil,
            ),
            context: "cleanup_after_failed_start worker=\(workerID)",
        )
    }

    private func cleanupCompletedDelegation(
        workerID: String,
        projectPath: String,
    ) async {
        let derivedWorktreeName = "delegation-\(workerID.prefix(8))"
        await cleanupCompletedDelegation(
            workerID: workerID,
            projectPath: projectPath,
            worktreeName: derivedWorktreeName,
        )
    }

    private func cleanupCompletedDelegation(
        workerID: String,
        projectPath: String,
        worktreeName: String,
    ) async {
        clearAttachedSession(projectPath: projectPath, workerID: workerID)

        let sessionKilled = await tmuxSessionKiller(worktreeName)
        DebugLog.write(
            "DelegationLoopManager.cleanup_completed step=kill_session worker=\(workerID) session=\(worktreeName) success=\(sessionKilled)",
        )

        do {
            try worktreeService.removeManagedWorktree(
                in: projectPath,
                name: worktreeName,
                force: true,
            )
            DebugLog.write(
                "DelegationLoopManager.cleanup_completed step=remove_worktree worker=\(workerID) worktree=\(worktreeName) success=true",
            )
        } catch {
            DebugLog.write(
                "DelegationLoopManager.cleanup_completed step=remove_worktree worker=\(workerID) worktree=\(worktreeName) success=false error=\(error.localizedDescription)",
            )
        }

        let branchName = "pkp/\(worktreeName)"
        do {
            try worktreeService.deleteBranch(
                in: projectPath,
                name: branchName,
                force: true,
            )
            DebugLog.write(
                "DelegationLoopManager.cleanup_completed step=delete_branch worker=\(workerID) branch=\(branchName) success=true",
            )
        } catch {
            DebugLog.write(
                "DelegationLoopManager.cleanup_completed step=delete_branch worker=\(workerID) branch=\(branchName) success=false error=\(error.localizedDescription)",
            )
        }
    }

    private func attachedSessionKey(projectPath: String, workerID: String) -> AttachedSessionKey {
        AttachedSessionKey(
            normalizedProjectPath: PathNormalizer.normalize(projectPath),
            workerID: workerID,
        )
    }

    private func clearAttachedSession(projectPath: String, workerID: String) {
        lastAttachedSessionIDs.removeValue(forKey: attachedSessionKey(projectPath: projectPath, workerID: workerID))
    }

    private func clearAttachedSessions(forProjectPath projectPath: String) {
        let normalizedProjectPath = PathNormalizer.normalize(projectPath)
        lastAttachedSessionIDs = lastAttachedSessionIDs.filter { key, _ in
            key.normalizedProjectPath != normalizedProjectPath
        }
    }

    private func applyMutationSideEffects(_ request: RuntimeDelegationMutationRequest) {
        switch request.kind {
        case "attach_session":
            guard let sessionID = request.sessionId else { return }
            lastAttachedSessionIDs[attachedSessionKey(
                projectPath: request.projectPath,
                workerID: request.workerId,
            )] = sessionID

        case "complete":
            clearAttachedSession(projectPath: request.projectPath, workerID: request.workerId)

        default:
            break
        }
    }

    private func logAttachSkipped(
        projectPath: String,
        workerID: String,
        sessionID: String,
        context: String,
        reason: String,
    ) {
        DebugLog.write(
            "DelegationLoopManager.attach skipped reason=\(reason) worker=\(workerID) session=\(sessionID) project=\(PathNormalizer.normalize(projectPath)) context=\(context)",
        )
    }

    private static func launchClaudePrint(
        request: DelegationClaudeLaunchRequest,
        claudePathResolver: @escaping @Sendable () async -> String?,
        onSessionID: @escaping @Sendable (String) async throws -> Void,
    ) async throws {
        guard let claudePath = await claudePathResolver() else {
            throw NSError(
                domain: "Capacitor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Claude CLI not found"],
            )
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: claudePath)
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)
        process.arguments = request.arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        DebugLog.write(
            "DelegationLoopManager.launch start cwd=\(request.workingDirectory) resume=\(request.resumeSessionID ?? "nil")",
        )

        let stderrBuffer = DelegationProcessLineBuffer(limit: 20)

        let outputTask = _Concurrency.Task.detached {
            do {
                for try await line in outputPipe.fileHandleForReading.bytes.lines {
                    guard let sessionID = DelegationSessionDiscovery.sessionID(from: line) else { continue }
                    do {
                        try await onSessionID(sessionID)
                    } catch {
                        DebugLog.write(
                            "DelegationLoopManager.session callback failure session=\(sessionID) error=\(error.localizedDescription)",
                        )
                    }
                }
            } catch {}
        }

        let errorDrainTask = _Concurrency.Task.detached {
            do {
                for try await line in errorPipe.fileHandleForReading.bytes.lines {
                    await stderrBuffer.append(line)
                }
            } catch {}
        }

        try process.run()
        if let promptData = request.prompt.data(using: .utf8) {
            try inputPipe.fileHandleForWriting.write(contentsOf: promptData)
            if !request.prompt.hasSuffix("\n") {
                try inputPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
            }
        }
        try? inputPipe.fileHandleForWriting.close()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        outputTask.cancel()
        errorDrainTask.cancel()

        let stderrSummary = await stderrBuffer.joined()
        DebugLog.write(
            "DelegationLoopManager.launch exit cwd=\(request.workingDirectory) resume=\(request.resumeSessionID ?? "nil") status=\(process.terminationStatus) stderr=\(stderrSummary.isEmpty ? "<empty>" : stderrSummary)",
        )

        guard process.terminationStatus == 0 else {
            let details = stderrSummary.isEmpty ? "" : " stderr: \(stderrSummary)"
            throw NSError(
                domain: "Capacitor",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Claude worker exited with status \(process.terminationStatus)\(details)"],
            )
        }
    }

    private func workerRootPaths(projectPath: String, workerID: String) -> WorkerRootPaths {
        let workerRoot = CapacitorProjectPaths.projectDataDirectory(for: projectPath, fileManager: fileManager)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent(workerID, isDirectory: true)

        return WorkerRootPaths(
            workerRoot: workerRoot,
            milestonesRoot: workerRoot.appendingPathComponent("milestones", isDirectory: true),
            statusPath: workerRoot.appendingPathComponent("status.md"),
            completionMarkerPath: workerRoot.appendingPathComponent("completion.json"),
            launchPromptPath: workerRoot.appendingPathComponent("launch-prompt.md"),
            resumePromptPath: workerRoot.appendingPathComponent("resume-prompt.md"),
        )
    }

    private func milestonePaths(milestonesRoot: URL, milestoneID: String) -> MilestonePaths {
        let directory = milestonesRoot.appendingPathComponent(milestoneID, isDirectory: true)
        return MilestonePaths(
            directory: directory,
            briefPath: directory.appendingPathComponent("brief.md"),
            manifestPath: directory.appendingPathComponent("manifest.json"),
            decisionJSONPath: directory.appendingPathComponent("decision.json"),
            decisionMarkdownPath: directory.appendingPathComponent("decision.md"),
            pendingDecisionPath: directory.appendingPathComponent("decision-pending.json"),
            sentinelPath: directory.appendingPathComponent(".review-ready"),
        )
    }

    private func nextMilestoneID(milestonesRoot: URL) -> String {
        let maxID = numericMilestoneIDs(in: milestonesRoot).max() ?? 0
        return String(format: "%02d", maxID + 1)
    }

    private func activeMilestoneID(
        milestonesRoot: URL,
        submittedMilestoneID: String? = nil,
    ) -> String? {
        let ids = numericMilestoneIDs(in: milestonesRoot)

        if let submittedMilestoneID,
           let submittedNumericID = Int(submittedMilestoneID)
        {
            for id in ids.sorted(by: >) where id > submittedNumericID {
                let milestoneID = String(format: "%02d", id)
                let milestone = milestonePaths(milestonesRoot: milestonesRoot, milestoneID: milestoneID)
                guard hasValidReviewReadyMilestone(milestone) else { continue }
                guard !hasDecision(for: milestone), !hasPendingDecision(for: milestone) else { continue }
                return milestoneID
            }
            return nil
        }

        for id in ids.sorted(by: >) {
            let milestoneID = String(format: "%02d", id)
            let milestone = milestonePaths(milestonesRoot: milestonesRoot, milestoneID: milestoneID)
            guard hasValidReviewReadyMilestone(milestone) else { continue }
            guard !hasDecision(for: milestone), !hasPendingDecision(for: milestone) else { continue }
            return milestoneID
        }

        return nil
    }

    private func numericMilestoneIDs(in milestonesRoot: URL) -> [Int] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: milestonesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        ) else {
            return []
        }
        return contents.compactMap { url in
            Int(url.lastPathComponent)
        }
    }

    private func createWorkerDirectories(rootPaths: WorkerRootPaths, milestonePaths: MilestonePaths) throws {
        try fileManager.createDirectory(at: rootPaths.workerRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: milestonePaths.directory, withIntermediateDirectories: true)
    }

    private func cleanupDecisionArtifacts(
        pendingDecisionPath: URL,
        decisionMarkdownPath: URL,
    ) {
        try? fileManager.removeItem(at: pendingDecisionPath)
        try? fileManager.removeItem(at: decisionMarkdownPath)
    }

    private func promotePendingDecision(
        pendingDecisionPath: URL,
        decisionJSONPath: URL,
    ) throws {
        if fileManager.fileExists(atPath: decisionJSONPath.path) {
            try fileManager.removeItem(at: decisionJSONPath)
        }
        try fileManager.moveItem(at: pendingDecisionPath, to: decisionJSONPath)
    }

    private func ensurePendingDecisionArtifacts(
        for context: AcceptedReviewDecisionContext,
        currentMilestone: MilestonePaths,
    ) throws {
        guard !fileManager.fileExists(atPath: currentMilestone.decisionJSONPath.path) else {
            return
        }

        let hasPendingDecision = fileManager.fileExists(atPath: currentMilestone.pendingDecisionPath.path)
        let hasDecisionMarkdown = fileManager.fileExists(atPath: currentMilestone.decisionMarkdownPath.path)
        guard !hasPendingDecision || !hasDecisionMarkdown else {
            return
        }

        // A failed background resume cleans staged artifacts. Recreate them here so
        // the same accepted review can be retried without re-entering the decision.
        try writeReviewDecision(
            decision: context.decision,
            note: context.note,
            to: currentMilestone,
            staged: true,
        )
    }

    private func normalizedReviewNote(_ note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func hasValidReviewReadyMilestone(_ milestone: MilestonePaths) -> Bool {
        guard fileManager.fileExists(atPath: milestone.sentinelPath.path) else {
            return false
        }

        guard let manifestData = fileManager.contents(atPath: milestone.manifestPath.path),
              (try? JSONSerialization.jsonObject(with: manifestData)) != nil
        else {
            return false
        }

        return true
    }

    private func hasDecision(for milestone: MilestonePaths) -> Bool {
        fileManager.fileExists(atPath: milestone.decisionJSONPath.path)
    }

    private func hasPendingDecision(for milestone: MilestonePaths) -> Bool {
        fileManager.fileExists(atPath: milestone.pendingDecisionPath.path)
    }

    private func writeReviewDecision(
        decision: ReviewDecision,
        note: String,
        to milestone: MilestonePaths,
        staged: Bool = false,
    ) throws {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ReviewDecisionPayload(
            version: 1,
            decision: decision.rawValue,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            submittedAt: ISO8601DateFormatter.shared.string(from: Date()),
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let jsonPath = staged ? milestone.pendingDecisionPath : milestone.decisionJSONPath
        try data.write(to: jsonPath, options: .atomic)

        let markdown = """
        # Review Decision

        - Decision: \(decision.rawValue)
        - Submitted At: \(payload.submittedAt)

        \(trimmedNote.isEmpty ? "No additional notes." : trimmedNote)
        """
        try markdown.write(to: milestone.decisionMarkdownPath, atomically: true, encoding: .utf8)
    }

    private func buildInitialPrompt(
        project: Project,
        idea: Idea,
        workerID: String,
        worktreePath: String,
        rootPaths: WorkerRootPaths,
        milestonePaths milestone: MilestonePaths,
    ) -> String {
        """
        You are executing one async delegation slice inside Capacitor.

        Project: \(project.name)
        Project path: \(project.path)
        Worktree path: \(worktreePath)
        Worker ID: \(workerID)

        Idea title: \(idea.title)
        Idea description:
        \(idea.description)

        Requirements:
        1. Work only inside the current git worktree.
        2. Do not spawn subagents and do not use the Agent tool.
        3. Do not perform broad repo audits or exploratory surveys outside the task at hand.
        4. Update \(rootPaths.statusPath.path) immediately with a short plan, then keep it current with concise progress notes.
        5. Produce exactly one reviewable checkpoint and stop there.
        6. Before stopping, write (in this order):
           - \(milestone.briefPath.path)
           - \(milestone.manifestPath.path)
           - \(milestone.sentinelPath.path) (empty file — signals milestone is ready for review)
        7. The manifest must be valid JSON with this shape:
           {
             "version": 1,
             "milestone_id": "\(milestone.directory.lastPathComponent)",
             "summary": "short summary",
             "artifacts": [
               { "label": "artifact label", "path": "absolute or relative file path" }
             ],
             "decisions": {
               "approve": { "label": "short contextual CTA", "description": "why the reviewer should approve" },
               "request_changes": { "label": "short contextual CTA", "description": "what specifically needs work" }
             },
             "swift_changes": true
           }
           The "decisions" field is required. Labels should be 2-4 words. Descriptions should be one short sentence — specific to what you did, not generic. The reviewer sees these as action options.
           Set "swift_changes" to true if you modified any .swift files. Omit it or set to false otherwise.
        8. Write \(rootPaths.statusPath.path) before any substantial exploration or code changes.
        9. Do not continue past the review checkpoint in this run.
        10. Exit after writing the sentinel file.

        Treat the review brief as the human-facing explanation of what changed, what still needs scrutiny, and what decision would unblock you.
        """
    }

    private func buildResumePrompt(
        projectName: String,
        decision: ReviewDecision,
        note: String,
        rootPaths: WorkerRootPaths,
        currentMilestonePaths: MilestonePaths,
        nextMilestoneID: String?,
    ) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteText = trimmedNote.isEmpty ? "No additional notes." : trimmedNote

        switch decision {
        case .approve:
            return """
            Resume the delegated work for \(projectName).

            The reviewer approved your work on milestone \(currentMilestonePaths.directory.lastPathComponent).

            Decision: approve
            Notes:
            \(noteText)

            Requirements:
            1. Apply any minor adjustments if requested, then finalize.
            2. Do not spawn subagents and do not use the Agent tool.
            3. Do not continue exploration or start new implementation work. Treat the approved checkpoint as final.
            4. Update \(rootPaths.statusPath.path) with final progress.
            5. Do not open another review checkpoint.
            6. When finished, write \(rootPaths.completionMarkerPath.path) as JSON with:
               {
                 "version": 1,
                 "status": "completed",
                 "completed_at": "<ISO8601 timestamp>",
                 "summary": "short completion summary"
               }
            7. Exit after writing the completion marker.
            """

        case .requestChanges:
            let nextID = nextMilestoneID ?? "02"
            let nextMilestone = milestonePaths(milestonesRoot: rootPaths.milestonesRoot, milestoneID: nextID)
            return """
            Resume the delegated work for \(projectName).

            The reviewer requested changes on milestone \(currentMilestonePaths.directory.lastPathComponent).

            Decision: request_changes
            Notes:
            \(noteText)

            Requirements:
            1. Address the requested delta in the current worktree.
            2. Do not spawn subagents and do not use the Agent tool.
            3. Update \(rootPaths.statusPath.path) with progress as you work.
            4. Address the requested changes and produce a new milestone.
            5. You MUST produce a new review checkpoint in \(nextMilestone.directory.path):
               - Write \(nextMilestone.briefPath.path)
               - Write \(nextMilestone.manifestPath.path)
               - Write \(nextMilestone.sentinelPath.path) (empty file — signals milestone is ready for review)
            6. The manifest must be valid JSON with this shape:
               {
                 "version": 1,
                 "milestone_id": "\(nextID)",
                 "summary": "short summary",
                 "artifacts": [
                   { "label": "artifact label", "path": "absolute or relative file path" }
                 ],
                 "decisions": {
                   "approve": { "label": "short contextual CTA", "description": "why the reviewer should approve" },
                   "request_changes": { "label": "short contextual CTA", "description": "what specifically needs work" }
                 },
                 "swift_changes": true
               }
               The "decisions" field is required. Labels should be 2-4 words. Descriptions should be one short sentence — specific to what you did, not generic. The reviewer sees these as action options.
               Set "swift_changes" to true if you modified any .swift files. Omit it or set to false otherwise.
            7. Write files in this order: brief.md, then manifest.json, then .review-ready sentinel.
            8. Exit after writing the sentinel file.
            """
        }
    }
}
