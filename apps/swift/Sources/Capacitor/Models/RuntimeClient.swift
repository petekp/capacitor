import Foundation

struct RuntimeHealth: Decodable {
    let status: String
    let pid: Int
    let version: String
    let protocolVersion: Int
    let security: RuntimeSecurityHealth?
    let runtime: RuntimeEngineHealth?
    let routing: RuntimeRoutingHealth?

    init(
        status: String,
        pid: Int,
        version: String,
        protocolVersion: Int,
        security: RuntimeSecurityHealth? = nil,
        runtime: RuntimeEngineHealth? = nil,
        routing: RuntimeRoutingHealth? = nil,
    ) {
        self.status = status
        self.pid = pid
        self.version = version
        self.protocolVersion = protocolVersion
        self.security = security
        self.runtime = runtime
        self.routing = routing
    }

    enum CodingKeys: String, CodingKey {
        case status, pid, version, security, runtime, routing
        case protocolVersion = "protocol_version"
    }
}

struct RuntimeSecurityHealth: Decodable {
    let peerAuthMode: String
    let rejectedConnections: UInt64

    enum CodingKeys: String, CodingKey {
        case peerAuthMode = "peer_auth_mode"
        case rejectedConnections = "rejected_connections"
    }
}

struct RuntimeEngineHealth: Decodable {
    let activeConnections: UInt64
    let maxActiveConnections: UInt64
    let buildHash: String

    enum CodingKeys: String, CodingKey {
        case activeConnections = "active_connections"
        case maxActiveConnections = "max_active_connections"
        case buildHash = "build_hash"
    }
}

struct RuntimeRoutingHealth: Decodable {
    let enabled: Bool
    let rollout: RuntimeRoutingRollout?

    enum CodingKeys: String, CodingKey {
        case enabled
        case rollout
    }
}

struct RuntimeRoutingRollout: Decodable {
    let agreementGateTarget: Double
    let minComparisonsRequired: UInt64?
    let minWindowHoursRequired: UInt64?
    let comparisons: UInt64
    let volumeGateMet: Bool?
    let windowGateMet: Bool?
    let statusAgreementRate: Double?
    let targetAgreementRate: Double?
    let firstComparisonAt: String?
    let lastComparisonAt: String?
    let windowElapsedHours: UInt64?
    let statusGateMet: Bool
    let targetGateMet: Bool
    let statusRowDefaultReady: Bool
    let launcherDefaultReady: Bool

    enum CodingKeys: String, CodingKey {
        case agreementGateTarget = "agreement_gate_target"
        case minComparisonsRequired = "min_comparisons_required"
        case minWindowHoursRequired = "min_window_hours_required"
        case comparisons
        case volumeGateMet = "volume_gate_met"
        case windowGateMet = "window_gate_met"
        case statusAgreementRate = "status_agreement_rate"
        case targetAgreementRate = "target_agreement_rate"
        case firstComparisonAt = "first_comparison_at"
        case lastComparisonAt = "last_comparison_at"
        case windowElapsedHours = "window_elapsed_hours"
        case statusGateMet = "status_gate_met"
        case targetGateMet = "target_gate_met"
        case statusRowDefaultReady = "status_row_default_ready"
        case launcherDefaultReady = "launcher_default_ready"
    }
}

struct RuntimeSession: Decodable {
    let sessionId: String
    let pid: UInt32
    let state: String
    let cwd: String
    let projectId: String?
    let workspaceId: String?
    let projectPath: String
    let updatedAt: String
    let stateChangedAt: String
    let lastEvent: String?
    let lastActivityAt: String?
    let toolsInFlight: Int?
    let readyReason: String?
    let isAlive: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case pid
        case state
        case cwd
        case projectId = "project_id"
        case workspaceId = "workspace_id"
        case projectPath = "project_path"
        case updatedAt = "updated_at"
        case stateChangedAt = "state_changed_at"
        case lastEvent = "last_event"
        case lastActivityAt = "last_activity_at"
        case toolsInFlight = "tools_in_flight"
        case readyReason = "ready_reason"
        case isAlive = "is_alive"
    }
}

