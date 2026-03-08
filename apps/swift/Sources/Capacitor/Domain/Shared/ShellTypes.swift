import Foundation

struct ShellProjectReference: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let path: String
    let workspaceId: String?

    init(
        id: String? = nil,
        displayName: String,
        path: String,
        workspaceId: String? = nil,
    ) {
        self.id = id ?? path
        self.displayName = displayName
        self.path = path
        self.workspaceId = workspaceId
    }
}

extension ShellProjectCatalogEntry: @unchecked Sendable {}
extension ShellProjectCatalogEntry {
    init(
        id: String? = nil,
        displayName: String,
        path: String,
        displayPath: String? = nil,
        lastActiveAt: String? = nil,
        claudeMdPath: String? = nil,
        claudeMdPreview: String? = nil,
        hasLocalSettings: Bool = false,
        taskCount: UInt32 = 0,
        stats: ShellProjectStats? = nil,
        isMissing: Bool = false,
    ) {
        self.init(
            id: id ?? path,
            displayName: displayName,
            path: path,
            displayPath: displayPath ?? path,
            lastActiveAt: lastActiveAt,
            claudeMdPath: claudeMdPath,
            claudeMdPreview: claudeMdPreview,
            hasLocalSettings: hasLocalSettings,
            taskCount: taskCount,
            stats: stats,
            isMissing: isMissing,
        )
    }
}

extension ShellProjectStats: @unchecked Sendable {}

extension ShellSuggestedProjectCandidate: @unchecked Sendable {}
extension ShellSuggestedProjectCandidate {
    init(
        id: String? = nil,
        displayName: String,
        path: String,
        displayPath: String? = nil,
        taskCount: UInt32 = 0,
        hasClaudeMd: Bool = false,
        hasProjectIndicators: Bool = false,
    ) {
        self.init(
            id: id ?? path,
            displayName: displayName,
            path: path,
            displayPath: displayPath ?? path,
            taskCount: taskCount,
            hasClaudeMd: hasClaudeMd,
            hasProjectIndicators: hasProjectIndicators,
        )
    }
}

enum ShellProjectValidationKind: String, Hashable, Sendable {
    case valid
    case suggestParent
    case missingClaudeMd
    case notAProject
    case alreadyTracked
    case pathNotFound
    case dangerousPath
    case unknown
}

struct ShellProjectValidationResult: Hashable, Sendable {
    let kind: ShellProjectValidationKind
    let path: String
    let suggestedPath: String?
    let reason: String?
    let hasClaudeMd: Bool
    let hasOtherMarkers: Bool
}

struct ShellRuntimeProjection: Sendable {
    let generatedAt: Date
    let activeProject: ShellProjectReference?
    let projects: [ShellProjectReference]
    let sessionsInFlight: Int
    let healthSummary: String
}

struct ShellRuntimeObservation: Sendable {
    let projectStates: [RuntimeProjectState]
    let sessions: [RuntimeSession]
    let shellState: ShellCwdState
}

struct ShellRuntimeHealthStatus: Sendable {
    let isEnabled: Bool
    let isHealthy: Bool
    let message: String
    let pid: Int?
    let version: String?
    let routingRollout: RuntimeRoutingRollout?
}

enum ShellSetupStage: String, Sendable {
    case unknown
    case ready
    case needsAttention
}

struct ShellSetupReadiness: Sendable {
    let stage: ShellSetupStage
    let blockingReason: String?
    let missingDependencies: [String]
    let hookState: String
}

struct ShellActivationRequest: Sendable {
    let project: ShellProjectReference
    let preferredSessionName: String?
    let source: String
}

enum ShellActivationDisposition: String, Sendable {
    case routed
    case launched
    case deferred
    case unavailable
}

struct ShellActivationDecision: Sendable {
    let disposition: ShellActivationDisposition
    let project: ShellProjectReference
    let reason: String
}

struct ShellIdeaDraft: Identifiable, Equatable, Sendable {
    let id: String
    var project: ShellProjectReference?
    var title: String
    var details: String

    static let empty = ShellIdeaDraft(
        id: UUID().uuidString.lowercased(),
        project: nil,
        title: "",
        details: "",
    )
}

enum ShellFeedbackCategory: String, Sendable {
    case bug
    case ux
    case feature
    case question
    case other
}

struct ShellFeedbackDraft: Equatable, Sendable {
    var category: ShellFeedbackCategory
    var project: ShellProjectReference?
    var summary: String
    var details: String
    var includeTelemetry: Bool

    static let empty = ShellFeedbackDraft(
        category: .other,
        project: nil,
        summary: "",
        details: "",
        includeTelemetry: true,
    )
}

enum ShellFeedbackStatus: String, Sendable {
    case submitted
    case deferred
}

struct ShellFeedbackReceipt: Equatable, Sendable {
    let feedbackID: String
    let status: ShellFeedbackStatus
    let note: String
}

enum ShellNavigationDestination: Hashable, Sendable {
    case projectList
    case projectDetail(projectID: String)
    case newIdea
    case setup
}
