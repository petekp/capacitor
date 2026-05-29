import Foundation

struct WorkBatchTaskClaim: Codable, Equatable {
    let taskID: String
    let status: String
    let summary: String?
    let claimedAt: Date?
    let contextUpdatedAt: Date?
    let deliveryGeneration: String?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case status
        case summary
        case claimedAt = "claimed_at"
        case contextUpdatedAt = "context_updated_at"
        case deliveryGeneration = "delivery_generation"
    }

    var isWorking: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "working"
    }
}

struct WorkBatchLoadedTaskClaim: Equatable {
    let claim: WorkBatchTaskClaim
    let url: URL
}

/// Thin wrapper over `JSONDirectoryStore`. Claims BORROW the completion-report
/// filename rule (uncapped, fallback "task") so a task's claim and its done report
/// resolve to the same basename.
struct WorkBatchTaskClaimStore {
    static let relativeDirectory = ".capacitor/work-batch-claims"

    private let store: JSONDirectoryStore<WorkBatchTaskClaim>

    init(
        worktreePath: String,
        fileManager: FileManager = .default,
    ) {
        store = JSONDirectoryStore(
            worktreePath: worktreePath,
            fileManager: fileManager,
            relativeDirectory: Self.relativeDirectory,
            fileName: WorkBatchCompletionReportStore.reportFileName(taskID:),
            loadPredicate: { $0.isWorking },
        )
    }

    func claimURL(taskID: String) -> URL {
        store.url(forID: taskID)
    }

    func loadClaims() throws -> [WorkBatchLoadedTaskClaim] {
        try store.load().map { WorkBatchLoadedTaskClaim(claim: $0.record, url: $0.url) }
    }

    func write(_ claim: WorkBatchTaskClaim) throws -> URL {
        try store.write(claim, id: claim.taskID)
    }
}
