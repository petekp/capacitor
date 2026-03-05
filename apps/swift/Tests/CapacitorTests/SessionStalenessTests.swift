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

    // MARK: - Working Staleness

    func testWorkingStateStaleBeyondThreshold() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.workingStaleThreshold - 1)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        let isStale = SessionStaleness.isWorkingStale(state: .working, updatedAt: timestamp, now: now)

        XCTAssertTrue(isStale)
    }

    func testWorkingStateNotStaleJustUnderThreshold() {
        let now = Date()
        let freshDate = now.addingTimeInterval(-(SessionStaleness.workingStaleThreshold - 1))
        let timestamp = ISO8601DateFormatter.shared.string(from: freshDate)

        let isStale = SessionStaleness.isWorkingStale(state: .working, updatedAt: timestamp, now: now)

        XCTAssertFalse(isStale)
    }

    func testNonWorkingStateIsNotWorkingStale() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.workingStaleThreshold - 3600)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        let isStale = SessionStaleness.isWorkingStale(state: .ready, updatedAt: timestamp, now: now)

        XCTAssertFalse(isStale)
    }
}
