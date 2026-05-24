#if DEBUG
    @testable import Capacitor
    import XCTest

    final class ReceiptFirstProofAdapterTests: XCTestCase {
        func testDefaultPathsPointAtCapacitorOwnedProofArtifacts() {
            let root = URL(fileURLWithPath: "/tmp/capacitor", isDirectory: true)
            let artifacts = ReceiptFirstProofArtifacts(proofDirectoryURL: root.appendingPathComponent("proof"))

            XCTAssertEqual(
                ReceiptFirstProofArtifacts.defaultGoalPacketURL(capacitorRoot: root).path,
                "/tmp/capacitor/docs/circuit/proofs/receipt-first-fixture/03-goal-packet.json",
            )
            XCTAssertEqual(
                ReceiptFirstProofArtifacts.defaultProofDirectoryURL(capacitorRoot: root).path,
                "/tmp/capacitor/docs/circuit/proofs/receipt-first-native-adapter",
            )
            XCTAssertEqual(
                artifacts.lastMessageURL.path,
                "/tmp/capacitor/proof/05-native-agent-last-message.txt",
            )
        }

        func testPrepareLaunchReadsExactContractGoalBodyAndBuildsCaptureCommand() throws {
            let packetURL = ReceiptFirstProofArtifacts.defaultGoalPacketURL()
            guard FileManager.default.fileExists(atPath: packetURL.path) else {
                throw XCTSkip("Capacitor-owned proof packet is not present on this machine")
            }

            let proofDirectory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: proofDirectory) }

            let adapter = ReceiptFirstProofAdapter(
                runShell: { _ in
                    XCTFail("prepareLaunch must not touch the terminal")
                    return (1, nil)
                },
                terminalScriptBuilder: { _, _ in
                    XCTFail("prepareLaunch must not build the terminal script")
                    return ""
                },
            )

            let launch = try adapter.prepareLaunch(
                packetURL: packetURL,
                proofDirectoryURL: proofDirectory,
            )

            XCTAssertEqual(launch.packet.id, "goal-packet-receipt-first-001")
            XCTAssertEqual(launch.packet.targetAgent, "codex")
            XCTAssertEqual(launch.packet.expectedReturn, "receipt")
            XCTAssertEqual(launch.bodySHA256, "7aa84e38bb5cd2213eca0ce495a64a31e3e52e461f309261056ef0bdefb83346")
            XCTAssertEqual(
                try String(contentsOf: launch.artifacts.insertedBodyURL, encoding: .utf8),
                launch.packet.body,
            )
            XCTAssertTrue(launch.packet.body.contains("CIRCUIT_RECEIPT"))
            XCTAssertTrue(launch.command.contains("PROOF_CODEX_HOME=\"$(mktemp -d"))
            XCTAssertTrue(launch.command.contains("codex_home: isolated temp home with auth symlink only"))
            XCTAssertTrue(launch.command.contains("CODEX_HOME=\"$PROOF_CODEX_HOME\" codex exec --ignore-user-config --cd \"$PROJECT_PATH\" --sandbox read-only"))
            XCTAssertTrue(launch.command.contains("--output-last-message \"$LAST_MESSAGE_FILE\" - < \"$BODY_FILE\""))
            XCTAssertTrue(launch.command.contains("RAW_RECEIPT_FILE"))
            XCTAssertTrue(launch.command.contains("No Circuit runtime invocation."))
            XCTAssertTrue(launch.command.contains("No agent-reasoning orchestration, queueing, checkpoint relay, retries, or generalized session management."))
            XCTAssertFalse(launch.command.contains("method-runner"))
        }

        func testPrepareLaunchSupportsClaudeCodeGoalPacket() throws {
            let proofDirectory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: proofDirectory) }

            let packetURL = proofDirectory.appendingPathComponent("packet.json")
            try writePacket(
                to: packetURL,
                targetAgent: "claude_code",
                projectPath: "/Users/pete/Code/example",
                body: "/goal Run a tiny Claude receipt proof. End with CIRCUIT_RECEIPT followed by JSON.",
            )

            let adapter = ReceiptFirstProofAdapter()
            let launch = try adapter.prepareLaunch(
                packetURL: packetURL,
                proofDirectoryURL: proofDirectory,
            )

            XCTAssertEqual(launch.packet.targetAgent, "claude_code")
            XCTAssertTrue(launch.command.contains("claude_code"))
            XCTAssertTrue(launch.command.contains("Claude Code CLI with stdin prompt"))
            XCTAssertTrue(launch.command.contains("--print --model \"${CLAUDE_MODEL:-haiku}\" --permission-mode acceptEdits --output-format text < \"$BODY_FILE\""))
            XCTAssertFalse(launch.command.contains("codex exec"))
        }

        func testLaunchUsesInjectedTerminalScriptBuilderInsteadOfTouchingRealTerminal() async throws {
            let proofDirectory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: proofDirectory) }

            let packetURL = proofDirectory.appendingPathComponent("packet.json")
            try writePacket(
                to: packetURL,
                projectPath: "/Users/pete/Code/example",
                body: "/goal Run a tiny receipt proof. End with CIRCUIT_RECEIPT followed by JSON.",
            )

            var builtProjectPath: String?
            var builtCommand: String?
            var launchedScript: String?

            let adapter = ReceiptFirstProofAdapter(
                runShell: { script in
                    launchedScript = script
                    return (0, "osascript ok")
                },
                terminalScriptBuilder: { projectPath, command in
                    builtProjectPath = projectPath
                    builtCommand = command
                    return "TERMINAL_SCRIPT:\(command)"
                },
            )

            let result = try await adapter.launch(
                packetURL: packetURL,
                proofDirectoryURL: proofDirectory,
            )

            XCTAssertEqual(builtProjectPath, "/Users/pete/Code/example")
            XCTAssertEqual(launchedScript, "TERMINAL_SCRIPT:\(builtCommand ?? "")")
            XCTAssertEqual(result.shellExitCode, 0)
            XCTAssertEqual(result.shellOutput, "osascript ok")
            XCTAssertEqual(
                try String(contentsOf: result.launch.artifacts.insertedBodyURL, encoding: .utf8),
                result.launch.packet.body,
            )
            XCTAssertTrue(result.launch.command.hasPrefix("/bin/bash -lc "))
            XCTAssertTrue(result.launch.command.contains("visible_surface: Ghostty launched by Capacitor Circuit first-slice action"))
        }

        func testLaunchAndWaitForCaptureWaitsUntilRawReceiptAndResultExist() async throws {
            let proofDirectory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: proofDirectory) }

            let packetURL = proofDirectory.appendingPathComponent("packet.json")
            try writePacket(
                to: packetURL,
                projectPath: "/Users/pete/Code/example",
                body: "/goal Run a tiny receipt proof. End with CIRCUIT_RECEIPT followed by JSON.",
            )

            let adapter = ReceiptFirstProofAdapter(
                runShell: { _ in
                    _Concurrency.Task {
                        try? await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
                        try? self.writeCompletedCapture(in: proofDirectory)
                    }
                    return (0, "osascript ok")
                },
                terminalScriptBuilder: { _, command in command },
            )

            let result = try await adapter.launchAndWaitForCapture(
                packetURL: packetURL,
                proofDirectoryURL: proofDirectory,
                timeoutSeconds: 1,
                pollIntervalNanoseconds: 5_000_000,
            )

            XCTAssertEqual(result.launch.packet.id, "goal-packet-test-001")
            XCTAssertEqual(result.shellExitCode, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.launch.artifacts.rawReceiptURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.launch.artifacts.resultURL.path))
        }

        func testCaptureShellScriptPreservesRawReceiptWithFakeCodex() async throws {
            let proofDirectory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: proofDirectory) }

            let projectDirectory = proofDirectory.appendingPathComponent("project", isDirectory: true)
            let binDirectory = proofDirectory.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

            let fakeCodexURL = binDirectory.appendingPathComponent("codex")
            try writeFakeCodex(to: fakeCodexURL)

            let packetURL = proofDirectory.appendingPathComponent("packet.json")
            try writePacket(
                to: packetURL,
                projectPath: projectDirectory.path,
                body: "/goal Run a tiny receipt proof. End with CIRCUIT_RECEIPT followed by JSON.",
            )

            let adapter = ReceiptFirstProofAdapter()
            let launch = try adapter.prepareLaunch(
                packetURL: packetURL,
                proofDirectoryURL: proofDirectory,
            )

            let result = await TerminalLauncher.runBashScriptWithResult("""
            export PATH=\(shellEscape(binDirectory.path)):"$PATH"
            \(launch.shellScript)
            """)

            XCTAssertEqual(result.exitCode, 0, result.output ?? "missing output")
            let expectedRawReceipt = """
            CIRCUIT_RECEIPT
            {"kind":"receipt","id":"fake","goal_packet_id":"goal-packet-test-001","status":"completed","summary":"ok","evidence":[],"changed_paths":[],"open_risks":[],"next_action":"stop"}
            """ + "\n"
            XCTAssertEqual(
                try String(contentsOf: launch.artifacts.rawReceiptURL, encoding: .utf8),
                expectedRawReceipt,
            )

            let resultData = try Data(contentsOf: launch.artifacts.resultURL)
            let resultJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
            XCTAssertEqual(resultJSON["status"] as? String, "native_capture_complete")
            XCTAssertEqual(resultJSON["goal_packet_id"] as? String, "goal-packet-test-001")
        }

        func testExtractReceiptBlockUsesLastBalancedReceipt() {
            let transcript = """
            noise
            CIRCUIT_RECEIPT
            {"kind":"receipt","id":"old","summary":"ignore me"}
            more output
            CIRCUIT_RECEIPT
            {"kind":"receipt","id":"new","summary":"brace } inside string","evidence":["a"]}
            trailing output
            """

            XCTAssertEqual(
                ReceiptFirstProofAdapter.extractReceiptBlock(from: transcript),
                """
                CIRCUIT_RECEIPT
                {"kind":"receipt","id":"new","summary":"brace } inside string","evidence":["a"]}
                """,
            )
        }

        func testExtractReceiptBlockSupportsFencedJson() {
            let lastMessage = """
            Done.
            CIRCUIT_RECEIPT
            ```json
            {"kind":"receipt","id":"fenced","status":"completed"}
            ```
            """

            XCTAssertEqual(
                ReceiptFirstProofAdapter.extractReceiptBlock(from: lastMessage),
                """
                CIRCUIT_RECEIPT
                {"kind":"receipt","id":"fenced","status":"completed"}
                """,
            )
        }

        func testExtractReceiptBlockIgnoresMarkerTextInsideReceiptJson() {
            let lastMessage = """
            CIRCUIT_RECEIPT
            {"kind":"receipt","id":"real","evidence":["body contains CIRCUIT_RECEIPT followed by JSON"]}
            """

            XCTAssertEqual(
                ReceiptFirstProofAdapter.extractReceiptBlock(from: lastMessage),
                """
                CIRCUIT_RECEIPT
                {"kind":"receipt","id":"real","evidence":["body contains CIRCUIT_RECEIPT followed by JSON"]}
                """,
            )
        }

        func testRejectsPacketWithoutReceiptInstruction() throws {
            let proofDirectory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: proofDirectory) }

            let packetURL = proofDirectory.appendingPathComponent("packet.json")
            try writePacket(
                to: packetURL,
                projectPath: "/Users/pete/Code/example",
                body: "/goal Run a tiny proof without the receipt marker.",
            )

            let adapter = ReceiptFirstProofAdapter()

            XCTAssertThrowsError(
                try adapter.prepareLaunch(packetURL: packetURL, proofDirectoryURL: proofDirectory),
            ) { error in
                XCTAssertEqual(
                    error as? ReceiptFirstProofAdapterError,
                    .invalidGoalPacket("GoalPacket.body must contain the visible CIRCUIT_RECEIPT return instruction."),
                )
            }
        }

        private func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("receipt-proof-adapter-\(UUID().uuidString)", isDirectory: true)
        }

        private func writePacket(
            to url: URL,
            targetAgent: String = "codex",
            projectPath: String,
            body: String,
        ) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )

            let packet: [String: Any] = [
                "kind": "goal_packet",
                "id": "goal-packet-test-001",
                "idea_id": "idea-test-001",
                "pursuit_id": "pursuit-test-001",
                "target_agent": targetAgent,
                "project_path": projectPath,
                "body": body,
                "expected_return": "receipt",
                "receipt_expectation": "Return a compact receipt.",
                "checkpoint_expectation": "Ask only if owner input changes the work.",
            ]
            let data = try JSONSerialization.data(withJSONObject: packet, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        }

        private func writeFakeCodex(to url: URL) throws {
            let script = """
            #!/bin/bash
            set -euo pipefail

            LAST_MESSAGE=""
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --output-last-message)
                  LAST_MESSAGE="$2"
                  shift 2
                  ;;
                *)
                  shift
                  ;;
              esac
            done

            cat >/dev/null
            cat > "$LAST_MESSAGE" <<'OUT'
            fake codex completed
            CIRCUIT_RECEIPT
            {"kind":"receipt","id":"fake","goal_packet_id":"goal-packet-test-001","status":"completed","summary":"ok","evidence":[],"changed_paths":[],"open_risks":[],"next_action":"stop"}
            OUT
            cat "$LAST_MESSAGE"
            """

            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path,
            )
        }

        private func writeCompletedCapture(in proofDirectory: URL) throws {
            let artifacts = ReceiptFirstProofArtifacts(proofDirectoryURL: proofDirectory)
            let rawReceipt = """
            CIRCUIT_RECEIPT
            {"kind":"receipt","id":"fake","goal_packet_id":"goal-packet-test-001","status":"completed","summary":"ok","evidence":[],"changed_paths":[],"open_risks":[],"next_action":"stop"}
            """ + "\n"
            try Data(rawReceipt.utf8).write(to: artifacts.rawReceiptURL)

            let result: [String: Any] = [
                "kind": "native_receipt_first_proof_result",
                "status": "native_capture_complete",
                "finished_at": "2026-05-24T03:15:23Z",
                "goal_packet_id": "goal-packet-test-001",
                "body_sha256": "abc123",
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
                    "One controlled Codex exec session only.",
                    "No Circuit runtime invocation.",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: artifacts.resultURL)
        }
    }
#endif
