import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum LayoutMode: String, CaseIterable {
    case vertical
    case dock
}

enum ProjectView: Equatable {
    case list
    case detail(Project)
    case delegationReview(Project)

    static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list):
            true
        case let (.detail(p1), .detail(p2)):
            p1.path == p2.path
        case let (.delegationReview(p1), .delegationReview(p2)):
            p1.path == p2.path
        default:
            false
        }
    }
}

enum AppFeatureError: LocalizedError {
    case ideaCaptureDisabled
    case projectDetailsDisabled

    var errorDescription: String? {
        switch self {
        case .ideaCaptureDisabled:
            "Idea capture is disabled for this build."
        case .projectDetailsDisabled:
            "Project details are disabled for this build."
        }
    }
}

struct RuntimeRunKey: Hashable, Sendable {
    let normalizedProjectPath: String
    let runID: String

    init(run: RuntimeRunState) {
        normalizedProjectPath = PathNormalizer.normalize(run.projectPath)
        runID = run.id
    }

    init(projectPath: String, runID: String) {
        normalizedProjectPath = PathNormalizer.normalize(projectPath)
        self.runID = runID
    }
}

/// Trims whitespace and clamps idea descriptions to 500 characters for run context.
func compactRunIdeaDescription(_ description: String?) -> String? {
    guard let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines),
          !desc.isEmpty
    else {
        return nil
    }
    if desc.count <= 500 {
        return desc
    }
    return String(desc.prefix(497)) + "..."
}

@Observable
@MainActor
class AppState {
    // MARK: - Layout Mode

    var layoutMode: LayoutMode = .vertical {
        didSet { saveLayoutMode() }
    }

    // MARK: - Build Channel + Feature Flags

    private(set) var channel: AppChannel = AppConfig.defaultChannel
    private(set) var profile: AppProfile = .stable
    private(set) var featureFlags: FeatureFlags = .defaults(for: .stable)
    private(set) var routingRollout: RuntimeRoutingRollout?

    var isIdeaCaptureEnabled: Bool {
        featureFlags.ideaCapture
    }

    var isProjectDetailsEnabled: Bool {
        featureFlags.projectDetails
    }

    var isWorkstreamsEnabled: Bool {
        featureFlags.workstreams && isProjectDetailsEnabled
    }

    var isProjectCreationEnabled: Bool {
        featureFlags.projectCreation
    }

    var isLlmFeaturesEnabled: Bool {
        featureFlags.llmFeatures && isProjectDetailsEnabled
    }

    var isDelegationLoopEnabled: Bool {
        featureFlags.delegationLoop && isProjectDetailsEnabled
    }

    var isMethodRunnerEnabled: Bool {
        featureFlags.methodRunner && isProjectDetailsEnabled
    }

    var isWindowAnchoringEnabled: Bool {
        featureFlags.windowAnchoring
    }

    // MARK: - Navigation

    var projectView: ProjectView = .list

    // MARK: - Review Window

    struct ReviewWindowTarget: Equatable {
        let projectPath: String
        let workerID: String
    }

    struct RunCheckpointWindowTarget: Equatable {
        let projectPath: String
        let runID: String
        let checkpointID: String
    }

    var reviewWindowTarget: ReviewWindowTarget?
    var runCheckpointWindowTarget: RunCheckpointWindowTarget?

    // MARK: - Data

    var dashboard: DashboardData?
    var projects: [Project] = []
    var suggestedProjects: [SuggestedProject] = []
    var selectedSuggestedPaths: Set<String> = []

    // MARK: - Active project creations (Idea → V1)

    var activeCreations: [ProjectCreation] = []
    private(set) var delegationStates: [String: RuntimeDelegationState] = [:]
    private(set) var runStatesByID: [RuntimeRunKey: RuntimeRunState] = [:]

    // MARK: - Cached Project Statuses (avoids FFI call per card per render)

    private(set) var projectStatuses: [String: ProjectStatus] = [:]

    // MARK: - UI State

    var isLoading = true
    var error: String?
    var toast: ToastMessage?
    var pendingDragDropTip = false

    /// Set by card-level DropDelegates when a file URL drag hovers over a project card.
    /// Complements ContentView's `isDragHovered` (which only fires between cards).
    var isFileDragOverCard = false

    // MARK: - Hook Diagnostic

    var hookDiagnostic: HookDiagnosticReport?

    // MARK: - Activation Trace (Debug)

    var activationTrace: String?

    // MARK: - Runtime Diagnostic

    var runtimeStatus: RuntimeStatus?

    // MARK: - Manual dormant overrides

    var manuallyDormant: Set<String> = [] {
        didSet { saveDormantOverrides() }
    }

    // MARK: - Custom project ordering (single global order)

    var projectOrder: [String] = [] {
        didSet { saveProjectOrder() }
    }

    /// Tracks last-known activity group per project path for transition detection.
    private var previousActivityGroup: [String: ActivityGroup] = [:]

    // MARK: - Modal State for Idea Capture

    var showCaptureModal = false
    var captureModalProject: Project?
    var captureModalOrigin: CGRect?

    // MARK: - Managers (extracted for cleaner architecture)

    let anchoringController = WindowAnchoringController()
    let shellStateStore = ShellStateStore()
    let routingStateStore = RoutingStateStore()
    let terminalLauncher = TerminalLauncher()
    let sessionStateManager = SessionStateManager()
    let hookServerManager: HookServerManager
    let projectDetailsManager = ProjectDetailsManager()
    private(set) var delegationLoopManager: DelegationLoopManager!
    let runCaptureCoordinator: RunCaptureCoordinator
    private let projectIngestionWorker = ProjectIngestionWorker()
    private(set) var projectCreationCoordinator: ProjectCreationCoordinator!
    private(set) var projectFeatureCoordinator: ProjectFeatureCoordinator!
    @ObservationIgnored
    lazy var workstreamsManager: WorkstreamsManager = .init(
        openWorktree: { [weak self] worktreeProject in
            self?.launchTerminal(for: worktreeProject)
        },
        activeWorktreePathsProvider: { [weak self] in
            self?.activeWorktreePathsForGuardrails() ?? []
        },
    )

    private(set) var activeProjectResolver: ActiveProjectResolver!

    // MARK: - Private State

    private let layoutModeKey = "layoutMode"
    private let activationPolicy = ActivationPolicy()
    private let runtimeClient: RuntimeClient
    private var methodRunCoordinator: MethodRunCoordinator?
    private var engine: CoreRuntime?
    private var refreshTimer: Timer?
    private var runtimeBootstrapTask: _Concurrency.Task<Void, Never>?
    private var runtimeSnapshotTask: _Concurrency.Task<Void, Never>?
    private var runtimeSnapshotGeneration: UInt64 = 0
    private var runtimeSnapshotCorrelationCounter: UInt64 = 0
    private var consecutiveRuntimeSnapshotFailures = 0
    private(set) var sessionStateRevision = 0
    private(set) var didShutdownForTesting = false
    #if DEBUG
        private(set) var runtimeBootstrapTraceForTesting: [String] = []
    #endif
    private var isShuttingDown = false

