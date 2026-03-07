@testable import Capacitor
import XCTest

@MainActor
final class RuntimeAutomationComposerTests: XCTestCase {
    func testRefreshLoopAppliesExpectedTickCadence() {
        var sessionRefreshes = 0
        var ideaChecks = 0
        var setupRefreshes = 0
        var hookServerChecks = 0
        var runtimeHealthRefreshes = 0
        var dashboardReloads = 0
        var timer: RuntimeAutomationComposerTestTimer?

        let controller = RuntimeAutomationComposer.makeController(
            writeEngine: { _ in },
            ensureRuntimeReady: {},
            configureProjectDetails: { _ in },
            reloadDashboardAfterBootstrap: {},
            refreshSetupDiagnosticsAfterBootstrap: {},
            startHookServer: {},
            startRefreshLoop: {},
            startShellTracking: {},
            writeError: { _ in },
            writeIsLoading: { _ in },
            refreshSessionStates: { sessionRefreshes += 1 },
            ideaCaptureEnabled: { true },
            checkIdeasFileChanges: { ideaChecks += 1 },
            refreshSetupDiagnostics: { setupRefreshes += 1 },
            checkHookServerHealth: { hookServerChecks += 1 },
            refreshRuntimeHealth: { runtimeHealthRefreshes += 1 },
            reloadDashboardOnInterval: { dashboardReloads += 1 },
            scheduleRepeatingTimer: { _, block in
                let created = RuntimeAutomationComposerTestTimer(onInvalidate: {}, tick: block)
                timer = created
                return created
            },
        )

        controller.startRefreshLoop()
        for _ in 0 ..< 15 {
            timer?.fire()
        }

        XCTAssertEqual(sessionRefreshes, 15)
        XCTAssertEqual(ideaChecks, 15)
        XCTAssertEqual(setupRefreshes, 3)
        XCTAssertEqual(hookServerChecks, 3)
        XCTAssertEqual(runtimeHealthRefreshes, 1)
        XCTAssertEqual(dashboardReloads, 1)
    }
}

@MainActor
private final class RuntimeAutomationComposerTestTimer: RuntimeAutomationTimer {
    private let onInvalidate: () -> Void
    private let tick: () -> Void

    init(onInvalidate: @escaping () -> Void, tick: @escaping () -> Void) {
        self.onInvalidate = onInvalidate
        self.tick = tick
    }

    func invalidate() {
        onInvalidate()
    }

    func fire() {
        tick()
    }
}
