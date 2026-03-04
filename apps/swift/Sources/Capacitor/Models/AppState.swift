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
    case newIdea

    static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list), (.newIdea, .newIdea):
            true
        case let (.detail(p1), .detail(p2)):
            p1.path == p2.path
        default:
            false
        }
    }
}

enum AppFeatureError: LocalizedError {
    case ideaCaptureDisabled
    case projectDetailsDisabled
    case projectCreationDisabled

    var errorDescription: String? {
        switch self {
        case .ideaCaptureDisabled:
            "Idea capture is disabled for this build."
        case .projectDetailsDisabled:
            "Project details are disabled for this build."
        case .projectCreationDisabled:
            "Project creation is disabled for this build."
        }
    }
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

    var isWindowAnchoringEnabled: Bool {
        featureFlags.windowAnchoring
    }

    // MARK: - Navigation

    var projectView: ProjectView = .list

    // MARK: - Data

    var dashboard: DashboardData?
    var projects: [Project] = []
    var suggestedProjects: [SuggestedProject] = []
    var selectedSuggestedPaths: Set<String> = []

    // MARK: - Active project creations (Idea → V1)

    var activeCreations: [ProjectCreation] = []

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
    let terminalLauncher = TerminalLauncher()
    let sessionStateManager = SessionStateManager()
    let projectDetailsManager = ProjectDetailsManager()
    private let projectIngestionWorker = ProjectIngestionWorker()
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
    private var engine: CoreRuntime?
    private var refreshTimer: Timer?
    private var runtimeSnapshotTask: _Concurrency.Task<Void, Never>?
    private var runtimeSnapshotGeneration: UInt64 = 0
    private var runtimeSnapshotCorrelationCounter: UInt64 = 0
    private(set) var sessionStateRevision = 0
    private(set) var didScheduleRuntimeBootstrapForTesting = false
    private(set) var didAttemptRuntimeHealthCheckForTesting = false
    private(set) var didStartRefreshTimerForTesting = false
    private(set) var didStartShellTrackingForTesting = false

    // MARK: - Computed Properties (bridging to managers)

    var activeProjectPath: String? {
        activeProjectResolver?.activeProject?.path
    }

    var activeSource: ActiveSource {
        activeProjectResolver?.activeSource ?? .none
    }

    // MARK: - Initialization

    init() {
        DebugLog.write(
            "AppState.init start runtimeEnabled=\(RuntimeClient.shared.isEnabled) home=\(FileManager.default.homeDirectoryForCurrentUser.path)",
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
        ProjectOrderStore.migrateIfNeeded()
        loadProjectOrder()

        activeProjectResolver = ActiveProjectResolver(
            sessionStateManager: sessionStateManager,
        )
        sessionStateManager.onVisualStateChanged = { [weak self] in
            guard let self else { return }
            sessionStateRevision &+= 1
        }

        terminalLauncher.onActivationResult = { [weak self] result in
            guard let self else { return }
            if !result.success {
                toast = ToastMessage(
                    "Couldn’t activate Ghostty.",
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
        didScheduleRuntimeBootstrapForTesting = true

        // Phase 2: Defer runtime bootstrap work past first SwiftUI render.
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                engine = try CoreRuntime()

                ensureRuntimeReady()

                projectDetailsManager.configure(engine: engine)
                loadDashboard()
                checkHookDiagnostic()
                setupRefreshTimer()
                startShellTracking()
            } catch {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    // MARK: - Setup

    private var hookHealthCheckCounter = 0
    private var statsRefreshCounter = 0
    private var runtimeHealthCheckCounter = 0

    private func setupRefreshTimer() {
        didStartRefreshTimerForTesting = true
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
        didStartShellTrackingForTesting = true
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
                let snapshot = try await RuntimeClient.shared.fetchRuntimeSnapshot(correlationId: correlationId)
                guard !_Concurrency.Task.isCancelled else { return }

                await MainActor.run {
                    guard refreshGeneration == self.runtimeSnapshotGeneration else {
                        DebugLog.write(
                            "AppState.refreshSessionStates source=runtime_snapshot_drop_stale cid=\(correlationId) generation=\(refreshGeneration) current=\(self.runtimeSnapshotGeneration)",
                        )
                        return
                    }

                    self.sessionStateManager.applyRuntimeProjectStates(
                        snapshot.projectStates,
                        for: currentProjects,
                        correlationId: correlationId,
                    )

                    DebugLog.write(
                        "AppState.refreshSessionStates source=runtime_snapshot_apply cid=\(correlationId) projects=\(snapshot.projectStates.count) sessions=\(snapshot.sessions.count) shells=\(snapshot.shellState.shells.count)",
                    )
                    self.updatePostSessionRefreshContext()
                }

                await shellStateStore.applyRuntimeShellState(
                    snapshot.shellState,
                    correlationId: correlationId,
                )
            } catch {
                await MainActor.run {
                    guard refreshGeneration == self.runtimeSnapshotGeneration else {
                        DebugLog.write(
                            "AppState.refreshSessionStates source=runtime_snapshot_error_drop_stale cid=\(correlationId) generation=\(refreshGeneration) current=\(self.runtimeSnapshotGeneration)",
                        )
                        return
                    }

                    DebugLog.write(
                        "AppState.refreshSessionStates source=runtime_snapshot_error cid=\(correlationId) error=\(error)",
                    )
                    self.updatePostSessionRefreshContext()
                }
            }
        }
    }

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
                heartbeatOk: false,
                heartbeatAgeSecs: nil,
                stateFileOk: false,
                message: "Engine not initialized",
            )
        }
        return engine.runHookTest()
    }

