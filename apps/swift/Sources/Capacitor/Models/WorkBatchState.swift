import Foundation

enum WorkBatchStatus: String, Codable, Equatable {
    case ready
    case working
    case waiting
    case compacting
    case idle

    /// The short status word, sourced from the canonical SessionState presentation
    /// via the existing `.sessionState` bridge so it never diverges from card chips.
    var label: String {
        sessionState.presentation.statusText
    }

    var sessionState: SessionState {
        switch self {
        case .ready:
            .ready
        case .working:
            .working
        case .waiting:
            .waiting
        case .compacting:
            .compacting
        case .idle:
            .idle
        }
    }
}

enum WorkBatchTaskStatus: String, Codable, Equatable {
    case queued
    case working
    case needsYou = "needs_you"
    case done
}

/// Structural attention state for a Work Batch.
///
/// Before the T2 teardown these states were smuggled into the
/// `currentActivitySummary` prose and then re-detected with string-sniffing
/// guards. They are now a persisted, typed fact the reducer (router +
/// reconciler) owns, and `WorkBatchProjectionBuilder.deriveBatchPresentation`
/// maps each variant to its exact display string. `.none` is the default for
/// any batch that has no outstanding attention condition (the steady state),
/// and any older on-disk batch that predates this field decodes to `.none`.
enum WorkBatchAttentionReason: Codable, Equatable {
    /// Steady state: no attention condition; presentation derives from facts.
    case none
    /// A FOREIGN-session ambiguity: two or more distinct Claude session-ids are
    /// active in the Batch Worktree, so the binding is genuinely ambiguous and
    /// must be resolved. Same-session duplicate-process detection was retired in
    /// C5 — the runtime tracks exactly one PID per session-id, so a same-session
    /// duplicate can never be derived from snapshot facts.
    case duplicateCockpit
    /// A queued Task was delivered to a live cockpit that never claimed it
    /// inside the pickup window. `taskID`/`taskTitle` name the stuck Task.
    case pickupTimeout(taskID: String, taskTitle: String)
    /// A session launch / resume / wake / context-mirror write failed.
    case launchFailed
    /// A wake of an existing cockpit failed with no Task to re-queue. Kept
    /// distinct from `.deliveryFailure` so the operator sees the wake-specific
    /// string ("Claude Code wake needs attention.") exactly as before the T2
    /// teardown.
    case wakeFailed
    /// Delivery to the cockpit could not complete (mirror or wake fault).
    case deliveryFailure
    /// No live Claude Code session matched the binding; needs reconnect.
    case needsReconnect

    private enum CodingKeys: String, CodingKey {
        case kind
        case taskID = "task_id"
        case taskTitle = "task_title"
    }

