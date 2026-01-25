@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class ActiveProjectResolverTests: XCTestCase {
    func testPrefersActiveSessionOverNewerReadySession() {
        let projectA = makeProject(name: "A", path: "/tmp/project-a")
        let projectB = makeProject(name: "B", path: "/tmp/project-b")

        let sessionStateManager = SessionStateManager()
        sessionStateManager.setSessionStatesForTesting([
            projectA.path: ProjectSessionState(
                state: .working,
                stateChangedAt: nil,
                updatedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-a",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
            projectB.path: ProjectSessionState(
                state: .ready,
                stateChangedAt: nil,
                updatedAt: "2026-02-02T19:05:00Z",
                sessionId: "session-b",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])

        let resolver = ActiveProjectResolver(sessionStateManager: sessionStateManager)
        resolver.updateProjects([projectA, projectB])
        resolver.resolve()

        XCTAssertEqual(resolver.activeProject?.path, projectA.path)
        XCTAssertEqual(resolver.activeSource, .claude(sessionId: "session-a"))
    }

    func testSelectsMostRecentReadySessionWhenNoActiveSessions() {
        let projectA = makeProject(name: "A", path: "/tmp/project-a")
        let projectB = makeProject(name: "B", path: "/tmp/project-b")

        let sessionStateManager = SessionStateManager()
        sessionStateManager.setSessionStatesForTesting([
            projectA.path: ProjectSessionState(
                state: .ready,
                stateChangedAt: nil,
                updatedAt: "2026-02-02T19:00:00Z",
                sessionId: "session-a",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
            projectB.path: ProjectSessionState(
                state: .ready,
                stateChangedAt: nil,
                updatedAt: "2026-02-02T19:05:00Z",
                sessionId: "session-b",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])

        let resolver = ActiveProjectResolver(sessionStateManager: sessionStateManager)
        resolver.updateProjects([projectA, projectB])
        resolver.resolve()

        XCTAssertEqual(resolver.activeProject?.path, projectB.path)
        XCTAssertEqual(resolver.activeSource, .claude(sessionId: "session-b"))
    }

    func testResolveReturnsNoneWhenNoSessionOrOverride() {
        let project = makeProject(name: "A", path: "/tmp/project-a")
        let sessionStateManager = SessionStateManager()
        sessionStateManager.setSessionStatesForTesting([:])
        let resolver = ActiveProjectResolver(sessionStateManager: sessionStateManager)
        resolver.updateProjects([project])
        resolver.resolve()

        XCTAssertNil(resolver.activeProject)
        XCTAssertEqual(resolver.activeSource, .none)
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }
}
