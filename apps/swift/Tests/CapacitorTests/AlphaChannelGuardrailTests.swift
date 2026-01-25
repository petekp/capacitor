@testable import Capacitor
import XCTest

final class AlphaChannelGuardrailTests: XCTestCase {
    func testNonAlphaBlockedInDebugWithoutBypass() {
        let message = AlphaChannelGuardrail.violationMessage(
            channel: .prod,
            environment: [:],
            isDebugBuild: true,
        )

        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("resolved channel was 'prod'") == true)
        XCTAssertTrue(message?.contains("Expected channel: alpha") == true)
        XCTAssertTrue(message?.contains("./scripts/dev/restart-current.sh") == true)
        XCTAssertTrue(message?.contains("CAPACITOR_ALLOW_NON_ALPHA=1") == true)
    }

    func testNonAlphaAllowedWithBypass() {
        let message = AlphaChannelGuardrail.violationMessage(
            channel: .beta,
            environment: ["CAPACITOR_ALLOW_NON_ALPHA": "1"],
            isDebugBuild: true,
        )

        XCTAssertNil(message)
    }

    func testAlphaAlwaysAllowedInDebug() {
        let message = AlphaChannelGuardrail.violationMessage(
            channel: .alpha,
            environment: [:],
            isDebugBuild: true,
        )

        XCTAssertNil(message)
    }
}