    private enum Kind: String, Codable {
        case none
        case duplicateCockpit = "duplicate_cockpit"
        case pickupTimeout = "pickup_timeout"
        case launchFailed = "launch_failed"
        case wakeFailed = "wake_failed"
        case deliveryFailure = "delivery_failure"
        case needsReconnect = "needs_reconnect"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // This is a LOCAL persisted enum, not a wire-status contract. Decode the
        // raw discriminator string and map any absent OR unrecognized/future
        // kind to `.none` so an older build can still load a state file written
        // by a newer build (graceful forward-compat) rather than failing the
        // whole snapshot decode.
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        let kind = rawKind.flatMap(Kind.init(rawValue:)) ?? .none
        switch kind {
        case .none:
            self = .none
        case .duplicateCockpit:
            self = .duplicateCockpit
        case .pickupTimeout:
            let taskID = try container.decodeIfPresent(String.self, forKey: .taskID) ?? ""
            let taskTitle = try container.decodeIfPresent(String.self, forKey: .taskTitle) ?? ""
            self = .pickupTimeout(taskID: taskID, taskTitle: taskTitle)
        case .launchFailed:
            self = .launchFailed
        case .wakeFailed:
            self = .wakeFailed
        case .deliveryFailure:
            self = .deliveryFailure
        case .needsReconnect:
            self = .needsReconnect
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .duplicateCockpit:
            try container.encode(Kind.duplicateCockpit, forKey: .kind)
        case let .pickupTimeout(taskID, taskTitle):
            try container.encode(Kind.pickupTimeout, forKey: .kind)
            try container.encode(taskID, forKey: .taskID)
            try container.encode(taskTitle, forKey: .taskTitle)
        case .launchFailed:
            try container.encode(Kind.launchFailed, forKey: .kind)
        case .wakeFailed:
            try container.encode(Kind.wakeFailed, forKey: .kind)
        case .deliveryFailure:
            try container.encode(Kind.deliveryFailure, forKey: .kind)
        case .needsReconnect:
            try container.encode(Kind.needsReconnect, forKey: .kind)
        }
    }
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
    /// Structural status decided by the reducer (router + reconciler) from live
    /// session facts. The projection re-derives the displayed status/summary
    /// from this plus tasks/checkpoints/attentionReason in
    /// `WorkBatchProjectionBuilder.deriveBatchPresentation`.
    var status: WorkBatchStatus
    /// Recorded activity line: the last genuine, agent- or operation-authored
    /// activity datum for the batch (a claim summary, a done-report summary, a
    /// "Reopened …"/"Answered …"/"Starting …" line, a queued-Task line, or a
    /// bespoke checkpoint line). It is no longer authored-then-sniffed for
    /// attention prose — attention states live in `attentionReason`. The
    /// projection treats it as one input fact among several.
    var currentActivitySummary: String
    var taskIDs: [String]
    var cockpitBindingID: String?
    /// Typed attention state; defaults to `.none`. Persisted; old files without
    /// the key decode to `.none`.
    var attentionReason: WorkBatchAttentionReason
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        name: String,
        projectPath: String,
        status: WorkBatchStatus,
        currentActivitySummary: String,
        taskIDs: [String],
        cockpitBindingID: String?,
        attentionReason: WorkBatchAttentionReason = .none,
        createdAt: Date,
        updatedAt: Date,
    ) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.status = status
        self.currentActivitySummary = currentActivitySummary
        self.taskIDs = taskIDs
        self.cockpitBindingID = cockpitBindingID
        self.attentionReason = attentionReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case projectPath = "project_path"
        case status
        case currentActivitySummary = "current_activity_summary"
        case taskIDs = "task_ids"
        case cockpitBindingID = "cockpit_binding_id"
        case attentionReason = "attention_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        status = try container.decode(WorkBatchStatus.self, forKey: .status)
        currentActivitySummary = try container.decode(String.self, forKey: .currentActivitySummary)
        taskIDs = try container.decode([String].self, forKey: .taskIDs)
        cockpitBindingID = try container.decodeIfPresent(String.self, forKey: .cockpitBindingID)
        // Migration: batches written before the T2 teardown have no
        // `attention_reason` key; decode them to the steady state.
        attentionReason = try container
            .decodeIfPresent(WorkBatchAttentionReason.self, forKey: .attentionReason) ?? .none
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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

struct WorkBatchDeliveryRecord: Codable, Equatable, Identifiable {
    let batchID: String
    var lastContextWrittenAt: Date?
    var lastDeliveryGeneration: String?
    var lastDeliveryAttemptAt: Date?
    var lastDeliveryAttemptKind: String?
    var lastClaimAt: Date?
    var lastActionableContextDigest: String? = nil
    var lastDeliveryAttemptDigest: String? = nil

    var id: String {
        batchID
    }

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case lastContextWrittenAt = "last_context_written_at"
        case lastDeliveryGeneration = "last_delivery_generation"
        case lastDeliveryAttemptAt = "last_delivery_attempt_at"
        case lastDeliveryAttemptKind = "last_delivery_attempt_kind"
        case lastClaimAt = "last_claim_at"
        case lastActionableContextDigest = "last_actionable_context_digest"
        case lastDeliveryAttemptDigest = "last_delivery_attempt_digest"
    }
}

