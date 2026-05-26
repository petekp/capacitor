@testable import Capacitor
import Foundation
import XCTest

final class GhosttyAutomationClientTests: XCTestCase {
    private final class StubAppleScriptClient: AppleScriptClient {
        var results: [AppleScriptExecutionResult] = []
        private(set) var scripts: [String] = []

        func runOutput(_ script: String) -> AppleScriptExecutionResult {
            scripts.append(script)
            return nextResult()
        }

        private func nextResult() -> AppleScriptExecutionResult {
            if results.isEmpty {
                return AppleScriptExecutionResult(success: true, output: nil, error: nil)
            }
            return results.removeFirst()
        }
    }

    private final class RecordingGhosttyAutomationClient: GhosttyAutomationClient {
        var snapshot = GhosttyAppSnapshot(windows: [])
        var selectedTabs: [(tabID: String, windowID: String)] = []
        var focusedTerminals: [String] = []
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

        func activateWindow(id _: String) -> Result<Void, TerminalActivationFailureReason> {
            .success(())
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

    func testParseSnapshotOutputAggregatesRowsIntoWindowTabTerminalHierarchy() {
        let output = [
            makeRow(
                windowID: "window-1",
                windowName: "Ghostty 1",
                isFront: true,
                tabID: "tab-1",
                tabName: "caps",
                tabIndex: 1,
                tabSelected: true,
                terminalID: "term-1",
                terminalName: "caps",
                terminalWorkingDirectory: "/Users/pete/Code/capacitor",
                focusedTerminalID: "term-1",
            ),
            makeRow(
                windowID: "window-1",
                windowName: "Ghostty 1",
                isFront: true,
                tabID: "tab-1",
                tabName: "caps",
                tabIndex: 1,
                tabSelected: true,
                terminalID: "term-2",
                terminalName: "pnpm dev",
                terminalWorkingDirectory: "/Users/pete/Code/capacitor",
                focusedTerminalID: "term-1",
            ),
        ].joined(separator: GhosttyAppleScriptDelimiters.row)

        let snapshot = DefaultGhosttyAutomationClient.parseSnapshotOutput(output)

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.id, "window-1")
        XCTAssertEqual(snapshot.windows.first?.tabs.count, 1)
        XCTAssertEqual(snapshot.windows.first?.tabs.first?.focusedTerminalID, "term-1")
        XCTAssertEqual(snapshot.windows.first?.tabs.first?.terminals.count, 2)
    }

