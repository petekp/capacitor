import CryptoKit
import Foundation

struct ReceiptFirstProofGoalPacket: Codable, Equatable {
    let kind: String
    let id: String
    let ideaID: String
    let pursuitID: String
    let targetAgent: String
    let projectPath: String
    let body: String
    let expectedReturn: String
    let receiptExpectation: String
    let checkpointExpectation: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case id
        case ideaID = "idea_id"
        case pursuitID = "pursuit_id"
        case targetAgent = "target_agent"
        case projectPath = "project_path"
        case body
        case expectedReturn = "expected_return"
        case receiptExpectation = "receipt_expectation"
        case checkpointExpectation = "checkpoint_expectation"
    }

    func validateForReceiptFirstProof() throws {
        guard kind == "goal_packet" else {
            throw ReceiptFirstProofAdapterError.invalidGoalPacket("Expected kind=goal_packet.")
        }
        guard targetAgent == "codex" || targetAgent == "claude_code" else {
            throw ReceiptFirstProofAdapterError.invalidGoalPacket("Slice 01 native proof only targets codex or claude_code.")
        }
        guard expectedReturn == "receipt" else {
            throw ReceiptFirstProofAdapterError.invalidGoalPacket("Slice 01 native proof only expects a receipt.")
        }
        guard body.contains("CIRCUIT_RECEIPT") else {
            throw ReceiptFirstProofAdapterError.invalidGoalPacket("GoalPacket.body must contain the visible CIRCUIT_RECEIPT return instruction.")
        }
    }
}

struct ReceiptFirstProofArtifacts: Equatable {
    let proofDirectoryURL: URL
    let insertedBodyURL: URL
    let transcriptURL: URL
    let lastMessageURL: URL
    let rawReceiptURL: URL
    let resultURL: URL

    init(proofDirectoryURL: URL) {
        self.proofDirectoryURL = proofDirectoryURL
        insertedBodyURL = proofDirectoryURL.appendingPathComponent("03-native-inserted-goal-body.txt")
        transcriptURL = proofDirectoryURL.appendingPathComponent("04-native-visible-session-transcript.txt")
        lastMessageURL = proofDirectoryURL.appendingPathComponent("05-native-agent-last-message.txt")
        rawReceiptURL = proofDirectoryURL.appendingPathComponent("06-native-captured-raw-receipt.txt")
        resultURL = proofDirectoryURL.appendingPathComponent("07-native-adapter-result.json")
    }

