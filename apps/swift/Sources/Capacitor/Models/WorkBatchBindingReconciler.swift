import Foundation

struct WorkBatchBindingReconciliationIssue: Equatable {
    enum Kind: Equatable {
        case duplicateCockpit
        case missingCockpit
    }

    let kind: Kind
    let batchID: String
    /// Distinct FOREIGN Claude session ids observed live in the Batch Worktree
    /// (the assigned cockpit id plus any others). Two or more distinct ids here
    /// means an ambiguous duplicate cockpit that must block re-entry.
    ///
    /// NOTE: same-session OS-process duplicate detection was RETIRED in C5. The
    /// runtime tracks exactly one PID per session id, so a same-session
    /// duplicate count could never be derived from snapshot facts (it would
    /// have been an exact alias for `osProcessAlive ? 1 : 0`). Foreign-session
    /// duplicate detection (via `sessionIDs`) and process-backed liveness (via
    /// `osProcessAlive`) are unaffected.
    let sessionIDs: [String]
    let message: String
}

struct WorkBatchBindingReconciliationResult: Equatable {
    let state: WorkBatchStateSnapshot
    let bindings: [WorkBatchCockpitBinding]
    let issues: [WorkBatchBindingReconciliationIssue]
}

enum WorkBatchBindingReconciler {
    static let defaultLaunchGrace: TimeInterval = 90

    static func reconcile(
        state: WorkBatchStateSnapshot,
        bindings: [WorkBatchCockpitBinding],
        sessions: [RuntimeSession],
        now: Date,
        launchGrace: TimeInterval = defaultLaunchGrace,
    ) -> WorkBatchBindingReconciliationResult {
        var updatedState = state
        var updatedBindings: [WorkBatchCockpitBinding] = []
        var issues: [WorkBatchBindingReconciliationIssue] = []

        for binding in bindings {
            var updatedBinding = binding
            let liveSessionsInWorktree = sessions
                .filter(isLiveSession)
                .filter { sessionIsInsideBatchWorktree($0, worktreePath: binding.worktreePath) }
            let exactSessions = liveSessionsInWorktree.filter { $0.sessionId == binding.claudeSessionID }
            let runtimeOtherSessionIDs = liveSessionsInWorktree
                .map(\.sessionId)
                .filter { $0 != binding.claudeSessionID }
            // OS-liveness facts (DISTINCT from event-decay `isAlive`) supplied by
            // the hud-hook sweep on each `RuntimeSession`. These replaced the
            // former `/bin/ps` + `/usr/sbin/lsof` process scan: process-backed
            // liveness of the exact assigned cockpit is `osProcessAlive == true`
            // even when transcript signals decayed.
            //
            // Same-session OS-process duplicate detection was RETIRED in C5: the
            // runtime keys sessions by id with one PID each, so a same-session
            // duplicate can never be derived from snapshot facts. Only FOREIGN
            // session ids in the worktree mark an ambiguous duplicate cockpit.
            let exactProcessSessions = sessions.filter { session in
                session.sessionId == binding.claudeSessionID &&
                    sessionIsInsideBatchWorktree(session, worktreePath: binding.worktreePath)
            }
            let hasProcessBackedExactCockpit = exactProcessSessions
                .contains { $0.osProcessAlive == true }
            let otherSessionIDs = Set(runtimeOtherSessionIDs).sorted()
            let hasDuplicateCockpit = !otherSessionIDs.isEmpty
            let exactCockpitActivity = exactCockpitActivity(
                exactSessions: exactSessions,
                hasProcessBackedExactCockpit: hasProcessBackedExactCockpit,
            )
            let hasExactSession = exactCockpitActivity != .absent
            let needsUser = batchNeedsUser(binding.batchID, in: updatedState)

            func recordDuplicateIssue() {
                var sessionIDs = Set(otherSessionIDs)
                sessionIDs.insert(binding.claudeSessionID)
                issues.append(WorkBatchBindingReconciliationIssue(
                    kind: .duplicateCockpit,
                    batchID: binding.batchID,
                    sessionIDs: sessionIDs.sorted(),
                    message: "Multiple Claude Code sessions are active in the Batch Worktree.",
                ))
            }

            if needsUser, hasDuplicateCockpit {
                if updatedBinding.status != .waiting {
                    updatedBinding.status = .waiting
                    updatedBinding.updatedAt = now
                }
                // New Work Batch checkpoint behavior: the user's pending
                // decision stays visible even if duplicate cockpits also exist.
                markWaitingForUser(binding.batchID, in: &updatedState, now: now)
                recordDuplicateIssue()
                updatedBindings.append(updatedBinding)
                continue
            }

            // New Work Batch Done behavior: old/duplicate Claude Code cockpits
            // should not pull a completed batch back into Needs You. Still
            // record duplicate evidence so a click does not silently focus the
            // wrong cockpit.
            if batchHasNoOpenTasks(binding.batchID, in: updatedState), !needsUser {
                if hasDuplicateCockpit {
                    recordDuplicateIssue()
                }

                if exactCockpitActivity == .working, !hasDuplicateCockpit {
                    if updatedBinding.status != .running {
                        updatedBinding.status = .running
                        updatedBinding.updatedAt = now
                    }
                    markActiveCockpitIfUseful(binding.batchID, in: &updatedState, now: now)
                } else {
                    if updatedBinding.status != .done {
                        updatedBinding.status = .done
                        updatedBinding.updatedAt = now
                    }
                    markDoneIfUseful(
                        binding.batchID,
                        in: &updatedState,
                        liveAssignedCockpitIsPresent: exactCockpitActivity != .absent,
                        now: now,
                    )
                }
                updatedBindings.append(updatedBinding)
                continue
            }

            if hasDuplicateCockpit {
                if updatedBinding.status != .waiting {
                    updatedBinding.status = .waiting
                    updatedBinding.updatedAt = now
                }
                markBatch(
                    binding.batchID,
                    in: &updatedState,
                    status: .waiting,
                    // Same-session process duplicates were RETIRED in C5, so a
                    // duplicateCockpit can now only be a FOREIGN-session
                    // duplicate (ambiguous).
                    attentionReason: .duplicateCockpit,
                    queueUnfinishedTasks: true,
                    now: now,
                )
                recordDuplicateIssue()
            } else if hasExactSession {
                if needsUser {
                    if updatedBinding.status != .waiting {
                        updatedBinding.status = .waiting
                        updatedBinding.updatedAt = now
                    }
                    markWaitingForUser(binding.batchID, in: &updatedState, now: now)
                    updatedBindings.append(updatedBinding)
                    continue
                }

                if updatedBinding.status != .running {
                    updatedBinding.status = .running
                    updatedBinding.updatedAt = now
                }
                markRunningIfUseful(binding.batchID, in: &updatedState, now: now)
            } else if shouldRemainLaunching(binding, now: now, launchGrace: launchGrace) {
                updatedBinding.status = .launching
            } else if binding.status != .done {
                if updatedBinding.status != .stale {
                    updatedBinding.status = .stale
                    updatedBinding.updatedAt = now
                }
                if needsUser {
                    markWaitingForUser(binding.batchID, in: &updatedState, now: now)
                } else {
                    markBatch(
                        binding.batchID,
                        in: &updatedState,
                        status: .waiting,
                        attentionReason: .needsReconnect,
                        queueUnfinishedTasks: true,
                        now: now,
                    )
                }
                issues.append(WorkBatchBindingReconciliationIssue(
                    kind: .missingCockpit,
                    batchID: binding.batchID,
                    sessionIDs: [binding.claudeSessionID],
                    message: "No live Claude Code session matched the Batch Cockpit Binding.",
                ))
            }

            updatedBindings.append(updatedBinding)
        }

        return WorkBatchBindingReconciliationResult(
            state: updatedState,
            bindings: updatedBindings,
            issues: issues,
        )
    }

