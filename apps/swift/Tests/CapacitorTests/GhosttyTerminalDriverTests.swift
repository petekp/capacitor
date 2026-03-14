@testable import Capacitor
import XCTest

final class GhosttyTerminalDriverTests: XCTestCase {
    private final class StubGhosttyAutomationClient: GhosttyAutomationClient {
        var supportStatusValue: GhosttyAutomationSupportStatus = .supported("1.3.0")
        private(set) var createdWindowConfigurations: [GhosttySurfaceConfigurationOptions] = []
        private(set) var createdTabs: [(windowID: String, configuration: GhosttySurfaceConfigurationOptions)] = []
        var snapshot = GhosttyAppSnapshot(windows: [])

        func supportStatus() -> GhosttyAutomationSupportStatus {
            supportStatusValue
        }

        func createWindow(configuration: GhosttySurfaceConfigurationOptions) -> Result<Void, TerminalActivationFailureReason> {
            createdWindowConfigurations.append(configuration)
            return .success(())
        }

        func createTab(inWindowID windowID: String, configuration: GhosttySurfaceConfigurationOptions) -> Result<Void, TerminalActivationFailureReason> {
            createdTabs.append((windowID: windowID, configuration: configuration))
            return .success(())
        }

        func readSnapshot() -> Result<GhosttyAppSnapshot, TerminalActivationFailureReason> {
            .success(snapshot)
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

    func testLaunchUsesNativeWindowCreation() async {
        let automationClient = StubGhosttyAutomationClient()
        let driver = GhosttyTerminalDriver(
            automationClient: automationClient,
            isRunning: { false },
        )

        let launched = await driver.launch(
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

    func testLaunchUsesNewTabInFrontWindowWhenGhosttyIsAlreadyRunning() async {
        let automationClient = StubGhosttyAutomationClient()
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "win-front",
                name: "Ghostty",
                isFront: true,
                tabs: [],
            ),
            GhosttyWindowSnapshot(
                id: "win-back",
                name: "Ghostty 2",
                isFront: false,
                tabs: [],
            ),
        ])

        let driver = GhosttyTerminalDriver(
            automationClient: automationClient,
            isRunning: { true },
        )

        let launched = await driver.launch(
            command: "tmux new-session -A -s 'attune' -c '/Users/pete/Code/attune'",
            projectPath: "/Users/pete/Code/attune",
        )

        XCTAssertTrue(launched)
        XCTAssertTrue(automationClient.createdWindowConfigurations.isEmpty)
        XCTAssertEqual(automationClient.createdTabs.count, 1)
        XCTAssertEqual(automationClient.createdTabs.first?.windowID, "win-front")
        XCTAssertEqual(
            automationClient.createdTabs.first?.configuration,
            GhosttySurfaceConfigurationOptions(
                initialWorkingDirectory: "/Users/pete/Code/attune",
                initialInput: "tmux new-session -A -s 'attune' -c '/Users/pete/Code/attune'",
            ),
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

    func testCreateTabAppleScriptUsesFrontWindowTarget() {
        let script = ghosttyCreateTabAppleScript(
            windowID: "win-front",
            configuration: GhosttySurfaceConfigurationOptions(
                initialWorkingDirectory: "/Users/pete/Code/attune",
                initialInput: "tmux new-session -A -s 'attune' -c '/Users/pete/Code/attune'",
            ),
        )

        XCTAssertTrue(script.contains("set targetWindow to first window whose id is \"win-front\""))
        XCTAssertTrue(script.contains("new tab in targetWindow with configuration launchConfig"))
    }
}