struct RuntimeProjectState: Decodable {
    let projectId: String?
    let workspaceId: String?
    let projectPath: String
    let state: String
    let updatedAt: String
    let stateChangedAt: String
    let sessionId: String?
    let latestSessionId: String?
    let sessionCount: Int
    let activeCount: Int
    let hasSession: Bool

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case workspaceId = "workspace_id"
        case projectPath = "project_path"
        case state
        case updatedAt = "updated_at"
        case stateChangedAt = "state_changed_at"
        case sessionId = "session_id"
        case latestSessionId = "latest_session_id"
        case sessionCount = "session_count"
        case activeCount = "active_count"
        case hasSession = "has_session"
    }
}

struct RuntimeSnapshot {
    let projectStates: [RuntimeProjectState]
    let sessions: [RuntimeSession]
    let shellState: ShellCwdState
    let routingViews: [RuntimeRoutingView]
}

struct CoreRoutingTarget: Decodable, Equatable {
    let kind: String
    let terminalApp: String?
    let sessionName: String?
    let paneId: String?
    let hostTty: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case terminalApp = "terminal_app"
        case sessionName = "session_name"
        case paneId = "pane_id"
        case hostTty = "host_tty"
    }

    init(
        kind: String,
        terminalApp: String? = nil,
        sessionName: String? = nil,
        paneId: String? = nil,
        hostTty: String? = nil,
    ) {
        self.kind = kind
        self.terminalApp = terminalApp
        self.sessionName = sessionName
        self.paneId = paneId
        self.hostTty = hostTty
    }
}

struct CoreRoutingEvidence: Equatable {
    let evidenceType: String
    let value: String
    let ageMs: UInt64
    let trustRank: UInt8
}

struct CoreRoutingSnapshot: Equatable {
    let version: Int
    let workspaceId: String
    let projectPath: String
    let status: String
    let target: CoreRoutingTarget
    let confidence: String
    let reasonCode: String
    let reason: String
    let evidence: [CoreRoutingEvidence]
    let updatedAt: String
}

struct RuntimeServiceConnection: Equatable {
    let baseURL: URL
    let bearerToken: String

    private enum Constants {
        static let portEnv = "CAPACITOR_RUNTIME_SERVICE_PORT"
        static let tokenEnv = "CAPACITOR_RUNTIME_SERVICE_TOKEN"
        static let connectionRelativePath = ".capacitor/runtime/runtime-service.json"
    }

    private struct ConnectionRecord: Decodable {
        let port: UInt16
        let authToken: String

        enum CodingKeys: String, CodingKey {
            case port
            case authToken = "auth_token"
        }
    }