    private static func isLiveSession(_ session: RuntimeSession) -> Bool {
        guard session.isAlive ?? true else {
            return false
        }

        guard let gcReason = session.gcReason else {
            return true
        }

        // New Work Batch cockpit behavior: a bound Claude Code session can
        // age out of transcript signals while still being a valid, visible
        // cockpit. Only treat that snapshot as live when it is safely idle.
        return gcReason == "signal_absence" &&
            session.state == .ready &&
            session.toolsInFlight == 0
    }

    private enum ExactCockpitActivity {
        case absent
        case readyForInput
        case working
    }

    private static func exactCockpitActivity(
        exactSessions: [RuntimeSession],
        hasProcessBackedExactCockpit: Bool,
    ) -> ExactCockpitActivity {
        if exactSessions.contains(where: sessionIsActivelyWorking) {
            return .working
        }
        if !exactSessions.isEmpty || hasProcessBackedExactCockpit {
            return .readyForInput
        }
        return .absent
    }

    private static func sessionIsActivelyWorking(_ session: RuntimeSession) -> Bool {
        if (session.toolsInFlight ?? 0) > 0 {
            return true
        }

        switch session.state {
        case .working, .compacting, .waiting:
            return true
        case .ready, .idle:
            return false
        }
    }

    private static func shouldRemainLaunching(
        _ binding: WorkBatchCockpitBinding,
        now: Date,
        launchGrace: TimeInterval,
    ) -> Bool {
        guard binding.status == .launching else { return false }
        return now.timeIntervalSince(binding.updatedAt) < launchGrace
    }

    private static func sessionIsInsideBatchWorktree(
        _ session: RuntimeSession,
        worktreePath: String,
    ) -> Bool {
        pathIsInside(session.cwd, root: worktreePath) ||
            pathIsInside(session.projectPath, root: worktreePath)
    }

