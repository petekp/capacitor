@testable import Capacitor
import Foundation
import XCTest

final class TelemetryRoutingPolicyTests: XCTestCase {
    func testBlocksNonFeedbackEventsForIngestEndpoint() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://ingest.example.com/v1/telemetry"))
        XCTAssertFalse(
            TelemetryRoutingPolicy.shouldSendEvent(
                type: "active_project_resolution",
                endpoint: endpoint,
            ),
        )
    }

    func testAllowsQuickFeedbackEventsForIngestEndpoint() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://ingest.example.com/v1/telemetry"))
        XCTAssertTrue(
            TelemetryRoutingPolicy.shouldSendEvent(
                type: "quick_feedback_submitted",
                endpoint: endpoint,
            ),
        )
    }

    func testAllowsActivationOutcomeForIngestEndpoint() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://ingest.example.com/v1/telemetry"))
        XCTAssertTrue(
            TelemetryRoutingPolicy.shouldSendEvent(
                type: "activation_outcome",
                endpoint: endpoint,
            ),
        )
    }

    func testAllowsNonFeedbackEventsForTransparentUILocalEndpoint() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://localhost:9133/telemetry"))
        XCTAssertTrue(
            TelemetryRoutingPolicy.shouldSendEvent(
                type: "active_project_resolution",
                endpoint: endpoint,
            ),
        )
    }
}