    // MARK: - Runtime Diagnostic

    func ensureRuntimeReady() {
        didAttemptRuntimeHealthCheckForTesting = true
        // Hard cutover mode: runtime state is sourced from the core snapshot file.
        // No legacy launchd lifecycle orchestration remains in AppState.
        checkRuntimeHealth()
    }

    func checkRuntimeHealth() {
        guard RuntimeClient.shared.isEnabled else {
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
                let health = try await RuntimeClient.shared.fetchHealth()
                await MainActor.run {
                    guard let self else { return }
                    self.runtimeStatus = RuntimeStatus(
                        isEnabled: true,
                        isHealthy: health.status == "ok",
                        message: "Core runtime snapshot mode",
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
                        message: "Core runtime snapshot unavailable",
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

    func submitQuickFeedback(
        _ message: String,
        preferences overridePreferences: QuickFeedbackPreferences? = nil,
    ) {
        submitQuickFeedback(
            QuickFeedbackDraft.legacy(message: message),
            preferences: overridePreferences,
            formSessionID: nil,
            openGitHubIssue: true,
        )
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
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }

            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    return
                }
                DispatchQueue.main.async {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if !urls.isEmpty {
                self?.addProjectsFromDrop(urls)
            }
        }
    }

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

    /// Creates a CLAUDE.md file for a project.
    func createClaudeMd(for path: String) -> Bool {
        guard let engine else { return false }
        do {
            try engine.createProjectClaudeMd(projectPath: path)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
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
        guard isProjectDetailsEnabled else { return }
        projectView = .detail(project)
    }

    func showNewIdea() {
        guard isProjectCreationEnabled else { return }
        projectView = .newIdea
    }

    func showProjectList() {
        projectView = .list
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

    /// Flat ordered list for backward compatibility (active then idle).
    func orderedProjects(_ projects: [Project]) -> [Project] {
        let grouped = orderedGroupedProjects(projects)
        return grouped.active + grouped.idle
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
        guard isIdeaCaptureEnabled else { return }
        captureModalProject = project
        captureModalOrigin = origin
        showCaptureModal = true
    }

    func captureIdea(for project: Project, text: String) -> Result<Void, Error> {
        guard isIdeaCaptureEnabled else {
            return .failure(AppFeatureError.ideaCaptureDisabled)
        }
        return projectDetailsManager.captureIdea(for: project, text: text)
    }

    func checkIdeasFileChanges() {
        guard isIdeaCaptureEnabled else { return }
        projectDetailsManager.checkIdeasFileChanges(for: projects)
    }

    func getIdeas(for project: Project) -> [Idea] {
        guard isIdeaCaptureEnabled else { return [] }
        return projectDetailsManager.getIdeas(for: project)
    }

    func isGeneratingTitle(for ideaId: String) -> Bool {
        guard isIdeaCaptureEnabled else { return false }
        return projectDetailsManager.isGeneratingTitle(for: ideaId)
    }

    func dismissIdea(_ idea: Idea, for project: Project) {
        guard isIdeaCaptureEnabled else { return }
        do {
            try projectDetailsManager.updateIdeaStatus(for: project, idea: idea, newStatus: "done")
        } catch {
            self.error = "Failed to dismiss idea: \(error.localizedDescription)"
        }
    }

    func reorderIdeas(_ reorderedIdeas: [Idea], for project: Project) {
        guard isIdeaCaptureEnabled else { return }
        projectDetailsManager.reorderIdeas(reorderedIdeas, for: project)
    }

    // MARK: - Project Descriptions (delegating to ProjectDetailsManager)

    func getDescription(for project: Project) -> String? {
        guard isLlmFeaturesEnabled else { return nil }
        return projectDetailsManager.getDescription(for: project)
    }

    func isGeneratingDescription(for project: Project) -> Bool {
        guard isLlmFeaturesEnabled else { return false }
        return projectDetailsManager.isGeneratingDescription(for: project)
    }

    func generateDescription(for project: Project) {
        guard isLlmFeaturesEnabled else { return }
        projectDetailsManager.generateDescription(for: project)
    }

    // MARK: - Project Creation

    private func loadCreations() {
        let creationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/creations.json")

        guard FileManager.default.fileExists(atPath: creationsPath.path) else { return }

        do {
            let data = try Data(contentsOf: creationsPath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            activeCreations = try decoder.decode([ProjectCreation].self, from: data)
            cleanupCompletedCreations()
        } catch {
            // File doesn't exist or is invalid - start fresh
        }
    }

    private func saveCreations() {
        guard isIdeaCaptureEnabled else { return }
        let creationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/creations.json")

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(activeCreations)
            try data.write(to: creationsPath)
        } catch {
            // Silently fail
        }
    }

    private func cleanupCompletedCreations() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        activeCreations = activeCreations.filter { creation in
            if creation.status == .completed || creation.status == .failed || creation.status == .cancelled {
                let completionDate = creation.completedAtDate ?? creation.createdAtDate ?? Date.distantPast
                return completionDate > cutoff
            }
            return true
        }
    }

    func startCreation(request: NewProjectRequest, projectPath: String) -> String {
        guard isIdeaCaptureEnabled else { return UUID().uuidString }
        let id = UUID().uuidString
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let creation = ProjectCreation(
            id: id,
            name: request.name,
            path: projectPath,
            description: request.description,
            status: .pending,
            sessionId: nil,
            progress: CreationProgress(phase: "setup", message: "Initializing project...", percentComplete: 0),
            error: nil,
            createdAt: now,
            completedAt: nil,
        )
        activeCreations.insert(creation, at: 0)
        saveCreations()
        return id
    }

    func updateCreationStatus(_ id: String, status: CreationStatus, sessionId: String? = nil, error: String? = nil) {
        guard let index = activeCreations.firstIndex(where: { $0.id == id }) else { return }
        activeCreations[index].status = status
        if let sessionId {
            activeCreations[index].sessionId = sessionId
        }
        if let error {
            activeCreations[index].error = error
        }
        if status == .completed || status == .failed || status == .cancelled {
            activeCreations[index].completedAt = ISO8601DateFormatter.shared.string(from: Date())
        }
        saveCreations()
    }

    func updateCreationProgress(_ id: String, phase: String, message: String, percentComplete: Int?) {
        guard let index = activeCreations.firstIndex(where: { $0.id == id }) else { return }
        activeCreations[index].progress = CreationProgress(
            phase: phase,
            message: message,
            percentComplete: percentComplete.map { UInt8(clamping: $0) },
        )
        saveCreations()
    }

    func cancelCreation(_ id: String) {
        updateCreationStatus(id, status: .cancelled)
    }

    func resumeCreation(_ id: String) {
        guard let creation = activeCreations.first(where: { $0.id == id }),
              let sessionId = creation.sessionId,
              creation.status == .failed || creation.status == .cancelled
        else {
            return
        }

        updateCreationStatus(id, status: .inProgress)
        updateCreationProgress(id, phase: "resuming", message: "Resuming session...", percentComplete: 30)

        _Concurrency.Task {
            do {
                try await launchClaudeResume(projectPath: creation.path, sessionId: sessionId, creationId: id)
            } catch {
                await MainActor.run {
                    updateCreationStatus(id, status: .failed, error: "Failed to resume: \(error.localizedDescription)")
                }
            }
        }
    }

    func canResumeCreation(_ id: String) -> Bool {
        guard let creation = activeCreations.first(where: { $0.id == id }) else {
            return false
        }
        return creation.sessionId != nil &&
            (creation.status == .failed || creation.status == .cancelled)
    }

    func createProjectFromIdea(_ request: NewProjectRequest, completion: @escaping (CreateProjectResult) -> Void) {
        guard isProjectCreationEnabled else {
            completion(CreateProjectResult(
                success: false,
                projectPath: "",
                sessionId: nil,
                error: AppFeatureError.projectCreationDisabled.errorDescription ?? "Project creation is disabled.",
            ))
            return
        }
        _Concurrency.Task {
            do {
                let result = try await createProjectAsync(request)
                await MainActor.run {
                    completion(result)
                }
            } catch {
                await MainActor.run {
                    completion(CreateProjectResult(
                        success: false,
                        projectPath: "",
                        sessionId: nil,
                        error: error.localizedDescription,
                    ))
                }
            }
        }
    }

    private func createProjectAsync(_ request: NewProjectRequest) async throws -> CreateProjectResult {
        let location = (request.location as NSString).expandingTildeInPath
        let sanitizedName = request.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        let projectPath = (location as NSString).appendingPathComponent(sanitizedName)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: projectPath) {
            return CreateProjectResult(
                success: false,
                projectPath: projectPath,
                sessionId: nil,
                error: "Project directory already exists",
            )
        }

        let creationId = await MainActor.run {
            startCreation(request: request, projectPath: projectPath)
        }

        await MainActor.run {
            updateCreationProgress(creationId, phase: "setup", message: "Creating project directory...", percentComplete: 10)
        }

        try fileManager.createDirectory(atPath: projectPath, withIntermediateDirectories: true)

        await MainActor.run {
            updateCreationProgress(creationId, phase: "setup", message: "Generating CLAUDE.md...", percentComplete: 20)
        }

        let claudeMd = generateClaudeMd(request)
        let claudeMdPath = (projectPath as NSString).appendingPathComponent("CLAUDE.md")
        try claudeMd.write(toFile: claudeMdPath, atomically: true, encoding: .utf8)

        await MainActor.run {
            updateCreationProgress(creationId, phase: "building", message: "Launching Claude to build v1...", percentComplete: 30)
            updateCreationStatus(creationId, status: .inProgress)
        }

        let prompt = buildCreationPrompt(request)

        var sessionId: String?
        do {
            sessionId = try await runClaudeForProject(projectPath: projectPath, prompt: prompt, creationId: creationId)
        } catch {
            await MainActor.run {
                updateCreationStatus(creationId, status: .failed, error: "Failed to run Claude: \(error.localizedDescription)")
            }
            return CreateProjectResult(
                success: false,
                projectPath: projectPath,
                sessionId: nil,
                error: "Failed to run Claude: \(error.localizedDescription)",
            )
        }

        do {
            try engine?.addProject(path: projectPath)
        } catch {
            // Continue even if adding to HUD fails
        }

        await MainActor.run {
            updateCreationProgress(creationId, phase: "building", message: "Claude is building your project in the terminal...", percentComplete: 50)
        }

        return CreateProjectResult(
            success: true,
            projectPath: projectPath,
            sessionId: sessionId,
            error: nil,
        )
    }

    private func generateClaudeMd(_ request: NewProjectRequest) -> String {
        var content = "# \(request.name)\n\n"
        content += "## Overview\n\n"
        content += "\(request.description)\n\n"

        if request.language != nil || request.framework != nil {
            content += "## Tech Stack\n\n"
            if let language = request.language {
                content += "- Language: \(language.capitalized)\n"
            }
            if let framework = request.framework {
                content += "- Framework: \(framework)\n"
            }
            content += "\n"
        }

        content += "## Status\n\n"
        content += "🚀 Initial v1 bootstrap in progress\n"

        return content
    }

    private func buildCreationPrompt(_ request: NewProjectRequest) -> String {
        var prompt = """
        Create a working v1 of "\(request.name)".

        Description: \(request.description)

        """

        if let language = request.language {
            prompt += "Use \(language) as the primary language.\n"
        }

        if let framework = request.framework {
            prompt += "Use \(framework) as the framework.\n"
        }

        prompt += """

        Requirements:
        - Create a WORKING implementation, not just scaffolding
        - Include a README.md with clear usage instructions
        - Make it runnable with a simple command (npm start, cargo run, etc.)
        - Focus on functionality over perfection - a working v1 is the goal
        - Include basic error handling
        """

        return prompt
    }

    private func runClaudeForProject(projectPath: String, prompt: String, creationId: String) async throws -> String? {
        let tempDir = FileManager.default.temporaryDirectory
        let promptFile = tempDir.appendingPathComponent("claude-prompt-\(UUID().uuidString).txt")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

        let existingSessions = getExistingSessionIds(for: projectPath)

        let claudeCmd = "/opt/homebrew/bin/claude \"$(cat '\(promptFile.path)')\" ; rm -f '\(promptFile.path)'"
        let script = TerminalScripts.launchWithCommand(projectPath: projectPath, command: claudeCmd, terminalApp: TerminalActivatorFactory.detectTerminalAppName())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        try process.run()

        startSessionMonitor(projectPath: projectPath, creationId: creationId, existingSessions: existingSessions)

        return nil
    }

    private func getExistingSessionIds(for projectPath: String) -> Set<String> {
        let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        let encodedPath = projectPath
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let sessionDir = claudeProjectsDir.appendingPathComponent(encodedPath)

        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil) else {
            return []
        }

        return Set(files
            .filter { $0.pathExtension == "jsonl" }
            .map { $0.deletingPathExtension().lastPathComponent })
    }

    private func startSessionMonitor(projectPath: String, creationId: String, existingSessions: Set<String>) {
        _Concurrency.Task {
            let maxAttempts = 60
            let pollInterval: UInt64 = 2_000_000_000

            for _ in 0 ..< maxAttempts {
                do {
                    try await _Concurrency.Task.sleep(nanoseconds: pollInterval)
                } catch {
                    return
                }

                let currentSessions = getExistingSessionIds(for: projectPath)
                let newSessions = currentSessions.subtracting(existingSessions)

                if let sessionId = newSessions.first {
                    await MainActor.run {
                        updateCreationStatus(creationId, status: .inProgress, sessionId: sessionId)
                        updateCreationProgress(creationId, phase: "building", message: "Claude is building your project...", percentComplete: 40)
                    }
                    startCompletionMonitor(projectPath: projectPath, creationId: creationId, sessionId: sessionId)
                    return
                }
            }
        }
    }

    private func startCompletionMonitor(projectPath: String, creationId: String, sessionId: String) {
        _Concurrency.Task {
            let claudeProjectsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")

            let encodedPath = projectPath
                .replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

            let sessionFile = claudeProjectsDir
                .appendingPathComponent(encodedPath)
                .appendingPathComponent("\(sessionId).jsonl")

            var lastSize: UInt64 = 0
            var stableCount = 0
            let maxStableChecks = 30

            for _ in 0 ..< 300 {
                do {
                    try await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }

                guard let creation = activeCreations.first(where: { $0.id == creationId }),
                      creation.status == .inProgress
                else {
                    return
                }

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFile.path),
                      let currentSize = attrs[.size] as? UInt64
                else {
                    continue
                }

                if currentSize == lastSize {
                    stableCount += 1
                    if stableCount >= maxStableChecks {
                        await MainActor.run {
                            updateCreationStatus(creationId, status: .completed)
                            updateCreationProgress(creationId, phase: "complete", message: "Project created successfully!", percentComplete: 100)
                            loadDashboard()
                        }
                        return
                    }
                } else {
                    stableCount = 0
                    lastSize = currentSize

                    let progress = min(90, 40 + (stableCount * 2))
                    await MainActor.run {
                        updateCreationProgress(creationId, phase: "building", message: "Claude is building your project...", percentComplete: progress)
                    }
                }
            }
        }
    }

    private func launchClaudeResume(projectPath: String, sessionId: String, creationId: String) async throws {
        let claudeCmd = "/opt/homebrew/bin/claude --resume \(sessionId)"
        let script = TerminalScripts.launchWithCommand(projectPath: projectPath, command: claudeCmd, terminalApp: TerminalActivatorFactory.detectTerminalAppName())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        try process.run()

        startCompletionMonitor(projectPath: projectPath, creationId: creationId, sessionId: sessionId)
    }
}
