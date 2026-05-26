import Foundation

@MainActor
final class TerminalActivationCoordinator {
    typealias ResolveSessionName = (Project) async -> String
    typealias RunResolvedActivation = (String, String) async -> Bool
    typealias CurrentFailureReason = () -> TerminalActivationFailureReason?

    var onActivationResult: ((TerminalActivationResult) -> Void)?

    private let resolveSessionName: ResolveSessionName
    private let runResolvedActivation: RunResolvedActivation
    private let currentFailureReason: CurrentFailureReason

    private var latestLaunchRequestID: UInt64 = 0
    private var launchTask: _Concurrency.Task<Void, Never>?

    init(
        resolveSessionName: @escaping ResolveSessionName,
        runResolvedActivation: @escaping RunResolvedActivation,
        currentFailureReason: @escaping CurrentFailureReason,
    ) {
        self.resolveSessionName = resolveSessionName
        self.runResolvedActivation = runResolvedActivation
        self.currentFailureReason = currentFailureReason
    }

    enum TerminalFocusResult: Equatable {
        case focused
        case alreadySelected
        case relaunchNeeded
        case failed(TerminalActivationFailureReason?)

        static func focusedIf(_ condition: Bool) -> Self {
            condition ? .focused : .relaunchNeeded
        }
    }

    static func runActivationFlow(
        sessionName: String,
        projectPath: String,
        resolveAnyClientTty: () async -> String?,
        ensureAndSwitch: (String, String, String, String?) async -> Bool,
        launchTerminalWithTmux: (String, String) async -> Bool,
        activateTerminal: (String?, String, String?) async -> TerminalFocusResult,
        resolveTargetPane: ((String?) async -> String?)? = nil,
        pollForNewClient: (() async -> String?)? = nil,
    ) async -> Bool {
        // Try to focus an existing terminal by content (CWD, title) before
        // resolving tmux clients. This handles non-tmux terminals that are
        // already open for the project.
        let directFocus = await activateTerminal(nil, projectPath, nil)
        TerminalActivationTrace.log(
            surface: .activationFlow,
            route: "direct_focus",
            projectPath: projectPath,
            sessionName: sessionName,
            evidence: ["ghostty_snapshot", "working_directory_or_title"],
            action: "focus_existing",
            outcome: directFocus.traceOutcome,
            reason: directFocus.traceFailureReason,
        )
        if directFocus == .focused {
            return true
        }

        let clientTty = await resolveAnyClientTty()
        TerminalActivationTrace.log(
            surface: .activationFlow,
            route: "tmux_client",
            projectPath: projectPath,
            sessionName: sessionName,
            evidence: clientTty == nil ? ["tmux_client_absent"] : ["tmux_client_present"],
            action: "resolve_client",
            outcome: clientTty == nil ? "none" : "resolved",
            reason: clientTty,
        )

        guard let clientTty else {
            if directFocus == .alreadySelected {
                TerminalActivationTrace.log(
                    surface: .activationFlow,
                    route: "direct_focus",
                    projectPath: projectPath,
                    sessionName: sessionName,
                    evidence: ["already_selected", "no_tmux_client"],
                    action: "accept_existing",
                    outcome: "focused",
                )
                return true
            }
            debugLog("runActivationFlow noClient, launching attach-or-create session=\(sessionName)")
            let launched = await launchTerminalWithTmux(sessionName, projectPath)
            TerminalActivationTrace.log(
                surface: .activationFlow,
                route: "launch",
                projectPath: projectPath,
                sessionName: sessionName,
                evidence: ["no_existing_terminal", "no_tmux_client"],
                action: "launch_tmux_attach",
                outcome: launched ? "launched" : "failed",
            )
            guard launched else {
                return false
            }
            if let poll = pollForNewClient {
                _ = await poll()
            }
            return true
        }

        let targetPane = await resolveTargetPane?(clientTty)
        let switched = await ensureAndSwitch(sessionName, projectPath, clientTty, targetPane)
        TerminalActivationTrace.log(
            surface: .activationFlow,
            route: "tmux_switch",
            projectPath: projectPath,
            sessionName: sessionName,
            evidence: ["client_tty:\(clientTty)", targetPane.map { "target_pane:\($0)" } ?? "target_pane:none"],
            action: "ensure_and_switch",
            outcome: switched ? "switched" : "failed",
        )
        guard switched else {
            debugLog("runActivationFlow ensureAndSwitch failed session=\(sessionName)")
            return false
        }

        let focusResult = await activateTerminal(clientTty, projectPath, sessionName)
        TerminalActivationTrace.log(
            surface: .activationFlow,
            route: "post_switch_focus",
            projectPath: projectPath,
            sessionName: sessionName,
            evidence: ["client_tty:\(clientTty)", "session_hint"],
            action: "focus_switched_terminal",
            outcome: focusResult.traceOutcome,
            reason: focusResult.traceFailureReason,
        )
        switch focusResult {
        case .focused, .alreadySelected:
            return true
        case .relaunchNeeded:
            debugLog("runActivationFlow terminal gone for tty=\(clientTty), relaunching")
            let launched = await launchTerminalWithTmux(sessionName, projectPath)
            TerminalActivationTrace.log(
                surface: .activationFlow,
                route: "launch",
                projectPath: projectPath,
                sessionName: sessionName,
                evidence: ["tmux_client_without_visible_terminal"],
                action: "launch_tmux_attach",
                outcome: launched ? "launched" : "failed",
            )
            guard launched else {
                return false
            }
            if let poll = pollForNewClient {
                _ = await poll()
            }
            return true
        case .failed:
            return false
        }
    }

    func launchTerminal(for project: Project) {
        latestLaunchRequestID &+= 1
        let requestID = latestLaunchRequestID
        launchTask?.cancel()
        launchTask = _Concurrency.Task { [weak self] in
            await self?.launchTerminalAsync(for: project, requestID: requestID)
        }
    }

    private func launchTerminalAsync(for project: Project, requestID: UInt64) async {
        guard shouldProcessLaunchRequest(requestID) else {
            debugLog("launchTerminalAsync ignored stale request id=\(requestID) path=\(project.path)")
            return
        }

        let sessionName = await resolveSessionName(project)

        guard shouldProcessLaunchRequest(requestID) else {
            debugLog("launchTerminalAsync ignored stale request id=\(requestID) path=\(project.path)")
            return
        }

        let success = await runResolvedActivation(sessionName, project.path)

        guard shouldProcessLaunchRequest(requestID) else {
            debugLog("launchTerminalAsync ignored stale request id=\(requestID) path=\(project.path)")
            return
        }

        Telemetry.emit("activation_outcome", "unified_v2", payload: [
            "project": project.name,
            "path": project.path,
            "session": sessionName,
            "success": success,
        ])
        onActivationResult?(TerminalActivationResult(
            projectName: project.name,
            projectPath: project.path,
            success: success,
            usedFallback: false,
            failureReason: success ? nil : currentFailureReason(),
        ))
    }

    private func shouldProcessLaunchRequest(_ requestID: UInt64) -> Bool {
        requestID == latestLaunchRequestID && !_Concurrency.Task.isCancelled
    }
}
