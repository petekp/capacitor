@testable import Capacitor
import XCTest

@MainActor
final class AppStateTerminalActivationTests: XCTestCase {
    func testActivationFailureWithoutReasonUsesGenericFallbackToast() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()

        appState.terminalLauncher.onActivationResult?(TerminalActivationResult(
            projectName: "capacitor",
            projectPath: "/Users/pete/Code/capacitor",
            success: false,
            usedFallback: false,
            failureReason: nil,
        ))

        XCTAssertEqual(appState.toast?.message, "Couldn't activate terminal.")
        XCTAssertEqual(appState.toast?.isError, true)
    }

    func testActivationFailureUsesHostTerminalFailureMessage() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()

        appState.terminalLauncher.onActivationResult?(TerminalActivationResult(
            projectName: "capacitor",
            projectPath: "/Users/pete/Code/capacitor",
            success: false,
            usedFallback: false,
            failureReason: .hostOperationFailed(
                app: .iTerm,
                operation: .sendCommand,
                detail: "Apple events denied",
            ),
        ))

        XCTAssertEqual(
            appState.toast?.message,
            "Couldn't send the launch command to iTerm. Make sure macOS Automation access is granted. (Apple events denied)",
        )
        XCTAssertEqual(appState.toast?.isError, true)
    }
}
