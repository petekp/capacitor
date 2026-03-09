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
    }

    func testConfigSourceDoesNotRetainUnusedTmuxPath() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Capacitor/Support/Config/CapacitorConfig.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains(["tmux", "Path"].joined()))
    }
}
