import Foundation

extension AppState {
    @discardableResult
    func beginReceiptLoopRun(
        for idea: Idea,
        project: Project,
        runID: String = UUID().uuidString.lowercased(),
        at timestamp: String = currentISO8601Timestamp(),
    ) -> ReceiptLoopRunStart {
        if let existing = runningReceiptLoopRun() {
            return ReceiptLoopRunStart(state: existing, didStart: false)
        }

        return ReceiptLoopRunStart(
            state: recordReceiptLoopStarted(
                for: idea,
                project: project,
                runID: runID,
                at: timestamp,
            ),
            didStart: true,
        )
    }

    @discardableResult
    func recordReceiptLoopStarted(
        for idea: Idea,
        project: Project,
        runID: String = UUID().uuidString.lowercased(),
        at timestamp: String = currentISO8601Timestamp(),
    ) -> ReceiptLoopRunState {
        let state = ReceiptLoopRunState(
            id: runID,
            projectPath: project.path,
            ideaId: idea.id,
            ideaTitle: IdeaRunIntent.project(idea).intent,
            status: .running,
            createdAt: timestamp,
            updatedAt: timestamp,
        )
        receiptLoopRunsByProjectPath[normalizedReceiptLoopProjectPath(project.path)] = state
        return state
    }

    func recordReceiptLoopCompleted(
        project: Project,
        runID: String,
        at timestamp: String = currentISO8601Timestamp(),
    ) {
        updateReceiptLoopRun(
            project: project,
            runID: runID,
            status: .completed,
            failureReason: nil,
            at: timestamp,
        )
    }

    func recordReceiptLoopFailed(
        project: Project,
        runID: String,
        reason: String,
        at timestamp: String = currentISO8601Timestamp(),
    ) {
        updateReceiptLoopRun(
            project: project,
            runID: runID,
            status: .failed,
            failureReason: reason,
            at: timestamp,
        )
    }

    func receiptLoopRun(for project: Project) -> ReceiptLoopRunState? {
        receiptLoopRunsByProjectPath[normalizedReceiptLoopProjectPath(project.path)]
    }

    func receiptLoopRuntimeRun(for project: Project) -> RuntimeRunState? {
        guard let state = receiptLoopRun(for: project) else { return nil }
        let freshTimestamp = state.status == .running ? currentISO8601Timestamp() : nil
        return state.runtimeRunState(updatedAtOverride: freshTimestamp)
    }

    private func updateReceiptLoopRun(
        project: Project,
        runID: String,
        status: ReceiptLoopRunState.Status,
        failureReason: String?,
        at timestamp: String,
    ) {
        let key = normalizedReceiptLoopProjectPath(project.path)
        let existing = receiptLoopRunsByProjectPath[key]
        if let existing, existing.id != runID {
            return
        }
        let state = ReceiptLoopRunState(
            id: runID,
            projectPath: existing?.projectPath ?? project.path,
            ideaId: existing?.ideaId,
            ideaTitle: existing?.ideaTitle ?? "Claude receipt loop",
            status: status,
            failureReason: failureReason,
            createdAt: existing?.createdAt ?? timestamp,
            updatedAt: timestamp,
        )
        receiptLoopRunsByProjectPath[key] = state
    }

    private func normalizedReceiptLoopProjectPath(_ path: String) -> String {
        PathNormalizer.normalize(path)
    }

    private func runningReceiptLoopRun() -> ReceiptLoopRunState? {
        receiptLoopRunsByProjectPath.values
            .filter { $0.status == .running }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id < rhs.id
            }
            .first
    }
}
