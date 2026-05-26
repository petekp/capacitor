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

struct WorkBatchTaskClaimStore {
    static let relativeDirectory = ".capacitor/work-batch-claims"

    private let worktreeURL: URL
    private let fileManager: FileManager

    init(
        worktreePath: String,
        fileManager: FileManager = .default,
    ) {
        worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        self.fileManager = fileManager
    }

    func claimURL(taskID: String) -> URL {
        directoryURL.appendingPathComponent(WorkBatchCompletionReportStore.reportFileName(taskID: taskID))
    }

    func loadClaims() throws -> [WorkBatchLoadedTaskClaim] {
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
                      let claim = try? decoder.decode(WorkBatchTaskClaim.self, from: data),
                      claim.isWorking
                else {
                    return nil
                }
                return WorkBatchLoadedTaskClaim(claim: claim, url: url)
            }
    }

    func write(_ claim: WorkBatchTaskClaim) throws -> URL {
        try? WorkBatchMetadataIgnoreInstaller.install(
            in: worktreeURL.path,
            fileManager: fileManager,
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
        )
        let url = claimURL(taskID: claim.taskID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(claim).write(to: url, options: .atomic)
        return url
    }

    private var directoryURL: URL {
        worktreeURL.appendingPathComponent(Self.relativeDirectory, isDirectory: true)
    }
}
