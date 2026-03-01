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

    func testStartupEventFormattingForPolicyBlockedIncludesReason() {
        let expectation = expectation(description: "captured log line")
        var capturedLine: String?
        DebugLog.setTestObserver { line in
            capturedLine = line
            expectation.fulfill()
        }
        defer { DebugLog.setTestObserver(nil) }

        DebugLog.write(startup: .hooksBlockedByPolicy(reason: "disableAllHooks is enabled."))
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(capturedLine?.contains("[Startup] Hooks blocked by policy (disableAllHooks is enabled.), showing WelcomeView") == true)
    }

    func testStartupEventFormattingForRepairIncludesStatusLabel() {
        let expectation = expectation(description: "captured log line")
        var capturedLine: String?
        DebugLog.setTestObserver { line in
            capturedLine = line
            expectation.fulfill()
        }
        defer { DebugLog.setTestObserver(nil) }

        DebugLog.write(startup: .hooksNeedAutoRepair(status: .binaryBroken(reason: "codesign error")))
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(capturedLine?.contains("[Startup] Hook status binaryBroken requires auto-repair") == true)
    }

    func testStartupEventFormattingForShellIntegrationIncludesConfigFile() {
        let expectation = expectation(description: "captured log line")
        var capturedLine: String?
        DebugLog.setTestObserver { line in
            capturedLine = line
            expectation.fulfill()
        }
        defer { DebugLog.setTestObserver(nil) }

        DebugLog.write(startup: .shellIntegrationInstalled(configFile: "~/.zshrc"))
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(capturedLine?.contains("[Startup] Shell integration installed in ~/.zshrc") == true)
    }
}
