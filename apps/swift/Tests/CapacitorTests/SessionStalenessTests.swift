@testable import Capacitor
import XCTest

final class SessionStalenessTests: XCTestCase {
    // MARK: - isActiveSessionStale (backwards-compat wrapper)

    func testWorkingStateStaleBeyondThreshold() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.workingStaleThreshold - 1)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        let isStale = SessionStaleness.isActiveSessionStale(state: .working, updatedAt: timestamp, now: now)

        XCTAssertTrue(isStale)
    }

    func testWorkingStateNotStaleJustUnderThreshold() {
        let now = Date()
        let freshDate = now.addingTimeInterval(-(SessionStaleness.workingStaleThreshold - 1))
        let timestamp = ISO8601DateFormatter.shared.string(from: freshDate)

        let isStale = SessionStaleness.isActiveSessionStale(state: .working, updatedAt: timestamp, now: now)

        XCTAssertFalse(isStale)
    }

    func testNonActiveStateIsNotStale() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.workingStaleThreshold - 3600)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        XCTAssertFalse(SessionStaleness.isActiveSessionStale(state: .ready, updatedAt: timestamp, now: now))
        XCTAssertFalse(SessionStaleness.isActiveSessionStale(state: .idle, updatedAt: timestamp, now: now))
    }

    func testWaitingStateStaleBeyondThreshold() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.workingStaleThreshold - 1)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        XCTAssertTrue(SessionStaleness.isActiveSessionStale(state: .waiting, updatedAt: timestamp, now: now))
    }

    func testCompactingStateStaleBeyondThreshold() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.workingStaleThreshold - 1)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        XCTAssertTrue(SessionStaleness.isActiveSessionStale(state: .compacting, updatedAt: timestamp, now: now))
    }

    // MARK: - isSessionEffectivelyDead (primary API)

    func testSessionEffectivelyDeadWhenIsAliveFalse() {
        let now = Date()
        // isAlive=false means Rust says the process has no shell corroboration
        XCTAssertTrue(SessionStaleness.isSessionEffectivelyDead(
            isAlive: false, state: .working, updatedAt: "2099-01-01T00:00:00Z", now: now,
        ))
    }

    func testSessionNotDeadWhenIsAliveTrue() {
        let now = Date()
        // isAlive=true means Rust confirms shell corroboration — session is alive
        // regardless of timestamp staleness
        let staleDate = now.addingTimeInterval(-SessionStaleness.workingStaleThreshold - 3600)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        XCTAssertFalse(SessionStaleness.isSessionEffectivelyDead(
            isAlive: true, state: .working, updatedAt: timestamp, now: now,
        ))
    }

    func testSessionFallsBackToTimestampWhenIsAliveNil() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.workingStaleThreshold - 1)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        // isAlive=nil (runtime service path) → falls back to timestamp
        XCTAssertTrue(SessionStaleness.isSessionEffectivelyDead(
            isAlive: nil, state: .working, updatedAt: timestamp, now: now,
        ))
    }

    func testSessionNotDeadForNonActiveStates() {
        let now = Date()
        // Non-active states are never "effectively dead"
        XCTAssertFalse(SessionStaleness.isSessionEffectivelyDead(
            isAlive: false, state: .ready, updatedAt: "2020-01-01T00:00:00Z", now: now,
        ))
        XCTAssertFalse(SessionStaleness.isSessionEffectivelyDead(
            isAlive: false, state: .idle, updatedAt: "2020-01-01T00:00:00Z", now: now,
        ))
    }

    func testSessionEffectivelyDeadForWaitingAndCompacting() {
        let now = Date()
        XCTAssertTrue(SessionStaleness.isSessionEffectivelyDead(
            isAlive: false, state: .waiting, updatedAt: "2099-01-01T00:00:00Z", now: now,
        ))
        XCTAssertTrue(SessionStaleness.isSessionEffectivelyDead(
            isAlive: false, state: .compacting, updatedAt: "2099-01-01T00:00:00Z", now: now,
        ))
    }

    // MARK: - isRunFreshnessExpired (run-specific)

    func testRunFreshnessExpiredBeyondThreshold() {
        let now = Date()
        let staleDate = now.addingTimeInterval(-SessionStaleness.workingStaleThreshold - 1)
        let timestamp = ISO8601DateFormatter.shared.string(from: staleDate)

        XCTAssertTrue(SessionStaleness.isRunFreshnessExpired(updatedAt: timestamp, now: now))
    }

    func testRunFreshnessNotExpiredWithinThreshold() {
        let now = Date()
        let freshDate = now.addingTimeInterval(-(SessionStaleness.workingStaleThreshold - 1))
        let timestamp = ISO8601DateFormatter.shared.string(from: freshDate)

        XCTAssertFalse(SessionStaleness.isRunFreshnessExpired(updatedAt: timestamp, now: now))
    }

    func testRunFreshnessNotExpiredForNilTimestamp() {
        let now = Date()
        XCTAssertFalse(SessionStaleness.isRunFreshnessExpired(updatedAt: nil, now: now))
    }
}
