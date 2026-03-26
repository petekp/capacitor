import Foundation

struct RuntimeHealth: Decodable {
    let status: String
    let pid: Int
    let version: String
    let protocolVersion: Int
    let schemaVersion: Int?
    let authMode: String
    let serviceMode: String
    let security: RuntimeSecurityHealth?
    let runtime: RuntimeEngineHealth?
    let routing: RuntimeRoutingHealth?

    init(
        status: String,
        pid: Int,
        version: String,
        protocolVersion: Int,
        schemaVersion: Int? = nil,
        authMode: String,
        serviceMode: String,
        security: RuntimeSecurityHealth? = nil,
        runtime: RuntimeEngineHealth? = nil,
        routing: RuntimeRoutingHealth? = nil,
    ) {
        self.status = status
        self.pid = pid
        self.version = version
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.authMode = authMode
        self.serviceMode = serviceMode
        self.security = security
        self.runtime = runtime
        self.routing = routing
    }

    enum CodingKeys: String, CodingKey {
        case status, pid, version, security, runtime, routing
        case protocolVersion = "protocol_version"
        case schemaVersion = "schema_version"
        case authMode = "auth_mode"
        case serviceMode = "service_mode"
    }

    var isCompatibleBootstrapService: Bool {
        status == "ok" &&
            protocolVersion == 1 &&
            authMode == "bearer" &&
            serviceMode == "bootstrap_only"
    }

    var bootstrapContractMismatchDescription: String {
        if status != "ok" {
            return "unexpected status \(status)"
        }
        if protocolVersion != 1 {
            return "unexpected protocol version \(protocolVersion)"
        }
        if authMode != "bearer" {
            return "unexpected auth mode \(authMode)"
        }
        if serviceMode != "bootstrap_only" {
            return "unexpected service mode \(serviceMode)"
        }
        return "unknown runtime health contract mismatch"
    }

    var normalizedSchemaVersion: Int {
        schemaVersion ?? 0
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
    let delegations: [RuntimeDelegationState]
    let runs: [RuntimeRunState]
}

struct RuntimeDelegationReview: Decodable, Equatable {
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

struct RuntimeDelegationState: Decodable, Equatable {
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
    let currentReview: RuntimeDelegationReview?

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

    init(
        projectPath: String,
        workerId: String,
        ideaId: String?,
        worktreeName: String,
        worktreePath: String,
        sessionId: String?,
        status: String,
        startedAt: String,
        updatedAt: String,
        submittedMilestoneId: String? = nil,
        currentReview: RuntimeDelegationReview?,
    ) {
        self.projectPath = projectPath
        self.workerId = workerId
        self.ideaId = ideaId
        self.worktreeName = worktreeName
        self.worktreePath = worktreePath
        self.sessionId = sessionId
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.submittedMilestoneId = submittedMilestoneId
        self.currentReview = currentReview
    }
}

enum RuntimeCheckpointKind: Equatable, Sendable, Codable {
    case proposal
    case implementationMilestone
    case alignmentReview
    case custom(label: String)

    private enum CodingKeys: String, CodingKey {
        case custom
    }

    private struct CustomPayload: Codable {
        let label: String
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self)
        {
            switch value {
            case "proposal":
                self = .proposal
            case "implementation_milestone":
                self = .implementationMilestone
            case "alignment_review":
                self = .alignmentReview
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported checkpoint kind: \(value)",
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.custom) {
            let payload = try container.decode(CustomPayload.self, forKey: .custom)
            self = .custom(label: payload.label)
            return
        }

        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Unsupported checkpoint kind payload",
        ))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .proposal:
            var container = encoder.singleValueContainer()
            try container.encode("proposal")
        case .implementationMilestone:
            var container = encoder.singleValueContainer()
            try container.encode("implementation_milestone")
        case .alignmentReview:
            var container = encoder.singleValueContainer()
            try container.encode("alignment_review")
        case let .custom(label):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(CustomPayload(label: label), forKey: .custom)
        }
    }

    init(_ kind: CheckpointKind) {
        switch kind {
        case .proposal:
            self = .proposal
        case .implementationMilestone:
            self = .implementationMilestone
        case .alignmentReview:
            self = .alignmentReview
        case let .custom(label):
            self = .custom(label: label)
        }
    }
}

