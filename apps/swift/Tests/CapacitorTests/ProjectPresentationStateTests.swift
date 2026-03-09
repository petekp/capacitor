@testable import Capacitor
import CoreGraphics
import XCTest

@MainActor
final class ProjectPresentationStateTests: XCTestCase {
    func testIdeaCaptureModalGatesAreOwnedByPresentationState() {
        let project = makeProject()
        var modalProject: ShellProjectReference?
        var modalOrigin: CGRect?
        var showCaptureModal = false

        let details = StubProjectPresentationDetails()
        let disabled = makeState(
            ideaCaptureEnabled: false,
            projectCreationEnabled: false,
            llmFeaturesEnabled: false,
            details: details,
            modalProject: { modalProject = $0 },
            modalOrigin: { modalOrigin = $0 },
            showCaptureModal: { showCaptureModal = $0 },
        )

        disabled.showIdeaCaptureModal(for: project, from: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertNil(modalProject)
        XCTAssertNil(modalOrigin)
        XCTAssertFalse(showCaptureModal)

        let enabled = makeState(
            ideaCaptureEnabled: true,
            projectCreationEnabled: false,
            llmFeaturesEnabled: false,
            details: details,
            modalProject: { modalProject = $0 },
            modalOrigin: { modalOrigin = $0 },
            showCaptureModal: { showCaptureModal = $0 },
        )

        let origin = CGRect(x: 1, y: 2, width: 3, height: 4)
        enabled.showIdeaCaptureModal(for: project, from: origin)

        XCTAssertEqual(modalProject, project.shellProjectReference)
        XCTAssertEqual(modalOrigin, origin)
        XCTAssertTrue(showCaptureModal)
    }

    func testPresentationStateReturnsExpectedFeatureGuardResults() {
        let project = ShellProjectReference(displayName: "Capacitor", path: "/tmp/capacitor")
        let idea = makeIdea()
        let request = NewProjectRequest(
            name: "Caps",
            description: "desc",
            location: "/tmp",
            language: "swift",
            framework: nil,
        )

        let details = StubProjectPresentationDetails()
        var createdResults: [CreateProjectResult] = []
        var capturedError: String?

        let disabled = makeState(
            ideaCaptureEnabled: false,
            projectCreationEnabled: false,
            llmFeaturesEnabled: false,
            details: details,
            projectCreationHandler: StubProjectIdeaCreationHandler(),
            writeError: { capturedError = $0 },
        )

        switch disabled.captureIdea(for: project, text: "hello") {
        case let .failure(error as AppFeatureError):
            if case .ideaCaptureDisabled = error {
                // expected
            } else {
                XCTFail("Expected ideaCaptureDisabled, got \(error)")
            }
        default:
            XCTFail("Expected idea capture to be blocked when feature is disabled")
        }

        XCTAssertTrue(disabled.ideas(for: project).isEmpty)
        XCTAssertFalse(disabled.isGeneratingTitle(for: idea.id))
        XCTAssertNil(disabled.description(for: project))
        XCTAssertFalse(disabled.isGeneratingDescription(for: project))

        disabled.dismissIdea(idea, for: project)
        XCTAssertNil(capturedError)

        disabled.createProjectFromIdea(request) { createdResults.append($0) }
        XCTAssertEqual(createdResults.count, 1)
        XCTAssertFalse(createdResults[0].success)
        XCTAssertEqual(createdResults[0].error, AppFeatureError.projectCreationDisabled.errorDescription)
    }

    func testPresentationStateDelegatesEnabledFeatureWorkAndPropagatesDismissErrors() {
        let project = ShellProjectReference(displayName: "Capacitor", path: "/tmp/capacitor")
        let idea = makeIdea()
        let request = NewProjectRequest(
            name: "Caps",
            description: "desc",
            location: "/tmp",
            language: "swift",
            framework: nil,
        )

        let details = StubProjectPresentationDetails()
        details.captureIdeaResult = .success(())
        details.storedIdeas = [idea]
        details.generatingIdeaIDs = [idea.id]
        details.storedDescription = "Generated"
        details.generatingDescriptionPaths = [project.path]
        details.dismissIdeaError = ExpectedError()

        let projectCreationHandler = StubProjectIdeaCreationHandler()
        projectCreationHandler.result = CreateProjectResult(
            success: true,
            projectPath: "/tmp/caps",
            sessionId: "sess",
            error: nil,
        )

        var capturedError: String?
        let state = makeState(
            ideaCaptureEnabled: true,
            projectCreationEnabled: true,
            llmFeaturesEnabled: true,
            details: details,
            projectCreationHandler: projectCreationHandler,
            writeError: { capturedError = $0 },
        )

        let captureResult = state.captureIdea(for: project, text: "hello")
        if case .failure = captureResult {
            XCTFail("Expected capture to delegate successfully")
        }
        XCTAssertEqual(details.capturedIdeas.count, 1)
        XCTAssertEqual(details.capturedIdeas.first?.0, project.shellProjectReference)
        XCTAssertEqual(details.capturedIdeas.first?.1, "hello")

        state.checkIdeasFileChanges(for: [project])
        XCTAssertEqual(details.checkedProjectSets, [[project]])
        XCTAssertEqual(state.ideas(for: project), [idea])
        XCTAssertTrue(state.isGeneratingTitle(for: idea.id))

        state.dismissIdea(idea, for: project)
        XCTAssertEqual(capturedError, "Failed to dismiss idea: boom")

        state.reorderIdeas([idea], for: project)
        XCTAssertEqual(details.reorderedIdeaLists.count, 1)
        XCTAssertEqual(details.reorderedIdeaLists.first?.0, [idea])
        XCTAssertEqual(details.reorderedIdeaLists.first?.1, project.shellProjectReference)

        XCTAssertEqual(state.description(for: project), "Generated")
        XCTAssertTrue(state.isGeneratingDescription(for: project))
        state.generateDescription(for: project)
        XCTAssertEqual(details.generatedDescriptionProjects, [project.shellProjectReference])

        var result: CreateProjectResult?
        state.createProjectFromIdea(request) { result = $0 }
        XCTAssertEqual(projectCreationHandler.requests, [request])
        XCTAssertEqual(
            result,
            CreateProjectResult(success: true, projectPath: "/tmp/caps", sessionId: "sess", error: nil),
        )
    }

    private func makeState(
        ideaCaptureEnabled: Bool = true,
        projectCreationEnabled: Bool = true,
        llmFeaturesEnabled: Bool = true,
        details: StubProjectPresentationDetails? = nil,
        projectCreationHandler: StubProjectIdeaCreationHandler? = nil,
        modalProject: @escaping (ShellProjectReference?) -> Void = { _ in },
        modalOrigin: @escaping (CGRect?) -> Void = { _ in },
        showCaptureModal: @escaping (Bool) -> Void = { _ in },
        writeError: @escaping (String?) -> Void = { _ in },
    ) -> ProjectPresentationState {
        let resolvedDetails = details ?? StubProjectPresentationDetails()
        let resolvedProjectCreationHandler = projectCreationHandler ?? StubProjectIdeaCreationHandler()

        return ProjectPresentationState(
            ideaCaptureEnabled: { ideaCaptureEnabled },
            projectCreationEnabled: { projectCreationEnabled },
            llmFeaturesEnabled: { llmFeaturesEnabled },
            projectDetails: resolvedDetails,
            projectCreation: resolvedProjectCreationHandler,
            writeCaptureModalProject: modalProject,
            writeCaptureModalOrigin: modalOrigin,
            writeShowCaptureModal: showCaptureModal,
            writeError: writeError,
        )
    }

    private func makeProject() -> Project {
        Project(
            name: "Capacitor",
            path: "/tmp/capacitor",
            displayPath: "/tmp/capacitor",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    private func makeIdea() -> Idea {
        Idea(
            id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            title: "Idea",
            description: "Desc",
            added: "2026-03-05T00:00:00Z",
            effort: "small",
            status: "open",
            triage: "pending",
            related: nil,
        )
    }
}

private final class StubProjectPresentationDetails: ProjectPresentationDetails {
    var captureIdeaResult: Result<Void, Error> = .failure(AppFeatureError.ideaCaptureDisabled)
    var storedIdeas: [Idea] = []
    var generatingIdeaIDs: Set<String> = []
    var storedDescription: String?
    var generatingDescriptionPaths: Set<String> = []
    var dismissIdeaError: Error?
    var capturedIdeas: [(ShellProjectReference, String)] = []
    var checkedProjectSets: [[ShellProjectReference]] = []
    var reorderedIdeaLists: [([Idea], ShellProjectReference)] = []
    var generatedDescriptionProjects: [ShellProjectReference] = []

    func captureIdea(for project: ShellProjectReference, text: String) -> Result<Void, Error> {
        capturedIdeas.append((project, text))
        return captureIdeaResult
    }

    func checkIdeasFileChanges(for projects: [ShellProjectReference]) {
        checkedProjectSets.append(projects)
    }

    func ideas(for _: String) -> [Idea] {
        storedIdeas
    }

    func isGeneratingTitle(for ideaID: String) -> Bool {
        generatingIdeaIDs.contains(ideaID)
    }

    func dismissIdea(_ idea: Idea, for project: ShellProjectReference) throws {
        _ = (idea, project)
        if let dismissIdeaError {
            throw dismissIdeaError
        }
    }

    func reorderIdeas(_ ideas: [Idea], for project: ShellProjectReference) {
        reorderedIdeaLists.append((ideas, project))
    }

    func description(for _: String) -> String? {
        storedDescription
    }

    func isGeneratingDescription(for projectPath: String) -> Bool {
        generatingDescriptionPaths.contains(projectPath)
    }

    func generateDescription(for project: ShellProjectReference) {
        generatedDescriptionProjects.append(project)
    }
}

private final class StubProjectIdeaCreationHandler: ProjectIdeaCreationHandling {
    var requests: [NewProjectRequest] = []
    var result = CreateProjectResult(
        success: false,
        projectPath: "",
        sessionId: nil,
        error: "unset",
    )

    func createProjectFromIdea(
        _ request: NewProjectRequest,
        completion: @escaping (CreateProjectResult) -> Void,
    ) {
        requests.append(request)
        completion(result)
    }
}

private struct ExpectedError: LocalizedError {
    var errorDescription: String? {
        "boom"
    }
}
