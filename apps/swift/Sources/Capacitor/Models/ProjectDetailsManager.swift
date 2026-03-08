import Foundation

@Observable
@MainActor
final class ProjectDetailsManager {
    private enum Constants {
        static let ideasCheckIntervalSeconds: TimeInterval = 2.0
        static let claudeMdTruncationLength = 3000
        static let fallbackTitleLength = 50
        static let claudeCliPath = "/opt/homebrew/bin/claude"
    }

    private let descriptionsFilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".capacitor/project-descriptions.json")
    private let gitCommandExecutor: @Sendable (String, [String]) -> String?

    private(set) var projectIdeas: [String: [Idea]] = [:]
    private(set) var projectDescriptions: [String: String] = [:]
    private(set) var generatingTitleForIdeas: Set<String> = []
    private(set) var generatingDescriptionFor: Set<String> = []

    private var ideaFileMtimes: [String: Date] = [:]
    private var lastIdeasCheck: Date = .distantPast

    private weak var engine: CoreRuntime?

    init(
        gitCommandExecutor: @escaping @Sendable (String, [String]) -> String? = { projectPath, arguments in
            ProjectDetailsManager.runGitCommand(projectPath: projectPath, arguments: arguments)
        },
    ) {
        self.gitCommandExecutor = gitCommandExecutor
    }

    func configure(engine: CoreRuntime?) {
        self.engine = engine
        loadProjectDescriptions()
    }

    // MARK: - Idea Capture

    func captureIdea(for project: some ShellProjectReferenceProviding, text: String) -> Result<Void, Error> {
        let projectReference = project.shellProjectReference
        guard let engine else {
            return .failure(NSError(domain: "HUD", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Engine not initialized",
            ]))
        }

        do {
            let ideaId = try engine.captureIdea(projectPath: projectReference.path, ideaText: text)
            loadIdeas(for: projectReference)
            sensemakeIdea(ideaId: ideaId, rawInput: text, project: projectReference)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func loadIdeas(for project: some ShellProjectReferenceProviding) {
        let projectReference = project.shellProjectReference
        guard let engine else { return }

        do {
            let ideas = try engine.loadIdeas(projectPath: projectReference.path)

            // Apply saved order (self-healing: missing IDs skipped, new ideas appended)
            let orderedIdeas = applyIdeasOrder(ideas: ideas, for: projectReference)
            projectIdeas[projectReference.path] = orderedIdeas

            // Track mtime for change detection (ideas now in global storage)
            let ideasFilePath = engine.getIdeasFilePath(projectPath: projectReference.path)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: ideasFilePath),
               let mtime = attrs[.modificationDate] as? Date
            {
                ideaFileMtimes[projectReference.path] = mtime
            }
        } catch {
            projectIdeas[projectReference.path] = []
        }
    }

    private func applyIdeasOrder(ideas: [Idea], for project: some ShellProjectReferenceProviding) -> [Idea] {
        let projectReference = project.shellProjectReference
        guard let engine else { return ideas }

        do {
            let orderedIds = try engine.loadIdeasOrder(projectPath: projectReference.path)
            guard !orderedIds.isEmpty else { return ideas }

            // Build lookup for O(1) access
            var ideasById: [String: Idea] = [:]
            for idea in ideas {
                ideasById[idea.id] = idea
            }

            // Collect ordered ideas first
            var result: [Idea] = []
            var usedIds: Set<String> = []

            for id in orderedIds {
                if let idea = ideasById[id] {
                    result.append(idea)
                    usedIds.insert(id)
                }
                // Missing IDs silently skipped (self-healing)
            }

            // Append any new ideas not in order file (preserves ULID order)
            for idea in ideas where !usedIds.contains(idea.id) {
                result.append(idea)
            }

            return result
        } catch {
            // Graceful degradation: return original order
            return ideas
        }
    }

    func loadAllIdeas(for projects: [some ShellProjectReferenceProviding]) {
        for project in projects {
            loadIdeas(for: project)
        }
    }

    func loadAllIdeasIncrementally(
        for projects: [some ShellProjectReferenceProviding],
        batchSize: Int = 2,
    ) async {
        guard batchSize > 0 else {
            loadAllIdeas(for: projects)
            return
        }

        for (index, project) in projects.enumerated() {
            loadIdeas(for: project)
            if (index + 1) % batchSize == 0 {
                await _Concurrency.Task.yield()
            }
        }
    }

    func checkIdeasFileChanges(for projects: [some ShellProjectReferenceProviding]) {
        let now = Date()
        guard now.timeIntervalSince(lastIdeasCheck) >= Constants.ideasCheckIntervalSeconds else { return }
        lastIdeasCheck = now

        guard let engine else { return }

        for project in projects {
            let projectReference = project.shellProjectReference
            let ideasFilePath = engine.getIdeasFilePath(projectPath: projectReference.path)

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: ideasFilePath),
                  let currentMtime = attrs[.modificationDate] as? Date
            else {
                continue
            }

            if let lastKnownMtime = ideaFileMtimes[projectReference.path] {
                if currentMtime > lastKnownMtime {
                    loadIdeas(for: projectReference)
                }
            } else {
                loadIdeas(for: projectReference)
            }
        }
    }

    func getIdeas(for project: some ProjectPathProviding) -> [Idea] {
        projectIdeas[project.path] ?? []
    }

    func isGeneratingTitle(for ideaId: String) -> Bool {
        generatingTitleForIdeas.contains(ideaId)
    }

    func updateIdeaStatus(for project: some ShellProjectReferenceProviding, idea: Idea, newStatus: String) throws {
        let projectReference = project.shellProjectReference
        try engine?.updateIdeaStatus(
            projectPath: projectReference.path,
            ideaId: idea.id,
            newStatus: newStatus,
        )
        loadIdeas(for: projectReference)
    }

    func reorderIdeas(_ reorderedIdeas: [Idea], for project: some ShellProjectReferenceProviding) {
        let projectReference = project.shellProjectReference
        projectIdeas[projectReference.path] = reorderedIdeas

        // Persist order to disk asynchronously
        let ideaIds = reorderedIdeas.map(\.id)
        _Concurrency.Task {
            do {
                try engine?.saveIdeasOrder(projectPath: projectReference.path, ideaIds: ideaIds)
            } catch {
                // Silently fail - order will be regenerated from ULID sort
            }
        }
    }

    // MARK: - Sensemaking

    private struct SensemakingResult: Decodable {
        let title: String
        let description: String?
        let confidence: Double?
    }

    private func sensemakeIdea(ideaId: String, rawInput: String, project: ShellProjectReference) {
        generatingTitleForIdeas.insert(ideaId)

        _Concurrency.Task {
            do {
                // Gather context
                let context = await gatherSensemakingContext(for: project, excluding: ideaId)

                // Build and run prompt
                let prompt = buildSensemakingPrompt(rawInput: rawInput, context: context)
                let response = try await generateWithHaiku(prompt: prompt, stripTrailingPunctuation: false)

                // Parse JSON response
                let result = try parseSensemakingResponse(response)

                await MainActor.run {
                    // Update title
                    try? engine?.updateIdeaTitle(projectPath: project.path, ideaId: ideaId, newTitle: result.title)

                    // Update description if we got an expansion
                    if let expandedDescription = result.description, !expandedDescription.isEmpty {
                        try? engine?.updateIdeaDescription(projectPath: project.path, ideaId: ideaId, newDescription: expandedDescription)
                    }

                    loadIdeas(for: project)
                    generatingTitleForIdeas.remove(ideaId)
                }
            } catch {
                await MainActor.run {
                    // Fallback: use truncated raw input as title
                    let fallbackTitle = String(rawInput.prefix(Constants.fallbackTitleLength))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try? engine?.updateIdeaTitle(projectPath: project.path, ideaId: ideaId, newTitle: fallbackTitle)
                    loadIdeas(for: project)
                    generatingTitleForIdeas.remove(ideaId)
                }
            }
        }
    }

    private struct SensemakingContext {
        let projectName: String
        let existingTitles: String
        let recentFiles: [String]
        let gitBranch: String?
        let lastCommitMessage: String?
    }

    private struct GitSensemakingContext {
        let recentFiles: [String]
        let gitBranch: String?
        let lastCommitMessage: String?
    }

    private func gatherSensemakingContext(for project: ShellProjectReference, excluding ideaId: String) async -> SensemakingContext {
        // Get existing idea titles for uniqueness
        let existingTitles = await MainActor.run {
            getIdeas(for: project)
                .filter { $0.id != ideaId && $0.title != "..." }
                .prefix(5)
                .map { "- \($0.title)" }
                .joined(separator: "\n")
        }

        let gitContext = await Self.loadGitSensemakingContext(
            projectPath: project.path,
            limit: 5,
            executor: gitCommandExecutor,
        )

        return SensemakingContext(
            projectName: project.displayName,
            existingTitles: existingTitles,
            recentFiles: gitContext.recentFiles,
            gitBranch: gitContext.gitBranch,
            lastCommitMessage: gitContext.lastCommitMessage,
        )
    }

    private nonisolated static func loadGitSensemakingContext(
        projectPath: String,
        limit: Int,
        executor: @escaping @Sendable (String, [String]) -> String?,
    ) async -> GitSensemakingContext {
        await _Concurrency.Task.detached(priority: .utility) {
            GitSensemakingContext(
                recentFiles: recentFiles(projectPath: projectPath, limit: limit, executor: executor),
                gitBranch: gitBranch(projectPath: projectPath, executor: executor),
                lastCommitMessage: lastCommitMessage(projectPath: projectPath, executor: executor),
            )
        }.value
    }

    private nonisolated static func recentFiles(
        projectPath: String,
        limit: Int,
        executor: @escaping @Sendable (String, [String]) -> String?,
    ) -> [String] {
        guard let output = executor(projectPath, ["diff", "--name-only", "HEAD~3", "HEAD"]) else {
            return []
        }

        return output.split(separator: "\n").prefix(limit).map(String.init)
    }

    private nonisolated static func gitBranch(
        projectPath: String,
        executor: @escaping @Sendable (String, [String]) -> String?,
    ) -> String? {
        trimmedGitOutput(
            executor(projectPath, ["branch", "--show-current"]),
        )
    }

    private nonisolated static func lastCommitMessage(
        projectPath: String,
        executor: @escaping @Sendable (String, [String]) -> String?,
    ) -> String? {
        trimmedGitOutput(
            executor(projectPath, ["log", "-1", "--format=%s"]),
        )
    }

    private nonisolated static func trimmedGitOutput(_ output: String?) -> String? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private nonisolated static func runGitCommand(
        projectPath: String,
        arguments: [String],
    ) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    #if DEBUG
        func gatherSensemakingContextForTesting(
            for project: some ShellProjectReferenceProviding,
            excluding ideaId: String,
        ) async -> (recentFiles: [String], gitBranch: String?, lastCommitMessage: String?) {
            let context = await gatherSensemakingContext(for: project.shellProjectReference, excluding: ideaId)
            return (context.recentFiles, context.gitBranch, context.lastCommitMessage)
        }
    #endif

    private func buildSensemakingPrompt(rawInput: String, context: SensemakingContext) -> String {
        var contextParts: [String] = []

        if !context.existingTitles.isEmpty {
            contextParts.append("Existing ideas:\n\(context.existingTitles)")
        }

        if !context.recentFiles.isEmpty {
            contextParts.append("Recent files: \(context.recentFiles.joined(separator: ", "))")
        }

        if let branch = context.gitBranch {
            contextParts.append("Branch: \(branch)")
        }

        if let commit = context.lastCommitMessage {
            contextParts.append("Last commit: \(commit)")
        }

        let contextSection = contextParts.isEmpty ? "" : "\n\nContext:\n\(contextParts.joined(separator: "\n"))"

        return """
        Transform this raw idea capture into a structured format.

        ASSESS the input:
        - If VAGUE (e.g., "that auth thing"): provide title AND 1-2 sentence description expanding what this likely means
        - If MODERATE (e.g., "fix timeout in auth flow"): provide title AND brief description
        - If SPECIFIC (e.g., "In auth.ts:42, handle 401"): provide title only, description can be null

        Project: \(context.projectName)
        Raw input: \(rawInput)\(contextSection)

        Return ONLY valid JSON (no markdown, no explanation):
        {"title": "3-8 word title", "description": "expansion or null", "confidence": 0.0-1.0}
        """
    }

    private func parseSensemakingResponse(_ response: String) throws -> SensemakingResult {
        // Clean up response - extract JSON if wrapped in markdown code blocks
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code block if present
        if json.hasPrefix("```") {
            let lines = json.split(separator: "\n", omittingEmptySubsequences: false)
            let filtered = lines.dropFirst().dropLast().joined(separator: "\n")
            json = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Handle case where model returns ```json ... ```
        if json.hasPrefix("json") {
            json = String(json.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "Sensemaking", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8"])
        }

        return try JSONDecoder().decode(SensemakingResult.self, from: data)
    }

    // MARK: - Project Descriptions

    private func loadProjectDescriptions() {
        guard FileManager.default.fileExists(atPath: descriptionsFilePath.path) else { return }

        do {
            let data = try Data(contentsOf: descriptionsFilePath)
            projectDescriptions = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            projectDescriptions = [:]
        }
    }

    private func saveProjectDescriptions() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(projectDescriptions)
            try data.write(to: descriptionsFilePath)
        } catch {
            // Silently fail - descriptions will be regenerated next time
        }
    }

    func getDescription(for project: some ProjectPathProviding) -> String? {
        projectDescriptions[project.path]
    }

    func isGeneratingDescription(for project: some ProjectPathProviding) -> Bool {
        generatingDescriptionFor.contains(project.path)
    }

    func generateDescription(for project: some ShellProjectReferenceProviding) {
        let projectReference = project.shellProjectReference
        guard !generatingDescriptionFor.contains(projectReference.path) else { return }
        generatingDescriptionFor.insert(projectReference.path)

        _Concurrency.Task {
            do {
                let claudeMdPath = "\(projectReference.path)/CLAUDE.md"
                let claudeMdContent: String = if FileManager.default.fileExists(atPath: claudeMdPath) {
                    try String(contentsOfFile: claudeMdPath, encoding: .utf8)
                } else {
                    "Project: \(projectReference.displayName)\nPath: \(projectReference.path)"
                }

                let description = try await generateWithHaiku(
                    prompt: buildDescriptionPrompt(claudeMd: claudeMdContent, projectName: projectReference.displayName),
                    stripTrailingPunctuation: false,
                )

                await MainActor.run {
                    projectDescriptions[projectReference.path] = description
                    saveProjectDescriptions()
                    generatingDescriptionFor.remove(projectReference.path)
                }
            } catch {
                await MainActor.run {
                    projectDescriptions[projectReference.path] = "A project at \(projectReference.path)"
                    saveProjectDescriptions()
                    generatingDescriptionFor.remove(projectReference.path)
                }
            }
        }
    }

    private func buildDescriptionPrompt(claudeMd: String, projectName: String) -> String {
        let truncatedContent = String(claudeMd.prefix(Constants.claudeMdTruncationLength))

        return """
        Generate a concise 1-2 sentence description of this project based on its CLAUDE.md file.
        Focus on WHAT the project does and its PURPOSE, not implementation details.
        Return ONLY the description text, no quotes, no markdown formatting.

        Project: \(projectName)

        CLAUDE.md content:
        \(truncatedContent)
        """
    }
}

// MARK: - Haiku CLI Integration

private extension ProjectDetailsManager {
    func generateWithHaiku(prompt: String, stripTrailingPunctuation: Bool) async throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: Constants.claudeCliPath)
        process.arguments = ["--print", "--model", "haiku", prompt]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                var output = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                output = Self.stripSurroundingQuotes(output)

                if stripTrailingPunctuation {
                    output = Self.stripTrailingPunctuation(output)
                }

                if process.terminationStatus == 0, !output.isEmpty {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "HUD",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Haiku generation failed"],
                    ))
                }
            }
        }
    }

    nonisolated static func stripSurroundingQuotes(_ text: String) -> String {
        var result = text
        if result.hasPrefix("\""), result.hasSuffix("\""), result.count > 2 {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }

    nonisolated static func stripTrailingPunctuation(_ text: String) -> String {
        var result = text
        while result.hasSuffix(".") || result.hasSuffix("!") || result.hasSuffix("?") {
            result = String(result.dropLast())
        }
        return result
    }
}
