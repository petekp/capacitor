@testable import Capacitor
import XCTest

@MainActor
final class RuntimeSupervisorTests: XCTestCase {
    func testRefreshObservationStoresObservationAndClearsError() async {
        let gateway = StubRuntimeGateway(
            observation: ShellRuntimeObservation(
                projectStates: [
                    RuntimeProjectState(
                        projectId: "project-1",
                        workspaceId: "workspace-1",
                        projectPath: "/tmp/capacitor",
                        state: "working",
                        updatedAt: "2026-03-06T00:00:00Z",
                        stateChangedAt: "2026-03-06T00:00:00Z",
                        sessionId: "session-1",
                        latestSessionId: "session-1",
                        sessionCount: 1,
                        activeCount: 1,
                        hasSession: true,
                    ),
                ],
                sessions: [],
                shellState: ShellCwdState(version: 1, shells: [:]),
            ),
        )
        let supervisor = RuntimeSupervisor(runtimeGateway: gateway)

        let result = await supervisor.refreshObservation(correlationId: "runtime-supervisor-test")

        guard case let .success(observation) = result else {
            return XCTFail("Expected successful runtime observation refresh")
        }
        XCTAssertEqual(observation.projectStates.first?.projectPath, "/tmp/capacitor")
        XCTAssertEqual(supervisor.observation?.projectStates.first?.projectPath, "/tmp/capacitor")
        XCTAssertNil(supervisor.lastError)
    }

    func testRefreshObservationStoresFailure() async {
        let gateway = StubRuntimeGateway(error: RuntimeClientError.timeout)
        let supervisor = RuntimeSupervisor(runtimeGateway: gateway)

        let result = await supervisor.refreshObservation(correlationId: "runtime-supervisor-failure")

        guard case let .failure(error) = result else {
            return XCTFail("Expected failed runtime observation refresh")
        }
        XCTAssertTrue(error is RuntimeClientError)
        XCTAssertNil(supervisor.observation)
        XCTAssertNotNil(supervisor.lastError)
    }

    func testRefreshHealthStatusStoresHealthAndClearsError() async {
        let gateway = StubRuntimeGateway(
            healthStatus: ShellRuntimeHealthStatus(
                isEnabled: true,
                isHealthy: true,
                message: "Core runtime snapshot mode",
                pid: 42,
                version: "1.0.0",
                routingRollout: nil,
            ),
        )
        let supervisor = RuntimeSupervisor(runtimeGateway: gateway)

        let status = await supervisor.refreshHealthStatus()

        XCTAssertEqual(status.pid, 42)
        XCTAssertEqual(supervisor.healthStatus?.version, "1.0.0")
        XCTAssertNil(supervisor.lastError)
    }
}

private struct StubRuntimeGateway: RuntimeGateway {
    let observation: ShellRuntimeObservation?
    let healthStatus: ShellRuntimeHealthStatus?
    let error: Error?

    init(
        observation: ShellRuntimeObservation? = nil,
        healthStatus: ShellRuntimeHealthStatus? = nil,
        error: Error? = nil,
    ) {
        self.observation = observation
        self.healthStatus = healthStatus
        self.error = error
    }

    func fetchObservation(correlationId _: String?) async throws -> ShellRuntimeObservation {
        if let error {
            throw error
        }
        return try XCTUnwrap(observation)
    }

    func fetchHealthStatus() async throws -> ShellRuntimeHealthStatus {
        if let error {
            throw error
        }
        return try XCTUnwrap(healthStatus)
    }

    func fetchProjection(correlationId _: String?) async throws -> ShellRuntimeProjection {
        ShellRuntimeProjection(
            generatedAt: Date(),
            activeProject: nil,
            projects: [],
            sessionsInFlight: 0,
            healthSummary: "stub",
        )
    }
}
