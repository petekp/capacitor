import XCTest
@testable import ClaudeHUD

final class SessionStateManagerTests: XCTestCase {

    @MainActor
    func testReconcileDoesNotDownshiftWorkingWhenNotLocked() {
        let manager = SessionStateManager()

        let state = ProjectSessionState(
            state: .working,
            stateChangedAt: ISO8601DateFormatter().string(from: Date()),
            sessionId: "s1",
            workingOn: nil,
            context: nil,
            isLocked: false
        )

        let reconciled = manager.reconcileStateWithLock(state, at: "/Users/petepetrash/Code/claude-hud")
        XCTAssertEqual(reconciled.state, .working)
        XCTAssertFalse(reconciled.isLocked)
    }

    @MainActor
    func testReconcileStalesReadyToIdleWhenNotLocked() {
        let manager = SessionStateManager()

        let staleDate = Date().addingTimeInterval(-200) // > 120s
        let state = ProjectSessionState(
            state: .ready,
            stateChangedAt: ISO8601DateFormatter().string(from: staleDate),
            sessionId: "s1",
            workingOn: nil,
            context: nil,
            isLocked: false
        )

        let reconciled = manager.reconcileStateWithLock(state, at: "/Users/petepetrash/Code/claude-hud")
        XCTAssertEqual(reconciled.state, .idle)
        XCTAssertFalse(reconciled.isLocked)
    }
}