    static func current(
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo,
    ) -> RuntimeServiceConnection? {
        if let port = processInfo.environment[Constants.portEnv]
            .flatMap({ UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
            let token = processInfo.environment[Constants.tokenEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        {
            return RuntimeServiceConnection(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                bearerToken: token,
            )
        }

        let connectionURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(Constants.connectionRelativePath)
        guard let data = try? Data(contentsOf: connectionURL),
              let record = try? JSONDecoder().decode(ConnectionRecord.self, from: data)
        else {
            return nil
        }

        return RuntimeServiceConnection(
            baseURL: URL(string: "http://127.0.0.1:\(record.port)")!,
            bearerToken: record.authToken,
        )
    }
}

private struct SnapshotPayload: Decodable {
    let projects: [SnapshotProjectPayload]
    let sessions: [SnapshotSessionPayload]
    let shells: [SnapshotShellPayload]
    let routing: [SnapshotRoutingPayload]

    init(_ snapshot: AppSnapshot) {
        projects = snapshot.projects.map(SnapshotProjectPayload.init)
        sessions = snapshot.sessions.map(SnapshotSessionPayload.init)
        shells = snapshot.shells.map(SnapshotShellPayload.init)
        routing = snapshot.routing.map(SnapshotRoutingPayload.init)
    }
}

private struct SnapshotProjectPayload: Decodable {
    let projectId: String?
    let workspaceId: String?
    let projectPath: String
    let state: String
    let updatedAt: String
    let stateChangedAt: String
    let representativeSessionId: String?
    let latestSessionId: String?
    let sessionCount: UInt64
    let activeCount: UInt64
    let hasSession: Bool

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case workspaceId = "workspace_id"
        case projectPath = "project_path"
        case state
        case updatedAt = "updated_at"
        case stateChangedAt = "state_changed_at"
        case representativeSessionId = "representative_session_id"
        case latestSessionId = "latest_session_id"
        case sessionCount = "session_count"
        case activeCount = "active_count"
        case hasSession = "has_session"
    }

    init(_ project: ProjectSummary) {
        projectId = project.projectId
        workspaceId = project.workspaceId
        projectPath = project.projectPath
        state = RuntimeClient.snapshotSessionStateString(project.state)
        updatedAt = project.updatedAt
        stateChangedAt = project.stateChangedAt
        representativeSessionId = project.representativeSessionId
        latestSessionId = project.latestSessionId
        sessionCount = project.sessionCount
        activeCount = project.activeCount
        hasSession = project.hasSession
    }
}

private struct SnapshotSessionPayload: Decodable {
    let sessionId: String
    let pid: UInt32
    let cwd: String
    let projectId: String
    let projectPath: String
    let workspaceId: String
    let state: String
    let stateChangedAt: String
    let updatedAt: String
    let lastEvent: String?
    let lastActivityAt: String?
    let toolsInFlight: UInt32
    let readyReason: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case pid
        case cwd
        case projectId = "project_id"
        case projectPath = "project_path"
        case workspaceId = "workspace_id"
        case state
        case stateChangedAt = "state_changed_at"
        case updatedAt = "updated_at"
        case lastEvent = "last_event"
        case lastActivityAt = "last_activity_at"
        case toolsInFlight = "tools_in_flight"
        case readyReason = "ready_reason"
    }

    init(_ session: SessionSummary) {
        sessionId = session.sessionId
        pid = session.pid
        cwd = session.cwd
        projectId = session.projectId
        projectPath = session.projectPath
        workspaceId = session.workspaceId
        state = RuntimeClient.snapshotSessionStateString(session.state)
        stateChangedAt = session.stateChangedAt
        updatedAt = session.updatedAt
        lastEvent = session.lastEvent
        lastActivityAt = session.lastActivityAt
        toolsInFlight = session.toolsInFlight
        readyReason = session.readyReason
    }
}

private struct SnapshotShellPayload: Decodable {
    let pid: UInt32
    let cwd: String
    let tty: String
    let parentApp: String
    let tmuxSession: String?
    let tmuxClientTty: String?
    let tmuxPane: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case pid
        case cwd
        case tty
        case parentApp = "parent_app"
        case tmuxSession = "tmux_session"
        case tmuxClientTty = "tmux_client_tty"
        case tmuxPane = "tmux_pane"
        case updatedAt = "updated_at"
    }

    init(_ shell: ShellSignal) {
        pid = shell.pid
        cwd = shell.cwd
        tty = shell.tty
        parentApp = shell.parentApp
        tmuxSession = shell.tmuxSession
        tmuxClientTty = shell.tmuxClientTty
        tmuxPane = shell.tmuxPane
        updatedAt = shell.updatedAt
    }
}

private struct SnapshotRoutingPayload: Decodable {
    let workspaceId: String
    let projectPath: String
    let status: String
    let target: CoreRoutingTarget
    let reasonCode: String
    let reason: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case projectPath = "project_path"
        case status
        case target
        case reasonCode = "reason_code"
        case reason
        case updatedAt = "updated_at"
    }

    init(_ route: RoutingView) {
        workspaceId = route.workspaceId
        projectPath = route.projectPath
        status = RuntimeClient.snapshotRoutingStatusString(route.status)
        target = CoreRoutingTarget(route.target)
        reasonCode = route.reasonCode
        reason = route.reason
        updatedAt = route.updatedAt
    }
}

enum RuntimeClientError: Error {
    case disabled
    case invalidResponse
    case timeout
    case runtimeUnavailable(String)
}

