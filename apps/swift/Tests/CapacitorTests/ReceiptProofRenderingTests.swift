#if DEBUG
    @testable import Capacitor
    import XCTest

    final class ReceiptProofRenderingTests: XCTestCase {
        func testDefaultPathsPointAtNativeAdapterProofArtifacts() {
            let root = URL(fileURLWithPath: "/tmp/capacitor", isDirectory: true)

            XCTAssertEqual(
                ReceiptProofRenderingStore.defaultResultURL(capacitorRoot: root).path,
                "/tmp/capacitor/docs/circuit/proofs/receipt-first-product-loop/native-session/07-native-adapter-result.json",
            )
            XCTAssertEqual(
                ReceiptProofRenderingStore.defaultRawReceiptURL(capacitorRoot: root).path,
                "/tmp/capacitor/docs/circuit/proofs/receipt-first-product-loop/native-session/06-native-captured-raw-receipt.txt",
            )
            XCTAssertEqual(
                ReceiptProofRenderingStore.defaultAgentEventURL(capacitorRoot: root).path,
                "/tmp/capacitor/docs/circuit/proofs/receipt-first-product-loop/normalization/01-agent-event.json",
            )
        }

        func testLoadsRenderingProjectionFromFixtureArtifacts() throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let resultURL = directory.appendingPathComponent("07-native-adapter-result.json")
            let agentEventURL = directory.appendingPathComponent("01-agent-event.json")
            let rawReceiptURL = directory.appendingPathComponent("06-native-captured-raw-receipt.txt")
            try writeResult(to: resultURL, status: "native_capture_complete")
            try writeRawReceipt(to: rawReceiptURL, receiptStatus: "completed")
            try writeAgentEvent(
                to: agentEventURL,
                receiptStatus: "completed",
                sourceRawReceiptPath: rawReceiptURL.path,
            )

            let projection = try ReceiptProofRenderingStore(
                resultURL: resultURL,
                agentEventURL: agentEventURL,
            ).loadProjection()

            XCTAssertEqual(projection.state, "complete")
            XCTAssertEqual(projection.primaryText, "Receipt proof captured")
            XCTAssertEqual(projection.statusLabel, "Complete")
            XCTAssertEqual(projection.statusTintName, "green")
            XCTAssertEqual(projection.result.goalPacketID, "goal-packet-rendering-test")
            XCTAssertEqual(projection.agentEvent.id, "event-rendering-test")
            XCTAssertEqual(projection.receipt.id, "receipt-rendering-test")
            XCTAssertEqual(projection.receipt.evidence, ["Exact body inserted.", "Raw receipt captured."])
            XCTAssertEqual(projection.resultPath, resultURL.path)
            XCTAssertEqual(projection.agentEventPath, agentEventURL.path)
            XCTAssertEqual(projection.sourceRawReceiptPath, rawReceiptURL.path)
        }

        func testProjectionMapsBlockedAndFailedReceiptStates() throws {
            let result = makeResult(status: "native_capture_complete")
            let blocked = try ReceiptProofRenderingStore.makeProjection(
                result: result,
                agentEvent: makeAgentEvent(receiptStatus: "blocked"),
                resultPath: "/result.json",
                agentEventPath: "/event.json",
            )
            let failed = try ReceiptProofRenderingStore.makeProjection(
                result: result,
                agentEvent: makeAgentEvent(receiptStatus: "failed"),
                resultPath: "/result.json",
                agentEventPath: "/event.json",
            )

            XCTAssertEqual(blocked.state, "blocked")
            XCTAssertEqual(blocked.statusTintName, "orange")
            XCTAssertEqual(failed.state, "failed")
            XCTAssertEqual(failed.statusTintName, "red")
        }

        func testRejectsReceiptWithoutMarker() throws {
            XCTAssertThrowsError(
                try ReceiptProofRenderingStore.receiptJSONData(fromRawReceipt: #"{"kind":"receipt"}"#),
            ) { error in
                XCTAssertEqual(error as? ReceiptProofRenderingError, .invalidMarker)
            }
        }

        func testRejectsMismatchedGoalPacketIDs() throws {
            let result = makeResult(goalPacketID: "goal-from-result")
            let agentEvent = makeAgentEvent(goalPacketID: "goal-from-event", receiptGoalPacketID: "goal-from-receipt")

            XCTAssertThrowsError(
                try ReceiptProofRenderingStore.makeProjection(
                    result: result,
                    agentEvent: agentEvent,
                    resultPath: "/result.json",
                    agentEventPath: "/event.json",
                ),
            ) { error in
                XCTAssertEqual(
                    error as? ReceiptProofRenderingError,
                    .mismatchedGoalPacket(result: "goal-from-result", event: "goal-from-event", receipt: "goal-from-receipt"),
                )
            }
        }

        func testRejectsStaleAgentEventPayloadWhenSourceRawReceiptDiffers() throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let resultURL = directory.appendingPathComponent("07-native-adapter-result.json")
            let rawReceiptURL = directory.appendingPathComponent("06-native-captured-raw-receipt.txt")
            let agentEventURL = directory.appendingPathComponent("01-agent-event.json")
            try writeResult(to: resultURL, status: "native_capture_complete")
            try writeRawReceipt(to: rawReceiptURL, receiptStatus: "blocked")
            try writeAgentEvent(
                to: agentEventURL,
                receiptStatus: "completed",
                sourceRawReceiptPath: rawReceiptURL.path,
            )

            XCTAssertThrowsError(
                try ReceiptProofRenderingStore(
                    resultURL: resultURL,
                    agentEventURL: agentEventURL,
                ).loadProjection(),
            ) { error in
                XCTAssertEqual(error as? ReceiptProofRenderingError, .staleAgentEventPayload)
            }
        }

        func testRejectsMissingSourceRawReceipt() throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let resultURL = directory.appendingPathComponent("07-native-adapter-result.json")
            let missingRawReceiptURL = directory.appendingPathComponent("06-native-captured-raw-receipt.txt")
            let agentEventURL = directory.appendingPathComponent("01-agent-event.json")
            try writeResult(to: resultURL, status: "native_capture_complete")
            try writeAgentEvent(
                to: agentEventURL,
                receiptStatus: "completed",
                sourceRawReceiptPath: missingRawReceiptURL.path,
            )

            XCTAssertThrowsError(
                try ReceiptProofRenderingStore(
                    resultURL: resultURL,
                    agentEventURL: agentEventURL,
                ).loadProjection(),
            ) { error in
                XCTAssertEqual(error as? ReceiptProofRenderingError, .missingSourceRawReceipt(missingRawReceiptURL.path))
            }
        }

        func testRejectsAgentEventWithoutSourceRawReceiptReference() throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let resultURL = directory.appendingPathComponent("07-native-adapter-result.json")
            let agentEventURL = directory.appendingPathComponent("01-agent-event.json")
            try writeResult(to: resultURL, status: "native_capture_complete")
            try writeAgentEvent(
                to: agentEventURL,
                receiptStatus: "completed",
                includeNormalization: false,
            )

            XCTAssertThrowsError(
                try ReceiptProofRenderingStore(
                    resultURL: resultURL,
                    agentEventURL: agentEventURL,
                ).loadProjection(),
            ) { error in
                XCTAssertEqual(error as? ReceiptProofRenderingError, .missingSourceRawReceiptPath)
            }
        }

        func testRejectsUnsupportedNormalizationMode() throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let resultURL = directory.appendingPathComponent("07-native-adapter-result.json")
            let rawReceiptURL = directory.appendingPathComponent("06-native-captured-raw-receipt.txt")
            let agentEventURL = directory.appendingPathComponent("01-agent-event.json")
            try writeResult(to: resultURL, status: "native_capture_complete")
            try writeRawReceipt(to: rawReceiptURL, receiptStatus: "completed")
            try writeAgentEvent(
                to: agentEventURL,
                receiptStatus: "completed",
                sourceRawReceiptPath: rawReceiptURL.path,
                normalizationMode: "fixture",
            )

            XCTAssertThrowsError(
                try ReceiptProofRenderingStore(
                    resultURL: resultURL,
                    agentEventURL: agentEventURL,
                ).loadProjection(),
            ) { error in
                XCTAssertEqual(error as? ReceiptProofRenderingError, .normalizationModeNotSupported("fixture"))
            }
        }

        func testRejectsCircuitRuntimeNormalization() throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let resultURL = directory.appendingPathComponent("07-native-adapter-result.json")
            let rawReceiptURL = directory.appendingPathComponent("06-native-captured-raw-receipt.txt")
            let agentEventURL = directory.appendingPathComponent("01-agent-event.json")
            try writeResult(to: resultURL, status: "native_capture_complete")
            try writeRawReceipt(to: rawReceiptURL, receiptStatus: "completed")
            try writeAgentEvent(
                to: agentEventURL,
                receiptStatus: "completed",
                sourceRawReceiptPath: rawReceiptURL.path,
                circuitRuntimeInvoked: true,
            )

            XCTAssertThrowsError(
                try ReceiptProofRenderingStore(
                    resultURL: resultURL,
                    agentEventURL: agentEventURL,
                ).loadProjection(),
            ) { error in
                XCTAssertEqual(error as? ReceiptProofRenderingError, .circuitRuntimeNormalizationNotSupported)
            }
        }

        func testLoadsCurrentNativeProofArtifactsWhenPresent() throws {
            let resultURL = ReceiptProofRenderingStore.defaultResultURL()
            let rawReceiptURL = ReceiptProofRenderingStore.defaultRawReceiptURL()
            let agentEventURL = ReceiptProofRenderingStore.defaultAgentEventURL()
            guard FileManager.default.fileExists(atPath: resultURL.path),
                  FileManager.default.fileExists(atPath: rawReceiptURL.path),
                  FileManager.default.fileExists(atPath: agentEventURL.path)
            else {
                throw XCTSkip("receipt-first product loop artifacts are not present on this machine")
            }

            let projection = try ReceiptProofRenderingStore().loadProjection()
            let rawReceipt = try String(contentsOf: rawReceiptURL, encoding: .utf8)
            let rawReceiptData = try ReceiptProofRenderingStore.receiptJSONData(fromRawReceipt: rawReceipt)
            let sourceReceipt = try JSONDecoder().decode(ReceiptProofReceipt.self, from: rawReceiptData)
            let expectedState = switch sourceReceipt.status {
            case "completed":
                "complete"
            case "failed":
                "failed"
            default:
                "blocked"
            }

            XCTAssertEqual(projection.state, expectedState)
            XCTAssertEqual(projection.result.status, "native_capture_complete")
            XCTAssertEqual(projection.result.goalPacketID, sourceReceipt.goalPacketID)
            XCTAssertEqual(projection.agentEvent.kind, "agent_event")
            XCTAssertEqual(projection.agentEvent.type, "receipt")
            XCTAssertEqual(projection.agentEvent.goalPacketID, sourceReceipt.goalPacketID)
            XCTAssertEqual(projection.receipt.kind, "receipt")
            XCTAssertEqual(projection.receipt.goalPacketID, sourceReceipt.goalPacketID)
            XCTAssertEqual(projection.agentEvent.session.host, "claude_code")
            XCTAssertTrue(projection.agentEvent.normalization?.sourceRawReceiptPath.hasSuffix("06-native-captured-raw-receipt.txt") == true)
            XCTAssertEqual(projection.agentEvent.normalization?.circuitRuntimeInvoked, false)
            XCTAssertEqual(projection.agentEvent.payload, sourceReceipt)
            XCTAssertTrue(projection.result.injection.exactBodyMatch)
            XCTAssertTrue(projection.result.capture.preservedForNormalization)
        }

        private func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("receipt-proof-rendering-\(UUID().uuidString)", isDirectory: true)
        }

        private func writeResult(
            to url: URL,
            status: String,
        ) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = makeResult(status: status)
            let data = try JSONEncoder().encode(result)
            try data.write(to: url)
        }

        private func writeRawReceipt(
            to url: URL,
            receiptStatus: String,
        ) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let receipt = makeReceipt(status: receiptStatus)
            let data = try JSONEncoder().encode(receipt)
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            try Data("CIRCUIT_RECEIPT\n\(json)\n".utf8).write(to: url)
        }

        private func writeAgentEvent(
            to url: URL,
            receiptStatus: String,
            sourceRawReceiptPath: String = "/tmp/source-raw-receipt.txt",
            includeNormalization: Bool = true,
            normalizationMode: String = "headless_receipt_normalizer",
            circuitRuntimeInvoked: Bool = false,
        ) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let event = makeAgentEvent(
                receiptStatus: receiptStatus,
                sourceRawReceiptPath: sourceRawReceiptPath,
                includeNormalization: includeNormalization,
                normalizationMode: normalizationMode,
                circuitRuntimeInvoked: circuitRuntimeInvoked,
            )
            let data = try JSONEncoder().encode(event)
            try data.write(to: url)
        }

        private func makeResult(
            goalPacketID: String = "goal-packet-rendering-test",
            status: String = "native_capture_complete",
        ) -> ReceiptProofAdapterResult {
            ReceiptProofAdapterResult(
                kind: "native_receipt_first_proof_result",
                status: status,
                finishedAt: "2026-05-24T03:15:23Z",
                goalPacketID: goalPacketID,
                bodySHA256: "abc123",
                codexExitCode: 0,
                visibleSurface: "Ghostty launched by Capacitor Circuit first-slice action",
                injection: .init(
                    mode: "stdin initial prompt",
                    bodyPath: "/tmp/body.txt",
                    exactBodyMatch: true,
                ),
                capture: .init(
                    mode: "stdout and last-message capture",
                    rawReceiptPath: "/tmp/receipt.txt",
                    preservedForNormalization: true,
                ),
                limits: [
                    "One controlled Codex exec session only.",
                    "No Circuit runtime invocation.",
                ],
            )
        }

        private func makeReceipt(
            goalPacketID: String = "goal-packet-rendering-test",
            status: String = "completed",
        ) -> ReceiptProofReceipt {
            ReceiptProofReceipt(
                kind: "receipt",
                id: "receipt-rendering-test",
                goalPacketID: goalPacketID,
                status: status,
                summary: "Rendered a captured receipt.",
                evidence: ["Exact body inserted.", "Raw receipt captured."],
                changedPaths: [],
                openRisks: ["Rendering is proof-only."],
                nextAction: "Stop before queueing.",
            )
        }

        private func makeAgentEvent(
            goalPacketID: String = "goal-packet-rendering-test",
            receiptGoalPacketID: String = "goal-packet-rendering-test",
            receiptStatus: String = "completed",
            sourceRawReceiptPath: String = "/tmp/source-raw-receipt.txt",
            includeNormalization: Bool = true,
            normalizationMode: String = "headless_receipt_normalizer",
            circuitRuntimeInvoked: Bool = false,
        ) -> ReceiptProofAgentEvent {
            ReceiptProofAgentEvent(
                kind: "agent_event",
                id: "event-rendering-test",
                goalPacketID: goalPacketID,
                session: .init(
                    host: "codex",
                    sessionID: "session-rendering-test",
                    visibleToOwner: true,
                ),
                type: "receipt",
                payload: makeReceipt(goalPacketID: receiptGoalPacketID, status: receiptStatus),
                recordedAt: "2026-05-24T03:15:23Z",
                normalization: includeNormalization ? .init(
                    mode: normalizationMode,
                    sourceRawReceiptPath: sourceRawReceiptPath,
                    circuitRuntimeInvoked: circuitRuntimeInvoked,
                ) : nil,
            )
        }
    }
#endif
