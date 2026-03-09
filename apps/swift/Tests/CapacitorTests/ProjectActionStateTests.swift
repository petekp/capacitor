@testable import Capacitor
import XCTest

@MainActor
final class ProjectActionStateTests: XCTestCase {
    func testConnectSelectedSuggestionsPublishesSuccessToast() {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: StubProjectCatalogGateway())
        let projectListState = ProjectListState(projectListPreferencesGateway: StubProjectListPreferencesGateway())
        let gateway = StubProjectMutationGateway()
        let suggestion = ShellSuggestedProjectCandidate(
            displayName: "Capacitor",
            path: "/tmp/capacitor",
            displayPath: "/tmp/capacitor",
            taskCount: 0,
            hasClaudeMd: true,
            hasProjectIndicators: true,
        )
        workflowState.replaceSuggestedProjectCatalog(with: [suggestion])
        workflowState.toggleSuggestedProjectSelection(path: suggestion.path)

        var toast: ToastMessage?
        let actionState = ProjectActionState(
            projectMutationService: ProjectMutationService(
                projectMutationGateway: gateway,
                projectWorkflowState: workflowState,
                projectListState: projectListState,
            ),
            isRuntimeAvailable: { true },
            writeToast: { toast = $0 },
        )

        actionState.connectSelectedSuggestions()

        XCTAssertEqual(toast?.message, "Connected 1 project")
        XCTAssertEqual(toast?.isError, false)
    }

    func testRemoveProjectReportsMutationErrors() {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: StubProjectCatalogGateway())
        let projectListState = ProjectListState(projectListPreferencesGateway: StubProjectListPreferencesGateway())
        let gateway = StubProjectMutationGateway(removeProjectError: NSError(domain: "ProjectActionStateTests", code: 7))

        var reportedError: String?
        let actionState = ProjectActionState(
            projectMutationService: ProjectMutationService(
                projectMutationGateway: gateway,
                projectWorkflowState: workflowState,
                projectListState: projectListState,
            ),
            isRuntimeAvailable: { true },
            writeError: { reportedError = $0 },
        )

        actionState.removeProject(path: "/tmp/capacitor")

        XCTAssertNotNil(reportedError)
        XCTAssertTrue(reportedError?.contains("ProjectActionStateTests error 7") == true)
    }

    func testCreateClaudeMdReturnsFalseWhenRuntimeIsUnavailable() {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: StubProjectCatalogGateway())
        let projectListState = ProjectListState(projectListPreferencesGateway: StubProjectListPreferencesGateway())
        let gateway = StubProjectMutationGateway()

        var reportedError: String?
        let actionState = ProjectActionState(
            projectMutationService: ProjectMutationService(
                projectMutationGateway: gateway,
                projectWorkflowState: workflowState,
                projectListState: projectListState,
            ),
            isRuntimeAvailable: { false },
            writeError: { reportedError = $0 },
        )

        let didCreate = actionState.createClaudeMd(for: "/tmp/capacitor")

        XCTAssertFalse(didCreate)
        XCTAssertNil(reportedError)
        XCTAssertEqual(gateway.createdClaudeMdPaths, [])
    }

    func testConnectProjectSelectionSetsPendingTipForNewConnection() {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: StubProjectCatalogGateway())
        let projectListState = ProjectListState(projectListPreferencesGateway: StubProjectListPreferencesGateway())
        let gateway = StubProjectMutationGateway(validationResults: [
            "/tmp/capacitor": ShellProjectValidationResult(
                kind: .valid,
                path: "/tmp/capacitor",
                suggestedPath: nil,
                reason: nil,
                hasClaudeMd: true,
                hasOtherMarkers: true,
            ),
        ])
        let actionState = ProjectActionState(
            projectMutationService: ProjectMutationService(
                projectMutationGateway: gateway,
                projectWorkflowState: workflowState,
                projectListState: projectListState,
            ),
            isRuntimeAvailable: { true },
        )

        actionState.connectProjectSelection(path: "/tmp/capacitor")

        XCTAssertTrue(actionState.pendingDragDropTip)
        XCTAssertEqual(gateway.addedPaths, ["/tmp/capacitor"])
    }

    func testImportProjectsPublishesFailureFirstToastAndSetsPendingTip() async throws {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: StubProjectCatalogGateway())
        let projectListState = ProjectListState(projectListPreferencesGateway: StubProjectListPreferencesGateway())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let validPath = root.appendingPathComponent("valid", isDirectory: true).path
        let invalidPath = root.appendingPathComponent("invalid", isDirectory: true).path

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: validPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: invalidPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gateway = StubProjectMutationGateway(validationResults: [
            validPath: ShellProjectValidationResult(
                kind: .valid,
                path: validPath,
                suggestedPath: nil,
                reason: nil,
                hasClaudeMd: true,
                hasOtherMarkers: true,
            ),
            invalidPath: ShellProjectValidationResult(
                kind: .notAProject,
                path: invalidPath,
                suggestedPath: nil,
                reason: nil,
                hasClaudeMd: false,
                hasOtherMarkers: false,
            ),
        ])

        var toast: ToastMessage?
        let service = ProjectMutationService(
            projectMutationGateway: gateway,
            projectWorkflowState: workflowState,
            projectListState: projectListState,
            projectImportProcessor: LiveProjectImportBatchProcessor(projectMutationGateway: gateway),
        )
        let actionState = ProjectActionState(
            projectMutationService: service,
            isRuntimeAvailable: { true },
            writeToast: { toast = $0 },
        )
        var ensureProjectListVisibleCount = 0

        await actionState.importProjects(
            from: [URL(fileURLWithPath: validPath), URL(fileURLWithPath: invalidPath)],
            ensureProjectListVisible: {
                ensureProjectListVisibleCount += 1
            },
        )

        XCTAssertEqual(ensureProjectListVisibleCount, 1)
        XCTAssertTrue(actionState.pendingDragDropTip)
        XCTAssertEqual(toast?.message, "invalid (not a project) failed (1 connected)")
        XCTAssertEqual(toast?.isError, true)
    }
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
    func loadDormantProjectPaths() -> Set<String> {
        []
    }

    func saveDormantProjectPaths(_: Set<String>) {}
    func loadProjectOrder() -> [String] {
        []
    }

    func saveProjectOrder(_: [String]) {}
    func migrateProjectOrderIfNeeded() {}
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
        validationResults[path] ?? ShellProjectValidationResult(
            kind: .valid,
            path: path,
            suggestedPath: nil,
            reason: nil,
            hasClaudeMd: true,
            hasOtherMarkers: true,
        )
    }

    func createProjectClaudeMd(projectPath: String) throws {
        createdClaudeMdPaths.append(projectPath)
    }
}
