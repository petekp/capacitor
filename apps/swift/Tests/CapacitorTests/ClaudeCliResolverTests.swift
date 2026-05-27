@testable import Capacitor
import XCTest

final class ClaudeCliResolverTests: XCTestCase {
    func testPrefersExecutableConfiguredPath() async throws {
        let tempDir = try makeTempDirectory()
        let configuredClaude = try writeExecutableClaude(in: tempDir.appendingPathComponent("configured-bin"))
        let fallbackClaude = try writeExecutableClaude(in: tempDir.appendingPathComponent("fallback-bin"))
        let configURL = tempDir.appendingPathComponent("runtime-config.json")
        try writeRuntimeConfig(claudePath: configuredClaude.path, to: configURL)

        let resolver = ClaudeCliResolver(
            config: CapacitorConfig(configURL: configURL),
            environment: ["PATH": ""],
            fallbackDirectories: [fallbackClaude.deletingLastPathComponent().path],
        )

        let resolved = await resolver.resolveClaudePath()

        XCTAssertEqual(resolved, configuredClaude.path)
    }

    func testFallsBackToPathWhenConfiguredPathIsStale() async throws {
        let tempDir = try makeTempDirectory()
        let pathClaude = try writeExecutableClaude(in: tempDir.appendingPathComponent("path-bin"))
        let fallbackClaude = try writeExecutableClaude(in: tempDir.appendingPathComponent("fallback-bin"))
        let configURL = tempDir.appendingPathComponent("runtime-config.json")
        try writeRuntimeConfig(claudePath: tempDir.appendingPathComponent("missing/claude").path, to: configURL)

        let resolver = ClaudeCliResolver(
            config: CapacitorConfig(configURL: configURL),
            environment: ["PATH": pathClaude.deletingLastPathComponent().path],
            fallbackDirectories: [fallbackClaude.deletingLastPathComponent().path],
        )

        let resolved = await resolver.resolveClaudePath()

        XCTAssertEqual(resolved, pathClaude.path)
    }

    func testFallsBackToKnownClaudeInstallLocationsWhenAppPathIsThin() async throws {
        let tempDir = try makeTempDirectory()
        let fallbackClaude = try writeExecutableClaude(in: tempDir.appendingPathComponent("home-local-bin"))
        let configURL = tempDir.appendingPathComponent("runtime-config.json")
        try writeRuntimeConfig(claudePath: tempDir.appendingPathComponent("stale/claude").path, to: configURL)

        let resolver = ClaudeCliResolver(
            config: CapacitorConfig(configURL: configURL),
            environment: ["PATH": "/usr/bin:/bin"],
            fallbackDirectories: [fallbackClaude.deletingLastPathComponent().path],
        )

        let resolved = await resolver.resolveClaudePath()

        XCTAssertEqual(resolved, fallbackClaude.path)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCliResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
        )
        return url
    }

    private func writeExecutableClaude(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
        )
        let url = directory.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path,
        )
        return url
    }

    private func writeRuntimeConfig(claudePath: String, to url: URL) throws {
        let data = try JSONEncoder().encode(CapacitorConfig.Config(
            claudePath: claudePath,
            tmuxPath: nil,
        ))
        try data.write(to: url, options: .atomic)
    }
}
