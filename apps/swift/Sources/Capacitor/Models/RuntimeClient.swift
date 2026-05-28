import Foundation

final class RuntimeClient {
    static let shared = RuntimeClient()

    private enum Constants {
        static let enabledEnv = "CAPACITOR_RUNTIME_ENABLED"
        static let minimumSchemaVersion = 3
        static let tmuxSignalFreshMs: UInt64 = 5000
        static let shellSignalFreshMs: UInt64 = 600_000
        static let shellRetentionHours: UInt64 = 24
        static let tmuxPollIntervalMs: UInt64 = 1000
    }

    private let isEnabledOverride: Bool?
    private let runtimeServiceConnectionOverride: RuntimeServiceConnection?
    private let loadRuntimeServiceConnection: () -> RuntimeServiceConnection?
    private let sendRequest: (URLRequest) async throws -> (Data, URLResponse)
    private var incompatibleSchemaHandler: (RuntimeHealth, Int) async -> Void = { _, _ in }

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

    func setIncompatibleSchemaHandler(
        _ handler: @escaping (RuntimeHealth, Int) async -> Void,
    ) {
        incompatibleSchemaHandler = handler
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
        return try makeRuntimeSnapshot(
            from: snapshot,
            correlationId: correlationId,
            operation: "fetchRuntimeSnapshot",
        )
    }

