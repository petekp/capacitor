@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class SessionSummarizerTests: XCTestCase {
    private final class MutableClock {
        var now: Date

        init(now: Date) {
            self.now = now
        }
    }

    // MARK: - Helpers

    private func makeProject(_ name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    private func makeSessionState(
        _ state: SessionState,
        sessionId: String? = "test-session",
    ) -> ProjectSessionState {
        ProjectSessionState(
            state: state,
            stateChangedAt: nil,
            updatedAt: nil,
            sessionId: sessionId,
            workingOn: nil,
            context: nil,
            thinking: nil,
            hasSession: true,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
        )
    }

    private func makeSummarizer(clock: @escaping () -> Date = { Date() }) -> SessionSummarizer {
        SessionSummarizer(
            claudePathResolver: { nil }, // No CLI in tests
            fileManager: .default,
            clock: clock,
        )
    }

    private func normalizeUserContent(_ text: String) -> String? {
        SessionSummarizer.normalizeUserContentForTesting(text)
    }

    private func encodedProjectDirectoryName(for projectPath: String) -> String {
        let standardized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        return String(standardized.map { character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return Character("-")
        })
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 4_000_000_000,
        pollNanoseconds: UInt64 = 100_000_000,
        condition: @escaping @MainActor () -> Bool,
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if condition() {
                return
            }
            try await _Concurrency.Task.sleep(nanoseconds: pollNanoseconds)
        }
        XCTFail("Timed out waiting for condition")
    }

    private func createFakeClaudeScript(
        at scriptURL: URL,
        callLogURL: URL,
        argsLogURL: URL? = nil,
        output: String,
    ) throws {
        let argsLogging = if let argsLogURL {
            "printf '%s\\n' \"$@\" > \"\(argsLogURL.path)\""
        } else {
            ""
        }

        let script = """
        #!/bin/sh
        echo called >> "\(callLogURL.path)"
        \(argsLogging)
        cat <<'EOF'
        \(output)
        EOF
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path,
        )
    }

    private func callCount(in logURL: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return 0
        }

        let content = try String(contentsOf: logURL, encoding: .utf8)
        return content
            .components(separatedBy: .newlines)
            .count(where: { !$0.isEmpty })
    }

    // MARK: - Skip Logic Tests

    func testSkipsDelegatedProjects() {
        let summarizer = makeSummarizer()
        let project = makeProject("Test", path: "/tmp/test-project")
        let normalizedPath = PathNormalizer.normalize(project.path)

        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working),
        ]
        let delegationStates: [String: RuntimeDelegationState] = [
            normalizedPath: RuntimeDelegationState(
                projectPath: project.path,
                workerId: "worker-1",
                ideaId: nil,
                worktreeName: "wt",
                worktreePath: "/tmp/wt",
                sessionId: nil,
                status: "running",
                startedAt: "2026-03-29T00:00:00Z",
                updatedAt: "2026-03-29T00:00:00Z",
                currentReview: nil,
            ),
        ]

        // Should not crash or trigger summarization (no claude CLI anyway)
        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: delegationStates,
        )

        // activeSummarizations should be empty since delegation is active
        XCTAssertTrue(summarizer.activeSummarizationsForTesting.isEmpty)
    }

    func testSkipsWhenAlreadySummarizing() {
        let summarizer = makeSummarizer()
        let project = makeProject("Test", path: "/tmp/test-project-summarizing")

        // Pre-mark as actively summarizing
        summarizer.activeSummarizationsForTesting.insert(project.path)

        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        // Should still be in active set (not double-triggered)
        XCTAssertTrue(summarizer.activeSummarizationsForTesting.contains(project.path))
    }

    func testSkipsCooldownPeriod() {
        let now = Date()
        let summarizer = makeSummarizer(clock: { now })
        let project = makeProject("Test", path: "/tmp/test-project-cooldown")

        // Mark as recently summarized (10 seconds ago, within 25s cooldown)
        summarizer.lastSummarizedAtForTesting[project.path] = now.addingTimeInterval(-10)

        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        // Should not trigger (still in cooldown)
        XCTAssertTrue(summarizer.activeSummarizationsForTesting.isEmpty)
    }

    func testAllowsSummarizationAfterCooldown() {
        let now = Date()
        let summarizer = makeSummarizer(clock: { now })
        let project = makeProject("Test", path: "/tmp/test-project-after-cooldown")

        // Mark as summarized 30 seconds ago (beyond 25s cooldown)
        summarizer.lastSummarizedAtForTesting[project.path] = now.addingTimeInterval(-30)

        // Use a summarizer that will try to resolve claude path (and fail gracefully)
        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        // Should attempt summarization (will be in activeSummarizations briefly)
        // Since claudePathResolver returns nil, it will complete quickly
        XCTAssertTrue(summarizer.activeSummarizationsForTesting.contains(project.path))
    }

    func testSkipsIdleSessions() {
        let now = Date()
        let summarizer = makeSummarizer(clock: { now })
        let project = makeProject("Test", path: "/tmp/test-project-idle")

        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.idle),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        // Should not trigger summarization for idle sessions
        XCTAssertTrue(summarizer.activeSummarizationsForTesting.isEmpty)
        // Should track idle-since
        XCTAssertNotNil(summarizer.idleSinceForTesting[project.path])
    }

    func testTracksIdleSinceTimestamp() {
        let now = Date()
        let summarizer = makeSummarizer(clock: { now })
        let project = makeProject("Test", path: "/tmp/test-idle-tracking")

        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.idle),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        let idleSince = summarizer.idleSinceForTesting[project.path]
        XCTAssertNotNil(idleSince)
        XCTAssertEqual(idleSince?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1.0)
    }

    func testResetsIdleTrackingWhenSessionBecomesActive() {
        let now = Date()
        let summarizer = makeSummarizer(clock: { now })
        let project = makeProject("Test", path: "/tmp/test-idle-reset")

        // Pre-set idle-since
        summarizer.idleSinceForTesting[project.path] = now.addingTimeInterval(-60)

        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        // Idle tracking should be cleared
        XCTAssertNil(summarizer.idleSinceForTesting[project.path])
    }

    func testTriggersForWorkingSession() {
        let now = Date()
        let summarizer = makeSummarizer(clock: { now })
        let project = makeProject("Test", path: "/tmp/test-project-working")

        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        // Should trigger (will be added to activeSummarizations)
        XCTAssertTrue(summarizer.activeSummarizationsForTesting.contains(project.path))
    }

    func testTriggersForReadySession() {
        let now = Date()
        let summarizer = makeSummarizer(clock: { now })
        let project = makeProject("Test", path: "/tmp/test-project-ready")

        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.ready),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        // Should trigger for ready sessions too
        XCTAssertTrue(summarizer.activeSummarizationsForTesting.contains(project.path))
    }

    // MARK: - JSONL Context Extraction Tests

    func testExtractContextFromJsonlFileDoesNotCrashOnMissingPath() {
        // extractJsonlContextSync looks under ~/.claude/projects/ which we can't inject.
        // This test verifies it returns nil gracefully for a nonexistent project.
        let context = SessionSummarizer.extractJsonlContextSync(
            projectPath: "/tmp/nonexistent-project-\(UUID().uuidString)",
            fileManager: .default,
        )
        XCTAssertNil(context)
    }

    func testNormalizeUserContentStripsSystemReminders() {
        let result = normalizeUserContent(
            """
            <system-reminder>important info</system-reminder>
            Please implement the login page
            """,
        )

        XCTAssertEqual(result, "Please implement the login page")
    }

    func testNormalizeUserContentReturnsNilForPureWrapper() {
        XCTAssertNil(normalizeUserContent("<command-name>/clear</command-name>"))
    }

    func testNormalizeUserContentReturnsNilForShortConfirmation() {
        XCTAssertNil(normalizeUserContent("yes"))
        XCTAssertNil(normalizeUserContent("proceed"))
    }

    func testNormalizeUserContentReturnsNilForTaskNotification() {
        XCTAssertNil(
            normalizeUserContent(
                """
                <task-notification>
                Agent completed task
                </task-notification>
                """,
            ),
        )
    }

    func testNormalizeUserContentPreservesRealContent() {
        let input = "Please implement the login page with OAuth support"
        XCTAssertEqual(normalizeUserContent(input), input)
    }

    func testExtractContextFromJsonlWithFixture() throws {
        // Test the internal extractContextFromJsonl(at:) method directly with a fixture file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonlFile = tempDir.appendingPathComponent("test-session.jsonl")

        // Use the real Claude Code JSONL format: top-level "type" + nested "message"
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Please implement the login page"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll implement the login page."},{"type":"tool_use","name":"Edit","id":"t1","input":{}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"t2","input":{}},{"type":"text","text":"Now adding styles."}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"Also add password validation"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","id":"t3","input":{}},{"type":"text","text":"Adding validation logic."}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        let context = SessionSummarizer.extractContextFromJsonl(at: jsonlFile)

        XCTAssertNotNil(context, "Should extract context from valid JSONL fixture")

        let ctx = try XCTUnwrap(context)
        XCTAssertTrue(ctx.contains("[Intent]"), "Should include an intent section: got \(ctx)")
        XCTAssertTrue(ctx.contains("[Progress]"), "Should include a progress section: got \(ctx)")
        XCTAssertTrue(ctx.contains("[Tools]"), "Should include a tools section: got \(ctx)")
        // Should contain the most recent user prompt
        XCTAssertTrue(ctx.contains("password validation"), "Should extract user prompt: got \(ctx)")
        // Should contain tool names
        XCTAssertTrue(ctx.contains("Edit") || ctx.contains("Read"), "Should extract tool names: got \(ctx)")
        // Should contain assistant text
        XCTAssertTrue(ctx.contains("validation logic") || ctx.contains("Adding"), "Should extract assistant text: got \(ctx)")
    }

    func testExtractContextSkipsThinkingBlocks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-thinking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonlFile = tempDir.appendingPathComponent("test-session.jsonl")
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"let me think about this..."},{"type":"text","text":"Here is my answer with enough detail to count as progress."}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        let context = SessionSummarizer.extractContextFromJsonl(at: jsonlFile)

        XCTAssertNotNil(context)
        XCTAssertTrue(try XCTUnwrap(context?.contains("Here is my answer")), "Should include text blocks")
        XCTAssertFalse(try XCTUnwrap(context?.contains("let me think")), "Should skip thinking blocks")
    }

    func testExtractContextUsesStructuredFormat() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-structured-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonlFile = tempDir.appendingPathComponent("test-session.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Please implement the login page with OAuth support"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"tool-1","input":{}},{"type":"text","text":"Reviewing the current authentication flow before making changes."}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        let context = try XCTUnwrap(SessionSummarizer.extractContextFromJsonl(at: jsonlFile))

        XCTAssertTrue(context.contains("[Intent]"))
        XCTAssertTrue(context.contains("[Progress]"))
        XCTAssertTrue(context.contains("[Tools]"))
    }

    func testExtractContextFindsIntentBuriedBehindToolResults() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-buried-intent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonlFile = tempDir.appendingPathComponent("test-session.jsonl")
        let noisyToolResult = String(repeating: "tool output ", count: 280)
        var lines = [
            #"{"type":"user","message":{"role":"user","content":"Please migrate the dashboard filter pipeline to structured extraction"}}"#,
        ]
        for index in 0 ..< 15 {
            lines.append(
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-\#(index)","content":"\#(noisyToolResult)"}]}}"#,
            )
        }

        try lines.joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        let context = try XCTUnwrap(SessionSummarizer.extractContextFromJsonl(at: jsonlFile))

        XCTAssertTrue(context.contains("[Intent]"))
        XCTAssertTrue(context.contains("structured extraction"), "Expected buried intent in context: \(context)")
    }

    func testAdaptiveWindowExpandsToFindIntentBeyondFirstWindow() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-adaptive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonlFile = tempDir.appendingPathComponent("test-session.jsonl")
        // The intent goes first, then enough noise to push it beyond the 32KB window.
        // Each tool_result entry is ~3.3KB, so 12 entries ≈ 40KB of noise after the intent.
        let filler = String(repeating: "x", count: 3000)
        var lines = [
            #"{"type":"user","message":{"role":"user","content":"Refactor the payment gateway integration to support Stripe webhooks"}}"#,
        ]
        for i in 0 ..< 12 {
            lines.append(
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-\#(i)","content":"\#(filler)"}]}}"#,
            )
        }
        try lines.joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        // Verify the file is larger than the first window (32KB)
        let fileSize = try FileManager.default.attributesOfItem(atPath: jsonlFile.path)[.size] as? UInt64 ?? 0
        XCTAssertGreaterThan(fileSize, 32768, "Fixture must exceed 32KB to test window expansion")

        let context = try XCTUnwrap(SessionSummarizer.extractContextFromJsonl(at: jsonlFile))
        XCTAssertTrue(context.contains("Stripe webhooks"), "Adaptive window should expand to find intent buried beyond 32KB: \(context)")
    }

    func testExtractContextSkipsWrapperNoiseInUserMessages() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-wrapper-noise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonlFile = tempDir.appendingPathComponent("test-session.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Make the session card show live status while I work"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"tool-1","input":{}},{"type":"text","text":"Inspecting the session status pipeline before updating it."}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"<system-reminder>Base directory for this skill: /tmp/example</system-reminder>"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        let context = try XCTUnwrap(SessionSummarizer.extractContextFromJsonl(at: jsonlFile))

        XCTAssertTrue(context.contains("Make the session card show live status while I work"))
        XCTAssertFalse(context.contains("Base directory for this skill"))
        XCTAssertFalse(context.contains("system-reminder"))
    }

    func testExtractContextSkipsFileHistorySnapshots() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonlFile = tempDir.appendingPathComponent("test-session.jsonl")
        let lines = [
            #"{"type":"file-history-snapshot","snapshot":{"trackedFileBackups":{}}}"#,
            #"{"type":"user","message":{"role":"user","content":"Hello from the real user request"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        let context = SessionSummarizer.extractContextFromJsonl(at: jsonlFile)

        XCTAssertNotNil(context)
        XCTAssertTrue(try XCTUnwrap(context?.contains("[Intent]")))
        XCTAssertTrue(try XCTUnwrap(context?.contains("Hello from the real user request")))
        XCTAssertFalse(try XCTUnwrap(context?.contains("snapshot")))
    }

    // MARK: - hud-status.json Writing Tests

    func testWriteHudStatusCreatesFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        SessionSummarizer.writeHudStatusSync(
            projectPath: tempDir.path,
            workingOn: "Implementing login page",
        )

        let hudFile = tempDir.appendingPathComponent(".claude/hud-status.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hudFile.path))

        let data = try Data(contentsOf: hudFile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["working_on"] as? String, "Implementing login page")
        XCTAssertEqual(json?["status"] as? String, "working")
        XCTAssertNotNil(json?["updated_at"] as? String)
    }

    func testWriteHudStatusClearsWorkingOn() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-clear-\(UUID().uuidString)")
        let hudDir = tempDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write initial status
        let initial: [String: Any] = [
            "working_on": "Some task",
            "status": "working",
            "next_step": "Deploy",
        ]
        let initialData = try JSONSerialization.data(withJSONObject: initial)
        try initialData.write(to: hudDir.appendingPathComponent("hud-status.json"))

        // Clear working_on
        SessionSummarizer.writeHudStatusSync(
            projectPath: tempDir.path,
            workingOn: nil,
        )

        let hudFile = tempDir.appendingPathComponent(".claude/hud-status.json")
        let data = try Data(contentsOf: hudFile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // working_on should be NSNull (null in JSON)
        XCTAssertTrue(json?["working_on"] is NSNull)
        XCTAssertEqual(json?["status"] as? String, "idle")
        // Existing fields should be preserved
        XCTAssertEqual(json?["next_step"] as? String, "Deploy")
    }

    func testWriteHudStatusPreservesExistingFields() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-preserve-\(UUID().uuidString)")
        let hudDir = tempDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write initial status with extra fields
        let initial: [String: Any] = [
            "working_on": "Old task",
            "blocker": "Waiting for review",
            "next_step": "Test and deploy",
        ]
        let initialData = try JSONSerialization.data(withJSONObject: initial)
        try initialData.write(to: hudDir.appendingPathComponent("hud-status.json"))

        // Update working_on
        SessionSummarizer.writeHudStatusSync(
            projectPath: tempDir.path,
            workingOn: "New task",
        )

        let hudFile = tempDir.appendingPathComponent(".claude/hud-status.json")
        let data = try Data(contentsOf: hudFile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["working_on"] as? String, "New task")
        XCTAssertEqual(json?["blocker"] as? String, "Waiting for review")
        XCTAssertEqual(json?["next_step"] as? String, "Test and deploy")
    }

    // MARK: - Multiple Projects

    func testEvaluatesMultipleProjectsIndependently() {
        let now = Date()
        let summarizer = makeSummarizer(clock: { now })

        let projectA = makeProject("A", path: "/tmp/test-multi-a")
        let projectB = makeProject("B", path: "/tmp/test-multi-b")
        let projectC = makeProject("C", path: "/tmp/test-multi-c")

        // A is working, B is idle, C is working but recently summarized
        summarizer.lastSummarizedAtForTesting[projectC.path] = now.addingTimeInterval(-5)

        let sessionStates: [String: ProjectSessionState] = [
            projectA.path: makeSessionState(.working),
            projectB.path: makeSessionState(.idle),
            projectC.path: makeSessionState(.working),
        ]

        summarizer.evaluateProjects(
            projects: [projectA, projectB, projectC],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        // A should trigger, B should not (idle), C should not (cooldown)
        XCTAssertTrue(summarizer.activeSummarizationsForTesting.contains(projectA.path))
        XCTAssertFalse(summarizer.activeSummarizationsForTesting.contains(projectB.path))
        XCTAssertFalse(summarizer.activeSummarizationsForTesting.contains(projectC.path))
    }

    func testEvaluateProjectsWritesHudStatusFromRealTranscriptAndIgnoresMetaUserNoise() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-end-to-end-\(UUID().uuidString)")
        let projectDir = tempDir.appendingPathComponent("project")
        let claudeProjectsDir = tempDir.appendingPathComponent("claude-projects")
        let encodedDir = claudeProjectsDir.appendingPathComponent(
            encodedProjectDirectoryName(for: projectDir.path),
            isDirectory: true,
        )
        let jsonlFile = encodedDir.appendingPathComponent("live-session.jsonl")
        let fakeClaude = tempDir.appendingPathComponent("fake-claude.sh")
        let argsLog = tempDir.appendingPathComponent("fake-claude-args.txt")

        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: encodedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let transcriptLines = [
            #"{"type":"user","message":{"role":"user","content":"Make the session card show live status while I work"}} "#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"tool-1","input":{}},{"type":"text","text":"Inspecting SessionSummarizer and AppState."}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /tmp/superpowers/using-git-worktrees\n\nThis is synthetic tool chatter and must not become the human prompt."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","id":"tool-2","input":{}},{"type":"text","text":"Preparing the real summarizer pipeline."}]}}"#,
        ]
        try transcriptLines.joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        let fakeClaudeScript = """
        #!/bin/sh
        printf '%s\n' "$@" > "\(argsLog.path)"
        cat <<'EOF'
        Live status fix
        Fixing live session status
        Fixing live session status updates in Capacitor
        EOF
        """
        try fakeClaudeScript.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeClaude.path,
        )

        let summarizer = SessionSummarizer(
            claudePathResolver: { fakeClaude.path },
            fileManager: .default,
            clock: { Date(timeIntervalSince1970: 1000) },
            claudeProjectsDirectory: claudeProjectsDir,
        )
        let project = makeProject("Capacitor", path: projectDir.path)
        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        let hudFile = projectDir.appendingPathComponent(".claude/hud-status.json")
        for _ in 0 ..< 40 {
            if FileManager.default.fileExists(atPath: hudFile.path) {
                break
            }
            try await _Concurrency.Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: hudFile.path),
            "Expected summarizer to write hud-status.json",
        )

        let hudData = try Data(contentsOf: hudFile)
        let hudJson = try XCTUnwrap(try JSONSerialization.jsonObject(with: hudData) as? [String: Any])
        XCTAssertEqual(hudJson["working_on"] as? String, "Fixing live session status")
        XCTAssertEqual(hudJson["status"] as? String, "working")

        let invocation = try String(contentsOf: argsLog, encoding: .utf8)
        XCTAssertTrue(invocation.contains("--print"))
        XCTAssertTrue(invocation.contains("--model"))
        XCTAssertTrue(invocation.contains("haiku"))
        XCTAssertTrue(invocation.contains("--no-session-persistence"))
        XCTAssertTrue(invocation.contains("Make the session card show live status while I work"))
        XCTAssertTrue(invocation.contains("[Tools]"))
        XCTAssertTrue(invocation.contains("Read"))
        XCTAssertTrue(invocation.contains("Edit"))
        XCTAssertFalse(invocation.contains("Base directory for this skill"))
    }

    func testEvaluateProjectsPrefersActiveSessionTranscriptOverNewerUnrelatedJsonl() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-session-id-\(UUID().uuidString)")
        let projectDir = tempDir.appendingPathComponent("project")
        let claudeProjectsDir = tempDir.appendingPathComponent("claude-projects")
        let encodedDir = claudeProjectsDir.appendingPathComponent(
            encodedProjectDirectoryName(for: projectDir.path),
            isDirectory: true,
        )
        let activeSessionID = "active-session-id"
        let unrelatedSessionID = "other-session-id"
        let activeJsonl = encodedDir.appendingPathComponent("\(activeSessionID).jsonl")
        let unrelatedJsonl = encodedDir.appendingPathComponent("\(unrelatedSessionID).jsonl")
        let fakeClaude = tempDir.appendingPathComponent("fake-claude.sh")
        let argsLog = tempDir.appendingPathComponent("fake-claude-args.txt")

        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: encodedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try [
            #"{"type":"user","message":{"role":"user","content":"Show the live status for this Capacitor debugging session"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"tool-1","input":{}},{"type":"text","text":"Inspecting the active session transcript."}]}}"#,
        ].joined(separator: "\n").write(to: activeJsonl, atomically: true, encoding: .utf8)

        try [
            #"{"type":"user","message":{"role":"user","content":"Initialize Claude Code with Vercel ecosystem docs"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"tool-2","input":{}},{"type":"text","text":"Reading Vercel setup docs."}]}}"#,
        ].joined(separator: "\n").write(to: unrelatedJsonl, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)],
            ofItemAtPath: activeJsonl.path,
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2000)],
            ofItemAtPath: unrelatedJsonl.path,
        )

        let fakeClaudeScript = """
        #!/bin/sh
        printf '%s\n' "$@" > "\(argsLog.path)"
        cat <<'EOF'
        Live session status
        Showing live session status
        Showing live session status for the active Capacitor debug run
        EOF
        """
        try fakeClaudeScript.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeClaude.path,
        )

        let summarizer = SessionSummarizer(
            claudePathResolver: { fakeClaude.path },
            fileManager: .default,
            clock: { Date(timeIntervalSince1970: 3000) },
            claudeProjectsDirectory: claudeProjectsDir,
        )
        let project = makeProject("Capacitor", path: projectDir.path)
        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working, sessionId: activeSessionID),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        let hudFile = projectDir.appendingPathComponent(".claude/hud-status.json")
        for _ in 0 ..< 40 {
            if FileManager.default.fileExists(atPath: hudFile.path) {
                break
            }
            try await _Concurrency.Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: hudFile.path))

        let invocation = try String(contentsOf: argsLog, encoding: .utf8)
        XCTAssertTrue(invocation.contains("Show the live status for this Capacitor debugging session"))
        XCTAssertFalse(invocation.contains("Initialize Claude Code with Vercel ecosystem docs"))
    }

    func testFingerprintCacheSkipsRedundantHaikuCall() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-fingerprint-skip-\(UUID().uuidString)")
        let projectDir = tempDir.appendingPathComponent("project")
        let claudeProjectsDir = tempDir.appendingPathComponent("claude-projects")
        let encodedDir = claudeProjectsDir.appendingPathComponent(
            encodedProjectDirectoryName(for: projectDir.path),
            isDirectory: true,
        )
        let jsonlFile = encodedDir.appendingPathComponent("live-session.jsonl")
        let fakeClaude = tempDir.appendingPathComponent("fake-claude.sh")
        let callLog = tempDir.appendingPathComponent("fake-claude-calls.txt")
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1000))

        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: encodedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try [
            #"{"type":"user","message":{"role":"user","content":"Summarize the session card work for the active project"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"tool-1","input":{}},{"type":"text","text":"Inspecting the session card state update pipeline before editing."}]}}"#,
        ].joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        try createFakeClaudeScript(
            at: fakeClaude,
            callLogURL: callLog,
            output: """
            Session card work
            Updating session card summary
            Updating session card summary in Capacitor
            """,
        )

        let summarizer = SessionSummarizer(
            claudePathResolver: { fakeClaude.path },
            fileManager: .default,
            clock: { clock.now },
            claudeProjectsDirectory: claudeProjectsDir,
        )
        let project = makeProject("Capacitor", path: projectDir.path)
        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        try await waitUntil {
            (try? self.callCount(in: callLog)) == 1 && summarizer.activeSummarizationsForTesting.isEmpty
        }

        clock.now = clock.now.addingTimeInterval(30)
        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        try await waitUntil {
            summarizer.activeSummarizationsForTesting.isEmpty
        }

        XCTAssertEqual(try callCount(in: callLog), 1)
        XCTAssertEqual(summarizer.contextFingerprintsForTesting.count, 1)
    }

    func testFingerprintCacheProceedsOnChangedContext() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSummarizerTests-fingerprint-change-\(UUID().uuidString)")
        let projectDir = tempDir.appendingPathComponent("project")
        let claudeProjectsDir = tempDir.appendingPathComponent("claude-projects")
        let encodedDir = claudeProjectsDir.appendingPathComponent(
            encodedProjectDirectoryName(for: projectDir.path),
            isDirectory: true,
        )
        let jsonlFile = encodedDir.appendingPathComponent("live-session.jsonl")
        let fakeClaude = tempDir.appendingPathComponent("fake-claude.sh")
        let callLog = tempDir.appendingPathComponent("fake-claude-calls.txt")
        let clock = MutableClock(now: Date(timeIntervalSince1970: 2000))

        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: encodedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try [
            #"{"type":"user","message":{"role":"user","content":"Summarize the current session card work"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","id":"tool-1","input":{}},{"type":"text","text":"Inspecting the session card work before making updates."}]}}"#,
        ].joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        try createFakeClaudeScript(
            at: fakeClaude,
            callLogURL: callLog,
            output: """
            Session card work
            Updating session card summary
            Updating session card summary in Capacitor
            """,
        )

        let summarizer = SessionSummarizer(
            claudePathResolver: { fakeClaude.path },
            fileManager: .default,
            clock: { clock.now },
            claudeProjectsDirectory: claudeProjectsDir,
        )
        let project = makeProject("Capacitor", path: projectDir.path)
        let sessionStates: [String: ProjectSessionState] = [
            project.path: makeSessionState(.working),
        ]

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        try await waitUntil {
            (try? self.callCount(in: callLog)) == 1 && summarizer.activeSummarizationsForTesting.isEmpty
        }

        try [
            #"{"type":"user","message":{"role":"user","content":"Summarize the updated terminal activation work"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","id":"tool-2","input":{}},{"type":"text","text":"Updating the terminal activation flow after the first pass."}]}}"#,
        ].joined(separator: "\n").write(to: jsonlFile, atomically: true, encoding: .utf8)

        clock.now = clock.now.addingTimeInterval(30)
        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: sessionStates,
            delegationStates: [:],
        )

        try await waitUntil {
            (try? self.callCount(in: callLog)) == 2 && summarizer.activeSummarizationsForTesting.isEmpty
        }

        XCTAssertEqual(try callCount(in: callLog), 2)
    }

    // MARK: - Variant Parsing

    func testParseVariantsFromThreeLines() {
        let output = """
        Fixing auth bug
        Fixing authentication token refresh bug
        Fixing token refresh bug in the OAuth authentication flow
        """
        let variants = SessionSummarizer.parseVariants(from: output)
        XCTAssertEqual(variants.short, "Fixing auth bug")
        XCTAssertTrue(variants.medium.starts(with: "Fixing authentication"))
        XCTAssertTrue(variants.long.starts(with: "Fixing token refresh"))
    }

    func testParseVariantsStripsNumberedPrefixes() {
        let output = """
        1. Fixing auth bug
        2. Fixing authentication token refresh bug
        3. Fixing token refresh bug in the OAuth flow
        """
        let variants = SessionSummarizer.parseVariants(from: output)
        XCTAssertEqual(variants.short, "Fixing auth bug")
        XCTAssertTrue(variants.medium.starts(with: "Fixing authentication"))
    }

    func testParseVariantsFallsBackOnSingleLine() {
        let output = "Fixing auth bug" // 15 chars, fits in all tiers
        let variants = SessionSummarizer.parseVariants(from: output)
        XCTAssertEqual(variants.short, "Fixing auth bug")
        XCTAssertEqual(variants.medium, "Fixing auth bug")
        XCTAssertEqual(variants.long, "Fixing auth bug")
    }

    func testParseVariantsTruncatesToMaxLengths() {
        let output = """
        This is a very long short line that exceeds twenty five characters easily
        This is a very long medium line that exceeds forty characters by quite a lot
        This is a very long long line that exceeds sixty characters by a significant amount for sure
        """
        let variants = SessionSummarizer.parseVariants(from: output)
        XCTAssertLessThanOrEqual(variants.short.count, 25)
        XCTAssertLessThanOrEqual(variants.medium.count, 40)
        XCTAssertLessThanOrEqual(variants.long.count, 60)
    }

    // MARK: - Best Summary Selection

    func testBestSummarySelectsLongestThatFits() {
        let summarizer = makeSummarizer()
        summarizer.cachedVariantsForTesting["/tmp/test"] = SessionSummarizer.SummaryVariants(
            short: "Fixing bug", // 10 chars
            medium: "Fixing auth token refresh bug", // 30 chars
            long: "Fixing authentication token refresh in OAuth flow", // 49 chars
        )

        // Wide card (400pt → budget ~57) — long variant (49 chars) fits
        summarizer.cardContentWidth = 400
        XCTAssertEqual(summarizer.bestSummary(for: "/tmp/test"), "Fixing authentication token refresh in OAuth flow")

        // Medium card (250pt → budget ~34) — medium variant (30 chars) fits, long (49) doesn't
        summarizer.cardContentWidth = 250
        XCTAssertEqual(summarizer.bestSummary(for: "/tmp/test"), "Fixing auth token refresh bug")

        // Very narrow card (100pt → budget = 25 floor) — only short (10 chars) fits
        // Note: budget is min-clamped to variantShortChars (25), medium is 30 > 25
        summarizer.cardContentWidth = 100
        XCTAssertEqual(summarizer.bestSummary(for: "/tmp/test"), "Fixing bug")
    }

    func testBestSummaryReturnsNilWhenNoCachedVariants() {
        let summarizer = makeSummarizer()
        XCTAssertNil(summarizer.bestSummary(for: "/tmp/nonexistent"))
    }

    // MARK: - Idle Cleanup Clears Cached Variants

    func testIdleCleanupClearsCachedVariants() {
        let idleClearDelay: TimeInterval = 300
        var now = Date()
        let summarizer = makeSummarizer(clock: { now })
        let project = makeProject("Test", path: "/tmp/test-idle-clear-cache")

        // Pre-populate a cached summary variant
        summarizer.cachedVariantsForTesting[project.path] = SessionSummarizer.SummaryVariants(
            short: "Old summary",
            medium: "Old summary from prior session",
            long: "Old summary from a completely different prior session",
        )

        // Set idle-since to just before the clear threshold
        summarizer.idleSinceForTesting[project.path] = now.addingTimeInterval(-(idleClearDelay - 1))

        // First evaluation: idle but not past threshold yet — cache should survive
        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: [project.path: makeSessionState(.idle)],
            delegationStates: [:],
        )
        XCTAssertNotNil(summarizer.cachedVariantsForTesting[project.path],
                        "Cache should survive before idle threshold")

        // Advance past the idle-clear threshold
        now = now.addingTimeInterval(2)

        summarizer.evaluateProjects(
            projects: [project],
            sessionStates: [project.path: makeSessionState(.idle)],
            delegationStates: [:],
        )
        XCTAssertNil(summarizer.cachedVariantsForTesting[project.path],
                     "Cached variants must be cleared after idle threshold")
        XCTAssertNil(summarizer.bestSummary(for: project.path),
                     "bestSummary should return nil after idle cleanup")
    }
}
