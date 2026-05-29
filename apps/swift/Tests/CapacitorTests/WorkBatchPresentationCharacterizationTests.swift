@testable import Capacitor
import Foundation
import XCTest

/// CHARACTERIZATION (oracle) tests for the (status, currentActivitySummary) the
/// home UI consumes for a Work Batch.
///
/// Method: drive REAL operations through `WorkBatchAutoRouter`,
/// `WorkBatchBindingReconciler`, and `WorkBatchProjectionBuilder`, then assert
/// on the PROJECTION the UI reads — `WorkBatchProjection.status` (which feeds
/// the StatusChip via `.sessionState`) and `WorkBatchProjection.currentActivitySummary`
/// — NOT on internal mark*/stored fields.
///
/// Asserting on the projection output makes this oracle valid across the
/// upcoming stored->derived refactor: the rewrite must reproduce the exact same
/// projection for each path. Each test pins the captured strings as constants
/// so a drift is loud.
///
/// The effective home StatusChip state is `pendingCheckpoints.isEmpty ? status.sessionState : .waiting`
/// (see WorkBatchHomeCardView). We expose that as `chipState(_:)` below so the
/// rewrite cannot silently change what the chip shows even if it changes the
/// underlying batch status enum.
@MainActor
final class WorkBatchPresentationCharacterizationTests: XCTestCase {
    // MARK: - Effective chip helper (what the card actually renders)

    /// Mirrors `WorkBatchHomeCardView`: a pending checkpoint forces the chip to
    /// `.waiting` regardless of the batch status enum.
    private func chipState(_ projection: WorkBatchProjection) -> SessionState {
        projection.pendingCheckpoints.isEmpty ? projection.status.sessionState : .waiting
    }

    // =========================================================================
    // MARK: - Reconciler-driven mark* paths (pure static reconcile + build)

    // =========================================================================
    // The reconciler is a pure function, so we drive it directly and project the
    // resulting state. These cover markRunningIfUseful / markActiveCockpitIfUseful
    // / markDoneIfUseful / markWaitingForUser / markBatch.

