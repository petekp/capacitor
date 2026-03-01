@testable import Capacitor
import XCTest

final class CapacitorConfigTests: XCTestCase {
    func testUsesDedicatedRuntimeConfigPath() {
        XCTAssertTrue(
            CapacitorConfig.defaultURL.path.hasSuffix("/.capacitor/runtime-config.json"),
            "CapacitorConfig should persist runtime state in a dedicated config file",
        )
    }

    func testRuntimeConfigPathDoesNotCollideWithAppConfigPath() {
        XCTAssertNotEqual(CapacitorConfig.defaultURL.path, AppConfig.ConfigFile.defaultURL.path)
        XCTAssertEqual(CapacitorConfig.legacyURL.path, AppConfig.ConfigFile.defaultURL.path)
    }
}
