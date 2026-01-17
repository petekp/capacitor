import Combine
import Foundation
import SwiftUI

enum Tab: String, CaseIterable {
    case projects
    case artifacts
}

enum LayoutMode: String, CaseIterable {
    case vertical
    case dock
}

enum ProjectView: Equatable {
    case list
    case detail(Project)
    case add
    case addLink
    case newIdea

    static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list), (.add, .add), (.addLink, .addLink), (.newIdea, .newIdea):
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
    // MARK: - Layout Mode

    @Published var layoutMode: LayoutMode = .vertical {
        didSet { saveLayoutMode() }
    }

    // MARK: - Navigation

    @Published var activeTab: Tab = .projects
    @Published var projectView: ProjectView = .list
    @Published var selectedProject: Project?

    /// Path pending validation when navigating to AddProjectView
    /// Set by HeaderView's folder picker, consumed by AddProjectView on appear
    @Published var pendingProjectPath: String?

    // MARK: - Data

    @Published var dashboard: DashboardData?
    @Published var artifacts: [Artifact] = []
    @Published var projects: [Project] = []

    // MARK: - Active project creations (Idea → V1)

    @Published var activeCreations: [ProjectCreation] = []
    private let creationsKey = "activeProjectCreations"

    // MARK: - UI State

    @Published var isLoading = true
    @Published var error: String?

    // MARK: - Dev Environment

    @Published var devServerPorts: [String: UInt16] = [:]
    @Published var devServerBrowsers: [String: String] = [:]

    // MARK: - Manual dormant overrides

    @Published var manuallyDormant: Set<String> = [] {
        didSet { saveDormantOverrides() }
    }

    // MARK: - Custom project ordering

    @Published var customProjectOrder: [String] = [] {
        didSet { saveProjectOrder() }
    }

    // MARK: - Relay client for remote state sync

    @Published var relayClient = RelayClient()
    @Published var isRemoteMode = false

    // MARK: - Modal State for Idea Capture

    @Published var showCaptureModal = false
    @Published var captureModalProject: Project?

    // MARK: - Managers (extracted for cleaner architecture)

    let terminalIntegration = TerminalIntegration()
    let sessionStateManager = SessionStateManager()
    let projectDetailsManager = ProjectDetailsManager()

    // MARK: - Private State

    private let dormantOverridesKey = "manuallyDormantProjects"
    private let projectOrderKey = "customProjectOrder"
    private let layoutModeKey = "layoutMode"
    private var engine: HudEngine?
    private var cancellables = Set<AnyCancellable>()
    private var stalenessTimer: Timer?

    // MARK: - Computed Properties (bridging to managers)

    var sessionStates: [String: ProjectSessionState] {
        sessionStateManager.sessionStates
    }

    var projectStatuses: [String: ProjectStatus] {
        var statuses: [String: ProjectStatus] = [:]
        for project in projects {
            if let status = engine?.getProjectStatus(projectPath: project.path) {
                statuses[project.path] = status
            }
        }
        return statuses
    }

    var activeProjectPath: String? {
        terminalIntegration.activeProjectPath
    }

    var flashingProjects: [String: SessionState] {
        sessionStateManager.flashingProjects
    }

    var projectIdeas: [String: [Idea]] {
        projectDetailsManager.projectIdeas
    }

    var generatingTitleForIdeas: Set<String> {
        projectDetailsManager.generatingTitleForIdeas
    }

    var projectDescriptions: [String: String] {
        projectDetailsManager.projectDescriptions
    }

    var generatingDescriptionFor: Set<String> {
        projectDetailsManager.generatingDescriptionFor
    }

    // MARK: - Initialization

    init() {
        loadLayoutMode()
        loadDormantOverrides()
        loadProjectOrder()
        loadCreations()
        do {
            engine = try HudEngine()
            sessionStateManager.configure(engine: engine)
            projectDetailsManager.configure(engine: engine)
            loadDashboard()
            setupRelayObserver()
            setupStalenessTimer()
            startTerminalTracking()
        } catch {
            self.error = error.localizedDescription
            self.isLoading = false
        }
    }

    // MARK: - Setup

    private func setupStalenessTimer() {
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshSessionStates()
                self?.checkIdeasFileChanges()
            }
        }
    }

    private func setupRelayObserver() {
        relayClient.$lastState
            .compactMap { $0 }
            .sink { [weak self] state in
                self?.sessionStateManager.applyRelayState(state)
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        relayClient.$isConnected
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        relayClient.$connectionError
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        relayClient.$projectHeartbeats
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        relayClient.$connectedAt
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func startTerminalTracking() {
        _Concurrency.Task {
            await terminalIntegration.startTracking(projects: projects)
        }
    }

    // MARK: - Data Loading

    func loadDashboard() {
        guard let engine = engine else { return }
        isLoading = true

        do {
            dashboard = try engine.loadDashboard()
            projects = dashboard?.projects ?? []
            terminalIntegration.updateProjectMapping(projects)
            artifacts = engine.listArtifacts()
            refreshSessionStates()
            refreshProjectStatuses()
            refreshDevServers()
            projectDetailsManager.loadAllIdeas(for: projects)
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func refreshSessionStates() {
        sessionStateManager.refreshSessionStates(for: projects)
        objectWillChange.send()
    }

    func refreshProjectStatuses() {
        objectWillChange.send()
    }

    // MARK: - Project Management

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

    /// Validates a project path before adding.
    /// Returns the validation result for UI handling.
    func validateProject(_ path: String) -> ValidationResultFfi? {
        guard let engine = engine else { return nil }
        return engine.validateProject(path: path)
    }

    /// Creates a CLAUDE.md file for a project.
    func createClaudeMd(for path: String) -> Bool {
        guard let engine = engine else { return false }
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
        sessionStateManager.getSessionState(for: project, relayClient: relayClient, isRemoteMode: isRemoteMode)
    }

    func isFlashing(_ project: Project) -> SessionState? {
        sessionStateManager.isFlashing(project)
    }

    func getProjectStatus(for project: Project) -> ProjectStatus? {
        engine?.getProjectStatus(projectPath: project.path)
    }

    // MARK: - Terminal Operations (delegating to TerminalIntegration)

    func launchTerminal(for project: Project) {
        terminalIntegration.launchTerminal(for: project)
        objectWillChange.send()
    }

    // MARK: - Navigation

    func showProjectDetail(_ project: Project) {
        selectedProject = project
        projectView = .detail(project)
    }

    func showAddProject(withPath path: String? = nil) {
        if let path = path {
            pendingProjectPath = path
            projectView = .addLink
        } else {
            projectView = .add
        }
    }

    func showAddLink() {
        projectView = .addLink
    }

    func showNewIdea() {
        projectView = .newIdea
    }

    func showProjectList() {
        selectedProject = nil
        projectView = .list
    }

    // MARK: - Relay

    func connectRelay() {
        isRemoteMode = true
        relayClient.connect()
    }

    func disconnectRelay() {
        isRemoteMode = false
        relayClient.disconnect()
    }

    // MARK: - Layout Mode Persistence

    private func loadLayoutMode() {
        if let rawValue = UserDefaults.standard.string(forKey: layoutModeKey),
           let mode = LayoutMode(rawValue: rawValue) {
            layoutMode = mode
        }
    }

    private func saveLayoutMode() {
        UserDefaults.standard.set(layoutMode.rawValue, forKey: layoutModeKey)
    }

    // MARK: - Dormant/Order Persistence

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

    func moveToDormant(_ project: Project) {
        manuallyDormant.insert(project.path)
    }

    func moveToRecent(_ project: Project) {
        manuallyDormant.remove(project.path)
    }

    func isManuallyDormant(_ project: Project) -> Bool {
        manuallyDormant.contains(project.path)
    }

    // MARK: - Dev Environment

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

    // MARK: - Idea Capture (delegating to ProjectDetailsManager)

    func showIdeaCaptureModal(for project: Project) {
        captureModalProject = project
        showCaptureModal = true
    }

    func captureIdea(for project: Project, text: String) -> Result<Void, Error> {
        let result = projectDetailsManager.captureIdea(for: project, text: text)
        objectWillChange.send()
        return result
    }

    func loadIdeas(for project: Project) {
        projectDetailsManager.loadIdeas(for: project)
        objectWillChange.send()
    }

    func loadAllIdeas() {
        projectDetailsManager.loadAllIdeas(for: projects)
        objectWillChange.send()
    }

    func checkIdeasFileChanges() {
        projectDetailsManager.checkIdeasFileChanges(for: projects)
    }

    func getIdeas(for project: Project) -> [Idea] {
        projectDetailsManager.getIdeas(for: project)
    }

    func isGeneratingTitle(for ideaId: String) -> Bool {
        projectDetailsManager.isGeneratingTitle(for: ideaId)
    }

    func workOnIdea(_ idea: Idea, for project: Project) {
        do {
            try projectDetailsManager.updateIdeaStatus(for: project, idea: idea, newStatus: "in-progress")
        } catch {
            self.error = "Failed to update idea status: \(error.localizedDescription)"
        }

        terminalIntegration.launchTerminalWithIdea(idea, for: project)
        objectWillChange.send()
    }

    func dismissIdea(_ idea: Idea, for project: Project) {
        do {
            try projectDetailsManager.updateIdeaStatus(for: project, idea: idea, newStatus: "done")
        } catch {
            self.error = "Failed to dismiss idea: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func reorderIdeas(for project: Project, from source: IndexSet, to destination: Int) {
        projectDetailsManager.reorderIdeas(for: project, from: source, to: destination)
        objectWillChange.send()
    }

    // MARK: - Project Descriptions (delegating to ProjectDetailsManager)

    func getDescription(for project: Project) -> String? {
        projectDetailsManager.getDescription(for: project)
    }

    func isGeneratingDescription(for project: Project) -> Bool {
        projectDetailsManager.isGeneratingDescription(for: project)
    }

    func generateDescription(for project: Project) {
        projectDetailsManager.generateDescription(for: project)
    }

    // MARK: - Project Creation

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
}