final class RuntimeClient {
    static let shared = RuntimeClient()

    private enum Constants {
        static let enabledEnv = "CAPACITOR_RUNTIME_ENABLED"
        static let tmuxSignalFreshMs: UInt64 = 5000
        static let shellSignalFreshMs: UInt64 = 600_000
        static let shellRetentionHours: UInt64 = 24
        static let tmuxPollIntervalMs: UInt64 = 1000
    }

    private let isEnabledOverride: Bool?
    private let runtimeServiceConnectionOverride: RuntimeServiceConnection?
    private let loadRuntimeServiceConnection: () -> RuntimeServiceConnection?
    private let sendRequest: (URLRequest) async throws -> (Data, URLResponse)

    init(
        isEnabledOverride: Bool? = nil,
        runtimeServiceConnectionOverride: RuntimeServiceConnection? = nil,
        loadRuntimeServiceConnection: @escaping () -> RuntimeServiceConnection? = { RuntimeServiceConnection.current() },
        sendRequest: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        },
    ) {
        self.isEnabledOverride = isEnabledOverride
        self.runtimeServiceConnectionOverride = runtimeServiceConnectionOverride
        self.loadRuntimeServiceConnection = loadRuntimeServiceConnection
        self.sendRequest = sendRequest
    }

    private init() {
        isEnabledOverride = nil
        runtimeServiceConnectionOverride = nil
        loadRuntimeServiceConnection = { RuntimeServiceConnection.current() }
        sendRequest = { request in
            try await URLSession.shared.data(for: request)
        }
    }

    var isEnabled: Bool {
        if let isEnabledOverride {
            return isEnabledOverride
        }
        guard let raw = getenv(Constants.enabledEnv) else {
            return true
        }
        let value = String(cString: raw)
        return ["1", "true", "TRUE", "yes", "YES"].contains(value)
    }

    func fetchHealth() async throws -> RuntimeHealth {
        try await fetchServiceHealth()
    }

    func fetchShellState() async throws -> ShellCwdState {
        let snapshot = try await requireSnapshot(operation: "fetchShellState")
        guard let shellState = mapShellState(snapshot, operation: "fetchShellState") else {
            throw RuntimeClientError.invalidResponse
        }
        DebugLog.write("RuntimeClient.fetchShellState source=\(runtimeSourceLabel) shells=\(shellState.shells.count)")
        return shellState
    }

    func fetchSessions() async throws -> [RuntimeSession] {
        let snapshot = try await requireSnapshot(operation: "fetchSessions")
        let sessions = mapSessions(snapshot)
        DebugLog.write("RuntimeClient.fetchSessions source=\(runtimeSourceLabel) count=\(sessions.count)")
        return sessions
    }

    func fetchProjectStates(correlationId: String? = nil) async throws -> [RuntimeProjectState] {
        let snapshot = try await requireSnapshot(correlationId: correlationId, operation: "fetchProjectStates")
        let states = mapProjectStates(snapshot)
        let cid = correlationId ?? "none"
        DebugLog.write("RuntimeClient.fetchProjectStates source=\(runtimeSourceLabel) cid=\(cid) count=\(states.count)")
        return states
    }

    func fetchRuntimeSnapshot(correlationId: String? = nil) async throws -> RuntimeSnapshot {
        let snapshot = try await requireSnapshot(correlationId: correlationId, operation: "fetchRuntimeSnapshot")
        let projectStates = mapProjectStates(snapshot)
        let sessions = mapSessions(snapshot)
        guard let shellState = mapShellState(
            snapshot,
            correlationId: correlationId,
            operation: "fetchRuntimeSnapshot",
        ) else {
            throw RuntimeClientError.invalidResponse
        }

        let cid = correlationId ?? "none"
        DebugLog.write(
            "RuntimeClient.fetchRuntimeSnapshot source=\(runtimeSourceLabel) cid=\(cid) projects=\(projectStates.count) sessions=\(sessions.count) shells=\(shellState.shells.count)",
        )

        return RuntimeSnapshot(
            projectStates: projectStates,
            sessions: sessions,
            shellState: shellState,
            routingViews: mapRoutingViews(snapshot),
        )
    }

    func fetchCoreRoutingSnapshot(projectPath: String, workspaceId: String?) async throws -> CoreRoutingSnapshot {
        let snapshot = try await requireSnapshot(operation: "fetchRoutingSnapshot")
        let resolved = resolveRoutingView(
            for: snapshot,
            projectPath: projectPath,
            workspaceId: workspaceId,
        )

        if let route = resolved.route {
            return mapCoreRoutingSnapshot(
                route,
                projectPath: projectPath,
                workspaceId: workspaceId,
                snapshot: snapshot,
            )
        }

        let normalizedPath = PathNormalizer.normalize(projectPath)
        let trimmedWorkspaceId = workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackWorkspaceId = (trimmedWorkspaceId?.isEmpty == false ? trimmedWorkspaceId : nil)
            ?? normalizedPath

        return CoreRoutingSnapshot(
            version: 1,
            workspaceId: fallbackWorkspaceId,
            projectPath: normalizedPath,
            status: "unavailable",
            target: CoreRoutingTarget(kind: "none"),
            confidence: "low",
            reasonCode: "NO_TRUSTED_EVIDENCE",
            reason: "No routing evidence available in runtime service snapshot",
            evidence: [],
            updatedAt: currentISO8601Timestamp(),
        )
    }

    private let runtimeSourceLabel = "runtime_service"

    private func requireSnapshot(
        correlationId: String? = nil,
        operation: String,
    ) async throws -> SnapshotPayload {
        guard isEnabled else {
            throw RuntimeClientError.disabled
        }

        return try await loadRuntimeServiceSnapshot(correlationId: correlationId, operation: operation)
    }

    private func loadRuntimeServiceSnapshot(
        correlationId: String? = nil,
        operation: String,
    ) async throws -> SnapshotPayload {
        let request = try runtimeServiceRequest(path: "/runtime/snapshot")

        do {
            let (data, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw RuntimeClientError.runtimeUnavailable(
                    "Runtime service snapshot request failed for \(request.url?.absoluteString ?? "unknown")",
                )
            }
            return try JSONDecoder().decode(SnapshotPayload.self, from: data)
        } catch let error as RuntimeClientError {
            throw error
        } catch {
            let cid = correlationId ?? "none"
            DebugLog.write(
                "RuntimeClient.\(operation) source=runtime_service_error cid=\(cid) error=\(error)",
            )
            throw RuntimeClientError.runtimeUnavailable(
                "Runtime service snapshot unavailable: \(error.localizedDescription)",
            )
        }
    }

    private func fetchServiceHealth() async throws -> RuntimeHealth {
        let request = try runtimeServiceRequest(path: "/health")

        do {
            let (data, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw RuntimeClientError.runtimeUnavailable(
                    "Runtime service health request failed for \(request.url?.absoluteString ?? "unknown")",
                )
            }
            return try JSONDecoder().decode(RuntimeHealth.self, from: data)
        } catch let error as RuntimeClientError {
            throw error
        } catch {
            throw RuntimeClientError.runtimeUnavailable(
                "Runtime service health unavailable: \(error.localizedDescription)",
            )
        }
    }

    private func runtimeServiceRequest(path: String) throws -> URLRequest {
        guard let connection = runtimeServiceConnectionOverride ?? loadRuntimeServiceConnection() else {
            throw RuntimeClientError.runtimeUnavailable("Runtime service connection unavailable")
        }

        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = connection.baseURL.appendingPathComponent(normalizedPath)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(connection.bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func mapProjectStates(_ snapshot: SnapshotPayload) -> [RuntimeProjectState] {
        snapshot.projects.map { project in
            RuntimeProjectState(
                projectId: project.projectId,
                workspaceId: project.workspaceId,
                projectPath: project.projectPath,
                state: project.state,
                updatedAt: project.updatedAt,
                stateChangedAt: project.stateChangedAt,
                sessionId: project.representativeSessionId,
                latestSessionId: project.latestSessionId,
                sessionCount: Int(project.sessionCount),
                activeCount: Int(project.activeCount),
                hasSession: project.hasSession,
            )
        }
    }

    private func mapSessions(_ snapshot: SnapshotPayload) -> [RuntimeSession] {
        snapshot.sessions.map { session in
            RuntimeSession(
                sessionId: session.sessionId,
                pid: session.pid,
                state: session.state,
                cwd: session.cwd,
                projectId: session.projectId,
                workspaceId: session.workspaceId,
                projectPath: session.projectPath,
                updatedAt: session.updatedAt,
                stateChangedAt: session.stateChangedAt,
                lastEvent: session.lastEvent,
                lastActivityAt: session.lastActivityAt,
                toolsInFlight: Int(session.toolsInFlight),
                readyReason: session.readyReason,
                isAlive: nil,
            )
        }
    }

    private func mapShellState(
        _ snapshot: SnapshotPayload,
        correlationId: String? = nil,
        operation: String,
    ) -> ShellCwdState? {
        var shells: [String: ShellEntry] = [:]
        for signal in snapshot.shells {
            guard let updatedAt = parseISO8601Date(signal.updatedAt) else {
                let cid = correlationId ?? "none"
                DebugLog.write(
                    "RuntimeClient.\(operation) source=\(runtimeSourceLabel)_map_error cid=\(cid) pid=\(signal.pid) invalid_updated_at=\(signal.updatedAt)",
                )
                return nil
            }

            shells[String(signal.pid)] = ShellEntry(
                cwd: signal.cwd,
                tty: signal.tty,
                parentApp: signal.parentApp,
                tmuxSession: signal.tmuxSession,
                tmuxClientTty: signal.tmuxClientTty,
                tmuxPane: signal.tmuxPane,
                updatedAt: updatedAt,
            )
        }

        return ShellCwdState(version: 1, shells: shells)
    }

    private func mapRoutingViews(_ snapshot: SnapshotPayload) -> [RuntimeRoutingView] {
        snapshot.routing.map { route in
            RuntimeRoutingView(
                workspaceId: route.workspaceId,
                projectPath: route.projectPath,
                status: route.status,
                target: route.target,
                reasonCode: normalizeReasonCode(route.reasonCode),
                reason: route.reason,
                updatedAt: route.updatedAt,
            )
        }
    }

    private func resolveRoutingView(
        for snapshot: SnapshotPayload,
        projectPath: String,
        workspaceId: String?,
    ) -> (route: SnapshotRoutingPayload?, scope: String) {
        let trimmedWorkspaceId = workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProjectPath = PathNormalizer.normalize(projectPath)

        if let workspace = trimmedWorkspaceId, !workspace.isEmpty {
            if let route = snapshot.routing.first(where: { $0.workspaceId == workspace }) {
                return (route, "workspace_id")
            }
        }

        if let route = snapshot.routing.first(where: {
            PathNormalizer.normalize($0.projectPath) == normalizedProjectPath
        }) {
            return (route, "project_path")
        }

        return (nil, "none")
    }

    private func mapCoreRoutingSnapshot(
        _ route: SnapshotRoutingPayload,
        projectPath: String,
        workspaceId _: String?,
        snapshot: SnapshotPayload,
    ) -> CoreRoutingSnapshot {
        let normalizedStatus = route.status
        let reasonCode = normalizeReasonCode(route.reasonCode)
        let evidence = tmuxClientEvidence(route: route, snapshot: snapshot)

        let confidence = if normalizedStatus == "attached" {
            "high"
        } else if normalizedStatus == "detached" {
            "medium"
        } else {
            "low"
        }

        return CoreRoutingSnapshot(
            version: 1,
            workspaceId: route.workspaceId,
            projectPath: PathNormalizer.normalize(projectPath),
            status: normalizedStatus,
            target: route.target,
            confidence: confidence,
            reasonCode: reasonCode,
            reason: route.reason,
            evidence: evidence,
            updatedAt: route.updatedAt,
        )
    }

    private func normalizeReasonCode(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "NO_TRUSTED_EVIDENCE"
        }
        return trimmed.uppercased()
    }

    private func tmuxClientEvidence(
        route: SnapshotRoutingPayload,
        snapshot: SnapshotPayload,
    ) -> [CoreRoutingEvidence] {
        guard route.target.kind == "tmux_session" || route.target.kind == "tmux_pane"
        else {
            return []
        }

        func normalizedValue(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else {
                return nil
            }
            return trimmed
        }

        let now = Date()
        let sessionName = normalizedValue(route.target.sessionName)
        let hostTty = normalizedValue(route.target.hostTty)

        guard sessionName != nil || hostTty != nil else {
            return []
        }

        func ageMs(from value: String) -> UInt64 {
            guard let updatedAt = parseISO8601Date(value) else {
                return 0
            }
            let interval = max(0, now.timeIntervalSince(updatedAt))
            return UInt64((interval * 1000).rounded())
        }

        func makeTmuxClientEvidence(
            value: String,
            ageMs: UInt64,
            preferredHostTty: String?,
        ) -> CoreRoutingEvidence {
            let trustRank: UInt8 = if let preferredHostTty {
                preferredHostTty == value ? 0 : 1
            } else {
                0
            }

            return CoreRoutingEvidence(
                evidenceType: "tmux_client",
                value: value,
                ageMs: ageMs,
                trustRank: trustRank,
            )
        }

        func shouldReplace(
            current: CoreRoutingEvidence,
            candidate: CoreRoutingEvidence,
        ) -> Bool {
            if candidate.trustRank != current.trustRank {
                return candidate.trustRank < current.trustRank
            }
            if candidate.ageMs != current.ageMs {
                return candidate.ageMs < current.ageMs
            }
            return candidate.value < current.value
        }

        var evidenceByValue: [String: CoreRoutingEvidence] = [:]

        if let hostTty {
            let routeEvidence = makeTmuxClientEvidence(
                value: hostTty,
                ageMs: ageMs(from: route.updatedAt),
                preferredHostTty: hostTty,
            )
            evidenceByValue[hostTty] = routeEvidence
        }

        if let sessionName {
            for shell in snapshot.shells where shell.tmuxSession == sessionName {
                guard let clientTty = normalizedValue(shell.tmuxClientTty) else {
                    continue
                }

                let candidate = makeTmuxClientEvidence(
                    value: clientTty,
                    ageMs: ageMs(from: shell.updatedAt),
                    preferredHostTty: hostTty,
                )

                if let current = evidenceByValue[clientTty] {
                    if shouldReplace(current: current, candidate: candidate) {
                        evidenceByValue[clientTty] = candidate
                    }
                } else {
                    evidenceByValue[clientTty] = candidate
                }
            }
        }

        return evidenceByValue.values.sorted { left, right in
            if left.trustRank != right.trustRank {
                return left.trustRank < right.trustRank
            }
            if left.ageMs != right.ageMs {
                return left.ageMs < right.ageMs
            }
            return left.value < right.value
        }
    }

    fileprivate static func snapshotSessionStateString(_ state: SessionState) -> String {
        switch state {
        case .working:
            "working"
        case .ready:
            "ready"
        case .idle:
            "idle"
        case .compacting:
            "compacting"
        case .waiting:
            "waiting"
        }
    }

    fileprivate static func snapshotRoutingStatusString(_ status: RoutingStatus) -> String {
        switch status {
        case .attached:
            "attached"
        case .detached:
            "detached"
        case .unavailable:
            "unavailable"
        }
    }

    fileprivate static func snapshotRoutingTargetKindString(_ kind: RoutingTargetKind) -> String {
        switch kind {
        case .tmuxPane:
            "tmux_pane"
        case .tmuxSession:
            "tmux_session"
        case .terminalApp:
            "terminal_app"
        case .none:
            "none"
        }
    }
}

private extension CoreRoutingTarget {
    init(_ target: RoutingTarget) {
        kind = RuntimeClient.snapshotRoutingTargetKindString(target.kind)
        terminalApp = target.terminalApp
        sessionName = target.sessionName
        paneId = target.paneId
        hostTty = target.hostTty
    }
}
