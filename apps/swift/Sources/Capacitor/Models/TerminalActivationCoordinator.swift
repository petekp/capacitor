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
        resolveTargetPane: ((String?) -> String?)? = nil,
        pollForNewClient: (() async -> String?)? = nil,
    ) async -> Bool {
        let clientTty = await resolveAnyClientTty()

        guard let clientTty else {
            debugLog("runActivationFlow noClient, launching attach-or-create session=\(sessionName)")
            guard await launchTerminalWithTmux(sessionName, projectPath) else {
                return false
            }
            if let poll = pollForNewClient {
                _ = await poll()
            }
            return true
        }

        let targetPane = resolveTargetPane?(clientTty)
        let switched = await ensureAndSwitch(sessionName, projectPath, clientTty, targetPane)
        guard switched else {
            debugLog("runActivationFlow ensureAndSwitch failed session=\(sessionName)")
            return false
        }

        let focusResult = await activateTerminal(clientTty, projectPath, sessionName)
        switch focusResult {
        case .focused:
            return true
        case .relaunchNeeded:
            debugLog("runActivationFlow terminal gone for tty=\(clientTty), relaunching")
            guard await launchTerminalWithTmux(sessionName, projectPath) else {
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
