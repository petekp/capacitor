@testable import Capacitor
import XCTest

final class UnavailableActivationGatewayTests: XCTestCase {
    func testActivateReturnsUnavailableDecision() async throws {
        let gateway = UnavailableActivationGateway()
        let project = ShellProjectReference(
            displayName: "Capacitor",
            path: "/tmp/capacitor",
        )

        let decision = try await gateway.activate(
            ShellActivationRequest(
                project: project,
                preferredSessionName: nil,
                source: "test",
            ),
        )

        XCTAssertEqual(decision.disposition, .unavailable)
        XCTAssertEqual(decision.project.path, project.path)
    }
}
