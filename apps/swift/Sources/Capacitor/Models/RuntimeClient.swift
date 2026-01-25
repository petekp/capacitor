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
}

struct CoreRoutingTarget: Equatable {
    let kind: String
    let value: String?
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

struct CoreRoutingDiagnostics: Equatable {
    let snapshot: CoreRoutingSnapshot
    let signalAgesMs: [String: UInt64]
    let candidateTargets: [CoreRoutingTarget]
    let conflicts: [String]
    let scopeResolution: String
}

struct RuntimeRoutingConfig: Decodable, Equatable {
    let tmuxSignalFreshMs: UInt64
    let shellSignalFreshMs: UInt64
    let shellRetentionHours: UInt64
    let tmuxPollIntervalMs: UInt64

    enum CodingKeys: String, CodingKey {
        case tmuxSignalFreshMs = "tmux_signal_fresh_ms"
        case shellSignalFreshMs = "shell_signal_fresh_ms"
        case shellRetentionHours = "shell_retention_hours"
        case tmuxPollIntervalMs = "tmux_poll_interval_ms"
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
        static let coreSnapshotEnv = "CAPACITOR_CORE_SNAPSHOT"
        static let coreSnapshotReadEnabledEnv = "CAPACITOR_CORE_SNAPSHOT_READ_ENABLED"
        static let coreSnapshotRelativePath = ".capacitor/runtime/app_snapshot.json"
        static let protocolVersion = 1
        static let tmuxSignalFreshMs: UInt64 = 5000
        static let shellSignalFreshMs: UInt64 = 600_000
        static let shellRetentionHours: UInt64 = 24
        static let tmuxPollIntervalMs: UInt64 = 1000
    }

    private let coreSnapshotPathOverride: String?
    private let isEnabledOverride: Bool?

    init(coreSnapshotPathOverride: String? = nil, isEnabledOverride: Bool? = nil) {
        self.coreSnapshotPathOverride = coreSnapshotPathOverride
        self.isEnabledOverride = isEnabledOverride
    }

    private init() {
        coreSnapshotPathOverride = nil
        isEnabledOverride = nil
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
        let snapshot = try requireSnapshot(operation: "fetchHealth")
        return RuntimeHealth(
            status: "ok",
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            version: "core-snapshot-v1",
            protocolVersion: Constants.protocolVersion,
            runtime: RuntimeEngineHealth(
                activeConnections: UInt64(snapshot.sessions.count),
                maxActiveConnections: UInt64(max(snapshot.sessions.count, 1)),
                buildHash: "core-snapshot",
            ),
            routing: RuntimeRoutingHealth(
                enabled: true,
                rollout: nil,
            ),
        )
    }

    func fetchShellState() async throws -> ShellCwdState {
        let snapshot = try requireSnapshot(operation: "fetchShellState")
        guard let shellState = mapShellState(snapshot, operation: "fetchShellState") else {
            throw RuntimeClientError.invalidResponse
        }
        DebugLog.write("RuntimeClient.fetchShellState source=core_snapshot shells=\(shellState.shells.count)")
        return shellState
    }

    func fetchSessions() async throws -> [RuntimeSession] {
        let snapshot = try requireSnapshot(operation: "fetchSessions")
        let sessions = mapSessions(snapshot)
        DebugLog.write("RuntimeClient.fetchSessions source=core_snapshot count=\(sessions.count)")
        return sessions
    }

    func fetchProjectStates(correlationId: String? = nil) async throws -> [RuntimeProjectState] {
        let snapshot = try requireSnapshot(correlationId: correlationId, operation: "fetchProjectStates")
        let states = mapProjectStates(snapshot)
        let cid = correlationId ?? "none"
        DebugLog.write("RuntimeClient.fetchProjectStates source=core_snapshot cid=\(cid) count=\(states.count)")
        return states
    }

