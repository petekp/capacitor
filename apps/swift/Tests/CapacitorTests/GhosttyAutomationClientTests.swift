@testable import Capacitor
import Foundation
import XCTest

final class GhosttyAutomationClientTests: XCTestCase {
    private final class StubAppleScriptClient: AppleScriptClient {
        var results: [AppleScriptExecutionResult] = []

        func run(_: String) {}

        func runChecked(_: String) -> Bool {
            nextResult().success
        }

        func runBoolean(_: String) -> Bool? {
            let result = nextResult()
            guard result.success,
                  let output = result.output?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
            else {
                return nil
            }

            switch output {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }

        func runOutput(_: String) -> AppleScriptExecutionResult {
            nextResult()
        }

        private func nextResult() -> AppleScriptExecutionResult {
            if results.isEmpty {
                return AppleScriptExecutionResult(success: true, output: nil, error: nil)
            }
            return results.removeFirst()
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
