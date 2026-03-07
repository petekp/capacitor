@testable import Capacitor
import CoreGraphics
import XCTest

@MainActor
final class ProjectFeatureCoordinatorTests: XCTestCase {
    func testNavigationAndIdeaCaptureGatesAreOwnedByCoordinator() {
        let project = makeProject()
        var navigationDestination: ShellNavigationDestination = .projectList
        var modalProject: Project?
        var modalOrigin: CGRect?
        var showCaptureModal = false

        let disabled = makeCoordinator(
            projectDetailsEnabled: false,
            ideaCaptureEnabled: false,
            projectCreationEnabled: false,
            llmFeaturesEnabled: false,
            setNavigationDestination: { navigationDestination = $0 },
            modalProject: { modalProject = $0 },
            modalOrigin: { modalOrigin = $0 },
            showCaptureModal: { showCaptureModal = $0 },
        )

        disabled.showProjectDetail(project)
        disabled.showNewIdea()
        disabled.showIdeaCaptureModal(for: project, from: CGRect(x: 1, y: 2, width: 3, height: 4))

        XCTAssertEqual(navigationDestination, .projectList)
        XCTAssertNil(modalProject)
        XCTAssertNil(modalOrigin)
        XCTAssertFalse(showCaptureModal)

        let enabled = makeCoordinator(
            projectDetailsEnabled: true,
            ideaCaptureEnabled: true,
            projectCreationEnabled: true,
            llmFeaturesEnabled: false,
            setNavigationDestination: { navigationDestination = $0 },
            modalProject: { modalProject = $0 },
            modalOrigin: { modalOrigin = $0 },
            showCaptureModal: { showCaptureModal = $0 },
        )

        enabled.showProjectDetail(project)
        XCTAssertEqual(navigationDestination, .projectDetail(projectID: project.path))

        enabled.showNewIdea()
        XCTAssertEqual(navigationDestination, .newIdea)

        let origin = CGRect(x: 1, y: 2, width: 3, height: 4)
        enabled.showIdeaCaptureModal(for: project, from: origin)
        XCTAssertEqual(modalProject, project)
        XCTAssertEqual(modalOrigin, origin)
        XCTAssertTrue(showCaptureModal)
    }

