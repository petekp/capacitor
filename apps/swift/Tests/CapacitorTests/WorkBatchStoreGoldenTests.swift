@testable import Capacitor
import Foundation
import XCTest

/// GOLDEN (oracle) characterization tests for the five WorkBatch directory stores.
///
/// These pin the EXACT current on-disk artifacts so an upcoming internal-structure
/// consolidation can be proven byte-for-byte preserving. The five stores write the
/// agent<->app IPC file-drop contract; the in-session Claude agent reads/writes these
/// files. Any change to a directory name, the filename sanitizer OUTPUT (including the
/// requests-only 80-char cap divergence), a fallback string ("task"/"checkpoint"),
/// the snake_case coding keys, the `.iso8601` date emission, the
/// `[.prettyPrinted, .sortedKeys]` formatting, or the lenient `.capacitorISO8601`
/// read path would BREAK the handshake.
///
/// The five stores under test:
///   1. WorkBatchTaskRequestStore        (R+W, 80-char-capped filename, fallback "task")
///   2. WorkBatchTaskClaimStore          (R+W, uncapped, fallback "task",
///                                        BORROWS CompletionReportStore.reportFileName)
///   3. WorkBatchCompletionReportStore   (R+W+deleteReport-dedup-rescan, uncapped, fallback "task")
///   4. WorkBatchCheckpointRequestStore  (R+W, uncapped, fallback "checkpoint")
///   5. WorkBatchCheckpointResponseStore (WRITE-ONLY, no load, uncapped,
///                                        BORROWS CheckpointRequestStore.fileName)
final class WorkBatchStoreGoldenTests: XCTestCase {
    // MARK: - Shared fixtures

    /// 1_775_000_000 == 2026-03-31T23:33:20Z. `.iso8601` emits exactly that string
    /// (no fractional seconds), which is itself a byte-level part of the contract.
    private static let fixedDate = Date(timeIntervalSince1970: 1_775_000_000)
    private static let fixedDateISO = "2026-03-31T23:33:20Z"

    /// A representative id with characters the sanitizer maps:
    /// uppercase -> lowercase, "/" and " " and "!" -> "-", runs of "-" collapsed.
    private static let mappedID = "Task/Green Border!!"
    private static let mappedSanitized = "task-green-border"

    /// A >80-character id used to lock the requests-only 80-char cap vs the uncapped others.
    /// 100 lowercase "a" sanitizes to 100 "a" (all letters, nothing mapped, nothing collapsed).
    private static let longID = String(repeating: "a", count: 100)
    private static let longBasename80 = String(repeating: "a", count: 80)
    private static let longBasename100 = String(repeating: "a", count: 100)

