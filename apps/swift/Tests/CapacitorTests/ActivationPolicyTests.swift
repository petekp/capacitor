@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class ActivationPolicyTests: XCTestCase {
    func testResolveIntentPrefersRoutedTerminalAppAndCarriesRouteHints() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: nil,
            sessionName: nil,
            route: RuntimeRoutingView(
                workspaceId: "workspace-capacitor",
                projectPath: "/Users/pete/Code/capacitor",
                status: .attached,
                target: CoreRoutingTarget(
                    kind: "tmux_pane",
                    terminalApp: "ghostty",
                    sessionName: "capacitor",
                    paneId: "%12",
                    hostTty: "/dev/ttys017",
                ),
                reasonCode: "TMUX_PANE_ATTACHED",
                reason: "Attached tmux pane",
                updatedAt: "2026-03-13T18:00:00Z",
            ),
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.terminalApp.app, .ghostty)
        XCTAssertEqual(intent.terminalApp.source, .runtimeRoute)
        XCTAssertEqual(intent.sessionName, "capacitor")
        XCTAssertEqual(intent.paneId, "%12")
        XCTAssertEqual(intent.hostTty, "/dev/ttys017")
    }

    func testResolveIntentFallsBackWhenAttachedRouteHasNoTerminalApp() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: nil,
            sessionName: "capacitor",
            route: RuntimeRoutingView(
                workspaceId: "workspace-capacitor",
                projectPath: "/Users/pete/Code/capacitor",
                status: .attached,
                target: CoreRoutingTarget(
                    kind: "tmux_pane",
                    terminalApp: nil,
                    sessionName: "capacitor",
                    paneId: "%2",
                    hostTty: "/dev/ttys017",
                ),
                reasonCode: "TMUX_PANE_ATTACHED",
                reason: "Attached tmux pane without host app identity",
                updatedAt: "2026-03-13T18:00:00Z",
            ),
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.terminalApp.app, .terminal)
        XCTAssertEqual(intent.terminalApp.source, .fallback)
        XCTAssertEqual(intent.sessionName, "capacitor")
        XCTAssertEqual(intent.paneId, "%2")
        XCTAssertEqual(intent.hostTty, "/dev/ttys017")
    }

    func testResolveIntentUsesExplicitFallbackWhenNoRouteOrShellEvidenceExists() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: nil,
            sessionName: nil,
            route: nil,
            fallbackTerminalApp: { .iTerm },
        )

        XCTAssertEqual(intent.terminalApp.app, .iTerm)
        XCTAssertEqual(intent.terminalApp.source, .fallback)
        XCTAssertNil(intent.sessionName)
        XCTAssertNil(intent.paneId)
        XCTAssertNil(intent.hostTty)
    }

    func testResolveIntentIgnoresShellEvidenceClientTtyMatchWhenRouteMissing() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: "/dev/ttys002",
            sessionName: "caps",
            route: nil,
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.terminalApp.app, .terminal)
        XCTAssertEqual(intent.terminalApp.source, .fallback)
        XCTAssertEqual(intent.sessionName, "caps")
        XCTAssertNil(intent.paneId)
        XCTAssertNil(intent.hostTty)
    }

    func testResolveIntentIgnoresShellEvidenceSessionMatchWhenRouteMissing() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: nil,
            sessionName: "caps",
            route: nil,
            fallbackTerminalApp: { .iTerm },
        )

        XCTAssertEqual(intent.terminalApp.app, .iTerm)
        XCTAssertEqual(intent.terminalApp.source, .fallback)
        XCTAssertEqual(intent.sessionName, "caps")
        XCTAssertNil(intent.paneId)
        XCTAssertNil(intent.hostTty)
    }

    func testResolveIntentIgnoresShellEvidenceProjectPathMatchWhenRouteMissing() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: nil,
            sessionName: "capacitor",
            route: nil,
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.terminalApp.app, .terminal)
        XCTAssertEqual(intent.terminalApp.source, .fallback)
        XCTAssertEqual(intent.sessionName, "capacitor")
        XCTAssertNil(intent.paneId)
        XCTAssertNil(intent.hostTty)
    }

    func testResolveIntentDoesNotRecoverTmuxPaneWhenRouteMissing() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/sanctuary",
            clientTty: "/dev/ttys001",
            sessionName: "shared",
            route: nil,
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.terminalApp.app, .terminal)
        XCTAssertEqual(intent.terminalApp.source, .fallback)
        XCTAssertEqual(intent.sessionName, "shared")
        XCTAssertNil(intent.paneId)
        XCTAssertNil(intent.hostTty)
    }
}