struct WorkBatchStateSnapshot: Codable, Equatable {
    var version: Int
    var batches: [WorkBatchRecord]
    var tasks: [WorkBatchTaskRecord]
    var classifications: [WorkBatchClassificationRecord]
    var checkpoints: [WorkBatchCheckpointRecord]
    var deliveryRecords: [WorkBatchDeliveryRecord]

    enum CodingKeys: String, CodingKey {
        case version
        case batches
        case tasks
        case classifications
        case checkpoints
        case deliveryRecords = "delivery_records"
    }

    init(
        version: Int,
        batches: [WorkBatchRecord],
        tasks: [WorkBatchTaskRecord],
        classifications: [WorkBatchClassificationRecord],
        checkpoints: [WorkBatchCheckpointRecord] = [],
        deliveryRecords: [WorkBatchDeliveryRecord] = [],
    ) {
        self.version = version
        self.batches = batches
        self.tasks = tasks
        self.classifications = classifications
        self.checkpoints = checkpoints
        self.deliveryRecords = deliveryRecords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        batches = try container.decode([WorkBatchRecord].self, forKey: .batches)
        tasks = try container.decode([WorkBatchTaskRecord].self, forKey: .tasks)
        classifications = try container.decode([WorkBatchClassificationRecord].self, forKey: .classifications)
        checkpoints = try container.decodeIfPresent([WorkBatchCheckpointRecord].self, forKey: .checkpoints) ?? []
        deliveryRecords = try container.decodeIfPresent(
            [WorkBatchDeliveryRecord].self,
            forKey: .deliveryRecords,
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(batches, forKey: .batches)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(classifications, forKey: .classifications)
        try container.encode(checkpoints, forKey: .checkpoints)
        try container.encode(deliveryRecords, forKey: .deliveryRecords)
    }

    static let empty = WorkBatchStateSnapshot(
        version: 1,
        batches: [],
        tasks: [],
        classifications: [],
        checkpoints: [],
        deliveryRecords: [],
    )
}

extension WorkBatchStateSnapshot {
    func deliveryRecord(batchID: String) -> WorkBatchDeliveryRecord? {
        deliveryRecords.first { $0.batchID == batchID }
    }

    mutating func upsertDeliveryRecord(_ record: WorkBatchDeliveryRecord) {
        if let index = deliveryRecords.firstIndex(where: { $0.batchID == record.batchID }) {
            deliveryRecords[index] = record
        } else {
            deliveryRecords.append(record)
        }
    }

    mutating func recordContextWrite(
        batchID: String,
        updatedAt: Date,
        deliveryGeneration: String,
        actionableContextDigest: String? = nil,
    ) {
        var record = deliveryRecord(batchID: batchID) ?? WorkBatchDeliveryRecord(
            batchID: batchID,
            lastContextWrittenAt: nil,
            lastDeliveryGeneration: nil,
            lastDeliveryAttemptAt: nil,
            lastDeliveryAttemptKind: nil,
            lastClaimAt: nil,
            lastActionableContextDigest: nil,
            lastDeliveryAttemptDigest: nil,
        )
        record.lastContextWrittenAt = updatedAt
        record.lastDeliveryGeneration = deliveryGeneration
        record.lastActionableContextDigest = actionableContextDigest
        upsertDeliveryRecord(record)
    }

    mutating func recordDeliveryAttempt(
        batchID: String,
        attemptedAt: Date,
        kind: String,
        actionableContextDigest: String? = nil,
    ) {
        var record = deliveryRecord(batchID: batchID) ?? WorkBatchDeliveryRecord(
            batchID: batchID,
            lastContextWrittenAt: nil,
            lastDeliveryGeneration: nil,
            lastDeliveryAttemptAt: nil,
            lastDeliveryAttemptKind: nil,
            lastClaimAt: nil,
            lastActionableContextDigest: nil,
            lastDeliveryAttemptDigest: nil,
        )
        record.lastDeliveryAttemptAt = attemptedAt
        record.lastDeliveryAttemptKind = kind
        record.lastDeliveryAttemptDigest = actionableContextDigest ?? record.lastActionableContextDigest
        upsertDeliveryRecord(record)
    }

