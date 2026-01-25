@testable import Capacitor
import XCTest

final class DebugLogTests: XCTestCase {
    func testWriteTrimsOversizedLogAndRetainsRecentEntries() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capacitor-debuglog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logURL = tempDir.appendingPathComponent("app-debug.log")
        let maxBytes = 1024
        let retainBytes = 256

        for index in 0 ..< 120 {
            let payload = String(repeating: "x", count: 64)
            DebugLog.write(
                "entry-\(index)-\(payload)",
                to: logURL,
                fallbackURL: nil,
                maxBytes: maxBytes,
                retainBytes: retainBytes,
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(size, maxBytes + 256)

        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains("entry-119-"), "Newest entries should be retained after trim")
        XCTAssertFalse(content.contains("entry-0-"), "Oldest entries should be discarded after trim")
        XCTAssertTrue(content.contains("[DebugLog] trimmed oversized log"), "Trim events should be visible in log")
    }
}
