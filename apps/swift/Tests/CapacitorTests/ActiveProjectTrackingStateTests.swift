@testable import Capacitor
import XCTest

@MainActor
final class ActiveProjectTrackingStateTests: XCTestCase {
    func testActivatePrefersManualOverride() {
        let sessionStateManager = SessionStateManager()
        let trackingState = ActiveProjectTrackingState(projectSessionReader: sessionStateManager)
        let project = makeProject(name: "Capacitor", path: "/tmp/capacitor")

        trackingState.updateProjects([project])
        trackingState.activate(project)

        XCTAssertEqual(trackingState.activeProjectPath, project.path)
        XCTAssertEqual(trackingState.activeSource, .none)
    }

    func testRefreshAfterSessionUpdateAdoptsClaudeResolution() {
        let project = makeProject(name: "Capacitor", path: "/tmp/capacitor")
        let sessionStateManager = SessionStateManager()
        sessionStateManager.setSessionStatesForTesting([
            project.path: ProjectSessionState(
                state: .working,
                stateChangedAt: nil,
                updatedAt: "2026-03-06T20:00:00Z",
                sessionId: "session-1",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])
        let trackingState = ActiveProjectTrackingState(projectSessionReader: sessionStateManager)

        trackingState.updateProjects([project])
        trackingState.refreshAfterSessionUpdate()

        XCTAssertEqual(trackingState.activeProjectPath, project.path)
        XCTAssertEqual(trackingState.activeSource, .claude(sessionId: "session-1"))
    }

    func testActivateSupportsShellProjectCatalogEntries() {
        let sessionStateManager = SessionStateManager()
        let trackingState = ActiveProjectTrackingState(projectSessionReader: sessionStateManager)
        let project = ShellProjectCatalogEntry(displayName: "Capacitor", path: "/tmp/capacitor")

        trackingState.updateProjects([project])
        trackingState.activate(project)

        XCTAssertEqual(trackingState.activeProjectPath, project.path)
        XCTAssertEqual(trackingState.activeProject?.displayName, project.displayName)
        XCTAssertEqual(trackingState.activeSource, .none)
    }

    func testRefreshAfterSessionUpdateReturnsNoneWhenNoProjectHasSession() {
        let sessionStateManager = SessionStateManager()
        let trackingState = ActiveProjectTrackingState(projectSessionReader: sessionStateManager)
        trackingState.updateProjects([makeProject(name: "Capacitor", path: "/tmp/capacitor")])

        trackingState.refreshAfterSessionUpdate()

        XCTAssertNil(trackingState.activeProject)
        XCTAssertEqual(trackingState.activeSource, .none)
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
