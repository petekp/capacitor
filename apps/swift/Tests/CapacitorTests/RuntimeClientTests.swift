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
        let client = try makeClient()

        let states = try await client.fetchProjectStates()

        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.projectPath, "/tmp/core-project")
        XCTAssertEqual(states.first?.state, "working")
        XCTAssertEqual(states.first?.sessionId, "session-core")
    }

    func testFetchSessionsUsesCoreSnapshotWhenAvailable() async throws {
        let client = try makeClient()

        let sessions = try await client.fetchSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, "session-core")
        XCTAssertEqual(sessions.first?.state, "working")
        XCTAssertEqual(sessions.first?.toolsInFlight, 1)
    }

    func testFetchShellStateUsesCoreSnapshotWhenAvailable() async throws {
        let client = try makeClient()

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
        let client = try makeClient()

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "runtime-test")

        XCTAssertEqual(snapshot.projectStates.count, 1)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.shellState.shells.count, 1)
        XCTAssertEqual(snapshot.projectStates.first?.projectPath, "/tmp/core-project")
        XCTAssertEqual(snapshot.sessions.first?.sessionId, "session-core")
    }

    func testFetchRuntimeSnapshotFailureScenarios() async throws {
        enum ExpectedError {
            case invalidResponse
            case runtimeUnavailable
        }

        let scenarios: [LabeledExpectationScenario<() throws -> RuntimeClient, ExpectedError>] = [
            LabeledExpectationScenario(
                label: "snapshot_missing",
                input: {
                    let missingPath = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathComponent("missing_snapshot.json")
                        .path
                    return RuntimeClient(coreSnapshotPathOverride: missingPath)
                },
                expected: .runtimeUnavailable,
            ),
            LabeledExpectationScenario(
                label: "invalid_shell_timestamp",
                input: { [self] in
                    try makeClient(
                        coreSnapshot: Self.makeInvalidShellTimestampSnapshot(),
                    )
                },
                expected: .invalidResponse,
            ),
            LabeledExpectationScenario(
                label: "snapshot_read_disabled",
                input: { [self] in
                    setenv("CAPACITOR_CORE_SNAPSHOT_READ_ENABLED", "0", 1)
                    return try makeClient()
                },
                expected: .runtimeUnavailable,
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.label)
            unsetenv("CAPACITOR_CORE_SNAPSHOT_READ_ENABLED")
            let client = try scenario.input()

            do {
                _ = try await client.fetchRuntimeSnapshot(correlationId: "failure-\(scenario.label)")
                XCTFail("\(context) expected RuntimeClientError")
            } catch let error as RuntimeClientError {
                switch (scenario.expected, error) {
                case (.invalidResponse, .invalidResponse):
                    break
                case let (.runtimeUnavailable, .runtimeUnavailable(message)):
                    XCTAssertTrue(
                        message.contains("Core runtime snapshot unavailable"),
                        "\(context) message mismatch",
                    )
                default:
                    XCTFail("\(context) unexpected RuntimeClientError: \(error)")
                }
            }
        }
    }

    func testFetchCoreRoutingSnapshotUnavailableScenarios() async throws {
        let normalizedUnmatchedPath = PathNormalizer.normalize("/TMP/Unmatched/../Unmatched///")
        let scenarios: [LabeledExpectationScenario<
            (projectPath: String, workspaceId: String),
            (workspaceId: String, projectPath: String),
        >] = [
            LabeledExpectationScenario(
                label: "explicit_workspace_id",
                input: (
                    projectPath: "/tmp/unmatched",
                    workspaceId: "workspace-missing",
                ),
                expected: (
                    workspaceId: "workspace-missing",
                    projectPath: "/tmp/unmatched",
                ),
            ),
            LabeledExpectationScenario(
                label: "blank_workspace_uses_normalized_project_path",
                input: (
                    projectPath: "/TMP/Unmatched/../Unmatched///",
                    workspaceId: "   ",
                ),
                expected: (
                    workspaceId: normalizedUnmatchedPath,
                    projectPath: normalizedUnmatchedPath,
                ),
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.label)
            let client = try makeClient()
            let snapshot = try await client.fetchCoreRoutingSnapshot(
                projectPath: scenario.input.projectPath,
                workspaceId: scenario.input.workspaceId,
            )

            assertUnavailableRoute(
                snapshot,
                projectPath: scenario.expected.projectPath,
                workspaceId: scenario.expected.workspaceId,
                context: context,
            )
        }
    }

    func testFetchCoreRoutingSnapshotReasonCodeScenarios() async throws {
        let scenarios: [LabeledExpectationScenario<
            String,
            (reasonCode: String?, scopeResolution: String?, candidateCount: Int?),
        >] = [
            LabeledExpectationScenario(
                label: "default_reason",
                input: "tmux_client_attached",
                expected: (
                    reasonCode: "TMUX_CLIENT_ATTACHED",
                    scopeResolution: nil,
                    candidateCount: nil,
                ),
            ),
            LabeledExpectationScenario(
                label: "normalizes_mixed_case",
                input: "  mixed_case_reason  ",
                expected: (
                    reasonCode: "MIXED_CASE_REASON",
                    scopeResolution: nil,
                    candidateCount: nil,
                ),
            ),
            LabeledExpectationScenario(
                label: "defaults_blank_reason",
                input: "   ",
                expected: (
                    reasonCode: "NO_TRUSTED_EVIDENCE",
                    scopeResolution: nil,
                    candidateCount: nil,
                ),
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.label)
            let client = try makeClient(
                coreSnapshot: Self.makeRoutingReasonSnapshot(reasonCode: scenario.input),
            )
            let snapshot = try await client.fetchCoreRoutingSnapshot(
                projectPath: "/tmp/core-project",
                workspaceId: "workspace-core",
            )
            assertAttachedTmuxRoute(
                snapshot,
                expectedReasonCode: scenario.expected.reasonCode,
                context: context,
            )
        }
    }

    func testFetchCoreRoutingDiagnosticsScopeResolutionScenarios() async throws {
        let scenarios: [LabeledExpectationScenario<
            String,
            (reasonCode: String?, scopeResolution: String?, candidateCount: Int?),
        >] = [
            LabeledExpectationScenario(
                label: "workspace_match",
                input: "workspace-core",
                expected: (
                    reasonCode: nil,
                    scopeResolution: "workspace_id",
                    candidateCount: 1,
                ),
            ),
            LabeledExpectationScenario(
                label: "workspace_missing_falls_back_to_project_path",
                input: "workspace-missing",
                expected: (
                    reasonCode: nil,
                    scopeResolution: "project_path",
                    candidateCount: 1,
                ),
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.label)
            let client = try makeClient()
            let diagnostics = try await client.fetchCoreRoutingDiagnostics(
                projectPath: "/tmp/core-project",
                workspaceId: scenario.input,
            )

            assertAttachedTmuxRoute(diagnostics.snapshot, context: context)
            if let expectedScope = scenario.expected.scopeResolution {
                XCTAssertEqual(diagnostics.scopeResolution, expectedScope, "\(context)")
            }
            if let expectedCount = scenario.expected.candidateCount {
                XCTAssertEqual(diagnostics.candidateTargets.count, expectedCount, "\(context)")
            }
        }
    }

    func testFetchRuntimeConfigReturnsCoreDefaults() async throws {
        let client = try makeClient()

        let config = try await client.fetchRuntimeConfig()
        XCTAssertEqual(config.tmuxSignalFreshMs, 5000)
        XCTAssertEqual(config.shellSignalFreshMs, 600_000)
        XCTAssertEqual(config.shellRetentionHours, 24)
        XCTAssertEqual(config.tmuxPollIntervalMs, 1000)
    }

    func testFetchHealthReturnsCoreSnapshotModeHealth() async throws {
        let client = try makeClient()

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

    private func makeClient(coreSnapshot: Data? = nil) throws -> RuntimeClient {
        let snapshotPath = try writeCoreSnapshot(coreSnapshot ?? Self.makeDefaultCoreSnapshot())
        return RuntimeClient(coreSnapshotPathOverride: snapshotPath)
    }

    private func assertAttachedTmuxRoute(
        _ snapshot: CoreRoutingSnapshot,
        expectedReasonCode: String? = nil,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(snapshot.status, "attached", "\(context) status mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.target.kind, "tmux_session", "\(context) target kind mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.target.value, "caps", "\(context) target value mismatch", file: file, line: line)
        if let expectedReasonCode {
            XCTAssertEqual(
                snapshot.reasonCode,
                expectedReasonCode,
                "\(context) reason code mismatch",
                file: file,
                line: line,
            )
        }
    }

    private func assertUnavailableRoute(
        _ snapshot: CoreRoutingSnapshot,
        projectPath: String,
        workspaceId: String,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(snapshot.status, "unavailable", "\(context) status mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.target.kind, "none", "\(context) target kind mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.reasonCode, "NO_TRUSTED_EVIDENCE", "\(context) reason mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.workspaceId, workspaceId, "\(context) workspace mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.projectPath, projectPath, "\(context) project path mismatch", file: file, line: line)
    }

    private static func makeDefaultCoreSnapshot() -> Data {
        makeCoreSnapshotResponse()
    }

    private static func makeInvalidShellTimestampSnapshot() -> Data {
        makeCoreSnapshotResponse(shellUpdatedAt: "not-an-rfc3339-timestamp")
    }

    private static func makeRoutingReasonSnapshot(reasonCode: String) -> Data {
        makeCoreSnapshotResponse(routeReasonCode: reasonCode)
    }

    private static func makeCoreSnapshotResponse(
        shellUpdatedAt: String = "2026-02-28T19:00:00Z",
        routeReasonCode: String = "tmux_client_attached",
    ) -> Data {
        let json = """
        {"projects":[{"project_id":"/tmp/core-project/.git","workspace_id":"workspace-core","project_path":"/tmp/core-project","display_name":"core-project","state":"working","updated_at":"2026-02-28T19:00:00Z","state_changed_at":"2026-02-28T19:00:00Z","representative_session_id":"session-core","latest_session_id":"session-core","session_count":1,"active_count":1,"has_session":true}],"sessions":[{"session_id":"session-core","pid":4242,"cwd":"/tmp/core-project","project_id":"/tmp/core-project/.git","project_path":"/tmp/core-project","workspace_id":"workspace-core","state":"working","state_changed_at":"2026-02-28T19:00:00Z","updated_at":"2026-02-28T19:00:00Z","last_event":"user_prompt_submit","last_activity_at":"2026-02-28T19:00:00Z","tools_in_flight":1,"ready_reason":null}],"shells":[{"pid":4242,"cwd":"/tmp/core-project","tty":"/dev/ttys001","parent_app":"Ghostty","tmux_session":"core","updated_at":"\(shellUpdatedAt)"}],"routing":[{"workspace_id":"workspace-core","project_path":"/tmp/core-project","status":"attached","target_kind":"tmux_session","target_value":"caps","reason_code":"\(routeReasonCode)","reason":"Attached tmux client","updated_at":"2026-02-28T19:00:00Z"}],"diagnostics":{"events_ingested":7,"sessions_tracked":1,"shell_signals_tracked":1,"events_skipped":0,"stale_events_skipped":0,"informational_events_skipped":0,"reducer_events_skipped":0,"last_error":null},"generated_at":"2026-02-28T19:00:00Z"}
        """
        return Data(json.utf8)
    }
}