    func testCoordinatorReturnsExpectedFeatureGuardResults() {
        let project = makeProject()
        let idea = makeIdea()
        let request = NewProjectRequest(
            name: "Caps",
            description: "desc",
            location: "/tmp",
            language: "swift",
            framework: nil,
        )

        var dismissCalls = 0
        var capturedError: String?
        var createdResults: [CreateProjectResult] = []

        let disabled = makeCoordinator(
            projectDetailsEnabled: false,
            ideaCaptureEnabled: false,
            projectCreationEnabled: false,
            llmFeaturesEnabled: false,
            writeError: { capturedError = $0 },
            dismissIdeaHandler: { _, _ in dismissCalls += 1 },
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

        XCTAssertEqual(disabled.getIdeas(for: project), [])
        XCTAssertFalse(disabled.isGeneratingTitle(for: idea.id))
        XCTAssertNil(disabled.getDescription(for: project))
        XCTAssertFalse(disabled.isGeneratingDescription(for: project))

        disabled.dismissIdea(idea, for: project)
        XCTAssertEqual(dismissCalls, 0)
        XCTAssertNil(capturedError)

        disabled.createProjectFromIdea(request) { createdResults.append($0) }
        XCTAssertEqual(createdResults.count, 1)
        XCTAssertFalse(createdResults[0].success)
        XCTAssertEqual(createdResults[0].error, AppFeatureError.projectCreationDisabled.errorDescription)
    }

    func testCoordinatorDelegatesEnabledFeatureWorkAndPropagatesDismissErrors() {
        let project = makeProject()
        let idea = makeIdea()
        let request = NewProjectRequest(
            name: "Caps",
            description: "desc",
            location: "/tmp",
            language: "swift",
            framework: nil,
        )
        let returnedIdeas = [idea]

        var capturedTexts: [String] = []
        var checkedProjectSets: [[Project]] = []
        var reorderedIdeaLists: [[Idea]] = []
        var generatedDescriptions: [Project] = []
        var createdRequests: [NewProjectRequest] = []
        var capturedError: String?

        struct ExpectedError: LocalizedError {
            var errorDescription: String? {
                "boom"
            }
        }

        let coordinator = makeCoordinator(
            projectDetailsEnabled: true,
            ideaCaptureEnabled: true,
            projectCreationEnabled: true,
            llmFeaturesEnabled: true,
            writeError: { capturedError = $0 },
            captureIdeaHandler: { _, text in
                capturedTexts.append(text)
                return .success(())
            },
            checkIdeasFileChangesHandler: { checkedProjectSets.append($0) },
            getIdeasHandler: { _ in returnedIdeas },
            isGeneratingTitleHandler: { $0 == idea.id },
            dismissIdeaHandler: { _, _ in throw ExpectedError() },
            reorderIdeasHandler: { ideas, _ in reorderedIdeaLists.append(ideas) },
            getDescriptionHandler: { _ in "Generated" },
            isGeneratingDescriptionHandler: { _ in true },
            generateDescriptionHandler: { generatedDescriptions.append($0) },
            createProjectFromIdeaHandler: { request, completion in
                createdRequests.append(request)
                completion(CreateProjectResult(success: true, projectPath: "/tmp/caps", sessionId: "sess", error: nil))
            },
        )

        let captureResult = coordinator.captureIdea(for: project, text: "hello")
        if case .failure = captureResult {
            XCTFail("Expected capture to delegate successfully")
        }
        XCTAssertEqual(capturedTexts, ["hello"])

        coordinator.checkIdeasFileChanges(for: [project])
        XCTAssertEqual(checkedProjectSets, [[project]])
        XCTAssertEqual(coordinator.getIdeas(for: project), returnedIdeas)
        XCTAssertTrue(coordinator.isGeneratingTitle(for: idea.id))

        coordinator.dismissIdea(idea, for: project)
        XCTAssertEqual(capturedError, "Failed to dismiss idea: boom")

        coordinator.reorderIdeas(returnedIdeas, for: project)
        XCTAssertEqual(reorderedIdeaLists, [returnedIdeas])

        XCTAssertEqual(coordinator.getDescription(for: project), "Generated")
        XCTAssertTrue(coordinator.isGeneratingDescription(for: project))
        coordinator.generateDescription(for: project)
        XCTAssertEqual(generatedDescriptions, [project])

        var result: CreateProjectResult?
        coordinator.createProjectFromIdea(request) { result = $0 }
        XCTAssertEqual(createdRequests, [request])
        XCTAssertEqual(result, CreateProjectResult(success: true, projectPath: "/tmp/caps", sessionId: "sess", error: nil))
    }

    private func makeCoordinator(
        projectDetailsEnabled: Bool = true,
        ideaCaptureEnabled: Bool = true,
        projectCreationEnabled: Bool = true,
        llmFeaturesEnabled: Bool = true,
        setNavigationDestination: @escaping (ShellNavigationDestination) -> Void = { _ in },
        modalProject: @escaping (Project?) -> Void = { _ in },
        modalOrigin: @escaping (CGRect?) -> Void = { _ in },
        showCaptureModal: @escaping (Bool) -> Void = { _ in },
        writeError: @escaping (String?) -> Void = { _ in },
        captureIdeaHandler: @escaping (Project, String) -> Result<Void, Error> = { _, _ in .success(()) },
        checkIdeasFileChangesHandler: @escaping ([Project]) -> Void = { _ in },
        getIdeasHandler: @escaping (Project) -> [Idea] = { _ in [] },
        isGeneratingTitleHandler: @escaping (String) -> Bool = { _ in false },
        dismissIdeaHandler: @escaping (Idea, Project) throws -> Void = { _, _ in },
        reorderIdeasHandler: @escaping ([Idea], Project) -> Void = { _, _ in },
        getDescriptionHandler: @escaping (Project) -> String? = { _ in nil },
        isGeneratingDescriptionHandler: @escaping (Project) -> Bool = { _ in false },
        generateDescriptionHandler: @escaping (Project) -> Void = { _ in },
        createProjectFromIdeaHandler: @escaping (NewProjectRequest, @escaping (CreateProjectResult) -> Void) -> Void = { _, _ in },
    ) -> ProjectFeatureCoordinator {
        ProjectFeatureCoordinator(
            projectDetailsEnabled: { projectDetailsEnabled },
            ideaCaptureEnabled: { ideaCaptureEnabled },
            projectCreationEnabled: { projectCreationEnabled },
            llmFeaturesEnabled: { llmFeaturesEnabled },
            writeNavigationDestination: setNavigationDestination,
            writeCaptureModalProject: modalProject,
            writeCaptureModalOrigin: modalOrigin,
            writeShowCaptureModal: showCaptureModal,
            writeError: writeError,
            captureIdeaHandler: captureIdeaHandler,
            checkIdeasFileChangesHandler: checkIdeasFileChangesHandler,
            getIdeasHandler: getIdeasHandler,
            isGeneratingTitleHandler: isGeneratingTitleHandler,
            dismissIdeaHandler: dismissIdeaHandler,
            reorderIdeasHandler: reorderIdeasHandler,
            getDescriptionHandler: getDescriptionHandler,
            isGeneratingDescriptionHandler: isGeneratingDescriptionHandler,
            generateDescriptionHandler: generateDescriptionHandler,
            createProjectFromIdeaHandler: createProjectFromIdeaHandler,
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