    func fetchRuntimeSnapshot(correlationId: String? = nil) async throws -> RuntimeSnapshot {
        let snapshot = try requireSnapshot(correlationId: correlationId, operation: "fetchRuntimeSnapshot")
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
            "RuntimeClient.fetchRuntimeSnapshot source=core_snapshot cid=\(cid) projects=\(projectStates.count) sessions=\(sessions.count) shells=\(shellState.shells.count)",
        )

        return RuntimeSnapshot(
            projectStates: projectStates,
            sessions: sessions,
            shellState: shellState,
        )
    }

    func fetchCoreRoutingSnapshot(projectPath: String, workspaceId: String?) async throws -> CoreRoutingSnapshot {
        let snapshot = try requireSnapshot(operation: "fetchRoutingSnapshot")
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
            target: CoreRoutingTarget(kind: "none", value: nil),
            confidence: "low",
            reasonCode: "NO_TRUSTED_EVIDENCE",
            reason: "No routing evidence available in core snapshot",
            evidence: [],
            updatedAt: ISO8601DateFormatter().string(from: Date()),
        )
    }

    func fetchCoreRoutingDiagnostics(projectPath: String, workspaceId: String?) async throws -> CoreRoutingDiagnostics {
        let snapshot = try requireSnapshot(operation: "fetchRoutingDiagnostics")
        let resolved = resolveRoutingView(
            for: snapshot,
            projectPath: projectPath,
            workspaceId: workspaceId,
        )
        let routingSnapshot = try await fetchCoreRoutingSnapshot(projectPath: projectPath, workspaceId: workspaceId)
        let candidateTargets: [CoreRoutingTarget] = routingSnapshot.target.kind == "none"
            ? []
            : [routingSnapshot.target]

        return CoreRoutingDiagnostics(
            snapshot: routingSnapshot,
            signalAgesMs: [:],
            candidateTargets: candidateTargets,
            conflicts: [],
            scopeResolution: resolved.scope,
        )
    }

    func fetchRuntimeConfig() async throws -> RuntimeRoutingConfig {
        _ = try requireSnapshot(operation: "fetchRuntimeConfig")
        return RuntimeRoutingConfig(
            tmuxSignalFreshMs: Constants.tmuxSignalFreshMs,
            shellSignalFreshMs: Constants.shellSignalFreshMs,
            shellRetentionHours: Constants.shellRetentionHours,
            tmuxPollIntervalMs: Constants.tmuxPollIntervalMs,
        )
    }

    private func requireSnapshot(
        correlationId: String? = nil,
        operation: String,
    ) throws -> AppSnapshot {
        guard isEnabled else {
            throw RuntimeClientError.disabled
        }

        if let snapshot = loadSnapshot(correlationId: correlationId, operation: operation) {
            return snapshot
        }

        throw RuntimeClientError.runtimeUnavailable(
            "Core runtime snapshot unavailable at \(coreSnapshotPath())",
        )
    }

    private func coreSnapshotPath() -> String {
        if let override = coreSnapshotPathOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }

        if let envOverride = getenv(Constants.coreSnapshotEnv) {
            let path = String(cString: envOverride).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(Constants.coreSnapshotRelativePath)
    }

    private func isCoreSnapshotReadEnabled() -> Bool {
        guard let raw = getenv(Constants.coreSnapshotReadEnabledEnv) else {
            return true
        }

        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["0", "false", "no", "off"].contains(value) {
            return false
        }
        if ["1", "true", "yes", "on"].contains(value) {
            return true
        }
        return true
    }

    private func loadSnapshot(
        correlationId: String? = nil,
        operation: String,
    ) -> AppSnapshot? {
        guard isCoreSnapshotReadEnabled() else {
            let cid = correlationId ?? "none"
            DebugLog.write("RuntimeClient.\(operation) source=core_snapshot_disabled cid=\(cid)")
            return nil
        }

        let path = coreSnapshotPath()
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let runtime = try CoreRuntime.newWithSnapshotFile(snapshotFile: path)
            return try runtime.appSnapshot()
        } catch {
            let cid = correlationId ?? "none"
            DebugLog.write(
                "RuntimeClient.\(operation) source=core_snapshot_ffi_error cid=\(cid) path=\(path) error=\(error)",
            )
            return nil
        }
    }

    private func mapProjectStates(_ snapshot: AppSnapshot) -> [RuntimeProjectState] {
        snapshot.projects.map { project in
            RuntimeProjectState(
                projectId: project.projectId,
                workspaceId: project.workspaceId,
                projectPath: project.projectPath,
                state: sessionStateString(project.state),
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

    private func mapSessions(_ snapshot: AppSnapshot) -> [RuntimeSession] {
        snapshot.sessions.map { session in
            RuntimeSession(
                sessionId: session.sessionId,
                pid: session.pid,
                state: sessionStateString(session.state),
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
        _ snapshot: AppSnapshot,
        correlationId: String? = nil,
        operation: String,
    ) -> ShellCwdState? {
        var shells: [String: ShellEntry] = [:]
        for signal in snapshot.shells {
            guard let updatedAt = RuntimeDateParser.parse(signal.updatedAt) else {
                let cid = correlationId ?? "none"
                DebugLog.write(
                    "RuntimeClient.\(operation) source=core_snapshot_map_error cid=\(cid) pid=\(signal.pid) invalid_updated_at=\(signal.updatedAt)",
                )
                return nil
            }

            shells[String(signal.pid)] = ShellEntry(
                cwd: signal.cwd,
                tty: signal.tty,
                parentApp: signal.parentApp,
                tmuxSession: signal.tmuxSession,
                tmuxClientTty: nil,
                updatedAt: updatedAt,
            )
        }

        return ShellCwdState(version: 1, shells: shells)
    }

    private func resolveRoutingView(
        for snapshot: AppSnapshot,
        projectPath: String,
        workspaceId: String?,
    ) -> (route: RoutingView?, scope: String) {
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
        _ route: RoutingView,
        projectPath: String,
        workspaceId _: String?,
        snapshot: AppSnapshot,
    ) -> CoreRoutingSnapshot {
        let normalizedStatus = routingStatusString(route.status)
        let normalizedTargetKind = routingTargetKindString(route.targetKind)
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
            target: CoreRoutingTarget(kind: normalizedTargetKind, value: route.targetValue),
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
        route: RoutingView,
        snapshot: AppSnapshot,
    ) -> [CoreRoutingEvidence] {
        guard route.targetKind == .tmuxSession,
              let target = route.targetValue,
              !target.isEmpty
        else {
            return []
        }

        let now = Date()
        return snapshot.shells
            .filter { $0.tmuxSession == target }
            .compactMap { shell in
                let ageMs: UInt64
                if let updatedAt = RuntimeDateParser.parse(shell.updatedAt) {
                    let interval = max(0, now.timeIntervalSince(updatedAt))
                    ageMs = UInt64((interval * 1000).rounded())
                } else {
                    ageMs = 0
                }

                let tty = shell.tty.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tty.isEmpty else { return nil }

                return CoreRoutingEvidence(
                    evidenceType: "tmux_client",
                    value: tty,
                    ageMs: ageMs,
                    trustRank: 0,
                )
            }
            .sorted { left, right in
                if left.trustRank != right.trustRank {
                    return left.trustRank < right.trustRank
                }
                return left.ageMs < right.ageMs
            }
    }

    private func sessionStateString(_ state: SessionState) -> String {
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

    private func routingStatusString(_ status: RoutingStatus) -> String {
        switch status {
        case .attached:
            "attached"
        case .detached:
            "detached"
        case .unavailable:
            "unavailable"
        }
    }

    private func routingTargetKindString(_ kind: RoutingTargetKind) -> String {
        switch kind {
        case .tmuxSession:
            "tmux_session"
        case .terminalApp:
            "terminal_app"
        case .none:
            "none"
        }
    }
}
