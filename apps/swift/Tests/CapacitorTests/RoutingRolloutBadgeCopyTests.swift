@testable import Capacitor
import XCTest

final class RoutingRolloutBadgeCopyTests: XCTestCase {
    func testThresholdSummaryFormatsComparisonAndMinimum() {
        let rollout = makeRollout(comparisons: 345, minComparisonsRequired: 1000)
        XCTAssertEqual(RoutingRolloutBadgeCopy.thresholdSummary(rollout), "345/1000")
    }

    func testWindowSummaryUsesFallbackWhenWindowFieldsAreUnavailable() {
        let rollout = makeRollout(
            windowElapsedHours: nil,
            minWindowHoursRequired: nil,
        )
        XCTAssertEqual(RoutingRolloutBadgeCopy.windowSummary(rollout), "n/a/n/a")
    }

    func testGateLabelMapsBooleanAndUnknownValues() {
        XCTAssertEqual(RoutingRolloutBadgeCopy.gateLabel(true), "yes")
        XCTAssertEqual(RoutingRolloutBadgeCopy.gateLabel(false), "no")
        XCTAssertEqual(RoutingRolloutBadgeCopy.gateLabel(nil), "unknown")
    }

    private func makeRollout(
        comparisons: UInt64 = 1000,
        minComparisonsRequired: UInt64? = 1000,
        windowElapsedHours: UInt64? = 240,
        minWindowHoursRequired: UInt64? = 168,
    ) -> RuntimeRoutingRollout {
        RuntimeRoutingRollout(
            agreementGateTarget: 0.995,
            minComparisonsRequired: minComparisonsRequired,
            minWindowHoursRequired: minWindowHoursRequired,
            comparisons: comparisons,
            volumeGateMet: true,
            windowGateMet: true,
            statusAgreementRate: 0.999,
            targetAgreementRate: 0.998,
            firstComparisonAt: "2026-02-01T09:00:00Z",
            lastComparisonAt: "2026-02-14T09:00:00Z",
            windowElapsedHours: windowElapsedHours,
            statusGateMet: true,
            targetGateMet: true,
            statusRowDefaultReady: true,
            launcherDefaultReady: true,
        )
    }
}
