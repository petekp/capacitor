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

struct RuntimeSession {
    let sessionId: String
    let pid: UInt32
    let state: SessionState
    let cwd: String
    let projectId: String?
    let workspaceId: String?
    let projectPath: String
    let updatedAt: String
    let stateChangedAt: String
    let lastEvent: String?
    let lastActivityAt: String?
    let toolsInFlight: Int?
    let stateSource: RuntimeStateSource?
    let lastAuthoritativeEventAt: String?
    let gcReason: String?
    let isAlive: Bool?
}

struct RuntimeStateSource: Decodable {
    let eventKind: String
    let authority: String
    let observedAt: String

    enum CodingKeys: String, CodingKey {
        case eventKind = "event_kind"
        case authority
        case observedAt = "observed_at"
    }
}

struct RuntimeProjectState {
    let projectId: String?
    let workspaceId: String?
    let projectPath: String
    let state: SessionState
    let updatedAt: String
    let stateChangedAt: String
    let sessionId: String?
    let latestSessionId: String?
    let sessionCount: Int
    let activeCount: Int
    let hasSession: Bool
}

struct RuntimeSnapshot {
    let projectStates: [RuntimeProjectState]
    let sessions: [RuntimeSession]
    let shellState: ShellCwdState
    let routingViews: [RuntimeRoutingView]
    let delegations: [RuntimeDelegationState]
    let runs: [RuntimeRunState]
    let changeVersion: UInt64
}

/// Response from the long-poll snapshot endpoint.
enum LongPollResponse {
    /// Snapshot changed and includes a full runtime snapshot payload.
    case changed(RuntimeSnapshot)
    /// Snapshot did not change before the server-side timeout elapsed.
    case unchanged(changeVersion: UInt64)
    /// The runtime service does not expose the long-poll endpoint yet.
    case unavailable
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

struct RuntimeDelegationState: Equatable {
    let projectPath: String
    let workerId: String
    let ideaId: String?
    let worktreeName: String
    let worktreePath: String
    let sessionId: String?
    let status: DelegationStatus
    let startedAt: String
    let updatedAt: String
    let submittedMilestoneId: String?
    let currentReview: RuntimeDelegationReview?

