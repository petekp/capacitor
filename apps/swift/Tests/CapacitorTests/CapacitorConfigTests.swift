@testable import Capacitor
import XCTest

final class CapacitorConfigTests: XCTestCase {
    private func writeConfig(_ config: CapacitorConfig.Config, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    func testUsesDedicatedRuntimeConfigPath() {
        XCTAssertTrue(
            CapacitorConfig.defaultURL.path.hasSuffix("/.capacitor/runtime-config.json"),
            "CapacitorConfig should persist runtime state in a dedicated config file",
        )
    }

    func testRuntimeConfigPathDoesNotCollideWithAppConfigPath() {
        XCTAssertNotEqual(CapacitorConfig.defaultURL.path, AppConfig.ConfigFile.defaultURL.path)
        XCTAssertTrue(AppConfig.ConfigFile.defaultURL.path.hasSuffix("/.capacitor/config.json"))
    }

    func testLoadUsesOnlyRuntimeConfigFile() async throws {
        let tempDir = try XCTUnwrap(FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        let runtimeURL = tempDir.appendingPathComponent("runtime-config.json")
        let ignoredConfigURL = tempDir.appendingPathComponent("config.json")

        try writeConfig(
            CapacitorConfig.Config(claudePath: "/runtime/claude", tmuxPath: "/runtime/tmux"),
            to: runtimeURL,
        )
        try writeConfig(
            CapacitorConfig.Config(claudePath: "/other/claude", tmuxPath: "/other/tmux"),
            to: ignoredConfigURL,
        )

        let config = CapacitorConfig(configURL: runtimeURL)
        let loaded = await config.load()
        XCTAssertEqual(loaded.claudePath, "/runtime/claude")
        XCTAssertEqual(loaded.tmuxPath, "/runtime/tmux")
    }

    func testLoadReturnsDefaultsWhenRuntimeConfigMissing() async throws {
        let tempDir = try XCTUnwrap(FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        let runtimeURL = tempDir.appendingPathComponent("runtime-config.json")
        let ignoredConfigURL = tempDir.appendingPathComponent("config.json")

        try writeConfig(
            CapacitorConfig.Config(claudePath: "/other/claude", tmuxPath: "/other/tmux"),
            to: ignoredConfigURL,
        )

        let config = CapacitorConfig(configURL: runtimeURL)
        let loaded = await config.load()
        XCTAssertNil(loaded.claudePath)
        XCTAssertNil(loaded.tmuxPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeURL.path))
    }
}
