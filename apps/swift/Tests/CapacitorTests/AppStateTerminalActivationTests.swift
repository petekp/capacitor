@testable import Capacitor
import XCTest

@MainActor
final class AppStateTerminalActivationTests: XCTestCase {
    func testActivationIntentUsesOnDemandRuntimeRouteWhenCachedRouteMissing() async throws {
        var requestedPaths: [String] = []
        let runtimeClient = try RuntimeClient(
            isEnabledOverride: true,
            runtimeServiceConnectionOverride: RuntimeServiceConnection(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:7812")),
                bearerToken: "service-secret",
            ),
            sendRequest: { request in
                requestedPaths.append(request.url?.path ?? "unknown")
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"],
                    ),
                )
                switch request.url?.path {
                case "/runtime/routing/resolve":
                    let json = """
                    {"workspace_id":"workspace-capacitor","project_path":"/Users/pete/Code/capacitor","status":"attached","target":{"kind":"tmux_session","terminal_app":"iterm2","session_name":"caps","pane_id":null,"host_tty":"/dev/ttys002"},"reason_code":"TMUX_SESSION_ATTACHED","reason":"Matched tmux session 'caps'","updated_at":"2026-03-15T05:40:01Z"}
                    """
                    return (Data(json.utf8), response)
                case "/runtime/snapshot":
                    let json = """
                    {"projects":[],"sessions":[],"shells":[],"routing":[],"diagnostics":{"events_ingested":0,"sessions_tracked":0,"shell_signals_tracked":0,"events_skipped":0,"stale_events_skipped":0,"informational_events_skipped":0,"reducer_events_skipped":0,"last_error":null},"generated_at":"2026-03-15T05:40:01Z"}
                    """
                    return (Data(json.utf8), response)
                case "/health":
                    let json = """
                    {"status":"ok","pid":4242,"version":"runtime-service-v1","protocol_version":1,"auth_mode":"bearer","service_mode":"bootstrap_only"}
                    """
                    return (Data(json.utf8), response)
                default:
                    return (Data(), response)
                }
            },
        )

        let appState = AppState(runtimeClient: runtimeClient)
        appState.cancelRuntimeAutomationForTesting()
        appState.shellStateStore.applyRuntimeShellState(
            ShellCwdState(
                version: 1,
                shells: [
                    "100": ShellEntry(
                        cwd: "/Users/pete/Code/capacitor",
                        tty: "/dev/ttys010",
                        parentApp: "Ghostty",
                        tmuxSession: "caps",
                        tmuxClientTty: "/dev/ttys002",
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    ),
                ],
            ),
        )

        let resolver = try XCTUnwrap(appState.terminalLauncher.activationIntentResolver)
        let intent = await resolver("/dev/ttys002", "/Users/pete/Code/capacitor", "caps")

        XCTAssertEqual(intent.terminalApp.app, .iTerm)
        XCTAssertEqual(intent.terminalApp.source, .runtimeRoute)
        XCTAssertEqual(intent.sessionName, "caps")
        XCTAssertNil(intent.paneId)
        XCTAssertEqual(intent.hostTty, "/dev/ttys002")
        XCTAssertEqual(requestedPaths, ["/runtime/routing/resolve"])
    }

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
