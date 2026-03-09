@testable import Capacitor
import XCTest

@MainActor
final class ProjectMutationServiceTests: XCTestCase {
    func testResolveProjectSelectionUsesCanonicalTrackedPathForDormantRecovery() throws {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: StubProjectCatalogGateway())
        let projectListState = ProjectListState(
            projectListPreferencesGateway: StubProjectListPreferencesGateway(
                dormantProjectPaths: ["/canonical/project"],
            ),
        )
        let gateway = StubProjectMutationGateway(
            validationResults: [
                "/tmp/link": ShellProjectValidationResult(
                    kind: .alreadyTracked,
                    path: "/canonical/project",
                    suggestedPath: nil,
                    reason: nil,
                    hasClaudeMd: true,
                    hasOtherMarkers: true,
                ),
            ],
        )
        var reloadRequests: [ReloadRequest] = []
        let service = ProjectMutationService(
            projectMutationGateway: gateway,
            projectWorkflowState: workflowState,
            projectListState: projectListState,
            reloadDashboard: { hydrateIdeas, showLoadingState in
                reloadRequests.append(ReloadRequest(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState))
            },
        )

        let outcome = try service.resolveProjectSelection(path: "/tmp/link")

        XCTAssertEqual(
            outcome,
            .alreadyTracked(path: "/canonical/project", isDormant: true),
        )
        XCTAssertEqual(reloadRequests, [])
        XCTAssertEqual(gateway.addedPaths, [])

        service.moveTrackedProjectToRecent(path: "/canonical/project")
        XCTAssertFalse(projectListState.isManuallyDormant(path: "/canonical/project"))
    }

    func testConnectSelectedSuggestedProjectsUpdatesWorkflowStateAndReloadsDashboard() {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: StubProjectCatalogGateway())
        let projectListState = ProjectListState(
            projectListPreferencesGateway: StubProjectListPreferencesGateway(),
        )
        let first = ShellSuggestedProjectCandidate(
            displayName: "Capacitor",
            path: "/tmp/capacitor",
            displayPath: "/tmp/capacitor",
            taskCount: 0,
            hasClaudeMd: true,
            hasProjectIndicators: true,
        )
        let second = ShellSuggestedProjectCandidate(
            displayName: "Intent",
            path: "/tmp/intent",
            displayPath: "/tmp/intent",
            taskCount: 0,
            hasClaudeMd: false,
            hasProjectIndicators: true,
        )
        workflowState.replaceSuggestedProjectCatalog(with: [first, second])
        workflowState.toggleSuggestedProjectSelection(path: first.path)
        XCTAssertEqual(workflowState.selectedSuggestedProjectCandidates, [first])

        let gateway = StubProjectMutationGateway()
        var reloadRequests: [ReloadRequest] = []
        let service = ProjectMutationService(
            projectMutationGateway: gateway,
            projectWorkflowState: workflowState,
            projectListState: projectListState,
            reloadDashboard: { hydrateIdeas, showLoadingState in
                reloadRequests.append(ReloadRequest(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState))
            },
        )

        let outcome = service.connectSelectedSuggestedProjects()

        XCTAssertEqual(outcome.connectedCount, 1)
        XCTAssertEqual(gateway.addedPaths, ["/tmp/capacitor"])
        XCTAssertEqual(projectListState.projectOrder, ["/tmp/capacitor"])
        XCTAssertEqual(workflowState.suggestedProjectCatalog, [second])
        XCTAssertTrue(workflowState.selectedSuggestedPaths.isEmpty)
        XCTAssertEqual(reloadRequests, [ReloadRequest(hydrateIdeas: true, showLoadingState: true)])
    }

    func testImportProjectsFromDropPrependsAddedProjectsAndMovesDormantTrackedProjects() async throws {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: StubProjectCatalogGateway())
        let projectListState = ProjectListState(
            projectListPreferencesGateway: StubProjectListPreferencesGateway(
                dormantProjectPaths: ["/canonical/tracked"],
            ),
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let validPath = root.appendingPathComponent("valid", isDirectory: true).path
        let trackedPath = root.appendingPathComponent("tracked", isDirectory: true).path

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: validPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trackedPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gateway = StubProjectMutationGateway(
            validationResults: [
                validPath: ShellProjectValidationResult(
                    kind: .valid,
                    path: validPath,
                    suggestedPath: nil,
                    reason: nil,
                    hasClaudeMd: true,
                    hasOtherMarkers: true,
                ),
                trackedPath: ShellProjectValidationResult(
                    kind: .alreadyTracked,
                    path: "/canonical/tracked",
                    suggestedPath: nil,
                    reason: nil,
                    hasClaudeMd: true,
                    hasOtherMarkers: true,
                ),
            ],
        )
        var reloadRequests: [ReloadRequest] = []
        var deferredIdeaHydrationCount = 0
        let service = ProjectMutationService(
            projectMutationGateway: gateway,
            projectWorkflowState: workflowState,
            projectListState: projectListState,
            reloadDashboard: { hydrateIdeas, showLoadingState in
                reloadRequests.append(ReloadRequest(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState))
            },
            scheduleDeferredIdeaHydration: {
                deferredIdeaHydrationCount += 1
            },
            projectImportProcessor: LiveProjectImportBatchProcessor(projectMutationGateway: gateway),
        )

        let outcome = await service.importProjectsFromDrop(paths: [validPath, trackedPath])
        let recovery = service.recoverTrackedProjects(paths: outcome.alreadyTrackedPaths)

        XCTAssertEqual(outcome.addedPaths, [validPath])
        XCTAssertEqual(outcome.alreadyTrackedPaths, ["/canonical/tracked"])
        XCTAssertEqual(outcome.failedNames, [])
        XCTAssertEqual(recovery.movedPaths, ["/canonical/tracked"])
        XCTAssertEqual(recovery.alreadyInProgressCount, 0)
        XCTAssertEqual(projectListState.projectOrder, [validPath])
        XCTAssertFalse(projectListState.isManuallyDormant(path: "/canonical/tracked"))
        XCTAssertEqual(reloadRequests, [ReloadRequest(hydrateIdeas: false, showLoadingState: false)])
        XCTAssertEqual(deferredIdeaHydrationCount, 1)
    }

    func testRegisterCreatedProjectAddsProjectWithoutReloadingDashboard() throws {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: StubProjectCatalogGateway())
        let projectListState = ProjectListState(
            projectListPreferencesGateway: StubProjectListPreferencesGateway(),
        )
        let gateway = StubProjectMutationGateway()
        var reloadRequests: [ReloadRequest] = []
        let service = ProjectMutationService(
            projectMutationGateway: gateway,
            projectWorkflowState: workflowState,
            projectListState: projectListState,
            reloadDashboard: { hydrateIdeas, showLoadingState in
                reloadRequests.append(ReloadRequest(hydrateIdeas: hydrateIdeas, showLoadingState: showLoadingState))
            },
        )

        try service.registerCreatedProject(path: "/tmp/created-project")

        XCTAssertEqual(gateway.addedPaths, ["/tmp/created-project"])
        XCTAssertEqual(projectListState.projectOrder, [])
        XCTAssertEqual(reloadRequests, [])
    }
}

