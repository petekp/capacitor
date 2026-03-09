import Foundation

protocol RuntimeSnapshotReading {
    var isEnabled: Bool { get }
    func fetchRuntimeSnapshot(correlationId: String?) async throws -> RuntimeSnapshot
    func fetchHealth() async throws -> RuntimeHealth
    func fetchSessions() async throws -> [RuntimeSession]
}

final class CoreRuntimeSnapshotReader: RuntimeSnapshotReading {
    static let shared = CoreRuntimeSnapshotReader()

    private let runtimeClient: RuntimeClient

    init(runtimeClient: RuntimeClient = .shared) {
        self.runtimeClient = runtimeClient
    }

    var isEnabled: Bool {
        runtimeClient.isEnabled
    }

    func fetchRuntimeSnapshot(correlationId: String?) async throws -> RuntimeSnapshot {
        try await runtimeClient.fetchRuntimeSnapshot(correlationId: correlationId)
    }

    func fetchHealth() async throws -> RuntimeHealth {
        try await runtimeClient.fetchHealth()
    }

    func fetchSessions() async throws -> [RuntimeSession] {
        try await runtimeClient.fetchSessions()
    }
}
