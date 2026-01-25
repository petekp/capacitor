@testable import Capacitor
import XCTest

@MainActor
final class ShellStateStoreRoutingStatusTests: XCTestCase {
    func testApplyRuntimeShellStateSetsStoreState() async {
        let store = ShellStateStore()
        let shellState = ShellCwdState(
            version: 1,
            shells: [
                "4242": ShellEntry(
                    cwd: "/tmp/core-project",
                    tty: "/dev/ttys001",
                    parentApp: "Ghostty",
                    tmuxSession: "core",
                    tmuxClientTty: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                ),
            ],
        )

        await store.applyRuntimeShellState(shellState, correlationId: "shell-apply-test")

        XCTAssertEqual(store.state?.version, 1)
        XCTAssertEqual(store.state?.shells["4242"]?.cwd, "/tmp/core-project")
        XCTAssertEqual(store.state?.shells["4242"]?.tmuxSession, "core")
    }

    func testApplyRuntimeShellStateReplacesPreviousState() async {
        let store = ShellStateStore()
        let initialState = ShellCwdState(
            version: 1,
            shells: [
                "100": ShellEntry(
                    cwd: "/tmp/old",
                    tty: "/dev/ttys005",
                    parentApp: "Terminal",
                    tmuxSession: nil,
                    tmuxClientTty: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                ),
            ],
        )

        await store.applyRuntimeShellState(initialState, correlationId: "initial")

        let nextState = ShellCwdState(
            version: 1,
            shells: [
                "200": ShellEntry(
                    cwd: "/tmp/new",
                    tty: "/dev/ttys006",
                    parentApp: "Ghostty",
                    tmuxSession: "next",
                    tmuxClientTty: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
                ),
            ],
        )

        await store.applyRuntimeShellState(nextState, correlationId: "next")

        XCTAssertNil(store.state?.shells["100"])
        XCTAssertEqual(store.state?.shells["200"]?.cwd, "/tmp/new")
        XCTAssertEqual(store.state?.shells.count, 1)
    }
}