enum RuntimeCaptureStatus: Equatable, Sendable {
    case notRequested
    case pending
    case inProgress
    case completed
    case failed(reason: String)
}

struct RuntimeCaptureClaim: Equatable, Sendable {
    let captureRequestId: String
    let clientId: String
    let claimedAt: String
    let observedCaptureUrl: String?
}

struct RuntimeMediaArtifact: Codable, Equatable, Sendable {
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

struct RuntimeMermaidSource: Codable, Equatable, Sendable {
    let label: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case label
        case source
    }
}

struct RuntimeCheckpointState: Equatable, Sendable {
    let id: String
    let phaseId: String
    let kind: RuntimeCheckpointKind
    let status: String
    let title: String
    let summary: String?
    let briefPath: String?
    let manifestPath: String?
    let mediaArtifacts: [RuntimeMediaArtifact]
    let mermaidSources: [RuntimeMermaidSource]
    let captureStatus: RuntimeCaptureStatus
    let captureUrl: String?
    let captureClaim: RuntimeCaptureClaim?
    let createdAt: String
    let decidedAt: String?
}

struct RuntimeRunState: Equatable, Sendable {
    let id: String
    let projectPath: String
    let methodId: String
    let methodName: String
    let status: String
    let sessionId: String?
    let delegationWorkerId: String?
    let statusMessage: String?
    let createdAt: String
    let updatedAt: String
    let activeCheckpoint: RuntimeCheckpointState?
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
    let delegations: [SnapshotDelegationPayload]
    let runs: [SnapshotRunPayload]

    enum CodingKeys: String, CodingKey {
        case projects
        case sessions
        case shells
        case routing
        case delegations
        case runs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([SnapshotProjectPayload].self, forKey: .projects)
        sessions = try container.decode([SnapshotSessionPayload].self, forKey: .sessions)
        shells = try container.decode([SnapshotShellPayload].self, forKey: .shells)
        routing = try container.decode([SnapshotRoutingPayload].self, forKey: .routing)
        delegations = try container.decodeIfPresent([SnapshotDelegationPayload].self, forKey: .delegations) ?? []
        runs = try container.decodeIfPresent([SnapshotRunPayload].self, forKey: .runs) ?? []
    }

