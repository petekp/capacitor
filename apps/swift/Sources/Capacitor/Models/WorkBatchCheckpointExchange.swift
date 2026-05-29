import Foundation

struct WorkBatchCheckpointRequest: Codable, Equatable {
    let checkpointID: String
    let taskID: String
    let question: String
    let reason: String
    let recommendedAction: String?
    let requestedAt: Date?

    enum CodingKeys: String, CodingKey {
        case checkpointID = "checkpoint_id"
        case taskID = "task_id"
        case question
        case reason
        case recommendedAction = "recommended_action"
        case requestedAt = "requested_at"
    }

    var hasUsableQuestion: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WorkBatchLoadedCheckpointRequest: Equatable {
    let request: WorkBatchCheckpointRequest
    let url: URL
}

/// Thin wrapper over `JSONDirectoryStore`. Uncapped filename, fallback "checkpoint",
/// loads only requests with a usable question.
struct WorkBatchCheckpointRequestStore {
    static let relativeDirectory = ".capacitor/work-batch-checkpoints"

    private let store: JSONDirectoryStore<WorkBatchCheckpointRequest>

    init(
        worktreePath: String,
        fileManager: FileManager = .default,
    ) {
        store = JSONDirectoryStore(
            worktreePath: worktreePath,
            fileManager: fileManager,
            relativeDirectory: Self.relativeDirectory,
            fileName: Self.fileName(id:),
            loadPredicate: { $0.hasUsableQuestion },
        )
    }

    func requestURL(checkpointID: String) -> URL {
        store.url(forID: checkpointID)
    }

    func loadRequests() throws -> [WorkBatchLoadedCheckpointRequest] {
        try store.load().map { WorkBatchLoadedCheckpointRequest(request: $0.record, url: $0.url) }
    }

    func write(_ request: WorkBatchCheckpointRequest) throws -> URL {
        try store.write(request, id: request.checkpointID)
    }

    static func fileName(id: String) -> String {
        "\(WorkBatchArtifactCodec.sanitizedIdentifier(id, fallback: "checkpoint", maxLength: nil)).json"
    }
}

struct WorkBatchCheckpointResponse: Codable, Equatable {
    let checkpointID: String
    let taskID: String
    let response: String
    let respondedAt: Date

    enum CodingKeys: String, CodingKey {
        case checkpointID = "checkpoint_id"
        case taskID = "task_id"
        case response
        case respondedAt = "responded_at"
    }
}

/// Thin wrapper over `JSONDirectoryStore`. WRITE-ONLY: it BORROWS the checkpoint
/// request filename rule (uncapped, fallback "checkpoint") and supplies no load
/// predicate, so no read path exists — responses are consumed by the agent side.
struct WorkBatchCheckpointResponseStore {
    static let relativeDirectory = ".capacitor/work-batch-checkpoint-responses"

    private let store: JSONDirectoryStore<WorkBatchCheckpointResponse>

    init(
        worktreePath: String,
        fileManager: FileManager = .default,
    ) {
        store = JSONDirectoryStore(
            worktreePath: worktreePath,
            fileManager: fileManager,
            relativeDirectory: Self.relativeDirectory,
            fileName: WorkBatchCheckpointRequestStore.fileName(id:),
        )
    }

    func responseURL(checkpointID: String) -> URL {
        store.url(forID: checkpointID)
    }

    func write(_ response: WorkBatchCheckpointResponse) throws -> URL {
        try store.write(response, id: response.checkpointID)
    }
}
