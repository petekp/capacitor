import AppKit
import Foundation

enum WorkBatchPreviewStatus: String, Codable, Equatable {
    case previewUnavailable = "preview_unavailable"
    case previewAvailable = "preview_available"
    case previewBuilding = "preview_building"
    case readyToInspect = "ready_to_inspect"
    case previewFailed = "preview_failed"

    init(_ proofStatus: MacOSPreviewWorkStatus) {
        switch proofStatus {
        case .previewBuilding:
            self = .previewBuilding
        case .readyToInspect:
            self = .readyToInspect
        case .previewFailed:
            self = .previewFailed
        case .previewUnavailable:
            self = .previewUnavailable
        }
    }
}

struct WorkBatchPreviewRecord: Codable, Equatable, Identifiable {
    let id: String
    let batchID: String
    let projectPath: String
    let worktreePath: String?
    let status: WorkBatchPreviewStatus
    let appPath: String?
    let bundleID: String?
    let displayName: String?
    let pid: Int32?
    let proofPath: String?
    let buildLogPath: String?
    let failureReason: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case batchID = "batch_id"
        case projectPath = "project_path"
        case worktreePath = "worktree_path"
        case status
        case appPath = "app_path"
        case bundleID = "bundle_id"
        case displayName = "display_name"
        case pid
        case proofPath = "proof_path"
        case buildLogPath = "build_log_path"
        case failureReason = "failure_reason"
        case updatedAt = "updated_at"
    }

    static func building(
        batchID: String,
        projectPath: String,
        binding: WorkBatchCockpitBinding,
        request: MacOSPreviewWorkRequest,
        updatedAt: Date,
    ) -> WorkBatchPreviewRecord {
        WorkBatchPreviewRecord(
            id: batchID,
            batchID: batchID,
            projectPath: projectPath,
            worktreePath: PathNormalizer.normalize(binding.worktreePath),
            status: .previewBuilding,
            appPath: PathNormalizer.normalize(request.appURL.path),
            bundleID: request.expectedBundleID,
            displayName: request.expectedDisplayName,
            pid: nil,
            proofPath: request.proofURL.path,
            buildLogPath: request.buildLogURL.path,
            failureReason: nil,
            updatedAt: updatedAt,
        )
    }

    static func unavailable(
        batchID: String,
        projectPath: String,
        worktreePath: String?,
        reason: String,
        updatedAt: Date,
    ) -> WorkBatchPreviewRecord {
        WorkBatchPreviewRecord(
            id: batchID,
            batchID: batchID,
            projectPath: projectPath,
            worktreePath: worktreePath.map(PathNormalizer.normalize),
            status: .previewUnavailable,
            appPath: nil,
            bundleID: MacOSPreviewWorkRequest.capacitorPreview().expectedBundleID,
            displayName: MacOSPreviewWorkRequest.capacitorPreview().expectedDisplayName,
            pid: nil,
            proofPath: nil,
            buildLogPath: nil,
            failureReason: reason,
            updatedAt: updatedAt,
        )
    }

    static func fromProof(
        _ proof: MacOSPreviewWorkProof,
        batchID: String,
        projectPath: String,
        proofPath: String,
        updatedAt: Date,
    ) -> WorkBatchPreviewRecord {
        WorkBatchPreviewRecord(
            id: batchID,
            batchID: batchID,
            projectPath: projectPath,
            worktreePath: PathNormalizer.normalize(proof.worktreePath),
            status: WorkBatchPreviewStatus(proof.status),
            appPath: proof.appPath.map(PathNormalizer.normalize),
            bundleID: proof.bundleID ?? proof.expectedBundleID,
            displayName: proof.displayName ?? proof.expectedDisplayName,
            pid: proof.pid,
            proofPath: proofPath,
            buildLogPath: proof.buildLogPath,
            failureReason: proof.failureReason,
            updatedAt: updatedAt,
        )
    }
}

struct WorkBatchPreviewProjection: Equatable {
    let status: WorkBatchPreviewStatus
    let label: String
    let isActionEnabled: Bool
    let actionLabel: String
    let reason: String?

