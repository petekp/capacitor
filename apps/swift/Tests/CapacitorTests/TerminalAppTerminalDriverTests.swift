@testable import Capacitor
import XCTest

final class TerminalAppTerminalDriverTests: XCTestCase {
    private final class StubAppleScriptClient: AppleScriptClient {
        private(set) var outputScripts: [String] = []
        var outputResults: [AppleScriptExecutionResult] = []

        func runOutput(_ script: String) -> AppleScriptExecutionResult {
            outputScripts.append(script)
            if outputResults.isEmpty {
                return AppleScriptExecutionResult(success: true, output: "false\n", error: nil)
            }
            return outputResults.removeFirst()
        }
    }

    func testFocusReturnsFocusedWhenTTYMatches() async {
        let appleScript = StubAppleScriptClient()
        appleScript.outputResults = [
            AppleScriptExecutionResult(success: true, output: "true\n", error: nil),
        ]

        let driver = TerminalAppTerminalDriver(
            appleScript: appleScript,
            isRunning: { true },
            runShell: { _ in
                XCTFail("focus should not run shell commands")
                return (1, nil)
            },
        )

        let result = await driver.focus(
            clientTty: "/dev/ttys001",
            projectPath: "/Users/pete/Code/capacitor",
            tmuxSessionHint: "capacitor",
        )

        XCTAssertEqual(result, .focused)
        XCTAssertNil(driver.lastFailureReason)
    }

    func testFocusReturnsRelaunchNeededWhenTTYDoesNotMatch() async {
        let appleScript = StubAppleScriptClient()
        appleScript.outputResults = [
            AppleScriptExecutionResult(success: true, output: "false\n", error: nil),
        ]

        let driver = TerminalAppTerminalDriver(
            appleScript: appleScript,
            isRunning: { true },
            runShell: { _ in
                XCTFail("focus should not run shell commands")
                return (1, nil)
            },
        )

        let result = await driver.focus(
            clientTty: "/dev/ttys001",
            projectPath: "/Users/pete/Code/capacitor",
            tmuxSessionHint: "capacitor",
        )

        XCTAssertEqual(result, .relaunchNeeded)
        XCTAssertNil(driver.lastFailureReason)
    }

    func testFocusReturnsFailedWhenAppleScriptExecutionFails() async {
        let appleScript = StubAppleScriptClient()
        appleScript.outputResults = [
            AppleScriptExecutionResult(success: false, output: nil, error: "Apple events disabled"),
        ]

        let driver = TerminalAppTerminalDriver(
            appleScript: appleScript,
            isRunning: { true },
            runShell: { _ in
                XCTFail("focus should not run shell commands")
                return (1, nil)
            },
        )

        let result = await driver.focus(
            clientTty: "/dev/ttys001",
            projectPath: "/Users/pete/Code/capacitor",
            tmuxSessionHint: "capacitor",
        )

        XCTAssertEqual(
            result,
            .failed(.hostOperationFailed(
                app: .terminal,
                operation: .focusByTTY,
                detail: "Apple events disabled",
            )),
        )
        XCTAssertEqual(
            driver.lastFailureReason,
            .hostOperationFailed(
                app: .terminal,
                operation: .focusByTTY,
                detail: "Apple events disabled",
            ),
        )
    }

    func testLaunchReturnsFalseWhenOpenFails() async {
        var commands: [String] = []
        let driver = TerminalAppTerminalDriver(
            appleScript: StubAppleScriptClient(),
            isRunning: { false },
            runShell: { script in
                commands.append(script)
                return (1, "open failed")
            },
        )

        let launched = await driver.launch(
            command: "tmux new-session -A -s 'capacitor' -c '/Users/pete/Code/capacitor'",
            projectPath: "/Users/pete/Code/capacitor",
        )

        XCTAssertFalse(launched)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].contains("open -b com.apple.Terminal"))
        XCTAssertEqual(
            driver.lastFailureReason,
            .hostOperationFailed(
                app: .terminal,
                operation: .openApplication,
                detail: "open failed",
            ),
        )
    }

    func testLaunchReturnsFalseWhenSendCommandFails() async {
        var commands: [String] = []
        let driver = TerminalAppTerminalDriver(
            appleScript: StubAppleScriptClient(),
            isRunning: { true },
            runShell: { script in
                commands.append(script)
                if commands.count == 1 {
                    return (0, nil)
                }
                return (1, "keystroke denied")
            },
        )

        let launched = await driver.launch(
            command: "tmux new-session -A -s 'capacitor' -c '/Users/pete/Code/capacitor'",
            projectPath: "/Users/pete/Code/capacitor",
        )

        XCTAssertFalse(launched)
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[1].contains("tell application \"Terminal\""))
        XCTAssertTrue(commands[1].contains("do script"))
        XCTAssertFalse(commands[1].contains("tell process \"Terminal\""))
        XCTAssertEqual(
            driver.lastFailureReason,
            .hostOperationFailed(
                app: .terminal,
                operation: .sendCommand,
                detail: "keystroke denied",
            ),
        )
    }
}
