@testable import Capacitor
import XCTest

final class SessionStalenessTests: XCTestCase {
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