    init(
        projectPath: String,
        workerId: String,
        ideaId: String?,
        worktreeName: String,
        worktreePath: String,
        sessionId: String?,
        status: DelegationStatus,
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

enum RuntimeCheckpointKind: Equatable, Codable {
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

enum RuntimeCaptureStatus: Equatable {
    case notRequested
    case pending
    case inProgress
    case completed
    case failed(reason: String)
}

struct RuntimeCaptureClaim: Equatable {
    let captureRequestId: String
    let clientId: String
    let claimedAt: String
    let observedCaptureUrl: String?
}

struct RuntimeCheckpointDecision: Codable, Equatable {
    let action: String
    let note: String?
}

struct RuntimeMediaArtifact: Codable, Equatable {
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

struct RuntimeMermaidSource: Codable, Equatable {
    let label: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case label
        case source
    }
}

struct RuntimeCheckpointState: Equatable {
    let id: String
    let historyOrdinal: UInt64?
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
    let decision: RuntimeCheckpointDecision?
    let createdAt: String
    let decidedAt: String?

    init(
        id: String,
        historyOrdinal: UInt64? = nil,
        phaseId: String,
        kind: RuntimeCheckpointKind,
        status: String,
        title: String,
        summary: String?,
        briefPath: String?,
        manifestPath: String?,
        mediaArtifacts: [RuntimeMediaArtifact],
        mermaidSources: [RuntimeMermaidSource],
        captureStatus: RuntimeCaptureStatus,
        captureUrl: String?,
        captureClaim: RuntimeCaptureClaim?,
        decision: RuntimeCheckpointDecision? = nil,
        createdAt: String,
        decidedAt: String?,
    ) {
        self.id = id
        self.historyOrdinal = historyOrdinal
        self.phaseId = phaseId
        self.kind = kind
        self.status = status
        self.title = title
        self.summary = summary
        self.briefPath = briefPath
        self.manifestPath = manifestPath
        self.mediaArtifacts = mediaArtifacts
        self.mermaidSources = mermaidSources
        self.captureStatus = captureStatus
        self.captureUrl = captureUrl
        self.captureClaim = captureClaim
        self.decision = decision
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}

struct RuntimePhaseInstance: Equatable {
    let id: String
    let name: String
    let status: PhaseStatus
    let startedAt: String?
    let completedAt: String?
}

struct RuntimeRunState: Equatable {
    let id: String
    let projectPath: String
    let methodId: String
    let methodName: String
    let status: RunStatus
    let sessionId: String?
    let delegationWorkerId: String?
    let statusMessage: String?
    let phases: [RuntimePhaseInstance]
    let currentPhaseIndex: Int
    let createdAt: String
    let updatedAt: String
    let activeCheckpoint: RuntimeCheckpointState?
    let pastCheckpoints: [RuntimeCheckpointState]
    let ideaId: String?
    let ideaTitle: String?
    let ideaDescription: String?

    init(
        id: String,
        projectPath: String,
        methodId: String,
        methodName: String,
        status: RunStatus,
        sessionId: String?,
        delegationWorkerId: String?,
        statusMessage: String?,
        phases: [RuntimePhaseInstance] = [],
        currentPhaseIndex: Int = 0,
        createdAt: String,
        updatedAt: String,
        activeCheckpoint: RuntimeCheckpointState?,
        pastCheckpoints: [RuntimeCheckpointState] = [],
        ideaId: String?,
        ideaTitle: String?,
        ideaDescription: String?,
    ) {
        self.id = id
        self.projectPath = projectPath
        self.methodId = methodId
        self.methodName = methodName
        self.status = status
        self.sessionId = sessionId
        self.delegationWorkerId = delegationWorkerId
        self.statusMessage = statusMessage
        self.phases = phases
        self.currentPhaseIndex = currentPhaseIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activeCheckpoint = activeCheckpoint
        self.pastCheckpoints = pastCheckpoints
        self.ideaId = ideaId
        self.ideaTitle = ideaTitle
        self.ideaDescription = ideaDescription
    }
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
    let status: RoutingStatus
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

struct RuntimeRunMutationRequest: Encodable, Equatable {
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
    let ideaId: String?
    let ideaTitle: String?
    let ideaDescription: String?

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
        case ideaId = "idea_id"
        case ideaTitle = "idea_title"
        case ideaDescription = "idea_description"
    }
}

// MARK: - Per-kind factories

/// Each `RunMutationKind` only reads a handful of fields; the rest are nil/[]
/// padding on the wire. These static factories let call sites pass only the
/// fields their kind actually uses and fill every irrelevant field internally.
/// The produced request is byte-identical to the equivalent full memberwise
/// initializer (same `kind` string, same field values, same nils/empty arrays).
extension RuntimeRunMutationRequest {
    /// `create` — start a new method run from an idea.
    static func create(
        projectPath: String,
        runId: String,
        methodId: String?,
        involvement: String? = nil,
        ideaId: String?,
        ideaTitle: String?,
        ideaDescription: String?,
    ) -> RuntimeRunMutationRequest {
        RuntimeRunMutationRequest(
            kind: "create",
            projectPath: projectPath,
            runId: runId,
            checkpointId: nil,
            methodId: methodId,
            involvement: involvement,
            checkpointKind: nil,
            checkpointTitle: nil,
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: nil,
            decisionAction: nil,
            decisionNote: nil,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            captureRequestId: nil,
            clientId: nil,
            observedCaptureUrl: nil,
            captureFailureReason: nil,
            completedMediaArtifacts: [],
            ideaId: ideaId,
            ideaTitle: ideaTitle,
            ideaDescription: ideaDescription,
        )
    }

    /// `submit_decision` — record a reviewer decision on a checkpoint.
    static func submitDecision(
        projectPath: String,
        runId: String,
        checkpointId: String?,
        decisionAction: String?,
        decisionNote: String?,
    ) -> RuntimeRunMutationRequest {
        RuntimeRunMutationRequest(
            kind: "submit_decision",
            projectPath: projectPath,
            runId: runId,
            checkpointId: checkpointId,
            methodId: nil,
            involvement: nil,
            checkpointKind: nil,
            checkpointTitle: nil,
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: nil,
            decisionAction: decisionAction,
            decisionNote: decisionNote,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            captureRequestId: nil,
            clientId: nil,
            observedCaptureUrl: nil,
            captureFailureReason: nil,
            completedMediaArtifacts: [],
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    /// `capture_claim` — claim ownership of a pending capture request.
    static func captureClaim(
        projectPath: String,
        runId: String,
        checkpointId: String?,
        captureRequestId: String?,
        clientId: String?,
        observedCaptureUrl: String?,
    ) -> RuntimeRunMutationRequest {
        RuntimeRunMutationRequest(
            kind: "capture_claim",
            projectPath: projectPath,
            runId: runId,
            checkpointId: checkpointId,
            methodId: nil,
            involvement: nil,
            checkpointKind: nil,
            checkpointTitle: nil,
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: nil,
            decisionAction: nil,
            decisionNote: nil,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            captureRequestId: captureRequestId,
            clientId: clientId,
            observedCaptureUrl: observedCaptureUrl,
            captureFailureReason: nil,
            completedMediaArtifacts: [],
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    /// `capture_failed` — report a failed capture attempt.
    static func captureFailed(
        projectPath: String,
        runId: String,
        checkpointId: String?,
        captureRequestId: String?,
        captureFailureReason: String?,
    ) -> RuntimeRunMutationRequest {
        RuntimeRunMutationRequest(
            kind: "capture_failed",
            projectPath: projectPath,
            runId: runId,
            checkpointId: checkpointId,
            methodId: nil,
            involvement: nil,
            checkpointKind: nil,
            checkpointTitle: nil,
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: nil,
            decisionAction: nil,
            decisionNote: nil,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            captureRequestId: captureRequestId,
            clientId: nil,
            observedCaptureUrl: nil,
            captureFailureReason: captureFailureReason,
            completedMediaArtifacts: [],
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    /// `capture_complete` — finalize a capture with its media artifacts.
    static func captureComplete(
        projectPath: String,
        runId: String,
        checkpointId: String?,
        captureRequestId: String?,
        completedMediaArtifacts: [RuntimeMediaArtifact],
    ) -> RuntimeRunMutationRequest {
        RuntimeRunMutationRequest(
            kind: "capture_complete",
            projectPath: projectPath,
            runId: runId,
            checkpointId: checkpointId,
            methodId: nil,
            involvement: nil,
            checkpointKind: nil,
            checkpointTitle: nil,
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: nil,
            decisionAction: nil,
            decisionNote: nil,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            captureRequestId: captureRequestId,
            clientId: nil,
            observedCaptureUrl: nil,
            captureFailureReason: nil,
            completedMediaArtifacts: completedMediaArtifacts,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    /// Status-family kinds (`start`/`heartbeat`/`pause`/`resume`/`complete`/`fail`/`cancel`)
    /// that carry at most a free-form `statusMessage`. The caller passes the wire
    /// `kind` string verbatim; all checkpoint/capture/idea fields are nil/[].
    static func status(
        kind: String,
        projectPath: String,
        runId: String,
        statusMessage: String? = nil,
    ) -> RuntimeRunMutationRequest {
        RuntimeRunMutationRequest(
            kind: kind,
            projectPath: projectPath,
            runId: runId,
            checkpointId: nil,
            methodId: nil,
            involvement: nil,
            checkpointKind: nil,
            checkpointTitle: nil,
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: nil,
            decisionAction: nil,
            decisionNote: nil,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: statusMessage,
            captureRequestId: nil,
            clientId: nil,
            observedCaptureUrl: nil,
            captureFailureReason: nil,
            completedMediaArtifacts: [],
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }
}

enum RuntimeClientError: Error {
    case disabled
    case invalidResponse
    case timeout
    case runtimeUnavailable(String)
    case mutationRejected(String)
}
