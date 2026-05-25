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
            let otherSessionIDs = liveSessionsInWorktree
                .map(\.sessionId)
                .filter { $0 != binding.claudeSessionID }
                .sorted()

            if !otherSessionIDs.isEmpty {
                if updatedBinding.status != .waiting {
                    updatedBinding.status = .waiting
                    updatedBinding.updatedAt = now
                }
                markBatch(
                    binding.batchID,
                    in: &updatedState,
                    status: .waiting,
                    summary: "Multiple Claude Code sessions match this Work Batch.",
                    queueUnfinishedTasks: true,
                    now: now,
                )
                issues.append(WorkBatchBindingReconciliationIssue(
                    kind: .duplicateCockpit,
                    batchID: binding.batchID,
                    sessionIDs: ([binding.claudeSessionID] + otherSessionIDs).sorted(),
                    message: "Multiple Claude Code sessions are active in the Batch Worktree.",
                ))
            } else if !exactSessions.isEmpty {
                if batchNeedsUser(binding.batchID, in: updatedState) {
                    if updatedBinding.status != .waiting {
                        updatedBinding.status = .waiting
                        updatedBinding.updatedAt = now
                    }
                    markWaitingForUser(binding.batchID, in: &updatedState, now: now)
                    updatedBindings.append(updatedBinding)
                    continue
                }

                // New Work Batch Done behavior: a still-open Claude Code terminal
                // should not make a completed batch look active again.
                if updatedBinding.status == .done,
                   batchHasNoOpenTasks(binding.batchID, in: updatedState)
                {
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
                if batchNeedsUser(binding.batchID, in: updatedState) {
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
        if session.gcReason != nil {
            return false
        }
        return session.isAlive ?? true
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
            state.batches[index].currentActivitySummary = "Claude Code is working in \(state.batches[index].name)."
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
            normalized.contains("needs reconnect") ||
            normalized.contains("needs attention") ||
            normalized.contains("multiple claude code sessions")
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
