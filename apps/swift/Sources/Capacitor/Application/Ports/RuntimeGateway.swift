import Foundation

protocol RuntimeGateway {
    func fetchObservation(correlationId: String?) async throws -> ShellRuntimeObservation
    func fetchHealthStatus() async throws -> ShellRuntimeHealthStatus
    func fetchProjection(correlationId: String?) async throws -> ShellRuntimeProjection
}
