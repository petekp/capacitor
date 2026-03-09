@testable import Capacitor
import XCTest

@MainActor
final class GhosttyAXReaderTests: XCTestCase {
    private let home = "/Users/pete"

    private func tab(title: String?, index: Int, isSelected: Bool = false) -> GhosttyTabSnapshot {
        GhosttyTabSnapshot(
            element: AXUIElementCreateSystemWide(),
            title: title,
            index: index,
            isSelected: isSelected,
        )
    }

    private func window(index: Int, isMain: Bool = false, tabs: [GhosttyTabSnapshot]) -> GhosttyWindowSnapshot {
        GhosttyWindowSnapshot(
            element: AXUIElementCreateSystemWide(),
            index: index,
            tabs: tabs,
            isMain: isMain,
        )
    }

    func testBestGhosttyTabMatchPrefersExactPathMatch() {
        let windows = [
            window(
                index: 0,
                tabs: [
                    tab(title: "/Users/pete/Code/other", index: 0),
                    tab(title: "/Users/pete/Code/capacitor/subdir", index: 1),
                ],
            ),
            window(
                index: 1,
                tabs: [
                    tab(title: "/Users/pete/Code/capacitor", index: 0),
                ],
            ),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
        )

        XCTAssertEqual(match?.window.index, 1)
        XCTAssertEqual(match?.tab.index, 0)
    }