    init(_ snapshot: AppSnapshot) {
        projects = snapshot.projects.map(SnapshotProjectPayload.init)
        sessions = snapshot.sessions.map(SnapshotSessionPayload.init)
        shells = snapshot.shells.map(SnapshotShellPayload.init)
        routing = snapshot.routing.map(SnapshotRoutingPayload.init)
        delegations = snapshot.delegations.map(SnapshotDelegationPayload.init)
        runs = snapshot.runs.map(SnapshotRunPayload.init)
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

    init(_ review: DelegationReviewState) {
        milestoneId = review.milestoneId
        briefPath = review.briefPath
        manifestPath = review.manifestPath
        requestedAt = review.requestedAt
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

    init(_ delegation: ProjectDelegationState) {
        projectPath = delegation.projectPath
        workerId = delegation.workerId
        ideaId = delegation.ideaId
        worktreeName = delegation.worktreeName
        worktreePath = delegation.worktreePath
        sessionId = delegation.sessionId
        status = RuntimeClient.snapshotDelegationStatusString(delegation.status)
        startedAt = delegation.startedAt
        updatedAt = delegation.updatedAt
        submittedMilestoneId = RuntimeClient.snapshotDelegationSubmittedMilestoneID(delegation)
        currentReview = delegation.currentReview.map(SnapshotDelegationReviewPayload.init)
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

    init(_ claim: CaptureClaim) {
        captureRequestId = claim.captureRequestId
        clientId = claim.clientId
        claimedAt = claim.claimedAt
        observedCaptureUrl = claim.observedCaptureUrl
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

    init(_ artifact: MediaArtifact) {
        artifactType = RuntimeClient.snapshotMediaArtifactTypeString(artifact.artifactType)
        path = artifact.path
        label = artifact.label
        width = artifact.width.map(Int.init)
        height = artifact.height.map(Int.init)
        durationSecs = artifact.durationSecs
    }
}

private struct SnapshotMermaidSourcePayload: Decodable {
    let label: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case label
        case source
    }

    init(_ source: MermaidSource) {
        label = source.label
        self.source = source.source
    }
}

private struct SnapshotCheckpointPayload: Decodable {
    let id: String
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
    let createdAt: String
    let decidedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
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

    init(_ checkpoint: ActiveCheckpoint) {
        id = checkpoint.id
        phaseId = checkpoint.phaseId
        kind = RuntimeCheckpointKind(checkpoint.kind)
        status = RuntimeClient.snapshotCheckpointStatusString(checkpoint.status)
        title = checkpoint.title
        summary = checkpoint.summary
        briefPath = checkpoint.briefPath
        manifestPath = checkpoint.manifestPath
        mediaArtifacts = checkpoint.mediaArtifacts.map(SnapshotMediaArtifactPayload.init)
        mermaidSources = checkpoint.mermaidSources.map(SnapshotMermaidSourcePayload.init)
        captureStatus = RuntimeCaptureStatus(checkpoint.captureStatus)
        captureUrl = checkpoint.captureUrl
        captureClaim = checkpoint.captureClaim.map(SnapshotCaptureClaimPayload.init)
        createdAt = checkpoint.createdAt
        decidedAt = checkpoint.decidedAt
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
    let createdAt: String
    let updatedAt: String
    let activeCheckpoint: SnapshotCheckpointPayload?

    enum CodingKeys: String, CodingKey {
        case id
        case projectPath = "project_path"
        case methodId = "method_id"
        case methodName = "method_name"
        case status
        case sessionId = "session_id"
        case delegationWorkerId = "delegation_worker_id"
        case statusMessage = "status_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case activeCheckpoint = "active_checkpoint"
    }

    init(_ run: RunState) {
        id = run.id
        projectPath = run.projectPath
        methodId = run.methodId
        methodName = run.methodName
        status = RuntimeClient.snapshotRunStatusString(run.status)
        sessionId = run.sessionId
        delegationWorkerId = run.delegationWorkerId
        // Runtime-service JSON snapshots carry `status_message`; the older bridge
        // payload used here for fallback construction does not yet expose it.
        statusMessage = nil
        createdAt = run.createdAt
        updatedAt = run.updatedAt
        activeCheckpoint = run.activeCheckpoint.map(SnapshotCheckpointPayload.init)
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

struct RuntimeDelegationMutationRequest: Encodable {
    let kind: String
    let projectPath: String
    let workerId: String
    let ideaId: String?
    let worktreeName: String?
    let worktreePath: String?
    let sessionId: String?
    let milestoneId: String?
    let briefPath: String?
    let manifestPath: String?
    let reviewDecision: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case projectPath = "project_path"
        case workerId = "worker_id"
        case ideaId = "idea_id"
        case worktreeName = "worktree_name"
        case worktreePath = "worktree_path"
        case sessionId = "session_id"
        case milestoneId = "milestone_id"
        case briefPath = "brief_path"
        case manifestPath = "manifest_path"
        case reviewDecision = "review_decision"
        case note
    }
}

struct RuntimeRunMutationRequest: Encodable, Equatable, Sendable {
    let kind: String
    let projectPath: String
    let runId: String
    let checkpointId: String?
    let methodId: String?
    let involvement: String?
    let checkpointKind: RuntimeCheckpointKind?
    let checkpointTitle: String?
    let checkpointSummary: String?
    let checkpointBriefPath: String?
    let checkpointManifestPath: String?
    let checkpointMediaArtifacts: [RuntimeMediaArtifact]
    let checkpointMermaidSources: [RuntimeMermaidSource]
    let captureUrl: String?
    let decisionAction: String?
    let decisionNote: String?
    let sessionId: String?
    let delegationWorkerId: String?
    let statusMessage: String?
    let captureRequestId: String?
    let clientId: String?
    let observedCaptureUrl: String?
    let captureFailureReason: String?
    let completedMediaArtifacts: [RuntimeMediaArtifact]

    enum CodingKeys: String, CodingKey {
        case kind
        case projectPath = "project_path"
        case runId = "run_id"
        case checkpointId = "checkpoint_id"
        case methodId = "method_id"
        case involvement
        case checkpointKind = "checkpoint_kind"
        case checkpointTitle = "checkpoint_title"
        case checkpointSummary = "checkpoint_summary"
        case checkpointBriefPath = "checkpoint_brief_path"
        case checkpointManifestPath = "checkpoint_manifest_path"
        case checkpointMediaArtifacts = "checkpoint_media_artifacts"
        case checkpointMermaidSources = "checkpoint_mermaid_sources"
        case captureUrl = "capture_url"
        case decisionAction = "decision_action"
        case decisionNote = "decision_note"
        case sessionId = "session_id"
        case delegationWorkerId = "delegation_worker_id"
        case statusMessage = "status_message"
        case captureRequestId = "capture_request_id"
        case clientId = "client_id"
        case observedCaptureUrl = "observed_capture_url"
        case captureFailureReason = "capture_failure_reason"
        case completedMediaArtifacts = "completed_media_artifacts"
    }
}

enum RuntimeClientError: Error {
    case disabled
    case invalidResponse
    case timeout
    case runtimeUnavailable(String)
    case mutationRejected(String)
}

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
        let projectStates = mapProjectStates(snapshot)
        let sessions = mapSessions(snapshot)
        let runs = mapRuns(snapshot)
        guard let shellState = mapShellState(
            snapshot,
            correlationId: correlationId,
            operation: "fetchRuntimeSnapshot",
        ) else {
            throw RuntimeClientError.invalidResponse
        }

        let cid = correlationId ?? "none"
        DebugLog.write(
            "RuntimeClient.fetchRuntimeSnapshot source=\(runtimeSourceLabel) cid=\(cid) projects=\(projectStates.count) sessions=\(sessions.count) shells=\(shellState.shells.count) runs=\(runs.count)",
        )

        return RuntimeSnapshot(
            projectStates: projectStates,
            sessions: sessions,
            shellState: shellState,
            routingViews: mapRoutingViews(snapshot),
            delegations: mapDelegations(snapshot),
            runs: runs,
        )
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

    fileprivate static func snapshotDelegationStatusString(_ status: DelegationStatus) -> String {
        snakeCaseEnumCaseName(status)
    }

    fileprivate static func snapshotRunStatusString(_ status: RunStatus) -> String {
        snakeCaseEnumCaseName(status)
    }

    fileprivate static func snapshotCheckpointStatusString(_ status: CheckpointStatus) -> String {
        snakeCaseEnumCaseName(status)
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

    fileprivate static func snapshotMediaArtifactTypeString(_ type: MediaArtifactType) -> String {
        snakeCaseEnumCaseName(type)
    }

    fileprivate static func snapshotDelegationSubmittedMilestoneID(_ delegation: ProjectDelegationState) -> String? {
        guard let reflectedValue = Mirror(reflecting: delegation)
            .children
            .first(where: { $0.label == "submittedMilestoneId" })?
            .value
        else {
            return nil
        }
        return unwrapOptionalString(reflectedValue)
    }

    private static func snakeCaseEnumCaseName(_ value: some Any) -> String {
        let rawName = String(describing: value)
        guard !rawName.isEmpty else { return rawName }

        var result = ""
        result.reserveCapacity(rawName.count + 4)

        for character in rawName {
            if character.isUppercase, !result.isEmpty {
                result.append("_")
            }
            result.append(contentsOf: String(character).lowercased())
        }

        return result
    }

    private static func unwrapOptionalString(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }

        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return nil
        }

        return mirror.children.first?.value as? String
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

private extension RuntimeCaptureStatus {
    init(_ status: CaptureStatus) {
        switch status {
        case .notRequested:
            self = .notRequested
        case .pending:
            self = .pending
        case .inProgress:
            self = .inProgress
        case .completed:
            self = .completed
        case let .failed(reason):
            self = .failed(reason: reason)
        }
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

private extension RuntimeCheckpointState {
    init(_ payload: SnapshotCheckpointPayload) {
        id = payload.id
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
        createdAt = payload.createdAt
        updatedAt = payload.updatedAt
        activeCheckpoint = payload.activeCheckpoint.map(RuntimeCheckpointState.init)
    }
}
