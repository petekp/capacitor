import Foundation

struct LiveRuntimeGateway: RuntimeGateway {
    private let runtimeClient: RuntimeClient

    init(runtimeClient: RuntimeClient = .shared) {
        self.runtimeClient = runtimeClient
    }

    func fetchObservation(correlationId: String?) async throws -> ShellRuntimeObservation {
        let snapshot = try await runtimeClient.fetchRuntimeSnapshot(correlationId: correlationId)
        return ShellRuntimeObservation(
            projectStates: snapshot.projectStates,
            sessions: snapshot.sessions,
            shellState: snapshot.shellState,
        )
    }

    func fetchHealthStatus() async throws -> ShellRuntimeHealthStatus {
        guard runtimeClient.isEnabled else {
            return ShellRuntimeHealthStatus(
                isEnabled: false,
                isHealthy: false,
                message: "Runtime disabled",
                pid: nil,
                version: nil,
                routingRollout: nil,
            )
        }

        do {
            let health = try await runtimeClient.fetchHealth()
            return ShellRuntimeHealthStatus(
                isEnabled: true,
                isHealthy: health.status == "ok",
                message: "Core runtime snapshot mode",
                pid: health.pid,
                version: health.version,
                routingRollout: health.routing?.rollout,
            )
        } catch {
            return ShellRuntimeHealthStatus(
                isEnabled: true,
                isHealthy: false,
                message: "Core runtime snapshot unavailable",
                pid: nil,
                version: nil,
                routingRollout: nil,
            )
        }
    }

    func fetchProjection(correlationId: String?) async throws -> ShellRuntimeProjection {
        let observation = try await fetchObservation(correlationId: correlationId)
        return Self.projection(from: observation)
    }

    private static func projection(from observation: ShellRuntimeObservation) -> ShellRuntimeProjection {
        let projects = observation.projectStates.map(projectReference)
        let activeProject = observation.projectStates
            .sorted { lhs, rhs in
                if lhs.activeCount == rhs.activeCount {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.activeCount > rhs.activeCount
            }
            .first(where: { $0.activeCount > 0 || $0.hasSession })
            .map(projectReference)

        return ShellRuntimeProjection(
            generatedAt: Date(),
            activeProject: activeProject,
            projects: projects,
            sessionsInFlight: observation.sessions.count,
            healthSummary: "\(observation.sessions.count) sessions across \(observation.projectStates.count) projects",
        )
    }

    private static func projectReference(_ state: RuntimeProjectState) -> ShellProjectReference {
        ShellProjectReference(
            id: state.projectId ?? state.projectPath,
            displayName: (state.projectPath as NSString).lastPathComponent,
            path: state.projectPath,
            workspaceId: state.workspaceId,
        )
    }
}
