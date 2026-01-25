@testable import Capacitor
import XCTest

final class SessionStalenessTests: XCTestCase {
    func testReadyStateStaleBeyondThreshold() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.readyStaleThreshold - 1)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        let isStale = SessionStaleness.isReadyStale(state: .ready, stateChangedAt: timestamp, now: now)

        XCTAssertTrue(isStale)
    }

    func testReadyStateNotStaleJustUnderThreshold() {
        let now = Date()
        let thresholdDate = now.addingTimeInterval(-(SessionStaleness.readyStaleThreshold - 1))
        let timestamp = ISO8601DateFormatter.shared.string(from: thresholdDate)

        let isStale = SessionStaleness.isReadyStale(state: .ready, stateChangedAt: timestamp, now: now)

        XCTAssertFalse(isStale)
    }

    func testNonReadyStateIsNotStale() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.readyStaleThreshold - 3600)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        let isStale = SessionStaleness.isReadyStale(state: .working, stateChangedAt: timestamp, now: now)

        XCTAssertFalse(isStale)
    }

    func testMissingTimestampIsNotStale() {
        let isStale = SessionStaleness.isReadyStale(state: .ready, stateChangedAt: nil, now: Date())

        XCTAssertFalse(isStale)
    }
}
