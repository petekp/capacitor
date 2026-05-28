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

struct WorkBatchTaskRequestStore {
    static let relativeDirectory = ".capacitor/work-batch-task-requests"

    private let worktreeURL: URL
    private let fileManager: FileManager

    init(
        worktreePath: String,
        fileManager: FileManager = .default,
    ) {
        worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        self.fileManager = fileManager
    }

    func requestURL(taskID: String) -> URL {
        directoryURL.appendingPathComponent(Self.fileName(id: taskID))
    }

    func loadRequests() throws -> [WorkBatchLoadedTaskRequest] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .capacitorISO8601

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let request = try? decoder.decode(WorkBatchTaskRequest.self, from: data),
                      request.hasUsableContent
                else {
                    return nil
                }
                return WorkBatchLoadedTaskRequest(request: request, url: url)
            }
    }

    func write(_ request: WorkBatchTaskRequest, taskID: String? = nil) throws -> URL {
        try? WorkBatchMetadataIgnoreInstaller.install(
            in: worktreeURL.path,
            fileManager: fileManager,
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
        )

        let rawTaskID = taskID ?? request.taskID ?? "task"
        let url = requestURL(taskID: rawTaskID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: url, options: .atomic)
        return url
    }

    static func fileName(id: String) -> String {
        "\(normalizedIdentifier(id, fallback: "task")).json"
    }

    static func normalizedIdentifier(
        _ rawValue: String,
        fallback: String,
    ) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let value = collapsed.isEmpty ? fallback : collapsed
        return String(value.prefix(80))
    }

    private var directoryURL: URL {
        worktreeURL.appendingPathComponent(Self.relativeDirectory, isDirectory: true)
    }
}