    // MARK: - Computed Properties (bridging to managers)

    var activeProjectPath: String? {
        activeProjectResolver?.activeProject?.path
    }

    var activeSource: ActiveSource {
        activeProjectResolver?.activeSource ?? .none
    }

    var methodRunnerRuntimeClient: RuntimeClient {
        runtimeClient
    }

    var methodRunnerCoordinator: MethodRunCoordinator? {
        methodRunCoordinator
    }

    var methodRunnerEngine: CoreRuntime? {
        engine
    }

    func setDelegationState(
        _ state: RuntimeDelegationState,
        forNormalizedProjectPath normalizedProjectPath: String,
    ) {
        delegationStates[normalizedProjectPath] = state
    }

    // MARK: - Initialization

    init(
        runtimeClient: RuntimeClient = RuntimeClient.shared,
        hookServerManager: HookServerManager = HookServerManager(),
    ) {
        self.runtimeClient = runtimeClient
        self.hookServerManager = hookServerManager
        runCaptureCoordinator = RunCaptureCoordinator(runtimeClient: runtimeClient)
        methodRunCoordinator = MethodRunCoordinator(mutateRun: { request in
            try await runtimeClient.mutateRun(request)
        })
        self.runtimeClient.setIncompatibleSchemaHandler { [weak self] health, minimumSchemaVersion in
            guard let self else { return }
            await MainActor.run {
                self.handleIncompatibleRuntimeServiceSchema(
                    observedSchemaVersion: health.normalizedSchemaVersion,
                    minimumSchemaVersion: minimumSchemaVersion,
                )
            }
        }
        DebugLog.write(
            "AppState.init start runtimeEnabled=\(runtimeClient.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
        )
        let config = AppConfig.current()
        #if DEBUG
            AlphaChannelGuardrail.enforceOrExit(channel: config.channel)
        #endif
        channel = config.channel
        profile = config.profile
        DebugLog.write("AppState.init config channel=\(channel.rawValue) profile=\(profile.rawValue)")
        featureFlags = config.featureFlags
        refreshAERoutingRuntimeFlags(with: nil)
        loadLayoutMode()
        loadDormantOverrides()
        loadProjectOrder()

        activeProjectResolver = ActiveProjectResolver(
            sessionStateManager: sessionStateManager,
        )
        terminalLauncher.activationIntentResolver = { [weak self] clientTty, projectPath, sessionName in
            guard let self else {
                return ActivationPolicy().resolveIntent(
                    projectPath: projectPath,
                    clientTty: clientTty,
                    sessionName: sessionName,
                    route: nil,
                )
            }

            let route = if let cachedRoute = routingStateStore.routingView(
                projectPath: projectPath,
                workspaceId: nil,
            ) {
                cachedRoute
            } else {
                await resolveActivationRoute(
                    projectPath: projectPath,
                    clientTty: clientTty,
                    sessionName: sessionName,
                )
            }
            return activationPolicy.resolveIntent(
                projectPath: projectPath,
                clientTty: clientTty,
                sessionName: sessionName,
                route: route,
            )
        }
        projectCreationCoordinator = ProjectCreationCoordinator(
            ideaCaptureEnabled: { [weak self] in
                self?.isIdeaCaptureEnabled ?? false
            },
            readCreations: { [weak self] in
                self?.activeCreations ?? []
            },
            writeCreations: { [weak self] creations in
                self?.activeCreations = creations
            },
            engineProvider: { [weak self] in
                self?.engine
            },
            dashboardReloader: { [weak self] in
                self?.loadDashboard()
            },
        )
        delegationLoopManager = DelegationLoopManager(runtimeClient: runtimeClient)
        projectFeatureCoordinator = ProjectFeatureCoordinator(
            projectDetailsEnabled: { [weak self] in
                self?.isProjectDetailsEnabled ?? false
            },
            ideaCaptureEnabled: { [weak self] in
                self?.isIdeaCaptureEnabled ?? false
            },
            llmFeaturesEnabled: { [weak self] in
                self?.isLlmFeaturesEnabled ?? false
            },
            writeProjectView: { [weak self] in
                self?.projectView = $0
            },
            writeCaptureModalProject: { [weak self] in
                self?.captureModalProject = $0
            },
            writeCaptureModalOrigin: { [weak self] in
                self?.captureModalOrigin = $0
            },
            writeShowCaptureModal: { [weak self] in
                self?.showCaptureModal = $0
            },
            writeError: { [weak self] in
                self?.error = $0
            },
            captureIdeaHandler: { [weak self] project, text in
                self?.projectDetailsManager.captureIdea(for: project, text: text) ?? .failure(AppFeatureError.ideaCaptureDisabled)
            },
            checkIdeasFileChangesHandler: { [weak self] projects in
                self?.projectDetailsManager.checkIdeasFileChanges(for: projects)
            },
            getIdeasHandler: { [weak self] project in
                self?.projectDetailsManager.getIdeas(for: project) ?? []
            },
            isGeneratingTitleHandler: { [weak self] ideaId in
                self?.projectDetailsManager.isGeneratingTitle(for: ideaId) ?? false
            },
            dismissIdeaHandler: { [weak self] idea, project in
                try self?.projectDetailsManager.updateIdeaStatus(for: project, idea: idea, newStatus: "done")
            },
            reorderIdeasHandler: { [weak self] ideas, project in
                self?.projectDetailsManager.reorderIdeas(ideas, for: project)
            },
            getDescriptionHandler: { [weak self] project in
                self?.projectDetailsManager.getDescription(for: project)
            },
            isGeneratingDescriptionHandler: { [weak self] project in
                self?.projectDetailsManager.isGeneratingDescription(for: project) ?? false
            },
            generateDescriptionHandler: { [weak self] project in
                self?.projectDetailsManager.generateDescription(for: project)
            },
        )
        sessionStateManager.onVisualStateChanged = { [weak self] in
            guard let self else { return }
            sessionStateRevision &+= 1
        }

        terminalLauncher.onActivationResult = { [weak self] result in
            guard let self else { return }
            if !result.success {
                toast = ToastMessage(
                    result.failureReason?.userMessage ?? "Couldn't activate terminal.",
                    isError: true,
                )
            }
        }

        if isIdeaCaptureEnabled {
            loadCreations()
        }

        scheduleRuntimeBootstrap()
    }

