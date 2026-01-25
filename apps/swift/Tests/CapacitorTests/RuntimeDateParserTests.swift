@testable import Capacitor
import XCTest

final class RuntimeDateParserTests: XCTestCase {
    func testParsesDateWithoutFractionalSeconds() {
        let date = RuntimeDateParser.parse("2026-02-02T19:00:00Z")
        XCTAssertNotNil(date)
    }

    func testParsesDateWithFractionalSeconds() {
        let date = RuntimeDateParser.parse("2026-02-02T19:00:00.123Z")
        XCTAssertNotNil(date)
    }

    func testParsesDateWithMicroseconds() {
        let date = RuntimeDateParser.parse("2026-02-02T19:00:00.123456Z")
        XCTAssertNotNil(date)
    }

    func testRejectsInvalidDate() {
        let date = RuntimeDateParser.parse("not-a-date")
        XCTAssertNil(date)
    }
}
