@testable import Capacitor
import XCTest

@MainActor
final class RuntimeHealthStateTests: XCTestCase {
    func testRefreshStoresStatusAndRoutingRollout() async {
        let gateway = RuntimeHealthStubGateway(
            healthStatus: ShellRuntimeHealthStatus(
                isEnabled: true,
                isHealthy: true,
                message: "healthy",
                pid: 42,
                version: "1.2.3",
                routingRollout: makeRoutingRollout(),
            ),
        )
        let state = RuntimeHealthState(runtimeSupervisor: RuntimeSupervisor(runtimeGateway: gateway))

        state.refresh()
        let expectation = expectation(description: "runtime health refreshed")
        _Concurrency.Task { @MainActor in
            while state.status == nil {
                await _Concurrency.Task.yield()
            }
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(state.status?.pid, 42)
        XCTAssertEqual(state.status?.version, "1.2.3")
        XCTAssertEqual(state.routingRollout?.comparisons, 7)
    }

    func testEnsureRuntimeReadyMarksAttemptForTesting() {
        let state = RuntimeHealthState(
            runtimeSupervisor: RuntimeSupervisor(runtimeGateway: RuntimeHealthStubGateway()),
        )

        state.ensureRuntimeReady()

        XCTAssertTrue(state.didAttemptHealthCheckForTesting)
    }
}

private func makeRoutingRollout() -> RuntimeRoutingRollout {
    let data = Data(
        """
        {
          "agreement_gate_target": 0.9,
          "min_comparisons_required": 5,
          "min_window_hours_required": 24,
          "comparisons": 7,
          "volume_gate_met": true,
          "window_gate_met": true,
          "status_agreement_rate": 0.95,
          "target_agreement_rate": 0.95,
          "first_comparison_at": "2026-03-06T00:00:00Z",
          "last_comparison_at": "2026-03-06T01:00:00Z",
          "window_elapsed_hours": 24,
          "status_gate_met": true,
          "target_gate_met": true,
          "status_row_default_ready": true,
          "launcher_default_ready": true
        }
        """.utf8,
    )

    return try! JSONDecoder().decode(RuntimeRoutingRollout.self, from: data)
}

private struct RuntimeHealthStubGateway: RuntimeGateway {
    var healthStatus: ShellRuntimeHealthStatus = .init(
        isEnabled: false,
        isHealthy: false,
        message: "offline",
        pid: nil,
        version: nil,
        routingRollout: nil,
    )

    func fetchObservation(correlationId _: String?) async throws -> ShellRuntimeObservation {
        ShellRuntimeObservation(projectStates: [], sessions: [], shellState: ShellCwdState(version: 1, shells: [:]))
    }

    func fetchHealthStatus() async throws -> ShellRuntimeHealthStatus {
        healthStatus
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