    static func defaultCapacitorRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> URL {
        if let configuredRoot = environment["CAPACITOR_REPO_ROOT"], !configuredRoot.isEmpty {
            return URL(fileURLWithPath: configuredRoot, isDirectory: true)
        }

        let localRoot = "/Users/petepetrash/Code/capacitor"
        if FileManager.default.fileExists(atPath: localRoot) {
            return URL(fileURLWithPath: localRoot, isDirectory: true)
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    static func defaultGoalPacketURL(capacitorRoot: URL = defaultCapacitorRoot()) -> URL {
        capacitorRoot
            .appendingPathComponent("docs/circuit/proofs/receipt-first-fixture/03-goal-packet.json")
    }

    static func defaultProofDirectoryURL(capacitorRoot: URL = defaultCapacitorRoot()) -> URL {
        capacitorRoot
            .appendingPathComponent("docs/circuit/proofs/receipt-first-native-adapter")
    }

    static func claudeProductLoopProofDirectoryURL(capacitorRoot: URL = defaultCapacitorRoot()) -> URL {
        capacitorRoot
            .appendingPathComponent("docs/circuit/proofs/receipt-first-product-loop/native-session")
    }
}

struct ReceiptFirstProofLaunch: Equatable {
    let packet: ReceiptFirstProofGoalPacket
    let artifacts: ReceiptFirstProofArtifacts
    let bodySHA256: String
    let shellScript: String
    let command: String
}

struct ReceiptFirstProofLaunchResult: Equatable {
    let launch: ReceiptFirstProofLaunch
    let terminalScript: String
    let shellExitCode: Int32
    let shellOutput: String?
}

enum ReceiptFirstProofAdapterError: Error, Equatable, LocalizedError {
    case invalidGoalPacket(String)
    case receiptNotFound
    case captureTimedOut(resultPath: String, rawReceiptPath: String)
    case launchFailed(exitCode: Int32, output: String?)

    var errorDescription: String? {
        switch self {
        case let .invalidGoalPacket(message):
            message
        case .receiptNotFound:
            "No CIRCUIT_RECEIPT block was found."
        case let .captureTimedOut(resultPath, rawReceiptPath):
            "Receipt-first proof did not finish before timeout. result=\(resultPath) rawReceipt=\(rawReceiptPath)"
        case let .launchFailed(exitCode, output):
            "Receipt-first proof launch failed with exit \(exitCode): \(output ?? "no output")"
        }
    }
}

struct ReceiptFirstProofAdapter {
    typealias RunShell = (String) async -> (exitCode: Int32, output: String?)
    typealias TerminalScriptBuilder = (_ projectPath: String, _ command: String) -> String

    private let runShell: RunShell
    private let terminalScriptBuilder: TerminalScriptBuilder
    private let fileManager: FileManager

    init(
        runShell: @escaping RunShell = { script in
            await TerminalLauncher.runBashScriptWithResult(script)
        },
        terminalScriptBuilder: @escaping TerminalScriptBuilder = { projectPath, command in
            TerminalScripts.launchWithCommand(
                projectPath: projectPath,
                command: command,
                preferredApp: .ghostty,
            )
        },
        fileManager: FileManager = .default,
    ) {
        self.runShell = runShell
        self.terminalScriptBuilder = terminalScriptBuilder
        self.fileManager = fileManager
    }

    func prepareLaunch(
        packetURL: URL = ReceiptFirstProofArtifacts.defaultGoalPacketURL(),
        proofDirectoryURL: URL = ReceiptFirstProofArtifacts.defaultProofDirectoryURL(),
    ) throws -> ReceiptFirstProofLaunch {
        let packet = try Self.loadGoalPacket(from: packetURL)
        return try prepareLaunch(packet: packet, proofDirectoryURL: proofDirectoryURL)
    }

    func prepareLaunch(
        packet: ReceiptFirstProofGoalPacket,
        proofDirectoryURL: URL,
    ) throws -> ReceiptFirstProofLaunch {
        try packet.validateForReceiptFirstProof()

        let artifacts = ReceiptFirstProofArtifacts(proofDirectoryURL: proofDirectoryURL)
        try fileManager.createDirectory(at: proofDirectoryURL, withIntermediateDirectories: true)

        for url in [
            artifacts.transcriptURL,
            artifacts.lastMessageURL,
            artifacts.rawReceiptURL,
            artifacts.resultURL,
        ] {
            try? fileManager.removeItem(at: url)
        }

        try Data(packet.body.utf8).write(to: artifacts.insertedBodyURL, options: .atomic)

        let bodySHA256 = Self.sha256Hex(packet.body)
        let shellScript = Self.makeCaptureShellScript(
            packet: packet,
            artifacts: artifacts,
            bodySHA256: bodySHA256,
        )
        let command = "/bin/bash -lc \(shellEscape(shellScript))"

        return ReceiptFirstProofLaunch(
            packet: packet,
            artifacts: artifacts,
            bodySHA256: bodySHA256,
            shellScript: shellScript,
            command: command,
        )
    }

    func launch(
        packetURL: URL = ReceiptFirstProofArtifacts.defaultGoalPacketURL(),
        proofDirectoryURL: URL = ReceiptFirstProofArtifacts.defaultProofDirectoryURL(),
    ) async throws -> ReceiptFirstProofLaunchResult {
        let prepared = try prepareLaunch(
            packetURL: packetURL,
            proofDirectoryURL: proofDirectoryURL,
        )
        return try await launch(prepared: prepared)
    }

    func launch(
        packet: ReceiptFirstProofGoalPacket,
        proofDirectoryURL: URL,
    ) async throws -> ReceiptFirstProofLaunchResult {
        let prepared = try prepareLaunch(
            packet: packet,
            proofDirectoryURL: proofDirectoryURL,
        )
        return try await launch(prepared: prepared)
    }

    private func launch(prepared: ReceiptFirstProofLaunch) async throws -> ReceiptFirstProofLaunchResult {
        let terminalScript = terminalScriptBuilder(prepared.packet.projectPath, prepared.command)
        let result = await runShell(terminalScript)
        guard result.exitCode == 0 else {
            throw ReceiptFirstProofAdapterError.launchFailed(
                exitCode: result.exitCode,
                output: result.output,
            )
        }
        return ReceiptFirstProofLaunchResult(
            launch: prepared,
            terminalScript: terminalScript,
            shellExitCode: result.exitCode,
            shellOutput: result.output,
        )
    }

    func launchAndWaitForCapture(
        packetURL: URL = ReceiptFirstProofArtifacts.defaultGoalPacketURL(),
        proofDirectoryURL: URL = ReceiptFirstProofArtifacts.defaultProofDirectoryURL(),
        timeoutSeconds: TimeInterval = 120,
        pollIntervalNanoseconds: UInt64 = 500_000_000,
    ) async throws -> ReceiptFirstProofLaunchResult {
        let result = try await launch(
            packetURL: packetURL,
            proofDirectoryURL: proofDirectoryURL,
        )
        try await waitForCapture(
            artifacts: result.launch.artifacts,
            timeoutSeconds: timeoutSeconds,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
        )
        return result
    }

    func launchAndWaitForCapture(
        packet: ReceiptFirstProofGoalPacket,
        proofDirectoryURL: URL,
        timeoutSeconds: TimeInterval = 120,
        pollIntervalNanoseconds: UInt64 = 500_000_000,
    ) async throws -> ReceiptFirstProofLaunchResult {
        let result = try await launch(
            packet: packet,
            proofDirectoryURL: proofDirectoryURL,
        )
        try await waitForCapture(
            artifacts: result.launch.artifacts,
            timeoutSeconds: timeoutSeconds,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
        )
        return result
    }

    static func loadGoalPacket(from url: URL) throws -> ReceiptFirstProofGoalPacket {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ReceiptFirstProofGoalPacket.self, from: data)
    }

    static func extractReceiptBlock(from text: String) -> String? {
        let marker = "CIRCUIT_RECEIPT"
        var lineStart = text.startIndex
        var lastMarkerEnd: String.Index?

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart ..< lineEnd]
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == marker {
                lastMarkerEnd = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }

        guard let lastMarkerEnd else { return nil }

        let afterMarker = String(text[lastMarkerEnd...])
        let candidate = receiptCandidate(afterMarker: afterMarker)
        guard let jsonStart = candidate.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        var index = jsonStart
        while index < candidate.endIndex {
            let character = candidate[index]

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return "CIRCUIT_RECEIPT\n\(candidate[jsonStart ... index])"
                }
            }