    func testBestGhosttyRouteMatchPrefersCachedTerminalID() {
        let snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "window-1",
                name: "Caps",
                isFront: false,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "caps",
                        index: 1,
                        isSelected: false,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "caps",
                                workingDirectory: "/Users/pete/Code/capacitor",
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                ],
            ),
            GhosttyWindowSnapshot(
                id: "window-2",
                name: "Other",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-2",
                        name: "other",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-2",
                                name: "other",
                                workingDirectory: "/Users/pete/Code/other",
                            ),
                        ],
                        focusedTerminalID: "term-2",
                    ),
                ],
            ),
        ])

        let match = bestGhosttyRouteMatch(
            snapshot: snapshot,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: "/Users/pete",
            preferredTerminalID: "term-2",
        )

        XCTAssertEqual(match?.source, .cachedTerminalID)
        XCTAssertEqual(match?.terminal?.id, "term-2")
    }

    func testInputTextTargetsGhosttyTerminalByID() {
        let appleScript = StubAppleScriptClient()
        let client = DefaultGhosttyAutomationClient(
            appleScript: appleScript,
            versionProvider: { "1.3.0" },
        )

        let result = client.inputText("Read .capacitor/work-batch-context.md again", terminalID: "term-1")

        if case .failure = result {
            XCTFail("Expected input text to succeed")
        }
        XCTAssertEqual(appleScript.scripts.count, 1)
        XCTAssertTrue(appleScript.scripts[0].contains("input text"))
        XCTAssertTrue(appleScript.scripts[0].contains("terminal id \"term-1\""))
        XCTAssertTrue(appleScript.scripts[0].contains("work-batch-context.md again"))
    }

    func testSendKeyTargetsGhosttyTerminalByID() {
        let appleScript = StubAppleScriptClient()
        let client = DefaultGhosttyAutomationClient(
            appleScript: appleScript,
            versionProvider: { "1.3.0" },
        )

        let result = client.sendKey("enter", terminalID: "term-1")

        if case .failure = result {
            XCTFail("Expected send key to succeed")
        }
        XCTAssertEqual(appleScript.scripts.count, 1)
        XCTAssertTrue(appleScript.scripts[0].contains("send key \"enter\""))
        XCTAssertTrue(appleScript.scripts[0].contains("terminal id \"term-1\""))
    }

    func testWorkBatchWakerInputsPromptIntoMatchedWorktreeTerminal() {
        let automationClient = RecordingGhosttyAutomationClient()
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "window-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "Mobile Prototype Polish",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "Mobile Prototype Polish",
                                workingDirectory: "/Users/pete/Code/app/.capacitor/worktrees/batch-mobile",
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                ],
            ),
        ])
        let waker = WorkBatchGhosttySessionWaker(
            automationClient: automationClient,
            homeDirectory: "/Users/pete",
        )

        let didWake = waker.wake(
            worktreePath: "/Users/pete/Code/app/.capacitor/worktrees/batch-mobile",
            batchName: "Mobile Prototype Polish",
            prompt: "Read .capacitor/work-batch-context.md again",
        )

        XCTAssertTrue(didWake)
        XCTAssertEqual(automationClient.focusedTerminals, ["term-1"])
        XCTAssertEqual(automationClient.inputTexts.count, 1)
        XCTAssertEqual(automationClient.inputTexts[0].text, "Read .capacitor/work-batch-context.md again")
        XCTAssertEqual(automationClient.inputTexts[0].terminalID, "term-1")
        XCTAssertEqual(automationClient.sentKeys.count, 1)
        XCTAssertEqual(automationClient.sentKeys[0].key, "enter")
        XCTAssertEqual(automationClient.sentKeys[0].terminalID, "term-1")
    }

    func testWorkBatchWakerDoesNotInputWhenNoWorktreeTerminalMatches() {
        let automationClient = RecordingGhosttyAutomationClient()
        automationClient.snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "window-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "Other",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "Other",
                                workingDirectory: "/Users/pete/Code/other",
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                ],
            ),
        ])
        let waker = WorkBatchGhosttySessionWaker(
            automationClient: automationClient,
            homeDirectory: "/Users/pete",
        )

        let didWake = waker.wake(
            worktreePath: "/Users/pete/Code/app/.capacitor/worktrees/batch-mobile",
            batchName: "Mobile Prototype Polish",
            prompt: "Read context",
        )

        XCTAssertFalse(didWake)
        XCTAssertTrue(automationClient.inputTexts.isEmpty)
        XCTAssertTrue(automationClient.sentKeys.isEmpty)
    }

    func testBestGhosttyRouteMatchPrefersWorkingDirectoryOverStaleTitle() {
        let snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "window-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "capacitor: ~/Code/capacitor",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "capacitor: ~/Code/capacitor",
                                workingDirectory: "/Users/pete/Code/agentic-canvas-v2",
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                ],
            ),
        ])

        let match = bestGhosttyRouteMatch(
            snapshot: snapshot,
            projectPath: "/Users/pete/Code/agentic-canvas-v2",
            homeDirectory: "/Users/pete",
            tmuxSessionHint: "agentic-canvas-v2",
        )

        XCTAssertEqual(match?.source, .terminalWorkingDirectory)
        XCTAssertEqual(match?.terminal?.id, "term-1")
    }

    func testBestGhosttyRouteMatchRespectsManagedWorktreeIsolation() {
        let snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "window-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "workstream-1",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-1",
                                name: "workstream-1",
                                workingDirectory: "/Users/pete/Code/codex/.capacitor/worktrees/workstream-1",
                            ),
                        ],
                        focusedTerminalID: "term-1",
                    ),
                ],
            ),
        ])

        let match = bestGhosttyRouteMatch(
            snapshot: snapshot,
            projectPath: "/Users/pete/Code/codex/.capacitor/worktrees/workstream-2",
            homeDirectory: "/Users/pete",
            tmuxSessionHint: "workstream-2",
        )

        XCTAssertNil(match)
    }

    func testBestGhosttyRouteMatchKeepsPathMatchingCaseSensitive() {
        let snapshot = GhosttyAppSnapshot(windows: [
            GhosttyWindowSnapshot(
                id: "window-1",
                name: "Ghostty",
                isFront: true,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-1",
                        name: "caps",
                        index: 1,
                        isSelected: true,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-upper",
                                name: "caps",
                                workingDirectory: "/Users/pete/Code/Foo",
                            ),
                        ],
                        focusedTerminalID: "term-upper",
                    ),
                ],
            ),
            GhosttyWindowSnapshot(
                id: "window-2",
                name: "Ghostty",
                isFront: false,
                tabs: [
                    GhosttyTabSnapshot(
                        id: "tab-2",
                        name: "caps",
                        index: 1,
                        isSelected: false,
                        terminals: [
                            GhosttyTerminalSnapshot(
                                id: "term-lower",
                                name: "caps",
                                workingDirectory: "/Users/pete/Code/foo",
                            ),
                        ],
                        focusedTerminalID: "term-lower",
                    ),
                ],
            ),
        ])

        let match = bestGhosttyRouteMatch(
            snapshot: snapshot,
            projectPath: "/Users/pete/Code/foo",
            homeDirectory: "/Users/pete",
        )

        XCTAssertEqual(match?.terminal?.id, "term-lower")
        XCTAssertEqual(match?.source, .terminalWorkingDirectory)
    }

    func testSupportStatusRejectsUnsupportedVersion() {
        let client = DefaultGhosttyAutomationClient(
            appleScript: StubAppleScriptClient(),
            versionProvider: { "1.2.9" },
        )

        XCTAssertEqual(client.supportStatus(), .unsupported(.ghosttyUnsupportedVersion("1.2.9")))
    }

    func testSupportStatusMarksAppleScriptFailuresUnavailable() {
        let appleScript = StubAppleScriptClient()
        appleScript.results = [
            AppleScriptExecutionResult(success: false, output: nil, error: "Apple events disabled"),
        ]
        let client = DefaultGhosttyAutomationClient(
            appleScript: appleScript,
            versionProvider: { "1.3.0" },
        )

        XCTAssertEqual(
            client.supportStatus(),
            .unsupported(.ghosttyAutomationUnavailable("Apple events disabled")),
        )
    }

    private func makeRow(
        windowID: String,
        windowName: String,
        isFront: Bool,
        tabID: String,
        tabName: String,
        tabIndex: Int,
        tabSelected: Bool,
        terminalID: String,
        terminalName: String,
        terminalWorkingDirectory: String,
        focusedTerminalID: String,
    ) -> String {
        [
            windowID,
            windowName,
            isFront ? "true" : "false",
            tabID,
            tabName,
            String(tabIndex),
            tabSelected ? "true" : "false",
            terminalID,
            terminalName,
            terminalWorkingDirectory,
            focusedTerminalID,
        ].joined(separator: GhosttyAppleScriptDelimiters.field)
    }
}