    private static func pathIsInside(_ path: String, root: String) -> Bool {
        let normalizedPath = PathNormalizer.normalize(path)
        let normalizedRoot = PathNormalizer.normalize(root)
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    // The reconciler now records only STRUCTURAL facts (status + attentionReason
    // + Task status) and never authors presentation prose. The displayed
    // (status, summary) is recomputed by
    // `WorkBatchProjectionBuilder.deriveBatchPresentation` from those facts.
    // Each setter clears any prior `attentionReason` so a recovered batch does
    // not keep showing a stale attention string.

    private static func markRunningIfUseful(
        _ batchID: String,
        in state: inout WorkBatchStateSnapshot,
        now: Date,
    ) {
        guard state.batches.contains(where: { $0.id == batchID }) else { return }
        let tasks = state.tasks.filter { $0.batchID == batchID }
        guard tasks.contains(where: { $0.status != .done }) else {
            return
        }
        setBatchStructure(batchID, in: &state, status: .working, attentionReason: .none, now: now)
    }

    private static func markActiveCockpitIfUseful(
        _ batchID: String,
        in state: inout WorkBatchStateSnapshot,
        now: Date,
    ) {
        setBatchStructure(batchID, in: &state, status: .working, attentionReason: .none, now: now)
    }

    private static func batchHasNoOpenTasks(
        _ batchID: String,
        in state: WorkBatchStateSnapshot,
    ) -> Bool {
        let tasks = state.tasks.filter { $0.batchID == batchID }
        return !tasks.isEmpty && tasks.allSatisfy { $0.status == .done }
    }

    private static func markDoneIfUseful(
        _ batchID: String,
        in state: inout WorkBatchStateSnapshot,
        liveAssignedCockpitIsPresent: Bool,
        now: Date,
    ) {
        // New Work Batch status rule: completed work with a live assigned cockpit
        // stays Ready so the user can see Claude is still open and awaiting
        // direction; otherwise it goes Idle.
        let targetStatus: WorkBatchStatus = liveAssignedCockpitIsPresent ? .ready : .idle
        setBatchStructure(batchID, in: &state, status: targetStatus, attentionReason: .none, now: now)
    }

    private static func batchNeedsUser(
        _ batchID: String,
        in state: WorkBatchStateSnapshot,
    ) -> Bool {
        state.tasks.contains { $0.batchID == batchID && $0.status == .needsYou } ||
            state.checkpoints.contains { $0.batchID == batchID && $0.status == .pending }
    }

    private static func markWaitingForUser(
        _ batchID: String,
        in state: inout WorkBatchStateSnapshot,
        now: Date,
    ) {
        // A pending checkpoint speaks for the batch in the projection, so the
        // reconciler only needs to record the waiting status and clear any
        // attention reason; the checkpoint question drives the summary.
        setBatchStructure(batchID, in: &state, status: .waiting, attentionReason: .none, now: now)
    }

    /// Sets the structural status + attention reason for a batch and clears the
    /// recorded activity line when an attention reason is present (the attention
    /// string is derived from the reason, not from prose). Optionally requeues
    /// unfinished Tasks.
    private static func markBatch(
        _ batchID: String,
        in state: inout WorkBatchStateSnapshot,
        status: WorkBatchStatus,
        attentionReason: WorkBatchAttentionReason,
        queueUnfinishedTasks: Bool = false,
        now: Date,
    ) {
        guard let index = state.batches.firstIndex(where: { $0.id == batchID }) else { return }
        var changed = false
        if state.batches[index].status != status {
            state.batches[index].status = status
            changed = true
        }
        if state.batches[index].attentionReason != attentionReason {
            state.batches[index].attentionReason = attentionReason
            changed = true
        }

        if queueUnfinishedTasks {
            for taskIndex in state.tasks.indices where state.tasks[taskIndex].batchID == batchID {
                guard state.tasks[taskIndex].status != .done,
                      state.tasks[taskIndex].status != .needsYou
                else { continue }
                if state.tasks[taskIndex].status != .queued {
                    state.tasks[taskIndex].status = .queued
                    state.tasks[taskIndex].updatedAt = now
                    changed = true
                }
            }
        }

        if changed {
            state.batches[index].updatedAt = now
        }
    }

    private static func setBatchStructure(
        _ batchID: String,
        in state: inout WorkBatchStateSnapshot,
        status: WorkBatchStatus,
        attentionReason: WorkBatchAttentionReason,
        now: Date,
    ) {
        guard let index = state.batches.firstIndex(where: { $0.id == batchID }) else { return }
        var changed = false
        if state.batches[index].status != status {
            state.batches[index].status = status
            changed = true
        }
        if state.batches[index].attentionReason != attentionReason {
            state.batches[index].attentionReason = attentionReason
            changed = true
        }
        if changed {
            state.batches[index].updatedAt = now
        }
    }
}
