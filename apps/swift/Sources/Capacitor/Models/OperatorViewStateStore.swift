import Foundation

actor OperatorViewStateStore {
    nonisolated static var defaultURL: URL {
        CapacitorProjectPaths.capacitorRoot()
            .appendingPathComponent("operator-view-state.json")
    }

    struct Snapshot: Codable, Equatable {
        static let empty = Snapshot()

        var schemaVersion: Int
        var lastAppOpenedAt: Date?
        var lastSeenCheckpoints: [String: Date]
        var lastSeenProjects: [String: Date]
        var lastSeenRuns: [String: Date]

        init(
            schemaVersion: Int = 1,
            lastAppOpenedAt: Date? = nil,
            lastSeenCheckpoints: [String: Date] = [:],
            lastSeenProjects: [String: Date] = [:],
            lastSeenRuns: [String: Date] = [:],
        ) {
            self.schemaVersion = schemaVersion
            self.lastAppOpenedAt = lastAppOpenedAt
            self.lastSeenCheckpoints = lastSeenCheckpoints
            self.lastSeenProjects = lastSeenProjects
            self.lastSeenRuns = lastSeenRuns
        }
    }

    private let stateURL: URL
    private let fileManager: FileManager
    private var cachedSnapshot: Snapshot?

    init(
        stateURL: URL = OperatorViewStateStore.defaultURL,
        fileManager: FileManager = .default,
    ) {
        self.stateURL = stateURL
        self.fileManager = fileManager
    }

    func load() throws -> Snapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }

        guard fileManager.fileExists(atPath: stateURL.path) else {
            cachedSnapshot = .empty
            return .empty
        }

        let data = try Data(contentsOf: stateURL)
        let snapshot = try Self.decoder.decode(Snapshot.self, from: data)
        cachedSnapshot = snapshot
        return snapshot
    }

    func recordAppOpened(at date: Date = Date()) throws {
        var snapshot = try load()
        snapshot.lastAppOpenedAt = date
        try save(snapshot)
    }

    func markProjectSeen(_ projectPath: String, at date: Date = Date()) throws {
        var snapshot = try load()
        snapshot.lastSeenProjects[PathNormalizer.normalize(projectPath)] = date
        try save(snapshot)
    }

    func markRunSeen(runID: String, at date: Date = Date()) throws {
        var snapshot = try load()
        snapshot.lastSeenRuns[runID] = date
        try save(snapshot)
    }

    func markCheckpointSeen(checkpointID: String, at date: Date = Date()) throws {
        var snapshot = try load()
        snapshot.lastSeenCheckpoints[checkpointID] = date
        try save(snapshot)
    }

    private func save(_ snapshot: Snapshot) throws {
        cachedSnapshot = snapshot
        let directory = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: stateURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
