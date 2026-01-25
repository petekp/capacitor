@testable import Capacitor
import Foundation
import XCTest

final class TelemetryRedactionTests: XCTestCase {
    func testShouldRedactPathsForRemoteEndpointByDefault() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://ingest.example.com/v1/telemetry"))
        XCTAssertTrue(TelemetryRedaction.shouldRedactPaths(environment: [:], endpoint: endpoint))
    }

    func testShouldNotRedactPathsForLocalEndpoint() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://localhost:9133/telemetry"))
        XCTAssertFalse(TelemetryRedaction.shouldRedactPaths(environment: [:], endpoint: endpoint))
    }

    func testShouldNotRedactPathsWhenExplicitlyOptedIn() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://ingest.example.com/v1/telemetry"))
        XCTAssertFalse(
            TelemetryRedaction.shouldRedactPaths(
                environment: ["CAPACITOR_TELEMETRY_INCLUDE_PATHS": "1"],
                endpoint: endpoint,
            ),
        )
    }

    func testRedactPayloadRedactsPathLikeFieldsRecursively() throws {
        let input: [String: Any] = [
            "path": "/Users/pete/Code/capacitor",
            "nested": [
                "project_path": "/Users/pete/Code/other",
                "cwd": "/Users/pete/Code/capacitor/apps/swift",
            ],
        ]

        let redacted = TelemetryRedaction.redactPayload(input)

        let topLevelPath = try XCTUnwrap(redacted["path"] as? String)
        XCTAssertTrue(topLevelPath.hasPrefix("path#"))
        XCTAssertFalse(topLevelPath.contains("/Users/"))

        let nested = try XCTUnwrap(redacted["nested"] as? [String: Any])
        let nestedPath = try XCTUnwrap(nested["project_path"] as? String)
        let nestedCwd = try XCTUnwrap(nested["cwd"] as? String)
        XCTAssertTrue(nestedPath.hasPrefix("path#"))
        XCTAssertTrue(nestedCwd.hasPrefix("path#"))
    }

    func testRedactPayloadRedactsEmbeddedPathsInFreeText() throws {
        let input: [String: Any] = [
            "error": "failed opening /Users/pete/Code/capacitor/main.swift",
        ]

        let redacted = TelemetryRedaction.redactPayload(input)
        let error = try XCTUnwrap(redacted["error"] as? String)

        XCTAssertFalse(error.contains("/Users/pete/Code/capacitor"))
        XCTAssertTrue(error.contains("path#"))
    }

    func testRedactMessageRedactsEmbeddedPaths() {
        let message = "Activation fallback for /Users/pete/Code/capacitor"
        let redacted = TelemetryRedaction.redactMessage(message)
        XCTAssertFalse(redacted.contains("/Users/pete/Code/capacitor"))
        XCTAssertTrue(redacted.contains("path#"))
    }
}
