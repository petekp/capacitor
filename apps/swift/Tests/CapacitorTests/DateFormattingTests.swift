@testable import Capacitor
import XCTest

final class DateFormattingTests: XCTestCase {
    func testParsesDateWithoutFractionalSeconds() {
        let date = parseISO8601Date("2026-02-02T19:00:00Z")
        XCTAssertNotNil(date)
    }

    func testParsesDateWithFractionalSeconds() {
        let date = parseISO8601Date("2026-02-02T19:00:00.123Z")
        XCTAssertNotNil(date)
    }

    func testParsesDateWithMicroseconds() {
        let date = parseISO8601Date("2026-02-02T19:00:00.123456Z")
        XCTAssertNotNil(date)
    }

    func testParsesDateWithLongFractionByTruncatingToMicroseconds() {
        let date = parseISO8601Date("2026-02-02T19:00:00.123456789Z")
        XCTAssertNotNil(date)
    }

    func testRejectsInvalidDate() {
        let date = parseISO8601Date("not-a-date")
        XCTAssertNil(date)
    }
}
