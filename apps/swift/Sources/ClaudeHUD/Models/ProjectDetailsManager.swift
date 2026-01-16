import Foundation

@MainActor
final class ProjectDetailsManager {
    private enum Constants {
        static let ideasCheckIntervalSeconds: TimeInterval = 2.0
        static let claudeMdTruncationLength = 3000
        static let fallbackTitleLength = 50
        static let claudeCliPath = "/opt/homebrew/bin/claude"
    }

    private let descriptionsFilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hud-project-descriptions.json")

    private(set) var projectIdeas: [String: [Idea]] = [:]
    private(set) var projectDescriptions: [String: String] = [:]
    private(set) var generatingTitleForIdeas: Set<String> = []
    private(set) var generatingDescriptionFor: Set<String> = []

    private var ideaFileMtimes: [String: Date] = [:]
    private var lastIdeasCheck: Date = .distantPast

    private weak var engine: HudEngine?

    func configure(engine: HudEngine?) {
        self.engine = engine
        loadProjectDescriptions()
    }

    // MARK: - Idea Capture

    func captureIdea(for project: Project, text: String) -> Result<Void, Error> {
        guard let engine = engine else {
            return .failure(NSError(domain: "HUD", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Engine not initialized"
            ]))
        }

        do {
            let ideaId = try engine.captureIdea(projectPath: project.path, ideaText: text)
            loadIdeas(for: project)
            generateTitleForIdea(ideaId: ideaId, description: text, project: project)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func loadIdeas(for project: Project) {
        guard let engine = engine else { return }

        do {
            let ideas = try engine.loadIdeas(projectPath: project.path)
            projectIdeas[project.path] = ideas

            let ideasFilePath = "\(project.path)/.claude/ideas.local.md"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: ideasFilePath),
               let mtime = attrs[.modificationDate] as? Date {
                ideaFileMtimes[project.path] = mtime
            }
        } catch {
            projectIdeas[project.path] = []
        }
    }

    func loadAllIdeas(for projects: [Project]) {
        for project in projects {
            loadIdeas(for: project)
        }
    }

    func checkIdeasFileChanges(for projects: [Project]) {
        let now = Date()
        guard now.timeIntervalSince(lastIdeasCheck) >= Constants.ideasCheckIntervalSeconds else { return }
        lastIdeasCheck = now

        for project in projects {
            let ideasFilePath = "\(project.path)/.claude/ideas.local.md"

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: ideasFilePath),
                  let currentMtime = attrs[.modificationDate] as? Date else {
                continue
            }

            if let lastKnownMtime = ideaFileMtimes[project.path] {
                if currentMtime > lastKnownMtime {
                    loadIdeas(for: project)
                }
            } else {
                loadIdeas(for: project)
            }
        }
    }

    func getIdeas(for project: Project) -> [Idea] {
        projectIdeas[project.path] ?? []
    }

    func isGeneratingTitle(for ideaId: String) -> Bool {
        generatingTitleForIdeas.contains(ideaId)
    }

    func updateIdeaStatus(for project: Project, idea: Idea, newStatus: String) throws {
        try engine?.updateIdeaStatus(
            projectPath: project.path,
            ideaId: idea.id,
            newStatus: newStatus
        )
        loadIdeas(for: project)
    }

    private func generateTitleForIdea(ideaId: String, description: String, project: Project) {
        generatingTitleForIdeas.insert(ideaId)

        _Concurrency.Task {
            do {
                let existingTitles = await MainActor.run {
                    getIdeas(for: project)
                        .filter { $0.id != ideaId && $0.title != "..." }
                        .prefix(10)
                        .map { "- \($0.title)" }
                        .joined(separator: "\n")
                }

                let title = try await generateWithHaiku(prompt: buildTitlePrompt(description: description, existingIdeas: existingTitles), stripTrailingPunctuation: true)

                await MainActor.run {
                    try? engine?.updateIdeaTitle(projectPath: project.path, ideaId: ideaId, newTitle: title)
                    loadIdeas(for: project)
                    generatingTitleForIdeas.remove(ideaId)
                }
            } catch {
                await MainActor.run {
                    let fallbackTitle = String(description.prefix(Constants.fallbackTitleLength))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try? engine?.updateIdeaTitle(projectPath: project.path, ideaId: ideaId, newTitle: fallbackTitle)
                    loadIdeas(for: project)
                    generatingTitleForIdeas.remove(ideaId)
                }
            }
        }
    }

    private func buildTitlePrompt(description: String, existingIdeas: String) -> String {
        let contextSection = existingIdeas.isEmpty ? "" : """

            Other ideas in this project (for context/uniqueness):
            \(existingIdeas)
            """

        return """
            Generate a concise 3-8 word title for this idea. Return ONLY the title text, no quotes, no punctuation unless part of a name.

            Idea: \(description)\(contextSection)
            """
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

    func getDescription(for project: Project) -> String? {
        projectDescriptions[project.path]
    }

    func isGeneratingDescription(for project: Project) -> Bool {
        generatingDescriptionFor.contains(project.path)
    }

    func generateDescription(for project: Project) {
        guard !generatingDescriptionFor.contains(project.path) else { return }
        generatingDescriptionFor.insert(project.path)

        _Concurrency.Task {
            do {
                let claudeMdPath = "\(project.path)/CLAUDE.md"
                let claudeMdContent: String

                if FileManager.default.fileExists(atPath: claudeMdPath) {
                    claudeMdContent = try String(contentsOfFile: claudeMdPath, encoding: .utf8)
                } else {
                    claudeMdContent = "Project: \(project.name)\nPath: \(project.path)"
                }

                let description = try await generateWithHaiku(
                    prompt: buildDescriptionPrompt(claudeMd: claudeMdContent, projectName: project.name),
                    stripTrailingPunctuation: false
                )

                await MainActor.run {
                    projectDescriptions[project.path] = description
                    saveProjectDescriptions()
                    generatingDescriptionFor.remove(project.path)
                }
            } catch {
                await MainActor.run {
                    projectDescriptions[project.path] = "A project at \(project.path)"
                    saveProjectDescriptions()
                    generatingDescriptionFor.remove(project.path)
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

                if process.terminationStatus == 0 && !output.isEmpty {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "HUD",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Haiku generation failed"]
                    ))
                }
            }
        }
    }

    nonisolated static func stripSurroundingQuotes(_ text: String) -> String {
        var result = text
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 2 {
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