    mutating func recordTaskClaim(
        batchID: String,
        claimedAt: Date,
    ) {
        var record = deliveryRecord(batchID: batchID) ?? WorkBatchDeliveryRecord(
            batchID: batchID,
            lastContextWrittenAt: nil,
            lastDeliveryGeneration: nil,
            lastDeliveryAttemptAt: nil,
            lastDeliveryAttemptKind: nil,
            lastClaimAt: nil,
            lastActionableContextDigest: nil,
            lastDeliveryAttemptDigest: nil,
        )
        record.lastClaimAt = claimedAt
        upsertDeliveryRecord(record)
    }
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
    let preview: WorkBatchPreviewProjection?

    init(
        id: String,
        name: String,
        status: WorkBatchStatus,
        queuedTaskCount: Int,
        currentActivitySummary: String,
        tasks: [WorkBatchTaskRecord],
        checkpoints: [WorkBatchCheckpointRecord] = [],
        binding: WorkBatchCockpitBinding?,
        preview: WorkBatchPreviewProjection? = nil,
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.queuedTaskCount = queuedTaskCount
        self.currentActivitySummary = currentActivitySummary
        self.tasks = tasks
        self.checkpoints = checkpoints
        self.binding = binding
        self.preview = preview
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

enum WorkBatchProjectPrimaryAction: Equatable {
    case openWorkBatch(batchID: String)
    case showProjectDetail
    case legacyTerminal
}

enum WorkBatchProjectPrimaryActionResolver {
    static func resolve(_ batches: [WorkBatchProjection]) -> WorkBatchProjectPrimaryAction {
        guard !batches.isEmpty else {
            return .legacyTerminal
        }

        if let checkpointBatch = batches.first(where: { !$0.pendingCheckpoints.isEmpty }) {
            return .openWorkBatch(batchID: checkpointBatch.id)
        }

        let activeBatches = batches.filter { batch in
            switch batch.status {
            case .working, .waiting, .ready, .compacting:
                true
            case .idle:
                false
            }
        }

        let activeBoundBatches = activeBatches.filter { $0.binding != nil }
        if activeBoundBatches.count == 1, let batch = activeBoundBatches.first {
            return .openWorkBatch(batchID: batch.id)
        }

        if activeBatches.count > 0 {
            return .showProjectDetail
        }

        let boundBatches = batches.filter { $0.binding != nil }
        if boundBatches.count == 1, let batch = boundBatches.first {
            return .openWorkBatch(batchID: batch.id)
        }

        return .showProjectDetail
    }
}

enum WorkBatchProjectContextSummaryResolver {
    static func resolve(_ batches: [WorkBatchProjection]) -> String? {
        let activeSummary = batches
            .first { batch in
                switch batch.status {
                case .working, .waiting, .ready, .compacting:
                    true
                case .idle:
                    false
                }
            }?
            .currentActivitySummary

        if let activeSummary = normalized(activeSummary) {
            return activeSummary
        }

        // New Work Batch behavior: once Tasks are Capacitor-managed, the card
        // should not fall back to stale legacy transcript summaries after completion.
        let latestIdleSummary = batches
            .first { $0.status == .idle }?
            .currentActivitySummary
        return normalized(latestIdleSummary)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

enum WorkBatchProjectVisualStateResolver {
    static func resolve(_ batches: [WorkBatchProjection]) -> SessionState? {
        if batches.contains(where: { !$0.pendingCheckpoints.isEmpty }) {
            return .waiting
        }

        return batches
            .first { batch in
                switch batch.status {
                case .ready, .working, .waiting, .compacting:
                    true
                case .idle:
                    false
                }
            }?
            .status
            .sessionState
    }
}

enum WorkBatchProjectionBuilder {
    typealias PreviewProjector = (
        _ batch: WorkBatchRecord,
        _ binding: WorkBatchCockpitBinding?,
        _ previewRecord: WorkBatchPreviewRecord?,
    ) -> WorkBatchPreviewProjection?

    static func build(
        state: WorkBatchStateSnapshot,
        bindings: [WorkBatchCockpitBinding],
        previewRecords: [WorkBatchPreviewRecord] = [],
        previewProjector: PreviewProjector? = nil,
    ) -> [WorkBatchProjection] {
        let tasksByBatch = Dictionary(grouping: state.tasks, by: \.batchID)
        let checkpointsByBatch = Dictionary(grouping: state.checkpoints, by: \.batchID)
        let bindingsByBatch = Dictionary(uniqueKeysWithValues: bindings.map { ($0.batchID, $0) })
        let previewsByBatch = Dictionary(uniqueKeysWithValues: previewRecords.map { ($0.batchID, $0) })

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
                let binding = bindingsByBatch[batch.id]
                let presentation = deriveBatchPresentation(
                    batch: batch,
                    tasks: sortedTasks,
                    checkpoints: checkpoints,
                )
                return WorkBatchProjection(
                    id: batch.id,
                    name: batch.name,
                    status: presentation.status,
                    queuedTaskCount: tasks.count(where: { $0.status == .queued }),
                    currentActivitySummary: presentation.summary,
                    tasks: sortedTasks,
                    checkpoints: checkpoints,
                    binding: binding,
                    preview: previewProjector?(batch, binding, previewsByBatch[batch.id]),
                )
            }
    }

    struct BatchPresentation: Equatable {
        let status: WorkBatchStatus
        let summary: String
    }

    /// Pure, total derivation of the `(status, summary)` the home UI consumes
    /// for one Work Batch.
    ///
    /// This is the single source of truth for Work Batch presentation. It reads
    /// only structural facts the reducer owns — the stored structural `status`,
    /// the per-Task statuses, whether a checkpoint is pending, the typed
    /// `attentionReason`, and the recorded activity line — and never inspects
    /// live prose to decide what to show. Every branch returns a concrete value,
    /// so it cannot flap or leave the summary undefined.
    ///
    /// Precedence (highest first):
    ///   1. A pending checkpoint always speaks for the batch (a queued
    ///      operator decision must stay visible even alongside duplicate
    ///      cockpits or delivery faults).
    ///   2. A typed `attentionReason` maps to its exact attention string.
    ///   3. The working-branch fact derivation (queued/working/all-done).
    ///   4. The recorded activity line, recomputed from facts where it is a
    ///      placeholder/generic and passed through where it is genuine.
    static func deriveBatchPresentation(
        batch: WorkBatchRecord,
        tasks: [WorkBatchTaskRecord],
        checkpoints: [WorkBatchCheckpointRecord],
    ) -> BatchPresentation {
        let status = batch.status

        // 1. Pending checkpoint wins: surface the bespoke "Checkpoint ready: …"
        //    recomputed from the checkpoint question, falling back to the
        //    generic line when no question is available.
        if let pendingCheckpoint = checkpoints.first(where: { $0.isPending }) {
            return BatchPresentation(
                status: status,
                summary: checkpointReadySummary(for: pendingCheckpoint, recordedLine: batch.currentActivitySummary),
            )
        }

        // 2. Typed attention state maps to its exact string.
        switch batch.attentionReason {
        case .none:
            break
        case .duplicateCockpit:
            return BatchPresentation(
                status: status,
                summary: "Multiple Claude Code sessions match this Work Batch.",
            )
        case let .pickupTimeout(_, taskTitle):
            let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let named = title.isEmpty ? "the queued Task" : title
            return BatchPresentation(
                status: status,
                summary: "Claude Code has not picked up \(named) yet. Click to re-enter.",
            )
        case .launchFailed:
            return BatchPresentation(status: status, summary: "Claude Code launch needs attention.")
        case .wakeFailed:
            return BatchPresentation(status: status, summary: "Claude Code wake needs attention.")
        case .deliveryFailure:
            return BatchPresentation(status: status, summary: "Claude Code delivery needs attention.")
        case .needsReconnect:
            return BatchPresentation(status: status, summary: "Claude Code session needs reconnect.")
        }

        // 3 + 4. Fact-derived summary for the steady state.
        return BatchPresentation(status: status, summary: displaySummary(for: batch, tasks: tasks))
    }

    private static func checkpointReadySummary(
        for checkpoint: WorkBatchCheckpointRecord,
        recordedLine: String,
    ) -> String {
        // The bespoke "Checkpoint ready: <question>" line is the genuine
        // checkpoint-creation activity datum; it is recomputed from the
        // question so it stays in sync. The recorded line is the discriminator:
        //   1. if the recorded line already is the matching bespoke sentence
        //      (checkpoint-creation path), surface it verbatim;
        //   2. else, reproduce 3a's `markWaitingForUser`: only substitute the
        //      generic operator prompt when the recorded line matched
        //      `shouldReplaceSummaryForUserInput` (empty/working/reconnecting/
        //      reconnect/attention/multiple). A genuine non-matching line (e.g.
        //      "Answered checkpoint for X. Claude Code will continue." or a
        //      stale bespoke "Checkpoint ready: OLD-Q") was preserved in 3a, so
        //      it passes through here unchanged.
        let recomputed = "Checkpoint ready: \(WorkBatchSummaryText.questionSentence(checkpoint.question))"
        let trimmedRecorded = recordedLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRecorded == recomputed {
            return recomputed
        }
        if shouldReplaceSummaryForUserInput(trimmedRecorded) {
            return "Checkpoint needs your input."
        }
        return trimmedRecorded
    }

    /// 3a `WorkBatchBindingReconciler.shouldReplaceSummaryForUserInput`, verbatim.
    /// Matches the recorded line (case-insensitive, trimmed) that
    /// `markWaitingForUser` would have replaced with the generic checkpoint
    /// prompt. Everything else was preserved.
    private static func shouldReplaceSummaryForUserInput(_ summary: String) -> Bool {
        let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ||
            normalized.contains("is working") ||
            normalized.contains("is reconnecting") ||
            normalized.contains("needs reconnect") ||
            normalized.contains("needs attention") ||
            normalized.contains("multiple claude code sessions")
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
        if batch.status == .working {
            let workingTasks = tasks.filter { $0.status == .working }
            let queuedTasks = tasks.filter { $0.status == .queued }

            if let workingTask = workingTasks.last,
               !queuedTasks.isEmpty
            {
                return "Working on \(workingTask.displayTitle). \(queuedTasks.count) queued."
            }

            if workingTasks.isEmpty,
               let queuedTask = queuedTasks.last
            {
                return "Queued \(queuedTask.displayTitle)."
            }

            if workingTasks.isEmpty,
               queuedTasks.isEmpty,
               !tasks.isEmpty,
               tasks.allSatisfy({ $0.status == .done })
            {
                return "Checking final result."
            }

            // Reproduce 3a's `markRunningIfUseful` + `runningSummary`: a single
            // working Task with no queued Task and no all-done short-circuit got
            // "Working on <title>." whenever the recorded line was empty or
            // matched the recovery replace set (the 3a
            // `shouldReplaceSummaryAfterRecovery` predicate — note it tests
            // "is working in", not "is working"). A genuine bespoke recorded line
            // for a single working Task (e.g. a fresh "Claude Code is starting on
            // X." launch line) was preserved in 3a and must still pass through to
            // the recorded-line logic below.
            if workingTasks.count == 1,
               queuedTasks.isEmpty,
               let workingTask = workingTasks.first
            {
                let recorded = batch.currentActivitySummary
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldReplaceSummaryAfterRecovery(recorded) {
                    return "Working on \(workingTask.displayTitle)."
                }
            }
        }

        let summary = batch.currentActivitySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Completed/done batch: reproduce 3a's `markDoneIfUseful`, which replaced
        // the recorded line with the Done completion line whenever
        // `shouldReplaceSummaryAfterCompletion` matched (empty, the two
        // generic-done strings, OR a recorded line containing "is working" /
        // "needs reconnect" / "needs attention" / "multiple claude code
        // sessions"). A genuine, non-matching recorded line — including the
        // stale "Working on …" wart, which the 3a predicate did NOT match
        // because it tests "is working", not "working" — is preserved verbatim
        // by the passthrough below.
        if isCompletedBatch(batch: batch, tasks: tasks),
           shouldReplaceSummaryAfterCompletion(summary)
        {
            return completionSummary(for: tasks)
        }
        // A generic-done placeholder on a non-completed batch is still cleaned
        // up to the fact-derived completion line, matching 3a `displaySummary`.
        if isGenericDoneSummary(summary) {
            return completionSummary(for: tasks)
        }
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

    private static func isCompletedBatch(
        batch: WorkBatchRecord,
        tasks: [WorkBatchTaskRecord],
    ) -> Bool {
        switch batch.status {
        case .ready, .idle:
            !tasks.isEmpty && tasks.allSatisfy { $0.status == .done }
        case .working, .waiting, .compacting:
            false
        }
    }

    private static func isGenericDoneSummary(_ summary: String) -> Bool {
        switch summary.lowercased() {
        case "done: all tasks completed.", "all tasks done.":
            true
        default:
            false
        }
    }

    /// 3a `WorkBatchBindingReconciler.shouldReplaceSummaryAfterCompletion`,
    /// verbatim. Matches the recorded line (case-insensitive, trimmed) that
    /// `markDoneIfUseful` would have replaced with the Done completion line.
    /// Note: it tests `contains("is working")`, NOT `contains("working")`, so a
    /// recorded "Working on <title>." does not match and survives unchanged.
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

    /// 3a `WorkBatchBindingReconciler.shouldReplaceSummaryAfterRecovery`,
    /// verbatim. Matches the recorded line (case-insensitive, trimmed) that
    /// `markRunningIfUseful` would have replaced with the running summary
    /// ("Working on <title>."). Note: it tests `contains("is working in")`, NOT
    /// `contains("is working")`/`contains("working")`, so a bespoke launch line
    /// ("Claude Code is starting on X.") and a stale "Working on X." both survive.
    private static func shouldReplaceSummaryAfterRecovery(_ summary: String) -> Bool {
        let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ||
            normalized.contains("is working in") ||
            normalized.contains("needs reconnect") ||
            normalized.contains("needs attention") ||
            normalized.contains("multiple claude code sessions")
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
        return WorkBatchSummaryText.doneSummary(taskTitle: completedTask.displayTitle)
    }
}

/// Single source of truth for the two pure summary-text helpers that the
/// author side (`WorkBatchAutoRouter`) and the derive side
/// (`WorkBatchProjectionBuilder`) both depend on. The checkpoint discriminator
/// in `deriveBatchPresentation` compares its recomputed
/// "Checkpoint ready: <questionSentence>" against the author-recorded line, so
/// the two sides MUST format the question identically; hoisting both functions
/// here removes the silent drift risk that two byte-identical copies created.
enum WorkBatchSummaryText {
    /// Normalizes a checkpoint question into a single sentence ending in
    /// terminal punctuation (defaulting to "?").
    static func questionSentence(_ rawQuestion: String) -> String {
        let trimmed = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "User input needed." }
        if let last = trimmed.last,
           [".", "!", "?"].contains(last)
        {
            return trimmed
        }
        return "\(trimmed)?"
    }

    /// Formats a completed Task title into the "Done: <title>." line.
    static func doneSummary(taskTitle: String) -> String {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Done." }
        if let last = title.last,
           [".", "!", "?"].contains(last)
        {
            return "Done: \(title)"
        }
        return "Done: \(title)."
    }
}
