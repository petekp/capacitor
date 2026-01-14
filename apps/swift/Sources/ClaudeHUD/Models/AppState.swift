import Combine
import Foundation
import SwiftUI

enum Tab: String, CaseIterable {
    case projects
    case artifacts
}

enum ProjectView: Equatable {
    case list
    case detail(Project)
    case add
    case newIdea

    static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list), (.add, .add), (.newIdea, .newIdea):
            return true
        case let (.detail(p1), .detail(p2)):
            return p1.path == p2.path
        default:
            return false
        }
    }
}


@MainActor
class AppState: ObservableObject {
    // Navigation
    @Published var activeTab: Tab = .projects
    @Published var projectView: ProjectView = .list
    @Published var selectedProject: Project?

    // Data
    @Published var dashboard: DashboardData?
    @Published var sessionStates: [String: ProjectSessionState] = [:]
    @Published var projectStatuses: [String: ProjectStatus] = [:]
    @Published var artifacts: [Artifact] = []
    @Published var projects: [Project] = []

    // Active project creations (Idea → V1)
    @Published var activeCreations: [ProjectCreation] = []
    private let creationsKey = "activeProjectCreations"

    // UI State
    @Published var isLoading = true
    @Published var error: String?
    @Published var alwaysOnTop = false
    @Published var flashingProjects: [String: SessionState] = [:]

    // Active project tracking (ephemeral, click-based)
    @Published var activeProjectPath: String?

    // Dev Environment
    @Published var devServerPorts: [String: UInt16] = [:]
    @Published var devServerBrowsers: [String: String] = [:]

    // Manual dormant overrides (persisted in UserDefaults)
    @Published var manuallyDormant: Set<String> = [] {
        didSet {
            saveDormantOverrides()
        }
    }

    // Custom project ordering (persisted in UserDefaults)
    @Published var customProjectOrder: [String] = [] {
        didSet {
            saveProjectOrder()
        }
    }

    // Internal state tracking (non-published)
    private var previousSessionStates: [String: SessionState] = [:]
    private let dormantOverridesKey = "manuallyDormantProjects"
    private let projectOrderKey = "customProjectOrder"

    // Rust bridge
    private var engine: HudEngine?

    // Relay client for remote state sync
    @Published var relayClient = RelayClient()
    @Published var isRemoteMode = false

    // Todos manager
    @Published var todosManager = TodosManager()

    // Plans manager
    @Published var plansManager = PlansManager()

    // Terminal tracking (Phase 2: Live tracking)
    private let terminalTracker = TerminalTracker()
    private var trackerUpdateTask: _Concurrency.Task<Void, Never>?

    init() {
        loadDormantOverrides()
        loadProjectOrder()
        loadCreations()
        todosManager.loadTodos()
        plansManager.loadPlans()
        do {
            engine = try HudEngine()
            loadDashboard()
            setupRelayObserver()
            setupStalenessTimer()
            startTerminalTracking()
        } catch {
            self.error = error.localizedDescription
            self.isLoading = false
        }
    }

