@testable import Capacitor
import XCTest

@MainActor
final class TmuxRouterTests: XCTestCase {
    private enum Constants {
        static let displayCurrentClientCommand = "tmux display-message -p '#{client_tty}' 2>/dev/null"
        static let listClientsWithSessionCommand =
            "tmux list-clients -F '#{client_tty} #{session_name}' 2>/dev/null"
        static let listClientsCommand = "tmux list-clients -F '#{client_tty}' 2>/dev/null"
    }

    func testResolveClientTtyReturnsCurrentClientWhenMatchesPreferred() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                switch command {
                case Constants.displayCurrentClientCommand:
                    return (0, "/dev/ttys001\n")
                default:
                    XCTFail("Unexpected command: \(command)")
                    return (1, nil)
                }
            },
        ).resolveAnyClientTty(preferredHostTty: "/dev/ttys001")

        XCTAssertEqual(tty, "/dev/ttys001")
        XCTAssertEqual(commands, [Constants.displayCurrentClientCommand])
    }

    func testResolveClientTtyFallsToListWhenCurrentDoesNotMatchPreferred() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                switch command {
                case Constants.displayCurrentClientCommand:
                    return (0, "/dev/ttys001\n")
                case Constants.listClientsWithSessionCommand:
                    return (0, """
                    /dev/ttys099 caps
                    /dev/ttys002 other
                    """)
                default:
                    XCTFail("Unexpected command: \(command)")
                    return (1, nil)
                }
            },
        ).resolveAnyClientTty(preferredHostTty: "/dev/ttys099")

        XCTAssertEqual(tty, "/dev/ttys099")
        XCTAssertEqual(
            commands,
            [
                Constants.displayCurrentClientCommand,
                Constants.listClientsWithSessionCommand,
            ],
        )
    }

    func testResolveClientTtyMatchesByTargetSession() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                switch command {
                case Constants.displayCurrentClientCommand:
                    return (0, "/dev/ttys001\n")
                case Constants.listClientsWithSessionCommand:
                    return (0, """
                    /dev/ttys050 target-session
                    /dev/ttys002 other
                    """)
                default:
                    XCTFail("Unexpected command: \(command)")
                    return (1, nil)
                }
            },
        ).resolveAnyClientTty(targetSession: "target-session")

        XCTAssertEqual(tty, "/dev/ttys050")
        XCTAssertEqual(
            commands,
            [
                Constants.displayCurrentClientCommand,
                Constants.listClientsWithSessionCommand,
            ],
        )
    }

    func testResolveClientTtyReturnsFirstWhenNoHints() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                switch command {
                case Constants.displayCurrentClientCommand:
                    return (1, nil)
                case Constants.listClientsWithSessionCommand:
                    return (0, """
                    /dev/ttys010 alpha
                    /dev/ttys011 beta
                    """)
                default:
                    XCTFail("Unexpected command: \(command)")
                    return (1, nil)
                }
            },
        ).resolveAnyClientTty()

        XCTAssertEqual(tty, "/dev/ttys010")
        XCTAssertEqual(
            commands,
            [
                Constants.displayCurrentClientCommand,
                Constants.listClientsWithSessionCommand,
            ],
        )
    }

    func testResolveClientTtyReturnsNilWhenHintsProvidedButNoMatch() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                switch command {
                case Constants.displayCurrentClientCommand:
                    return (1, nil)
                case Constants.listClientsWithSessionCommand:
                    return (0, """
                    /dev/ttys001 alpha
                    /dev/ttys002 beta
                    """)
                default:
                    XCTFail("Unexpected command: \(command)")
                    return (1, nil)
                }
            },
        ).resolveAnyClientTty(
            preferredHostTty: "/dev/ttys099",
            targetSession: "target-session",
        )

        XCTAssertNil(tty)
        XCTAssertEqual(
            commands,
            [
                Constants.displayCurrentClientCommand,
                Constants.listClientsWithSessionCommand,
            ],
        )
    }

    func testResolveClientTtyPrefersHostTtyOverSessionMatch() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                switch command {
                case Constants.displayCurrentClientCommand:
                    return (1, nil)
                case Constants.listClientsWithSessionCommand:
                    return (0, """
                    /dev/ttys040 unrelated
                    /dev/ttys050 target-session
                    """)
                default:
                    XCTFail("Unexpected command: \(command)")
                    return (1, nil)
                }
            },
        ).resolveAnyClientTty(
            preferredHostTty: "/dev/ttys040",
            targetSession: "target-session",
        )

        XCTAssertEqual(tty, "/dev/ttys040")
        XCTAssertEqual(
            commands,
            [
                Constants.displayCurrentClientCommand,
                Constants.listClientsWithSessionCommand,
            ],
        )
    }

    func testResolveClientTtyIgnoresWhitespaceOnlyHints() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                switch command {
                case Constants.displayCurrentClientCommand:
                    return (1, nil)
                case Constants.listClientsWithSessionCommand:
                    return (0, """
                    /dev/ttys020 alpha
                    /dev/ttys021 beta
                    """)
                default:
                    XCTFail("Unexpected command: \(command)")
                    return (1, nil)
                }
            },
        ).resolveAnyClientTty(
            preferredHostTty: " \n\t ",
            targetSession: "   ",
        )

        XCTAssertEqual(tty, "/dev/ttys020")
        XCTAssertEqual(
            commands,
            [
                Constants.displayCurrentClientCommand,
                Constants.listClientsWithSessionCommand,
            ],
        )
    }

    func testResolveClientTtyReturnsNilWhenListClientsFails() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                switch command {
                case Constants.displayCurrentClientCommand:
                    return (1, nil)
                case Constants.listClientsWithSessionCommand:
                    return (1, "tmux unavailable")
                default:
                    XCTFail("Unexpected command: \(command)")
                    return (1, nil)
                }
            },
        ).resolveAnyClientTty()

        XCTAssertNil(tty)
        XCTAssertEqual(
            commands,
            [
                Constants.displayCurrentClientCommand,
                Constants.listClientsWithSessionCommand,
            ],
        )
    }

    func testResolveClientTtyReturnsCurrentClientWhenNoHintsNeeded() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                switch command {
                case Constants.displayCurrentClientCommand:
                    return (0, "/dev/ttys777\n")
                default:
                    XCTFail("Unexpected command: \(command)")
                    return (1, nil)
                }
            },
        ).resolveAnyClientTty()

        XCTAssertEqual(tty, "/dev/ttys777")
        XCTAssertEqual(commands, [Constants.displayCurrentClientCommand])
    }

    func testEnsureAndSwitchSelectsPaneWhenProvided() async {
        var commands: [String] = []

        let ok = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                return (0, nil)
            },
        ).ensureSessionAndSwitch(
            sessionName: "my-session",
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: "/dev/ttys001",
            targetPane: "%12",
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(
            commands,
            [
                "tmux switch-client -c '/dev/ttys001' -t 'my-session' 2>&1",
                "tmux select-window -t '%12' 2>&1",
                "tmux select-pane -t '%12' 2>&1",
            ],
        )
    }

    func testEnsureAndSwitchReturnsSuccessWhenPaneSelectionFails() async {
        var commands: [String] = []

        let ok = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                if command == "tmux select-window -t '%12' 2>&1" {
                    return (1, "stale pane")
                }
                return (0, nil)
            },
        ).ensureSessionAndSwitch(
            sessionName: "my-session",
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: "/dev/ttys001",
            targetPane: "%12",
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(
            commands,
            [
                "tmux switch-client -c '/dev/ttys001' -t 'my-session' 2>&1",
                "tmux select-window -t '%12' 2>&1",
            ],
        )
    }

    func testEnsureAndSwitchIgnoresEmptyTargetPane() async {
        var commands: [String] = []

        let ok = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                return (0, nil)
            },
        ).ensureSessionAndSwitch(
            sessionName: "my-session",
            projectPath: "/Users/pete/Code/capacitor",
            clientTty: "/dev/ttys001",
            targetPane: "  \n\t  ",
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(commands, ["tmux switch-client -c '/dev/ttys001' -t 'my-session' 2>&1"])
    }

    func testPollForNewClientReturnsOnFirstSuccess() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                XCTAssertEqual(command, Constants.listClientsCommand)
                return (0, """
                /dev/ttys300
                /dev/ttys301
                """)
            },
        ).pollForNewClient(intervalNanoseconds: 1000)

        XCTAssertEqual(tty, "/dev/ttys300")
        XCTAssertEqual(commands, [Constants.listClientsCommand])
    }

    func testPollForNewClientReturnsAfterRetries() async {
        var commands: [String] = []
        var results: [TmuxRouter.CommandResult] = [
            (1, nil),
            (0, " \n"),
            (0, """
            /dev/ttys450
            /dev/ttys451
            """),
        ]

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                XCTAssertEqual(command, Constants.listClientsCommand)
                return results.removeFirst()
            },
        ).pollForNewClient(
            maxAttempts: 5,
            intervalNanoseconds: 1000,
        )

        XCTAssertEqual(tty, "/dev/ttys450")
        XCTAssertEqual(commands, Array(repeating: Constants.listClientsCommand, count: 3))
    }

    func testPollForNewClientReturnsNilOnTimeout() async {
        var commands: [String] = []

        let tty = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                XCTAssertEqual(command, Constants.listClientsCommand)
                return (0, " \n")
            },
        ).pollForNewClient(
            maxAttempts: 3,
            intervalNanoseconds: 1000,
        )

        XCTAssertNil(tty)
        XCTAssertEqual(commands, Array(repeating: Constants.listClientsCommand, count: 3))
    }

    func testKillSessionSendsCorrectCommand() async {
        var commands: [String] = []

        let killed = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                return (0, nil)
            },
        ).killSession(sessionName: "my-session")

        XCTAssertTrue(killed)
        XCTAssertEqual(commands, ["tmux kill-session -t 'my-session' 2>&1"])
    }

    func testKillSessionReturnsFalseOnFailure() async {
        var commands: [String] = []

        let killed = await TmuxRouter(
            runScript: { command in
                commands.append(command)
                return (1, "no such session")
            },
        ).killSession(sessionName: "my-session")

        XCTAssertFalse(killed)
        XCTAssertEqual(commands, ["tmux kill-session -t 'my-session' 2>&1"])
    }
}
