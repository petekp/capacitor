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

        func inputText(_: String, terminalID _: String) -> Result<Void, TerminalActivationFailureReason> {
            .success(())
        }

        func sendKey(_: String, terminalID _: String) -> Result<Void, TerminalActivationFailureReason> {
            .success(())
        }
    }

    private final class RecordingGhosttyAutomationClient: GhosttyAutomationClient {
        var snapshot = GhosttyAppSnapshot(windows: [])
        var selectedTabs: [(tabID: String, windowID: String)] = []
        var focusedTerminals: [String] = []
        var activatedWindows: [String] = []
        var inputTexts: [(text: String, terminalID: String)] = []
        var sentKeys: [(key: String, terminalID: String)] = []

        func supportStatus() -> GhosttyAutomationSupportStatus {
            .supported("1.3.0")
        }

        func createWindow(configuration _: GhosttySurfaceConfigurationOptions) -> Result<Void, TerminalActivationFailureReason> {
            .success(())
        }

        func createTab(inWindowID _: String, configuration _: GhosttySurfaceConfigurationOptions) -> Result<Void, TerminalActivationFailureReason> {
            .success(())
        }

        func readSnapshot() -> Result<GhosttyAppSnapshot, TerminalActivationFailureReason> {
            .success(snapshot)
        }

        func selectTab(id: String, inWindowID windowID: String) -> Result<Void, TerminalActivationFailureReason> {
            selectedTabs.append((tabID: id, windowID: windowID))
            return .success(())
        }

        func focusTerminal(id: String) -> Result<Void, TerminalActivationFailureReason> {
            focusedTerminals.append(id)
            return .success(())
        }

        func activateWindow(id: String) -> Result<Void, TerminalActivationFailureReason> {
            activatedWindows.append(id)
            return .success(())
        }

        func inputText(_ text: String, terminalID: String) -> Result<Void, TerminalActivationFailureReason> {
            inputTexts.append((text: text, terminalID: terminalID))
            return .success(())
        }

        func sendKey(_ key: String, terminalID: String) -> Result<Void, TerminalActivationFailureReason> {
            sentKeys.append((key: key, terminalID: terminalID))
            return .success(())
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

    func testLaunchCommandScriptReusesFrontGhosttyWindowWhenPossible() {
        let script = TerminalScripts.launchWithCommand(
            projectPath: "/Users/pete/Code/capacitor",
            command: "claude --resume",
            preferredApp: .ghostty,
        )

        XCTAssertTrue(script.contains("new surface configuration"))
        XCTAssertTrue(script.contains("set initial working directory of launchConfig"))
        XCTAssertTrue(script.contains("set initial input of launchConfig to \"claude --resume\" & linefeed"))
        XCTAssertTrue(script.contains("if (count of windows) > 0 then"))
        XCTAssertTrue(script.contains("set targetWindow to front window"))
        XCTAssertTrue(script.contains("new tab in targetWindow with configuration launchConfig"))
        XCTAssertTrue(script.contains("new window with configuration launchConfig"))
        XCTAssertFalse(script.contains("open -a "))
    }

    func testDirectFocusSkipsStaleCwdMatchInSelectedTab() async {
        let automationClient = RecordingGhosttyAutomationClient()
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "win-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "capacitor",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "capacitor",
                                workingDirectory: "/Users/pete/Code/capacitor",
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                ],
            ),
        ])

        let driver = GhosttyTerminalDriver(
            automationClient: automationClient,
            isRunning: { true },
        )

        let result = await driver.focus(
            clientTty: nil,
            projectPath: "/Users/pete/Code/capacitor",
            tmuxSessionHint: nil,
        )

        XCTAssertEqual(result, .relaunchNeeded)
        XCTAssertTrue(automationClient.selectedTabs.isEmpty)
        XCTAssertTrue(automationClient.focusedTerminals.isEmpty)
    }

    func testDirectFocusFindsCwdMatchInDifferentTab() async {
        let automationClient = RecordingGhosttyAutomationClient()
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "win-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "notes",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "notes",
                                workingDirectory: "/Users/pete/Notes",
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                    GhosttyTabSnapshot(
                        id: "tab-2",
                        name: "capacitor",
                        index: 2,
                        isSelected: false,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-2",
                                name: "capacitor",
                                workingDirectory: "/Users/pete/Code/capacitor",
                            ),
                        ],
                        focusedTerminalID: "term-2",
                    ),
                ],
            ),
        ])

        let driver = GhosttyTerminalDriver(
            automationClient: automationClient,
            isRunning: { true },
        )

        let result = await driver.focus(
            clientTty: nil,
            projectPath: "/Users/pete/Code/capacitor",
            tmuxSessionHint: nil,
        )

        XCTAssertEqual(result, .focused)
        XCTAssertEqual(automationClient.selectedTabs.count, 1)
        XCTAssertEqual(automationClient.selectedTabs.first?.tabID, "tab-2")
        XCTAssertEqual(automationClient.selectedTabs.first?.windowID, "win-1")
        XCTAssertEqual(automationClient.focusedTerminals, ["term-2"])
    }

    func testDirectFocusAllowsTitleMatchInSelectedTab() async {
        let automationClient = RecordingGhosttyAutomationClient()
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "win-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "scratch",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "capacitor: claude",
                                workingDirectory: nil,
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                ],
            ),
        ])

        let driver = GhosttyTerminalDriver(
            automationClient: automationClient,
            isRunning: { true },
        )

        let result = await driver.focus(
            clientTty: nil,
            projectPath: "/Users/pete/Code/capacitor",
            tmuxSessionHint: nil,
        )

        XCTAssertEqual(result, .focused)
        XCTAssertTrue(automationClient.selectedTabs.isEmpty)
        XCTAssertEqual(automationClient.focusedTerminals, ["term-1"])
    }

    /// Regression test for terminal tab switch bug:
    /// When a non-tmux project (Tab A) is activated using a tmux client TTY from Tab B,
    /// the cache maps Tab B's TTY → Tab A's terminal ID. A subsequent tmux project
    /// activation must NOT reuse that stale cache entry.
    func testFocusDoesNotReuseStaleCacheForTmuxActivation() async {
        let automationClient = RecordingGhosttyAutomationClient()
        // Snapshot: Tab A (arc-design-studio, non-tmux), Tab B (tmux client)
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "win-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-a",
                        name: "arc-design-studio",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-a",
                                name: "arc-design-studio",
                                workingDirectory: "/Users/pete/Code/arc-design-studio",
                            ),
                        ],
                        focusedTerminalID: "term-a",
                    ),
                    GhosttyTabSnapshot(
                        id: "tab-b",
                        name: "old-session",
                        index: 2,
                        isSelected: false,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-b",
                                name: "old-session",
                                workingDirectory: "/Users/pete",
                            ),
                        ],
                        focusedTerminalID: "term-b",
                    ),
                ],
            ),
        ])

        let driver = GhosttyTerminalDriver(
            automationClient: automationClient,
            isRunning: { true },
        )

        // Step 1: Activate arc-design-studio using the tmux client TTY from Tab B.
        // This finds Tab A by CWD match. The fix should NOT cache term-a under this TTY.
        let result1 = await driver.focus(
            clientTty: "/dev/ttys042",
            projectPath: "/Users/pete/Code/arc-design-studio",
            tmuxSessionHint: "arc-design-studio",
        )
        XCTAssertEqual(result1, .focused)

        // Step 2: Now simulate tmux switch-client to "capacitor" — Tab B's title updates.
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "win-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-a",
                        name: "arc-design-studio",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-a",
                                name: "arc-design-studio",
                                workingDirectory: "/Users/pete/Code/arc-design-studio",
                            ),
                        ],
                        focusedTerminalID: "term-a",
                    ),
                    GhosttyTabSnapshot(
                        id: "tab-b",
                        name: "capacitor",
                        index: 2,
                        isSelected: false,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-b",
                                name: "capacitor",
                                workingDirectory: "/Users/pete/Code/capacitor",
                            ),
                        ],
                        focusedTerminalID: "term-b",
                    ),
                ],
            ),
        ])

        automationClient.selectedTabs.removeAll()

        // Step 3: Activate capacitor. Should find Tab B by session hint, NOT Tab A via cache.
        let result2 = await driver.focus(
            clientTty: "/dev/ttys042",
            projectPath: "/Users/pete/Code/capacitor",
            tmuxSessionHint: "capacitor",
        )
        XCTAssertEqual(result2, .focused)
        // Tab B was not selected, so selectTab must have been called for tab-b
        XCTAssertTrue(
            automationClient.selectedTabs.contains(where: { $0.tabID == "tab-b" }),
            "Expected tab-b to be selected, but got: \(automationClient.selectedTabs)",
        )
        // Should NOT have selected tab-a (the stale cache target)
        XCTAssertFalse(
            automationClient.selectedTabs.contains(where: { $0.tabID == "tab-a" }),
            "tab-a should NOT have been selected — that would mean the stale cache was used",
        )
    }

    func testCacheIsPopulatedOnSessionHintMatch() async {
        let automationClient = RecordingGhosttyAutomationClient()
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "win-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "capacitor",
                        index: 1,
                        isSelected: false,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "capacitor",
                                workingDirectory: "/Users/pete/Code/capacitor",
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                ],
            ),
        ])

        let driver = GhosttyTerminalDriver(
            automationClient: automationClient,
            isRunning: { true },
        )

        // First activation — matches by CWD + session hint. Session hint match wins for cache.
        let result1 = await driver.focus(
            clientTty: "/dev/ttys042",
            projectPath: "/Users/pete/Code/capacitor",
            tmuxSessionHint: "capacitor",
        )
        XCTAssertEqual(result1, .focused)

        // Second activation — if cache was populated by session hint, it should still work.
        // Change the snapshot so CWD no longer matches but the terminal ID is cached.
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "win-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "capacitor",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "capacitor",
                                workingDirectory: "/Users/pete/Code/capacitor/subdir",
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                ],
            ),
        ])

        let result2 = await driver.focus(
            clientTty: "/dev/ttys042",
            projectPath: "/Users/pete/Code/capacitor",
            tmuxSessionHint: "capacitor",
        )
        XCTAssertEqual(result2, .focused)
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
