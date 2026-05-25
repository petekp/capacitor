import Foundation

enum WorkBatchStatus: String, Codable, Equatable {
    case ready
    case working
    case waiting
    case compacting
    case idle

    var label: String {
        switch self {
        case .ready:
            "Ready"
        case .working:
            "Working"
        case .waiting:
            "Waiting"
        case .compacting:
            "Compacting"
        case .idle:
            "Idle"
        }
    }
}

enum WorkBatchTaskStatus: String, Codable, Equatable {
    case queued
    case working
    case needsYou = "needs_you"
    case done
}

struct WorkBatchTaskRecord: Codable, Equatable, Identifiable {
    let id: String
    let sourceIdeaID: String?
    var title: String
    var body: String
    var status: WorkBatchTaskStatus
    var batchID: String
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sourceIdeaID = "source_idea_id"
        case title
        case body
        case status
        case batchID = "batch_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var taskItem: WorkBatchTaskItem {
        WorkBatchTaskItem(
            id: id,
            title: displayTitle,
            body: body,
            status: status.rawValue,
        )
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != "..." {
            return trimmedTitle
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBody.isEmpty ? "Untitled Task" : String(trimmedBody.prefix(80))
    }
}

struct WorkBatchRecord: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var projectPath: String
    var status: WorkBatchStatus
    var currentActivitySummary: String
    var taskIDs: [String]
    var cockpitBindingID: String?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case projectPath = "project_path"
        case status
        case currentActivitySummary = "current_activity_summary"
        case taskIDs = "task_ids"
        case cockpitBindingID = "cockpit_binding_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum WorkBatchClassificationTarget: Equatable {
    case existing(batchID: String)
    case new(batchName: String)
}

struct WorkBatchClassificationRecord: Codable, Equatable, Identifiable {
    enum TargetKind: String, Codable {
        case existing
        case new
    }

    let id: String
    let taskID: String
    let targetKind: TargetKind
    let batchID: String?
    let proposedBatchName: String?
    let confidence: Double
    let rationale: String
    let summary: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case targetKind = "target_kind"
        case batchID = "batch_id"
        case proposedBatchName = "proposed_batch_name"
        case confidence
        case rationale
        case summary
        case createdAt = "created_at"
    }

    var target: WorkBatchClassificationTarget {
        if targetKind == .existing, let batchID {
            return .existing(batchID: batchID)
        }
        return .new(batchName: proposedBatchName ?? "New Work Batch")
    }

    static func existing(
        taskID: String,
        batchID: String,
        confidence: Double,
        rationale: String,
        summary: String,
        createdAt: Date = Date(),
    ) -> WorkBatchClassificationRecord {
        WorkBatchClassificationRecord(
            id: UUID().uuidString.lowercased(),
            taskID: taskID,
            targetKind: .existing,
            batchID: batchID,
            proposedBatchName: nil,
            confidence: confidence,
            rationale: rationale,
            summary: summary,
            createdAt: createdAt,
        )
    }

    static func new(
        taskID: String,
        batchName: String,
        confidence: Double,
        rationale: String,
        summary: String,
        createdAt: Date = Date(),
    ) -> WorkBatchClassificationRecord {
        WorkBatchClassificationRecord(
            id: UUID().uuidString.lowercased(),
            taskID: taskID,
            targetKind: .new,
            batchID: nil,
            proposedBatchName: batchName,
            confidence: confidence,
            rationale: rationale,
            summary: summary,
            createdAt: createdAt,
        )
    }
}

enum WorkBatchCheckpointStatus: String, Codable, Equatable {
    case pending
    case answered
}

struct WorkBatchCheckpointRecord: Codable, Equatable, Identifiable {
    let id: String
    let batchID: String
    let taskID: String
    var question: String
    var reason: String
    var recommendedAction: String?
    var status: WorkBatchCheckpointStatus
    let requestedAt: Date
    var respondedAt: Date?
    var response: String?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case batchID = "batch_id"
        case taskID = "task_id"
        case question
        case reason
        case recommendedAction = "recommended_action"
        case status
        case requestedAt = "requested_at"
        case respondedAt = "responded_at"
        case response
        case updatedAt = "updated_at"
    }

    var isPending: Bool {
        status == .pending
    }
}

struct WorkBatchStateSnapshot: Codable, Equatable {
    var version: Int
    var batches: [WorkBatchRecord]
    var tasks: [WorkBatchTaskRecord]
    var classifications: [WorkBatchClassificationRecord]
    var checkpoints: [WorkBatchCheckpointRecord]

    enum CodingKeys: String, CodingKey {
        case version
        case batches
        case tasks
        case classifications
        case checkpoints
    }

    init(
        version: Int,
        batches: [WorkBatchRecord],
        tasks: [WorkBatchTaskRecord],
        classifications: [WorkBatchClassificationRecord],
        checkpoints: [WorkBatchCheckpointRecord] = [],
    ) {
        self.version = version
        self.batches = batches
        self.tasks = tasks
        self.classifications = classifications
        self.checkpoints = checkpoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        batches = try container.decode([WorkBatchRecord].self, forKey: .batches)
        tasks = try container.decode([WorkBatchTaskRecord].self, forKey: .tasks)
        classifications = try container.decode([WorkBatchClassificationRecord].self, forKey: .classifications)
        checkpoints = try container.decodeIfPresent([WorkBatchCheckpointRecord].self, forKey: .checkpoints) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(batches, forKey: .batches)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(classifications, forKey: .classifications)
        try container.encode(checkpoints, forKey: .checkpoints)
    }