    private func scheduleRuntimeBootstrap() {
        // Phase 2: Defer runtime bootstrap work past first SwiftUI render.
        runtimeBootstrapTask?.cancel()
        runtimeBootstrapTask = _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard !_Concurrency.Task.isCancelled else { return }
                engine = try CoreRuntime()
                recordRuntimeBootstrapStepForTesting("createCoreRuntime")
                guard !_Concurrency.Task.isCancelled else { return }

                recordRuntimeBootstrapStepForTesting("startHookServer")
                hookServerManager.startIfNeeded()
                guard !_Concurrency.Task.isCancelled else { return }

                recordRuntimeBootstrapStepForTesting("ensureRuntimeReady")
                ensureRuntimeReady()
                guard !_Concurrency.Task.isCancelled else { return }

                projectDetailsManager.configure(engine: engine)
                loadDashboard()
                guard !_Concurrency.Task.isCancelled else { return }
                checkHookDiagnostic()
                setupRefreshTimer()
                startShellTracking()
            } catch {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        didShutdownForTesting = true

        runtimeBootstrapTask?.cancel()
        runtimeBootstrapTask = nil
        runtimeSnapshotTask?.cancel()
        runtimeSnapshotTask = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        hookServerManager.stop()
    }

    // MARK: - Setup

    private var hookHealthCheckCounter = 0
    private var hookServerHealthCounter = 0
    private var statsRefreshCounter = 0
    private var runtimeHealthCheckCounter = 0

    private func setupRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.refreshSessionStates()
                if self.isIdeaCaptureEnabled {
                    self.checkIdeasFileChanges()
                }

                // Check hook diagnostic every ~10 seconds
                self.hookHealthCheckCounter += 1
                if self.hookHealthCheckCounter >= 5 {
                    self.hookHealthCheckCounter = 0
                    self.checkHookDiagnostic()
                }

                // Check hook server health every ~10 seconds
                self.hookServerHealthCounter += 1
                if self.hookServerHealthCounter >= 5 {
                    self.hookServerHealthCounter = 0
                    self.hookServerManager.checkHealth()
                }

                // Check runtime health every ~16 seconds
                self.runtimeHealthCheckCounter += 1
                if self.runtimeHealthCheckCounter >= 8 {
                    self.runtimeHealthCheckCounter = 0
                    self.checkRuntimeHealth()
                }

