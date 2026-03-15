@testable import Capacitor
import XCTest

final class SessionResolutionPolicyTests: XCTestCase {
    func testChooseSessionNamePrefersRoutedSession() async {
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/capacitor",
            routedSessionName: "routed-session",
        )

        XCTAssertEqual(resolved, "routed-session")
    }

    func testChooseSessionNamePrefersInjectedFallbackOverTmuxDiscovery() async {
        let policy = SessionResolutionPolicy(
            discoverFallbackSession: { _ in "fallback-session" },
        )

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/capacitor",
            routedSessionName: nil,
        )

        XCTAssertEqual(resolved, "fallback-session")
    }

    func testChooseSessionNameFallsBackToProjectSlugWhenNoStrongerSignalExists() async {
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/capacitor",
            routedSessionName: nil,
        )

        XCTAssertEqual(resolved, "capacitor")
    }
}
