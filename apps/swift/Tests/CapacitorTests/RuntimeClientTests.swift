@testable import Capacitor
import Foundation
import XCTest

final class RuntimeClientTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        unsetenv("CAPACITOR_RUNTIME_ENABLED")
        unsetenv("CAPACITOR_CORE_SNAPSHOT")
        unsetenv("CAPACITOR_CORE_SNAPSHOT_READ_ENABLED")
    }

    func testIsEnabledDefaultsToTrueWhenEnvMissing() {
        unsetenv("CAPACITOR_RUNTIME_ENABLED")
        let client = RuntimeClient()
        XCTAssertTrue(client.isEnabled)
    }

    func testFetchProjectStatesUsesCoreSnapshotWhenAvailable() async throws {
        let snapshotPath = try writeCoreSnapshot(Self.makeCoreSnapshotResponse())
        let client = RuntimeClient(coreSnapshotPathOverride: snapshotPath)

        let states = try await client.fetchProjectStates()

        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.projectPath, "/tmp/core-project")
        XCTAssertEqual(states.first?.state, "working")
        XCTAssertEqual(states.first?.sessionId, "session-core")
    }

    func testFetchSessionsUsesCoreSnapshotWhenAvailable() async throws {
        let snapshotPath = try writeCoreSnapshot(Self.makeCoreSnapshotResponse())
        let client = RuntimeClient(coreSnapshotPathOverride: snapshotPath)

        let sessions = try await client.fetchSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, "session-core")
        XCTAssertEqual(sessions.first?.state, "working")
        XCTAssertEqual(sessions.first?.toolsInFlight, 1)
    }

    func testFetchShellStateUsesCoreSnapshotWhenAvailable() async throws {
        let snapshotPath = try writeCoreSnapshot(Self.makeCoreSnapshotResponse())
        let client = RuntimeClient(coreSnapshotPathOverride: snapshotPath)

        let shellState = try await client.fetchShellState()

        XCTAssertEqual(shellState.version, 1)
        XCTAssertEqual(shellState.shells.count, 1)
        let shell = try XCTUnwrap(shellState.shells["4242"])
        XCTAssertEqual(shell.cwd, "/tmp/core-project")
        XCTAssertEqual(shell.tty, "/dev/ttys001")
        XCTAssertEqual(shell.parentApp, "Ghostty")
        XCTAssertEqual(shell.tmuxSession, "core")
    }

    func testFetchRuntimeSnapshotUsesCoreSnapshotWhenAvailable() async throws {
        let snapshotPath = try writeCoreSnapshot(Self.makeCoreSnapshotResponse())
        let client = RuntimeClient(coreSnapshotPathOverride: snapshotPath)

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "runtime-test")

        XCTAssertEqual(snapshot.projectStates.count, 1)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.shellState.shells.count, 1)
        XCTAssertEqual(snapshot.projectStates.first?.projectPath, "/tmp/core-project")
        XCTAssertEqual(snapshot.sessions.first?.sessionId, "session-core")
    }

    func testFetchRuntimeSnapshotThrowsWhenSnapshotMissing() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing_snapshot.json")
            .path
        let client = RuntimeClient(coreSnapshotPathOverride: missingPath)

        do {
            _ = try await client.fetchRuntimeSnapshot(correlationId: "missing")
            XCTFail("Expected snapshot unavailable error")
        } catch let error as RuntimeClientError {
            switch error {
            case let .runtimeUnavailable(message):
                XCTAssertTrue(message.contains("Core runtime snapshot unavailable"))
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFetchCoreRoutingSnapshotDerivesFromCoreSnapshotRouting() async throws {
        let snapshotPath = try writeCoreSnapshot(Self.makeCoreSnapshotResponse())
        let client = RuntimeClient(coreSnapshotPathOverride: snapshotPath)

        let snapshot = try await client.fetchCoreRoutingSnapshot(
            projectPath: "/tmp/core-project",
            workspaceId: "workspace-core",
        )

        XCTAssertEqual(snapshot.status, "attached")
        XCTAssertEqual(snapshot.target.kind, "tmux_session")
        XCTAssertEqual(snapshot.target.value, "caps")
        XCTAssertEqual(snapshot.reasonCode, "TMUX_CLIENT_ATTACHED")
    }

    func testFetchCoreRoutingSnapshotReturnsUnavailableWithoutMatchingRoute() async throws {
        let snapshotPath = try writeCoreSnapshot(Self.makeCoreSnapshotResponse())
        let client = RuntimeClient(coreSnapshotPathOverride: snapshotPath)

        let snapshot = try await client.fetchCoreRoutingSnapshot(
            projectPath: "/tmp/unmatched",
            workspaceId: "workspace-missing",
        )

        XCTAssertEqual(snapshot.status, "unavailable")
        XCTAssertEqual(snapshot.target.kind, "none")
        XCTAssertEqual(snapshot.reasonCode, "NO_TRUSTED_EVIDENCE")
    }

    func testFetchCoreRoutingDiagnosticsMirrorsDerivedRoutingSnapshot() async throws {
        let snapshotPath = try writeCoreSnapshot(Self.makeCoreSnapshotResponse())
        let client = RuntimeClient(coreSnapshotPathOverride: snapshotPath)

        let diagnostics = try await client.fetchCoreRoutingDiagnostics(
            projectPath: "/tmp/core-project",
            workspaceId: "workspace-core",
        )

        XCTAssertEqual(diagnostics.snapshot.status, "attached")
        XCTAssertEqual(diagnostics.snapshot.target.kind, "tmux_session")
        XCTAssertEqual(diagnostics.scopeResolution, "workspace_id")
        XCTAssertEqual(diagnostics.candidateTargets.count, 1)
    }

    func testRuntimeClientNoLongerExposesLegacyRoutingSnapshotSurface() throws {
        let source = try loadRuntimeClientSource()
        XCTAssertFalse(source.contains("struct DaemonRoutingSnapshot"))
        XCTAssertFalse(source.contains("struct DaemonRoutingDiagnostics"))
        XCTAssertFalse(source.contains("func fetchRoutingSnapshot("))
        XCTAssertFalse(source.contains("func fetchRoutingDiagnostics("))
    }

    func testFetchRuntimeConfigReturnsCoreDefaults() async throws {
        let snapshotPath = try writeCoreSnapshot(Self.makeCoreSnapshotResponse())
        let client = RuntimeClient(coreSnapshotPathOverride: snapshotPath)

        let config = try await client.fetchRuntimeConfig()
        XCTAssertEqual(config.tmuxSignalFreshMs, 5000)
        XCTAssertEqual(config.shellSignalFreshMs, 600_000)
        XCTAssertEqual(config.shellRetentionHours, 24)
        XCTAssertEqual(config.tmuxPollIntervalMs, 1000)
    }

    func testFetchHealthReturnsCoreSnapshotModeHealth() async throws {
        let snapshotPath = try writeCoreSnapshot(Self.makeCoreSnapshotResponse())
        let client = RuntimeClient(coreSnapshotPathOverride: snapshotPath)

        let health = try await client.fetchHealth()

        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.protocolVersion, 1)
        XCTAssertTrue(health.version.contains("core-snapshot"))
    }

    private func writeCoreSnapshot(_ data: Data) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let snapshotPath = tempDir.appendingPathComponent("app_snapshot.json")
        try data.write(to: snapshotPath)
        return snapshotPath.path
    }

    private func loadRuntimeClientSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let swiftPackageRoot = testsDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = swiftPackageRoot
            .appendingPathComponent("Sources/Capacitor/Models/RuntimeClient.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func makeCoreSnapshotResponse() -> Data {
        let json = """
        {"projects":[{"project_id":"/tmp/core-project/.git","workspace_id":"workspace-core","project_path":"/tmp/core-project","display_name":"core-project","state":"working","updated_at":"2026-02-28T19:00:00Z","state_changed_at":"2026-02-28T19:00:00Z","representative_session_id":"session-core","latest_session_id":"session-core","session_count":1,"active_count":1,"has_session":true}],"sessions":[{"session_id":"session-core","pid":4242,"cwd":"/tmp/core-project","project_id":"/tmp/core-project/.git","project_path":"/tmp/core-project","workspace_id":"workspace-core","state":"working","state_changed_at":"2026-02-28T19:00:00Z","updated_at":"2026-02-28T19:00:00Z","last_event":"user_prompt_submit","last_activity_at":"2026-02-28T19:00:00Z","tools_in_flight":1,"ready_reason":null}],"shells":[{"pid":4242,"cwd":"/tmp/core-project","tty":"/dev/ttys001","parent_app":"Ghostty","tmux_session":"core","updated_at":"2026-02-28T19:00:00Z"}],"routing":[{"workspace_id":"workspace-core","project_path":"/tmp/core-project","status":"attached","target_kind":"tmux_session","target_value":"caps","reason_code":"tmux_client_attached","reason":"Attached tmux client","updated_at":"2026-02-28T19:00:00Z"}],"diagnostics":{"events_ingested":7,"sessions_tracked":1,"shell_signals_tracked":1,"last_error":null},"generated_at":"2026-02-28T19:00:00Z"}
        """
        return Data(json.utf8)
    }
}