    static func available(reason: String? = nil) -> WorkBatchPreviewProjection {
        WorkBatchPreviewProjection(
            status: .previewAvailable,
            label: "Preview available",
            isActionEnabled: true,
            actionLabel: "Open Preview",
            reason: reason,
        )
    }

    static func unavailable(reason: String) -> WorkBatchPreviewProjection {
        WorkBatchPreviewProjection(
            status: .previewUnavailable,
            label: "Preview unavailable",
            isActionEnabled: false,
            actionLabel: "Open Preview",
            reason: reason,
        )
    }

    static func building(reason: String? = nil) -> WorkBatchPreviewProjection {
        WorkBatchPreviewProjection(
            status: .previewBuilding,
            label: "Preview building",
            isActionEnabled: false,
            actionLabel: "Preview building",
            reason: reason,
        )
    }

    static func ready() -> WorkBatchPreviewProjection {
        WorkBatchPreviewProjection(
            status: .readyToInspect,
            label: "Ready to inspect",
            isActionEnabled: true,
            actionLabel: "Bring Preview Forward",
            reason: nil,
        )
    }

    static func failed(reason: String?) -> WorkBatchPreviewProjection {
        WorkBatchPreviewProjection(
            status: .previewFailed,
            label: "Preview failed",
            isActionEnabled: true,
            actionLabel: "Retry Preview",
            reason: reason,
        )
    }

    static func conflict(reason: String?) -> WorkBatchPreviewProjection {
        WorkBatchPreviewProjection(
            status: .previewUnavailable,
            label: "Preview already open",
            isActionEnabled: false,
            actionLabel: "Open Preview",
            reason: reason,
        )
    }
}

struct WorkBatchPreviewStateStore {
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
            .appendingPathComponent("previews.json")
    }

    func previewDirectoryURL(batchID: String) -> URL {
        fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("previews", isDirectory: true)
            .appendingPathComponent(Self.safeBatchDirectoryName(batchID), isDirectory: true)
    }

    func proofURL(batchID: String) -> URL {
        previewDirectoryURL(batchID: batchID).appendingPathComponent("latest-preview-proof.json")
    }

    func buildLogURL(batchID: String) -> URL {
        previewDirectoryURL(batchID: batchID).appendingPathComponent("latest-build.log")
    }

    func load() throws -> [WorkBatchPreviewRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([WorkBatchPreviewRecord].self, from: data)
    }

    func save(_ records: [WorkBatchPreviewRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records.sorted { $0.batchID < $1.batchID }).write(to: fileURL, options: .atomic)
    }

    func record(batchID: String) throws -> WorkBatchPreviewRecord? {
        try load().first { $0.batchID == batchID }
    }

    func upsert(_ record: WorkBatchPreviewRecord) throws {
        var records = try load()
        if let index = records.firstIndex(where: { $0.batchID == record.batchID }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records)
    }

    private static func safeBatchDirectoryName(_ batchID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = batchID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "batch" : value
    }
}

struct WorkBatchPreviewAppActivity {
    var runningApplicationResolver: MacOSPreviewRunningApplicationResolving = NSWorkspaceMacOSPreviewRunningApplicationResolver()

    func isMatchingRunning(record: WorkBatchPreviewRecord) -> Bool {
        matchingRunningApplication(record: record) != nil
    }

    func activate(record: WorkBatchPreviewRecord) -> Bool {
        guard let matching = matchingRunningApplication(record: record) else { return false }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: matching.bundleID)
            .first(where: { $0.processIdentifier == matching.pid })
        else {
            return false
        }
        _ = app.activate()
        return true
    }

    func isPreviewIdentityRunning(bundleID: String) -> Bool {
        !runningApplicationResolver.runningApplications(bundleIdentifier: bundleID).isEmpty
    }

    private func matchingRunningApplication(record: WorkBatchPreviewRecord) -> MatchingPreviewApplication? {
        guard record.status == .readyToInspect,
              let bundleID = record.bundleID,
              let expectedAppPath = record.appPath.map(PathNormalizer.normalize)
        else {
            return nil
        }

        return runningApplicationResolver.runningApplications(bundleIdentifier: bundleID)
            .first { running in
                guard let runningPath = MacOSPreviewAppPathResolver.normalizedBundlePath(
                    bundleURL: running.bundleURL,
                    executableURL: running.executableURL,
                )
                else { return false }
                if let pid = record.pid, running.pid != pid {
                    return false
                }
                return runningPath == expectedAppPath
            }
            .map { MatchingPreviewApplication(pid: $0.pid, bundleID: bundleID) }
    }

    private struct MatchingPreviewApplication {
        let pid: Int32
        let bundleID: String
    }
}

