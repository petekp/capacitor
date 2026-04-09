import CryptoKit
import Foundation

/// Coordinates per-project session summarization by reading recent JSONL transcript
/// context, invoking Claude Haiku to generate a one-line summary, and writing the
/// result to `.claude/hud-status.json` in each project directory.
///
/// This feeds the existing pipeline:
///   `.claude/hud-status.json` -> Rust `read_project_status()` -> Swift `refreshProjectStatuses()` -> Card
@Observable
@MainActor
final class SessionSummarizer {
    // MARK: - Configuration

    private enum Constants {
        /// Minimum interval between summarizations for the same project.
        static let summarizationCooldownSeconds: TimeInterval = 25
        /// After a session goes idle for this long, clear the working_on field.
        static let idleClearDelaySeconds: TimeInterval = 300 // 5 minutes
        /// Character targets for each summary variant tier.
        static let variantShortChars = 25
        static let variantMediumChars = 40
        static let variantLongChars = 60
        /// Average character width in points for .callout font on macOS.
        static let averageCharWidthPts: CGFloat = 6.5
        /// Horizontal padding consumed by the card chrome (leading + trailing).
        static let cardHorizontalPaddingPts: CGFloat = 24
        /// Initial tail window to read from the JSONL file before expanding.
        static let jsonlTailBytes = 32768
        /// Adaptive tail windows for extracting structured signal from tool-heavy transcripts.
        static let windowSizes = [32768, 65536, 131_072, 262_144]
        /// Target context string length for the prompt.
        static let maxContextLength = 1000
    }

    private struct ContextExtraction {
        var intentItems: [String]
        var progressSnippets: [String]
        var toolNames: [String]
    }

    // MARK: - Summary Variants

    /// Pre-generated summary variants at different lengths, keyed by project path.
    /// The card picks the longest one that fits the current width.
    struct SummaryVariants {
        let short: String // ~25 chars
        let medium: String // ~40 chars
        let long: String // ~60 chars
    }

    /// Cached variants per project path.
    private(set) var cachedVariants: [String: SummaryVariants] = [:]
    /// SHA-256 fingerprint of the last context string per project path.
    private var contextFingerprints: [String: String] = [:]

    /// Current card content width in points. Updated by the view layer.
    var cardContentWidth: CGFloat = 0

    /// Returns the best-fitting summary for the given project path and current card width.
    func bestSummary(for projectPath: String) -> String? {
        guard let variants = cachedVariants[projectPath] else { return nil }
        let charBudget = currentCharacterBudget
        if charBudget >= variants.long.count { return variants.long }
        if charBudget >= variants.medium.count { return variants.medium }
        return variants.short
    }

    /// Character budget derived from current card width.
    private var currentCharacterBudget: Int {
        guard cardContentWidth > 0 else { return Constants.variantMediumChars }
        let textWidth = cardContentWidth - Constants.cardHorizontalPaddingPts
        return max(Int(textWidth / Constants.averageCharWidthPts), Constants.variantShortChars)
    }

    // MARK: - Per-project tracking

    /// When we last successfully summarized each project (keyed by project path).
    private var lastSummarizedAt: [String: Date] = [:]
    /// When each project was first observed as idle (for idle-clear timing).
    private var idleSince: [String: Date] = [:]
    /// Projects currently being summarized (prevents concurrent summarization).
    private var activeSummarizations: Set<String> = []

    // MARK: - Dependencies (injectable for testing)

    private let claudePathResolver: @Sendable () async -> String?
    private let fileManager: FileManager
    private let clock: () -> Date
    /// Override for testing — when nil, uses the real ~/.claude/projects/ path.
    private let claudeProjectsDirectory: URL?

    init(
        claudePathResolver: @escaping @Sendable () async -> String? = {
            await ClaudeCliResolver.shared.resolveClaudePath()
        },
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = { Date() },
        claudeProjectsDirectory: URL? = nil,
    ) {
        self.claudePathResolver = claudePathResolver
        self.fileManager = fileManager
        self.clock = clock
        self.claudeProjectsDirectory = claudeProjectsDirectory
    }

