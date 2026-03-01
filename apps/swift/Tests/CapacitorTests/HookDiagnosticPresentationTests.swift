@testable import Capacitor
import XCTest

@MainActor
final class HookDiagnosticPresentationTests: XCTestCase {
    func testSetupCardVisibilityScenariosMatchContract() {
        struct Scenario {
            let label: String
            let diagnostic: HookDiagnosticReport
            let expectedVisible: Bool
        }

        let scenarios: [Scenario] = [
            Scenario(
                label: "idle-after-first-run",
                diagnostic: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .notFiring(lastSeenSecs: 120),
                    configOk: true,
                    lastHeartbeatAgeSecs: 120,
                ),
                expectedVisible: false,
            ),
            Scenario(
                label: "first-run-not-firing",
                diagnostic: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .notFiring(lastSeenSecs: nil),
                    isFirstRun: true,
                    configOk: true,
                ),
                expectedVisible: false,
            ),
            Scenario(
                label: "config-missing",
                diagnostic: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .configMissing,
                    configOk: false,
                ),
                expectedVisible: true,
            ),
            Scenario(
                label: "first-run-config-missing",
                diagnostic: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .configMissing,
                    isFirstRun: true,
                    configOk: false,
                ),
                expectedVisible: true,
            ),
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                scenario.diagnostic.shouldShowSetupCard,
                scenario.expectedVisible,
                "[\(scenario.label)] setup card visibility mismatch",
            )
        }
    }

    func testSetupCardHeaderAndGuidanceScenariosMatchContract() {
        struct Scenario {
            let label: String
            let diagnostic: HookDiagnosticReport
            let expectedPolicyBlocked: Bool
            let expectedHeader: String
            let expectedGuidance: String
        }

        let scenarios: [Scenario] = [
            Scenario(
                label: "config-missing",
                diagnostic: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .configMissing,
                    configOk: false,
                ),
                expectedPolicyBlocked: false,
                expectedHeader: "Claude hooks not configured",
                expectedGuidance: "Install/update Claude hooks in `~/.claude/settings.json`.",
            ),
            Scenario(
                label: "policy-blocked",
                diagnostic: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .policyBlocked(reason: "disableAllHooks is enabled."),
                    canAutoFix: false,
                    configOk: false,
                ),
                expectedPolicyBlocked: true,
                expectedHeader: "Hooks disabled by policy",
                expectedGuidance: "disableAllHooks is enabled. Remove this setting to enable session tracking.",
            ),
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                scenario.diagnostic.setupCardIsPolicyBlocked,
                scenario.expectedPolicyBlocked,
                "[\(scenario.label)] policy blocked state mismatch",
            )
            XCTAssertEqual(
                scenario.diagnostic.setupCardHeaderMessage,
                scenario.expectedHeader,
                "[\(scenario.label)] setup card header mismatch",
            )
            XCTAssertEqual(
                scenario.diagnostic.setupCardGuidanceMessage,
                scenario.expectedGuidance,
                "[\(scenario.label)] setup card guidance mismatch",
            )
        }
    }
}
