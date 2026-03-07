import Foundation

@MainActor
@Observable
final class RuntimeHealthState {
    private let runtimeSupervisor: RuntimeSupervisor
    private let emitTelemetry: (_ event: String, _ message: String, _ payload: [String: Any]) -> Void

    private(set) var status: RuntimeStatus?
    private(set) var routingRollout: RuntimeRoutingRollout?
    private(set) var didAttemptHealthCheckForTesting = false

    init(
        runtimeSupervisor: RuntimeSupervisor,
        emitTelemetry: @escaping (_ event: String, _ message: String, _ payload: [String: Any]) -> Void = { event, message, payload in
            Telemetry.emit(event, message, payload: payload)
        },
    ) {
        self.runtimeSupervisor = runtimeSupervisor
        self.emitTelemetry = emitTelemetry
    }

    func ensureRuntimeReady() {
        didAttemptHealthCheckForTesting = true
        refresh()
    }

    func refresh() {
        _Concurrency.Task { [weak self] in
            let healthStatus = await self?.runtimeSupervisor.refreshHealthStatus()
            await MainActor.run {
                guard let self, let healthStatus else { return }
                self.status = RuntimeStatus(
                    isEnabled: healthStatus.isEnabled,
                    isHealthy: healthStatus.isHealthy,
                    message: healthStatus.message,
                    pid: healthStatus.pid,
                    version: healthStatus.version,
                )
                self.routingRollout = healthStatus.routingRollout

                if !healthStatus.isEnabled {
                    self.emitTelemetry("runtime_health", "Runtime disabled", [
                        "enabled": false,
                    ])
                } else if healthStatus.isHealthy {
                    self.emitTelemetry("runtime_health", "Runtime healthy", [
                        "enabled": true,
                        "healthy": true,
                        "pid": healthStatus.pid ?? -1,
                        "version": healthStatus.version ?? "unknown",
                    ])
                } else {
                    self.emitTelemetry("runtime_health", "Runtime unhealthy", [
                        "enabled": true,
                        "healthy": false,
                    ])
                }
            }
        }
    }
}