    private func setupStalenessTimer() {
        // Poll every second for real-time "thinking" state updates
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshSessionStates()
            }
        }
    }

    private func setupRelayObserver() {
        relayClient.$lastState
            .compactMap { $0 }
            .sink { [weak self] state in
                self?.applyRelayState(state)
            }
            .store(in: &cancellables)

        // Forward relayClient state changes to trigger SwiftUI updates
        relayClient.$isConnected
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        relayClient.$connectionError
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        relayClient.$projectHeartbeats
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        relayClient.$connectedAt
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Terminal Tracking (Phase 2)

    private func startTerminalTracking() {
        _Concurrency.Task {
            await terminalTracker.startTracking(projects: projects)
            startTrackerPolling()
        }
    }

    private func startTrackerPolling() {
        trackerUpdateTask = _Concurrency.Task { @MainActor [weak self] in
            while !_Concurrency.Task.isCancelled {
                guard let self = self else { break }

                // Only update if terminal has a project focused
                // If no terminal focused or no tmux session, keep existing active project (sticky behavior)
                if let path = await self.terminalTracker.getActiveProjectPath() {
                    self.activeProjectPath = path
                }
                // Note: We intentionally DON'T clear activeProjectPath when nil
                // This preserves the clicked project until a different one is focused

                try? await _Concurrency.Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }
    }

    private func updateTerminalTracking() {
        _Concurrency.Task {
            await terminalTracker.updateProjectMapping(projects)
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var stalenessTimer: Timer?

    private func applyRelayState(_ state: RelayHudState) {
        for (path, projectState) in state.projects {
            let sessionState = parseSessionState(projectState.state)

            sessionStates[path] = ProjectSessionState(
                state: sessionState,
                stateChangedAt: projectState.lastUpdated,
                sessionId: nil,
                workingOn: projectState.workingOn,
                context: nil,
                thinking: nil,
                isLocked: false
            )

            if let previous = previousSessionStates[path], previous != sessionState {
                switch sessionState {
                case .ready, .waiting, .compacting:
                    flashingProjects[path] = sessionState
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                        self?.flashingProjects.removeValue(forKey: path)
                    }
                case .working, .idle:
                    break
                }
            }
            previousSessionStates[path] = sessionState
        }
    }

    private func parseSessionState(_ raw: String) -> SessionState {
        switch raw {
        case "working": return .working
        case "ready": return .ready
        case "compacting": return .compacting
        case "waiting": return .waiting
        default: return .idle
        }
    }

    func connectRelay() {
        isRemoteMode = true
        relayClient.connect()
    }

    func disconnectRelay() {
        isRemoteMode = false
        relayClient.disconnect()
    }

    private func loadDormantOverrides() {
        if let paths = UserDefaults.standard.array(forKey: dormantOverridesKey) as? [String] {
            manuallyDormant = Set(paths)
        }
    }

    private func saveDormantOverrides() {
        UserDefaults.standard.set(Array(manuallyDormant), forKey: dormantOverridesKey)
    }

    private func loadProjectOrder() {
        if let order = UserDefaults.standard.array(forKey: projectOrderKey) as? [String] {
            customProjectOrder = order
        }
    }

    private func saveProjectOrder() {
        UserDefaults.standard.set(customProjectOrder, forKey: projectOrderKey)
    }

    private func loadCreations() {
        let creationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hud-creations.json")

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
        let creationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hud-creations.json")

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(activeCreations)
            try data.write(to: creationsPath)
        } catch {
            // Silently fail - creations will be lost but app continues
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
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
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
            completedAt: nil
        )
        activeCreations.insert(creation, at: 0)
        saveCreations()
        return id
    }

    func updateCreationStatus(_ id: String, status: CreationStatus, sessionId: String? = nil, error: String? = nil) {
        guard let index = activeCreations.firstIndex(where: { $0.id == id }) else { return }
        activeCreations[index].status = status
        if let sessionId = sessionId {
            activeCreations[index].sessionId = sessionId
        }
        if let error = error {
            activeCreations[index].error = error
        }
        if status == .completed || status == .failed || status == .cancelled {
            activeCreations[index].completedAt = ISO8601DateFormatter().string(from: Date())
        }
        saveCreations()
    }

    func updateCreationProgress(_ id: String, phase: String, message: String, percentComplete: Int?) {
        guard let index = activeCreations.firstIndex(where: { $0.id == id }) else { return }
        activeCreations[index].progress = CreationProgress(
            phase: phase,
            message: message,
            percentComplete: percentComplete.map { UInt8(clamping: $0) }
        )
        saveCreations()
    }

    func cancelCreation(_ id: String) {
        updateCreationStatus(id, status: .cancelled)
    }

    func resumeCreation(_ id: String) {
        guard let creation = activeCreations.first(where: { $0.id == id }),
              let sessionId = creation.sessionId,
              (creation.status == .failed || creation.status == .cancelled) else {
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

    func getActiveCreationsCount() -> Int {
        activeCreations.filter { $0.status == .pending || $0.status == .inProgress }.count
    }

    private func launchClaudeResume(projectPath: String, sessionId: String, creationId: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            PROJECT_PATH="\(projectPath)"
            SESSION_ID="\(sessionId)"
            CLAUDE_CMD="/opt/homebrew/bin/claude --resume $SESSION_ID"

            if [ -d "/Applications/Ghostty.app" ]; then
                open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH" -e bash -c "$CLAUDE_CMD"
            elif [ -d "/Applications/iTerm.app" ]; then
                osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "iTerm" to activate'
            else
                osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "Terminal" to activate'
            fi
        """]

        try process.run()

        startCompletionMonitor(projectPath: projectPath, creationId: creationId, sessionId: sessionId)
    }

    func orderedProjects(_ projects: [Project]) -> [Project] {
        guard !customProjectOrder.isEmpty else { return projects }

        var result: [Project] = []
        var remaining = projects

        for path in customProjectOrder {
            if let index = remaining.firstIndex(where: { $0.path == path }) {
                result.append(remaining.remove(at: index))
            }
        }
        result.append(contentsOf: remaining)
        return result
    }

    func moveProject(from source: IndexSet, to destination: Int, in projectList: [Project]) {
        var paths = projectList.map { $0.path }
        paths.move(fromOffsets: source, toOffset: destination)
        customProjectOrder = paths
    }

    func loadDashboard() {
        guard let engine = engine else { return }
        isLoading = true

        do {
            dashboard = try engine.loadDashboard()
            projects = dashboard?.projects ?? []
            updateTerminalTracking() // Update project mapping for live tracking
            artifacts = engine.listArtifacts()
            refreshSessionStates()
            refreshProjectStatuses()
            refreshDevServers()
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func refreshSessionStates() {
        guard let engine = engine else { return }
        var states = engine.getAllSessionStates(projects: projects)

        // Cross-check: The lock file is the source of truth for whether Claude is running.
        // The state file may be stale because hooks write to cwd, which can differ from
        // the pinned project path (e.g., running from apps/swift but pinned at claude-hud).
        for (path, state) in states {
            if state.isLocked {
                // Lock exists = Claude IS running for this project (or a related path)
                if state.state == .idle {
                    // State file says idle, but lock proves Claude is running
                    // This happens when hooks write to a different cwd than the pinned project
                    // Default to "ready" since we don't know if it's actively working
                    states[path] = ProjectSessionState(
                        state: .ready,
                        stateChangedAt: nil,
                        sessionId: state.sessionId,
                        workingOn: state.workingOn,
                                context: state.context,
                        thinking: nil,
                        isLocked: true
                    )
                }
                // If state is "working" or "ready" and locked, that's valid - keep it
            } else {
                // No lock = Claude is definitely not running for this project
                if state.state == .working || state.state == .compacting {
                    // "working"/"compacting" without lock means Claude finished or terminated
                    // Show as "ready" since user can resume the session
                    states[path] = ProjectSessionState(
                        state: .ready,
                        stateChangedAt: state.stateChangedAt,
                        sessionId: state.sessionId,
                        workingOn: state.workingOn,
                                context: state.context,
                        thinking: false,
                        isLocked: false
                    )
                } else if state.state == .ready {
                    // "ready" without lock means session ended but SessionEnd hook didn't fire
                    // Check staleness: if state is older than 2 minutes, mark as idle
                    if let stateChangedAt = state.stateChangedAt,
                       let changeDate = ISO8601DateFormatter().date(from: stateChangedAt),
                       Date().timeIntervalSince(changeDate) > 120 {
                        states[path] = ProjectSessionState(
                            state: .idle,
                            stateChangedAt: state.stateChangedAt,
                            sessionId: state.sessionId,
                            workingOn: state.workingOn,
                                        context: state.context,
                            thinking: false,
                            isLocked: false
                        )
                    }
                }
            }
        }

        sessionStates = states
        checkForStateChanges()
    }

    private func checkForStateChanges() {
        for (path, sessionState) in sessionStates {
            let current = sessionState.state
            if let previous = previousSessionStates[path], previous != current {
                switch current {
                case .ready, .waiting, .compacting:
                    flashingProjects[path] = current
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                        self?.flashingProjects.removeValue(forKey: path)
                    }
                case .working, .idle:
                    break
                }
            }
            previousSessionStates[path] = current
        }
    }

    func isFlashing(_ project: Project) -> SessionState? {
        flashingProjects[project.path]
    }

    func refreshProjectStatuses() {
        guard let engine = engine else { return }
        for project in projects {
            if let status = engine.getProjectStatus(projectPath: project.path) {
                projectStatuses[project.path] = status
            }
        }
    }

    func getProjectStatus(for project: Project) -> ProjectStatus? {
        projectStatuses[project.path]
    }

    func addProject(_ path: String) {
        guard let engine = engine else { return }
        do {
            try engine.addProject(path: path)
            loadDashboard()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeProject(_ path: String) {
        guard let engine = engine else { return }
        do {
            try engine.removeProject(path: path)
            loadDashboard()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Finds the most relevant state for a project by checking both the pinned path
    /// and any child paths (subdirectories). Returns the state with the most recent
    /// `context.updated_at` timestamp.
    ///
    /// This is needed because Claude Code hooks write to the cwd, which may be a
    /// subdirectory of the pinned project path. For example:
    /// - Pinned project: `/Users/foo/claude-hud`
    /// - Actual cwd: `/Users/foo/claude-hud/apps/swift`
    ///
    /// We want to show the freshest state data regardless of which path it's keyed under.
    private func findMostRecentState(for projectPath: String) -> ProjectSessionState? {
        var bestState: ProjectSessionState? = nil
        var bestTimestamp: Date? = nil
        let isoFormatter = ISO8601DateFormatter()

        for (path, state) in sessionStates {
            // Match exact path OR child paths (paths that start with project path + "/")
            let isMatch = (path == projectPath) || path.hasPrefix(projectPath + "/")

            if isMatch {
                // Parse the timestamp from context.updated_at
                var stateTimestamp: Date? = nil
                if let updatedAt = state.context?.updatedAt {
                    stateTimestamp = isoFormatter.date(from: updatedAt)
                }

                // If no timestamp, fall back to stateChangedAt
                if stateTimestamp == nil, let stateChangedAt = state.stateChangedAt {
                    stateTimestamp = isoFormatter.date(from: stateChangedAt)
                }

                // Compare timestamps to find the most recent
                if let current = stateTimestamp {
                    if bestTimestamp == nil || current > bestTimestamp! {
                        bestState = state
                        bestTimestamp = current
                    }
                } else if bestState == nil {
                    // No timestamp but we have no state yet - use this one
                    bestState = state
                }
            }
        }

        return bestState
    }

    func getSessionState(for project: Project) -> ProjectSessionState? {
        // First, find the most relevant state for this project.
        // Hooks write to the cwd, which may be a subdirectory of the pinned project.
        // We need to check BOTH the pinned path AND any child paths, using the most recent.
        guard var state = findMostRecentState(for: project.path) else {
            return nil
        }

        // If we got state from a child path, it might have is_locked=false even though
        // the parent project IS locked. Check if the parent is locked and inherit that.
        if !state.isLocked {
            if let parentState = sessionStates[project.path], parentState.isLocked {
                state = ProjectSessionState(
                    state: state.state,
                    stateChangedAt: state.stateChangedAt,
                    sessionId: state.sessionId,
                    workingOn: state.workingOn,
                        context: state.context,
                    thinking: state.thinking,
                    isLocked: true  // Inherit lock from parent
                )
            }
        }

        // Check if the "thinking" state is stale
        // The thinking flag is updated by PostToolUse hooks. If it's been more than
        // 30 seconds since the last update and thinking=true, Claude likely finished
        // working and is waiting for input (Ready state).
        let thinkingStalenessThreshold: TimeInterval = 30
        var effectiveThinking = state.thinking

        if let thinking = state.thinking, thinking {
            // thinking=true, but check if it's stale
            if let thinkingUpdatedAt = state.context?.updatedAt,
               let updateDate = ISO8601DateFormatter().date(from: thinkingUpdatedAt),
               Date().timeIntervalSince(updateDate) > thinkingStalenessThreshold {
                // thinking=true is stale - treat as false
                effectiveThinking = false
            }
        }

        // Use the effective thinking state (after staleness check)
        // But TRUST THE LOCK: if isLocked=true, Claude IS running - don't downgrade.
        if let thinking = effectiveThinking {
            if thinking {
                // Claude is actively making API calls - definitely working
                return ProjectSessionState(
                    state: .working,
                    stateChangedAt: state.stateChangedAt,
                    sessionId: state.sessionId,
                    workingOn: state.workingOn,
                        context: state.context,
                    thinking: true,
                    isLocked: state.isLocked
                )
            } else if state.state == .working && !state.isLocked {
                // thinking=false AND no lock means Claude actually finished
                // The session ended but hooks were slow to update
                return ProjectSessionState(
                    state: .ready,
                    stateChangedAt: state.stateChangedAt,
                    sessionId: state.sessionId,
                    workingOn: state.workingOn,
                        context: state.context,
                    thinking: false,
                    isLocked: false
                )
            }
            // If state=working AND isLocked=true, trust it - Claude is working
            // (even if thinking is stale, Claude could be generating a long response)
        }

        // Staleness-based "Waiting" detection
        // IMPORTANT: Only use in remote mode where we have reliable heartbeats.
        // Local mode staleness detection is too unreliable - Claude can generate
        // long text responses without tool use, causing false "Waiting" states.
        if state.state == .working && isRemoteMode {
            let stalenessThreshold: TimeInterval = 30

            // Find the most recent heartbeat from any subdirectory of this project
            // Heartbeats are keyed by cwd which may be a subdirectory of the pinned project path
            let lastHeartbeat = relayClient.projectHeartbeats
                .filter { $0.key.hasPrefix(project.path) }
                .map { $0.value }
                .max()

            // If we have a heartbeat, check its staleness
            if let heartbeat = lastHeartbeat {
                if Date().timeIntervalSince(heartbeat) > stalenessThreshold {
                    return ProjectSessionState(
                        state: .waiting,
                        stateChangedAt: state.stateChangedAt,
                        sessionId: state.sessionId,
                        workingOn: state.workingOn,
                                context: state.context,
                        thinking: state.thinking,
                        isLocked: state.isLocked
                    )
                }
            } else if let connectedAt = relayClient.connectedAt,
                      Date().timeIntervalSince(connectedAt) > stalenessThreshold {
                // No heartbeats received, but we've been connected long enough
                // If Claude were actually working, we would have received heartbeats by now
                return ProjectSessionState(
                    state: .waiting,
                    stateChangedAt: state.stateChangedAt,
                    sessionId: state.sessionId,
                    workingOn: state.workingOn,
                        context: state.context,
                    thinking: state.thinking,
                    isLocked: state.isLocked
                )
            }
        }

        return state
    }

    func launchTerminal(for project: Project) {
        // Set active project when launching terminal
        activeProjectPath = project.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            SESSION="\(project.name)"
            PROJECT_PATH="\(project.path)"

            # Check if tmux is installed
            if ! command -v tmux &> /dev/null; then
                # NO TMUX: Open terminal directly in project directory
                if [ -d "/Applications/Ghostty.app" ]; then
                    open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH"
                elif [ -d "/Applications/iTerm.app" ]; then
                    osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PROJECT_PATH' && exec $SHELL\\""
                    osascript -e 'tell application "iTerm" to activate'
                elif [ -d "/Applications/Alacritty.app" ]; then
                    open -na "Alacritty.app" --args --working-directory "$PROJECT_PATH"
                elif command -v kitty &>/dev/null; then
                    kitty --directory "$PROJECT_PATH" &
                elif [ -d "/Applications/Warp.app" ]; then
                    open -a "Warp" "$PROJECT_PATH"
                else
                    osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PROJECT_PATH'\\""
                    osascript -e 'tell application "Terminal" to activate'
                fi
                exit 0
            fi

            # TMUX AVAILABLE: Use session management
            # Check if any tmux client is attached (i.e., a terminal is running tmux)
            HAS_ATTACHED_CLIENT=$(tmux list-clients 2>/dev/null | head -1)

            if [ -n "$HAS_ATTACHED_CLIENT" ]; then
                # A tmux client exists - we can switch sessions
                if tmux has-session -t "$SESSION" 2>/dev/null; then
                    # Session exists, switch to it
                    tmux switch-client -t "$SESSION" 2>/dev/null
                else
                    # Create session and switch
                    tmux new-session -d -s "$SESSION" -c "$PROJECT_PATH"
                    tmux switch-client -t "$SESSION" 2>/dev/null
                fi

                # Activate the terminal that has tmux
                if pgrep -xq "Ghostty"; then
                    osascript -e 'tell application "Ghostty" to activate'
                elif pgrep -xq "iTerm2"; then
                    osascript -e 'tell application "iTerm" to activate'
                elif pgrep -xq "WarpTerminal"; then
                    osascript -e 'tell application "Warp" to activate'
                elif pgrep -xq "Alacritty"; then
                    osascript -e 'tell application "Alacritty" to activate'
                elif pgrep -xq "kitty"; then
                    osascript -e 'tell application "kitty" to activate'
                elif pgrep -xq "Terminal"; then
                    osascript -e 'tell application "Terminal" to activate'
                fi
            else
                # No tmux client attached - need to launch a new terminal
                # Use tmux new-session -A which attaches if exists, creates if not
                TMUX_CMD="tmux new-session -A -s '$SESSION' -c '$PROJECT_PATH'"

                # Try to launch with preferred terminal (in order of preference)
                if [ -d "/Applications/Ghostty.app" ]; then
                    open -na "Ghostty.app" --args -e sh -c "$TMUX_CMD"
                elif [ -d "/Applications/iTerm.app" ]; then
                    osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"$TMUX_CMD\\""
                    osascript -e 'tell application "iTerm" to activate'
                elif [ -d "/Applications/Alacritty.app" ]; then
                    open -na "Alacritty.app" --args -e sh -c "$TMUX_CMD"
                elif command -v kitty &>/dev/null; then
                    kitty sh -c "$TMUX_CMD" &
                elif [ -d "/Applications/Warp.app" ]; then
                    # Warp has limited tmux support, just open directory
                    open -a "Warp" "$PROJECT_PATH"
                else
                    # Fallback to Terminal.app
                    osascript -e "tell application \\"Terminal\\" to do script \\"$TMUX_CMD\\""
                    osascript -e 'tell application "Terminal" to activate'
                fi
            fi
        """]
        try? process.run()
    }

    func showProjectDetail(_ project: Project) {
        selectedProject = project
        projectView = .detail(project)
    }

    func showAddProject() {
        projectView = .add
    }

    func showNewIdea() {
        projectView = .newIdea
    }

    func showProjectList() {
        selectedProject = nil
        projectView = .list
    }

    func createProjectFromIdea(_ request: NewProjectRequest, completion: @escaping (CreateProjectResult) -> Void) {
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
                        error: error.localizedDescription
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
                error: "Project directory already exists"
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
                error: "Failed to run Claude: \(error.localizedDescription)"
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
            error: nil
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            PROJECT_PATH="\(projectPath)"
            PROMPT_FILE="\(promptFile.path)"
            CLAUDE_CMD="/opt/homebrew/bin/claude \\"\\$(cat '$PROMPT_FILE')\\" ; rm -f '$PROMPT_FILE'"

            # Try terminals in preference order
            if [ -d "/Applications/Ghostty.app" ]; then
                open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH" -e bash -c "$CLAUDE_CMD"
            elif [ -d "/Applications/iTerm.app" ]; then
                osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "iTerm" to activate'
            elif [ -d "/Applications/Warp.app" ]; then
                osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "Terminal" to activate'
            else
                osascript -e "tell application \\"Terminal\\" to do script \\"cd '$PROJECT_PATH' && $CLAUDE_CMD\\""
                osascript -e 'tell application "Terminal" to activate'
            fi
        """]

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

            for _ in 0..<maxAttempts {
                try? await _Concurrency.Task.sleep(nanoseconds: pollInterval)

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

            for _ in 0..<300 {
                try? await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)

                guard let creation = activeCreations.first(where: { $0.id == creationId }),
                      creation.status == .inProgress else {
                    return
                }

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFile.path),
                      let currentSize = attrs[.size] as? UInt64 else {
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

    func moveToDormant(_ project: Project) {
        manuallyDormant.insert(project.path)
    }

    func moveToRecent(_ project: Project) {
        manuallyDormant.remove(project.path)
    }

    func isManuallyDormant(_ project: Project) -> Bool {
        manuallyDormant.contains(project.path)
    }

    nonisolated func refreshDevServers() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self = self else { return }
            let projectsCopy = self.projects

            for project in projectsCopy {
                let projectPath = project.path

                let port = await DevEnvironment.findDevServerPort(for: projectPath)

                if let port = port {
                    self.devServerPorts[projectPath] = port

                    let browser = await DevEnvironment.findBrowserWithLocalhost(port: port)
                    if let browser = browser {
                        self.devServerBrowsers[projectPath] = browser
                    }
                } else {
                    self.devServerPorts.removeValue(forKey: projectPath)
                    self.devServerBrowsers.removeValue(forKey: projectPath)
                }
            }
        }
    }

    func getDevServerPort(for project: Project) -> UInt16? {
        devServerPorts[project.path]
    }

    func hasDevServer(_ project: Project) -> Bool {
        devServerPorts[project.path] != nil
    }

    func openInBrowser(_ project: Project) {
        guard let port = devServerPorts[project.path] else { return }

        if let browser = devServerBrowsers[project.path] {
            DevEnvironment.focusBrowserTab(browser: browser, port: port)
        } else {
            DevEnvironment.openInBrowser(port: port)
        }
    }

    func launchFullEnvironment(for project: Project) {
        launchTerminal(for: project)

        if let port = devServerPorts[project.path] {
            if let browser = devServerBrowsers[project.path] {
                DevEnvironment.focusBrowserTab(browser: browser, port: port)
            } else {
                DevEnvironment.openInBrowser(port: port)
            }
        }
    }
}
