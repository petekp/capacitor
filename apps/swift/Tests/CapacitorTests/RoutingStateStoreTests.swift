@testable import Capacitor
import XCTest

@MainActor
final class RoutingStateStoreTests: XCTestCase {
    func testApplyRuntimeRoutingViewsStoresRoutesByWorkspace() {
        let store = RoutingStateStore()
        let route = RuntimeRoutingView(
            workspaceId: "workspace-core",
            projectPath: "/tmp/core-project",
            status: .attached,
            target: CoreRoutingTarget(kind: "tmux_session", sessionName: "caps"),
            reasonCode: "TMUX_SESSION_ATTACHED",
            reason: "Attached tmux session",
            updatedAt: "2026-03-11T21:00:00Z",
        )

        store.applyRuntimeRoutingViews([route], correlationId: "routing-apply")

        XCTAssertEqual(
            store.routingView(projectPath: "/tmp/core-project", workspaceId: "workspace-core"),
            route,
        )
    }

    func testRoutingViewFallsBackToProjectPathLookup() {
        let store = RoutingStateStore()
        let route = RuntimeRoutingView(
            workspaceId: "workspace-core",
            projectPath: "/tmp/core-project",
            status: .attached,
            target: CoreRoutingTarget(kind: "tmux_session", sessionName: "caps"),
            reasonCode: "TMUX_SESSION_ATTACHED",
            reason: "Attached tmux session",
            updatedAt: "2026-03-11T21:00:00Z",
        )

        store.applyRuntimeRoutingViews([route], correlationId: "routing-project-path")

        XCTAssertEqual(
            store.routingView(projectPath: "/tmp/core-project/", workspaceId: nil),
            route,
        )
    }

    func testClearRuntimeRoutingViewsEmptiesState() {
        let store = RoutingStateStore()
        store.applyRuntimeRoutingViews([
            RuntimeRoutingView(
                workspaceId: "workspace-core",
                projectPath: "/tmp/core-project",
                status: .attached,
                target: CoreRoutingTarget(kind: "tmux_session", sessionName: "caps"),
                reasonCode: "TMUX_SESSION_ATTACHED",
                reason: "Attached tmux session",
                updatedAt: "2026-03-11T21:00:00Z",
            ),
        ], correlationId: "routing-before-clear")

        store.clearRuntimeRoutingViews(correlationId: "routing-clear")

        XCTAssertTrue(store.routesByWorkspaceID.isEmpty)
    }
}