private struct ReloadRequest: Equatable {
    let hydrateIdeas: Bool
    let showLoadingState: Bool
}

private struct StubProjectCatalogGateway: ProjectCatalogGateway {
    func loadProjects() throws -> [ShellProjectCatalogEntry] {
        []
    }

    func loadSuggestedProjects() throws -> [ShellSuggestedProjectCandidate] {
        []
    }
}

private final class StubProjectListPreferencesGateway: ProjectListPreferencesGateway {
    private let initialDormantProjectPaths: Set<String>
    private let initialProjectOrder: [String]

    init(
        dormantProjectPaths: Set<String> = [],
        projectOrder: [String] = [],
    ) {
        initialDormantProjectPaths = dormantProjectPaths
        initialProjectOrder = projectOrder
    }

    func loadDormantProjectPaths() -> Set<String> {
        initialDormantProjectPaths
    }

    func saveDormantProjectPaths(_: Set<String>) {}

    func loadProjectOrder() -> [String] {
        initialProjectOrder
    }

    func saveProjectOrder(_: [String]) {}
}

private final class StubProjectMutationGateway: ProjectMutationGateway {
    let validationResults: [String: ShellProjectValidationResult]
    let removeProjectError: Error?
    private(set) var addedPaths: [String] = []
    private(set) var removedPaths: [String] = []
    private(set) var createdClaudeMdPaths: [String] = []

    init(
        validationResults: [String: ShellProjectValidationResult] = [:],
        removeProjectError: Error? = nil,
    ) {
        self.validationResults = validationResults
        self.removeProjectError = removeProjectError
    }

    func addProject(path: String) throws {
        addedPaths.append(path)
    }

    func removeProject(path: String) throws {
        if let removeProjectError {
            throw removeProjectError
        }
        removedPaths.append(path)
    }

    func validateProject(path: String) throws -> ShellProjectValidationResult {
        guard let result = validationResults[path] else {
            throw NSError(domain: "StubProjectMutationGateway", code: 1)
        }
        return result
    }

    func createProjectClaudeMd(projectPath: String) throws {
        createdClaudeMdPaths.append(projectPath)
    }
}
