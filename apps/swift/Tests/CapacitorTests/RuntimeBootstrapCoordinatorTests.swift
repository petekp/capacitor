@testable import Capacitor
import XCTest

@MainActor
final class RuntimeBootstrapCoordinatorTests: XCTestCase {
    func testBootstrapRunsPostBootstrapSequenceInOrder() async {
        var events: [String] = []
        let coordinator = RuntimeBootstrapCoordinator(
            runtimeFactory: {
                events.append("construct")
                return try CoreRuntime()
            },
            writeEngine: { _ in events.append("writeEngine") },
            ensureRuntimeReady: { events.append("ensureRuntimeReady") },
            configureProjectDetails: { _ in events.append("configureProjectDetails") },
            reloadDashboard: { events.append("reloadDashboard") },
            refreshSetupDiagnostics: { events.append("refreshSetupDiagnostics") },
            startHookServer: { events.append("startHookServer") },
            startRefreshLoop: { events.append("startRefreshLoop") },
            startShellTracking: { events.append("startShellTracking") },
            writeError: { _ in events.append("writeError") },
            writeIsLoading: { _ in events.append("writeIsLoading") },
        )

        await coordinator.bootstrap()

        XCTAssertEqual(
            events,
            [
                "construct",
                "writeEngine",
                "ensureRuntimeReady",
                "configureProjectDetails",
                "reloadDashboard",
                "refreshSetupDiagnostics",
                "startHookServer",
                "startRefreshLoop",
                "startShellTracking",
            ],
        )
    }

    func testBootstrapWritesErrorAndClearsLoadingOnFailure() async {
        struct ExpectedError: LocalizedError {
            var errorDescription: String? {
                "boom"
            }
        }

        var errorMessage: String?
        var isLoading: Bool?
        let coordinator = RuntimeBootstrapCoordinator(
            runtimeFactory: { throw ExpectedError() },
            writeEngine: { _ in XCTFail("should not write engine on failure") },
            ensureRuntimeReady: {},
            configureProjectDetails: { _ in },
            reloadDashboard: {},
            refreshSetupDiagnostics: {},
            startHookServer: {},
            startRefreshLoop: {},
            startShellTracking: {},
            writeError: { errorMessage = $0 },
            writeIsLoading: { isLoading = $0 },
        )

        await coordinator.bootstrap()

        XCTAssertEqual(errorMessage, "boom")
        XCTAssertEqual(isLoading, false)
    }
}
