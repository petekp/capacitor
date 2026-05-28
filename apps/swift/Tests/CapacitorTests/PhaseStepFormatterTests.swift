@testable import Capacitor
import XCTest

final class PhaseStepFormatterTests: XCTestCase {
    // MARK: - Active run with phases

    func testActiveRunShowsCurrentPhase() {
        let phases = makePhases(["Research", "Implementation", "Review"])
        let result = PhaseStepFormatter.format(
            phases: phases,
            currentPhaseIndex: 1,
            runStatus: .active,
            statusMessage: nil,
        )
        XCTAssertEqual(result, "2/3 Implementation")
    }

    func testActiveRunFirstPhase() {
        let phases = makePhases(["Scope", "Plan", "Build", "Test", "Ship"])
        let result = PhaseStepFormatter.format(
            phases: phases,
            currentPhaseIndex: 0,
            runStatus: .active,
            statusMessage: nil,
        )
        XCTAssertEqual(result, "1/5 Scope")
    }

    // MARK: - Terminal states

    func testCompletedRunShowsTotalComplete() {
        let phases = makePhases(["Research", "Implementation", "Review"])
        let result = PhaseStepFormatter.format(
            phases: phases,
            currentPhaseIndex: 2,
            runStatus: .completed,
            statusMessage: nil,
        )
        XCTAssertEqual(result, "3/3 Complete")
    }

    func testFailedRunShowsFailurePhase() {
        let phases = makePhases(["Research", "Implementation", "Review"])
        let result = PhaseStepFormatter.format(
            phases: phases,
            currentPhaseIndex: 1,
            runStatus: .failed,
            statusMessage: nil,
        )
        XCTAssertEqual(result, "2/3 Failed at Implementation")
    }

    func testCancelledRunShowsCancelledPhase() {
        let phases = makePhases(["Research", "Implementation", "Review"])
        let result = PhaseStepFormatter.format(
            phases: phases,
            currentPhaseIndex: 0,
            runStatus: .cancelled,
            statusMessage: nil,
        )
        XCTAssertEqual(result, "1/3 Cancelled")
    }

    // MARK: - Fallbacks

    func testEmptyPhasesFallsBackToStatusMessage() {
        let result = PhaseStepFormatter.format(
            phases: [],
            currentPhaseIndex: 0,
            runStatus: .active,
            statusMessage: "Doing something",
        )
        XCTAssertEqual(result, "Doing something")
    }

    func testEmptyPhasesWithNilStatusMessageReturnsNil() {
        let result = PhaseStepFormatter.format(
            phases: [],
            currentPhaseIndex: 0,
            runStatus: .active,
            statusMessage: nil,
        )
        XCTAssertNil(result)
    }

    func testOutOfBoundsIndexClampsToLastPhase() {
        let phases = makePhases(["Research", "Implementation"])
        let result = PhaseStepFormatter.format(
            phases: phases,
            currentPhaseIndex: 99,
            runStatus: .active,
            statusMessage: nil,
        )
        XCTAssertEqual(result, "2/2 Implementation")
    }

    // MARK: - Helpers

    private func makePhases(_ names: [String]) -> [RuntimePhaseInstance] {
        names.enumerated().map { index, name in
            RuntimePhaseInstance(
                id: "phase-\(index)",
                name: name,
                status: index == 0 ? .active : .pending,
                startedAt: nil,
                completedAt: nil,
            )
        }
    }
}