    func testReconciler_exactLiveSession_marksRunning_projectsWorking() {
        let result = reconcile(
            batchStatus: .waiting,
            summary: "Claude Code session needs reconnect.",
            taskStatus: .queued,
            bindingStatus: .stale,
            sessions: [session(id: "session-batch", cwd: worktree, isAlive: true)],
        )
        let projection = project(result)
        // ORACLE NOTE: markRunningIfUseful sets the STORED summary to
        // "Working on Add green border.", but the batch is .working with a
        // single queued task, so WorkBatchProjectionBuilder.displaySummary
        // RE-DERIVES the working-branch summary to "Queued <title>." — that is
        // what the UI actually shows. The rewrite must reproduce the PROJECTED
        // value, not the stored mark* prose.
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, "Queued Add green border.")
        XCTAssertEqual(chipState(projection), .working)
    }

    func testReconciler_missingSession_marksStale_projectsWaitingReconnect() {
        let result = reconcile(
            batchStatus: .working,
            summary: "Claude Code is starting on Add green border.",
            taskStatus: .working,
            bindingStatus: .launching,
            bindingUpdatedAt: Date(timeIntervalSince1970: 1_775_000_080), // > launchGrace before `now`
            sessions: [],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, "Claude Code session needs reconnect.")
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testReconciler_recentLaunching_keepsStartingSummary() {
        let result = reconcile(
            batchStatus: .working,
            summary: "Claude Code is starting on Add green border.",
            taskStatus: .working,
            bindingStatus: .launching,
            bindingUpdatedAt: Date(timeIntervalSince1970: 1_775_000_190), // inside launchGrace
            sessions: [],
        )
        let projection = project(result)
        // launching binding inside grace: batch keeps its working/launching prose.
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, "Claude Code is starting on Add green border.")
        XCTAssertEqual(chipState(projection), .working)
    }

    func testReconciler_doneBatch_liveAliveCockpit_replaceableSummary_projectsReadyDone() {
        // markDoneIfUseful only replaces the summary when
        // shouldReplaceSummaryAfterCompletion matches. An empty/replaceable
        // stored summary IS replaced with the completion summary.
        let result = reconcile(
            batchStatus: .working,
            summary: "",
            taskStatus: .done,
            bindingStatus: .running,
            sessions: [session(id: "session-batch", cwd: worktree, state: "ready", toolsInFlight: 0, isAlive: true)],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .ready)
        XCTAssertEqual(projection.currentActivitySummary, "Done: Add green border.")
        XCTAssertEqual(chipState(projection), .ready)
    }

    func testReconciler_doneBatch_liveAliveCockpit_workingOnProse_survivesAsReadySummary() {
        // ORACLE NOTE / FRAGILE STICKINESS: shouldReplaceSummaryAfterCompletion
        // matches the substring "is working" but NOT "Working on". So a stale
        // "Working on <title>." prose is NOT replaced when the batch completes —
        // it survives into a .ready (Done) batch and the home card shows the
        // stale working prose despite the batch being done. The rewrite must
        // reproduce this exact (status=.ready, stale "Working on ..." summary)
        // unless the audit intends to fix it; pinning it makes any change loud.
        let result = reconcile(
            batchStatus: .working,
            summary: "Working on Add green border.",
            taskStatus: .done,
            bindingStatus: .running,
            sessions: [session(id: "session-batch", cwd: worktree, state: "ready", toolsInFlight: 0, isAlive: true)],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .ready)
        XCTAssertEqual(projection.currentActivitySummary, "Working on Add green border.")
        XCTAssertEqual(chipState(projection), .ready)
    }

    func testReconciler_doneBatch_workingAssignedCockpit_projectsWorkingCheckingFinalResult() {
        let result = reconcile(
            batchStatus: .ready,
            summary: "Done: Add green border.",
            taskStatus: .done,
            bindingStatus: .done,
            sessions: [session(id: "session-batch", cwd: worktree, state: "working", toolsInFlight: 0, isAlive: true)],
        )
        let projection = project(result)
        // markActiveCockpitIfUseful: working exact cockpit + no dupes => .working
        // BUT displaySummary re-derives for .working with all tasks done =>
        // "Checking final result."
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, "Checking final result.")
        XCTAssertEqual(chipState(projection), .working)
    }

    func testReconciler_pendingCheckpoint_replacesReconnectSummary_withCheckpointNeedsInput() {
        // markWaitingForUser replaces a "needs reconnect" summary with the
        // generic "Checkpoint needs your input." because the bespoke checkpoint
        // prose is not present.
        let result = reconcileWithCheckpoint(
            batchStatus: .working,
            summary: "Claude Code session needs reconnect.",
            taskStatus: .needsYou,
            bindingStatus: .stale,
            sessions: [],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, "Checkpoint needs your input.")
        XCTAssertEqual(projection.pendingCheckpoints.count, 1)
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testReconciler_pendingCheckpoint_keepsBespokeCheckpointReadySummary_sticky() {
        // STICKY: the bespoke "Checkpoint ready: <question>" prose is preserved
        // by shouldReplaceSummaryForUserInput (it neither matches the generic
        // markers nor is empty), so markWaitingForUser leaves it intact.
        let bespoke = "Checkpoint ready: Which green token should I use?"
        let result = reconcileWithCheckpoint(
            batchStatus: .waiting,
            summary: bespoke,
            taskStatus: .needsYou,
            bindingStatus: .waiting,
            sessions: [session(id: "session-batch", cwd: worktree, isAlive: true)],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, bespoke)
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testReconciler_pendingCheckpoint_winsOverDuplicateCockpit_keepsCheckpointReady() {
        // A pending checkpoint + duplicate cockpit: the user's decision stays
        // visible, bespoke summary preserved.
        let bespoke = "Checkpoint ready: Which green token should I use?"
        let result = reconcileWithCheckpoint(
            batchStatus: .waiting,
            summary: bespoke,
            taskStatus: .needsYou,
            bindingStatus: .running,
            sessions: [
                session(id: "session-batch", cwd: worktree, isAlive: true),
                session(id: "manual-duplicate", cwd: "\(worktree)/src", isAlive: true),
            ],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, bespoke)
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testReconciler_duplicateForeignCockpit_projectsWaiting_multipleSessionsMatch() {
        // SMUGGLED-IN ATTENTION STATE #1 (duplicate-cockpit, foreign): no backing
        // field, lives only in the summary string.
        let result = reconcile(
            batchStatus: .working,
            summary: "Working on Add green border.",
            taskStatus: .queued,
            bindingStatus: .running,
            sessions: [
                session(id: "session-batch", cwd: worktree, isAlive: true),
                session(id: "manual-duplicate", cwd: "\(worktree)/src", isAlive: true),
            ],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, "Multiple Claude Code sessions match this Work Batch.")
        XCTAssertEqual(chipState(projection), .waiting)
    }

    /// C5 RETIREMENT LOCK: same-session OS-process duplicate detection is gone.
    /// A single assigned, process-alive session (no foreign session ids) is just
    /// the live cockpit — it must NOT project the duplicate-cockpit waiting
    /// state.
    func testReconciler_singleAssignedProcessAlive_doesNotProjectDuplicateWaiting() {
        let result = reconcile(
            batchStatus: .working,
            summary: "Working on Add green border.",
            taskStatus: .queued,
            bindingStatus: .running,
            sessions: [
                // The OS-liveness sweep reports the single assigned session as
                // process-alive after its event signals decayed. This is the
                // live cockpit, not a duplicate.
                session(
                    id: "session-batch",
                    cwd: worktree,
                    state: "working",
                    gcReason: "signal_absence",
                    isAlive: false,
                    osProcessAlive: true,
                ),
            ],
        )
        let projection = project(result)
        XCTAssertNotEqual(projection.status, .waiting)
        XCTAssertNotEqual(projection.currentActivitySummary, "Multiple Claude Code sessions match this Work Batch.")
        XCTAssertNotEqual(chipState(projection), .waiting)
    }

    func testReconciler_doneBatch_foreignDuplicate_staysReadyDone() {
        // Done batch with foreign duplicate: does NOT pull back to waiting; the
        // batch stays Ready with its Done summary, only duplicate evidence is
        // recorded (issue), not a summary change.
        let result = reconcile(
            batchStatus: .ready,
            summary: "Done: Add green border.",
            taskStatus: .done,
            bindingStatus: .done,
            sessions: [
                session(id: "session-batch", cwd: worktree, state: "ready", toolsInFlight: 0, isAlive: true),
                session(id: "manual-duplicate", cwd: "\(worktree)/src", state: "ready", toolsInFlight: 0, isAlive: true),
            ],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .ready)
        XCTAssertEqual(projection.currentActivitySummary, "Done: Add green border.")
        XCTAssertEqual(chipState(projection), .ready)
    }

    // =========================================================================
    // MARK: - Router-driven mark* paths

    // =========================================================================

    func testRouter_newSession_launchSummary_projectsWorkingStarting() async throws {
        let harness = try Harness()
        let router = harness.router(
            classifier: harness.newBatchClassifier(name: "Mobile prototype"),
            coordinator: harness.launchingCoordinator(expectedName: "batch-mobile-prototype-idea-1", sessionID: "assigned-session-1"),
        )
        let result = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-1", title: "Add green border around the mobile prototype"),
            now: harness.now,
        )
        let projection = harness.projection(router: router, batchID: result.batch.id)
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(
            projection.currentActivitySummary,
            "Claude Code is starting on Add green border around the mobile prototype.",
        )
        XCTAssertEqual(chipState(projection), .working)
    }

    func testRouter_newBatchAppend_starting_displaySummaryRederivesFromTask() async throws {
        // The freshly appended batch carries "Starting <title>." while queued;
        // displaySummary (working status, single queued task) re-derives to
        // "Queued <title>." — pin the projected value.
        let harness = try Harness()
        // Force a launch failure AFTER the new batch is appended so the batch
        // stays with a queued task and we can observe the new-batch prose path
        // through displaySummary. Easiest: route into an existing bound batch.
        // Instead, drive markLaunchFailed via a failing new-session launch.
        struct LaunchError: Error {}
        let router = harness.router(
            classifier: harness.newBatchClassifier(name: "Mobile prototype"),
            coordinator: harness.failingCoordinator(expectedName: "batch-mobile-prototype-idea-1", error: LaunchError()),
        )
        do {
            _ = try await router.routeCapturedTask(
                project: harness.project,
                idea: harness.idea(id: "idea-1", title: "Add green border"),
                now: harness.now,
            )
            XCTFail("expected launch failure")
        } catch is LaunchError {}

        let projections = router.projections(for: harness.project.path)
        let projection = try XCTUnwrap(projections.first)
        // markLaunchFailed sets status=.waiting, summary="Claude Code launch needs attention."
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, "Claude Code launch needs attention.")
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testRouter_existingBindingContextMirrorFailure_markLaunchFailed() async throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        // Point the binding's worktree at a regular file so the mirror write throws.
        let fileURL = harness.tempDir.appendingPathComponent("not-a-worktree")
        try "file".write(to: fileURL, atomically: true, encoding: .utf8)
        try harness.bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: harness.project.path,
            worktreeName: "batch-mobile",
            worktreePath: fileURL.path,
            host: .claudeCode,
            claudeSessionID: "assigned-session-existing",
            status: .running,
            createdAt: harness.now,
            updatedAt: harness.now,
        ))
        let router = harness.router(
            classifier: harness.existingClassifier(batchID: "batch-mobile"),
            coordinator: harness.noLaunchCoordinator(),
        )
        do {
            _ = try await router.routeCapturedTask(
                project: harness.project,
                idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
                now: harness.now,
            )
            XCTFail("expected mirror write failure")
        } catch {}

        let projection = harness.projection(router: router, batchID: "batch-mobile")
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, "Claude Code launch needs attention.")
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testRouter_resumeStaleBinding_markResumeStarted_projectsWorkingReconnecting() async throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale, taskStatus: .queued)
        var state = try harness.stateStore.load()
        state.batches[0].currentActivitySummary = "Claude Code launch needs attention."
        try harness.stateStore.save(state)
        let router = harness.router(
            classifier: harness.existingClassifier(batchID: "batch-mobile"),
            coordinator: harness.recordingCoordinator(expectedName: "should-not-launch"),
        )
        _ = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now,
        )
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        // ORACLE NOTE: markResumeStarted STORES
        // "Claude Code is reconnecting to <title>." and re-queues the task, but
        // the batch is .working with a single queued task, so displaySummary
        // RE-DERIVES to "Queued <title>." for the UI. The bespoke reconnecting
        // prose never reaches the home card on this path.
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(
            projection.currentActivitySummary,
            "Queued Add green border around the mobile prototype.",
        )
        XCTAssertEqual(chipState(projection), .working)
    }

    func testRouter_wakeExistingSession_markExistingSessionWoken_projectsWorkingNudged() async throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .stale, taskStatus: .queued)
        var state = try harness.stateStore.load()
        state.batches[0].currentActivitySummary = "Claude Code session needs reconnect."
        try harness.stateStore.save(state)
        let router = harness.router(
            classifier: harness.existingClassifier(batchID: "batch-mobile"),
            coordinator: harness.wakingCoordinator(expectedName: "should-not-launch"),
            safeWakeBoundaryAllowsInput: { binding in binding.batchID == "batch-mobile" },
        )
        _ = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.session(
                    id: "assigned-session-existing",
                    cwd: harness.mobileWorktreePath,
                    state: "working",
                    gcReason: "signal_absence",
                    isAlive: false,
                    osProcessAlive: true,
                ),
            ],
            now: harness.now,
        )
        _ = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now.addingTimeInterval(5),
        )
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        // ORACLE NOTE: markExistingSessionWoken STORES
        // "Claude Code was nudged to pick up <title>." and re-queues the task,
        // but the batch is .working with a single queued task, so displaySummary
        // RE-DERIVES to "Queued <title>." for the UI. The bespoke nudge prose
        // never reaches the home card on this path.
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(
            projection.currentActivitySummary,
            "Queued Add green border around the mobile prototype.",
        )
        XCTAssertEqual(chipState(projection), .working)
    }

    func testRouter_pickupTimeout_markBatchPickupTimedOut_projectsWaitingNotPickedUp() async throws {
        // SMUGGLED-IN ATTENTION STATE #2 (pickup-timeout): no backing field,
        // lives only in the summary string.
        let harness = try Harness()
        try harness.seedMobileBatch(
            status: .working,
            bindingStatus: .running,
            taskStatus: .queued,
            deliveryRecords: [
                WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: harness.now,
                    lastDeliveryGeneration: "batch-mobile:current",
                    lastDeliveryAttemptAt: harness.now,
                    lastDeliveryAttemptKind: WorkBatchDeliveryAction.wakeExistingSession.rawValue,
                    lastClaimAt: nil,
                ),
            ],
        )
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.wakingCoordinator(expectedName: "should-not-launch"),
        )
        _ = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.session(
                    id: "assigned-session-existing",
                    cwd: harness.mobileWorktreePath,
                    state: "working",
                    gcReason: "signal_absence",
                    isAlive: false,
                    osProcessAlive: true,
                ),
            ],
            now: harness.now,
        )
        _ = try await router.followThroughWorkBatchDelivery(
            project: harness.project,
            batchID: "batch-mobile",
            preferredTaskID: "idea-old",
            now: harness.now.addingTimeInterval(WorkBatchDeliveryPolicy.pickupClaimTimeout + 1),
        )
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(
            projection.currentActivitySummary,
            "Claude Code has not picked up Adjust mobile spacing yet. Click to re-enter.",
        )
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testRouter_reconciliationBlockedDuplicate_markReconciliationBlocked_projectsWaiting() async throws {
        // markReconciliationBlocked via the delivery policy duplicate-cockpit
        // branch. Foreign duplicate => "Multiple Claude Code sessions match this Work Batch."
        let harness = try Harness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running, taskStatus: .queued)
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.wakingCoordinator(expectedName: "should-not-launch"),
        )
        _ = router.reconcileBindings(
            projects: [harness.project],
            sessions: [
                harness.session(id: "assigned-session-existing", cwd: harness.mobileWorktreePath, isAlive: true),
                harness.session(id: "manual-duplicate", cwd: "\(harness.mobileWorktreePath)/src", isAlive: true),
            ],
            now: harness.now,
        )
        _ = try await router.followThroughWorkBatchDelivery(
            project: harness.project,
            batchID: "batch-mobile",
            preferredTaskID: "idea-old",
            now: harness.now,
        )
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, "Multiple Claude Code sessions match this Work Batch.")
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testRouter_existingBatchQueue_markClassificationApplied_projectsWorkingQueuedSummary() async throws {
        // applyClassification existing branch: status=.working, summary="Queued <title> in <name>."
        // displaySummary for .working with a queued task + a working task re-derives;
        // here the existing task is .working and the new one is .queued, so
        // displaySummary returns "Working on <workingTitle>. 1 queued."
        let harness = try Harness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running, taskStatus: .working)
        let router = harness.router(
            classifier: harness.existingClassifier(batchID: "batch-mobile"),
            coordinator: harness.noLaunchCoordinator(),
        )
        _ = try await router.routeCapturedTask(
            project: harness.project,
            idea: harness.idea(id: "idea-green", title: "Add green border around the mobile prototype"),
            now: harness.now,
        )
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(
            projection.currentActivitySummary,
            "Working on Adjust mobile spacing. 1 queued.",
        )
        XCTAssertEqual(chipState(projection), .working)
    }

    func testRouter_ingestCheckpoint_projectsWaitingCheckpointReady() throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running, taskStatus: .working)
        _ = try WorkBatchCheckpointRequestStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchCheckpointRequest(
            checkpointID: "checkpoint-green-token",
            taskID: "idea-old",
            question: "Which green token should I use?",
            reason: "There are multiple green tokens.",
            recommendedAction: "Use production if this is product-facing.",
            requestedAt: harness.now.addingTimeInterval(30),
        ))
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.noLaunchCoordinator(),
        )
        _ = router.ingestCheckpointRequests(projects: [harness.project], now: harness.now.addingTimeInterval(30))
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, "Checkpoint ready: Which green token should I use?")
        XCTAssertEqual(projection.pendingCheckpoints.count, 1)
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testRouter_ingestTaskClaim_projectsWorkingClaimSummary() throws {
        let harness = try Harness()
        let claimTime = harness.now.addingTimeInterval(20)
        try harness.seedMobileBatch(
            status: .working,
            bindingStatus: .running,
            taskStatus: .queued,
            deliveryRecords: [
                WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: harness.now,
                    lastDeliveryGeneration: "batch-mobile:1775000000",
                    lastDeliveryAttemptAt: nil,
                    lastDeliveryAttemptKind: nil,
                    lastClaimAt: nil,
                ),
            ],
        )
        _ = try WorkBatchTaskClaimStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchTaskClaim(
            taskID: "idea-old",
            status: "working",
            summary: "Working on mobile spacing.",
            claimedAt: claimTime,
            contextUpdatedAt: harness.now,
            deliveryGeneration: "batch-mobile:1775000000",
        ))
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.noLaunchCoordinator(),
        )
        _ = router.ingestTaskClaims(projects: [harness.project], now: claimTime)
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        // task is now .working, batch is .working with single working task =>
        // displaySummary returns the stored claim summary unchanged.
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, "Working on mobile spacing.")
        XCTAssertEqual(chipState(projection), .working)
    }

    func testRouter_ingestCompletionReport_allDone_projectsIdleDone() throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        let completedAt = harness.now.addingTimeInterval(10)
        _ = try WorkBatchCompletionReportStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchCompletionReport(
            taskID: "idea-old",
            status: "done",
            summary: "Adjusted mobile spacing",
            evidence: ["Changed spacing constants"],
            completedAt: completedAt,
        ))
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.noLaunchCoordinator(),
        )
        _ = router.ingestCompletionReports(projects: [harness.project], now: completedAt)
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        XCTAssertEqual(projection.status, .idle)
        XCTAssertEqual(projection.currentActivitySummary, "Done: Adjusted mobile spacing.")
        XCTAssertEqual(chipState(projection), .idle)
    }

    func testRouter_ingestCompletionReport_partialDone_projectsWorkingDoneWithOpenCount() throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .working, bindingStatus: .running)
        var state = try harness.stateStore.load()
        state.batches[0].taskIDs.append("idea-green")
        state.tasks.append(WorkBatchTaskRecord(
            id: "idea-green",
            sourceIdeaID: "idea-green",
            title: "Add green border",
            body: "",
            status: .queued,
            batchID: "batch-mobile",
            createdAt: harness.now,
            updatedAt: harness.now,
        ))
        try harness.stateStore.save(state)
        let completedAt = harness.now.addingTimeInterval(10)
        _ = try WorkBatchCompletionReportStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchCompletionReport(
            taskID: "idea-old",
            status: "done",
            summary: "Adjusted mobile spacing",
            evidence: [],
            completedAt: completedAt,
        ))
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.noLaunchCoordinator(),
        )
        _ = router.ingestCompletionReports(projects: [harness.project], now: completedAt)
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        // binding .running => batchStatusAfterPartialDone => .working, then
        // displaySummary working-branch: one queued task remains, no working
        // task => "Queued Add green border."
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, "Queued Add green border.")
        XCTAssertEqual(chipState(projection), .working)
    }

    func testRouter_submitCheckpointResponse_moreOpenTasks_projectsWaitingAnswered() throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .waiting, taskStatus: .needsYou)
        var state = try harness.stateStore.load()
        state.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "cp-1",
                batchID: "batch-mobile",
                taskID: "idea-old",
                question: "Which green token should I use?",
                reason: "Multiple greens.",
                recommendedAction: nil,
                status: .pending,
                requestedAt: harness.now,
                respondedAt: nil,
                response: nil,
                updatedAt: harness.now,
            ),
        ]
        try harness.stateStore.save(state)
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.noLaunchCoordinator(),
        )
        _ = try router.submitCheckpointResponse(
            project: harness.project,
            batchID: "batch-mobile",
            checkpointID: "cp-1",
            response: "Use production token",
            now: harness.now.addingTimeInterval(60),
        )
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(
            projection.currentActivitySummary,
            "Answered checkpoint for Adjust mobile spacing. Claude Code will continue.",
        )
        XCTAssertTrue(projection.pendingCheckpoints.isEmpty)
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testRouter_submitCheckpointResponse_noOpenTasks_projectsIdleDone() throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .waiting, bindingStatus: .waiting, taskStatus: .done)
        var state = try harness.stateStore.load()
        state.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "cp-1",
                batchID: "batch-mobile",
                taskID: "idea-old",
                question: "Which green token should I use?",
                reason: "Multiple greens.",
                recommendedAction: nil,
                status: .pending,
                requestedAt: harness.now,
                respondedAt: nil,
                response: nil,
                updatedAt: harness.now,
            ),
        ]
        try harness.stateStore.save(state)
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.noLaunchCoordinator(),
        )
        _ = try router.submitCheckpointResponse(
            project: harness.project,
            batchID: "batch-mobile",
            checkpointID: "cp-1",
            response: "Use production token",
            now: harness.now.addingTimeInterval(60),
        )
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        // already-done task: closes the attention item to .idle with Done prose.
        XCTAssertEqual(projection.status, .idle)
        XCTAssertEqual(projection.currentActivitySummary, "Done: Adjust mobile spacing.")
        XCTAssertTrue(projection.pendingCheckpoints.isEmpty)
        XCTAssertEqual(chipState(projection), .idle)
    }

    func testRouter_unresolveTask_projectsWaitingReopened() throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .idle, bindingStatus: .done, taskStatus: .done)
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.noLaunchCoordinator(),
        )
        _ = try router.unresolveTask(
            project: harness.project,
            batchID: "batch-mobile",
            taskID: "idea-old",
            now: harness.now.addingTimeInterval(60),
        )
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(
            projection.currentActivitySummary,
            "Reopened Adjust mobile spacing. Claude Code will pick it back up.",
        )
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testRouter_ingestTaskRequest_projectsWorkingQueuedSummary() throws {
        let harness = try Harness()
        try harness.seedMobileBatch(status: .ready, bindingStatus: .running, taskStatus: .done)
        let requestedAt = harness.now.addingTimeInterval(30)
        _ = try WorkBatchTaskRequestStore(
            worktreePath: harness.mobileWorktreePath,
            fileManager: harness.fileManager,
        ).write(WorkBatchTaskRequest(
            taskID: "Task/Empty State Copy",
            title: "Fix empty state copy",
            body: "The user asked for clearer copy in the empty state.",
            source: "manual_user_instruction",
            requestedAt: requestedAt,
        ))
        let router = harness.router(
            classifier: harness.throwingClassifier(),
            coordinator: harness.noLaunchCoordinator(),
        )
        _ = router.ingestTaskRequests(projects: [harness.project], now: requestedAt)
        let projection = harness.projection(router: router, batchID: "batch-mobile")
        // running binding => statusAfterQueuedTaskRequest => .working.
        // displaySummary working branch: one queued task, no working task =>
        // "Queued Fix empty state copy."
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, "Queued Fix empty state copy.")
        XCTAssertEqual(chipState(projection), .working)
    }

    // =========================================================================
    // MARK: - Normal lifecycle / displaySummary / displayPriority (pure build)

    // =========================================================================

    func testBuild_workingWithWorkingAndQueued_summarizesWorkingPlusCount() {
        let batch = batchRecord(status: .working, summary: "ignored stored prose")
        let tasks = [
            task(id: "t1", title: "First task", status: .working, createdAt: 0),
            task(id: "t2", title: "Second task", status: .queued, createdAt: 1),
            task(id: "t3", title: "Third task", status: .queued, createdAt: 2),
        ]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, "Working on First task. 2 queued.")
        XCTAssertEqual(projection.queuedTaskCount, 2)
    }

    func testBuild_workingSingleTask_emptyRecorded_summarizesWorkingOnTitle() {
        // 3a PARITY (markRunningIfUseful + runningSummary): a single .working
        // Task with NO .queued Task and a replaceable/empty recorded line was
        // given "Working on <title>." by the reconciler. 3b's displaySummary
        // working-branch only overrode for working+queued / queued-only /
        // all-done, so this case projected the EMPTY recorded line. The restored
        // branch must re-derive the running summary here.
        let batch = batchRecord(status: .working, summary: "")
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .working, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, "Working on Adjust mobile spacing.")
        XCTAssertEqual(chipState(projection), .working)
    }

    func testBuild_workingSingleTask_bespokeStartingLine_isPreserved() {
        // Sibling guard for the restored running-summary branch: a genuine,
        // non-replaceable bespoke recorded line for a single working Task (a
        // fresh launch line) does NOT match shouldReplaceSummaryAfterRecovery, so
        // it must pass through unchanged rather than being overwritten with the
        // generic "Working on <title>." running summary.
        let bespoke = "Claude Code is starting on Adjust mobile spacing."
        let batch = batchRecord(status: .working, summary: bespoke)
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .working, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, bespoke)
        XCTAssertEqual(chipState(projection), .working)
    }

    func testBuild_workingAllDone_summarizesCheckingFinalResult() {
        let batch = batchRecord(status: .working, summary: "ignored stored prose")
        let tasks = [
            task(id: "t1", title: "First task", status: .done, createdAt: 0),
            task(id: "t2", title: "Second task", status: .done, createdAt: 1),
        ]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.status, .working)
        XCTAssertEqual(projection.currentActivitySummary, "Checking final result.")
    }

    func testBuild_genericDoneSummary_isRederivedToCompletionSummary() {
        let batch = batchRecord(status: .idle, summary: "Done: all tasks completed.")
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .done, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.status, .idle)
        XCTAssertEqual(projection.currentActivitySummary, "Done: Adjust mobile spacing.")
    }

    func testBuild_startingPlaceholderEllipsis_isRederivedFromTaskTitle() {
        let batch = batchRecord(status: .ready, summary: "Claude Code is starting on ...")
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .queued, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.currentActivitySummary, "Claude Code is starting on Adjust mobile spacing.")
    }

    func testBuild_checkpointReadySummary_isPreservedVerbatim() {
        // Bespoke "Checkpoint ready: ..." summary has no "..." so it passes through.
        let summary = "Checkpoint ready: Which green token should I use?"
        let batch = batchRecord(status: .waiting, summary: summary)
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .needsYou, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.currentActivitySummary, summary)
    }

    func testBuild_doneSummary_isPreservedVerbatim() {
        let summary = "Done: Adjusted mobile spacing."
        let batch = batchRecord(status: .idle, summary: summary)
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .done, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.currentActivitySummary, summary)
    }

    func testBuild_displayPriority_sortOrderAcrossMixedStatuses() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        // Build a mixed set; capture the resulting projection ID order.
        let batches: [WorkBatchRecord] = [
            batchRecord(id: "b-idle", name: "Idle batch", status: .idle, summary: "Done: x.", updatedAt: now.addingTimeInterval(500)),
            batchRecord(id: "b-ready", name: "Ready batch", status: .ready, summary: "Done: y.", updatedAt: now.addingTimeInterval(400)),
            batchRecord(id: "b-working", name: "Working batch", status: .working, summary: "Working.", updatedAt: now.addingTimeInterval(300)),
            batchRecord(id: "b-working-queued", name: "Working queued batch", status: .working, summary: "Working.", updatedAt: now.addingTimeInterval(200)),
            batchRecord(id: "b-waiting", name: "Waiting batch", status: .waiting, summary: "Checkpoint ready: q?", updatedAt: now.addingTimeInterval(100)),
            batchRecord(id: "b-compacting", name: "Compacting batch", status: .compacting, summary: "Compacting.", updatedAt: now.addingTimeInterval(50)),
        ]
        let tasks: [WorkBatchTaskRecord] = [
            task(id: "tq", title: "Queued task", status: .queued, createdAt: 0, batchID: "b-working-queued"),
            task(id: "tw", title: "Working task", status: .working, createdAt: 0, batchID: "b-working"),
        ]
        let projections = WorkBatchProjectionBuilder.build(
            state: WorkBatchStateSnapshot(version: 1, batches: batches, tasks: tasks, classifications: []),
            bindings: [],
        )
        // displayPriority: waiting(40) > working+queued(35) > working(30) > ready/compacting(20) > idle(0)
        // ready and compacting tie at 20, broken by updatedAt desc (b-ready newer than b-compacting).
        XCTAssertEqual(
            projections.map(\.id),
            ["b-waiting", "b-working-queued", "b-working", "b-ready", "b-compacting", "b-idle"],
        )
    }

    // =========================================================================
    // MARK: - Previously-uncovered parity paths (restored 3a behavior)

    // =========================================================================

    func testBuild_wakeFailedAttentionReason_projectsWakeNeedsAttention() {
        // 3a PARITY: the wake catch-with-nil-taskID path showed
        // "Claude Code wake needs attention." 3b folded it into .deliveryFailure
        // ("...delivery needs attention.") until the .wakeFailed variant was
        // restored. Pin the exact wake string and confirm it stays distinct
        // from the delivery-failure string. The routing path (autorouter wake
        // catch) is effectively unreachable end-to-end (a non-nil prompt
        // implies a queued task, which makes firstOpenTaskID non-nil), so we
        // pin the derivation mapping directly through build().
        let batch = batchRecord(status: .waiting, summary: "", attentionReason: .wakeFailed)
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .queued, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, "Claude Code wake needs attention.")
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testBuild_deliveryFailureAttentionReason_staysDistinctFromWake() {
        // Sibling guard: the genuine delivery-failure path must keep its own
        // string so .wakeFailed and .deliveryFailure never collapse again.
        let batch = batchRecord(status: .waiting, summary: "", attentionReason: .deliveryFailure)
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .queued, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.currentActivitySummary, "Claude Code delivery needs attention.")
    }

    func testBuild_completedBatch_recordedIsWorkingProse_isRederivedToDone() {
        // 3a PARITY (markDoneIfUseful + shouldReplaceSummaryAfterCompletion):
        // a completed/done batch whose recorded line CONTAINS "is working"
        // matched the old predicate and was replaced with the Done line. 3b's
        // setBatchStructure no longer rewrites the recorded line, so the
        // override must re-derive here. Recorded prose deliberately contains
        // "is working" (e.g. legacy "Claude Code is working in <wt>.").
        let batch = batchRecord(status: .ready, summary: "Claude Code is working in the worktree.")
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .done, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.status, .ready)
        XCTAssertEqual(projection.currentActivitySummary, "Done: Adjust mobile spacing.")
    }

    func testBuild_completedBatch_recordedWorkingOnProse_survivesUnchanged_pinsWart() {
        // 3a PARITY WART (pinned twice — see also the reconciler-driven sibling
        // testReconciler_doneBatch_liveAliveCockpit_workingOnProse_survivesAsReadySummary):
        // the old predicate tested contains("is working"), NOT contains("working"),
        // so a recorded "Working on <title>." did NOT match and survived onto a
        // Done/Ready batch. The override must NOT over-broaden to "Working on".
        let batch = batchRecord(status: .ready, summary: "Working on Adjust mobile spacing.")
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .done, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.status, .ready)
        XCTAssertEqual(projection.currentActivitySummary, "Working on Adjust mobile spacing.")
    }

    func testBuild_completedBatch_recordedNeedsReconnectProse_isRederivedToDone() {
        // 3a PARITY: "needs reconnect" is another token in
        // shouldReplaceSummaryAfterCompletion; a stale reconnect line on a
        // completed batch must re-derive to the Done line.
        let batch = batchRecord(status: .idle, summary: "Claude Code session needs reconnect.")
        let tasks = [task(id: "t1", title: "Adjust mobile spacing", status: .done, createdAt: 0)]
        let projection = buildSingle(batch: batch, tasks: tasks)
        XCTAssertEqual(projection.status, .idle)
        XCTAssertEqual(projection.currentActivitySummary, "Done: Adjust mobile spacing.")
    }

    func testReconciler_pendingCheckpoint_genuineAnsweredLine_isPreservedNotOverridden() {
        // 3a PARITY (markWaitingForUser + shouldReplaceSummaryForUserInput): a
        // genuine recorded line that does NOT match the replace set (here an
        // "Answered checkpoint for X..." continuation line) was PRESERVED — the
        // generic "Checkpoint needs your input." only substituted for the
        // matching set. 3b's checkpointReadySummary over-broadened until this
        // was restored. Drive the reconciler so the path matches production.
        let answeredLine = "Answered checkpoint for Add green border. Claude Code will continue."
        let result = reconcileWithCheckpoint(
            batchStatus: .working,
            summary: answeredLine,
            taskStatus: .needsYou,
            bindingStatus: .stale,
            sessions: [],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, answeredLine)
        XCTAssertEqual(projection.pendingCheckpoints.count, 1)
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testReconciler_pendingCheckpoint_launchingWithinGrace_replaceableSummary_projectsCheckpointNeedsInput() {
        // PIN (intentional broadening, finding 2 of the parity re-review): the
        // pending-checkpoint summary override now applies at PROJECTION time to
        // ANY pending-checkpoint batch, not only reconciler-touched ones. Here
        // the binding is launching-within-grace, so the reconciler keeps it
        // .launching and does NOT author the summary (markWaitingForUser never
        // runs). With a replaceable stored summary, the projection still surfaces
        // the generic "Checkpoint needs your input." This documents the broadening
        // as intentional and benign on the production path.
        let result = reconcileWithCheckpoint(
            batchStatus: .working,
            summary: "Claude Code session needs reconnect.",
            taskStatus: .needsYou,
            bindingStatus: .launching,
            // Inside launchGrace relative to `now` (1_775_000_200): keep the
            // binding launching so the reconciler leaves the batch untouched.
            bindingUpdatedAt: Date(timeIntervalSince1970: 1_775_000_190),
            sessions: [],
        )
        let projection = project(result)
        XCTAssertEqual(projection.currentActivitySummary, "Checkpoint needs your input.")
        XCTAssertEqual(projection.pendingCheckpoints.count, 1)
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testReconciler_pendingCheckpoint_staleBespokeForOtherQuestion_isPreserved() {
        // 3a PARITY: a stale bespoke "Checkpoint ready: OLD-Q" line whose
        // question does NOT match the current pending checkpoint did not match
        // shouldReplaceSummaryForUserInput, so it was preserved verbatim rather
        // than collapsed to the generic prompt.
        let stale = "Checkpoint ready: Should I delete the legacy file?"
        let result = reconcileWithCheckpoint(
            batchStatus: .waiting,
            summary: stale,
            taskStatus: .needsYou,
            bindingStatus: .stale,
            sessions: [],
        )
        let projection = project(result)
        XCTAssertEqual(projection.status, .waiting)
        XCTAssertEqual(projection.currentActivitySummary, stale)
        XCTAssertEqual(chipState(projection), .waiting)
    }

    func testBuild_migratedOldBatch_noAttentionReasonOnDisk_projectsSaneStatusAndSummary() throws {
        // A batch written before the T2 teardown has no `attention_reason` key.
        // Driving it through the real load() + build() path must (1) decode
        // attentionReason to .none and (2) produce a sane projection: here a
        // completed Idle batch whose stale recorded line contains "is working"
        // re-derives to the Done line, exactly as 3a's markDoneIfUseful would.
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fileManager.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("state.json")
        try """
        {
          "version": 1,
          "batches": [
            {
              "id": "batch-mobile",
              "name": "Mobile prototype",
              "project_path": "/tmp/project",
              "status": "idle",
              "current_activity_summary": "Claude Code is working in the worktree.",
              "task_ids": ["task-green"],
              "cockpit_binding_id": "batch-mobile",
              "created_at": "2026-05-01T00:00:00Z",
              "updated_at": "2026-05-01T00:00:00Z"
            }
          ],
          "tasks": [
            {
              "id": "task-green",
              "source_idea_id": "task-green",
              "title": "Add green border",
              "body": "",
              "status": "done",
              "batch_id": "batch-mobile",
              "created_at": "2026-05-01T00:00:00Z",
              "updated_at": "2026-05-01T00:00:00Z"
            }
          ],
          "classifications": []
        }
        """.write(to: storeURL, atomically: true, encoding: .utf8)

        let loaded = try WorkBatchStateStore(fileURL: storeURL, fileManager: fileManager).load()
        XCTAssertEqual(loaded.batches.first?.attentionReason, WorkBatchAttentionReason.none)

        let projections = WorkBatchProjectionBuilder.build(state: loaded, bindings: [])
        let projection = try XCTUnwrap(projections.first)
        XCTAssertEqual(projection.status, .idle)
        XCTAssertEqual(projection.currentActivitySummary, "Done: Add green border.")
        XCTAssertEqual(chipState(projection), .idle)
    }

    // =========================================================================
    // MARK: - Pure reconcile + project helpers

    // =========================================================================

    private let worktree = "/tmp/project/.capacitor/worktrees/batch-mobile"
    private let projectPath = "/tmp/project"

    private func reconcile(
        batchStatus: WorkBatchStatus,
        summary: String,
        taskStatus: WorkBatchTaskStatus,
        bindingStatus: WorkBatchCockpitBindingStatus,
        bindingUpdatedAt: Date = Date(timeIntervalSince1970: 1_775_000_000),
        sessions: [RuntimeSession],
    ) -> WorkBatchBindingReconciliationResult {
        WorkBatchBindingReconciler.reconcile(
            state: pureState(batchStatus: batchStatus, summary: summary, taskStatus: taskStatus, checkpointPending: false),
            bindings: [pureBinding(status: bindingStatus, updatedAt: bindingUpdatedAt)],
            sessions: sessions,
            now: Date(timeIntervalSince1970: 1_775_000_200),
        )
    }

    private func reconcileWithCheckpoint(
        batchStatus: WorkBatchStatus,
        summary: String,
        taskStatus: WorkBatchTaskStatus,
        bindingStatus: WorkBatchCockpitBindingStatus,
        bindingUpdatedAt: Date = Date(timeIntervalSince1970: 1_775_000_000),
        sessions: [RuntimeSession],
    ) -> WorkBatchBindingReconciliationResult {
        WorkBatchBindingReconciler.reconcile(
            state: pureState(batchStatus: batchStatus, summary: summary, taskStatus: taskStatus, checkpointPending: true),
            bindings: [pureBinding(status: bindingStatus, updatedAt: bindingUpdatedAt)],
            sessions: sessions,
            now: Date(timeIntervalSince1970: 1_775_000_200),
        )
    }

    private func project(_ result: WorkBatchBindingReconciliationResult) -> WorkBatchProjection {
        let projections = WorkBatchProjectionBuilder.build(state: result.state, bindings: result.bindings)
        return projections.first(where: { $0.id == "batch-mobile" }) ?? projections[0]
    }

    private func pureState(
        batchStatus: WorkBatchStatus,
        summary: String,
        taskStatus: WorkBatchTaskStatus,
        checkpointPending: Bool,
    ) -> WorkBatchStateSnapshot {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        return WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: projectPath,
                    status: batchStatus,
                    currentActivitySummary: summary,
                    taskIDs: ["task-green"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: taskStatus,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
            checkpoints: checkpointPending ? [
                WorkBatchCheckpointRecord(
                    id: "cp-1",
                    batchID: "batch-mobile",
                    taskID: "task-green",
                    question: "Which green token should I use?",
                    reason: "Multiple greens.",
                    recommendedAction: nil,
                    status: .pending,
                    requestedAt: now,
                    respondedAt: nil,
                    response: nil,
                    updatedAt: now,
                ),
            ] : [],
        )
    }

    private func pureBinding(
        status: WorkBatchCockpitBindingStatus,
        updatedAt: Date,
    ) -> WorkBatchCockpitBinding {
        WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: projectPath,
            worktreeName: "batch-mobile",
            worktreePath: worktree,
            host: .claudeCode,
            claudeSessionID: "session-batch",
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: updatedAt,
        )
    }

    private func session(
        id: String,
        cwd: String,
        state: String = "working",
        toolsInFlight: Int? = nil,
        gcReason: String? = nil,
        isAlive: Bool? = true,
        osProcessAlive: Bool? = nil,
    ) -> RuntimeSession {
        RuntimeSession(
            sessionId: id,
            pid: 1234,
            state: try! SessionState.decode(wire: state),
            cwd: cwd,
            projectId: nil,
            workspaceId: nil,
            projectPath: cwd,
            updatedAt: "2026-05-25T00:00:00Z",
            stateChangedAt: "2026-05-25T00:00:00Z",
            lastEvent: nil,
            lastActivityAt: nil,
            toolsInFlight: toolsInFlight,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
            gcReason: gcReason,
            isAlive: isAlive,
            osProcessAlive: osProcessAlive,
        )
    }

    // MARK: - Build helpers

    private func batchRecord(
        id: String = "batch-mobile",
        name: String = "Mobile prototype",
        status: WorkBatchStatus,
        summary: String,
        attentionReason: WorkBatchAttentionReason = .none,
        updatedAt: Date = Date(timeIntervalSince1970: 1_775_000_000),
    ) -> WorkBatchRecord {
        WorkBatchRecord(
            id: id,
            name: name,
            projectPath: projectPath,
            status: status,
            currentActivitySummary: summary,
            taskIDs: [],
            cockpitBindingID: nil,
            attentionReason: attentionReason,
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: updatedAt,
        )
    }

    private func task(
        id: String,
        title: String,
        status: WorkBatchTaskStatus,
        createdAt offset: TimeInterval,
        batchID: String = "batch-mobile",
    ) -> WorkBatchTaskRecord {
        let base = Date(timeIntervalSince1970: 1_775_000_000)
        return WorkBatchTaskRecord(
            id: id,
            sourceIdeaID: id,
            title: title,
            body: "",
            status: status,
            batchID: batchID,
            createdAt: base.addingTimeInterval(offset),
            updatedAt: base.addingTimeInterval(offset),
        )
    }

    private func buildSingle(batch: WorkBatchRecord, tasks: [WorkBatchTaskRecord]) -> WorkBatchProjection {
        WorkBatchProjectionBuilder.build(
            state: WorkBatchStateSnapshot(version: 1, batches: [batch], tasks: tasks, classifications: []),
            bindings: [],
        )[0]
    }
}