    func testBestGhosttyTabMatchSupportsDecoratedAndTildeTitles() {
        let windows = [
            window(index: 0, tabs: [
                tab(title: "petepetrash@host:~/Code/capacitor", index: 1),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
        )

        XCTAssertEqual(match?.window.index, 0)
        XCTAssertEqual(match?.tab.index, 1)
    }

    func testBestGhosttyTabMatchSupportsEllipsizedPathTitles() {
        let windows = [
            window(index: 0, tabs: [
                tab(title: "…/Code/aui/assistant-ui", index: 2),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/aui/assistant-ui",
            homeDirectory: home,
        )

        XCTAssertEqual(match?.window.index, 0)
        XCTAssertEqual(match?.tab.index, 2)
    }

    func testBestGhosttyTabMatchSupportsTmuxSessionStyleTitles() {
        let windows = [
            window(index: 0, tabs: [
                tab(title: "~/", index: 0, isSelected: true),
                tab(title: "assistant-ui:1:zsh - \"Work\"", index: 1, isSelected: false),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/aui/assistant-ui",
            homeDirectory: home,
        )

        XCTAssertEqual(match?.window.index, 0)
        XCTAssertEqual(match?.tab.index, 1)
    }

    func testBestGhosttyTabMatchSupportsTmuxSessionHintWhenProjectSlugDiffers() {
        let windows = [
            window(index: 0, tabs: [
                tab(title: "mcp-app-studio:1:2.1.50 - \"✳ Fullscreen Transition Performance\"", index: 0, isSelected: false),
                tab(title: "pnpm dev", index: 1, isSelected: true),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/aui/mcp-app-studio-starter",
            homeDirectory: home,
            tmuxSessionHint: "mcp-app-studio",
        )

        XCTAssertEqual(match?.window.index, 0)
        XCTAssertEqual(match?.tab.index, 0)
    }

    func testBestGhosttyTabMatchSupportsSessionPrefixInProjectSlugWithoutHint() {
        let windows = [
            window(index: 0, tabs: [
                tab(title: "mcp-app-studio:1:2.1.50 - \"✳ Fullscreen Transition Performance\"", index: 0, isSelected: false),
                tab(title: "pnpm dev", index: 1, isSelected: true),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/aui/mcp-app-studio-starter",
            homeDirectory: home,
        )

        XCTAssertEqual(match?.window.index, 0)
        XCTAssertEqual(match?.tab.index, 0)
    }

    func testBestGhosttyTabMatchPrefersSelectedTabWhenRankAndDistanceTie() {
        let windows = [
            window(index: 0, tabs: [
                tab(title: "/Users/pete/Code/capacitor/deep", index: 0, isSelected: false),
                tab(title: "/Users/pete/Code/capacitor/deep", index: 1, isSelected: true),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
        )

        XCTAssertEqual(match?.window.index, 0)
        XCTAssertEqual(match?.tab.index, 1)
    }

    func testBestGhosttyTabMatchFallsBackToLowestTabIndexWhenNotSelected() {
        let windows = [
            window(index: 0, tabs: [
                tab(title: "/Users/pete/Code/capacitor/deep", index: 4, isSelected: false),
                tab(title: "/Users/pete/Code/capacitor/deep", index: 1, isSelected: false),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
        )

        XCTAssertEqual(match?.window.index, 0)
        XCTAssertEqual(match?.tab.index, 1)
    }

    func testBestGhosttyTabMatchPrefersMainWindowAcrossEquivalentCandidates() {
        let windows = [
            window(index: 0, isMain: false, tabs: [
                tab(title: "/Users/pete/Code/capacitor/deep", index: 0, isSelected: true),
            ]),
            window(index: 1, isMain: true, tabs: [
                tab(title: "/Users/pete/Code/capacitor/deep", index: 0, isSelected: true),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
        )

        XCTAssertEqual(match?.window.index, 1)
        XCTAssertEqual(match?.tab.index, 0)
    }

    func testBestGhosttyTabMatchRespectsManagedWorktreeIsolation() {
        let windows = [
            window(index: 0, tabs: [
                tab(title: "/Users/pete/Code/codex/.capacitor/worktrees/workstream-1", index: 0),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/codex/.capacitor/worktrees/workstream-2",
            homeDirectory: home,
        )

        XCTAssertNil(match)
    }

    func testBestGhosttyTabMatchIgnoresNonPathDecoratedTitle() {
        let windows = [
            window(index: 0, tabs: [
                tab(title: "🔔 tool-ui:1:2.1.50 - \"✳ Tooling Workspace Setup\"", index: 0),
            ]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
        )

        XCTAssertNil(match)
    }

    func testBestGhosttyTabMatchReturnsNilWhenNoTabsMatch() {
        let windows = [
            window(index: 0, tabs: []),
            window(index: 1, tabs: [tab(title: nil, index: 0)]),
        ]

        let match = bestGhosttyTabMatch(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
        )

        XCTAssertNil(match)
    }

    // MARK: - Window Title Session Matching (D-008)

    /// When tabs aren't enumerable (tabCount=0), window title provides the
    /// session match signal. A window whose title contains the session name
    /// indicates the session IS displayed in that window.
    func testWindowTitleMatchesSessionWithSessionHint() {
        let windows = [
            window(index: 0, title: "capacitor: ~/Code/capacitor", tabs: []),
        ]

        let result = ghosttyWindowTitleMatchesSession(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
            tmuxSessionHint: "capacitor",
        )

        XCTAssertTrue(result, "Window title containing session name should match")
    }

    func testWindowTitleMatchesSessionViaProjectPath() {
        let windows = [
            window(index: 0, title: "~/Code/capacitor", tabs: []),
        ]

        let result = ghosttyWindowTitleMatchesSession(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
        )

        XCTAssertTrue(result, "Window title matching project path should match")
    }

    func testWindowTitleDoesNotMatchUnrelatedSession() {
        let windows = [
            window(index: 0, title: "other-project: ~/Code/other-project", tabs: []),
        ]

        let result = ghosttyWindowTitleMatchesSession(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
            tmuxSessionHint: "capacitor",
        )

        XCTAssertFalse(result, "Unrelated window title should not match")
    }

    func testWindowTitleDoesNotMatchWhenWindowsHaveNoTitles() {
        let windows = [
            window(index: 0, title: nil, tabs: []),
            window(index: 1, title: "", tabs: []),
        ]

        let result = ghosttyWindowTitleMatchesSession(
            windows: windows,
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
            tmuxSessionHint: "capacitor",
        )

        XCTAssertFalse(result, "Windows without titles should not match")
    }

    func testWindowTitleDoesNotMatchEmptyWindows() {
        let result = ghosttyWindowTitleMatchesSession(
            windows: [],
            projectPath: "/Users/pete/Code/capacitor",
            homeDirectory: home,
        )

        XCTAssertFalse(result, "Empty window list should not match")
    }

    // MARK: - Helpers

    private func window(index: Int, title: String?, isMain: Bool = false, tabs: [GhosttyTabSnapshot]) -> GhosttyWindowSnapshot {
        GhosttyWindowSnapshot(
            element: AXUIElementCreateSystemWide(),
            index: index,
            tabs: tabs,
            isMain: isMain,
            title: title,
        )
    }
}
