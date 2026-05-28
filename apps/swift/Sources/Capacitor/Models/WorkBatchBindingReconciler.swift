import Foundation

struct WorkBatchBindingReconciliationIssue: Equatable {
    enum Kind: Equatable {
        case duplicateCockpit
        case missingCockpit
    }

    let kind: Kind
    let batchID: String
    let sessionIDs: [String]
    let message: String
}

struct WorkBatchBindingReconciliationResult: Equatable {
    let state: WorkBatchStateSnapshot
    let bindings: [WorkBatchCockpitBinding]
    let issues: [WorkBatchBindingReconciliationIssue]
}

enum WorkBatchBindingReconciler {
    typealias ProcessSessionLookup = (WorkBatchCockpitBinding) -> [String]

    static let defaultLaunchGrace: TimeInterval = 90

    static func reconcile(
        state: WorkBatchStateSnapshot,
        bindings: [WorkBatchCockpitBinding],
        sessions: [RuntimeSession],
        now: Date,
        launchGrace: TimeInterval = defaultLaunchGrace,
        processSessionIDs: ProcessSessionLookup = { _ in [] },
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
            let processSessionIDs = processSessionIDs(binding)
            let processExactCount = processSessionIDs.count(where: { $0 == binding.claudeSessionID })
            let processOtherSessionIDs = processSessionIDs.filter { $0 != binding.claudeSessionID }
            let otherSessionIDs = Set(runtimeOtherSessionIDs + processOtherSessionIDs).sorted()
            let hasDuplicateExactProcess = processExactCount > 1
            let hasDuplicateCockpit = !otherSessionIDs.isEmpty || hasDuplicateExactProcess
            let exactCockpitActivity = exactCockpitActivity(
                exactSessions: exactSessions,
                processExactCount: processExactCount,
            )
            let hasExactSession = exactCockpitActivity != .absent
            let needsUser = batchNeedsUser(binding.batchID, in: updatedState)

            func recordDuplicateIssue() {
                issues.append(WorkBatchBindingReconciliationIssue(
                    kind: .duplicateCockpit,
                    batchID: binding.batchID,
                    sessionIDs: duplicateIssueSessionIDs(
                        bindingSessionID: binding.claudeSessionID,
                        otherSessionIDs: otherSessionIDs,
                        hasDuplicateExactProcess: hasDuplicateExactProcess,
                    ),
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
                    summary: duplicateCockpitSummary(
                        hasForeignDuplicate: !otherSessionIDs.isEmpty,
                        hasDuplicateExactProcess: hasDuplicateExactProcess,
                    ),
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
                        summary: "Claude Code session needs reconnect.",
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
        processExactCount: Int,
    ) -> ExactCockpitActivity {
        if exactSessions.contains(where: sessionIsActivelyWorking) {
            return .working
        }
        if !exactSessions.isEmpty || processExactCount > 0 {
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

    private static func duplicateIssueSessionIDs(
        bindingSessionID: String,
        otherSessionIDs: [String],
        hasDuplicateExactProcess: Bool,
    ) -> [String] {
        var sessionIDs = Set(otherSessionIDs)
        sessionIDs.insert(bindingSessionID)
        if hasDuplicateExactProcess {
            sessionIDs.insert("\(bindingSessionID) (duplicate process)")
        }
        return sessionIDs.sorted()
    }

    private static func duplicateCockpitSummary(
        hasForeignDuplicate: Bool,
        hasDuplicateExactProcess: Bool,
    ) -> String {
        if hasDuplicateExactProcess, !hasForeignDuplicate {
            return "Claude Code is already open; click to re-enter."
        }
        return "Multiple Claude Code sessions match this Work Batch."
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

    private static func markRunningIfUseful(
        _ batchID: String,
        in state: inout WorkBatchStateSnapshot,
        now: Date,
    ) {
        guard let index = state.batches.firstIndex(where: { $0.id == batchID }) else { return }
        let tasks = state.tasks.filter { $0.batchID == batchID }
        guard tasks.contains(where: { $0.status != .done }) else {
            return
        }

        var changed = false
        if state.batches[index].status != .working {
            state.batches[index].status = .working
            changed = true
        }
        if shouldReplaceSummaryAfterRecovery(state.batches[index].currentActivitySummary) {
            state.batches[index].currentActivitySummary = runningSummary(for: tasks)
            changed = true
        }
        if changed {
            state.batches[index].updatedAt = now
        }
    }

    private static func markActiveCockpitIfUseful(
        _ batchID: String,
        in state: inout WorkBatchStateSnapshot,
        now: Date,
    ) {
        guard let index = state.batches.firstIndex(where: { $0.id == batchID }) else { return }
        var changed = false
        if state.batches[index].status != .working {
            state.batches[index].status = .working
            changed = true
        }
        if shouldReplaceSummaryForActiveCockpit(state.batches[index].currentActivitySummary) {
            state.batches[index].currentActivitySummary = "Checking final result."
            changed = true
        }
        if changed {
            state.batches[index].updatedAt = now
        }
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
        guard let index = state.batches.firstIndex(where: { $0.id == batchID }) else { return }
        let targetStatus: WorkBatchStatus = liveAssignedCockpitIsPresent ? .ready : .idle
        var changed = false
        // New Work Batch status rule: completed work with a live assigned cockpit stays Ready
        // so the user can see that Claude is still open and awaiting direction.
        if state.batches[index].status != targetStatus {
            state.batches[index].status = targetStatus
            changed = true
        }
        let summary = state.batches[index].currentActivitySummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldReplaceSummaryAfterCompletion(summary) {
            state.batches[index].currentActivitySummary = completionSummary(
                for: state.tasks.filter { $0.batchID == batchID },
            )
            changed = true
        }
        if changed {
            state.batches[index].updatedAt = now
        }
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
        guard let index = state.batches.firstIndex(where: { $0.id == batchID }) else { return }
        var changed = false
        if state.batches[index].status != .waiting {
            state.batches[index].status = .waiting
            changed = true
        }
        let summary = state.batches[index].currentActivitySummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldReplaceSummaryForUserInput(summary) {
            state.batches[index].currentActivitySummary = "Checkpoint needs your input."
            changed = true
        }
        if changed {
            state.batches[index].updatedAt = now
        }
    }

    private static func shouldReplaceSummaryForUserInput(_ summary: String) -> Bool {
        let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ||
            normalized.contains("is working") ||
            normalized.contains("is reconnecting") ||
            normalized.contains("needs reconnect") ||
            normalized.contains("needs attention") ||
            normalized.contains("multiple claude code sessions")
    }

    private static func shouldReplaceSummaryAfterRecovery(_ summary: String) -> Bool {
        let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ||
            normalized.contains("is working in") ||
            normalized.contains("needs reconnect") ||
            normalized.contains("needs attention") ||
            normalized.contains("multiple claude code sessions")
    }

    private static func shouldReplaceSummaryAfterCompletion(_ summary: String) -> Bool {
        let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ||
            normalized == "done: all tasks completed." ||
            normalized == "all tasks done." ||
            normalized.contains("is working") ||
            normalized.contains("needs reconnect") ||
            normalized.contains("needs attention") ||
            normalized.contains("multiple claude code sessions")
    }

    private static func shouldReplaceSummaryForActiveCockpit(_ summary: String) -> Bool {
        let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ||
            normalized.hasPrefix("done:") ||
            normalized.contains("is working in") ||
            normalized.contains("needs reconnect") ||
            normalized.contains("needs attention") ||
            normalized.contains("multiple claude code sessions")
    }

    private static func runningSummary(for tasks: [WorkBatchTaskRecord]) -> String {
        let activeTask = tasks.last { task in
            task.status == .working || task.status == .queued
        } ?? tasks.last { $0.status != .done }

        guard let activeTask else {
            return "Working on next step."
        }
        return "Working on \(activeTask.displayTitle)."
    }

    private static func completionSummary(for tasks: [WorkBatchTaskRecord]) -> String {
        let completedTask = tasks
            .filter { $0.status == .done }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.createdAt > $1.createdAt
            }
            .first

        guard let completedTask else {
            return "Done."
        }
        return doneSummary(taskTitle: completedTask.displayTitle)
    }

    private static func doneSummary(taskTitle: String) -> String {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Done." }
        if let last = title.last,
           [".", "!", "?"].contains(last)
        {
            return "Done: \(title)"
        }
        return "Done: \(title)."
    }

    private static func markBatch(
        _ batchID: String,
        in state: inout WorkBatchStateSnapshot,
        status: WorkBatchStatus,
        summary: String,
        queueUnfinishedTasks: Bool = false,
        now: Date,
    ) {
        guard let index = state.batches.firstIndex(where: { $0.id == batchID }) else { return }
        var changed = false
        if state.batches[index].status != status {
            state.batches[index].status = status
            changed = true
        }
        if state.batches[index].currentActivitySummary != summary {
            state.batches[index].currentActivitySummary = summary
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
}
