@testable import Capacitor
import XCTest

@MainActor
final class HookDiagnosticPresentationTests: XCTestCase {
    func testSetupCardVisibilityScenariosMatchContract() {
        let scenarios: [LabeledExpectationScenario<HookDiagnosticReport, Bool>] = [
            LabeledExpectationScenario(
                label: "healthy-report-hidden",
                input: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: nil,
                    isHealthy: true,
                    configOk: true,
                    firingOk: true,
                ),
                expected: false,
            ),
            LabeledExpectationScenario(
                label: "not-firing-hidden",
                input: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .notFiring(lastSeenSecs: 120),
                    configOk: true,
                    lastHeartbeatAgeSecs: 120,
                ),
                expected: false,
            ),
            LabeledExpectationScenario(
                label: "config-missing-shown",
                input: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .configMissing,
                    configOk: false,
                ),
                expected: true,
            )
        ]

        assertLabeledScenarios(scenarios, mismatch: "setup card visibility mismatch") { diagnostic in
            diagnostic.shouldShowSetupCard
        }
    }

    func testSetupCardHeaderAndGuidanceScenariosMatchContract() {
        struct SetupCardPresentation: Equatable {
            let isPolicyBlocked: Bool
            let header: String
            let guidance: String?
        }

        let scenarios: [LabeledExpectationScenario<HookDiagnosticReport, SetupCardPresentation>] = [
            LabeledExpectationScenario(
                label: "config-missing",
                input: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .configMissing,
                    configOk: false,
                ),
                expected: SetupCardPresentation(
                    isPolicyBlocked: false,
                    header: "Claude hooks not configured",
                    guidance: "Install/update Claude hooks in `~/.claude/settings.json`."
                ),
            ),
            LabeledExpectationScenario(
                label: "policy-blocked",
                input: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: .policyBlocked(reason: "disableAllHooks is enabled."),
                    canAutoFix: false,
                    configOk: false,
                ),
                expected: SetupCardPresentation(
                    isPolicyBlocked: true,
                    header: "Hooks disabled by policy",
                    guidance: "disableAllHooks is enabled. Remove this setting to enable session tracking."
                ),
            ),
        ]

        assertLabeledScenarios(scenarios, mismatch: "setup card presentation mismatch") { diagnostic in
            SetupCardPresentation(
                isPolicyBlocked: diagnostic.setupCardIsPolicyBlocked,
                header: diagnostic.setupCardHeaderMessage,
                guidance: diagnostic.setupCardGuidanceMessage
            )
        }
    }
}
