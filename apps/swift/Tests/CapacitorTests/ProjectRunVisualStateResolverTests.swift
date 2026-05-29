@testable import Capacitor
import XCTest

final class ProjectRunVisualStateResolverTests: XCTestCase {
    func testPausedCheckpointRunWinsOverActiveRun() throws {
        let projectPath = "/tmp/core-project"
        let now = try XCTUnwrap(parseISO8601Date("2026-03-26T10:06:10Z"))
        let activeRun = makeRun(
            id: "run-active",
            projectPath: projectPath,
            status: "active",
            updatedAt: "2026-03-26T10:05:00Z",
            createdAt: "2026-03-26T10:00:00Z",
            checkpointID: nil,
        )
        let pausedCheckpointRun = makeRun(
            id: "run-paused",
            projectPath: projectPath,
            status: "paused",
            updatedAt: "2026-03-26T10:06:00Z",
            createdAt: "2026-03-26T10:01:00Z",
            checkpointID: "checkpoint-1",
        )

        let resolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([activeRun, pausedCheckpointRun]),
            now: now,
        )

        XCTAssertEqual(resolution.run, pausedCheckpointRun)
        XCTAssertEqual(resolution.visualState, .waiting(statusMessage: nil))
    }

    func testPausedRunWithoutCheckpointSurfacesAsWaiting() throws {
        let projectPath = "/tmp/core-project"
        let now = try XCTUnwrap(parseISO8601Date("2026-03-26T10:06:10Z"))
        let activeRun = makeRun(
            id: "run-active",
            projectPath: projectPath,
            status: "active",
            updatedAt: "2026-03-26T10:05:00Z",
            createdAt: "2026-03-26T10:00:00Z",
            checkpointID: nil,
        )
        let pausedRun = makeRun(
            id: "run-paused-blocked",
            projectPath: projectPath,
            status: "paused",
            updatedAt: "2026-03-26T10:06:00Z",
            createdAt: "2026-03-26T10:01:00Z",
            checkpointID: nil,
            statusMessage: "Run blocked: gate rejected",
        )

        let resolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([activeRun, pausedRun]),
            now: now,
        )

        XCTAssertEqual(resolution.run, pausedRun)
        XCTAssertEqual(
            resolution.visualState,
            .waiting(statusMessage: "Run blocked: gate rejected"),
        )
    }

    func testActiveRunWinsOverCreatedRun() throws {
        let projectPath = "/tmp/core-project"
        let now = try XCTUnwrap(parseISO8601Date("2026-03-26T10:05:40Z"))
        let createdRun = makeRun(
            id: "run-created",
            projectPath: projectPath,
            status: "created",
            updatedAt: "2026-03-26T10:06:00Z",
            createdAt: "2026-03-26T10:06:00Z",
            checkpointID: nil,
        )
        let activeRun = makeRun(
            id: "run-active",
            projectPath: projectPath,
            status: "active",
            updatedAt: "2026-03-26T10:05:30Z",
            createdAt: "2026-03-26T10:00:00Z",
            checkpointID: nil,
        )

        let resolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([createdRun, activeRun]),
            now: now,
        )

        XCTAssertEqual(resolution.run, activeRun)
        XCTAssertEqual(resolution.visualState, .working(statusMessage: nil))
    }

    func testStaleActiveRunReturnsNone() {
        let projectPath = "/tmp/core-project"
        let updatedAt = "2026-03-26T10:06:00Z"
        let now = parseISO8601Date(updatedAt)!.addingTimeInterval(SessionStaleness.workingStaleThreshold + 1)
        let activeRun = makeRun(
            id: "run-stale-active",
            projectPath: projectPath,
            status: "active",
            updatedAt: updatedAt,
            createdAt: "2026-03-26T10:00:00Z",
            checkpointID: nil,
        )

        let resolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([activeRun]),
            now: now,
        )

        XCTAssertEqual(resolution.run, activeRun)
        XCTAssertEqual(resolution.visualState, .none)
    }

    func testStalePausedCheckpointRunResolvesToNone() throws {
        let projectPath = "/tmp/core-project"
        let updatedAt = "2026-03-26T10:06:00Z"
        let now = try XCTUnwrap(parseISO8601Date(updatedAt)?.addingTimeInterval(31 * 60))
        let pausedRun = makeRun(
            id: "run-stale-paused",
            projectPath: projectPath,
            status: "paused",
            updatedAt: updatedAt,
            createdAt: "2026-03-26T10:00:00Z",
            checkpointID: "checkpoint-1",
        )

        let resolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([pausedRun]),
            now: now,
        )

        XCTAssertNil(resolution.run)
        XCTAssertEqual(resolution.visualState, .none)
    }

    func testFreshActiveRunWinsOverStalePausedCheckpointRun() throws {
        let projectPath = "/tmp/core-project"
        let pausedUpdatedAt = "2026-03-26T10:06:00Z"
        let now = try XCTUnwrap(parseISO8601Date(pausedUpdatedAt)?.addingTimeInterval(31 * 60))
        let stalePausedRun = makeRun(
            id: "run-stale-paused",
            projectPath: projectPath,
            status: "paused",
            updatedAt: pausedUpdatedAt,
            createdAt: "2026-03-26T10:00:00Z",
            checkpointID: "checkpoint-1",
        )
        let freshActiveRun = makeRun(
            id: "run-fresh-active",
            projectPath: projectPath,
            status: "active",
            updatedAt: "2026-03-26T10:36:30Z",
            createdAt: "2026-03-26T10:35:00Z",
            checkpointID: nil,
        )

        let resolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([stalePausedRun, freshActiveRun]),
            now: now,
        )

        XCTAssertEqual(resolution.run, freshActiveRun)
        XCTAssertEqual(resolution.visualState, .working(statusMessage: nil))
    }

    func testStatusMessagePassesThroughForWorkingAndWaitingRuns() throws {
        let projectPath = "/tmp/core-project"
        let now = try XCTUnwrap(parseISO8601Date("2026-03-26T10:06:10Z"))
        let workingRun = makeRun(
            id: "run-working-message",
            projectPath: projectPath,
            status: "active",
            updatedAt: "2026-03-26T10:06:00Z",
            createdAt: "2026-03-26T10:00:00Z",
            checkpointID: nil,
            statusMessage: "Generating implementation plan",
        )
        let waitingRun = makeRun(
            id: "run-waiting-message",
            projectPath: projectPath,
            status: "paused",
            updatedAt: "2026-03-26T10:06:00Z",
            createdAt: "2026-03-26T10:01:00Z",
            checkpointID: "checkpoint-1",
            statusMessage: "Waiting for review decision",
        )

        let workingResolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([workingRun]),
            now: now,
        )
        let waitingResolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([waitingRun]),
            now: now,
        )

        XCTAssertEqual(workingResolution.run, workingRun)
        XCTAssertEqual(
            workingResolution.visualState,
            .working(statusMessage: "Generating implementation plan"),
        )
        XCTAssertEqual(waitingResolution.run, waitingRun)
        XCTAssertEqual(
            waitingResolution.visualState,
            .waiting(statusMessage: "Waiting for review decision"),
        )
    }

    func testTieBreaksByNewestUpdatedAtThenCreatedAt() throws {
        let projectPath = "/tmp/core-project"
        let now = try XCTUnwrap(parseISO8601Date("2026-03-26T10:06:10Z"))
        let olderUpdatedRun = makeRun(
            id: "run-older-updated",
            projectPath: projectPath,
            status: "active",
            updatedAt: "2026-03-26T10:05:00Z",
            createdAt: "2026-03-26T10:04:00Z",
            checkpointID: nil,
        )
        let newerUpdatedRun = makeRun(
            id: "run-newer-updated",
            projectPath: projectPath,
            status: "active",
            updatedAt: "2026-03-26T10:06:00Z",
            createdAt: "2026-03-26T10:03:00Z",
            checkpointID: nil,
        )

        let newerUpdatedResolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([olderUpdatedRun, newerUpdatedRun]),
            now: now,
        )

        XCTAssertEqual(newerUpdatedResolution.run, newerUpdatedRun)

        let olderCreatedRun = makeRun(
            id: "run-older-created",
            projectPath: projectPath,
            status: "active",
            updatedAt: "2026-03-26T10:06:00Z",
            createdAt: "2026-03-26T10:01:00Z",
            checkpointID: nil,
        )
        let newerCreatedRun = makeRun(
            id: "run-newer-created",
            projectPath: projectPath,
            status: "active",
            updatedAt: "2026-03-26T10:06:00Z",
            createdAt: "2026-03-26T10:02:00Z",
            checkpointID: nil,
        )

        let newerCreatedResolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([olderCreatedRun, newerCreatedRun]),
            now: now,
        )

        XCTAssertEqual(newerCreatedResolution.run, newerCreatedRun)
    }

    func testActiveRunWithPhasesShowsFormattedStepLine() throws {
        let projectPath = "/tmp/core-project"
        let now = try XCTUnwrap(parseISO8601Date("2026-03-26T10:06:10Z"))
        let phases: [RuntimePhaseInstance] = [
            RuntimePhaseInstance(id: "p1", name: "Research", status: .completed, startedAt: nil, completedAt: nil),
            RuntimePhaseInstance(id: "p2", name: "Implementation", status: .active, startedAt: nil, completedAt: nil),
            RuntimePhaseInstance(id: "p3", name: "Review", status: .pending, startedAt: nil, completedAt: nil),
        ]
        let run = RuntimeRunState(
            id: "run-phased",
            projectPath: projectPath,
            methodId: "shape_and_execute",
            methodName: "Shape & Execute",
            status: .active,
            sessionId: "s1",
            delegationWorkerId: nil,
            statusMessage: "Legacy status",
            phases: phases,
            currentPhaseIndex: 1,
            createdAt: "2026-03-26T10:00:00Z",
            updatedAt: "2026-03-26T10:05:30Z",
            activeCheckpoint: nil,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )

        let resolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([run]),
            now: now,
        )

        XCTAssertEqual(resolution.visualState, .working(statusMessage: "2/3 Implementation"))
    }

    func testCompletedRunWithPastCheckpointHistoryResolvesCompleted() throws {
        let projectPath = "/tmp/core-project"
        let now = try XCTUnwrap(parseISO8601Date("2026-03-26T10:06:10Z"))
        let completedRun = makeRun(
            id: "run-completed-with-history",
            projectPath: projectPath,
            status: "completed",
            updatedAt: "2026-03-26T10:05:30Z",
            createdAt: "2026-03-26T10:00:00Z",
            checkpointID: nil,
            pastCheckpoints: [
                RuntimeCheckpointState(
                    id: "checkpoint-decided",
                    phaseId: "phase-checkpoint-decided",
                    kind: .implementationMilestone,
                    status: "decided",
                    title: "Checkpoint checkpoint-decided",
                    summary: "Review the current milestone.",
                    briefPath: nil,
                    manifestPath: nil,
                    mediaArtifacts: [],
                    mermaidSources: [],
                    captureStatus: .notRequested,
                    captureUrl: nil,
                    captureClaim: nil,
                    decision: RuntimeCheckpointDecision(action: "approve", note: nil),
                    createdAt: "2026-03-26T10:04:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                ),
            ],
        )

        let resolution = ProjectRunVisualStateResolver.resolve(
            projectPath: projectPath,
            runsByID: runsByID([completedRun]),
            now: now,
        )

        XCTAssertEqual(resolution.run, completedRun)
        XCTAssertEqual(resolution.visualState, .completed(statusMessage: nil))
    }

    func testNoRunsReturnsNone() throws {
        let resolution = try ProjectRunVisualStateResolver.resolve(
            projectPath: "/tmp/core-project",
            runsByID: [:],
            now: XCTUnwrap(parseISO8601Date("2026-03-26T10:06:10Z")),
        )

        XCTAssertNil(resolution.run)
        XCTAssertEqual(resolution.visualState, .none)
    }

    private func runsByID(_ runs: [RuntimeRunState]) -> [RuntimeRunKey: RuntimeRunState] {
        Dictionary(uniqueKeysWithValues: runs.map { (RuntimeRunKey(run: $0), $0) })
    }

    private func makeRun(
        id: String,
        projectPath: String,
        status: String,
        updatedAt: String,
        createdAt: String,
        checkpointID: String?,
        statusMessage: String? = nil,
        pastCheckpoints: [RuntimeCheckpointState] = [],
    ) -> RuntimeRunState {
        let checkpoint: RuntimeCheckpointState? = if let checkpointID {
            RuntimeCheckpointState(
                id: checkpointID,
                phaseId: "phase-\(checkpointID)",
                kind: .implementationMilestone,
                status: "active",
                title: "Checkpoint \(checkpointID)",
                summary: "Review the current milestone.",
                briefPath: nil,
                manifestPath: nil,
                mediaArtifacts: [],
                mermaidSources: [],
                captureStatus: .notRequested,
                captureUrl: nil,
                captureClaim: nil,
                createdAt: updatedAt,
                decidedAt: nil,
            )
        } else {
            nil
        }

        return RuntimeRunState(
            id: id,
            projectPath: projectPath,
            methodId: "execution_only",
            methodName: "Execute",
            status: try! RunStatus.decode(wire: status),
            sessionId: "run-session-\(id)",
            delegationWorkerId: nil,
            statusMessage: statusMessage,
            createdAt: createdAt,
            updatedAt: updatedAt,
            activeCheckpoint: checkpoint,
            pastCheckpoints: pastCheckpoints,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }
}