                // Refresh stats (including latestSummary from JSONL) every ~30 seconds
                self.statsRefreshCounter += 1
                if self.statsRefreshCounter >= 15 {
                    self.statsRefreshCounter = 0
                    self.loadDashboard()
                }
            }
        }
    }

    private func startShellTracking() {
        activeProjectResolver.updateProjects(projects)
    }

    // MARK: - Data Loading

    func loadDashboard(hydrateIdeas: Bool = true, showLoadingState: Bool = true) {
        guard let engine else { return }
        if showLoadingState {
            isLoading = true
        }

        do {
            dashboard = try engine.loadDashboard()
            projects = dashboard?.projects ?? []
            if projects.isEmpty, suggestedProjects.isEmpty {
                refreshSuggestedProjects()
            } else if !projects.isEmpty, !suggestedProjects.isEmpty {
                suggestedProjects = []
                selectedSuggestedPaths = []
            }
            activeProjectResolver.updateProjects(projects)
            refreshSessionStates()
            if hydrateIdeas, isIdeaCaptureEnabled {
                projectDetailsManager.loadAllIdeas(for: projects)
            }
            if showLoadingState {
                isLoading = false
            }
        } catch {
            self.error = error.localizedDescription
            if showLoadingState {
                isLoading = false
            }
        }
    }

    func refreshSessionStates() {
        refreshProjectStatuses()
        runtimeSnapshotGeneration &+= 1
        let refreshGeneration = runtimeSnapshotGeneration
        let correlationId = nextRuntimeSnapshotCorrelationId()
        let currentProjects = projects
        runtimeSnapshotTask?.cancel()
        runtimeSnapshotTask = _Concurrency.Task { [weak self] in
            guard let self else { return }

            do {
                let snapshot = try await runtimeClient.fetchRuntimeSnapshot(correlationId: correlationId)
                guard !_Concurrency.Task.isCancelled else { return }

                await applyRuntimeSnapshotIfFresh(
                    snapshot,
                    refreshGeneration: refreshGeneration,
                    correlationId: correlationId,
                    projects: currentProjects,
                )
            } catch {
                await MainActor.run {
                    self.handleRuntimeSnapshotFailureIfFresh(
                        refreshGeneration: refreshGeneration,
                        correlationId: correlationId,
                        errorDescription: String(describing: error),
                    )
                }
            }
        }
    }

    @MainActor
    private func applyRuntimeSnapshotIfFresh(
        _ snapshot: RuntimeSnapshot,
        refreshGeneration: UInt64,
        correlationId: String,
        projects: [Project],
    ) async {
        guard refreshGeneration == runtimeSnapshotGeneration else {
            DebugLog.write(
                "AppState.refreshSessionStates source=runtime_snapshot_drop_stale cid=\(correlationId) generation=\(refreshGeneration) current=\(runtimeSnapshotGeneration)",
            )
            return
        }

        guard !_Concurrency.Task.isCancelled else { return }

        sessionStateManager.applyRuntimeProjectStates(
            snapshot.projectStates,
            for: projects,
            correlationId: correlationId,
        )
        shellStateStore.applyRuntimeShellState(
            snapshot.shellState,
            correlationId: correlationId,
        )
        routingStateStore.applyRuntimeRoutingViews(
            snapshot.routingViews,
            correlationId: correlationId,
        )
        if isDelegationLoopEnabled {
            let nextDelegations = Dictionary(
                uniqueKeysWithValues: snapshot.delegations.map {
                    (PathNormalizer.normalize($0.projectPath), $0)
                },
            )
            if nextDelegations != delegationStates {
                delegationStates = nextDelegations
            }
        } else if !delegationStates.isEmpty {
            delegationStates = [:]
        }
        let nextRunsByID = Dictionary(
            snapshot.runs.map { (RuntimeRunKey(run: $0), $0) },
            uniquingKeysWith: { existing, incoming in
                DebugLog.write(
                    "AppState.refreshSessionStates duplicate RuntimeRunKey for run=\(incoming.id) projectPath=\(incoming.projectPath) — keeping first",
                )
                return existing
            },
        )
        let previousRunsByID = runStatesByID
        if nextRunsByID != runStatesByID {
            runStatesByID = nextRunsByID
        }
        reconcileRunCheckpointWindowTarget(
            previousRunsByID: previousRunsByID,
            nextRunsByID: nextRunsByID,
        )
        consecutiveRuntimeSnapshotFailures = 0

        DebugLog.write(
            "AppState.refreshSessionStates source=runtime_snapshot_apply cid=\(correlationId) projects=\(snapshot.projectStates.count) sessions=\(snapshot.sessions.count) shells=\(snapshot.shellState.shells.count) routing=\(snapshot.routingViews.count) runs=\(snapshot.runs.count)",
        )
        if isDelegationLoopEnabled {
            _Concurrency.Task { [delegationLoopManager] in
                await delegationLoopManager?.reconcile(delegations: snapshot.delegations)
            }
        }
        _Concurrency.Task { [runCaptureCoordinator] in
            await runCaptureCoordinator.reconcile(runs: snapshot.runs)
        }
        updatePostSessionRefreshContext()
    }

    @MainActor
    private func handleRuntimeSnapshotFailureIfFresh(
        refreshGeneration: UInt64,
        correlationId: String,
        errorDescription: String,
    ) {
        guard refreshGeneration == runtimeSnapshotGeneration else {
            DebugLog.write(
                "AppState.refreshSessionStates source=runtime_snapshot_error_drop_stale cid=\(correlationId) generation=\(refreshGeneration) current=\(runtimeSnapshotGeneration)",
            )
            return
        }

        consecutiveRuntimeSnapshotFailures += 1
        DebugLog.write(
            "AppState.refreshSessionStates source=runtime_snapshot_error cid=\(correlationId) failures=\(consecutiveRuntimeSnapshotFailures) error=\(errorDescription)",
        )

        if consecutiveRuntimeSnapshotFailures >= 2 {
            DebugLog.write(
                "AppState.refreshSessionStates source=runtime_snapshot_error_clear cid=\(correlationId) failures=\(consecutiveRuntimeSnapshotFailures)",
            )
            sessionStateManager.clearRuntimeProjectStates()
            shellStateStore.clearRuntimeShellState(correlationId: correlationId)
            routingStateStore.clearRuntimeRoutingViews(correlationId: correlationId)
            delegationStates = [:]
            runCheckpointWindowTarget = nil
        }

        updatePostSessionRefreshContext()
    }

    #if DEBUG
        func applyRuntimeSnapshotForTesting(
            _ snapshot: RuntimeSnapshot,
            refreshGeneration: UInt64,
            correlationId: String,
            projects: [Project],
        ) async {
            await applyRuntimeSnapshotIfFresh(
                snapshot,
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                projects: projects,
            )
        }

        func setRuntimeSnapshotGenerationForTesting(_ generation: UInt64) {
            runtimeSnapshotGeneration = generation
        }

        func handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: UInt64,
            correlationId: String,
            errorDescription: String,
        ) {
            handleRuntimeSnapshotFailureIfFresh(
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                errorDescription: errorDescription,
            )
        }

        func cancelRuntimeAutomationForTesting() {
            runtimeBootstrapTask?.cancel()
            runtimeBootstrapTask = nil
            runtimeSnapshotTask?.cancel()
            runtimeSnapshotTask = nil
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    #endif

    private func nextRuntimeSnapshotCorrelationId() -> String {
        runtimeSnapshotCorrelationCounter &+= 1
        return "app-snap-\(runtimeSnapshotCorrelationCounter)"
    }

    private func updatePostSessionRefreshContext() {
        activeProjectResolver.resolve()
        reconcileProjectGroups()
        DiagnosticsSnapshotLogger.updateContext(
            activeProjectPath: activeProjectPath,
            activeSource: activeSource,
        )
        DebugLog.write("AppState.refreshSessionStates activeProject=\(activeProjectResolver.activeProject?.path ?? "nil") source=\(String(describing: activeProjectResolver.activeSource))")
        if let active = activeProjectResolver.activeProject {
            Telemetry.emit("active_project_resolution", "Resolved active project", payload: [
                "project": active.name,
                "path": active.path,
                "source": String(describing: activeProjectResolver.activeSource),
            ])
        } else {
            Telemetry.emit("active_project_resolution", "No active project", payload: [
                "source": String(describing: activeProjectResolver.activeSource),
            ])
        }
    }

    // MARK: - Hook Diagnostic

    func checkHookDiagnostic() {
        guard let engine else { return }
        hookDiagnostic = engine.getHookDiagnostic()
    }

    func fixHooks() {
        guard let engine else { return }

        if let hookInstallError = HookInstaller.ensureHooksInstalled(using: engine) {
            toast = ToastMessage(hookInstallError, isError: true)
            return
        }

        checkHookDiagnostic()
        if hookDiagnostic?.isHealthy == true {
            toast = ToastMessage("Hooks repaired")
        }
    }

    func testHooks() -> HookTestResult {
        guard let engine else {
            return HookTestResult(
                success: false,
                hookActivityOk: false,
                hookActivityAgeSecs: nil,
                runtimeServiceOk: false,
                message: "Engine not initialized",
            )
        }
        return engine.runHookTest()
    }

    // MARK: - Runtime Diagnostic

    func ensureRuntimeReady() {
        // Hard cutover mode: live runtime state comes from the local runtime service.
        // No legacy launchd lifecycle orchestration remains in AppState.
        checkRuntimeHealth()
    }

    func checkRuntimeHealth() {
        guard runtimeClient.isEnabled else {
            runtimeStatus = RuntimeStatus(
                isEnabled: false,
                isHealthy: false,
                message: "Runtime disabled",
                pid: nil,
                version: nil,
            )
            refreshAERoutingRuntimeFlags(with: nil)
            Telemetry.emit("runtime_health", "Runtime disabled", payload: [
                "enabled": false,
            ])
            return
        }

        _Concurrency.Task { [weak self] in
            do {
                guard let self else { return }
                let health = try await runtimeClient.fetchHealth()
                await MainActor.run {
                    self.runtimeStatus = RuntimeStatus(
                        isEnabled: true,
                        isHealthy: health.isCompatibleBootstrapService,
                        message: "Local runtime service healthy",
                        pid: health.pid,
                        version: health.version,
                    )
                    self.refreshAERoutingRuntimeFlags(with: health)
                    Telemetry.emit("runtime_health", "Runtime healthy", payload: [
                        "enabled": true,
                        "healthy": true,
                        "pid": health.pid,
                        "version": health.version,
                    ])
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.runtimeStatus = RuntimeStatus(
                        isEnabled: true,
                        isHealthy: false,
                        message: "Local runtime service unavailable",
                        pid: nil,
                        version: nil,
                    )
                    self.refreshAERoutingRuntimeFlags(with: nil)
                    Telemetry.emit("runtime_health", "Runtime unhealthy", payload: [
                        "enabled": true,
                        "healthy": false,
                        "error": String(describing: error),
                    ])
                }
            }
        }
    }

    private func handleIncompatibleRuntimeServiceSchema(
        observedSchemaVersion: Int,
        minimumSchemaVersion: Int,
    ) {
        DebugLog.write(
            "Runtime service schema version \(observedSchemaVersion) is older than required version \(minimumSchemaVersion). Restarting runtime.",
        )
        hookServerManager.stop()
        hookServerManager.startIfNeeded()
        toast = ToastMessage("Runtime service restarted for compatibility")
    }

    private func resolveActivationRoute(
        projectPath: String,
        clientTty: String?,
        sessionName: String?,
    ) async -> RuntimeRoutingView? {
        do {
            let snapshot = try await runtimeClient.fetchCoreRoutingSnapshot(
                projectPath: projectPath,
                workspaceId: nil,
                clientTty: clientTty,
                sessionName: sessionName,
            )
            guard snapshot.status != "unavailable", snapshot.target.kind != "none" else {
                return nil
            }
            return RuntimeRoutingView(
                workspaceId: snapshot.workspaceId,
                projectPath: snapshot.projectPath,
                status: snapshot.status,
                target: snapshot.target,
                reasonCode: snapshot.reasonCode,
                reason: snapshot.reason,
                updatedAt: snapshot.updatedAt,
            )
        } catch {
            DebugLog.write(
                "AppState.resolveActivationRoute source=runtime_route_error path=\(projectPath) error=\(error)",
            )
            return nil
        }
    }

    // MARK: - Quick Feedback

    func submitQuickFeedback(
        _ draft: QuickFeedbackDraft,
        preferences overridePreferences: QuickFeedbackPreferences? = nil,
        formSessionID: String? = nil,
        openGitHubIssue: Bool = true,
    ) {
        let normalizedDraft = draft.normalized()
        let preferences = overridePreferences ?? QuickFeedbackPreferences.load()
        let context = quickFeedbackContext()
        let submitter = QuickFeedbackSubmitter(
            openURL: { url in
                NSWorkspace.shared.open(url)
            },
            sendRequest: { request in
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(httpResponse.statusCode)
                {
                    throw URLError(.badServerResponse)
                }
            },
        )

        _Concurrency.Task { [weak self] in
            let outcome = await submitter.submit(
                draft: normalizedDraft,
                context: context,
                preferences: preferences,
                openGitHubIssue: openGitHubIssue,
            )

            await MainActor.run {
                guard let self else { return }

                if openGitHubIssue {
                    if outcome.issueOpened {
                        if outcome.endpointAttempted, outcome.endpointSucceeded {
                            self.toast = ToastMessage("Opened GitHub issue and sent telemetry")
                        } else if outcome.endpointAttempted {
                            self.toast = ToastMessage("Opened GitHub issue (endpoint send failed)")
                        } else {
                            self.toast = ToastMessage("Opened GitHub issue")
                        }
                    } else {
                        self.toast = .error("Couldn’t open GitHub issue")
                    }
                } else {
                    if outcome.endpointAttempted, outcome.endpointSucceeded {
                        self.toast = ToastMessage("Shared feedback")
                    } else if outcome.endpointAttempted {
                        self.toast = .error("Couldn’t share feedback")
                    } else {
                        self.toast = .error("Couldn’t share feedback (no endpoint configured)")
                    }
                }

                Telemetry.emit("quick_feedback_submitted", "Quick feedback submitted", payload: [
                    "feedback_id": outcome.feedbackID,
                    "issue_requested": openGitHubIssue,
                    "issue_opened": outcome.issueOpened,
                    "endpoint_attempted": outcome.endpointAttempted,
                    "endpoint_succeeded": outcome.endpointSucceeded,
                    "category": normalizedDraft.category.rawValue,
                    "impact": normalizedDraft.impact.rawValue,
                    "reproducibility": normalizedDraft.reproducibility.rawValue,
                    "completion_count": normalizedDraft.completionCount,
                    "telemetry_enabled": preferences.includeTelemetry,
                    "project_paths_enabled": preferences.includeProjectPaths,
                    "session_count": context.sessionStates.count,
                    "project_count": context.projectCount,
                    "active_source": context.activeSource,
                ])

                QuickFeedbackFunnel.emitSubmitResult(
                    sessionID: formSessionID,
                    feedbackID: outcome.feedbackID,
                    draft: normalizedDraft,
                    preferences: preferences,
                    issueRequested: openGitHubIssue,
                    issueOpened: outcome.issueOpened,
                    endpointAttempted: outcome.endpointAttempted,
                    endpointSucceeded: outcome.endpointSucceeded,
                )
            }
        }
    }

    private func refreshAERoutingRuntimeFlags(with health: RuntimeHealth?) {
        routingRollout = health?.routing?.rollout
    }

    private func quickFeedbackContext() -> QuickFeedbackContext {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "unknown"

        return QuickFeedbackContext(
            appVersion: appVersion,
            buildNumber: buildNumber,
            channel: channel,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            runtimeStatus: runtimeStatus,
            activeProjectPath: activeProjectPath,
            activeSource: String(describing: activeSource),
            projectCount: projects.count,
            sessionStates: sessionStateManager.sessionStates,
            activationTrace: activationTrace,
        )
    }

    // MARK: - Project Management

    func refreshSuggestedProjects() {
        guard let engine else { return }
        do {
            suggestedProjects = try engine.getSuggestedProjects()
        } catch {
            DebugLog.write("AppState.refreshSuggestedProjects error=\(error.localizedDescription)")
            suggestedProjects = []
        }
    }

    func addSuggestedProjects(_ suggestions: [SuggestedProject]) {
        guard let engine else { return }
        var addedCount = 0
        for suggestion in suggestions {
            do {
                try engine.addProject(path: suggestion.path)
                prependToProjectOrder(suggestion.path)
                suggestedProjects.removeAll { $0.path == suggestion.path }
                addedCount += 1
            } catch {
                DebugLog.write("AppState.addSuggestedProjects error for \(suggestion.name): \(error.localizedDescription)")
            }
        }
        if addedCount > 0 {
            loadDashboard()
            toast = ToastMessage("Connected \(addedCount) project\(addedCount == 1 ? "" : "s")")
        }
    }

    func connectSelectedSuggestions() {
        let selected = suggestedProjects.filter { selectedSuggestedPaths.contains($0.path) }
        addSuggestedProjects(selected)
        selectedSuggestedPaths = []
    }

    func addProject(_ path: String) {
        guard let engine else { return }
        do {
            try engine.addProject(path: path)
            prependToProjectOrder(path)
            loadDashboard()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prependToProjectOrder(_ path: String) {
        var newOrder = projectOrder
        newOrder.removeAll { $0 == path }
        newOrder.insert(path, at: 0)
        setProjectOrder(
            newOrder,
            reason: "project_added",
            extraPayload: ["path": path],
        )
    }

    private func prependToProjectOrder(paths: [String]) {
        let uniqueIncomingPaths = uniquePaths(paths)
        guard !uniqueIncomingPaths.isEmpty else { return }

        var newOrder = projectOrder
        for path in uniqueIncomingPaths {
            newOrder.removeAll { $0 == path }
        }
        newOrder.insert(contentsOf: uniqueIncomingPaths, at: 0)

        setProjectOrder(
            newOrder,
            reason: "projects_added_batch",
            extraPayload: ["pathCount": uniqueIncomingPaths.count],
        )
    }

    func connectProjectViaFileBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select a project folder to connect"
        panel.prompt = "Connect"

        guard panel.runModal() == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        if urls.count > 1 {
            addProjectsFromDrop(urls)
            return
        }

        guard let url = urls.first else { return }
        let path = url.path
        guard let result = validateProject(path) else { return }

        switch result.resultType {
        case "valid", "missing_claude_md":
            addProject(path)
            pendingDragDropTip = true

        case "suggest_parent":
            if let suggested = result.suggestedPath {
                addProject(suggested)
                pendingDragDropTip = true
            } else {
                toast = .error("Could not determine project root")
            }

        case "already_tracked":
            if manuallyDormant.contains(path) {
                _ = withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    manuallyDormant.remove(path)
                }
                toast = ToastMessage("Moved to In Progress")
            } else {
                toast = ToastMessage("Already linked!")
            }

        case "dangerous_path":
            toast = .error(result.reason ?? "Path is too broad")

        case "path_not_found":
            toast = .error("Path not found")

        default:
            toast = .error(result.reason ?? "Could not connect project")
        }
    }

    /// Extracts file URLs from drop providers and forwards to `addProjectsFromDrop`.
    /// Used by card-level DropDelegates to handle external file drags that land on project cards.
    func handleFileURLDrop(_ providers: [NSItemProvider]) {
        let loaders: [(@escaping (Data?) -> Void) -> Void] = providers.compactMap { provider in
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                return nil
            }
            return { completion in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    completion(item as? Data)
                }
            }
        }

        collectDroppedFileURLs(loaders: loaders) { [weak self] urls in
            if !urls.isEmpty {
                self?.addProjectsFromDrop(urls)
            }
        }
    }

    private func collectDroppedFileURLs(
        loaders: [(@escaping (Data?) -> Void) -> Void],
        completion: @escaping ([URL]) -> Void,
    ) {
        guard !loaders.isEmpty else {
            completion([])
            return
        }

        var urls: [URL] = []
        let urlsLock = NSLock()
        let group = DispatchGroup()

        for load in loaders {
            group.enter()
            load { data in
                defer { group.leave() }
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    return
                }
                urlsLock.lock()
                urls.append(url)
                urlsLock.unlock()
            }
        }

        group.notify(queue: .main) {
            urlsLock.lock()
            let snapshot = urls
            urlsLock.unlock()
            completion(snapshot)
        }
    }

    #if DEBUG
        func collectDroppedFileURLsForTesting(
            loaders: [(@escaping (Data?) -> Void) -> Void],
            completion: @escaping ([URL]) -> Void,
        ) {
            collectDroppedFileURLs(loaders: loaders, completion: completion)
        }
    #endif

    /// Connects multiple projects from a drag-and-drop operation.
    ///
    /// Toast priority: errors first, then success. For mixed results, shows
    /// "project-a, project-b and X more failed (Y connected)" to surface failures
    /// prominently while still acknowledging successes.
    ///
    /// Already-tracked projects are silently moved from Paused to In Progress
    /// if applicable, showing "Moved to In Progress" rather than an error.
    func addProjectsFromDrop(_ urls: [URL]) {
        guard engine != nil else { return }
        guard let worker = projectIngestionWorker else { return }

        // Navigate to list view first if not already there
        if projectView != .list {
            showProjectList()
        }

        let paths = urls.map(\.path)

        _Concurrency.Task { [weak self] in
            let outcome = await worker.addProjects(paths: paths)
            await MainActor.run {
                guard let self else { return }

                let finalAddedCount = outcome.addedCount
                let finalAddedPaths = outcome.addedPaths
                let finalAlreadyTrackedPaths = outcome.alreadyTrackedPaths
                let finalFailedNames = outcome.failedNames

                // Separate already-tracked projects into paused vs already in progress
                var movedCount = 0
                var alreadyInProgressCount = 0

                if !finalAlreadyTrackedPaths.isEmpty {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        for path in finalAlreadyTrackedPaths {
                            if self.manuallyDormant.contains(path) {
                                self.manuallyDormant.remove(path)
                                movedCount += 1
                            } else {
                                alreadyInProgressCount += 1
                            }
                        }
                    }
                }

                if finalAddedCount > 0 {
                    // Batch prepend so order persistence/telemetry runs once for large imports.
                    self.prependToProjectOrder(paths: finalAddedPaths)
                    var fastSwapTransaction = Transaction(animation: nil)
                    fastSwapTransaction.disablesAnimations = true
                    withTransaction(fastSwapTransaction) {
                        self.loadDashboard(hydrateIdeas: false, showLoadingState: false)
                    }
                    self.scheduleDeferredIdeaHydration()
                    self.pendingDragDropTip = true
                }

                // Show appropriate toast with error-first formatting
                if !finalFailedNames.isEmpty {
                    let message = Self.formatMixedResultsToast(
                        failedNames: finalFailedNames,
                        connectedCount: finalAddedCount,
                    )
                    self.toast = .error(message)
                } else if finalAddedCount == 0 {
                    if movedCount > 0 {
                        self.toast = ToastMessage(
                            movedCount == 1 ? "Moved to In Progress" : "Moved \(movedCount) projects to In Progress",
                        )
                    } else if alreadyInProgressCount > 0 {
                        self.toast = ToastMessage("Already linked!")
                    }
                }
            }
        }
    }

    /// Formats a mixed results toast with truncation.
    /// Examples: "project-a failed (2 connected)", "project-a, project-b and 3 more failed (1 connected)"
    private static func formatMixedResultsToast(failedNames: [String], connectedCount: Int) -> String {
        let failedCount = failedNames.count

        // Build the failed portion with truncation (max 2 names shown)
        let failedPortion: String
        if failedCount == 1 {
            failedPortion = "\(failedNames[0]) failed"
        } else if failedCount == 2 {
            failedPortion = "\(failedNames[0]), \(failedNames[1]) failed"
        } else {
            let remainder = failedCount - 2
            failedPortion = "\(failedNames[0]), \(failedNames[1]) and \(remainder) more failed"
        }

        // Add success suffix if any were connected
        if connectedCount > 0 {
            return "\(failedPortion) (\(connectedCount) connected)"
        } else {
            return failedPortion
        }
    }

    private func scheduleDeferredIdeaHydration() {
        guard isIdeaCaptureEnabled else { return }

        _Concurrency.Task { [weak self] in
            guard let self else { return }

            // Yield one frame so connect-state -> list transition can complete first.
            await _Concurrency.Task.yield()
            guard isIdeaCaptureEnabled else { return }
            await projectDetailsManager.loadAllIdeasIncrementally(for: projects)
        }
    }

    func removeProject(_ path: String) {
        guard let engine else { return }
        do {
            try engine.removeProject(path: path)
            var newOrder = projectOrder
            newOrder.removeAll { $0 == path }
            setProjectOrder(
                newOrder,
                reason: "project_removed",
                extraPayload: ["path": path],
            )
            previousActivityGroup.removeValue(forKey: path)
            manuallyDormant.remove(path)
            loadDashboard()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Validates a project path before adding.
    /// Returns the validation result for UI handling.
    func validateProject(_ path: String) -> ValidationResultFfi? {
        guard let engine else { return nil }
        return engine.validateProject(path: path)
    }

    // MARK: - Session State Access (delegating to manager)

    func getSessionState(for project: Project) -> ProjectSessionState? {
        _ = sessionStateRevision
        return sessionStateManager.getSessionState(for: project)
    }

    func isFlashing(_ project: Project) -> SessionState? {
        _ = sessionStateRevision
        return sessionStateManager.isFlashing(project)
    }

    func getProjectStatus(for project: Project) -> ProjectStatus? {
        projectStatuses[project.path]
    }

    /// Batch-refresh project statuses from the Rust engine.
    /// Called on the 2-second timer alongside session state refresh.
    /// Replaces per-card FFI calls with a single batch update.
    private func refreshProjectStatuses() {
        guard let engine else { return }
        var updated: [String: ProjectStatus] = [:]
        for project in projects {
            if let status = engine.getProjectStatus(projectPath: project.path) {
                updated[project.path] = status
            }
        }
        if updated != projectStatuses {
            projectStatuses = updated
        }
    }

    // MARK: - Terminal Operations

    func launchTerminal(for project: Project) {
        activeProjectResolver.setManualOverride(project)
        activeProjectResolver.resolve()
        terminalLauncher.launchTerminal(for: project)
    }

    func handlePrimaryProjectAction(for project: Project) {
        let action = ProjectPrimaryActionResolver.resolve(
            delegationState: delegationState(for: project),
            isDelegationEnabled: isDelegationLoopEnabled,
        )

        switch action {
        case .openTerminal:
            launchTerminal(for: project)
        case .openDelegationReview:
            showDelegationReview(project)
        }
    }

    private func activeWorktreePathsForGuardrails() -> Set<String> {
        var paths: Set<String> = []

        for (projectPath, state) in sessionStateManager.sessionStates where state.state == .working {
            paths.insert(PathNormalizer.normalize(projectPath))
        }

        if let activePath = activeProjectPath {
            paths.insert(PathNormalizer.normalize(activePath))
        }

        return paths
    }

    // MARK: - Navigation

    func showProjectDetail(_ project: Project) {
        projectFeatureCoordinator.showProjectDetail(project)
    }

    func showDelegationReview(_ project: Project) {
        guard isDelegationLoopEnabled else {
            launchTerminal(for: project)
            return
        }
        if let delegation = delegationState(for: project) {
            reviewWindowTarget = ReviewWindowTarget(
                projectPath: project.path,
                workerID: delegation.workerId,
            )
        }
    }

    func submitRunCheckpointDecision(
        projectPath: String,
        runID: String,
        checkpointID: String,
        action: String,
        note: String?,
    ) async throws {
        try await runtimeClient.mutateRun(RuntimeRunMutationRequest(
            kind: "submit_decision",
            projectPath: projectPath,
            runId: runID,
            checkpointId: checkpointID,
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
            decisionAction: action,
            decisionNote: note?.isEmpty == true ? nil : note,
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
        ))
    }

    func showProjectList() {
        projectFeatureCoordinator.showProjectList()
    }

    // MARK: - Layout Mode Persistence

    private func loadLayoutMode() {
        if let rawValue = UserDefaults.standard.string(forKey: layoutModeKey),
           let mode = LayoutMode(rawValue: rawValue)
        {
            layoutMode = mode
        }
    }

    private func saveLayoutMode() {
        UserDefaults.standard.set(layoutMode.rawValue, forKey: layoutModeKey)
    }

    // MARK: - Dormant/Order Persistence

    private func loadDormantOverrides() {
        manuallyDormant = DormantOverrideStore.load()
    }

    private func saveDormantOverrides() {
        DormantOverrideStore.save(manuallyDormant)
    }

    private func loadProjectOrder() {
        projectOrder = ProjectOrderStore.load()
    }

    private func saveProjectOrder() {
        ProjectOrderStore.save(projectOrder)
    }

    /// Returns grouped projects: active first, then idle. Paused projects are excluded upstream.
    func orderedGroupedProjects(_ projects: [Project]) -> (active: [Project], idle: [Project]) {
        _ = sessionStateRevision
        return ProjectOrdering.orderedGroupedProjects(
            projects,
            order: projectOrder,
            sessionStates: sessionStateManager.sessionStates,
        )
    }

    func moveProject(from source: IndexSet, to destination: Int, in projectList: [Project], group: ActivityGroup) {
        let visibleProjects = projects.filter { !manuallyDormant.contains($0.path) }
        let newOrder = ProjectOrdering.movedGlobalOrder(
            from: source,
            to: destination,
            in: projectList,
            globalOrder: projectOrder,
            allProjects: visibleProjects,
        )
        setProjectOrder(
            newOrder,
            reason: group == .active ? "drag_reorder_active" : "drag_reorder_idle",
            extraPayload: [
                "groupSize": projectList.count,
                "sourceIndexes": source.map(String.init).joined(separator: ","),
                "destination": destination,
            ],
        )
    }

    // MARK: - Activity Group Reconciliation

    /// Tracks activity transitions and keeps persisted global order clean.
    private func reconcileProjectGroups() {
        let states = sessionStateManager.sessionStates
        let currentProjectPaths = projects.map(\.path)
        let currentPathSet = Set(currentProjectPaths)
        var transitionCount = 0

        for project in projects {
            let path = project.path
            // Skip paused projects — they're managed separately
            guard !manuallyDormant.contains(path) else { continue }

            let currentGroup: ActivityGroup = ProjectOrdering.isActive(path, sessionStates: states) ? .active : .idle
            let previousGroup = previousActivityGroup[path]

            if previousGroup != currentGroup {
                transitionCount += 1
                previousActivityGroup[path] = currentGroup
            }
        }

        // Clean up removed projects
        let removedPaths = Set(previousActivityGroup.keys).subtracting(currentPathSet)
        for path in removedPaths {
            previousActivityGroup.removeValue(forKey: path)
        }

        var reconciledOrder = uniquePaths(projectOrder).filter { currentPathSet.contains($0) }
        let missingPaths = currentProjectPaths.filter { !reconciledOrder.contains($0) }
        reconciledOrder.append(contentsOf: missingPaths)

        var payload: [String: Any] = [
            "transitionCount": transitionCount,
            "removedPathCount": removedPaths.count,
            "missingPathCount": missingPaths.count,
        ]
        if !missingPaths.isEmpty {
            payload["missingPaths"] = missingPaths
        }
        if !removedPaths.isEmpty {
            payload["removedPaths"] = Array(removedPaths)
        }

        let hadDuplicates = uniquePaths(projectOrder).count != projectOrder.count
        if hadDuplicates {
            emitProjectOrderAnomaly(
                "Deduplicated project order during session reconcile",
                payload: ["reason": "duplicate_paths_detected"],
            )
        }
        if !missingPaths.isEmpty {
            emitProjectOrderAnomaly(
                "Appended missing project paths to persisted order",
                payload: [
                    "reason": "missing_paths",
                    "missingPathCount": missingPaths.count,
                ],
            )
        }

        setProjectOrder(
            reconciledOrder,
            reason: "session_reconcile",
            extraPayload: payload,
        )
    }

    private func setProjectOrder(
        _ newOrder: [String],
        reason: String,
        extraPayload: [String: Any] = [:],
    ) {
        let normalizedOrder = uniquePaths(newOrder)
        let oldOrder = projectOrder
        guard normalizedOrder != oldOrder else { return }

        projectOrder = normalizedOrder

        var payload = extraPayload
        payload["reason"] = reason
        payload["oldCount"] = oldOrder.count
        payload["newCount"] = normalizedOrder.count
        payload["changedPathCount"] = Set(oldOrder).symmetricDifference(Set(normalizedOrder)).count
        Telemetry.emit("project_order_changed", "Project order updated", payload: payload)
    }

    private func emitProjectOrderAnomaly(_ message: String, payload: [String: Any]) {
        Telemetry.emit("project_order_anomaly", message, payload: payload)
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(paths.count)
        for path in paths where !seen.contains(path) {
            seen.insert(path)
            result.append(path)
        }
        return result
    }

    func moveToDormant(_ project: Project) {
        manuallyDormant.insert(project.path)
    }

    func moveToRecent(_ project: Project) {
        manuallyDormant.remove(project.path)
    }

    func isManuallyDormant(_ project: Project) -> Bool {
        manuallyDormant.contains(project.path)
    }

    // MARK: - Idea Capture (delegating to ProjectDetailsManager)

    func showIdeaCaptureModal(for project: Project, from origin: CGRect? = nil) {
        projectFeatureCoordinator.showIdeaCaptureModal(for: project, from: origin)
    }

    func captureIdea(for project: Project, text: String) -> Result<Void, Error> {
        projectFeatureCoordinator.captureIdea(for: project, text: text)
    }

    func checkIdeasFileChanges() {
        projectFeatureCoordinator.checkIdeasFileChanges(for: projects)
    }

    func getIdeas(for project: Project) -> [Idea] {
        projectFeatureCoordinator.getIdeas(for: project)
    }

    func isGeneratingTitle(for ideaId: String) -> Bool {
        projectFeatureCoordinator.isGeneratingTitle(for: ideaId)
    }

    func dismissIdea(_ idea: Idea, for project: Project) {
        projectFeatureCoordinator.dismissIdea(idea, for: project)
    }

    func reorderIdeas(_ reorderedIdeas: [Idea], for project: Project) {
        projectFeatureCoordinator.reorderIdeas(reorderedIdeas, for: project)
    }

    func delegateIdea(_ idea: Idea, for project: Project) {
        guard isDelegationLoopEnabled else {
            error = "Delegation loop is disabled for this build."
            return
        }

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                try await delegationLoopManager.startDelegation(project: project, idea: idea)
                await MainActor.run {
                    self.refreshSessionStates()
                }
            } catch {
                await MainActor.run {
                    let message = DelegationUserFacingMessage.startFailure(for: error)
                    DebugLog.write(
                        "AppState.delegateIdea failure project=\(project.path) error=\(error.localizedDescription) userMessage=\(message)",
                    )
                    self.toast = .error(message)
                    self.refreshSessionStates()
                }
            }
        }
    }

    func delegationState(for project: Project) -> RuntimeDelegationState? {
        guard isDelegationLoopEnabled else { return nil }
        return delegationStates[PathNormalizer.normalize(project.path)]
    }

    func delegationState(forPath projectPath: String) -> RuntimeDelegationState? {
        guard isDelegationLoopEnabled else { return nil }
        return delegationStates[PathNormalizer.normalize(projectPath)]
    }

    // MARK: - Project Descriptions (delegating to ProjectDetailsManager)

    func getDescription(for project: Project) -> String? {
        projectFeatureCoordinator.getDescription(for: project)
    }

    func isGeneratingDescription(for project: Project) -> Bool {
        projectFeatureCoordinator.isGeneratingDescription(for: project)
    }

    func generateDescription(for project: Project) {
        projectFeatureCoordinator.generateDescription(for: project)
    }

    // MARK: - Project Creation

    private func loadCreations() {
        projectCreationCoordinator.loadCreations()
    }

    #if DEBUG
        func applyDiscoveredSessionToCreationForTesting(_ creationId: String, sessionId: String) -> Bool {
            projectCreationCoordinator.applyDiscoveredSessionToCreationForTesting(creationId, sessionId: sessionId)
        }

        func setCreationMonitorTasksForTesting(
            creationId: String,
            sessionTask: _Concurrency.Task<Void, Never>?,
            completionTask: _Concurrency.Task<Void, Never>?,
        ) {
            projectCreationCoordinator.setCreationMonitorTasksForTesting(
                creationId: creationId,
                sessionTask: sessionTask,
                completionTask: completionTask,
            )
        }

        func hasCreationMonitorTasksForTesting(creationId: String) -> Bool {
            projectCreationCoordinator.hasCreationMonitorTasksForTesting(creationId: creationId)
        }
    #endif

    private func recordRuntimeBootstrapStepForTesting(_ step: String) {
        #if DEBUG
            runtimeBootstrapTraceForTesting.append(step)
        #endif
    }

    func cancelCreation(_ id: String) {
        projectCreationCoordinator.cancelCreation(id)
    }

    func resumeCreation(_ id: String) {
        projectCreationCoordinator.resumeCreation(id)
    }

    func canResumeCreation(_ id: String) -> Bool {
        projectCreationCoordinator.canResumeCreation(id)
    }
}
