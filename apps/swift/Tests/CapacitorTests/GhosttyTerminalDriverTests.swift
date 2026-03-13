@testable import Capacitor
import XCTest

final class GhosttyTerminalDriverTests: XCTestCase {
    private final class StubGhosttyAutomationClient: GhosttyAutomationClient {
        var supportStatusValue: GhosttyAutomationSupportStatus = .supported("1.3.0")
        private(set) var createdWindowConfigurations: [GhosttySurfaceConfigurationOptions] = []

        func supportStatus() -> GhosttyAutomationSupportStatus {
            supportStatusValue
        }

        func createWindow(configuration: GhosttySurfaceConfigurationOptions) -> Result<Void, TerminalActivationFailureReason> {
            createdWindowConfigurations.append(configuration)
            return .success(())
        }

        func readSnapshot() -> Result<GhosttyAppSnapshot, TerminalActivationFailureReason> {
            .success(GhosttyAppSnapshot(windows: []))
        }

        func selectTab(id _: String, inWindowID _: String) -> Result<Void, TerminalActivationFailureReason> {
            .success(())
        }

        func focusTerminal(id _: String) -> Result<Void, TerminalActivationFailureReason> {
            .success(())
        }

        func activateWindow(id _: String) -> Result<Void, TerminalActivationFailureReason> {
            .success(())
        }
    }

    func testLaunchUsesNativeWindowCreation() {
        let automationClient = StubGhosttyAutomationClient()
        let driver = GhosttyTerminalDriver(
            automationClient: automationClient,
            isRunning: { false },
        )

        let launched = driver.launch(
            command: "tmux new-session -A -s 'capacitor' -c '/Users/pete/Code/capacitor'",
            projectPath: "/Users/pete/Code/capacitor",
        )

        XCTAssertTrue(launched)
        XCTAssertEqual(
            automationClient.createdWindowConfigurations,
            [
                GhosttySurfaceConfigurationOptions(
                    initialWorkingDirectory: "/Users/pete/Code/capacitor",
                    initialInput: "tmux new-session -A -s 'capacitor' -c '/Users/pete/Code/capacitor'",
                ),
            ],
        )
    }

    func testLaunchCommandScriptUsesNativeWindowCreation() {
        let script = TerminalScripts.launchWithCommand(
            projectPath: "/Users/pete/Code/capacitor",
            command: "claude --resume",
            preferredApp: .ghostty,
        )

        XCTAssertTrue(script.contains("new surface configuration"))
        XCTAssertTrue(script.contains("set initial working directory of launchConfig"))
        XCTAssertTrue(script.contains("set initial input of launchConfig to \"claude --resume\" & linefeed"))
        XCTAssertTrue(script.contains("new window with configuration launchConfig"))
        XCTAssertFalse(script.contains("open -a "))
    }
}
