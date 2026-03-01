@testable import Capacitor
import XCTest

final class HookPresentationPolicyTests: XCTestCase {
    func testSetupStepStatusForInstalledIsConnected() {
        XCTAssertEqual(
            HookPresentationPolicy.setupStepStatus(for: .installed(version: "1.2.3")),
            .completed(detail: "Connected"),
        )
    }

    func testSetupStepStatusForNotInstalledPromptsInstall() {
        XCTAssertEqual(
            HookPresentationPolicy.setupStepStatus(for: .notInstalled),
            .actionNeeded(message: "Tap Install to connect"),
        )
    }

    func testSetupStepStatusForPolicyBlockedShowsPolicyError() {
        XCTAssertEqual(
            HookPresentationPolicy.setupStepStatus(for: .policyBlocked(reason: "disableAllHooks is enabled")),
            .error(message: "Your Claude settings prevent hook installation"),
        )
    }

    func testSetupStepStatusForBrokenStatesUsesRepairMessage() {
        XCTAssertEqual(
            HookPresentationPolicy.setupStepStatus(for: .binaryBroken(reason: "codesign error")),
            .error(message: "Session tracking needs repair"),
        )
        XCTAssertEqual(
            HookPresentationPolicy.setupStepStatus(for: .symlinkBroken(target: "/missing", reason: "target missing")),
            .error(message: "Session tracking needs repair"),
        )
    }

    func testSetupCardHeaderUsesFirstRunOverride() {
        XCTAssertEqual(
            HookPresentationPolicy.setupCardHeader(for: .configMissing, isFirstRun: true),
            "Let's get you set up",
        )
    }

    func testSetupCardHeaderForIssueMatchesContract() {
        XCTAssertEqual(
            HookPresentationPolicy.setupCardHeader(for: .binaryMissing, isFirstRun: false),
            "Hook binary missing",
        )
        XCTAssertEqual(
            HookPresentationPolicy.setupCardHeader(for: nil, isFirstRun: false),
            "Session tracking unavailable",
        )
    }

    func testStartupPolicyBlockedMessageIncludesReason() {
        XCTAssertEqual(
            HookPresentationPolicy.startupPolicyBlockedMessage(reason: "disableAllHooks is enabled."),
            "Hooks blocked by policy (disableAllHooks is enabled.), showing WelcomeView",
        )
    }

    func testStartupRepairMessageIsStatusSpecific() {
        XCTAssertEqual(
            HookPresentationPolicy.startupNeedsRepairMessage(for: .notInstalled),
            "Hook status notInstalled requires auto-repair",
        )
        XCTAssertEqual(
            HookPresentationPolicy.startupNeedsRepairMessage(for: .binaryBroken(reason: "codesign error")),
            "Hook status binaryBroken requires auto-repair",
        )
    }
}
