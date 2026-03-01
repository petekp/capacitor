@testable import Capacitor
import XCTest

@MainActor
final class HookDiagnosticPresentationTests: XCTestCase {
    func testSetupCardHiddenWhenHooksIdleAfterFirstRun() {
        let diagnostic = SetupTestFixtures.hookDiagnosticReport(
            primaryIssue: .notFiring(lastSeenSecs: 120),
            configOk: true,
            lastHeartbeatAgeSecs: 120,
        )

        XCTAssertFalse(diagnostic.shouldShowSetupCard)
    }

    func testSetupCardHiddenOnFirstRunWhenNotFiring() {
        let diagnostic = SetupTestFixtures.hookDiagnosticReport(
            primaryIssue: .notFiring(lastSeenSecs: nil),
            isFirstRun: true,
            configOk: true,
        )

        XCTAssertFalse(diagnostic.shouldShowSetupCard)
    }

    func testSetupCardShownOnConfigMissing() {
        let diagnostic = SetupTestFixtures.hookDiagnosticReport(
            primaryIssue: .configMissing,
            configOk: false,
        )

        XCTAssertTrue(diagnostic.shouldShowSetupCard)
    }

    func testSetupCardShownOnFirstRunWhenConfigMissing() {
        let diagnostic = SetupTestFixtures.hookDiagnosticReport(
            primaryIssue: .configMissing,
            isFirstRun: true,
            configOk: false,
        )

        XCTAssertTrue(diagnostic.shouldShowSetupCard)
    }

    func testSetupCardHeaderMessageIsIssueSpecificForConfigMissing() {
        let diagnostic = SetupTestFixtures.hookDiagnosticReport(
            primaryIssue: .configMissing,
            configOk: false,
        )

        XCTAssertEqual(diagnostic.setupCardHeaderMessage, "Claude hooks not configured")
        XCTAssertEqual(diagnostic.setupCardGuidanceMessage, "Install/update Claude hooks in `~/.claude/settings.json`.")
    }

    func testSetupCardGuidanceIncludesPolicyReasonWhenBlocked() {
        let diagnostic = SetupTestFixtures.hookDiagnosticReport(
            primaryIssue: .policyBlocked(reason: "disableAllHooks is enabled."),
            canAutoFix: false,
            configOk: false,
        )

        XCTAssertTrue(diagnostic.setupCardIsPolicyBlocked)
        XCTAssertEqual(diagnostic.setupCardHeaderMessage, "Hooks disabled by policy")
        XCTAssertEqual(
            diagnostic.setupCardGuidanceMessage,
            "disableAllHooks is enabled. Remove this setting to enable session tracking.",
        )
    }
}
