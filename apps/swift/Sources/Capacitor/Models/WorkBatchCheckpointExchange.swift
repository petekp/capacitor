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

struct WorkBatchCheckpointRequestStore {
    static let relativeDirectory = ".capacitor/work-batch-checkpoints"

    private let worktreeURL: URL
    private let fileManager: FileManager

    init(
        worktreePath: String,
        fileManager: FileManager = .default,
    ) {
        worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        self.fileManager = fileManager
    }

    func requestURL(checkpointID: String) -> URL {
        directoryURL.appendingPathComponent(Self.fileName(id: checkpointID))
    }

    func loadRequests() throws -> [WorkBatchLoadedCheckpointRequest] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let request = try? decoder.decode(WorkBatchCheckpointRequest.self, from: data),
                      request.hasUsableQuestion
                else {
                    return nil
                }
                return WorkBatchLoadedCheckpointRequest(request: request, url: url)
            }
    }

    func write(_ request: WorkBatchCheckpointRequest) throws -> URL {
        try? WorkBatchMetadataIgnoreInstaller.install(
            in: worktreeURL.path,
            fileManager: fileManager,
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
        )

        let url = requestURL(checkpointID: request.checkpointID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: url, options: .atomic)
        return url
    }

    static func fileName(id: String) -> String {
        let sanitized = id.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let basename = collapsed.isEmpty ? "checkpoint" : collapsed
        return "\(basename).json"
    }

    private var directoryURL: URL {
        worktreeURL.appendingPathComponent(Self.relativeDirectory, isDirectory: true)
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

struct WorkBatchCheckpointResponseStore {
    static let relativeDirectory = ".capacitor/work-batch-checkpoint-responses"

    private let worktreeURL: URL
    private let fileManager: FileManager

    init(
        worktreePath: String,
        fileManager: FileManager = .default,
    ) {
        worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        self.fileManager = fileManager
    }

    func responseURL(checkpointID: String) -> URL {
        directoryURL.appendingPathComponent(WorkBatchCheckpointRequestStore.fileName(id: checkpointID))
    }

    func write(_ response: WorkBatchCheckpointResponse) throws -> URL {
        try? WorkBatchMetadataIgnoreInstaller.install(
            in: worktreeURL.path,
            fileManager: fileManager,
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
        )

        let url = responseURL(checkpointID: response.checkpointID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(response).write(to: url, options: .atomic)
        return url
    }

    private var directoryURL: URL {
        worktreeURL.appendingPathComponent(Self.relativeDirectory, isDirectory: true)
    }
}
