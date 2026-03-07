import Foundation

@MainActor
final class RuntimeSupervisor {
    private let runtimeGateway: any RuntimeGateway

    private(set) var observation: ShellRuntimeObservation?
    private(set) var healthStatus: ShellRuntimeHealthStatus?
    private(set) var projection: ShellRuntimeProjection?
    private(set) var lastError: Error?

    init(runtimeGateway: any RuntimeGateway) {
        self.runtimeGateway = runtimeGateway
    }

    func refreshObservation(correlationId: String? = nil) async -> Result<ShellRuntimeObservation, Error> {
        do {
            let observation = try await runtimeGateway.fetchObservation(correlationId: correlationId)
            self.observation = observation
            lastError = nil
            return .success(observation)
        } catch {
            observation = nil
            lastError = error
            return .failure(error)
        }
    }

    func refresh(correlationId: String? = nil) async {
        do {
            projection = try await runtimeGateway.fetchProjection(correlationId: correlationId)
            lastError = nil
        } catch {
            lastError = error
        }
    }

    func refreshHealthStatus() async -> ShellRuntimeHealthStatus {
        do {
            let status = try await runtimeGateway.fetchHealthStatus()
            healthStatus = status
            lastError = nil
            return status
        } catch {
            let fallback = ShellRuntimeHealthStatus(
                isEnabled: true,
                isHealthy: false,
                message: "Core runtime snapshot unavailable",
                pid: nil,
                version: nil,
                routingRollout: nil,
            )
            healthStatus = fallback
            lastError = error
            return fallback
        }
    }
}
