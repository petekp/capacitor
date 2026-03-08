@testable import Capacitor
import XCTest

@MainActor
final class RuntimeAutomationControllerTests: XCTestCase {
    func testStartBootstrapRunsBootstrapAndMarksControllerState() async {
        var bootstrapRuns = 0
        let controller = RuntimeAutomationController(
            bootstrapRuntime: {
                bootstrapRuns += 1
            },
            onTimerTick: {},
            scheduleRepeatingTimer: { _, block in
                TestTimer(onInvalidate: {}, tick: block)
            }
        )

        controller.startBootstrap()
        for _ in 0 ..< 5 {
            await _Concurrency.Task.yield()
        }

        XCTAssertEqual(bootstrapRuns, 1)
        XCTAssertTrue(controller.didScheduleBootstrapForTesting)
    }

    func testStartRefreshLoopTicksInjectedWorkAndStopInvalidatesTimer() {
        var tickCount = 0
        var invalidated = false
        var timer: TestTimer?
        let controller = RuntimeAutomationController(
            bootstrapRuntime: {},
            onTimerTick: {
                tickCount += 1
            },
            scheduleRepeatingTimer: { _, block in
                let created = TestTimer(onInvalidate: {
                    invalidated = true
                }, tick: block)
                timer = created
                return created
            }
        )

        controller.startRefreshLoop()
        XCTAssertTrue(controller.didStartRefreshTimerForTesting)

        timer?.fire()
        XCTAssertEqual(tickCount, 1)

        controller.stopAutomation()
        XCTAssertTrue(invalidated)
    }
}

@MainActor
private final class TestTimer: RuntimeAutomationTimer {
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