    // MARK: - Public API

    /// Evaluates all projects and triggers summarization where appropriate.
    /// Called from AppState's 2-second refresh timer.
    func evaluateProjects(
        projects: [Project],
        sessionStates: [String: ProjectSessionState],
        delegationStates: [String: RuntimeDelegationState],
    ) {
        let now = clock()

        for project in projects {
            let path = project.path
            let normalizedPath = PathNormalizer.normalize(path)
            let sessionState = sessionStates[path]
            let state = sessionState?.state

            // Skip if delegation is active for this project
            let hasDelegation = delegationStates[normalizedPath] != nil
            if hasDelegation {
                continue
            }

            // Skip if already summarizing
            if activeSummarizations.contains(path) {
                continue
            }

            // Handle idle-clear logic
            if state == .idle || state == nil {
                if idleSince[path] == nil {
                    idleSince[path] = now
                }
                if let idleStart = idleSince[path],
                   now.timeIntervalSince(idleStart) >= Constants.idleClearDelaySeconds
                {
                    clearWorkingOn(for: project)
                    idleSince[path] = nil // Reset so we don't keep writing
                }
                // If idle and last summary was recent, skip
                if let lastSummary = lastSummarizedAt[path],
                   now.timeIntervalSince(lastSummary) < Constants.idleClearDelaySeconds
                {
                    continue
                }
                continue
            }

            // Reset idle tracker when not idle
            idleSince.removeValue(forKey: path)

            // Skip if last summarized too recently
            if let lastSummary = lastSummarizedAt[path],
               now.timeIntervalSince(lastSummary) < Constants.summarizationCooldownSeconds
            {
                continue
            }

            // Trigger summarization for working/ready sessions
            if state == .working || state == .ready {
                triggerSummarization(for: project, preferredSessionID: sessionState?.sessionId)
            }
        }
    }

    // MARK: - Summarization Pipeline

    private func triggerSummarization(for project: Project, preferredSessionID: String?) {
        let path = project.path
        activeSummarizations.insert(path)

        _Concurrency.Task { [weak self] in
            defer {
                _Concurrency.Task { @MainActor [weak self] in
                    self?.activeSummarizations.remove(path)
                }
            }

            guard let self else { return }

            // Step 1: Extract JSONL context
            guard let context = await extractJsonlContext(
                for: project,
                preferredSessionID: preferredSessionID,
            ) else {
                DebugLog.write("SessionSummarizer.triggerSummarization path=\(path) skip=no_jsonl_context")
                return
            }

            let fingerprint = SHA256.hash(data: Data(context.utf8))
                .map { String(format: "%02x", $0) }
                .joined()

            if let cached = await MainActor.run(body: { self.contextFingerprints[path] }),
               cached == fingerprint
            {
                DebugLog.write("SessionSummarizer.triggerSummarization path=\(path) skip=context_unchanged")
                return
            }

            // Step 2: Resolve claude CLI
            guard let claudePath = await claudePathResolver() else {
                DebugLog.write("SessionSummarizer.triggerSummarization path=\(path) skip=claude_cli_not_found")
                return
            }

            // Step 3: Invoke Haiku for multi-variant summarization
            let variants: SummaryVariants
            do {
                variants = try await invokeVariantSummarization(claudePath: claudePath, context: context)
            } catch {
                DebugLog.write("SessionSummarizer.triggerSummarization path=\(path) error=\(error.localizedDescription)")
                return
            }

            // Step 4: Cache variants and write medium to hud-status.json
            await writeHudStatus(for: project, workingOn: variants.medium)

            await MainActor.run { [weak self] in
                self?.contextFingerprints[path] = fingerprint
                self?.cachedVariants[path] = variants
                self?.lastSummarizedAt[path] = self?.clock() ?? Date()
                DebugLog.write("SessionSummarizer.triggerSummarization path=\(path) success short=\"\(variants.short)\" medium=\"\(variants.medium)\" long=\"\(variants.long)\"")
            }
        }
    }