struct WorkBatchPreviewProjector {
    var fileManager: FileManager = .default
    var isPreviewRunning: (WorkBatchPreviewRecord) -> Bool = { record in
        WorkBatchPreviewAppActivity().isMatchingRunning(record: record)
    }

    var isPreviewIdentityRunning: (String) -> Bool = { bundleID in
        WorkBatchPreviewAppActivity().isPreviewIdentityRunning(bundleID: bundleID)
    }

    func projection(
        projectPath: String,
        batch _: WorkBatchRecord,
        binding: WorkBatchCockpitBinding?,
        previewRecord: WorkBatchPreviewRecord?,
    ) -> WorkBatchPreviewProjection? {
        guard isCapacitorPreviewCapable(at: projectPath) else { return nil }

        guard let binding else {
            return .unavailable(reason: "No batch worktree yet")
        }

        guard isCapacitorPreviewSourceCapable(at: binding.worktreePath) else {
            return .unavailable(reason: "Preview is not available in this batch worktree")
        }

        if let previewRecord,
           previewRecord.status == .readyToInspect,
           previewRecord.worktreePath.map(PathNormalizer.normalize) == PathNormalizer.normalize(binding.worktreePath),
           isPreviewRunning(previewRecord)
        {
            return .ready()
        }

        let previewBundleID = previewRecord?.bundleID ?? MacOSPreviewWorkRequest.capacitorPreview().expectedBundleID
        if isPreviewIdentityRunning(previewBundleID) {
            return .conflict(reason: "A Capacitor Preview is already open. Close it before opening this batch preview.")
        }

        guard let previewRecord else {
            return .available()
        }

        switch previewRecord.status {
        case .previewAvailable:
            return .available(reason: previewRecord.failureReason)
        case .previewUnavailable:
            return .available()
        case .previewBuilding:
            return .building(reason: previewRecord.failureReason)
        case .readyToInspect:
            return .available()
        case .previewFailed:
            if isAlreadyRunningConflict(previewRecord),
               let bundleID = previewRecord.bundleID,
               isPreviewIdentityRunning(bundleID)
            {
                return .conflict(reason: previewRecord.failureReason)
            }
            return .failed(reason: previewRecord.failureReason)
        }
    }

    func isCapacitorPreviewCapable(at path: String) -> Bool {
        isCapacitorPreviewBuildToolAvailable(projectPath: path)
            && isCapacitorPreviewSourceCapable(at: path)
    }

    func isCapacitorPreviewBuildToolAvailable(projectPath: String) -> Bool {
        fileManager.fileExists(atPath: buildScriptURL(projectPath: projectPath).path)
    }

    func isCapacitorPreviewSourceCapable(at path: String) -> Bool {
        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        // TODO: Replace this Capacitor-only proof hook with explicit project
        // preview capabilities once we design the generic provider model.
        let requiredPaths = [
            "apps/swift/Package.swift",
            "apps/swift/Sources/Capacitor/App.swift",
        ]
        return requiredPaths.allSatisfy { relativePath in
            fileManager.fileExists(atPath: rootURL.appendingPathComponent(relativePath).path)
        }
    }

    func buildScriptURL(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath, isDirectory: true)
            .appendingPathComponent("scripts/dev/build-preview-app.sh")
            .standardizedFileURL
    }

    private func isAlreadyRunningConflict(_ record: WorkBatchPreviewRecord) -> Bool {
        record.failureReason?.localizedCaseInsensitiveContains("already running") == true
    }
}