    func longPollSnapshot(sinceVersion: UInt64) async throws -> LongPollResponse {
        guard isEnabled else {
            throw RuntimeClientError.disabled
        }

        var request = try runtimeServiceRequest(
            path: "/runtime/snapshot/poll",
            queryItems: [URLQueryItem(name: "since_version", value: String(sinceVersion))],
        )
        request.timeoutInterval = 35

        do {
            let (data, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse else {
                throw RuntimeClientError.invalidResponse
            }

            switch http.statusCode {
            case 200:
                let metadata = try JSONDecoder().decode(LongPollMetadata.self, from: data)
                guard metadata.changed else {
                    return .unchanged(snapshotVersion: metadata.snapshotVersion ?? sinceVersion)
                }

                let snapshot = try makeRuntimeSnapshot(
                    from: decodeSnapshotPayload(data),
                    operation: "longPollSnapshot",
                )
                return .changed(snapshot)
            case 404:
                return .unavailable
            default:
                throw RuntimeClientError.runtimeUnavailable(
                    "Runtime service long-poll request failed for \(request.url?.absoluteString ?? "unknown")",
                )
            }
        } catch let error as RuntimeClientError {
            throw error
        } catch {
            throw RuntimeClientError.runtimeUnavailable(
                "Runtime service long-poll unavailable: \(error.localizedDescription)",
            )
        }
    }

    func fetchCoreRoutingSnapshot(
        projectPath: String,
        workspaceId: String?,
        clientTty: String? = nil,
        sessionName: String? = nil,
    ) async throws -> CoreRoutingSnapshot {
        let route = try await resolveRouting(
            projectPath: projectPath,
            workspaceId: workspaceId,
            clientTty: clientTty,
            sessionName: sessionName,
        )
        return mapCoreRoutingSnapshot(
            route,
            projectPath: projectPath,
            workspaceId: workspaceId,
        )
    }

    func mutateDelegation(_ requestBody: RuntimeDelegationMutationRequest) async throws {
        guard isEnabled else {
            throw RuntimeClientError.disabled
        }

        var request = try runtimeServiceRequest(path: "/runtime/delegation/mutate")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        do {
            let (data, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw RuntimeClientError.runtimeUnavailable(
                    "Runtime delegation mutation failed for \(request.url?.absoluteString ?? "unknown")",
                )
            }

            if let outcome = try? JSONDecoder().decode(MutationOutcomeResponse.self, from: data),
               !outcome.ok
            {
                throw RuntimeClientError.mutationRejected(outcome.message)
            }
        } catch let error as RuntimeClientError {
            throw error
        } catch {
            throw RuntimeClientError.runtimeUnavailable(
                "Runtime delegation mutation unavailable: \(error.localizedDescription)",
            )
        }
    }

    func mutateRun(_ requestBody: RuntimeRunMutationRequest) async throws {
        guard isEnabled else {
            throw RuntimeClientError.disabled
        }

        var request = try runtimeServiceRequest(path: "/runtime/run/mutate")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        do {
            let (data, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw RuntimeClientError.runtimeUnavailable(
                    "Runtime run mutation failed for \(request.url?.absoluteString ?? "unknown")",
                )
            }

            if let outcome = try? JSONDecoder().decode(MutationOutcomeResponse.self, from: data),
               !outcome.ok
            {
                throw RuntimeClientError.mutationRejected(outcome.message)
            }
        } catch let error as RuntimeClientError {
            throw error
        } catch {
            throw RuntimeClientError.runtimeUnavailable(
                "Runtime run mutation unavailable: \(error.localizedDescription)",
            )
        }
    }

    func reportSleep() async throws {
        guard isEnabled else {
            throw RuntimeClientError.disabled
        }

        var request = try runtimeServiceRequest(path: "/runtime/power/sleep")
        request.httpMethod = "POST"

        do {
            let (_, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw RuntimeClientError.runtimeUnavailable(
                    "Runtime power sleep request failed for \(request.url?.absoluteString ?? "unknown")",
                )
            }
        } catch let error as RuntimeClientError {
            throw error
        } catch {
            throw RuntimeClientError.runtimeUnavailable(
                "Runtime power sleep unavailable: \(error.localizedDescription)",
            )
        }
    }

    func reportWake() async throws {
        guard isEnabled else {
            throw RuntimeClientError.disabled
        }

        var request = try runtimeServiceRequest(path: "/runtime/power/wake")
        request.httpMethod = "POST"

        do {
            let (_, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw RuntimeClientError.runtimeUnavailable(
                    "Runtime power wake request failed for \(request.url?.absoluteString ?? "unknown")",
                )
            }
        } catch let error as RuntimeClientError {
            throw error
        } catch {
            throw RuntimeClientError.runtimeUnavailable(
                "Runtime power wake unavailable: \(error.localizedDescription)",
            )
        }
    }

    private struct MutationOutcomeResponse: Decodable {
        let ok: Bool
        let message: String
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

    private func resolveRouting(
        projectPath: String,
        workspaceId: String?,
        clientTty: String?,
        sessionName: String?,
    ) async throws -> SnapshotRoutingPayload {
        guard isEnabled else {
            throw RuntimeClientError.disabled
        }

        var request = try runtimeServiceRequest(path: "/runtime/routing/resolve")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ResolveRoutingRequest(
            projectPath: projectPath,
            workspaceId: workspaceId,
            sessionName: sessionName,
            clientTty: clientTty,
        ))

        do {
            let (data, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw RuntimeClientError.runtimeUnavailable(
                    "Runtime route request failed for \(request.url?.absoluteString ?? "unknown")",
                )
            }
            return try JSONDecoder().decode(SnapshotRoutingPayload.self, from: data)
        } catch let error as RuntimeClientError {
            throw error
        } catch {
            throw RuntimeClientError.runtimeUnavailable(
                "Runtime route unavailable: \(error.localizedDescription)",
            )
        }
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
            return try decodeSnapshotPayload(data)
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
            let health = try JSONDecoder().decode(RuntimeHealth.self, from: data)
            guard health.isCompatibleBootstrapService else {
                throw RuntimeClientError.runtimeUnavailable(
                    "Unexpected runtime service health contract: \(health.bootstrapContractMismatchDescription)",
                )
            }
            guard health.normalizedSchemaVersion >= Constants.minimumSchemaVersion else {
                let message =
                    "Runtime service schema version \(health.normalizedSchemaVersion) is older than required version \(Constants.minimumSchemaVersion). Restarting runtime."
                DebugLog.write(message)
                await incompatibleSchemaHandler(health, Constants.minimumSchemaVersion)
                throw RuntimeClientError.runtimeUnavailable(message)
            }
            return health
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

    private func runtimeServiceRequest(
        path: String,
        queryItems: [URLQueryItem],
    ) throws -> URLRequest {
        guard let connection = runtimeServiceConnectionOverride ?? loadRuntimeServiceConnection() else {
            throw RuntimeClientError.runtimeUnavailable("Runtime service connection unavailable")
        }

        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = connection.baseURL.appendingPathComponent(normalizedPath)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RuntimeClientError.invalidResponse
        }
        components.queryItems = queryItems
        guard let resolvedURL = components.url else {
            throw RuntimeClientError.invalidResponse
        }

        var request = URLRequest(url: resolvedURL)
        request.setValue("Bearer \(connection.bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func decodeSnapshotPayload(_ data: Data) throws -> SnapshotPayload {
        try JSONDecoder().decode(SnapshotPayload.self, from: data)
    }

    private func makeRuntimeSnapshot(
        from snapshot: SnapshotPayload,
        correlationId: String? = nil,
        operation: String,
    ) throws -> RuntimeSnapshot {
        let projectStates = mapProjectStates(snapshot)
        let sessions = mapSessions(snapshot)
        let runs = mapRuns(snapshot)
        guard let shellState = mapShellState(
            snapshot,
            correlationId: correlationId,
            operation: operation,
        ) else {
            throw RuntimeClientError.invalidResponse
        }

        let cid = correlationId ?? "none"
        DebugLog.write(
            "RuntimeClient.\(operation) source=\(runtimeSourceLabel) cid=\(cid) projects=\(projectStates.count) sessions=\(sessions.count) shells=\(shellState.shells.count) runs=\(runs.count)",
        )

        return RuntimeSnapshot(
            projectStates: projectStates,
            sessions: sessions,
            shellState: shellState,
            routingViews: mapRoutingViews(snapshot),
            delegations: mapDelegations(snapshot),
            runs: runs,
            snapshotVersion: snapshot.snapshotVersion,
        )
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
                stateSource: session.stateSource.map {
                    RuntimeStateSource(
                        eventKind: String(describing: $0.eventKind),
                        authority: String(describing: $0.authority),
                        observedAt: $0.observedAt,
                    )
                },
                lastAuthoritativeEventAt: session.lastAuthoritativeEventAt,
                gcReason: session.gcReason,
                isAlive: session.isAlive,
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

    private func mapDelegations(_ snapshot: SnapshotPayload) -> [RuntimeDelegationState] {
        snapshot.delegations.map { delegation in
            RuntimeDelegationState(
                projectPath: delegation.projectPath,
                workerId: delegation.workerId,
                ideaId: delegation.ideaId,
                worktreeName: delegation.worktreeName,
                worktreePath: delegation.worktreePath,
                sessionId: delegation.sessionId,
                status: delegation.status,
                startedAt: delegation.startedAt,
                updatedAt: delegation.updatedAt,
                submittedMilestoneId: delegation.submittedMilestoneId,
                currentReview: delegation.currentReview.map { review in
                    RuntimeDelegationReview(
                        milestoneId: review.milestoneId,
                        briefPath: review.briefPath,
                        manifestPath: review.manifestPath,
                        requestedAt: review.requestedAt,
                    )
                },
            )
        }
    }

    private func mapRuns(_ snapshot: SnapshotPayload) -> [RuntimeRunState] {
        snapshot.runs.map(RuntimeRunState.init)
    }

    private func mapCoreRoutingSnapshot(
        _ route: SnapshotRoutingPayload,
        projectPath: String,
        workspaceId _: String?,
    ) -> CoreRoutingSnapshot {
        let normalizedStatus = route.status
        let reasonCode = normalizeReasonCode(route.reasonCode)

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
            evidence: [],
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
}

private struct LongPollMetadata: Decodable {
    let changed: Bool
    let snapshotVersion: UInt64?

    enum CodingKeys: String, CodingKey {
        case changed
        case snapshotVersion = "snapshot_version"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changed = try container.decodeIfPresent(Bool.self, forKey: .changed) ?? true
        snapshotVersion = try container.decodeIfPresent(UInt64.self, forKey: .snapshotVersion)
    }
}

private struct SnapshotPayload: Decodable {
    let snapshotVersion: UInt64
    let projects: [SnapshotProjectPayload]
    let sessions: [SnapshotSessionPayload]
    let shells: [SnapshotShellPayload]
    let routing: [SnapshotRoutingPayload]
    let delegations: [SnapshotDelegationPayload]
    let runs: [SnapshotRunPayload]

    enum CodingKeys: String, CodingKey {
        case snapshotVersion = "snapshot_version"
        case projects
        case sessions
        case shells
        case routing
        case delegations
        case runs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshotVersion = try container.decodeIfPresent(UInt64.self, forKey: .snapshotVersion) ?? 0
        projects = try container.decode([SnapshotProjectPayload].self, forKey: .projects)
        sessions = try container.decode([SnapshotSessionPayload].self, forKey: .sessions)
        shells = try container.decode([SnapshotShellPayload].self, forKey: .shells)
        routing = try container.decode([SnapshotRoutingPayload].self, forKey: .routing)
        delegations = try container.decodeIfPresent([SnapshotDelegationPayload].self, forKey: .delegations) ?? []
        runs = try container.decodeIfPresent([SnapshotRunPayload].self, forKey: .runs) ?? []
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
    let stateSource: SnapshotStateSourcePayload?
    let lastAuthoritativeEventAt: String?
    let gcReason: String?
    let isAlive: Bool?

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
        case stateSource = "state_source"
        case lastAuthoritativeEventAt = "last_authoritative_event_at"
        case gcReason = "gc_reason"
        case isAlive = "is_alive"
    }
}

private struct SnapshotStateSourcePayload: Decodable {
    let eventKind: String
    let authority: String
    let observedAt: String

    enum CodingKeys: String, CodingKey {
        case eventKind = "event_kind"
        case authority
        case observedAt = "observed_at"
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
}

private struct SnapshotDelegationReviewPayload: Decodable {
    let milestoneId: String
    let briefPath: String
    let manifestPath: String
    let requestedAt: String

    enum CodingKeys: String, CodingKey {
        case milestoneId = "milestone_id"
        case briefPath = "brief_path"
        case manifestPath = "manifest_path"
        case requestedAt = "requested_at"
    }
}

private struct SnapshotDelegationPayload: Decodable {
    let projectPath: String
    let workerId: String
    let ideaId: String?
    let worktreeName: String
    let worktreePath: String
    let sessionId: String?
    let status: String
    let startedAt: String
    let updatedAt: String
    let submittedMilestoneId: String?
    let currentReview: SnapshotDelegationReviewPayload?

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case workerId = "worker_id"
        case ideaId = "idea_id"
        case worktreeName = "worktree_name"
        case worktreePath = "worktree_path"
        case sessionId = "session_id"
        case status
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case submittedMilestoneId = "submitted_milestone_id"
        case currentReview = "current_review"
    }
}

private struct SnapshotCaptureClaimPayload: Decodable {
    let captureRequestId: String
    let clientId: String
    let claimedAt: String
    let observedCaptureUrl: String?

    enum CodingKeys: String, CodingKey {
        case captureRequestId = "capture_request_id"
        case clientId = "client_id"
        case claimedAt = "claimed_at"
        case observedCaptureUrl = "observed_capture_url"
    }
}

private struct SnapshotMediaArtifactPayload: Decodable {
    let artifactType: String
    let path: String
    let label: String
    let width: Int?
    let height: Int?
    let durationSecs: String?

    enum CodingKeys: String, CodingKey {
        case artifactType = "artifact_type"
        case path
        case label
        case width
        case height
        case durationSecs = "duration_secs"
    }
}

private struct SnapshotMermaidSourcePayload: Decodable {
    let label: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case label
        case source
    }
}

private struct SnapshotCheckpointDecisionPayload: Decodable {
    let action: String
    let note: String?
}

private struct SnapshotCheckpointPayload: Decodable {
    let id: String
    let historyOrdinal: UInt64?
    let phaseId: String
    let kind: RuntimeCheckpointKind
    let status: String
    let title: String
    let summary: String?
    let briefPath: String?
    let manifestPath: String?
    let mediaArtifacts: [SnapshotMediaArtifactPayload]
    let mermaidSources: [SnapshotMermaidSourcePayload]
    let captureStatus: RuntimeCaptureStatus
    let captureUrl: String?
    let captureClaim: SnapshotCaptureClaimPayload?
    let decision: SnapshotCheckpointDecisionPayload?
    let createdAt: String
    let decidedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case historyOrdinal = "history_ordinal"
        case phaseId = "phase_id"
        case kind
        case status
        case title
        case summary
        case briefPath = "brief_path"
        case manifestPath = "manifest_path"
        case mediaArtifacts = "media_artifacts"
        case mermaidSources = "mermaid_sources"
        case captureStatus = "capture_status"
        case captureUrl = "capture_url"
        case captureClaim = "capture_claim"
        case decision
        case createdAt = "created_at"
        case decidedAt = "decided_at"
    }

    private struct FailedCaptureStatusPayload: Decodable {
        struct ReasonPayload: Decodable {
            let reason: String
        }

        let failed: ReasonPayload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        historyOrdinal = try container.decodeIfPresent(UInt64.self, forKey: .historyOrdinal)
        phaseId = try container.decode(String.self, forKey: .phaseId)
        kind = try container.decode(RuntimeCheckpointKind.self, forKey: .kind)
        status = try container.decode(String.self, forKey: .status)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        briefPath = try container.decodeIfPresent(String.self, forKey: .briefPath)
        manifestPath = try container.decodeIfPresent(String.self, forKey: .manifestPath)
        mediaArtifacts = try container.decodeIfPresent([SnapshotMediaArtifactPayload].self, forKey: .mediaArtifacts) ?? []
        mermaidSources = try container.decodeIfPresent([SnapshotMermaidSourcePayload].self, forKey: .mermaidSources) ?? []
        captureUrl = try container.decodeIfPresent(String.self, forKey: .captureUrl)
        captureClaim = try container.decodeIfPresent(SnapshotCaptureClaimPayload.self, forKey: .captureClaim)
        decision = try container.decodeIfPresent(SnapshotCheckpointDecisionPayload.self, forKey: .decision)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        decidedAt = try container.decodeIfPresent(String.self, forKey: .decidedAt)

        if let rawStatus = try? container.decode(String.self, forKey: .captureStatus) {
            switch rawStatus {
            case "not_requested":
                captureStatus = .notRequested
            case "pending":
                captureStatus = .pending
            case "in_progress":
                captureStatus = .inProgress
            case "completed":
                captureStatus = .completed
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .captureStatus,
                    in: container,
                    debugDescription: "Unsupported capture status: \(rawStatus)",
                )
            }
        } else {
            let payload = try container.decode(FailedCaptureStatusPayload.self, forKey: .captureStatus)
            captureStatus = .failed(reason: payload.failed.reason)
        }
    }
}

private struct SnapshotPhasePayload: Decodable {
    let id: String
    let name: String
    let status: String
    let startedAt: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

private struct SnapshotRunPayload: Decodable {
    let id: String
    let projectPath: String
    let methodId: String
    let methodName: String
    let status: String
    let sessionId: String?
    let delegationWorkerId: String?
    let statusMessage: String?
    let phases: [SnapshotPhasePayload]
    let currentPhaseIndex: Int
    let createdAt: String
    let updatedAt: String
    let activeCheckpoint: SnapshotCheckpointPayload?
    let pastCheckpoints: [SnapshotCheckpointPayload]
    let ideaId: String?
    let ideaTitle: String?
    let ideaDescription: String?

