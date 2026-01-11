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

    static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list), (.add, .add):
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
    @Published var navigationDirection: NavigationDirection = .push

    // Data
    @Published var dashboard: DashboardData?
    @Published var sessionStates: [String: ProjectSessionState] = [:]
    @Published var projectStatuses: [String: ProjectStatus] = [:]
    @Published var artifacts: [Artifact] = []
    @Published var projects: [Project] = []

    // UI State
    @Published var isLoading = true
    @Published var error: String?
    @Published var alwaysOnTop = false
    @Published var flashingProjects: [String: SessionState] = [:]

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

    init() {
        loadDormantOverrides()
        loadProjectOrder()
        do {
            engine = try HudEngine()
            loadDashboard()
            setupRelayObserver()
            setupStalenessTimer()
        } catch {
            self.error = error.localizedDescription
            self.isLoading = false
        }
    }

    private func setupStalenessTimer() {
        // Check every second for responsive staleness detection
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
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
                nextStep: projectState.nextStep,
                context: nil
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
        sessionStates = engine.getAllSessionStates(projects: projects)
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

    func getSessionState(for project: Project) -> ProjectSessionState? {
        guard let state = sessionStates[project.path] else {
            return nil
        }

        if state.state == .working {
            let stalenessThreshold: TimeInterval = 5

            if isRemoteMode {
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
                            nextStep: state.nextStep,
                            context: state.context
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
                        nextStep: state.nextStep,
                        context: state.context
                    )
                }
            } else {
                let lastHeartbeat: Date?
                if let updatedAt = state.context?.updatedAt {
                    lastHeartbeat = ISO8601DateFormatter().date(from: updatedAt)
                } else if let stateChangedAt = state.stateChangedAt {
                    lastHeartbeat = ISO8601DateFormatter().date(from: stateChangedAt)
                } else {
                    lastHeartbeat = nil
                }

                if let heartbeat = lastHeartbeat,
                   Date().timeIntervalSince(heartbeat) > stalenessThreshold {
                    return ProjectSessionState(
                        state: .waiting,
                        stateChangedAt: state.stateChangedAt,
                        sessionId: state.sessionId,
                        workingOn: state.workingOn,
                        nextStep: state.nextStep,
                        context: state.context
                    )
                }
            }
        }

        return state
    }

    func launchTerminal(for project: Project) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            SESSION="\(project.name)"

            # Check if session already exists
            if tmux has-session -t "$SESSION" 2>/dev/null; then
                # Session exists - just switch to it
                tmux switch-client -t "$SESSION" 2>/dev/null || true
            else
                # Create new session
                tmux new-session -d -s "$SESSION" -c "\(project.path)"
                tmux switch-client -t "$SESSION" 2>/dev/null || true
            fi

            # Activate whichever terminal app is running tmux
            # Check common terminal apps in order of likelihood
            if pgrep -xq "iTerm2"; then
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
        """]
        try? process.run()
    }

    func showProjectDetail(_ project: Project) {
        navigationDirection = .push
        selectedProject = project
        projectView = .detail(project)
    }

    func showAddProject() {
        navigationDirection = .push
        projectView = .add
    }

    func showProjectList() {
        navigationDirection = .pop
        selectedProject = nil
        projectView = .list
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
