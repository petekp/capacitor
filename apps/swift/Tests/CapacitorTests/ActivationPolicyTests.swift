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
                status: "attached",
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
            shellState: ShellCwdState(
                version: 1,
                shells: [
                    "100": ShellEntry(
                        cwd: "/Users/pete/Code/capacitor",
                        tty: "/dev/ttys031",
                        parentApp: "Terminal",
                        tmuxSession: "capacitor",
                        tmuxClientTty: nil,
                        tmuxPane: "%99",
                        updatedAt: Date(timeIntervalSince1970: 1_742_000_000),
                    ),
                ],
            ),
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.terminalApp.app, .ghostty)
        XCTAssertEqual(intent.terminalApp.source, .runtimeRoute)
        XCTAssertEqual(intent.sessionName, "capacitor")
        XCTAssertEqual(intent.paneId, "%12")
        XCTAssertEqual(intent.hostTty, "/dev/ttys017")
    }

    func testResolveIntentUsesShellEvidenceWhenAttachedRouteHasNoTerminalApp() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: nil,
            sessionName: "capacitor",
            route: RuntimeRoutingView(
                workspaceId: "workspace-capacitor",
                projectPath: "/Users/pete/Code/capacitor",
                status: "attached",
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
            shellState: ShellCwdState(
                version: 1,
                shells: [
                    "200": ShellEntry(
                        cwd: "/Users/pete/Code/capacitor",
                        tty: "/dev/ttys031",
                        parentApp: "Ghostty",
                        tmuxSession: "capacitor",
                        tmuxClientTty: nil,
                        tmuxPane: "%2",
                        updatedAt: Date(timeIntervalSince1970: 1_742_000_300),
                    ),
                    "201": ShellEntry(
                        cwd: "/Users/pete",
                        tty: "/dev/ttys029",
                        parentApp: "Terminal",
                        tmuxSession: "capacitor",
                        tmuxClientTty: nil,
                        tmuxPane: "%5",
                        updatedAt: Date(timeIntervalSince1970: 1_742_000_100),
                    ),
                ],
            ),
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.terminalApp.app, .ghostty)
        XCTAssertEqual(intent.terminalApp.source, .shellEvidence)
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
            shellState: nil,
            fallbackTerminalApp: { .iTerm },
        )

        XCTAssertEqual(intent.terminalApp.app, .iTerm)
        XCTAssertEqual(intent.terminalApp.source, .fallback)
        XCTAssertNil(intent.sessionName)
        XCTAssertNil(intent.paneId)
        XCTAssertNil(intent.hostTty)
    }

    func testResolveIntentUsesShellEvidenceThatPrefersClientTtyMatch() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: "/dev/ttys002",
            sessionName: "caps",
            route: nil,
            shellState: ShellCwdState(
                version: 1,
                shells: [
                    "100": ShellEntry(
                        cwd: "/Users/pete/Code/capacitor",
                        tty: "/dev/ttys010",
                        parentApp: "Ghostty",
                        tmuxSession: "caps",
                        tmuxClientTty: "/dev/ttys001",
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    ),
                    "101": ShellEntry(
                        cwd: "/Users/pete/Code/capacitor",
                        tty: "/dev/ttys020",
                        parentApp: "iTerm2",
                        tmuxSession: "caps",
                        tmuxClientTty: "/dev/ttys002",
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    ),
                ],
            ),
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.terminalApp.app, .iTerm)
        XCTAssertEqual(intent.terminalApp.source, .shellEvidence)
    }

    func testResolveIntentUsesShellEvidenceThatFallsBackToSessionMatch() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: nil,
            sessionName: "caps",
            route: nil,
            shellState: ShellCwdState(
                version: 1,
                shells: [
                    "200": ShellEntry(
                        cwd: "/Users/pete/Code/capacitor",
                        tty: "/dev/ttys030",
                        parentApp: "Terminal",
                        tmuxSession: "caps",
                        tmuxClientTty: nil,
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
                    ),
                ],
            ),
            fallbackTerminalApp: { .iTerm },
        )

        XCTAssertEqual(intent.terminalApp.app, .terminal)
        XCTAssertEqual(intent.terminalApp.source, .shellEvidence)
    }

    func testResolveIntentUsesShellEvidenceThatPrefersExactProjectPathWhenClientTtyUnknown() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: nil,
            sessionName: "capacitor",
            route: nil,
            shellState: ShellCwdState(
                version: 1,
                shells: [
                    "300": ShellEntry(
                        cwd: "/Users/pete/Code/capacitor",
                        tty: "/dev/ttys031",
                        parentApp: "Ghostty",
                        tmuxSession: nil,
                        tmuxClientTty: nil,
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_300),
                    ),
                    "301": ShellEntry(
                        cwd: "/Users/pete",
                        tty: "/dev/ttys029",
                        parentApp: "Terminal",
                        tmuxSession: "capacitor",
                        tmuxClientTty: nil,
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    ),
                ],
            ),
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.terminalApp.app, .ghostty)
        XCTAssertEqual(intent.terminalApp.source, .shellEvidence)
    }

    func testResolveIntentUsesShellEvidenceThatPrefersExactProjectPathPaneInSharedSession() {
        let policy = ActivationPolicy()
        let intent = policy.resolveIntent(
            projectPath: "/Users/pete/Code/sanctuary",
            clientTty: "/dev/ttys001",
            sessionName: "shared",
            route: nil,
            shellState: ShellCwdState(
                version: 1,
                shells: [
                    "300": ShellEntry(
                        cwd: "/Users/pete/Code/capacitor",
                        tty: "/dev/ttys030",
                        parentApp: "Ghostty",
                        tmuxSession: "shared",
                        tmuxClientTty: "/dev/ttys001",
                        tmuxPane: "%1",
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_300),
                    ),
                    "301": ShellEntry(
                        cwd: "/Users/pete/Code/sanctuary",
                        tty: "/dev/ttys031",
                        parentApp: "Ghostty",
                        tmuxSession: "shared",
                        tmuxClientTty: "/dev/ttys001",
                        tmuxPane: "%2",
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_400),
                    ),
                ],
            ),
            fallbackTerminalApp: { .terminal },
        )

        XCTAssertEqual(intent.paneId, "%2")
    }
}