    // MARK: - JSONL Context Extraction

    nonisolated func extractJsonlContext(
        for project: Project,
        preferredSessionID: String? = nil,
    ) async -> String? {
        let projectPath = project.path
        let claudeProjectsDirectory = claudeProjectsDirectory
        return await _Concurrency.Task.detached(priority: .utility) {
            Self.extractJsonlContextSync(
                projectPath: projectPath,
                preferredSessionID: preferredSessionID,
                fileManager: .default,
                claudeProjectsDirectory: claudeProjectsDirectory,
            )
        }.value
    }

    /// Finds and reads the most recent JSONL session file for a project, extracting
    /// normalized human intent, assistant progress, and recent tool usage.
    nonisolated static func extractJsonlContextSync(
        projectPath: String,
        preferredSessionID: String? = nil,
        fileManager: FileManager = .default,
        claudeProjectsDirectory: URL? = nil,
    ) -> String? {
        let claudeProjectsDir = claudeProjectsDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)

        // Build encoded directory name (same encoding as DelegationSessionDiscovery)
        let standardized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let resolvedPath: String = if fileManager.fileExists(atPath: standardized) {
            URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        } else {
            standardized
        }
        let encodedName = String(resolvedPath.map { character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return Character("-")
        })

        let sessionDir = claudeProjectsDir.appendingPathComponent(encodedName, isDirectory: true)
        guard fileManager.fileExists(atPath: sessionDir.path) else {
            // Try case-insensitive match
            guard let candidates = try? fileManager.contentsOfDirectory(
                at: claudeProjectsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
            ) else {
                return nil
            }
            let lowered = encodedName.lowercased()
            guard let match = candidates.first(where: { $0.lastPathComponent.lowercased() == lowered }) else {
                return nil
            }
            return readJsonlTail(
                from: match,
                preferredSessionID: preferredSessionID,
                fileManager: fileManager,
            )
        }

