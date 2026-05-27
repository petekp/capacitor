@testable import Capacitor
import XCTest

final class ReceiptLoopRunStateTests: XCTestCase {
    func testRunningReceiptLoopProducesRunLikeCommitmentState() throws {
        let state = ReceiptLoopRunState(
            id: "receipt-run-1",
            projectPath: "/tmp/receipt",
            ideaId: "idea-1",
            ideaTitle: "Improve checkpoint evidence packets",
            status: .running,
            createdAt: "2027-01-15T07:59:00Z",
            updatedAt: "2027-01-15T08:00:00Z",
        )

        let run = state.runtimeRunState()
        let now = try XCTUnwrap(parseISO8601Date("2027-01-15T08:05:00Z"))

        XCTAssertEqual(run.id, "receipt-run-1")
        XCTAssertEqual(run.methodId, CircuitReceiptGoalPacketMethod.id)
        XCTAssertEqual(run.methodName, "Claude Receipt Goal Packet")
        XCTAssertEqual(run.status, "active")
        XCTAssertEqual(
            run.statusMessage,
            "Working on: Improve checkpoint evidence packets. Expected next signal: receipt. Healthy silence window: ~20m",
        )
        XCTAssertEqual(
            ProjectRunVisualStateResolver.visualState(for: run, now: now),
            .working(statusMessage: run.statusMessage),
        )
    }

    func testCompletedReceiptLoopProducesTerminalRunLikeState() {
        let state = ReceiptLoopRunState(
            id: "receipt-run-done",
            projectPath: "/tmp/receipt",
            ideaId: "idea-1",
            ideaTitle: "Tighten receipt loop",
            status: .completed,
            createdAt: "2027-01-15T07:59:00Z",
            updatedAt: "2027-01-15T08:00:00Z",
        )

        let run = state.runtimeRunState()

        XCTAssertEqual(run.status, "completed")
        XCTAssertEqual(run.statusMessage, "Receipt captured for Tighten receipt loop")
    }
}
