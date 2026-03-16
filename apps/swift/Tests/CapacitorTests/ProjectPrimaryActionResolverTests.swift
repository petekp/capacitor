@testable import Capacitor
import XCTest

final class ProjectPrimaryActionResolverTests: XCTestCase {
    func testRoutesToNativeReviewWhenDelegationNeedsReview() {
        let action = ProjectPrimaryActionResolver.resolve(
            delegationState: RuntimeDelegationState(
                projectPath: "/tmp/core-project",
                workerId: "worker-1",
                ideaId: "idea-1",
                worktreeName: "delegation-worker-1",
                worktreePath: "/tmp/core-project/.capacitor/worktrees/delegation-worker-1",
                sessionId: "worker-session-1",
                status: "review_needed",
                startedAt: "2026-02-28T19:00:00Z",
                updatedAt: "2026-02-28T19:05:00Z",
                currentReview: RuntimeDelegationReview(
                    milestoneId: "01",
                    briefPath: "/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/brief.md",
                    manifestPath: "/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/manifest.json",
                    requestedAt: "2026-02-28T19:05:00Z",
                ),
            ),
            isDelegationEnabled: true,
        )

        XCTAssertEqual(action, .openDelegationReview)
    }

    func testFallsBackToTerminalWhenDelegationLoopIsDisabled() {
        let action = ProjectPrimaryActionResolver.resolve(
            delegationState: RuntimeDelegationState(
                projectPath: "/tmp/core-project",
                workerId: "worker-1",
                ideaId: "idea-1",
                worktreeName: "delegation-worker-1",
                worktreePath: "/tmp/core-project/.capacitor/worktrees/delegation-worker-1",
                sessionId: "worker-session-1",
                status: "review_needed",
                startedAt: "2026-02-28T19:00:00Z",
                updatedAt: "2026-02-28T19:05:00Z",
                currentReview: RuntimeDelegationReview(
                    milestoneId: "01",
                    briefPath: "/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/brief.md",
                    manifestPath: "/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/manifest.json",
                    requestedAt: "2026-02-28T19:05:00Z",
                ),
            ),
            isDelegationEnabled: false,
        )

        XCTAssertEqual(action, .openTerminal)
    }
}
