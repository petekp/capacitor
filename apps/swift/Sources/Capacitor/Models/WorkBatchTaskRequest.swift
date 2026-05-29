import Foundation

struct WorkBatchTaskRequest: Codable, Equatable {
    let taskID: String?
    let title: String?
    let body: String?
    let source: String?
    let requestedAt: Date?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case title
        case body
        case source
        case requestedAt = "requested_at"
    }

    var normalizedTitle: String {
        title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var normalizedBody: String {
        body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var hasUsableContent: Bool {
        !normalizedTitle.isEmpty || !normalizedBody.isEmpty
    }
}

struct WorkBatchLoadedTaskRequest: Equatable {
    let request: WorkBatchTaskRequest
    let url: URL

    var canonicalTaskID: String {
        WorkBatchTaskRequestStore.normalizedIdentifier(
            request.taskID ?? url.deletingPathExtension().lastPathComponent,
            fallback: "task",
        )
    }
}

/// Thin wrapper over `JSONDirectoryStore`. Requests are the ONLY store that caps the
/// sanitized basename at 80 characters (`maxLength: 80`, fallback "task").
struct WorkBatchTaskRequestStore {
    static let relativeDirectory = ".capacitor/work-batch-task-requests"

    private let store: JSONDirectoryStore<WorkBatchTaskRequest>

    init(
        worktreePath: String,
        fileManager: FileManager = .default,
    ) {
        store = JSONDirectoryStore(
            worktreePath: worktreePath,
            fileManager: fileManager,
            relativeDirectory: Self.relativeDirectory,
            fileName: Self.fileName(id:),
            loadPredicate: { $0.hasUsableContent },
        )
    }

    func requestURL(taskID: String) -> URL {
        store.url(forID: taskID)
    }

    func loadRequests() throws -> [WorkBatchLoadedTaskRequest] {
        try store.load().map { WorkBatchLoadedTaskRequest(request: $0.record, url: $0.url) }
    }

    func write(_ request: WorkBatchTaskRequest, taskID: String? = nil) throws -> URL {
        let rawTaskID = taskID ?? request.taskID ?? "task"
        return try store.write(request, id: rawTaskID)
    }

    static func fileName(id: String) -> String {
        "\(normalizedIdentifier(id, fallback: "task")).json"
    }

    static func normalizedIdentifier(
        _ rawValue: String,
        fallback: String,
    ) -> String {
        WorkBatchArtifactCodec.sanitizedIdentifier(rawValue, fallback: fallback, maxLength: 80)
    }
}