        return readJsonlTail(
            from: sessionDir,
            preferredSessionID: preferredSessionID,
            fileManager: fileManager,
        )
    }

    /// Finds the most recently modified JSONL file in a session directory and
    /// extracts structured context from an adaptive tail window.
    private nonisolated static func readJsonlTail(
        from sessionDir: URL,
        preferredSessionID: String? = nil,
        fileManager: FileManager,
    ) -> String? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles],
        ) else {
            return nil
        }

        let jsonlFiles = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        if let preferredSessionID,
           let preferredFile = jsonlFiles.first(where: {
               $0.deletingPathExtension().lastPathComponent == preferredSessionID
           })
        {
            return extractContextFromJsonl(at: preferredFile)
        }

        guard let mostRecent = jsonlFiles.first else {
            return nil
        }

        return extractContextFromJsonl(at: mostRecent)
    }

    /// Reads the tail of a JSONL file and extracts structured context.
    /// Internal (not private) so it can be tested with fixture files.
    nonisolated static func extractContextFromJsonl(at url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fileHandle.close() }

        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        var bestExtraction: ContextExtraction?

        for windowSize in Constants.windowSizes {
            let readLength = Int(min(UInt64(windowSize), fileSize))
            let readStart = fileSize > UInt64(windowSize)
                ? fileSize - UInt64(windowSize)
                : 0

            fileHandle.seek(toFileOffset: readStart)
            let data = fileHandle.readData(ofLength: readLength)
            let text = String(decoding: data, as: UTF8.self)
            guard !text.isEmpty else { continue }

            let extraction = extractSignals(from: text)
            bestExtraction = extraction

            let isLastWindow = windowSize == Constants.windowSizes.last
            if extraction.intentItems.count >= 2 || isLastWindow || fileSize <= UInt64(windowSize) {
                break
            }
        }

        guard let extraction = bestExtraction else { return nil }
        return makeStructuredContext(from: extraction)
    }

    private nonisolated static func extractSignals(from text: String) -> ContextExtraction {
        let parsedLines = text.components(separatedBy: "\n")
        var intentItems: [String] = []
        var progressSnippets: [String] = []
        var toolNames: [String] = []
        var toolNameSet: Set<String> = []

        let appendAssistantSnippet: (String) -> Void = { text in
            guard progressSnippets.count < 3 else { return }
            let snippet = String(text.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard snippet.count > 20 else { return }
            progressSnippets.append(snippet)
        }

        let appendIntentItem: (String) -> Void = { text in
            guard intentItems.count < 2,
                  let normalized = normalizeUserContent(text)
            else {
                return
            }
            intentItems.append(normalized)
        }

        let appendToolName: (String) -> Void = { name in
            guard toolNames.count < 8 else { return }
            guard toolNameSet.insert(name).inserted else { return }
            toolNames.append(name)
        }

        var quotasFilled: Bool {
            intentItems.count >= 2 && progressSnippets.count >= 3 && toolNames.count >= 5
        }

        for line in parsedLines.reversed() {
            if quotasFilled { break }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            let entryType = json["type"] as? String ?? ""
            if entryType == "file-history-snapshot" {
                continue
            }
            if json["isMeta"] as? Bool == true {
                continue
            }

            let message = json["message"] as? [String: Any]
            let role = message?["role"] as? String ?? json["role"] as? String
            let contentArray = message?["content"] as? [[String: Any]] ?? json["content"] as? [[String: Any]]
            let messageContentString = message?["content"] as? String
            let topLevelContentString = json["content"] as? String

            if role == "assistant" || entryType == "assistant" {
                if let content = contentArray {
                    for block in content {
                        let blockType = block["type"] as? String
                        if blockType == "thinking" {
                            continue
                        }
                        if blockType == "tool_use", let name = block["name"] as? String {
                            appendToolName(name)
                        }
                        if blockType == "text", let text = block["text"] as? String {
                            appendAssistantSnippet(text)
                        }
                    }
                } else if let contentString = messageContentString ?? topLevelContentString {
                    appendAssistantSnippet(contentString)
                }
            }

            if role == "user" || entryType == "user" {
                if let content = contentArray {
                    let isToolResultOnly = !content.isEmpty && content.allSatisfy { ($0["type"] as? String) == "tool_result" }
                    if !isToolResultOnly {
                        for block in content where (block["type"] as? String) == "text" {
                            if let text = block["text"] as? String {
                                appendIntentItem(text)
                            }
                        }
                    }
                }

                if let contentString = messageContentString {
                    appendIntentItem(contentString)
                }

                if let topLevelContentString,
                   topLevelContentString != messageContentString
                {
                    appendIntentItem(topLevelContentString)
                }
            }
        }

        intentItems.reverse()
        progressSnippets.reverse()

        return ContextExtraction(
            intentItems: intentItems,
            progressSnippets: progressSnippets,
            toolNames: toolNames,
        )
    }

    private nonisolated static func makeStructuredContext(from extraction: ContextExtraction) -> String? {
        func section(title: String, body: String?) -> String? {
            guard let body, !body.isEmpty else { return nil }
            return "\(title)\n\(body)"
        }

        func joinSections(_ sections: [String?]) -> String {
            sections.compactMap(\.self).joined(separator: "\n\n")
        }

        var intentSection = section(title: "[Intent]", body: extraction.intentItems.isEmpty ? nil : extraction.intentItems.joined(separator: "\n"))
        var progressSection = section(title: "[Progress]", body: extraction.progressSnippets.isEmpty ? nil : extraction.progressSnippets.joined(separator: "\n"))
        var toolsSection = section(title: "[Tools]", body: extraction.toolNames.isEmpty ? nil : extraction.toolNames.joined(separator: ", "))

        var result = joinSections([intentSection, progressSection, toolsSection])
        guard !result.isEmpty else { return nil }

        if result.count > Constants.maxContextLength, toolsSection != nil {
            let base = joinSections([intentSection, progressSection])
            let separatorCount = base.isEmpty ? 0 : 2
            let available = Constants.maxContextLength - base.count - separatorCount
            toolsSection = available > 0 ? String(toolsSection!.prefix(available)) : nil
            result = joinSections([intentSection, progressSection, toolsSection])
        }

        if result.count > Constants.maxContextLength, progressSection != nil {
            let base = joinSections([intentSection])
            let separatorCount = base.isEmpty ? 0 : 2
            let available = Constants.maxContextLength - base.count - separatorCount
            progressSection = available > 0 ? String(progressSection!.prefix(available)) : nil
            result = joinSections([intentSection, progressSection, toolsSection])
        }

        if result.count > Constants.maxContextLength {
            intentSection = intentSection.map { String($0.prefix(Constants.maxContextLength)) }
            result = joinSections([intentSection, progressSection, toolsSection])
        }

        if result.count > Constants.maxContextLength {
            return String(result.prefix(Constants.maxContextLength))
        }
        return result
    }

    /// Strips known XML wrapper patterns from user message text.
    /// Returns nil if the text is entirely noise or a short confirmation.
    private nonisolated static func normalizeUserContent(_ text: String) -> String? {
        let wrappedTags = [
            "system-reminder",
            "local-command-caveat",
            "task-notification",
            "command-name",
            "command-message",
            "command-args",
        ]

        let confirmationSet: Set = [
            "yes",
            "y",
            "ok",
            "okay",
            "sure",
            "proceed",
            "continue",
            "go ahead",
            "do it",
            "sounds good",
            "lgtm",
            "go",
            "yep",
            "yup",
            "confirmed",
        ]

        var cleaned = text
        for tag in wrappedTags {
            cleaned = replacingMatches(
                in: cleaned,
                pattern: "<\(tag)>[\\s\\S]*?</\(tag)>",
            )
        }

        cleaned = cleaned
            .components(separatedBy: .newlines)
            .filter { line in
                let lowered = line.lowercased()
                return !lowered.contains("hook success:")
                    && !lowered.contains("hook additional context:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count >= 10 else {
            return nil
        }

        if confirmationSet.contains(cleaned.lowercased()) {
            return nil
        }

        return String(cleaned.prefix(200))
    }

    private nonisolated static func replacingMatches(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators],
        ) else {
            return text
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    // MARK: - Haiku Invocation

    nonisolated func invokeVariantSummarization(claudePath: String, context: String) async throws -> SummaryVariants {
        try await _Concurrency.Task.detached(priority: .utility) {
            try Self.invokeVariantSummarizationSync(claudePath: claudePath, context: context)
        }.value
    }

    /// Invokes `claude --print --model haiku` to generate three length variants in one call.
    nonisolated static func invokeVariantSummarizationSync(claudePath: String, context: String) throws -> SummaryVariants {
        let prompt = """
        Based on the following Claude Code session transcript context, describe what the session is currently doing or just did. Use present tense. Focus on the intent, not the mechanics.

        Produce exactly 3 lines — short, medium, and long variants of the same summary. Each line must be a COMPLETE thought (no trailing ellipsis). Do not number them or add labels. Do not include quotes.

        Line 1: max \(Constants.variantShortChars) chars (very brief, e.g. "Fixing auth bug")
        Line 2: max \(Constants.variantMediumChars) chars (e.g. "Fixing authentication token refresh bug")
        Line 3: max \(Constants.variantLongChars) chars (e.g. "Fixing token refresh bug in the OAuth authentication flow")

        Session context:
        \(context)
        """

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--print", "--model", "haiku", "--no-session-persistence", prompt]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Timeout after 30 seconds to prevent permanent lockout.
        let deadline = DispatchTime.now() + .seconds(30)
        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            waitGroup.leave()
        }
        if waitGroup.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw NSError(
                domain: "SessionSummarizer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Haiku summarization timed out after 30s"],
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0, !output.isEmpty else {
            throw NSError(
                domain: "SessionSummarizer",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Haiku summarization failed (exit \(process.terminationStatus))"],
            )
        }

        return parseVariants(from: output)
    }

    /// Parses three newline-separated variants from the Haiku output.
    /// Falls back gracefully: if fewer than 3 lines, duplicates the available text.
    nonisolated static func parseVariants(from output: String) -> SummaryVariants {
        let lines = output
            .components(separatedBy: .newlines)
            .map { line in
                var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip leading bullets/dashes/numbers
                if let range = cleaned.range(of: #"^[\d\.\-\*\)]+\s*"#, options: .regularExpression) {
                    cleaned = String(cleaned[range.upperBound...])
                }
                // Strip surrounding quotes
                if cleaned.hasPrefix("\""), cleaned.hasSuffix("\""), cleaned.count > 2 {
                    cleaned = String(cleaned.dropFirst().dropLast())
                }
                return cleaned
            }
            .filter { !$0.isEmpty }

        let short = String((lines.first ?? "Working").prefix(Constants.variantShortChars))
        let medium = String((lines.count > 1 ? lines[1] : lines.first ?? "Working").prefix(Constants.variantMediumChars))
        let long = String((lines.count > 2 ? lines[2] : medium).prefix(Constants.variantLongChars))

        return SummaryVariants(short: short, medium: medium, long: long)
    }

    // MARK: - hud-status.json Writing

    /// Writes the `working_on` field to `.claude/hud-status.json` in the project directory.
    nonisolated func writeHudStatus(for project: Project, workingOn: String?) async {
        await _Concurrency.Task.detached(priority: .utility) {
            Self.writeHudStatusSync(projectPath: project.path, workingOn: workingOn)
        }.value
    }

    nonisolated static func writeHudStatusSync(projectPath: String, workingOn: String?) {
        let hudDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude")
        let hudFile = hudDir.appendingPathComponent("hud-status.json")

        // Read existing content to preserve other fields
        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: hudFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            existing = json
        }

        // Update fields
        if let workingOn {
            existing["working_on"] = workingOn
            existing["status"] = "working"
        } else {
            existing["working_on"] = NSNull()
            existing["status"] = "idle"
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        existing["updated_at"] = formatter.string(from: Date())

        // Ensure .claude directory exists
        try? FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)

        // Write atomically
        if let data = try? JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: hudFile, options: .atomic)
        }
    }

    // MARK: - Idle Cleanup

    private func clearWorkingOn(for project: Project) {
        contextFingerprints.removeValue(forKey: project.path)
        cachedVariants.removeValue(forKey: project.path)

        // Only clear if there is actually a working_on to clear
        let hudFile = URL(fileURLWithPath: project.path)
            .appendingPathComponent(".claude/hud-status.json")
        guard fileManager.fileExists(atPath: hudFile.path),
              let data = try? Data(contentsOf: hudFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["working_on"] is String
        else {
            return
        }

        _Concurrency.Task { [weak self] in
            await self?.writeHudStatus(for: project, workingOn: nil)
            DebugLog.write("SessionSummarizer.clearWorkingOn path=\(project.path)")
        }
    }

    // MARK: - Testing Support

    #if DEBUG
        var lastSummarizedAtForTesting: [String: Date] {
            get { lastSummarizedAt }
            set { lastSummarizedAt = newValue }
        }

        var activeSummarizationsForTesting: Set<String> {
            get { activeSummarizations }
            set { activeSummarizations = newValue }
        }

        var idleSinceForTesting: [String: Date] {
            get { idleSince }
            set { idleSince = newValue }
        }

        var cachedVariantsForTesting: [String: SummaryVariants] {
            get { cachedVariants }
            set { cachedVariants = newValue }
        }

        var contextFingerprintsForTesting: [String: String] {
            get { contextFingerprints }
            set { contextFingerprints = newValue }
        }

        nonisolated static func normalizeUserContentForTesting(_ text: String) -> String? {
            normalizeUserContent(text)
        }
    #endif
}