// MARK: - Router harness

@MainActor
private final class Harness {
    let fileManager = FileManager.default
    let tempDir: URL
    let projectRoot: URL
    let stateStore: WorkBatchStateStore
    let bindingStore: WorkBatchCockpitBindingStore
    let now = Date(timeIntervalSince1970: 1_775_000_000)

    var mobileWorktreePath: String {
        projectRoot.appendingPathComponent(".capacitor/worktrees/batch-mobile", isDirectory: true).path
    }

    var project: Project {
        Project(
            name: "Arc Design Studio",
            path: projectRoot.path,
            workspaceId: WorkspaceIdentity.fromPath(projectRoot.path),
            displayPath: projectRoot.path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    init() throws {
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        stateStore = WorkBatchStateStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            fileManager: fileManager,
        )
        bindingStore = WorkBatchCockpitBindingStore(
            fileURL: tempDir.appendingPathComponent("bindings.json"),
            fileManager: fileManager,
        )
    }

    deinit {
        try? fileManager.removeItem(at: tempDir)
    }

    func idea(id: String, title: String, description: String? = nil) -> Idea {
        Idea(
            id: id,
            title: title,
            description: description ?? title,
            added: "2026-05-24T00:00:00Z",
            effort: "small",
            status: "open",
            triage: "pending",
            related: nil,
        )
    }

    func router(
        classifier: @escaping WorkBatchAutoRouter.Classifier,
        coordinator: WorkBatchTaskSessionCoordinator,
        safeWakeBoundaryAllowsInput: ((WorkBatchCockpitBinding) -> Bool)? = nil,
    ) -> WorkBatchAutoRouter {
        WorkBatchAutoRouter(
            classifier: classifier,
            stateStoreFactory: { [stateStore] _ in stateStore },
            bindingStoreFactory: { [bindingStore] _ in bindingStore },
            taskSessionCoordinator: coordinator,
            safeWakeBoundaryAllowsInput: safeWakeBoundaryAllowsInput,
        )
    }

    /// Projects through the SAME path the UI reads (`router.projections(for:)`).
    func projection(router: WorkBatchAutoRouter, batchID: String) -> WorkBatchProjection {
        let projections = router.projections(for: project.path)
        return projections.first(where: { $0.id == batchID }) ?? projections[0]
    }

    // MARK: classifiers

    func newBatchClassifier(name: String) -> WorkBatchAutoRouter.Classifier {
        { [now] request in
            .new(
                taskID: request.task.id,
                batchName: name,
                confidence: 0.9,
                rationale: "New batch.",
                summary: "Started \(name).",
                createdAt: now,
            )
        }
    }

    func existingClassifier(batchID: String) -> WorkBatchAutoRouter.Classifier {
        { [now] request in
            .existing(
                taskID: request.task.id,
                batchID: batchID,
                confidence: 0.88,
                rationale: "Same area.",
                summary: "Added.",
                createdAt: now,
            )
        }
    }

    func throwingClassifier() -> WorkBatchAutoRouter.Classifier {
        { _ in throw NSError(domain: "test", code: 1) }
    }

    // MARK: coordinators

    func launchingCoordinator(expectedName _: String, sessionID: String) -> WorkBatchTaskSessionCoordinator {
        WorkBatchTaskSessionCoordinator(
            worktreeService: acceptingWorktreeService(),
            fileManager: fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            sessionIDGenerator: { sessionID },
            runTerminalScript: { _ in },
            bindingStoreFactory: { [bindingStore] _ in bindingStore },
        )
    }

    func failingCoordinator(expectedName _: String, error: Error) -> WorkBatchTaskSessionCoordinator {
        WorkBatchTaskSessionCoordinator(
            worktreeService: acceptingWorktreeService(),
            fileManager: fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { _ in throw error },
            bindingStoreFactory: { [bindingStore] _ in bindingStore },
        )
    }

    func noLaunchCoordinator() -> WorkBatchTaskSessionCoordinator {
        WorkBatchTaskSessionCoordinator(
            worktreeService: worktreeService(expectedName: "should-not-launch"),
            fileManager: fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { _ in },
            bindingStoreFactory: { [bindingStore] _ in bindingStore },
        )
    }

    func recordingCoordinator(expectedName: String) -> WorkBatchTaskSessionCoordinator {
        WorkBatchTaskSessionCoordinator(
            worktreeService: worktreeService(expectedName: expectedName),
            fileManager: fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { _ in },
            bindingStoreFactory: { [bindingStore] _ in bindingStore },
        )
    }

    func wakingCoordinator(expectedName: String) -> WorkBatchTaskSessionCoordinator {
        WorkBatchTaskSessionCoordinator(
            worktreeService: worktreeService(expectedName: expectedName),
            fileManager: fileManager,
            claudePathResolver: { "/opt/homebrew/bin/claude" },
            runTerminalScript: { _ in },
            wakeExistingTerminal: { _, _, _ in true },
            bindingStoreFactory: { [bindingStore] _ in bindingStore },
        )
    }

    func worktreeService(expectedName: String) -> WorktreeService {
        WorktreeService(fileManager: fileManager) { [projectRoot, fileManager] arguments, cwd in
            guard arguments == [
                "worktree",
                "add",
                ".capacitor/worktrees/\(expectedName)",
                "-b",
                "pkp/\(expectedName)",
            ], cwd == projectRoot.path else {
                return .init(exitCode: 1, stdout: "", stderr: "unexpected git command")
            }
            let url = projectRoot.appendingPathComponent(".capacitor/worktrees/\(expectedName)", isDirectory: true)
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func acceptingWorktreeService() -> WorktreeService {
        WorktreeService(fileManager: fileManager) { [projectRoot, fileManager] arguments, cwd in
            guard arguments.count == 5,
                  arguments[0] == "worktree",
                  arguments[1] == "add",
                  arguments[2].hasPrefix(".capacitor/worktrees/"),
                  arguments[3] == "-b",
                  arguments[4].hasPrefix("pkp/"),
                  cwd == projectRoot.path
            else {
                return .init(exitCode: 1, stdout: "", stderr: "unexpected git command")
            }
            let relativePath = arguments[2]
            let url = projectRoot.appendingPathComponent(relativePath, isDirectory: true)
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func seedMobileBatch(
        status: WorkBatchStatus,
        bindingStatus: WorkBatchCockpitBindingStatus,
        taskStatus: WorkBatchTaskStatus = .working,
        deliveryRecords: [WorkBatchDeliveryRecord] = [],
    ) throws {
        try stateStore.save(WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: project.path,
                    status: status,
                    currentActivitySummary: "Tweaking prototype styling.",
                    taskIDs: ["idea-old"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "idea-old",
                    sourceIdeaID: "idea-old",
                    title: "Adjust mobile spacing",
                    body: "",
                    status: taskStatus,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
            deliveryRecords: deliveryRecords,
        ))
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: mobileWorktreePath, isDirectory: true),
            withIntermediateDirectories: true,
        )
        try bindingStore.upsert(WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: project.path,
            worktreeName: "batch-mobile",
            worktreePath: mobileWorktreePath,
            host: .claudeCode,
            claudeSessionID: "assigned-session-existing",
            status: bindingStatus,
            createdAt: now,
            updatedAt: now,
        ))
    }

    func session(
        id: String,
        cwd: String,
        state: String = "working",
        toolsInFlight: Int? = nil,
        gcReason: String? = nil,
        isAlive: Bool? = true,
        osProcessAlive: Bool? = nil,
    ) -> RuntimeSession {
        RuntimeSession(
            sessionId: id,
            pid: 1234,
            state: try! SessionState.decode(wire: state),
            cwd: cwd,
            projectId: nil,
            workspaceId: nil,
            projectPath: cwd,
            updatedAt: "2026-05-25T00:00:00Z",
            stateChangedAt: "2026-05-25T00:00:00Z",
            lastEvent: nil,
            lastActivityAt: nil,
            toolsInFlight: toolsInFlight,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
            gcReason: gcReason,
            isAlive: isAlive,
            osProcessAlive: osProcessAlive,
        )
    }
}