    private func makeTempWorktree() throws -> (URL, FileManager) {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true,
        )
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }
        return (tempDir, fileManager)
    }

    private func readString(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - (1) Exact relative directory strings

    func testRelativeDirectoryStringsAreExact() {
        XCTAssertEqual(
            WorkBatchTaskRequestStore.relativeDirectory,
            ".capacitor/work-batch-task-requests",
        )
        XCTAssertEqual(
            WorkBatchTaskClaimStore.relativeDirectory,
            ".capacitor/work-batch-claims",
        )
        XCTAssertEqual(
            WorkBatchCompletionReportStore.relativeDirectory,
            ".capacitor/work-batch-completions",
        )
        XCTAssertEqual(
            WorkBatchCheckpointRequestStore.relativeDirectory,
            ".capacitor/work-batch-checkpoints",
        )
        XCTAssertEqual(
            WorkBatchCheckpointResponseStore.relativeDirectory,
            ".capacitor/work-batch-checkpoint-responses",
        )
    }

    // MARK: - (2) Exact filenames for representative ids

    func testTaskRequestStoreFilenamesAreExact_capped() {
        // normal id (already-clean) -> unchanged
        XCTAssertEqual(WorkBatchTaskRequestStore.fileName(id: "task-123"), "task-123.json")
        // uppercase normal id -> lowercased
        XCTAssertEqual(WorkBatchTaskRequestStore.fileName(id: "Task-123"), "task-123.json")
        // mapped-character id -> "/" " " "!" -> "-", runs collapsed
        XCTAssertEqual(
            WorkBatchTaskRequestStore.fileName(id: Self.mappedID),
            "\(Self.mappedSanitized).json",
        )
        // >80-char id -> CAPPED at 80 (requests-only divergence)
        let longFile = WorkBatchTaskRequestStore.fileName(id: Self.longID)
        XCTAssertEqual(longFile, "\(Self.longBasename80).json")
        XCTAssertEqual(longFile, "\(String(repeating: "a", count: 80)).json")
        XCTAssertEqual(longFile.replacingOccurrences(of: ".json", with: "").count, 80)
        // empty / whitespace-only / all-mapped id -> fallback "task"
        XCTAssertEqual(WorkBatchTaskRequestStore.fileName(id: ""), "task.json")
        XCTAssertEqual(WorkBatchTaskRequestStore.fileName(id: "   "), "task.json")
        XCTAssertEqual(WorkBatchTaskRequestStore.fileName(id: "///"), "task.json")
    }

    func testCompletionReportStoreFilenamesAreExact_uncapped() {
        XCTAssertEqual(WorkBatchCompletionReportStore.reportFileName(taskID: "task-123"), "task-123.json")
        XCTAssertEqual(WorkBatchCompletionReportStore.reportFileName(taskID: "Task-123"), "task-123.json")
        XCTAssertEqual(
            WorkBatchCompletionReportStore.reportFileName(taskID: Self.mappedID),
            "\(Self.mappedSanitized).json",
        )
        // >80-char id -> UNCAPPED, full 100 characters preserved
        let longFile = WorkBatchCompletionReportStore.reportFileName(taskID: Self.longID)
        XCTAssertEqual(longFile, "\(Self.longBasename100).json")
        XCTAssertEqual(longFile.replacingOccurrences(of: ".json", with: "").count, 100)
        // empty / all-mapped -> fallback "task"
        XCTAssertEqual(WorkBatchCompletionReportStore.reportFileName(taskID: ""), "task.json")
        XCTAssertEqual(WorkBatchCompletionReportStore.reportFileName(taskID: "///"), "task.json")
    }

    func testCheckpointRequestStoreFilenamesAreExact_uncapped() {
        XCTAssertEqual(WorkBatchCheckpointRequestStore.fileName(id: "ck-1"), "ck-1.json")
        XCTAssertEqual(WorkBatchCheckpointRequestStore.fileName(id: "CK-1"), "ck-1.json")
        XCTAssertEqual(
            WorkBatchCheckpointRequestStore.fileName(id: Self.mappedID),
            "\(Self.mappedSanitized).json",
        )
        // >80-char id -> UNCAPPED, full 100 characters preserved
        let longFile = WorkBatchCheckpointRequestStore.fileName(id: Self.longID)
        XCTAssertEqual(longFile, "\(Self.longBasename100).json")
        XCTAssertEqual(longFile.replacingOccurrences(of: ".json", with: "").count, 100)
        // empty / all-mapped -> fallback "checkpoint"
        XCTAssertEqual(WorkBatchCheckpointRequestStore.fileName(id: ""), "checkpoint.json")
        XCTAssertEqual(WorkBatchCheckpointRequestStore.fileName(id: "///"), "checkpoint.json")
    }

    /// Explicit cross-store proof of the 80-char cap divergence on a single shared id.
    func testEightyCharCapDivergenceAcrossStores() {
        let requestsFile = WorkBatchTaskRequestStore.fileName(id: Self.longID)
        let completionsFile = WorkBatchCompletionReportStore.reportFileName(taskID: Self.longID)
        let checkpointsFile = WorkBatchCheckpointRequestStore.fileName(id: Self.longID)

        // task-requests is the ONLY store that caps the basename at 80 characters.
        XCTAssertEqual(requestsFile.replacingOccurrences(of: ".json", with: "").count, 80)
        XCTAssertEqual(completionsFile.replacingOccurrences(of: ".json", with: "").count, 100)
        XCTAssertEqual(checkpointsFile.replacingOccurrences(of: ".json", with: "").count, 100)
        XCTAssertNotEqual(requestsFile, completionsFile)
        XCTAssertNotEqual(requestsFile, checkpointsFile)
        XCTAssertEqual(completionsFile, checkpointsFile)
    }

    // MARK: - (3) Cross-store BORROW pairs (assert borrowed filename bytes)

    func testTaskClaimStoreBorrowsCompletionReportFileName() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchTaskClaimStore(worktreePath: tempDir.path, fileManager: fileManager)

        // Normal id: claim URL filename must equal CompletionReportStore.reportFileName bytes.
        XCTAssertEqual(
            store.claimURL(taskID: "task-123").lastPathComponent,
            WorkBatchCompletionReportStore.reportFileName(taskID: "task-123"),
        )
        XCTAssertEqual(store.claimURL(taskID: "task-123").lastPathComponent, "task-123.json")

        // Mapped id.
        XCTAssertEqual(
            store.claimURL(taskID: Self.mappedID).lastPathComponent,
            WorkBatchCompletionReportStore.reportFileName(taskID: Self.mappedID),
        )
        XCTAssertEqual(store.claimURL(taskID: Self.mappedID).lastPathComponent, "\(Self.mappedSanitized).json")

        // >80-char id: claims inherit the UNCAPPED behavior of the borrowed function.
        let longClaim = store.claimURL(taskID: Self.longID).lastPathComponent
        XCTAssertEqual(longClaim, WorkBatchCompletionReportStore.reportFileName(taskID: Self.longID))
        XCTAssertEqual(longClaim, "\(Self.longBasename100).json")
        XCTAssertEqual(longClaim.replacingOccurrences(of: ".json", with: "").count, 100)

        // Empty id -> borrowed fallback "task".
        XCTAssertEqual(store.claimURL(taskID: "").lastPathComponent, "task.json")
        XCTAssertEqual(store.claimURL(taskID: "///").lastPathComponent, "task.json")

        // Directory placement is the claims directory, not the completions directory.
        XCTAssertTrue(
            store.claimURL(taskID: "task-123").path
                .hasSuffix(".capacitor/work-batch-claims/task-123.json"),
        )
    }

    func testCheckpointResponseStoreBorrowsCheckpointRequestFileName() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchCheckpointResponseStore(worktreePath: tempDir.path, fileManager: fileManager)

        // Normal id: response URL filename must equal CheckpointRequestStore.fileName bytes.
        XCTAssertEqual(
            store.responseURL(checkpointID: "ck-1").lastPathComponent,
            WorkBatchCheckpointRequestStore.fileName(id: "ck-1"),
        )
        XCTAssertEqual(store.responseURL(checkpointID: "ck-1").lastPathComponent, "ck-1.json")

        // Mapped id.
        XCTAssertEqual(
            store.responseURL(checkpointID: Self.mappedID).lastPathComponent,
            WorkBatchCheckpointRequestStore.fileName(id: Self.mappedID),
        )

        // >80-char id: responses inherit the UNCAPPED behavior of the borrowed function.
        let longResponse = store.responseURL(checkpointID: Self.longID).lastPathComponent
        XCTAssertEqual(longResponse, WorkBatchCheckpointRequestStore.fileName(id: Self.longID))
        XCTAssertEqual(longResponse, "\(Self.longBasename100).json")
        XCTAssertEqual(longResponse.replacingOccurrences(of: ".json", with: "").count, 100)

        // Empty id -> borrowed fallback "checkpoint".
        XCTAssertEqual(store.responseURL(checkpointID: "").lastPathComponent, "checkpoint.json")
        XCTAssertEqual(store.responseURL(checkpointID: "///").lastPathComponent, "checkpoint.json")

        // Directory placement is the responses directory, not the checkpoints directory.
        XCTAssertTrue(
            store.responseURL(checkpointID: "ck-1").path
                .hasSuffix(".capacitor/work-batch-checkpoint-responses/ck-1.json"),
        )
    }

    // MARK: - (4) Exact JSON bytes a write produces (snake_case, prettyPrinted, sortedKeys, iso8601)

    func testTaskRequestStoreEmitsExactJSONBytes() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchTaskRequestStore(worktreePath: tempDir.path, fileManager: fileManager)
        let request = WorkBatchTaskRequest(
            taskID: "task-123",
            title: "Add border",
            body: "Make it green",
            source: "agent",
            requestedAt: Self.fixedDate,
        )

        let url = try store.write(request)

        let expected = """
        {
          "body" : "Make it green",
          "requested_at" : "\(Self.fixedDateISO)",
          "source" : "agent",
          "task_id" : "task-123",
          "title" : "Add border"
        }
        """
        XCTAssertEqual(try readString(url), expected)
        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-task-requests/task-123.json"))
    }

    func testTaskClaimStoreEmitsExactJSONBytes() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchTaskClaimStore(worktreePath: tempDir.path, fileManager: fileManager)
        let claim = WorkBatchTaskClaim(
            taskID: "task-123",
            status: "working",
            summary: "in progress",
            claimedAt: Self.fixedDate,
            contextUpdatedAt: Self.fixedDate,
            deliveryGeneration: "gen-1",
        )

        let url = try store.write(claim)

        let expected = """
        {
          "claimed_at" : "\(Self.fixedDateISO)",
          "context_updated_at" : "\(Self.fixedDateISO)",
          "delivery_generation" : "gen-1",
          "status" : "working",
          "summary" : "in progress",
          "task_id" : "task-123"
        }
        """
        XCTAssertEqual(try readString(url), expected)
        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-claims/task-123.json"))
    }

    func testCompletionReportStoreEmitsExactJSONBytes() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager)
        let report = WorkBatchCompletionReport(
            taskID: "task-123",
            status: "done",
            summary: "Added the green border",
            evidence: ["Updated styles", "Verified state"],
            completedAt: Self.fixedDate,
        )

        let url = try store.write(report)

        let expected = """
        {
          "completed_at" : "\(Self.fixedDateISO)",
          "evidence" : [
            "Updated styles",
            "Verified state"
          ],
          "status" : "done",
          "summary" : "Added the green border",
          "task_id" : "task-123"
        }
        """
        XCTAssertEqual(try readString(url), expected)
        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-completions/task-123.json"))
    }

    func testCheckpointRequestStoreEmitsExactJSONBytes() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchCheckpointRequestStore(worktreePath: tempDir.path, fileManager: fileManager)
        let request = WorkBatchCheckpointRequest(
            checkpointID: "ck-1",
            taskID: "task-123",
            question: "Proceed?",
            reason: "ambiguous",
            recommendedAction: "ask",
            requestedAt: Self.fixedDate,
        )

        let url = try store.write(request)

        let expected = """
        {
          "checkpoint_id" : "ck-1",
          "question" : "Proceed?",
          "reason" : "ambiguous",
          "recommended_action" : "ask",
          "requested_at" : "\(Self.fixedDateISO)",
          "task_id" : "task-123"
        }
        """
        XCTAssertEqual(try readString(url), expected)
        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-checkpoints/ck-1.json"))
    }

    func testCheckpointResponseStoreEmitsExactJSONBytes() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchCheckpointResponseStore(worktreePath: tempDir.path, fileManager: fileManager)
        let response = WorkBatchCheckpointResponse(
            checkpointID: "ck-1",
            taskID: "task-123",
            response: "yes",
            respondedAt: Self.fixedDate,
        )

        let url = try store.write(response)

        let expected = """
        {
          "checkpoint_id" : "ck-1",
          "responded_at" : "\(Self.fixedDateISO)",
          "response" : "yes",
          "task_id" : "task-123"
        }
        """
        XCTAssertEqual(try readString(url), expected)
        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-checkpoint-responses/ck-1.json"))
    }

    // MARK: - (5) Round-trip load via the lenient .capacitorISO8601 decoder

    func testTaskRequestStoreRoundTripsThroughLenientDecoder() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchTaskRequestStore(worktreePath: tempDir.path, fileManager: fileManager)
        let request = WorkBatchTaskRequest(
            taskID: "task-123",
            title: "Add border",
            body: "Make it green",
            source: "agent",
            requestedAt: Self.fixedDate,
        )
        _ = try store.write(request)

        let loaded = try store.loadRequests()
        XCTAssertEqual(loaded.map(\.request), [request])
        XCTAssertEqual(loaded.first?.url.lastPathComponent, "task-123.json")
    }

    func testTaskClaimStoreRoundTripsThroughLenientDecoder() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchTaskClaimStore(worktreePath: tempDir.path, fileManager: fileManager)
        let claim = WorkBatchTaskClaim(
            taskID: "task-123",
            status: "working",
            summary: "in progress",
            claimedAt: Self.fixedDate,
            contextUpdatedAt: Self.fixedDate,
            deliveryGeneration: "gen-1",
        )
        _ = try store.write(claim)

        let loaded = try store.loadClaims()
        XCTAssertEqual(loaded.map(\.claim), [claim])
    }

    func testCompletionReportStoreRoundTripsThroughLenientDecoder() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager)
        let report = WorkBatchCompletionReport(
            taskID: "task-123",
            status: "done",
            summary: "Added the green border",
            evidence: ["Updated styles", "Verified state"],
            completedAt: Self.fixedDate,
        )
        _ = try store.write(report)

        let loaded = try store.loadReports()
        XCTAssertEqual(loaded.map(\.report), [report])
    }

    func testCheckpointRequestStoreRoundTripsThroughLenientDecoder() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchCheckpointRequestStore(worktreePath: tempDir.path, fileManager: fileManager)
        let request = WorkBatchCheckpointRequest(
            checkpointID: "ck-1",
            taskID: "task-123",
            question: "Proceed?",
            reason: "ambiguous",
            recommendedAction: "ask",
            requestedAt: Self.fixedDate,
        )
        _ = try store.write(request)

        let loaded = try store.loadRequests()
        XCTAssertEqual(loaded.map(\.request), [request])
    }

    /// The `.iso8601` ENCODER emits timestamps WITHOUT fractional seconds
    /// (e.g. "2026-03-31T23:33:20Z"). The strict `ISO8601DateFormatter` configured
    /// with `.withFractionalSeconds` REJECTS that form (returns nil). The lenient
    /// `.capacitorISO8601` decoder accepts it via its no-fractional-seconds fallback.
    /// This proves the read path is strictly more permissive than a naive strict
    /// fractional parser, which is exactly why the stores' own output round-trips.
    func testLenientDecoderAcceptsTimestampsTheStrictFractionalParserRejects() throws {
        // The store's own emitted form (no fractional seconds).
        let storeEmittedForm = Self.fixedDateISO // "2026-03-31T23:33:20Z"

        // Strict-with-fractional REJECTS the no-fractional-seconds form.
        let strictFractional = ISO8601DateFormatter()
        strictFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNil(
            strictFractional.date(from: storeEmittedForm),
            "Strict fractional parser must reject the no-fractional-seconds form, proving leniency is load-bearing.",
        )

        // The lenient store decoder ACCEPTS it on round-trip.
        let (tempDir, fileManager) = try makeTempWorktree()
        let directoryURL = tempDir.appendingPathComponent(
            WorkBatchCompletionReportStore.relativeDirectory,
            isDirectory: true,
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try """
        {
          "task_id": "task-lenient",
          "status": "done",
          "summary": "round trip",
          "evidence": ["e"],
          "completed_at": "\(storeEmittedForm)"
        }
        """.write(
            to: directoryURL.appendingPathComponent("task-lenient.json"),
            atomically: true,
            encoding: .utf8,
        )

        let loaded = try WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager)
            .loadReports()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.report.completedAt, Self.fixedDate)
    }

    /// The lenient decoder additionally accepts agent-written fractional-second forms
    /// (millisecond precision with explicit "Z"), locking the second leg of leniency.
    func testLenientDecoderAcceptsAgentWrittenFractionalSecondForm() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let directoryURL = tempDir.appendingPathComponent(
            WorkBatchCompletionReportStore.relativeDirectory,
            isDirectory: true,
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try """
        {
          "task_id": "task-frac",
          "status": "done",
          "summary": "frac",
          "evidence": ["e"],
          "completed_at": "2026-05-25T19:02:00.000Z"
        }
        """.write(
            to: directoryURL.appendingPathComponent("task-frac.json"),
            atomically: true,
            encoding: .utf8,
        )

        let loaded = try WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager)
            .loadReports()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.report.completedAt, parseISO8601Date("2026-05-25T19:02:00.000Z"))
    }

    // MARK: - (6) CompletionReportStore.deleteReport dedup-rescan semantics

    func testDeleteReportRemovesBothFilesSharingTheSameTaskID() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager)
        let report = WorkBatchCompletionReport(
            taskID: "task-dup",
            status: "done",
            summary: "Added border",
            evidence: ["Changed CSS"],
            completedAt: Self.fixedDate,
        )

        // (a) Canonical file at the sanitized path.
        let canonicalURL = try store.write(report)

        // (b) A second file with a DIFFERENT filename but the SAME embedded task_id.
        let directoryURL = tempDir.appendingPathComponent(
            WorkBatchCompletionReportStore.relativeDirectory,
            isDirectory: true,
        )
        let manualURL = directoryURL.appendingPathComponent("manual-name.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: manualURL, options: .atomic)

        // Pre-condition: both exist and both load.
        XCTAssertTrue(fileManager.fileExists(atPath: canonicalURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: manualURL.path))
        XCTAssertEqual(try store.loadReports().count, 2)

        // deleteReport must remove BOTH via its dedup-rescan (canonical removal +
        // a rescan that deletes any other loaded report sharing the task_id).
        try store.deleteReport(taskID: "task-dup")

        XCTAssertFalse(fileManager.fileExists(atPath: canonicalURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: manualURL.path))
        XCTAssertTrue(try store.loadReports().isEmpty)
    }

    func testDeleteReportLeavesUnrelatedTaskIDsUntouched() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager)
        let target = WorkBatchCompletionReport(
            taskID: "task-target",
            status: "done",
            summary: "t",
            evidence: ["e"],
            completedAt: nil,
        )
        let bystander = WorkBatchCompletionReport(
            taskID: "task-bystander",
            status: "done",
            summary: "b",
            evidence: ["e"],
            completedAt: nil,
        )
        _ = try store.write(target)
        let bystanderURL = try store.write(bystander)

        try store.deleteReport(taskID: "task-target")

        XCTAssertTrue(fileManager.fileExists(atPath: bystanderURL.path))
        XCTAssertEqual(try store.loadReports().map(\.report), [bystander])
    }

    // MARK: - (7) WRITE-ONLY nature of CheckpointResponseStore

    /// CheckpointResponseStore exposes write + responseURL but NO load method.
    /// We pin write-and-readback-by-hand to confirm the artifact lands and that the
    /// store offers no read API of its own (responses are consumed by the agent side).
    func testCheckpointResponseStoreIsWriteOnlyAndProducesReadableArtifact() throws {
        let (tempDir, fileManager) = try makeTempWorktree()
        let store = WorkBatchCheckpointResponseStore(worktreePath: tempDir.path, fileManager: fileManager)
        let response = WorkBatchCheckpointResponse(
            checkpointID: "ck-1",
            taskID: "task-123",
            response: "yes",
            respondedAt: Self.fixedDate,
        )

        let url = try store.write(response)
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))

        // No store-side load: read the bytes directly and decode with the same lenient
        // strategy the other stores use, confirming the on-disk form is a valid response.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .capacitorISO8601
        let data = try Data(contentsOf: url)
        let decoded = try decoder.decode(WorkBatchCheckpointResponse.self, from: data)
        XCTAssertEqual(decoded, response)
    }
}
