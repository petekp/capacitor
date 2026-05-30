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

@MainActor
final class ProjectDetailsManagerObservationTests: XCTestCase {
    func testGetIdeasObservationInvalidatesWhenIdeasReordered() {
        let manager = ProjectDetailsManager()
        let project = makeProject(name: "Test", path: "/tmp/test")
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
        let unblockCommand = DispatchSemaphore(value: 0)
        let blockingState = BlockingState()

        let manager = ProjectDetailsManager(gitCommandExecutor: { _, arguments in
            if blockingState.takeShouldBlock() {
                commandStarted.fulfill()
                unblockCommand.wait()
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

        let project = makeProject(name: "Test", path: "/tmp/test")
        let contextTask = _Concurrency.Task {
            await manager.gatherSensemakingContextForTesting(for: project, excluding: "ignored")
        }

        await fulfillment(of: [commandStarted], timeout: 1.0)

        _Concurrency.Task { @MainActor in
            mainActorAvailable.fulfill()
        }

        await fulfillment(of: [mainActorAvailable], timeout: 0.2)

        unblockCommand.signal()
        let context = await contextTask.value

        XCTAssertEqual(context.recentFiles, ["Sources/App.swift", "README.md"])
        XCTAssertEqual(context.gitBranch, "feature/test")
        XCTAssertEqual(context.lastCommitMessage, "Improve loading")
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            workspaceId: WorkspaceIdentity.fromPath(path),
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
}
