@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchTaskSessionTests: XCTestCase {
    private final class ActivationLogCollector {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    func testClaudeStartRequestUsesAssignedSessionID() {
        let request = ClaudeCodeTaskSessionLaunchRequest(
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-ui",
            batchName: "Mobile prototype",
            sessionID: "56c839a4-3a6c-46a1-9e04-c9d6bde7f4b8",
            mode: .start(prompt: "Read the batch context and begin."),
        )

        XCTAssertEqual(
            request.arguments,
            [
                "--session-id",
                "56c839a4-3a6c-46a1-9e04-c9d6bde7f4b8",
                "--permission-mode",
                "auto",
                "--name",
                "Mobile prototype",
                "Read the batch context and begin.",
            ],
        )
        XCTAssertFalse(request.arguments.contains("--resume"))
    }

    func testInitialPromptIsOperatorFacingAndSingleLine() {
        let prompt = WorkBatchTaskSessionCoordinator.initialPrompt(
            contextMirrorRelativePath: WorkBatchContextMirror.relativePath,
        )

        XCTAssertFalse(prompt.contains("\n"))
        XCTAssertEqual(prompt, "Assessing tasks...")
        XCTAssertFalse(prompt.contains("Read .capacitor/work-batch-context.md"))
        XCTAssertFalse(prompt.contains("Task claim"))
        XCTAssertFalse(prompt.contains("Done report"))
        XCTAssertFalse(prompt.contains("Checkpoint request"))
    }

    func testResumePromptIsOperatorFacingAndSingleLine() {
        let prompt = WorkBatchTaskSessionCoordinator.resumePrompt(
            contextMirrorRelativePath: WorkBatchContextMirror.relativePath,
        )

        XCTAssertFalse(prompt.contains("\n"))
        XCTAssertEqual(prompt, "Assessing updated tasks...")
        XCTAssertFalse(prompt.contains("Read .capacitor/work-batch-context.md"))
        XCTAssertFalse(prompt.contains("Task claim"))
        XCTAssertFalse(prompt.contains("Done report"))
        XCTAssertFalse(prompt.contains("Checkpoint request"))
    }

    func testAgentInstructionsPromptCarriesHiddenBatchContract() {
        let prompt = WorkBatchTaskSessionCoordinator.agentInstructionsPrompt(
            contextMirrorRelativePath: WorkBatchContextMirror.relativePath,
        )

        XCTAssertFalse(prompt.contains("\n"))
        XCTAssertTrue(prompt.contains("Read .capacitor/work-batch-context.md"))
        XCTAssertTrue(prompt.contains("Task claim"))
        XCTAssertTrue(prompt.contains("Done report"))
        XCTAssertTrue(prompt.contains("Checkpoint request"))
        XCTAssertTrue(prompt.contains("Do not narrate Capacitor artifact mechanics"))
    }

    func testLaunchRequestAppendsSystemPromptFileBeforeVisiblePrompt() {
        let request = ClaudeCodeTaskSessionLaunchRequest(
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-ui",
            batchName: "Mobile prototype",
            sessionID: "56c839a4-3a6c-46a1-9e04-c9d6bde7f4b8",
            appendedSystemPromptFile: ".capacitor/work-batch-agent-instructions.md",
            mode: .start(prompt: "Assessing tasks..."),
        )

        XCTAssertEqual(request.arguments.suffix(3), [
            "--append-system-prompt-file",
            ".capacitor/work-batch-agent-instructions.md",
            "Assessing tasks...",
        ])
    }

    func testClaudeResumeRequestUsesAssignedSessionID() {
        let request = ClaudeCodeTaskSessionLaunchRequest(
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-ui",
            batchName: "Mobile prototype",
            sessionID: "68d42879-5c45-40da-86de-2427c64411dc",
            mode: .resume(prompt: nil),
        )

        XCTAssertEqual(
            request.arguments,
            [
                "--resume",
                "68d42879-5c45-40da-86de-2427c64411dc",
                "--permission-mode",
                "auto",
            ],
        )
    }

    @MainActor
    func testOpenExistingRunningSessionFocusesVisibleCockpitWithoutResume() async throws {
        let recorder = TerminalScriptRecorder()
        let focusRecorder = ExistingTerminalFocusRecorder(result: true)
        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "assigned-session",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
        )
        let coordinator = WorkBatchTaskSessionCoordinator(
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { script in
                await recorder.record(script)
            },
            focusExistingTerminal: { projectPath, sessionName in
                await focusRecorder.record(projectPath: projectPath, sessionName: sessionName)
            },
        )

        let request = try await coordinator.openExistingSession(binding)

        XCTAssertNil(request)
        let focusAttempts = await focusRecorder.snapshot()
        XCTAssertEqual(focusAttempts.count, 1)
        XCTAssertEqual(focusAttempts[0].projectPath, "/tmp/project/.capacitor/worktrees/batch-mobile")
        XCTAssertEqual(focusAttempts[0].sessionName, "Mobile prototype")
        let scripts = await recorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
    }

    @MainActor
    func testOpenExistingRunningSessionWritesFocusedActivationTrace() async throws {
        let collector = ActivationLogCollector()
        DebugLog.setTestObserver { line in
            collector.append(line)
        }
        defer { DebugLog.setTestObserver(nil) }

        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "assigned-session",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
        )
        let coordinator = WorkBatchTaskSessionCoordinator(
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { _ in },
            focusExistingTerminal: { _, _ in true },
        )

        _ = try await coordinator.openExistingSession(binding)

        let lines = collector.snapshot()
        XCTAssertTrue(lines.contains {
            $0.contains("[TerminalActivation]")
                && $0.contains("surface=\"work_batch_session\"")
                && $0.contains("route=\"work_batch_cockpit\"")
                && $0.contains("action=\"focus_existing\"")
                && $0.contains("outcome=\"focused\"")
        })
    }

    @MainActor
    func testOpenExistingRunningSessionDoesNotResumeWhenFocusFails() async throws {
        let recorder = TerminalScriptRecorder()
        let focusRecorder = ExistingTerminalFocusRecorder(result: false)
        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "assigned-session",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
        )
        let coordinator = WorkBatchTaskSessionCoordinator(
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { script in
                await recorder.record(script)
            },
            focusExistingTerminal: { projectPath, sessionName in
                await focusRecorder.record(projectPath: projectPath, sessionName: sessionName)
            },
        )

        do {
            _ = try await coordinator.openExistingSession(binding)
            XCTFail("Expected running binding focus failure to stop before resume")
        } catch let error as WorkBatchTaskSessionError {
            XCTAssertEqual(error, .existingSessionFocusFailed)
        }

        let focusAttempts = await focusRecorder.snapshot()
        XCTAssertEqual(focusAttempts.count, 1)
        XCTAssertEqual(focusAttempts[0].sessionName, "Mobile prototype")
        let scripts = await recorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
    }

    @MainActor
    func testManualOpenCanFocusStaleBindingBeforeResume() async throws {
        let recorder = TerminalScriptRecorder()
        let focusRecorder = ExistingTerminalFocusRecorder(result: true)
        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "assigned-session",
            status: .stale,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
        )
        let coordinator = WorkBatchTaskSessionCoordinator(
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { script in
                await recorder.record(script)
            },
            focusExistingTerminal: { projectPath, sessionName in
                await focusRecorder.record(projectPath: projectPath, sessionName: sessionName)
            },
        )

        let request = try await coordinator.openExistingSession(
            binding,
            allowResumeWhenFocusFails: true,
            preferFocusBeforeResume: true,
        )

        XCTAssertNil(request)
        let focusAttempts = await focusRecorder.snapshot()
        XCTAssertEqual(focusAttempts.count, 1)
        XCTAssertEqual(focusAttempts[0].projectPath, "/tmp/project/.capacitor/worktrees/batch-mobile")
        XCTAssertEqual(focusAttempts[0].sessionName, "Mobile prototype")
        let scripts = await recorder.snapshot()
        XCTAssertTrue(scripts.isEmpty)
    }

    @MainActor
    func testManualOpenResumesStaleBindingWhenFocusFails() async throws {
        let recorder = TerminalScriptRecorder()
        let focusRecorder = ExistingTerminalFocusRecorder(result: false)
        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "assigned-session",
            status: .stale,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
        )
        let coordinator = WorkBatchTaskSessionCoordinator(
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { script in
                await recorder.record(script)
            },
            focusExistingTerminal: { projectPath, sessionName in
                await focusRecorder.record(projectPath: projectPath, sessionName: sessionName)
            },
        )

        let request = try await coordinator.openExistingSession(
            binding,
            allowResumeWhenFocusFails: true,
            preferFocusBeforeResume: true,
        )

        XCTAssertEqual(request?.arguments.first, "--resume")
        XCTAssertEqual(request?.arguments.dropFirst().first, "assigned-session")
        let focusAttempts = await focusRecorder.snapshot()
        XCTAssertEqual(focusAttempts.count, 1)
        let scripts = await recorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--resume"))
        XCTAssertTrue(scripts[0].contains("assigned-session"))
    }

    @MainActor
    func testWakeExistingSessionInputsResumePromptIntoVisibleCockpit() async throws {
        let wakeRecorder = ExistingTerminalWakeRecorder(result: true)
        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "assigned-session",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
        )
        let coordinator = WorkBatchTaskSessionCoordinator(
            wakeExistingTerminal: { projectPath, sessionName, prompt in
                await wakeRecorder.record(
                    projectPath: projectPath,
                    sessionName: sessionName,
                    prompt: prompt,
                )
            },
        )

        try await coordinator.wakeExistingSession(binding)

        let attempts = await wakeRecorder.snapshot()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0].projectPath, "/tmp/project/.capacitor/worktrees/batch-mobile")
        XCTAssertEqual(attempts[0].sessionName, "Mobile prototype")
        XCTAssertEqual(attempts[0].prompt, "Assessing updated tasks...")
        XCTAssertFalse(attempts[0].prompt.contains("Task claim"))
    }

    @MainActor
    func testWakeExistingSessionThrowsWhenVisibleCockpitCannotBeWoken() async throws {
        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "assigned-session",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
        )
        let coordinator = WorkBatchTaskSessionCoordinator(
            wakeExistingTerminal: { _, _, _ in false },
        )

        do {
            try await coordinator.wakeExistingSession(binding)
            XCTFail("Expected failed wake to throw")
        } catch let error as WorkBatchTaskSessionError {
            XCTAssertEqual(error, .existingSessionWakeFailed)
        }
    }

    @MainActor
    func testOpenExistingStaleSessionLaunchesClaudeResumeInBatchWorktree() async throws {
        let recorder = TerminalScriptRecorder()
        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "assigned-session",
            status: .stale,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
        )
        let coordinator = WorkBatchTaskSessionCoordinator(
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { script in
                await recorder.record(script)
            },
            focusExistingTerminal: { _, _ in
                XCTFail("stale binding should reconnect by resume, not direct focus")
                return true
            },
        )

        let request = try await coordinator.openExistingSession(binding)

        XCTAssertEqual(request?.arguments.first, "--resume")
        XCTAssertEqual(request?.arguments.dropFirst().first, "assigned-session")
        XCTAssertTrue(request?.arguments.last?.contains("Assessing updated tasks...") == true)
        let scripts = await recorder.snapshot()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("--resume"))
        XCTAssertTrue(scripts[0].contains("assigned-session"))
        XCTAssertTrue(scripts[0].contains("--append-system-prompt-file"))
        XCTAssertTrue(scripts[0].contains(".capacitor/work-batch-agent-instructions.md"))
        XCTAssertFalse(scripts[0].contains("Task claim"))
        XCTAssertTrue(scripts[0].contains("/tmp/project/.capacitor/worktrees/batch-mobile"))
    }

    func testContextMirrorRendersTasksAndCheckpointGuidance() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let mirror = WorkBatchContextMirror(
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            tasks: [
                WorkBatchTaskItem(
                    id: "task-1",
                    title: "Add green border around the mobile prototype",
                    body: "Use the existing design tokens if possible.",
                    status: "queued",
                ),
            ],
            deliveryGeneration: "batch-mobile:1775000000",
            updatedAt: now,
        )

        XCTAssertTrue(mirror.markdown.contains("Batch: Mobile prototype"))
        XCTAssertTrue(mirror.markdown.contains("- [queued] Add green border around the mobile prototype (`task-1`)"))
        XCTAssertTrue(mirror.markdown.contains(".capacitor/work-batch-claims/<task-id>.json"))
        XCTAssertTrue(mirror.markdown.contains("\"status\":\"working\""))
        XCTAssertTrue(mirror.markdown.contains("\"delivery_generation\":\"batch-mobile:1775000000\""))
        XCTAssertFalse(mirror.markdown.contains("\"\""))
        XCTAssertTrue(mirror.markdown.contains(".capacitor/work-batch-completions/<task-id>.json"))
        XCTAssertTrue(mirror.markdown.contains(".capacitor/work-batch-checkpoints/<checkpoint-id>.json"))
        XCTAssertTrue(mirror.markdown.contains(".capacitor/work-batch-checkpoint-responses/<checkpoint-id>.json"))
        XCTAssertTrue(mirror.markdown.contains("\"status\":\"done\""))
        XCTAssertTrue(mirror.markdown.contains("If user input is needed before continuing, ask for a checkpoint"))
        XCTAssertTrue(mirror.markdown.contains("current agent-readable view"))
        XCTAssertFalse(mirror.markdown.contains("source of truth"))
        XCTAssertTrue(mirror.markdown.contains("Use the existing design tokens if possible."))
    }

    func testContextMirrorRendersPendingAndAnsweredCheckpoints() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let mirror = WorkBatchContextMirror(
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            tasks: [
                WorkBatchTaskItem(
                    id: "task-1",
                    title: "Add green border",
                    body: "",
                    status: "needs_you",
                ),
            ],
            checkpoints: [
                WorkBatchCheckpointRecord(
                    id: "checkpoint-green-token",
                    batchID: "batch-mobile",
                    taskID: "task-1",
                    question: "Which green token should I use?",
                    reason: "There are debug and production green tokens.",
                    recommendedAction: "Use production if this is user-facing.",
                    status: .pending,
                    requestedAt: now,
                    respondedAt: nil,
                    response: nil,
                    updatedAt: now,
                ),
                WorkBatchCheckpointRecord(
                    id: "checkpoint-border-width",
                    batchID: "batch-mobile",
                    taskID: "task-1",
                    question: "How wide should the border be?",
                    reason: "No width was specified.",
                    recommendedAction: nil,
                    status: .answered,
                    requestedAt: now,
                    respondedAt: now.addingTimeInterval(60),
                    response: "Use 2px.",
                    updatedAt: now.addingTimeInterval(60),
                ),
            ],
            updatedAt: now,
        )

        XCTAssertTrue(mirror.markdown.contains("- [pending] Which green token should I use? (`checkpoint-green-token`, Task `task-1`)"))
        XCTAssertTrue(mirror.markdown.contains("Recommended action: Use production if this is user-facing."))
        XCTAssertTrue(mirror.markdown.contains("- [answered] How wide should the border be? (`checkpoint-border-width`, Task `task-1`)"))
        XCTAssertTrue(mirror.markdown.contains("User response: Use 2px."))
    }

    func testContextMirrorInstallsLocalGitIgnoreForCapacitorMetadata() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktreeURL = tempDir.appendingPathComponent("worktree", isDirectory: true)
        let gitDirURL = tempDir.appendingPathComponent("gitdir", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: gitDirURL, withIntermediateDirectories: true)
        try "gitdir: ../gitdir\n".write(
            to: worktreeURL.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8,
        )
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let mirror = WorkBatchContextMirror(
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreePath: worktreeURL.path,
            tasks: [],
            updatedAt: Date(timeIntervalSince1970: 1_775_000_000),
        )

        _ = try mirror.write(fileManager: fileManager)
        _ = try mirror.write(fileManager: fileManager)

        let exclude = try String(
            contentsOf: gitDirURL
                .appendingPathComponent("info", isDirectory: true)
                .appendingPathComponent("exclude"),
            encoding: .utf8,
        )
        XCTAssertEqual(exclude.components(separatedBy: ".capacitor/").count - 1, 1)
        XCTAssertTrue(exclude.contains("# Capacitor Work Batch metadata\n.capacitor/"))
    }

    func testBindingStorePersistsBindingsUnderEnvelope() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("cockpit-bindings.json")
        let store = WorkBatchCockpitBindingStore(fileURL: fileURL, fileManager: fileManager)
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let binding = WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "56c839a4-3a6c-46a1-9e04-c9d6bde7f4b8",
            status: .launching,
            createdAt: now,
            updatedAt: now,
        )

        try store.upsert(binding)

        XCTAssertEqual(try store.load(), [binding])
        XCTAssertEqual(try store.binding(batchID: "batch-mobile"), binding)

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains(#""version" : 1"#))
        XCTAssertTrue(persisted.contains(#""claude_session_id" : "56c839a4-3a6c-46a1-9e04-c9d6bde7f4b8""#))
    }

    @MainActor
    func testCoordinatorCreatesBatchWorktreeStoresBindingAndLaunchesClaudeWithAssignedSessionID() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let storeURL = tempDir.appendingPathComponent("cockpit-bindings.json")
        let recorder = TerminalScriptRecorder()
        let worktreeService = WorktreeService(fileManager: fileManager) { arguments, cwd in
            guard arguments == [
                "worktree",
                "add",
                ".capacitor/worktrees/batch-mobile",
                "-b",
                "pkp/batch-mobile",
            ], cwd == projectRoot.path else {
                return .init(exitCode: 1, stdout: "", stderr: "unexpected git command")
            }

            let worktreeURL = projectRoot
                .appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
            try? fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }

        let coordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: worktreeService,
            fileManager: fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { "68d42879-5c45-40da-86de-2427c64411dc" },
            runTerminalScript: { script in
                await recorder.record(script)
            },
            bindingStoreFactory: { _ in
                WorkBatchCockpitBindingStore(fileURL: storeURL, fileManager: fileManager)
            },
        )

        let result = try await coordinator.startNewSession(
            WorkBatchTaskSessionStartRequest(
                projectPath: projectRoot.path,
                batchID: "batch-mobile",
                batchName: "Mobile prototype",
                tasks: [
                    WorkBatchTaskItem(
                        id: "task-1",
                        title: "Add green border around the mobile prototype",
                        body: "Test task from Capacitor.",
                        status: "queued",
                    ),
                ],
                now: Date(timeIntervalSince1970: 1_775_000_000),
            ),
        )

        XCTAssertEqual(result.binding.claudeSessionID, "68d42879-5c45-40da-86de-2427c64411dc")
        XCTAssertEqual(result.binding.worktreeName, "batch-mobile")
        XCTAssertEqual(result.launchRequest.arguments.prefix(2), ["--session-id", "68d42879-5c45-40da-86de-2427c64411dc"])
        XCTAssertTrue(result.launchRequest.arguments.contains("--append-system-prompt-file"))

        let mirror = try String(contentsOf: result.contextMirrorURL, encoding: .utf8)
        XCTAssertTrue(mirror.contains("Add green border around the mobile prototype"))
        XCTAssertTrue(mirror.contains("Keep visible terminal updates short and operator-facing"))
        XCTAssertTrue(result.contextMirrorURL.path.hasSuffix(WorkBatchContextMirror.relativePath))
        let instructionsURL = result.contextMirrorURL
            .deletingLastPathComponent()
            .appendingPathComponent("work-batch-agent-instructions.md")
        let instructions = try String(contentsOf: instructionsURL, encoding: .utf8)
        XCTAssertTrue(instructions.contains("Read .capacitor/work-batch-context.md"))
        XCTAssertTrue(instructions.contains("Task claim"))

        let loaded = try WorkBatchCockpitBindingStore(fileURL: storeURL, fileManager: fileManager).load()
        XCTAssertEqual(loaded, [result.binding])

        let launchedScripts = await recorder.snapshot()
        XCTAssertEqual(launchedScripts.count, 1)
        XCTAssertTrue(launchedScripts[0].contains("--session-id"))
        XCTAssertTrue(launchedScripts[0].contains("68d42879-5c45-40da-86de-2427c64411dc"))
        XCTAssertTrue(launchedScripts[0].contains("--append-system-prompt-file"))
        XCTAssertTrue(launchedScripts[0].contains(".capacitor/work-batch-agent-instructions.md"))
        XCTAssertFalse(launchedScripts[0].contains("Task claim"))
        XCTAssertTrue(launchedScripts[0].contains("Assessing tasks..."))
    }

    @MainActor
    func testCoordinatorDoesNotCreateWorktreeWhenClaudeIsMissing() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let storeURL = tempDir.appendingPathComponent("cockpit-bindings.json")
        var gitCalls = 0
        let worktreeService = WorktreeService(fileManager: fileManager) { _, _ in
            gitCalls += 1
            return .init(exitCode: 0, stdout: "", stderr: "")
        }

        let coordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: worktreeService,
            fileManager: fileManager,
            claudePathResolver: { nil },
            runTerminalScript: { _ in
                XCTFail("missing Claude should stop before launch")
            },
            bindingStoreFactory: { _ in
                WorkBatchCockpitBindingStore(fileURL: storeURL, fileManager: fileManager)
            },
        )

        do {
            _ = try await coordinator.startNewSession(
                WorkBatchTaskSessionStartRequest(
                    projectPath: projectRoot.path,
                    batchID: "batch-mobile",
                    batchName: "Mobile prototype",
                    tasks: [],
                ),
            )
            XCTFail("Expected missing Claude to throw")
        } catch let error as WorkBatchTaskSessionError {
            XCTAssertEqual(error, .claudeNotFound)
        }

        XCTAssertEqual(gitCalls, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: storeURL.path))
    }

    @MainActor
    func testCoordinatorDoesNotPersistBindingWhenTerminalLaunchFails() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let storeURL = tempDir.appendingPathComponent("cockpit-bindings.json")
        let worktreeService = WorktreeService(fileManager: fileManager) { arguments, cwd in
            guard arguments == [
                "worktree",
                "add",
                ".capacitor/worktrees/batch-mobile",
                "-b",
                "pkp/batch-mobile",
            ], cwd == projectRoot.path else {
                return .init(exitCode: 1, stdout: "", stderr: "unexpected git command")
            }
            let worktreeURL = projectRoot
                .appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true)
            try? fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }

        struct LaunchError: Error {}
        let coordinator = WorkBatchTaskSessionCoordinator(
            worktreeService: worktreeService,
            fileManager: fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { "assigned-session" },
            runTerminalScript: { _ in throw LaunchError() },
            bindingStoreFactory: { _ in
                WorkBatchCockpitBindingStore(fileURL: storeURL, fileManager: fileManager)
            },
        )

        do {
            _ = try await coordinator.startNewSession(
                WorkBatchTaskSessionStartRequest(
                    projectPath: projectRoot.path,
                    batchID: "batch-mobile",
                    batchName: "Mobile prototype",
                    tasks: [],
                ),
            )
            XCTFail("Expected terminal launch failure")
        } catch is LaunchError {
            // expected
        }

        XCTAssertFalse(fileManager.fileExists(atPath: storeURL.path))
    }

    func testWorktreeNameDoesNotDoublePrefixBatchIDs() {
        XCTAssertEqual(
            WorkBatchTaskSessionCoordinator.worktreeName(batchID: "batch-mobile"),
            "batch-mobile",
        )
        XCTAssertEqual(
            WorkBatchTaskSessionCoordinator.worktreeName(batchID: "Mobile Prototype"),
            "batch-mobile-prototype",
        )
        XCTAssertLessThanOrEqual(
            WorkBatchTaskSessionCoordinator.worktreeName(batchID: "batch-\(String(repeating: "a", count: 80))").count,
            38,
        )
    }
}

private actor TerminalScriptRecorder {
    private var scripts: [String] = []

    func record(_ script: String) {
        scripts.append(script)
    }

    func snapshot() -> [String] {
        scripts
    }
}

private actor ExistingTerminalFocusRecorder {
    struct Attempt: Equatable {
        let projectPath: String
        let sessionName: String?
    }

    private let result: Bool
    private var attempts: [Attempt] = []

    init(result: Bool) {
        self.result = result
    }

    func record(projectPath: String, sessionName: String?) -> Bool {
        attempts.append(Attempt(projectPath: projectPath, sessionName: sessionName))
        return result
    }

    func snapshot() -> [Attempt] {
        attempts
    }
}

private actor ExistingTerminalWakeRecorder {
    struct Attempt: Equatable {
        let projectPath: String
        let sessionName: String?
        let prompt: String
    }

    private let result: Bool
    private var attempts: [Attempt] = []

    init(result: Bool) {
        self.result = result
    }

    func record(projectPath: String, sessionName: String?, prompt: String) -> Bool {
        attempts.append(Attempt(projectPath: projectPath, sessionName: sessionName, prompt: prompt))
        return result
    }

    func snapshot() -> [Attempt] {
        attempts
    }
}
