import Foundation
import XCTest

final class RestartAppScriptTests: XCTestCase {
    func testRestartScriptKeepsNewestDebugAppProcessAfterLaunch() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("scripts/dev/restart-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("APP_PID=$(pgrep -n -f \"$DEBUG_APP/Contents/MacOS/Capacitor$\" || true)"))
        XCTAssertTrue(script.contains("terminate_pid_with_escalation \"$DEBUG_PID\" \"duplicate debug app\""))
        XCTAssertTrue(script.contains("pgrep -f \"$DEBUG_APP/Contents/MacOS/Capacitor$\" || true"))
        XCTAssertTrue(script.contains("Keep the newest process"))
    }

    func testRestartScriptFallsBackWhenLaunchServicesDoesNotReportDebugAppProcess() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("scripts/dev/restart-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("LaunchServices did not report the debug app process"))
        XCTAssertTrue(script.contains("nohup \"$DEBUG_APP_BIN\" >/tmp/capacitor-debug-app.launch.log 2>&1 &"))
        XCTAssertTrue(script.contains("for _ in {1..60}; do"))
    }

    func testRestartScriptAllowsCapacitorPreviewBesideDebug() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("scripts/dev/restart-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("CapacitorPreview.app/Contents/MacOS/Capacitor"))
        XCTAssertTrue(script.contains("Capacitor Preview is allowed"))
    }

    func testRestartScriptAddsCargoBinToPathForAgentLaunchedRebuilds() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("scripts/dev/restart-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("export PATH=\"$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}\""))
    }
}
