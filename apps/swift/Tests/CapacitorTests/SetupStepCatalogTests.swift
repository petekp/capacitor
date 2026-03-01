@testable import Capacitor
import XCTest

final class SetupStepCatalogTests: XCTestCase {
    func testDefaultStepsUseCanonicalOrderAndMetadata() {
        let steps = SetupStepCatalog.defaultSteps()

        XCTAssertEqual(steps.map(\.id), ["claude", "hooks", "shell"])
        XCTAssertEqual(steps.map(\.title), ["Claude Code", "Session tracking", "Terminal tracking"])
        XCTAssertEqual(
            steps.map(\.description),
            [
                "Capacitor reads your Claude sessions to show live project status",
                "See which projects are active and what Claude is working on",
                "Add hook to ~/.zshrc to auto-detect which project each terminal is in",
            ],
        )
        XCTAssertEqual(steps.map(\.isOptional), [false, false, true])
    }

    func testCatalogBuildersPreserveProvidedStatus() {
        XCTAssertEqual(
            SetupStepCatalog.claude(status: .completed(detail: "Installed")).status,
            .completed(detail: "Installed"),
        )
        XCTAssertEqual(
            SetupStepCatalog.hooks(status: .actionNeeded(message: "Tap Install to connect")).status,
            .actionNeeded(message: "Tap Install to connect"),
        )
        XCTAssertEqual(
            SetupStepCatalog.shell(status: .completed(detail: "Active")).status,
            .completed(detail: "Active"),
        )
    }

    func testStepLookupRoutesToCanonicalBuilder() {
        let lookedUp = SetupStepCatalog.step(for: "hooks", status: .error(message: "Session tracking needs repair"))
        let canonical = SetupStepCatalog.hooks(status: .error(message: "Session tracking needs repair"))

        XCTAssertEqual(lookedUp.id, canonical.id)
        XCTAssertEqual(lookedUp.title, canonical.title)
        XCTAssertEqual(lookedUp.description, canonical.description)
        XCTAssertEqual(lookedUp.status, canonical.status)
        XCTAssertEqual(lookedUp.isOptional, canonical.isOptional)
    }
}
