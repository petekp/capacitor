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

actor DelegationLoopManager {
    enum ReviewDecision: String {
        case approve
        case requestChanges = "request_changes"
    }

    typealias DelegationMutator = @Sendable (RuntimeDelegationMutationRequest) async throws -> Void
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

    private struct WorkerPaths {
        let workerRoot: URL
        let statusPath: URL
        let milestoneDirectory: URL
        let briefPath: URL
        let manifestPath: URL
        let decisionJSONPath: URL
        let decisionMarkdownPath: URL
        let completionMarkerPath: URL
        let launchPromptPath: URL
        let resumePromptPath: URL
    }

    private enum Constants {
        static let milestoneID = "01"
    }

    private let runtimeMutation: DelegationMutator
    private let claudeLauncher: ClaudeLauncher
    private let sessionDiscovery: DelegationSessionDiscovery
    private let worktreeService: WorktreeService
    private let fileManager: FileManager

    init(
        runtimeClient: RuntimeClient,
        worktreeService: WorktreeService = WorktreeService(),
        fileManager: FileManager = .default,
        claudeProjectsDirectoryProvider: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
        },
        claudePathResolver: @escaping @Sendable () async -> String? = {
            await ClaudeCliResolver.shared.resolveClaudePath()
        },
        claudeLauncher: ClaudeLauncher? = nil,
    ) {
        let launcher = claudeLauncher ?? { request, onSessionID in
            try await Self.launchClaudePrint(
                request: request,
                claudePathResolver: claudePathResolver,
                onSessionID: onSessionID,
            )
        }

        self.init(
            mutateDelegation: { request in
                try await runtimeClient.mutateDelegation(request)
            },
            worktreeService: worktreeService,
            fileManager: fileManager,
            sessionDiscovery: DelegationSessionDiscovery(
                fileManager: fileManager,
                claudeProjectsDirectory: claudeProjectsDirectoryProvider(),
            ),
            claudeLauncher: launcher,
        )
    }

    init(
        mutateDelegation: @escaping DelegationMutator,
        worktreeService: WorktreeService = WorktreeService(),
        fileManager: FileManager = .default,
        sessionDiscovery: DelegationSessionDiscovery,
        claudeLauncher: @escaping ClaudeLauncher,
    ) {
        runtimeMutation = mutateDelegation
        self.claudeLauncher = claudeLauncher
        self.sessionDiscovery = sessionDiscovery
        self.worktreeService = worktreeService
        self.fileManager = fileManager
    }

    func startDelegation(project: Project, idea: Idea) async throws {
        let workerID = UUID().uuidString.lowercased()
        let worktreeName = "delegation-\(workerID.prefix(8))"
        let branchName = "pkp/\(worktreeName)"
        let paths = workerPaths(projectPath: project.path, workerID: workerID)
        let worktree = try worktreeService.createManagedWorktree(
            in: project.path,
            name: worktreeName,
            branchName: branchName,
        )

        do {
            try createWorkerDirectories(paths)
            let prompt = buildInitialPrompt(
                project: project,
                idea: idea,
                workerID: workerID,
                worktreePath: worktree.path,
                paths: paths,
            )
            try prompt.write(to: paths.launchPromptPath, atomically: true, encoding: .utf8)

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
                try await attachSession(
                    projectPath: project.path,
                    workerID: workerID,
                    ideaID: idea.id,
                    worktreeName: worktreeName,
                    worktreePath: worktree.path,
                    sessionID: sessionID,
                    context: "attach_session source=stream worker=\(workerID)",
                )
            }
        } catch {
            try? worktreeService.removeManagedWorktree(
                in: project.path,
                name: worktreeName,
                force: true,
            )
            await mutateDelegationLoggedIgnoringFailure(
                RuntimeDelegationMutationRequest(
                    kind: "complete",
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
                context: "cleanup_after_failed_start worker=\(workerID)",
            )
            throw error
        }
    }

    func submitReviewDecision(
        project: Project,
        delegation: RuntimeDelegationState,
        decision: ReviewDecision,
        note: String,
    ) async throws {
        let discoveredSessionID = delegation.sessionId ?? sessionDiscovery.mostRecentSessionID(for: delegation.worktreePath)
        guard let sessionID = discoveredSessionID else {
            throw NSError(
                domain: "Capacitor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Delegation session is missing"],
            )
        }

        if delegation.sessionId == nil {
            try await attachSession(
                projectPath: project.path,
                workerID: delegation.workerId,
                ideaID: delegation.ideaId,
                worktreeName: delegation.worktreeName,
                worktreePath: delegation.worktreePath,
                sessionID: sessionID,
                context: "attach_session source=review_action worker=\(delegation.workerId)",
            )
        }

        let paths = workerPaths(projectPath: project.path, workerID: delegation.workerId)
        try createWorkerDirectories(paths)
        try writeReviewDecision(decision: decision, note: note, to: paths)

        try await mutateDelegationLogged(
            RuntimeDelegationMutationRequest(
                kind: "resume",
                projectPath: project.path,
                workerId: delegation.workerId,
                ideaId: delegation.ideaId,
                worktreeName: delegation.worktreeName,
                worktreePath: delegation.worktreePath,
                sessionId: sessionID,
                milestoneId: delegation.currentReview?.milestoneId,
                briefPath: delegation.currentReview?.briefPath,
                manifestPath: delegation.currentReview?.manifestPath,
                reviewDecision: decision.rawValue,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note,
            ),
            context: "resume worker=\(delegation.workerId) decision=\(decision.rawValue)",
        )

        let prompt = buildResumePrompt(
            project: project,
            decision: decision,
            note: note,
            paths: paths,
        )
        try prompt.write(to: paths.resumePromptPath, atomically: true, encoding: .utf8)

        do {
            try await claudeLauncher(
                DelegationClaudeLaunchRequest(
                    workingDirectory: delegation.worktreePath,
                    prompt: prompt,
                    resumeSessionID: sessionID,
                ),
            ) { _ in }
        } catch {
            await mutateDelegationLoggedIgnoringFailure(
                RuntimeDelegationMutationRequest(
                    kind: "review_ready",
                    projectPath: project.path,
                    workerId: delegation.workerId,
                    ideaId: delegation.ideaId,
                    worktreeName: delegation.worktreeName,
                    worktreePath: delegation.worktreePath,
                    sessionId: sessionID,
                    milestoneId: delegation.currentReview?.milestoneId,
                    briefPath: delegation.currentReview?.briefPath,
                    manifestPath: delegation.currentReview?.manifestPath,
                    reviewDecision: nil,
                    note: nil,
                ),
                context: "restore_review_ready_after_resume_failure worker=\(delegation.workerId)",
            )
            throw error
        }
    }

    func reconcile(delegations: [RuntimeDelegationState]) async {
        for delegation in delegations {
            await reconcile(delegation: delegation)
        }
    }

    private func reconcile(delegation: RuntimeDelegationState) async {
        let paths = workerPaths(projectPath: delegation.projectPath, workerID: delegation.workerId)
        let discoveredSessionID = delegation.sessionId ?? sessionDiscovery.mostRecentSessionID(for: delegation.worktreePath)

        if delegation.sessionId == nil, let discoveredSessionID {
            await mutateDelegationLoggedIgnoringFailure(
                RuntimeDelegationMutationRequest(
                    kind: "attach_session",
                    projectPath: delegation.projectPath,
                    workerId: delegation.workerId,
                    ideaId: delegation.ideaId,
                    worktreeName: delegation.worktreeName,
                    worktreePath: delegation.worktreePath,
                    sessionId: discoveredSessionID,
                    milestoneId: nil,
                    briefPath: nil,
                    manifestPath: nil,
                    reviewDecision: nil,
                    note: nil,
                ),
                context: "attach_session source=reconcile worker=\(delegation.workerId)",
            )
        }

        guard delegation.status == "working" else { return }

        if fileManager.fileExists(atPath: paths.completionMarkerPath.path) {
            await mutateDelegationLoggedIgnoringFailure(
                RuntimeDelegationMutationRequest(
                    kind: "complete",
                    projectPath: delegation.projectPath,
                    workerId: delegation.workerId,
                    ideaId: delegation.ideaId,
                    worktreeName: delegation.worktreeName,
                    worktreePath: delegation.worktreePath,
                    sessionId: discoveredSessionID,
                    milestoneId: nil,
                    briefPath: nil,
                    manifestPath: nil,
                    reviewDecision: nil,
                    note: nil,
                ),
                context: "complete source=reconcile worker=\(delegation.workerId)",
            )
            return
        }

        if fileManager.fileExists(atPath: paths.decisionJSONPath.path) {
            return
        }

        guard fileManager.fileExists(atPath: paths.briefPath.path),
              fileManager.fileExists(atPath: paths.manifestPath.path)
        else {
            return
        }

        await mutateDelegationLoggedIgnoringFailure(
            RuntimeDelegationMutationRequest(
                kind: "review_ready",
                projectPath: delegation.projectPath,
                workerId: delegation.workerId,
                ideaId: delegation.ideaId,
                worktreeName: delegation.worktreeName,
                worktreePath: delegation.worktreePath,
                sessionId: discoveredSessionID,
                milestoneId: Constants.milestoneID,
                briefPath: paths.briefPath.path,
                manifestPath: paths.manifestPath.path,
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

    private func attachSession(
        projectPath: String,
        workerID: String,
        ideaID: String?,
        worktreeName: String?,
        worktreePath: String?,
        sessionID: String,
        context: String,
    ) async throws {
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

    private func workerPaths(projectPath: String, workerID: String) -> WorkerPaths {
        let workerRoot = CapacitorProjectPaths.projectDataDirectory(for: projectPath, fileManager: fileManager)
            .appendingPathComponent("delegations", isDirectory: true)
            .appendingPathComponent(workerID, isDirectory: true)
        let milestoneDirectory = workerRoot
            .appendingPathComponent("milestones", isDirectory: true)
            .appendingPathComponent(Constants.milestoneID, isDirectory: true)

        return WorkerPaths(
            workerRoot: workerRoot,
            statusPath: workerRoot.appendingPathComponent("status.md"),
            milestoneDirectory: milestoneDirectory,
            briefPath: milestoneDirectory.appendingPathComponent("brief.md"),
            manifestPath: milestoneDirectory.appendingPathComponent("manifest.json"),
            decisionJSONPath: milestoneDirectory.appendingPathComponent("decision.json"),
            decisionMarkdownPath: milestoneDirectory.appendingPathComponent("decision.md"),
            completionMarkerPath: workerRoot.appendingPathComponent("completion.json"),
            launchPromptPath: workerRoot.appendingPathComponent("launch-prompt.md"),
            resumePromptPath: workerRoot.appendingPathComponent("resume-prompt.md"),
        )
    }

    private func createWorkerDirectories(_ paths: WorkerPaths) throws {
        try fileManager.createDirectory(at: paths.workerRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.milestoneDirectory, withIntermediateDirectories: true)
    }

    private func writeReviewDecision(
        decision: ReviewDecision,
        note: String,
        to paths: WorkerPaths,
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
        try data.write(to: paths.decisionJSONPath, options: .atomic)

        let markdown = """
        # Review Decision

        - Decision: \(decision.rawValue)
        - Submitted At: \(payload.submittedAt)

        \(trimmedNote.isEmpty ? "No additional notes." : trimmedNote)
        """
        try markdown.write(to: paths.decisionMarkdownPath, atomically: true, encoding: .utf8)
    }

    private func buildInitialPrompt(
        project: Project,
        idea: Idea,
        workerID: String,
        worktreePath: String,
        paths: WorkerPaths,
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
        4. Update \(paths.statusPath.path) immediately with a short plan, then keep it current with concise progress notes.
        5. Produce exactly one reviewable checkpoint and stop there.
        6. Before stopping, write:
           - \(paths.briefPath.path)
           - \(paths.manifestPath.path)
        7. The manifest must be valid JSON with this shape:
           {
             "version": 1,
             "milestone_id": "\(Constants.milestoneID)",
             "summary": "short summary",
             "artifacts": [
               { "label": "artifact label", "path": "absolute or relative file path" }
             ]
           }
        8. Write \(paths.statusPath.path) before any substantial exploration or code changes.
        9. Do not continue past the review checkpoint in this run.
        10. Exit after writing the review files.

        Treat the review brief as the human-facing explanation of what changed, what still needs scrutiny, and what decision would unblock you.
        """
    }

    private func buildResumePrompt(
        project: Project,
        decision: ReviewDecision,
        note: String,
        paths: WorkerPaths,
    ) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        Resume the delegated work for \(project.name).

        Read the user's review decision from:
        - \(paths.decisionJSONPath.path)
        - \(paths.decisionMarkdownPath.path)

        Current decision: \(decision.rawValue)
        Notes:
        \(trimmedNote.isEmpty ? "No additional notes." : trimmedNote)

        Requirements:
        1. Apply the review feedback and finish the task in the current worktree.
        2. Do not spawn subagents and do not use the Agent tool.
        3. If the decision is approve and no changes were requested, do not continue exploration or new implementation work. Treat the approved checkpoint as final, update \(paths.statusPath.path), write the completion marker, and exit.
        4. If the decision is request_changes, address only the requested delta, then update \(paths.statusPath.path), write the completion marker, and exit.
        5. Do not open another review checkpoint in this slice.
        6. Update \(paths.statusPath.path) with final progress before exiting.
        7. When finished, write \(paths.completionMarkerPath.path) as JSON with:
           {
             "version": 1,
             "status": "completed",
             "completed_at": "<ISO8601 timestamp>",
             "summary": "short completion summary"
           }
        8. Exit after writing the completion marker.
        """
    }
}
