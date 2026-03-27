@testable import Capacitor
import Foundation
import XCTest

final class RuntimeClientTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        unsetenv("CAPACITOR_RUNTIME_ENABLED")
    }

    func testIsEnabledDefaultsToTrueWhenEnvMissing() {
        unsetenv("CAPACITOR_RUNTIME_ENABLED")
        let client = RuntimeClient()
        XCTAssertTrue(client.isEnabled)
    }

    func testServiceModeWithoutConnectionReturnsRuntimeUnavailable() async throws {
        let client = RuntimeClient(loadRuntimeServiceConnection: { nil })

        do {
            _ = try await client.fetchRuntimeSnapshot(correlationId: "service")
            XCTFail("expected runtimeUnavailable in service mode")
        } catch let error as RuntimeClientError {
            switch error {
            case let .runtimeUnavailable(message):
                XCTAssertTrue(message.contains("connection unavailable"), "message mismatch: \(message)")
            default:
                XCTFail("unexpected RuntimeClientError: \(error)")
            }
        }
    }

    func testServiceModeFetchRuntimeSnapshotUsesRuntimeServiceSnapshot() async throws {
        var capturedRequest: URLRequest?
        let client = try RuntimeClient(
            isEnabledOverride: true,
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:7812")),
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                capturedRequest = request
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                return (Self.makeDefaultCoreSnapshot(), response)
            },
        )

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "service-runtime")

        XCTAssertEqual(capturedRequest?.url?.path, "/runtime/snapshot")
        XCTAssertEqual(
            capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer service-secret",
        )
        XCTAssertEqual(snapshot.projectStates.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.sessionId, "session-core")
        XCTAssertEqual(snapshot.shellState.shells.count, 1)
        XCTAssertEqual(snapshot.routingViews.count, 1)
        XCTAssertTrue(snapshot.runs.isEmpty)
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
        XCTAssertEqual(shell.tmuxClientTty, "/dev/ttys099")
        XCTAssertEqual(shell.tmuxPane, "%42")
    }

    func testFetchRuntimeSnapshotUsesCoreSnapshotWhenAvailable() async throws {
        let client = try makeClient()

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "runtime-test")

        XCTAssertEqual(snapshot.projectStates.count, 1)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.shellState.shells.count, 1)
        XCTAssertEqual(snapshot.routingViews.count, 1)
        XCTAssertTrue(snapshot.delegations.isEmpty)
        XCTAssertTrue(snapshot.runs.isEmpty)
        XCTAssertEqual(snapshot.projectStates.first?.projectPath, "/tmp/core-project")
        XCTAssertEqual(snapshot.sessions.first?.sessionId, "session-core")
    }

    func testFetchRuntimeSnapshotMapsDelegationReviewNeededState() async throws {
        let client = try makeClient(
            coreSnapshot: Self.makeDelegationReviewNeededSnapshot(),
        )

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "delegation-runtime")

        XCTAssertEqual(snapshot.delegations.count, 1)
        XCTAssertEqual(snapshot.delegations.first?.projectPath, "/tmp/core-project")
        XCTAssertEqual(snapshot.delegations.first?.workerId, "worker-1")
        XCTAssertEqual(snapshot.delegations.first?.sessionId, "worker-session-1")
        XCTAssertEqual(snapshot.delegations.first?.status, "review_needed")
        XCTAssertEqual(snapshot.delegations.first?.currentReview?.milestoneId, "01")
        XCTAssertEqual(
            snapshot.delegations.first?.currentReview?.manifestPath,
            "/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/manifest.json",
        )
    }

    func testFetchRuntimeSnapshotMapsDelegationResumePendingState() async throws {
        let client = try makeClient(
            coreSnapshot: Self.makeDelegationResumePendingSnapshot(),
        )

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "delegation-resume-pending")

        XCTAssertEqual(snapshot.delegations.count, 1)
        XCTAssertEqual(snapshot.delegations.first?.status, "resume_pending")
        XCTAssertEqual(snapshot.delegations.first?.submittedMilestoneId, "01")
        XCTAssertEqual(snapshot.delegations.first?.currentReview?.milestoneId, "01")
    }

    func testFetchRuntimeSnapshotMapsRunCheckpointCapturePending() async throws {
        let client = try makeClient(
            coreSnapshot: Self.makeRunCheckpointPendingSnapshot(),
        )

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "run-capture-pending")

        let run = try XCTUnwrap(snapshot.runs.first)
        let checkpoint = try XCTUnwrap(run.activeCheckpoint)
        XCTAssertEqual(run.id, "run-001")
        XCTAssertEqual(run.projectPath, "/tmp/core-project")
        XCTAssertEqual(checkpoint.id, "checkpoint-001")
        XCTAssertEqual(checkpoint.captureStatus, .pending)
        XCTAssertEqual(checkpoint.captureUrl, "http://localhost:3000")
        XCTAssertNil(checkpoint.captureClaim)
    }

    func testFetchRuntimeSnapshotMapsRunCheckpointCaptureFailed() async throws {
        let client = try makeClient(
            coreSnapshot: Self.makeRunCheckpointFailedSnapshot(),
        )

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "run-capture-failed")

        let checkpoint = try XCTUnwrap(snapshot.runs.first?.activeCheckpoint)
        if case let .failed(reason) = checkpoint.captureStatus {
            XCTAssertEqual(reason, "timeout")
        } else {
            XCTFail("expected failed capture status")
        }
        XCTAssertEqual(checkpoint.captureClaim?.captureRequestId, "capture-001")
        XCTAssertEqual(checkpoint.captureClaim?.clientId, "capacitor-mac-1234")
        XCTAssertEqual(checkpoint.captureClaim?.claimedAt, "2026-02-28T19:02:00Z")
        XCTAssertEqual(checkpoint.captureClaim?.observedCaptureUrl, "http://localhost:3000")
    }

    func testFetchRuntimeSnapshotMapsRunCheckpointCaptureStatusStrings() async throws {
        let scenarios: [LabeledExpectationScenario<String, RuntimeCaptureStatus>] = [
            LabeledExpectationScenario(
                label: "not_requested",
                input: "not_requested",
                expected: .notRequested,
            ),
            LabeledExpectationScenario(
                label: "in_progress",
                input: "in_progress",
                expected: .inProgress,
            ),
            LabeledExpectationScenario(
                label: "completed",
                input: "completed",
                expected: .completed,
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.label)
            let client = try makeClient(
                coreSnapshot: Self.makeRunCheckpointSnapshot(captureStatusJSON: "\"\(scenario.input)\""),
            )

            let snapshot = try await client.fetchRuntimeSnapshot(
                correlationId: "run-capture-\(scenario.label)",
            )

            let checkpoint = try XCTUnwrap(snapshot.runs.first?.activeCheckpoint, context)
            XCTAssertEqual(checkpoint.captureStatus, scenario.expected, context)
        }
    }

    func testFetchRuntimeSnapshotMapsAllNonFailedCaptureStatuses() async throws {
        let scenarios: [(label: String, captureStatusJSON: String, expected: RuntimeCaptureStatus)] = [
            ("not_requested", "\"not_requested\"", .notRequested),
            ("in_progress", "\"in_progress\"", .inProgress),
            ("completed", "\"completed\"", .completed),
        ]

        for scenario in scenarios {
            let context = scenario.label
            let client = try makeClient(
                coreSnapshot: Self.makeRunCheckpointCaptureStatusSnapshot(
                    captureStatusJSON: scenario.captureStatusJSON,
                ),
            )

            let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "run-capture-\(scenario.label)")

            let checkpoint = try XCTUnwrap(snapshot.runs.first?.activeCheckpoint)
            XCTAssertEqual(
                checkpoint.captureStatus,
                scenario.expected,
                "\(context) capture status mismatch",
            )
        }
    }

    func testFetchRuntimeSnapshotIncludesRunsInRuntimeSnapshot() async throws {
        let client = try makeClient(
            coreSnapshot: Self.makeRunCheckpointPendingSnapshot(),
        )

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "run-included")

        XCTAssertEqual(snapshot.runs.count, 1)
        XCTAssertEqual(snapshot.runs.first?.id, "run-001")
        XCTAssertEqual(snapshot.runs.first?.methodId, "method-001")
        XCTAssertEqual(snapshot.runs.first?.methodName, "Execution")
        XCTAssertEqual(snapshot.runs.first?.status, "paused")
        XCTAssertEqual(snapshot.runs.first?.sessionId, "session-core")
        XCTAssertEqual(snapshot.runs.first?.delegationWorkerId, "worker-1")
    }

    func testFetchRuntimeSnapshotMapsCustomCheckpointKind() async throws {
        let client = try makeClient(
            coreSnapshot: Self.makeRunCustomCheckpointKindSnapshot(),
        )

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "run-custom-kind")

        let checkpoint = try XCTUnwrap(snapshot.runs.first?.activeCheckpoint)
        switch checkpoint.kind {
        case let .custom(label):
            XCTAssertEqual(label, "QA hold")
        default:
            XCTFail("expected custom checkpoint kind")
        }
    }

    func testFetchRuntimeSnapshotFailureScenarios() async throws {
        enum ExpectedError {
            case invalidResponse
            case runtimeUnavailable
        }

        let scenarios: [LabeledExpectationScenario<() throws -> RuntimeClient, ExpectedError>] = [
            LabeledExpectationScenario(
                label: "service_connection_missing",
                input: {
                    RuntimeClient(loadRuntimeServiceConnection: { nil })
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
                label: "service_snapshot_non_200",
                input: { [self] in
                    try makeClient(responseStatusCode: 503)
                },
                expected: .runtimeUnavailable,
            ),
        ]

        for scenario in scenarios {
            let context = scenarioContext(scenario.label)
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
                        message.contains("Runtime service"),
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
        // swiftformat:disable trailingCommas
        let scenarios: [LabeledExpectationScenario<
            (projectPath: String, workspaceId: String),
            (workspaceId: String, projectPath: String)
        >] = [
            // swiftformat:enable trailingCommas
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
        // swiftformat:disable trailingCommas
        let scenarios: [LabeledExpectationScenario<
            String,
            (reasonCode: String?, scopeResolution: String?, candidateCount: Int?)
        >] = [
            // swiftformat:enable trailingCommas
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

    func testFetchCoreRoutingSnapshotUsesActivationRouteQueryEndpoint() async throws {
        var capturedPath: String?
        var capturedBody: Data?
        let client = try RuntimeClient(
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:7812")),
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                capturedPath = request.url?.path
                capturedBody = request.httpBody
                let json = """
                {"workspace_id":"workspace-capacitor","project_path":"/Users/pete/Code/capacitor","status":"attached","target":{"kind":"tmux_session","terminal_app":"iterm2","session_name":"caps","pane_id":null,"host_tty":"/dev/ttys002"},"reason_code":"TMUX_SESSION_ATTACHED","reason":"Matched tmux session 'caps'","updated_at":"2026-03-15T05:40:01Z"}
                """
                return (Data(json.utf8), response)
            },
        )

        let snapshot = try await client.fetchCoreRoutingSnapshot(
            projectPath: "/Users/pete/Code/capacitor",
            workspaceId: nil,
            clientTty: "/dev/ttys002",
            sessionName: "caps",
        )

        XCTAssertEqual(capturedPath, "/runtime/routing/resolve")
        let body = try XCTUnwrap(capturedBody)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: String?]
        XCTAssertEqual(payload?["project_path"] ?? nil, "/Users/pete/Code/capacitor")
        XCTAssertEqual(payload?["client_tty"] ?? nil, "/dev/ttys002")
        XCTAssertEqual(payload?["session_name"] ?? nil, "caps")
        XCTAssertEqual(snapshot.target.terminalApp, "iterm2")
        XCTAssertEqual(snapshot.target.sessionName, "caps")
        XCTAssertEqual(snapshot.target.hostTty, "/dev/ttys002")
        XCTAssertEqual(snapshot.reasonCode, "TMUX_SESSION_ATTACHED")
    }

    func testFetchHealthReturnsCoreSnapshotModeHealth() async throws {
        let client = try makeClient()

        let health = try await client.fetchHealth()

        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.protocolVersion, 1)
        XCTAssertEqual(health.schemaVersion, 3)
        XCTAssertEqual(health.authMode, "bearer")
        XCTAssertEqual(health.serviceMode, "bootstrap_only")
        XCTAssertTrue(health.version.contains("runtime-service"))
    }

    func testFetchHealthRejectsMissingSchemaVersionAndRequestsCompatibilityRestart() async throws {
        let restartRequested = expectation(description: "compatibility restart requested")
        let client = try RuntimeClient(
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:7812")),
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                let json = """
                {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":1,"auth_mode":"bearer","service_mode":"bootstrap_only"}
                """
                return (Data(json.utf8), response)
            },
        )

        var observedHealth: RuntimeHealth?
        var observedMinimumSchemaVersion: Int?
        client.setIncompatibleSchemaHandler { health, minimumSchemaVersion in
            observedHealth = health
            observedMinimumSchemaVersion = minimumSchemaVersion
            restartRequested.fulfill()
        }

        do {
            _ = try await client.fetchHealth()
            XCTFail("expected runtimeUnavailable for missing schema version")
        } catch let error as RuntimeClientError {
            switch error {
            case let .runtimeUnavailable(message):
                XCTAssertTrue(message.contains("schema version"), "message mismatch: \(message)")
            default:
                XCTFail("unexpected RuntimeClientError: \(error)")
            }
        }

        await fulfillment(of: [restartRequested], timeout: 0.5)
        XCTAssertNil(observedHealth?.schemaVersion)
        XCTAssertEqual(observedMinimumSchemaVersion, 3)
    }

    func testFetchHealthRejectsUnexpectedProtocolVersion() async throws {
        let client = try RuntimeClient(
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:7812")),
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                let json = """
                {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":99,"auth_mode":"bearer","service_mode":"bootstrap_only"}
                """
                return (Data(json.utf8), response)
            },
        )

        do {
            _ = try await client.fetchHealth()
            XCTFail("expected runtimeUnavailable for mismatched protocol version")
        } catch let error as RuntimeClientError {
            switch error {
            case let .runtimeUnavailable(message):
                XCTAssertTrue(message.contains("health"), "message mismatch: \(message)")
            default:
                XCTFail("unexpected RuntimeClientError: \(error)")
            }
        }
    }

    func testFetchHealthRejectsUnexpectedAuthMode() async throws {
        let client = try RuntimeClient(
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:7812")),
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                let json = """
                {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":1,"auth_mode":"none","service_mode":"bootstrap_only"}
                """
                return (Data(json.utf8), response)
            },
        )

        do {
            _ = try await client.fetchHealth()
            XCTFail("expected runtimeUnavailable for mismatched auth mode")
        } catch let error as RuntimeClientError {
            switch error {
            case let .runtimeUnavailable(message):
                XCTAssertTrue(message.contains("health"), "message mismatch: \(message)")
            default:
                XCTFail("unexpected RuntimeClientError: \(error)")
            }
        }
    }

    func testFetchHealthRejectsUnexpectedServiceMode() async throws {
        let client = try RuntimeClient(
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:7812")),
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                let json = """
                {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":1,"auth_mode":"bearer","service_mode":"daemon"}
                """
                return (Data(json.utf8), response)
            },
        )

        do {
            _ = try await client.fetchHealth()
            XCTFail("expected runtimeUnavailable for mismatched service mode")
        } catch let error as RuntimeClientError {
            switch error {
            case let .runtimeUnavailable(message):
                XCTAssertTrue(message.contains("health"), "message mismatch: \(message)")
            default:
                XCTFail("unexpected RuntimeClientError: \(error)")
            }
        }
    }

    func testMutateDelegationSuccessDoesNotThrow() async throws {
        let client = try makeMutationClient(
            mutationResponse: #"{"ok":true,"message":"delegation started"}"#,
        )

        try await client.mutateDelegation(RuntimeDelegationMutationRequest(
            kind: "start",
            projectPath: "/tmp/test",
            workerId: "worker-1",
            ideaId: nil,
            worktreeName: "wt-1",
            worktreePath: "/tmp/wt",
            sessionId: nil,
            milestoneId: nil,
            briefPath: nil,
            manifestPath: nil,
            reviewDecision: nil,
            note: nil,
        ))
    }

    func testMutateDelegationRejectedThrowsMutationRejected() async throws {
        let client = try makeMutationClient(
            mutationResponse: #"{"ok":false,"message":"delegation already active for project"}"#,
        )

        do {
            try await client.mutateDelegation(RuntimeDelegationMutationRequest(
                kind: "start",
                projectPath: "/tmp/test",
                workerId: "worker-1",
                ideaId: nil,
                worktreeName: "wt-1",
                worktreePath: "/tmp/wt",
                sessionId: nil,
                milestoneId: nil,
                briefPath: nil,
                manifestPath: nil,
                reviewDecision: nil,
                note: nil,
            ))
            XCTFail("expected mutationRejected error")
        } catch let error as RuntimeClientError {
            switch error {
            case let .mutationRejected(message):
                XCTAssertEqual(message, "delegation already active for project")
            default:
                XCTFail("unexpected RuntimeClientError: \(error)")
            }
        }
    }

    func testMutateDelegationNon200ThrowsRuntimeUnavailable() async throws {
        let client = try makeMutationClient(
            mutationResponse: #"{"error":"not found"}"#,
            statusCode: 404,
        )

        do {
            try await client.mutateDelegation(RuntimeDelegationMutationRequest(
                kind: "start",
                projectPath: "/tmp/test",
                workerId: "worker-1",
                ideaId: nil,
                worktreeName: nil,
                worktreePath: nil,
                sessionId: nil,
                milestoneId: nil,
                briefPath: nil,
                manifestPath: nil,
                reviewDecision: nil,
                note: nil,
            ))
            XCTFail("expected runtimeUnavailable error")
        } catch let error as RuntimeClientError {
            switch error {
            case .runtimeUnavailable:
                break
            default:
                XCTFail("unexpected RuntimeClientError: \(error)")
            }
        }
    }

    func testMutateRunSuccessDoesNotThrow() async throws {
        let client = try makeMutationClient(
            mutationResponse: #"{"ok":true,"message":"run capture claimed"}"#,
        )

        try await client.mutateRun(makeRunMutationRequest())
    }

    func testMutateRunRejectedThrowsMutationRejected() async throws {
        let client = try makeMutationClient(
            mutationResponse: #"{"ok":false,"message":"run mutation rejected"}"#,
        )

        do {
            try await client.mutateRun(makeRunMutationRequest())
            XCTFail("expected mutationRejected error")
        } catch let error as RuntimeClientError {
            switch error {
            case let .mutationRejected(message):
                XCTAssertEqual(message, "run mutation rejected")
            default:
                XCTFail("unexpected RuntimeClientError: \(error)")
            }
        }
    }

    func testMutateRunNon200ThrowsRuntimeUnavailable() async throws {
        let client = try makeMutationClient(
            mutationResponse: #"{"error":"not found"}"#,
            statusCode: 404,
        )

        do {
            try await client.mutateRun(makeRunMutationRequest())
            XCTFail("expected runtimeUnavailable error")
        } catch let error as RuntimeClientError {
            switch error {
            case .runtimeUnavailable:
                break
            default:
                XCTFail("unexpected RuntimeClientError: \(error)")
            }
        }
    }

    func testMutateRunTargetsRuntimeRunMutateEndpoint() async throws {
        var capturedRequest: URLRequest?
        let client = try makeMutationClient(
            mutationResponse: #"{"ok":true,"message":"run capture claimed"}"#,
            requestObserver: { request in
                capturedRequest = request
            },
        )

        try await client.mutateRun(makeRunMutationRequest())

        XCTAssertEqual(capturedRequest?.url?.path, "/runtime/run/mutate")
        XCTAssertEqual(
            capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer service-secret",
        )
        let body = try XCTUnwrap(capturedRequest?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["checkpoint_id"] as? String, "checkpoint-001")
        XCTAssertEqual(payload["capture_request_id"] as? String, "capture-001")
        XCTAssertNil(payload["capture_requested"])
    }

    func testRuntimeRunMutationRequestEncodesCustomCheckpointKind() throws {
        let request = makeRunMutationRequest(checkpointKind: .custom(label: "QA hold"))

        let data = try JSONEncoder().encode(request)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let checkpointKind = try XCTUnwrap(payload["checkpoint_kind"] as? [String: Any])
        let custom = try XCTUnwrap(checkpointKind["custom"] as? [String: Any])

        XCTAssertEqual(custom["label"] as? String, "QA hold")
    }

    func testRuntimeRunMutationRequestEncodesIdeaFieldsUsingSnakeCaseKeys() throws {
        let request = RuntimeRunMutationRequest(
            kind: "create",
            projectPath: "/tmp/core-project",
            runId: "run-idea-encode",
            checkpointId: nil,
            methodId: "method-001",
            involvement: nil,
            checkpointKind: nil,
            checkpointTitle: nil,
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: nil,
            decisionAction: nil,
            decisionNote: nil,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            captureRequestId: nil,
            clientId: nil,
            observedCaptureUrl: nil,
            captureFailureReason: nil,
            completedMediaArtifacts: [],
            ideaId: "test-1",
            ideaTitle: "Fix bug",
            ideaDescription: "Description",
        )

        let encoded = try JSONEncoder().encode(request)
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertTrue(json.contains(#""idea_id":"test-1""#))
        XCTAssertTrue(json.contains(#""idea_title":"Fix bug""#))
        XCTAssertTrue(json.contains(#""idea_description":"Description""#))
    }

    func testFetchRuntimeSnapshotDecodesRunIdeaFields() async throws {
        let client = try makeClient(
            coreSnapshot: Self.makeRunIdeaFieldsSnapshot(
                ideaFieldsJSON: #","idea_id":"test-1","idea_title":"Fix bug","idea_description":"Description""#,
            ),
        )

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "run-idea-fields")
        let run = try XCTUnwrap(snapshot.runs.first)

        XCTAssertEqual(run.ideaId, "test-1")
        XCTAssertEqual(run.ideaTitle, "Fix bug")
        XCTAssertEqual(run.ideaDescription, "Description")
    }

    func testFetchRuntimeSnapshotDecodesRunWithoutIdeaFieldsAsNil() async throws {
        let client = try makeClient(
            coreSnapshot: Self.makeRunIdeaFieldsSnapshot(),
        )

        let snapshot = try await client.fetchRuntimeSnapshot(correlationId: "run-idea-fields-omitted")
        let run = try XCTUnwrap(snapshot.runs.first)

        XCTAssertNil(run.ideaId)
        XCTAssertNil(run.ideaTitle)
        XCTAssertNil(run.ideaDescription)
    }

    private func makeMutationClient(
        mutationResponse: String,
        statusCode: Int = 200,
        requestObserver: ((URLRequest) -> Void)? = nil,
    ) throws -> RuntimeClient {
        RuntimeClient(
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: URL(string: "http://127.0.0.1:7812")!,
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                requestObserver?(request)
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                return (Data(mutationResponse.utf8), response)
            },
        )
    }

    private func makeClient(
        coreSnapshot: Data? = nil,
        responseStatusCode: Int = 200,
    ) throws -> RuntimeClient {
        RuntimeClient(
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: URL(string: "http://127.0.0.1:7812")!,
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: responseStatusCode,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )

                switch request.url?.path {
                case "/health":
                    let json = """
                    {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":1,"schema_version":3,"auth_mode":"bearer","service_mode":"bootstrap_only"}
                    """
                    return (Data(json.utf8), response)
                case "/runtime/routing/resolve":
                    return (
                        Self.makeRoutingResolveResponse(
                            requestBody: request.httpBody,
                            coreSnapshot: coreSnapshot ?? Self.makeDefaultCoreSnapshot(),
                        ),
                        response,
                    )
                case "/runtime/snapshot":
                    return (coreSnapshot ?? Self.makeDefaultCoreSnapshot(), response)
                default:
                    return (Data(), response)
                }
            },
        )
    }

    private func assertAttachedTmuxRoute(
        _ snapshot: CoreRoutingSnapshot,
        expectedReasonCode: String? = nil,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(snapshot.status, "attached", "\(context) status mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.target.kind, "tmux_pane", "\(context) target kind mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.target.paneId, "%42", "\(context) pane mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.target.sessionName, "core", "\(context) session mismatch", file: file, line: line)
        XCTAssertEqual(snapshot.target.hostTty, "/dev/ttys099", "\(context) host tty mismatch", file: file, line: line)
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

    private static func makeDelegationReviewNeededSnapshot() -> Data {
        makeCoreSnapshotResponse(
            delegationJSON: """
            ,"delegations":[{"project_path":"/tmp/core-project","worker_id":"worker-1","idea_id":"idea-1","worktree_name":"delegation-worker-1","worktree_path":"/tmp/core-project/.capacitor/worktrees/delegation-worker-1","session_id":"worker-session-1","status":"review_needed","started_at":"2026-02-28T19:00:00Z","updated_at":"2026-02-28T19:05:00Z","current_review":{"milestone_id":"01","brief_path":"/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/brief.md","manifest_path":"/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/manifest.json","requested_at":"2026-02-28T19:05:00Z"}}]
            """,
        )
    }

    private static func makeDelegationResumePendingSnapshot() -> Data {
        makeCoreSnapshotResponse(
            delegationJSON: """
            ,"delegations":[{"project_path":"/tmp/core-project","worker_id":"worker-1","idea_id":"idea-1","worktree_name":"delegation-worker-1","worktree_path":"/tmp/core-project/.capacitor/worktrees/delegation-worker-1","session_id":"worker-session-1","status":"resume_pending","started_at":"2026-02-28T19:00:00Z","updated_at":"2026-02-28T19:05:00Z","submitted_milestone_id":"01","current_review":{"milestone_id":"01","brief_path":"/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/brief.md","manifest_path":"/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/manifest.json","requested_at":"2026-02-28T19:05:00Z"}}]
            """,
        )
    }

    private static func makeRunCheckpointPendingSnapshot() -> Data {
        makeRunCheckpointSnapshot(captureStatusJSON: #""pending""#)
    }

    private static func makeRunCheckpointFailedSnapshot() -> Data {
        makeRunCheckpointSnapshot(
            captureStatusJSON: #"{"failed":{"reason":"timeout"}}"#,
            updatedAt: "2026-02-28T19:03:00Z",
            mediaArtifactsJSON:
            #"[{"artifact_type":"screenshot","path":"/tmp/core-project/.artifacts/web-capture.png","label":"Web capture","width":1440,"height":900,"duration_secs":null}]"#,
            mermaidSourcesJSON: #"[{"label":"Sequence","source":"graph LR; A-->B"}]"#,
            captureClaimJSON:
            #"{"capture_request_id":"capture-001","client_id":"capacitor-mac-1234","claimed_at":"2026-02-28T19:02:00Z","observed_capture_url":"http://localhost:3000"}"#,
        )
    }

    private static func makeRunCheckpointCaptureStatusSnapshot(
        captureStatusJSON: String,
    ) -> Data {
        makeCoreSnapshotResponse(
            runsJSON: """
            ,"runs":[{"id":"run-001","project_path":"/tmp/core-project","method_id":"method-001","method_name":"Execution","status":"paused","session_id":"session-core","delegation_worker_id":"worker-1","created_at":"2026-02-28T19:00:00Z","updated_at":"2026-02-28T19:01:00Z","active_checkpoint":{"id":"checkpoint-001","phase_id":"phase-001","kind":"implementation_milestone","status":"active","title":"Capture homepage","summary":"Verify the implementation checkpoint.","brief_path":"/tmp/core-project/brief.md","manifest_path":"/tmp/core-project/manifest.json","media_artifacts":[],"mermaid_sources":[],"capture_status":\(captureStatusJSON),"capture_url":"http://localhost:3000","capture_claim":null,"created_at":"2026-02-28T19:00:00Z","decided_at":null}}]
            """,
        )
    }

    private static func makeRunIdeaFieldsSnapshot(
        ideaFieldsJSON: String = "",
    ) -> Data {
        makeCoreSnapshotResponse(
            runsJSON: """
            ,"runs":[{"id":"run-idea-001","project_path":"/tmp/core-project","method_id":"method-001","method_name":"Execution","status":"active","session_id":"session-core","delegation_worker_id":"worker-1","status_message":"Drafting packet","created_at":"2026-02-28T19:00:00Z","updated_at":"2026-02-28T19:03:00Z","active_checkpoint":null\(ideaFieldsJSON)}]
            """,
        )
    }

    private static func makeRunCustomCheckpointKindSnapshot() -> Data {
        makeCoreSnapshotResponse(
            runsJSON: """
            ,"runs":[{"id":"run-001","project_path":"/tmp/core-project","method_id":"method-001","method_name":"Execution","status":"paused","session_id":"session-core","delegation_worker_id":"worker-1","created_at":"2026-02-28T19:00:00Z","updated_at":"2026-02-28T19:03:00Z","active_checkpoint":{"id":"checkpoint-001","phase_id":"phase-001","kind":{"custom":{"label":"QA hold"}},"status":"active","title":"Capture homepage","summary":"Wait for QA confirmation.","brief_path":null,"manifest_path":null,"media_artifacts":[],"mermaid_sources":[],"capture_status":"pending","capture_url":"http://localhost:3000","capture_claim":null,"created_at":"2026-02-28T19:00:00Z","decided_at":null}}]
            """,
        )
    }

    private static func makeRunCheckpointSnapshot(
        captureStatusJSON: String,
        updatedAt: String = "2026-02-28T19:01:00Z",
        mediaArtifactsJSON: String = "[]",
        mermaidSourcesJSON: String = "[]",
        captureClaimJSON: String = "null",
    ) -> Data {
        makeCoreSnapshotResponse(
            runsJSON: """
            ,"runs":[{"id":"run-001","project_path":"/tmp/core-project","method_id":"method-001","method_name":"Execution","status":"paused","session_id":"session-core","delegation_worker_id":"worker-1","created_at":"2026-02-28T19:00:00Z","updated_at":"\(updatedAt)","active_checkpoint":{"id":"checkpoint-001","phase_id":"phase-001","kind":"implementation_milestone","status":"active","title":"Capture homepage","summary":"Verify the implementation checkpoint.","brief_path":"/tmp/core-project/brief.md","manifest_path":"/tmp/core-project/manifest.json","media_artifacts":\(mediaArtifactsJSON),"mermaid_sources":\(mermaidSourcesJSON),"capture_status":\(captureStatusJSON),"capture_url":"http://localhost:3000","capture_claim":\(captureClaimJSON),"created_at":"2026-02-28T19:00:00Z","decided_at":null}}]
            """,
        )
    }

    private static func makeRoutingResolveResponse(
        requestBody: Data?,
        coreSnapshot: Data,
    ) -> Data {
        let requestObject = requestBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        let requestProjectPath = PathNormalizer.normalize(requestObject["project_path"] as? String ?? "")
        let requestWorkspaceId = (requestObject["workspace_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let snapshotObject = (try? JSONSerialization.jsonObject(with: coreSnapshot) as? [String: Any]) ?? [:]
        let routes = snapshotObject["routing"] as? [[String: Any]] ?? []

        if let route = routes.first(where: { route in
            let routeWorkspaceId = route["workspace_id"] as? String
            let routeProjectPath = PathNormalizer.normalize(route["project_path"] as? String ?? "")
            if let requestWorkspaceId, !requestWorkspaceId.isEmpty, routeWorkspaceId == requestWorkspaceId {
                return true
            }
            return routeProjectPath == requestProjectPath
        }) {
            return (try? JSONSerialization.data(withJSONObject: route)) ?? Data("{}".utf8)
        }

        let unresolvedWorkspaceId = {
            if let requestWorkspaceId, !requestWorkspaceId.isEmpty {
                return requestWorkspaceId
            }
            return requestProjectPath
        }()
        let json = """
        {"workspace_id":"\(unresolvedWorkspaceId)","project_path":"\(requestProjectPath)","status":"unavailable","target":{"kind":"none","terminal_app":null,"session_name":null,"pane_id":null,"host_tty":null},"reason_code":"NO_TRUSTED_EVIDENCE","reason":"No routing evidence available in runtime service","updated_at":"2026-02-28T19:00:00Z"}
        """
        return Data(json.utf8)
    }

    private static func makeCoreSnapshotResponse(
        shellUpdatedAt: String = "2026-02-28T19:00:00Z",
        routeReasonCode: String = "tmux_client_attached",
        shellTmuxClientTty: String? = "/dev/ttys099",
        delegationJSON: String = ",\"delegations\":[]",
        runsJSON: String = ",\"runs\":[]",
    ) -> Data {
        let shellTmuxClientTtyJSON = if let shellTmuxClientTty {
            "\"\(shellTmuxClientTty)\""
        } else {
            "null"
        }
        let json = """
        {"projects":[{"project_id":"/tmp/core-project/.git","workspace_id":"workspace-core","project_path":"/tmp/core-project","display_name":"core-project","state":"working","updated_at":"2026-02-28T19:00:00Z","state_changed_at":"2026-02-28T19:00:00Z","representative_session_id":"session-core","latest_session_id":"session-core","session_count":1,"active_count":1,"has_session":true}],"sessions":[{"session_id":"session-core","pid":4242,"cwd":"/tmp/core-project","project_id":"/tmp/core-project/.git","project_path":"/tmp/core-project","workspace_id":"workspace-core","state":"working","state_changed_at":"2026-02-28T19:00:00Z","updated_at":"2026-02-28T19:00:00Z","last_event":"user_prompt_submit","last_activity_at":"2026-02-28T19:00:00Z","tools_in_flight":1,"ready_reason":null}],"shells":[{"pid":4242,"cwd":"/tmp/core-project","tty":"/dev/ttys001","parent_app":"Ghostty","tmux_session":"core","tmux_client_tty":\(shellTmuxClientTtyJSON),"tmux_pane":"%42","updated_at":"\(shellUpdatedAt)"}],"routing":[{"workspace_id":"workspace-core","project_path":"/tmp/core-project","status":"attached","target":{"kind":"tmux_pane","terminal_app":"Ghostty","session_name":"core","pane_id":"%42","host_tty":"/dev/ttys099"},"reason_code":"\(routeReasonCode)","reason":"Attached tmux pane","updated_at":"2026-02-28T19:00:00Z"}]\(delegationJSON)\(runsJSON),"diagnostics":{"events_ingested":7,"sessions_tracked":1,"shell_signals_tracked":1,"events_skipped":0,"stale_events_skipped":0,"informational_events_skipped":0,"reducer_events_skipped":0,"last_error":null},"generated_at":"2026-02-28T19:00:00Z"}
        """
        return Data(json.utf8)
    }

    private func makeRunMutationRequest(
        kind: String = "capture_claim",
        checkpointKind: RuntimeCheckpointKind? = .implementationMilestone,
    ) -> RuntimeRunMutationRequest {
        RuntimeRunMutationRequest(
            kind: kind,
            projectPath: "/tmp/core-project",
            runId: "run-001",
            checkpointId: "checkpoint-001",
            methodId: "method-001",
            involvement: "driver",
            checkpointKind: checkpointKind,
            checkpointTitle: "Capture homepage",
            checkpointSummary: "Verify the implementation checkpoint.",
            checkpointBriefPath: "/tmp/core-project/brief.md",
            checkpointManifestPath: "/tmp/core-project/manifest.json",
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: "http://localhost:3000",
            decisionAction: nil,
            decisionNote: nil,
            sessionId: "session-core",
            delegationWorkerId: "worker-1",
            statusMessage: nil,
            captureRequestId: "capture-001",
            clientId: "capacitor-mac-1234",
            observedCaptureUrl: "http://localhost:3000",
            captureFailureReason: nil,
            completedMediaArtifacts: [],
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }
}