    static let empty = WorkBatchStateSnapshot(
        version: 1,
        batches: [],
        tasks: [],
        classifications: [],
        checkpoints: [],
    )
}

struct WorkBatchStateStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(projectPath: String, fileManager: FileManager = .default) {
        self.init(
            fileURL: Self.defaultFileURL(projectPath: projectPath, fileManager: fileManager),
            fileManager: fileManager,
        )
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func defaultFileURL(projectPath: String, fileManager: FileManager = .default) -> URL {
        CapacitorProjectPaths.projectDataDirectory(for: projectPath, fileManager: fileManager)
            .appendingPathComponent("work-batches", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    func load() throws -> WorkBatchStateSnapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkBatchStateSnapshot.self, from: data)
    }

    func save(_ snapshot: WorkBatchStateSnapshot) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

struct WorkBatchProjection: Equatable, Identifiable {
    let id: String
    let name: String
    let status: WorkBatchStatus
    let queuedTaskCount: Int
    let currentActivitySummary: String
    let tasks: [WorkBatchTaskRecord]
    let checkpoints: [WorkBatchCheckpointRecord]
    let binding: WorkBatchCockpitBinding?

    init(
        id: String,
        name: String,
        status: WorkBatchStatus,
        queuedTaskCount: Int,
        currentActivitySummary: String,
        tasks: [WorkBatchTaskRecord],
        checkpoints: [WorkBatchCheckpointRecord] = [],
        binding: WorkBatchCockpitBinding?,
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.queuedTaskCount = queuedTaskCount
        self.currentActivitySummary = currentActivitySummary
        self.tasks = tasks
        self.checkpoints = checkpoints
        self.binding = binding
    }

    var pendingCheckpoints: [WorkBatchCheckpointRecord] {
        checkpoints.filter(\.isPending)
    }
}

enum WorkBatchOpenAction: Equatable {
    case answerCheckpoint(WorkBatchCheckpointRecord)
    case openCockpit
}

enum WorkBatchOpenActionResolver {
    static func resolve(_ batch: WorkBatchProjection) -> WorkBatchOpenAction {
        if let checkpoint = batch.pendingCheckpoints.first {
            // New Work Batch behavior: primary Open Batch is checkpoint-first.
            // Legacy direct cockpit access stays available from the terminal button.
            return .answerCheckpoint(checkpoint)
        }
        return .openCockpit
    }
}

enum WorkBatchProjectionBuilder {
    static func build(
        state: WorkBatchStateSnapshot,
        bindings: [WorkBatchCockpitBinding],
    ) -> [WorkBatchProjection] {
        let tasksByBatch = Dictionary(grouping: state.tasks, by: \.batchID)
        let checkpointsByBatch = Dictionary(grouping: state.checkpoints, by: \.batchID)
        let bindingsByBatch = Dictionary(uniqueKeysWithValues: bindings.map { ($0.batchID, $0) })

        return state.batches
            .sorted { lhs, rhs in
                let lhsTasks = tasksByBatch[lhs.id] ?? []
                let rhsTasks = tasksByBatch[rhs.id] ?? []
                let lhsPriority = displayPriority(for: lhs, tasks: lhsTasks)
                let rhsPriority = displayPriority(for: rhs, tasks: rhsTasks)
                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { batch in
                let tasks = tasksByBatch[batch.id] ?? []
                let checkpoints = (checkpointsByBatch[batch.id] ?? [])
                    .sorted { lhs, rhs in
                        if lhs.status != rhs.status {
                            return lhs.status == .pending
                        }
                        if lhs.updatedAt != rhs.updatedAt {
                            return lhs.updatedAt > rhs.updatedAt
                        }
                        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                    }
                let sortedTasks = tasks.sorted { $0.createdAt < $1.createdAt }
                return WorkBatchProjection(
                    id: batch.id,
                    name: batch.name,
                    status: batch.status,
                    queuedTaskCount: tasks.count(where: { $0.status == .queued }),
                    currentActivitySummary: displaySummary(for: batch, tasks: sortedTasks),
                    tasks: sortedTasks,
                    checkpoints: checkpoints,
                    binding: bindingsByBatch[batch.id],
                )
            }
    }

    private static func displayPriority(
        for batch: WorkBatchRecord,
        tasks: [WorkBatchTaskRecord],
    ) -> Int {
        switch batch.status {
        case .waiting:
            40
        case .working where tasks.contains(where: { $0.status == .queued }):
            35
        case .working:
            30
        case .ready, .compacting:
            20
        case .idle:
            0
        }
    }

    private static func displaySummary(
        for batch: WorkBatchRecord,
        tasks: [WorkBatchTaskRecord],
    ) -> String {
        let summary = batch.currentActivitySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary.contains("..."),
              let task = tasks.last
        else {
            return summary
        }

        let taskTitle = task.displayTitle
        if summary.hasPrefix("Claude Code is starting on ") {
            return "Claude Code is starting on \(taskTitle)."
        }
        if summary.hasPrefix("Starting ") {
            return "Starting \(taskTitle)."
        }
        if summary.hasPrefix("Added ") {
            return "Added \(taskTitle)."
        }
        return taskTitle
    }
}
