@testable import Capacitor
import Observation
import XCTest

private final class BlockingState: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false

    func takeShouldBlock() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let shouldBlock = !blocked
        if shouldBlock {
            blocked = true
        }
        return shouldBlock
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
final class ProjectDetailsManagerObservationTests: XCTestCase {
    func testGetIdeasObservationInvalidatesWhenIdeasReordered() {
        let manager = ProjectDetailsManager()
        let project = ShellProjectReference(displayName: "Test", path: "/tmp/test")
        let reorderedIdeas = [
            Idea(
                id: "01JEXAMPLE00000000000000000",
                title: "Idea",
                description: "Desc",
                added: "2026-02-10T00:00:00Z",
                effort: "small",
                status: "open",
                triage: "pending",
                related: nil,
            ),
        ]

        let invalidated = expectation(description: "observation invalidated")
        withObservationTracking {
            _ = manager.getIdeas(for: project)
        } onChange: {
            invalidated.fulfill()
        }

        manager.reorderIdeas(reorderedIdeas, for: project)

        wait(for: [invalidated], timeout: 0.1)
    }

    func testGatherSensemakingContextDoesNotBlockMainActorWhileGitContextLoads() async {
        let commandStarted = expectation(description: "git command started")
        let mainActorAvailable = expectation(description: "main actor still available")
        let unblockCommand = AsyncGate()
        let blockingState = BlockingState()

        let manager = ProjectDetailsManager(gitCommandExecutor: { _, arguments in
            if blockingState.takeShouldBlock() {
                commandStarted.fulfill()
                await unblockCommand.wait()
            }

            switch arguments {
            case ["diff", "--name-only", "HEAD~3", "HEAD"]:
                return "Sources/App.swift\nREADME.md\n"
            case ["branch", "--show-current"]:
                return "feature/test\n"
            case ["log", "-1", "--format=%s"]:
                return "Improve loading\n"
            default:
                return nil
            }
        })

        let project = ShellProjectReference(displayName: "Test", path: "/tmp/test")
        let contextTask = _Concurrency.Task {
            await manager.gatherSensemakingContextForTesting(for: project, excluding: "ignored")
        }

        await fulfillment(of: [commandStarted], timeout: 1.0)

        _Concurrency.Task { @MainActor in
            mainActorAvailable.fulfill()
        }

        await fulfillment(of: [mainActorAvailable], timeout: 0.2)

        await unblockCommand.open()
        let context = await contextTask.value

        XCTAssertEqual(context.recentFiles, ["Sources/App.swift", "README.md"])
        XCTAssertEqual(context.gitBranch, "feature/test")
        XCTAssertEqual(context.lastCommitMessage, "Improve loading")
    }
}
