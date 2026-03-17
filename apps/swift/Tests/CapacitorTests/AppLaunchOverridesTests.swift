@testable import Capacitor
import XCTest

final class AppLaunchOverridesTests: XCTestCase {
    func testSkipSetupValidationDefaultsToFalse() {
        XCTAssertFalse(AppLaunchOverrides.shouldSkipSetupValidation(info: [:]))
    }

    func testSkipSetupValidationAcceptsStringTrueValues() {
        XCTAssertTrue(AppLaunchOverrides.shouldSkipSetupValidation(info: ["CapacitorSkipSetupValidation": "1"]))
        XCTAssertTrue(AppLaunchOverrides.shouldSkipSetupValidation(info: ["CapacitorSkipSetupValidation": "true"]))
    }

    func testSkipSetupValidationAcceptsNumericTruthiness() {
        XCTAssertTrue(AppLaunchOverrides.shouldSkipSetupValidation(info: ["CapacitorSkipSetupValidation": 1]))
        XCTAssertFalse(AppLaunchOverrides.shouldSkipSetupValidation(info: ["CapacitorSkipSetupValidation": 0]))
    }
}