    enum CodingKeys: String, CodingKey {
        case id
        case projectPath = "project_path"
        case methodId = "method_id"
        case methodName = "method_name"
        case status
        case sessionId = "session_id"
        case delegationWorkerId = "delegation_worker_id"
        case statusMessage = "status_message"
        case phases
        case currentPhaseIndex = "current_phase_index"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case activeCheckpoint = "active_checkpoint"
        case pastCheckpoints = "past_checkpoints"
        case ideaId = "idea_id"
        case ideaTitle = "idea_title"
        case ideaDescription = "idea_description"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        methodId = try container.decode(String.self, forKey: .methodId)
        methodName = try container.decode(String.self, forKey: .methodName)
        status = try container.decode(String.self, forKey: .status)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        delegationWorkerId = try container.decodeIfPresent(String.self, forKey: .delegationWorkerId)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        phases = try container.decodeIfPresent([SnapshotPhasePayload].self, forKey: .phases) ?? []
        currentPhaseIndex = try container.decodeIfPresent(Int.self, forKey: .currentPhaseIndex) ?? 0
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        activeCheckpoint = try container.decodeIfPresent(SnapshotCheckpointPayload.self, forKey: .activeCheckpoint)
        pastCheckpoints = try container.decodeIfPresent([SnapshotCheckpointPayload].self, forKey: .pastCheckpoints) ?? []
        ideaId = try container.decodeIfPresent(String.self, forKey: .ideaId)
        ideaTitle = try container.decodeIfPresent(String.self, forKey: .ideaTitle)
        ideaDescription = try container.decodeIfPresent(String.self, forKey: .ideaDescription)
    }
}

private struct ResolveRoutingRequest: Encodable {
    let projectPath: String
    let workspaceId: String?
    let sessionName: String?
    let clientTty: String?

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case workspaceId = "workspace_id"
        case sessionName = "session_name"
        case clientTty = "client_tty"
    }
}

private extension RuntimeMediaArtifact {
    init(_ payload: SnapshotMediaArtifactPayload) {
        artifactType = payload.artifactType
        path = payload.path
        label = payload.label
        width = payload.width
        height = payload.height
        durationSecs = payload.durationSecs
    }
}

private extension RuntimeMermaidSource {
    init(_ payload: SnapshotMermaidSourcePayload) {
        label = payload.label
        source = payload.source
    }
}

private extension RuntimeCaptureClaim {
    init(_ payload: SnapshotCaptureClaimPayload) {
        captureRequestId = payload.captureRequestId
        clientId = payload.clientId
        claimedAt = payload.claimedAt
        observedCaptureUrl = payload.observedCaptureUrl
    }
}

private extension RuntimeCheckpointDecision {
    init(_ payload: SnapshotCheckpointDecisionPayload) {
        action = payload.action
        note = payload.note
    }
}

private extension RuntimeCheckpointState {
    init(_ payload: SnapshotCheckpointPayload) {
        id = payload.id
        historyOrdinal = payload.historyOrdinal
        phaseId = payload.phaseId
        kind = payload.kind
        status = payload.status
        title = payload.title
        summary = payload.summary
        briefPath = payload.briefPath
        manifestPath = payload.manifestPath
        mediaArtifacts = payload.mediaArtifacts.map(RuntimeMediaArtifact.init)
        mermaidSources = payload.mermaidSources.map(RuntimeMermaidSource.init)
        captureStatus = payload.captureStatus
        captureUrl = payload.captureUrl
        captureClaim = payload.captureClaim.map(RuntimeCaptureClaim.init)
        decision = payload.decision.map(RuntimeCheckpointDecision.init)
        createdAt = payload.createdAt
        decidedAt = payload.decidedAt
    }
}

private extension RuntimeRunState {
    init(_ payload: SnapshotRunPayload) {
        id = payload.id
        projectPath = payload.projectPath
        methodId = payload.methodId
        methodName = payload.methodName
        status = payload.status
        sessionId = payload.sessionId
        delegationWorkerId = payload.delegationWorkerId
        statusMessage = payload.statusMessage
        phases = payload.phases.map { phase in
            RuntimePhaseInstance(
                id: phase.id,
                name: phase.name,
                status: phase.status,
                startedAt: phase.startedAt,
                completedAt: phase.completedAt,
            )
        }
        currentPhaseIndex = payload.currentPhaseIndex
        createdAt = payload.createdAt
        updatedAt = payload.updatedAt
        activeCheckpoint = payload.activeCheckpoint.map(RuntimeCheckpointState.init)
        pastCheckpoints = payload.pastCheckpoints.map(RuntimeCheckpointState.init)
        ideaId = payload.ideaId
        ideaTitle = payload.ideaTitle
        ideaDescription = payload.ideaDescription
    }
}
