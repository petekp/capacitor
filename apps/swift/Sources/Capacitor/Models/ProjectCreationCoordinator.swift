import Foundation

@Observable
@MainActor
final class ProjectCreationCoordinator {
    private struct CreationMonitorHandle {
        let token: UUID
        let task: _Concurrency.Task<Void, Never>
    }

    private let ideaCaptureEnabled: @MainActor () -> Bool
    private let registerCreatedProjectHandler: @MainActor (String) throws -> Void
    private let dashboardReloader: @MainActor () -> Void
    private let claudeProjectsDirectoryProvider: () -> URL
    private(set) var creations: [ProjectCreation] = []

    @ObservationIgnored
    private var creationSessionMonitorTasks: [String: CreationMonitorHandle] = [:]
    @ObservationIgnored
    private var creationCompletionMonitorTasks: [String: CreationMonitorHandle] = [:]

    init(
        ideaCaptureEnabled: @escaping @MainActor () -> Bool,
        registerCreatedProject: @escaping @MainActor (String) throws -> Void,
        dashboardReloader: @escaping @MainActor () -> Void,
        claudeProjectsDirectoryProvider: @escaping () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
        },
    ) {
        self.ideaCaptureEnabled = ideaCaptureEnabled
        registerCreatedProjectHandler = registerCreatedProject
        self.dashboardReloader = dashboardReloader
        self.claudeProjectsDirectoryProvider = claudeProjectsDirectoryProvider
    }

    func loadCreations() {
        guard ideaCaptureEnabled() else { return }
        guard FileManager.default.fileExists(atPath: creationsPath.path) else { return }

        do {
            let data = try Data(contentsOf: creationsPath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loadedCreations = try decoder.decode([ProjectCreation].self, from: data)
            creations = cleanupCompletedCreations(loadedCreations)
        } catch {
            creations = []
        }
    }

    func startCreation(request: NewProjectRequest, projectPath: String) -> String {
        guard ideaCaptureEnabled() else { return UUID().uuidString }

        let id = UUID().uuidString
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let creation = ProjectCreation(
            id: id,
            name: request.name,
            path: projectPath,
            description: request.description,
            status: .pending,
            sessionId: nil,
            progress: CreationProgress(phase: "setup", message: "Initializing project...", percentComplete: 0),
            error: nil,
            createdAt: now,
            completedAt: nil,
        )

        mutateCreations { creations in
            creations.insert(creation, at: 0)
        }

        return id
    }

    func updateCreationStatus(
        _ id: String,
        status: CreationStatus,
        sessionId: String? = nil,
        error: String? = nil,
    ) {
        mutateCreations { creations in
            guard let index = creations.firstIndex(where: { $0.id == id }) else { return }
            creations[index].status = status
            if let sessionId {
                creations[index].sessionId = sessionId
            }
            if let error {
                creations[index].error = error
            }
            if status == .completed || status == .failed || status == .cancelled {
                creations[index].completedAt = ISO8601DateFormatter.shared.string(from: Date())
                cancelCreationMonitorTasks(for: id)
            }
        }
    }

    func updateCreationProgress(_ id: String, phase: String, message: String, percentComplete: Int?) {
        mutateCreations { creations in
            guard let index = creations.firstIndex(where: { $0.id == id }) else { return }
            creations[index].progress = CreationProgress(
                phase: phase,
                message: message,
                percentComplete: percentComplete.map { UInt8(clamping: $0) },
            )
        }
    }

    func cancelCreation(_ id: String) {
        updateCreationStatus(id, status: .cancelled)
    }

    func resumeCreation(_ id: String) {
        guard let creation = creations.first(where: { $0.id == id }),
              let sessionId = creation.sessionId,
              creation.status == .failed || creation.status == .cancelled
        else {
            return
        }

        updateCreationStatus(id, status: .inProgress)
        updateCreationProgress(id, phase: "resuming", message: "Resuming session...", percentComplete: 30)

        _Concurrency.Task {
            do {
                try await launchClaudeResume(projectPath: creation.path, sessionId: sessionId, creationId: id)
            } catch {
                await MainActor.run {
                    self.updateCreationStatus(id, status: .failed, error: "Failed to resume: \(error.localizedDescription)")
                }
            }
        }
    }

    func canResumeCreation(_ id: String) -> Bool {
        guard let creation = creations.first(where: { $0.id == id }) else {
            return false
        }
        return creation.sessionId != nil &&
            (creation.status == .failed || creation.status == .cancelled)
    }

    func createProjectFromIdea(
        _ request: NewProjectRequest,
        completion: @escaping (CreateProjectResult) -> Void,
    ) {
        _Concurrency.Task {
            do {
                let result = try await self.createProjectAsync(request)
                await MainActor.run {
                    completion(result)
                }
            } catch {
                await MainActor.run {
                    completion(CreateProjectResult(
                        success: false,
                        projectPath: "",
                        sessionId: nil,
                        error: error.localizedDescription,
                    ))
                }
            }
        }
    }

    #if DEBUG
        func registerCreatedProjectForTesting(_ projectPath: String) {
            registerCreatedProject(projectPath)
        }

        func applyDiscoveredSessionToCreationForTesting(_ creationId: String, sessionId: String) -> Bool {
            applyDiscoveredSessionToCreation(creationId, sessionId: sessionId)
        }

        func sessionFileURLForTesting(projectPath: String, sessionId: String) -> URL {
            claudeProjectsDirectoryProvider()
                .appendingPathComponent(encodedSessionDirectoryName(for: projectPath))
                .appendingPathComponent("\(sessionId).jsonl")
        }

        func setCreationMonitorTasksForTesting(
            creationId: String,
            sessionTask: _Concurrency.Task<Void, Never>?,
            completionTask: _Concurrency.Task<Void, Never>?,
        ) {
            if let sessionTask {
                creationSessionMonitorTasks[creationId] = CreationMonitorHandle(token: UUID(), task: sessionTask)
            } else {
                creationSessionMonitorTasks.removeValue(forKey: creationId)
            }

            if let completionTask {
                creationCompletionMonitorTasks[creationId] = CreationMonitorHandle(token: UUID(), task: completionTask)
            } else {
                creationCompletionMonitorTasks.removeValue(forKey: creationId)
            }
        }

        func hasCreationMonitorTasksForTesting(creationId: String) -> Bool {
            creationSessionMonitorTasks[creationId] != nil || creationCompletionMonitorTasks[creationId] != nil
        }

        func selectDiscoveredSessionIdForTesting(projectPath: String, existingSessions: Set<String>) -> String? {
            selectDiscoveredSessionId(projectPath: projectPath, existingSessions: existingSessions)
        }

        func setCreationsForTesting(_ creations: [ProjectCreation]) {
            self.creations = creations
        }
    #endif

    private var creationsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/creations.json")
    }

    private func mutateCreations(_ mutate: (inout [ProjectCreation]) -> Void) {
        mutate(&creations)
        saveCreationsIfNeeded(creations)
    }

    private func saveCreationsIfNeeded(_ creations: [ProjectCreation]) {
        guard ideaCaptureEnabled() else { return }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(creations)
            try data.write(to: creationsPath)
        } catch {
            // Silently fail
        }
    }

    private func cleanupCompletedCreations(_ creations: [ProjectCreation]) -> [ProjectCreation] {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        return creations.filter { creation in
            if creation.status == .completed || creation.status == .failed || creation.status == .cancelled {
                let completionDate = creation.completedAtDate ?? creation.createdAtDate ?? Date.distantPast
                return completionDate > cutoff
            }
            return true
        }
    }

    private func applyDiscoveredSessionToCreation(_ creationId: String, sessionId: String) -> Bool {
        guard let creation = creations.first(where: { $0.id == creationId }) else {
            return false
        }

        guard creation.status == .pending || creation.status == .inProgress else {
            return false
        }

        updateCreationStatus(creationId, status: .inProgress, sessionId: sessionId)
        updateCreationProgress(creationId, phase: "building", message: "Claude is building your project...", percentComplete: 40)
        return true
    }

    private func cancelCreationMonitorTasks(for creationId: String) {
        if let handle = creationSessionMonitorTasks.removeValue(forKey: creationId) {
            handle.task.cancel()
        }
        if let handle = creationCompletionMonitorTasks.removeValue(forKey: creationId) {
            handle.task.cancel()
        }
    }

    private func clearCreationSessionMonitorTask(_ creationId: String, matching token: UUID) {
        guard let handle = creationSessionMonitorTasks[creationId], handle.token == token else {
            return
        }
        creationSessionMonitorTasks.removeValue(forKey: creationId)
    }

    private func clearCreationCompletionMonitorTask(_ creationId: String, matching token: UUID) {
        guard let handle = creationCompletionMonitorTasks[creationId], handle.token == token else {
            return
        }
        creationCompletionMonitorTasks.removeValue(forKey: creationId)
    }

    private func createProjectAsync(_ request: NewProjectRequest) async throws -> CreateProjectResult {
        let location = (request.location as NSString).expandingTildeInPath
        let sanitizedName = request.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        let projectPath = (location as NSString).appendingPathComponent(sanitizedName)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: projectPath) {
            return CreateProjectResult(
                success: false,
                projectPath: projectPath,
                sessionId: nil,
                error: "Project directory already exists",
            )
        }

        let creationId = await MainActor.run {
            self.startCreation(request: request, projectPath: projectPath)
        }

        await MainActor.run {
            self.updateCreationProgress(creationId, phase: "setup", message: "Creating project directory...", percentComplete: 10)
        }

        try fileManager.createDirectory(atPath: projectPath, withIntermediateDirectories: true)

        await MainActor.run {
            self.updateCreationProgress(creationId, phase: "setup", message: "Generating CLAUDE.md...", percentComplete: 20)
        }

        let claudeMd = generateClaudeMd(request)
        let claudeMdPath = (projectPath as NSString).appendingPathComponent("CLAUDE.md")
        try claudeMd.write(toFile: claudeMdPath, atomically: true, encoding: .utf8)

        await MainActor.run {
            self.updateCreationProgress(creationId, phase: "building", message: "Launching Claude to build v1...", percentComplete: 30)
            self.updateCreationStatus(creationId, status: .inProgress)
        }

        let prompt = buildCreationPrompt(request)

        let sessionId: String?
        do {
            sessionId = try await runClaudeForProject(projectPath: projectPath, prompt: prompt, creationId: creationId)
        } catch {
            await MainActor.run {
                self.updateCreationStatus(creationId, status: .failed, error: "Failed to run Claude: \(error.localizedDescription)")
            }
            return CreateProjectResult(
                success: false,
                projectPath: projectPath,
                sessionId: nil,
                error: "Failed to run Claude: \(error.localizedDescription)",
            )
        }

        registerCreatedProject(projectPath)

        await MainActor.run {
            self.updateCreationProgress(creationId, phase: "building", message: "Claude is building your project in the terminal...", percentComplete: 50)
        }

        return CreateProjectResult(
            success: true,
            projectPath: projectPath,
            sessionId: sessionId,
            error: nil,
        )
    }

    private func generateClaudeMd(_ request: NewProjectRequest) -> String {
        var content = "# \(request.name)\n\n"
        content += "## Overview\n\n"
        content += "\(request.description)\n\n"

        if request.language != nil || request.framework != nil {
            content += "## Tech Stack\n\n"
            if let language = request.language {
                content += "- Language: \(language.capitalized)\n"
            }
            if let framework = request.framework {
                content += "- Framework: \(framework)\n"
            }
            content += "\n"
        }

        content += "## Status\n\n"
        content += "🚀 Initial v1 bootstrap in progress\n"

        return content
    }

    private func buildCreationPrompt(_ request: NewProjectRequest) -> String {
        var prompt = """
        Create a working v1 of "\(request.name)".

        Description: \(request.description)

        """

        if let language = request.language {
            prompt += "Use \(language) as the primary language.\n"
        }

        if let framework = request.framework {
            prompt += "Use \(framework) as the framework.\n"
        }

        prompt += """

        Requirements:
        - Create a WORKING implementation, not just scaffolding
        - Include a README.md with clear usage instructions
        - Make it runnable with a simple command (npm start, cargo run, etc.)
        - Focus on functionality over perfection - a working v1 is the goal
        - Include basic error handling
        """

        return prompt
    }

    private func registerCreatedProject(_ projectPath: String) {
        do {
            try registerCreatedProjectHandler(projectPath)
        } catch {
            // Continue even if adding to HUD fails
        }
    }

    private func runClaudeForProject(projectPath: String, prompt: String, creationId: String) async throws -> String? {
        let tempDir = FileManager.default.temporaryDirectory
        let promptFile = tempDir.appendingPathComponent("claude-prompt-\(UUID().uuidString).txt")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

        let existingSessions = getExistingSessionIds(for: projectPath)

        let claudeCmd = "/opt/homebrew/bin/claude \"$(cat '\(promptFile.path)')\" ; rm -f '\(promptFile.path)'"
        let script = TerminalScripts.launchWithCommand(projectPath: projectPath, command: claudeCmd)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        try process.run()

        startSessionMonitor(projectPath: projectPath, creationId: creationId, existingSessions: existingSessions)

        return nil
    }

    private func getExistingSessionIds(for projectPath: String) -> Set<String> {
        Set(sessionFiles(for: projectPath).map { $0.deletingPathExtension().lastPathComponent })
    }

    private func selectDiscoveredSessionId(projectPath: String, existingSessions: Set<String>) -> String? {
        let newSessionFiles = sessionFiles(for: projectPath)
            .filter { !existingSessions.contains($0.deletingPathExtension().lastPathComponent) }

        return newSessionFiles
            .sorted(by: compareSessionFiles)
            .first?
            .deletingPathExtension()
            .lastPathComponent
    }

    private func sessionFiles(for projectPath: String) -> [URL] {
        let sessionDir = claudeProjectsDirectoryProvider().appendingPathComponent(encodedSessionDirectoryName(for: projectPath))

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
        ) else {
            return []
        }

        return files.filter { $0.pathExtension == "jsonl" }
    }

    private func encodedSessionDirectoryName(for projectPath: String) -> String {
        projectPath
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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

    private func startSessionMonitor(projectPath: String, creationId: String, existingSessions: Set<String>) {
        let token = UUID()
        let task = _Concurrency.Task { [weak self] in
            defer {
                _Concurrency.Task { @MainActor [weak self] in
                    self?.clearCreationSessionMonitorTask(creationId, matching: token)
                }
            }

            guard let self else { return }
            let maxAttempts = 60
            let pollInterval: UInt64 = 2_000_000_000

            for _ in 0 ..< maxAttempts {
                do {
                    try await _Concurrency.Task.sleep(nanoseconds: pollInterval)
                } catch {
                    return
                }

                if let sessionId = selectDiscoveredSessionId(
                    projectPath: projectPath,
                    existingSessions: existingSessions,
                ) {
                    if _Concurrency.Task.isCancelled {
                        return
                    }
                    guard await MainActor.run(body: {
                        self.applyDiscoveredSessionToCreation(creationId, sessionId: sessionId)
                    }) else {
                        return
                    }
                    startCompletionMonitor(projectPath: projectPath, creationId: creationId, sessionId: sessionId)
                    return
                }
            }
        }

        if let existingTask = creationSessionMonitorTasks[creationId]?.task {
            existingTask.cancel()
        }
        creationSessionMonitorTasks[creationId] = CreationMonitorHandle(token: token, task: task)
    }

    private func startCompletionMonitor(projectPath: String, creationId: String, sessionId: String) {
        let token = UUID()
        let task = _Concurrency.Task { [weak self] in
            defer {
                _Concurrency.Task { @MainActor [weak self] in
                    self?.clearCreationCompletionMonitorTask(creationId, matching: token)
                }
            }

            guard let self else { return }
            let sessionFile = claudeProjectsDirectoryProvider()
                .appendingPathComponent(encodedSessionDirectoryName(for: projectPath))
                .appendingPathComponent("\(sessionId).jsonl")

            var lastSize: UInt64 = 0
            var stableCount = 0
            let maxStableChecks = 30

            for _ in 0 ..< 300 {
                do {
                    try await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }

                if _Concurrency.Task.isCancelled {
                    return
                }

                guard let creation = creations.first(where: { $0.id == creationId }),
                      creation.status == .inProgress
                else {
                    return
                }

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFile.path),
                      let currentSize = attrs[.size] as? UInt64
                else {
                    continue
                }

                if currentSize == lastSize {
                    stableCount += 1
                    if stableCount >= maxStableChecks {
                        await MainActor.run {
                            self.updateCreationStatus(creationId, status: .completed)
                            self.updateCreationProgress(creationId, phase: "complete", message: "Project created successfully!", percentComplete: 100)
                            self.dashboardReloader()
                        }
                        return
                    }
                } else {
                    stableCount = 0
                    lastSize = currentSize

                    let progress = min(90, 40 + (stableCount * 2))
                    await MainActor.run {
                        self.updateCreationProgress(creationId, phase: "building", message: "Claude is building your project...", percentComplete: progress)
                    }
                }
            }
        }

        if let existingTask = creationCompletionMonitorTasks[creationId]?.task {
            existingTask.cancel()
        }
        creationCompletionMonitorTasks[creationId] = CreationMonitorHandle(token: token, task: task)
    }

    private func launchClaudeResume(projectPath: String, sessionId: String, creationId: String) async throws {
        let claudeCmd = "/opt/homebrew/bin/claude --resume \(sessionId)"
        let script = TerminalScripts.launchWithCommand(projectPath: projectPath, command: claudeCmd)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        try process.run()

        startCompletionMonitor(projectPath: projectPath, creationId: creationId, sessionId: sessionId)
    }
}
