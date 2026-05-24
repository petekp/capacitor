#if DEBUG
    @testable import Capacitor
    import XCTest

    final class CircuitReceiptProductLoopTests: XCTestCase {
        func testMapsCapturedIdeaToContractIdea() {
            let project = makeProject()
            let idea = makeIdea(id: "01HXIDEA", title: "Prove the receipt-first Capacitor <-> Circuit slice")

            let mapped = CircuitCapturedIdeaMapper.map(idea: idea, project: project)

            XCTAssertEqual(mapped.kind, "idea")
            XCTAssertEqual(mapped.id, "idea-01HXIDEA")
            XCTAssertEqual(mapped.project.name, "capacitor")
            XCTAssertEqual(mapped.project.path, "/Users/pete/Code/capacitor")
            XCTAssertTrue(mapped.text.contains("Prove the receipt-first Capacitor <-> Circuit slice"))
            XCTAssertEqual(mapped.capturedAt, "2026-05-24T01:30:00Z")
        }

        func testPlanningBoundaryWritesRequestAndDecodesHeadlessResponse() async throws {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = CircuitReceiptProductLoopPaths(capacitorRoot: root)
            let boundary = CircuitProtocolProcessBoundary(paths: paths, runShell: { command in
                XCTAssertTrue(command.contains("scripts/circuit/plan-goal-packet.py --stdin"))
                return (0, Self.planningResponseJSON())
            })
            let request = CircuitPlanningRequest(
                kind: "plan_goal_packet_request",
                targetAgent: "claude_code",
                idea: CircuitCapturedIdeaMapper.map(idea: makeIdea(), project: makeProject()),
            )

            let response = try await boundary.plan(request)

            XCTAssertEqual(response.kind, "plan_goal_packet_response")
            XCTAssertEqual(response.planning.mode, "headless_receipt_first_planner")
            XCTAssertEqual(response.planning.circuitRuntimeInvoked, false)
            XCTAssertEqual(response.goalPacket.targetAgent, "claude_code")
            XCTAssertTrue(response.goalPacket.body.contains("CIRCUIT_RECEIPT"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.planningRequestURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.planningResponseURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.goalPacketURL.path))
        }

        func testProductLoopRunsPlanningLaunchNormalizeAndProjectionWithFakes() async throws {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            let paths = CircuitReceiptProductLoopPaths(capacitorRoot: root)
            let boundary = CircuitProtocolProcessBoundary(paths: paths, runShell: { command in
                if command.contains("plan-goal-packet.py") {
                    return (0, Self.planningResponseJSON())
                }
                if command.contains("normalize-agent-event.py") {
                    let requestData = try! Data(contentsOf: paths.normalizationRequestURL)
                    let request = try! JSONSerialization.jsonObject(with: requestData) as! [String: Any]
                    XCTAssertEqual(request["kind"] as? String, "normalize_agent_event_request")
                    XCTAssertTrue((request["raw_receipt_text"] as? String)?.hasPrefix("CIRCUIT_RECEIPT") == true)
                    let adapterResult = request["adapter_result"] as? [String: Any]
                    XCTAssertEqual(adapterResult?["host"] as? String, "claude_code")
                    XCTAssertEqual(request["source_raw_receipt_path"] as? String, ReceiptFirstProofArtifacts(proofDirectoryURL: paths.nativeSessionDirectory).rawReceiptURL.path)
                    return (0, Self.agentEventJSON(rawReceiptPath: ReceiptFirstProofArtifacts(proofDirectoryURL: paths.nativeSessionDirectory).rawReceiptURL.path))
                }
                return (1, "unexpected command")
            })
            let adapter = ReceiptFirstProofAdapter(
                runShell: { _ in
                    _Concurrency.Task {
                        try? await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
                        try? Self.writeCompletedCapture(in: paths.nativeSessionDirectory)
                    }
                    return (0, "launched")
                },
                terminalScriptBuilder: { _, command in command },
            )
            let loop = CircuitReceiptProductLoop(paths: paths, boundary: boundary, adapter: adapter)

            let result = try await loop.run(project: makeProject(), idea: makeIdea())

            XCTAssertEqual(result.planningResponse.goalPacket.targetAgent, "claude_code")
            XCTAssertEqual(result.launchResult.launch.packet.id, "goal-packet-claude-loop")
            XCTAssertEqual(result.agentEvent.session.host, "claude_code")
            XCTAssertEqual(result.projection.state, "complete")
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.agentEventURL.path))
        }

        private static func planningResponseJSON() -> String {
            """
            {
              "kind": "plan_goal_packet_response",
              "planning": {
                "mode": "headless_receipt_first_planner",
                "circuit_runtime_invoked": false
              },
              "pursuit_proposal": {
                "kind": "pursuit_proposal",
                "id": "pursuit-claude-loop",
                "idea_id": "idea-01HXIDEA",
                "goal": "Prove the receipt-first Capacitor <-> Circuit slice.",
                "why_now": "The handoff is ready.",
                "dependencies": [],
                "risks": [],
                "suggested_agent": "claude_code",
                "checkpoint_condition": "Stop before orchestration.",
                "delivery_target": "docs/circuit/proofs/receipt-first-product-loop/"
              },
              "goal_packet": {
                "kind": "goal_packet",
                "id": "goal-packet-claude-loop",
                "idea_id": "idea-01HXIDEA",
                "pursuit_id": "pursuit-claude-loop",
                "target_agent": "claude_code",
                "project_path": "/Users/pete/Code/capacitor",
                "body": "/goal Prove the loop. End with CIRCUIT_RECEIPT followed by JSON.",
                "expected_return": "receipt",
                "receipt_expectation": "Return a compact receipt.",
                "checkpoint_expectation": "Ask only if owner input changes the work."
              }
            }
            """
        }

        private static func agentEventJSON(rawReceiptPath: String) -> String {
            """
            {
              "kind": "agent_event",
              "id": "event-receipt-claude-loop",
              "goal_packet_id": "goal-packet-claude-loop",
              "session": {
                "host": "claude_code",
                "session_id": "session-receipt-test",
                "visible_to_owner": true
              },
              "type": "receipt",
              "payload": {
                "kind": "receipt",
                "id": "receipt-claude-loop",
                "goal_packet_id": "goal-packet-claude-loop",
                "status": "completed",
                "summary": "Loop completed.",
                "evidence": [],
                "changed_paths": [],
                "open_risks": [],
                "next_action": "Stop."
              },
              "recorded_at": "2026-05-24T01:35:00Z",
              "normalization": {
                "mode": "headless_receipt_normalizer",
                "source_raw_receipt_path": "\(rawReceiptPath)",
                "circuit_runtime_invoked": false
              }
            }
            """
        }

        private static func writeCompletedCapture(in proofDirectory: URL) throws {
            let artifacts = ReceiptFirstProofArtifacts(proofDirectoryURL: proofDirectory)
            try FileManager.default.createDirectory(at: proofDirectory, withIntermediateDirectories: true)
            let rawReceipt = """
            CIRCUIT_RECEIPT
            {"kind":"receipt","id":"receipt-claude-loop","goal_packet_id":"goal-packet-claude-loop","status":"completed","summary":"Loop completed.","evidence":[],"changed_paths":[],"open_risks":[],"next_action":"Stop."}
            """ + "\n"
            try Data(rawReceipt.utf8).write(to: artifacts.rawReceiptURL)

            let result: [String: Any] = [
                "kind": "native_receipt_first_proof_result",
                "status": "native_capture_complete",
                "finished_at": "2026-05-24T01:35:00Z",
                "goal_packet_id": "goal-packet-claude-loop",
                "host": "claude_code",
                "body_sha256": "abc123",
                "agent_exit_code": 0,
                "codex_exit_code": 0,
                "visible_surface": "Ghostty launched by Capacitor Circuit first-slice action",
                "injection": [
                    "mode": "stdin initial prompt",
                    "body_path": artifacts.insertedBodyURL.path,
                    "exact_body_match": true,
                ],
                "capture": [
                    "mode": "stdout and last-message capture",
                    "raw_receipt_path": artifacts.rawReceiptURL.path,
                    "preserved_for_normalization": true,
                ],
                "limits": [
                    "One controlled claude_code CLI session only.",
                    "No Circuit runtime invocation.",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: artifacts.resultURL)
        }

        private func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("circuit-product-loop-\(UUID().uuidString)", isDirectory: true)
        }

        private func makeIdea(
            id: String = "01HXIDEA",
            title: String = "Prove the receipt-first Capacitor <-> Circuit slice",
        ) -> Idea {
            Idea(
                id: id,
                title: title,
                description: "Use one visible Claude Code CLI session and return a CIRCUIT_RECEIPT.",
                added: "2026-05-24T01:30:00Z",
                effort: "small",
                status: "open",
                triage: "pending",
                related: nil,
            )
        }

        private func makeProject() -> Project {
            Project(
                name: "capacitor",
                path: "/Users/pete/Code/capacitor",
                displayPath: "~/Code/capacitor",
                lastActive: nil,
                claudeMdPath: nil,
                claudeMdPreview: nil,
                hasLocalSettings: false,
                taskCount: 0,
                stats: nil,
                isMissing: false,
            )
        }
    }
#endif