            index = candidate.index(after: index)
        }

        return nil
    }

    private func waitForCapture(
        artifacts: ReceiptFirstProofArtifacts,
        timeoutSeconds: TimeInterval,
        pollIntervalNanoseconds: UInt64,
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if try captureIsReady(artifacts: artifacts) {
                return
            }

            try await _Concurrency.Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        throw ReceiptFirstProofAdapterError.captureTimedOut(
            resultPath: artifacts.resultURL.path,
            rawReceiptPath: artifacts.rawReceiptURL.path,
        )
    }

    private func captureIsReady(artifacts: ReceiptFirstProofArtifacts) throws -> Bool {
        guard fileManager.fileExists(atPath: artifacts.resultURL.path) else {
            return false
        }

        let resultData = try Data(contentsOf: artifacts.resultURL)
        let result = try JSONDecoder().decode(ReceiptProofAdapterResult.self, from: resultData)

        guard result.status != "blocked_no_receipt" else {
            throw ReceiptFirstProofAdapterError.receiptNotFound
        }

        guard result.status == "native_capture_complete" || result.status == "native_capture_with_nonzero_exit" else {
            return false
        }

        guard fileManager.fileExists(atPath: artifacts.rawReceiptURL.path) else {
            return false
        }

        let rawReceipt = try String(contentsOf: artifacts.rawReceiptURL, encoding: .utf8)
        return Self.extractReceiptBlock(from: rawReceipt) != nil
    }

    private static func receiptCandidate(afterMarker: String) -> String {
        let trimmed = afterMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return afterMarker }

        var lines = trimmed.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return afterMarker }
        lines.removeFirst()

        if let fenceEnd = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
        }) {
            return lines[..<fenceEnd].joined(separator: "\n")
        }

        return lines.joined(separator: "\n")
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeCaptureShellScript(
        packet: ReceiptFirstProofGoalPacket,
        artifacts: ReceiptFirstProofArtifacts,
        bodySHA256: String,
    ) -> String {
        let hostDisplayName = packet.targetAgent == "claude_code" ? "Claude Code CLI" : "Codex"
        let runCommand = packet.targetAgent == "claude_code"
            ? claudeRunCommand()
            : codexRunCommand()

        return """
        set -euo pipefail
        PACKET_ID=\(shellEscape(packet.id))
        PROJECT_PATH=\(shellEscape(packet.projectPath))
        TARGET_AGENT=\(shellEscape(packet.targetAgent))
        BODY_FILE=\(shellEscape(artifacts.insertedBodyURL.path))
        TRANSCRIPT_FILE=\(shellEscape(artifacts.transcriptURL.path))
        LAST_MESSAGE_FILE=\(shellEscape(artifacts.lastMessageURL.path))
        RAW_RECEIPT_FILE=\(shellEscape(artifacts.rawReceiptURL.path))
        RESULT_FILE=\(shellEscape(artifacts.resultURL.path))
        BODY_SHA=\(shellEscape(bodySHA256))

        mkdir -p \(shellEscape(artifacts.proofDirectoryURL.path))
        rm -f "$TRANSCRIPT_FILE" "$LAST_MESSAGE_FILE" "$RAW_RECEIPT_FILE" "$RESULT_FILE"
        cd "$PROJECT_PATH"

        {
          echo "NATIVE_CAPACITOR_RECEIPT_FIRST_PROOF"
          echo "goal_packet_id: $PACKET_ID"
          echo "host: $TARGET_AGENT"
          echo "visible_surface: Ghostty launched by Capacitor Circuit first-slice action"
          echo "mode: \(hostDisplayName) with stdin prompt"
          echo "body_sha256: $BODY_SHA"
          echo
          echo "CAPACITOR_ADAPTER_INSERTED_EXACT_GOAL_PACKET_BODY"
          cat "$BODY_FILE"
          echo
          echo "END_INSERTED_BODY"
          echo
          echo "AGENT_CLI_OUTPUT"
        } | tee -a "$TRANSCRIPT_FILE"

        set +e
        \(runCommand)
        AGENT_EXIT=${PIPESTATUS[0]}

        /usr/bin/python3 - "$LAST_MESSAGE_FILE" "$TRANSCRIPT_FILE" "$RAW_RECEIPT_FILE" "$RESULT_FILE" "$AGENT_EXIT" "$PACKET_ID" "$BODY_SHA" "$BODY_FILE" "$TARGET_AGENT" <<'PY'
        import json
        import pathlib
        import re
        import sys
        from datetime import datetime, timezone

        last_message_path = pathlib.Path(sys.argv[1])
        transcript_path = pathlib.Path(sys.argv[2])
        raw_receipt_path = pathlib.Path(sys.argv[3])
        result_path = pathlib.Path(sys.argv[4])
        agent_exit = int(sys.argv[5])
        packet_id = sys.argv[6]
        body_sha = sys.argv[7]
        body_file_path = pathlib.Path(sys.argv[8])
        target_agent = sys.argv[9]

        def read_text(path):
            return path.read_text() if path.exists() else ""

        def extract_last_receipt_block(text):
            marker = "CIRCUIT_RECEIPT"
            matches = list(re.finditer(r"(?m)^[ \\t]*CIRCUIT_RECEIPT[ \\t]*(?:\\n|$)", text))
            if not matches:
                return None
            after_marker = text[matches[-1].end():]
            candidate = after_marker.strip()
            if candidate.startswith("```"):
                lines = candidate.splitlines()
                lines = lines[1:]
                for index, line in enumerate(lines):
                    if line.strip().startswith("```"):
                        lines = lines[:index]
                        break
                candidate = "\\n".join(lines)
            start = candidate.find("{")
            if start < 0:
                return None
            depth = 0
            in_string = False
            escaped = False
            for index in range(start, len(candidate)):
                char = candidate[index]
                if in_string:
                    if escaped:
                        escaped = False
                    elif char == "\\\\":
                        escaped = True
                    elif char == "\\"":
                        in_string = False
                    continue
                if char == "\\"":
                    in_string = True
                elif char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                    if depth == 0:
                        return "CIRCUIT_RECEIPT\\n" + candidate[start:index + 1]
            return None

        last_message = read_text(last_message_path)
        transcript = read_text(transcript_path)
        receipt_block = extract_last_receipt_block(last_message) or extract_last_receipt_block(transcript)
        finished_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

        if not receipt_block:
            result_path.write_text(json.dumps({
                "kind": "native_receipt_first_proof_result",
                "status": "blocked_no_receipt",
                "finished_at": finished_at,
                "goal_packet_id": packet_id,
                "host": target_agent,
                "body_sha256": body_sha,
                "agent_exit_code": agent_exit,
                "codex_exit_code": agent_exit,
                "transcript_path": str(transcript_path),
                "last_message_path": str(last_message_path),
                "blocker": f"{target_agent} did not return a visible CIRCUIT_RECEIPT block."
            }, indent=2) + "\\n")
            sys.exit(2)

        raw_receipt_path.write_text(receipt_block + "\\n")
        result_path.write_text(json.dumps({
            "kind": "native_receipt_first_proof_result",
            "status": "native_capture_complete" if agent_exit == 0 else "native_capture_with_nonzero_exit",
            "finished_at": finished_at,
            "goal_packet_id": packet_id,
            "host": target_agent,
            "body_sha256": body_sha,
            "agent_exit_code": agent_exit,
            "codex_exit_code": agent_exit,
            "visible_surface": "Ghostty launched by Capacitor Circuit first-slice action",
            "injection": {
                "mode": "stdin initial prompt",
                "body_path": str(body_file_path),
                "exact_body_match": True
            },
            "capture": {
                "mode": "stdout and last-message capture",
                "raw_receipt_path": str(raw_receipt_path),
                "preserved_for_normalization": True
            },
            "limits": [
                f"One controlled {target_agent} CLI session only.",
                "No Circuit runtime invocation.",
                "No agent-reasoning orchestration, queueing, checkpoint relay, retries, or generalized session management."
            ]
        }, indent=2) + "\\n")
        sys.exit(0)
        PY
        PY_EXIT=$?
        set -e

        if [ "$PY_EXIT" -ne 0 ]; then
          exit "$PY_EXIT"
        fi
        exit "$AGENT_EXIT"
        """
    }

    private static func codexRunCommand() -> String {
        """
        ORIGINAL_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
        PROOF_CODEX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/capacitor-codex-home.XXXXXX")"
        trap 'rm -rf "$PROOF_CODEX_HOME"' EXIT
        if [[ -f "$ORIGINAL_CODEX_HOME/auth.json" ]]; then
          ln -s "$ORIGINAL_CODEX_HOME/auth.json" "$PROOF_CODEX_HOME/auth.json"
        fi
        echo "codex_home: isolated temp home with auth symlink only" | tee -a "$TRANSCRIPT_FILE"
        echo "sandbox: read-only" | tee -a "$TRANSCRIPT_FILE"
        CODEX_HOME="$PROOF_CODEX_HOME" codex exec --ignore-user-config --cd "$PROJECT_PATH" --sandbox read-only --color never --output-last-message "$LAST_MESSAGE_FILE" - < "$BODY_FILE" 2>&1 | tee -a "$TRANSCRIPT_FILE"
        """
    }

    private static func claudeRunCommand() -> String {
        """
        CLAUDE_BIN="${CLAUDE_CODE_PATH:-}"
        if [[ -z "$CLAUDE_BIN" ]]; then
          CLAUDE_BIN="$(command -v claude || true)"
        fi
        if [[ -z "$CLAUDE_BIN" && -x "$HOME/.local/bin/claude" ]]; then
          CLAUDE_BIN="$HOME/.local/bin/claude"
        fi
        if [[ -z "$CLAUDE_BIN" ]]; then
          echo "Claude CLI not found." | tee "$LAST_MESSAGE_FILE" | tee -a "$TRANSCRIPT_FILE"
          exit 127
        fi
        "$CLAUDE_BIN" --print --model "${CLAUDE_MODEL:-haiku}" --permission-mode acceptEdits --output-format text < "$BODY_FILE" 2>&1 | tee "$LAST_MESSAGE_FILE" | tee -a "$TRANSCRIPT_FILE"
        """
    }
}
