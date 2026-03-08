import CoreGraphics
import Foundation

@MainActor
final class ProjectFeatureCoordinator {
    private let projectDetailsEnabled: @MainActor () -> Bool
    private let ideaCaptureEnabled: @MainActor () -> Bool
    private let projectCreationEnabled: @MainActor () -> Bool
    private let llmFeaturesEnabled: @MainActor () -> Bool

    private let writeNavigationDestination: @MainActor (ShellNavigationDestination) -> Void
    private let writeCaptureModalProject: @MainActor (ShellProjectReference?) -> Void
    private let writeCaptureModalOrigin: @MainActor (CGRect?) -> Void
    private let writeShowCaptureModal: @MainActor (Bool) -> Void
    private let writeError: @MainActor (String?) -> Void

    private let captureIdeaHandler: @MainActor (ShellProjectReference, String) -> Result<Void, Error>
    private let checkIdeasFileChangesHandler: @MainActor ([ShellProjectReference]) -> Void
    private let getIdeasHandler: @MainActor (ShellProjectReference) -> [Idea]
    private let isGeneratingTitleHandler: @MainActor (String) -> Bool
    private let dismissIdeaHandler: @MainActor (Idea, ShellProjectReference) throws -> Void
    private let reorderIdeasHandler: @MainActor ([Idea], ShellProjectReference) -> Void

    private let getDescriptionHandler: @MainActor (ShellProjectReference) -> String?
    private let isGeneratingDescriptionHandler: @MainActor (ShellProjectReference) -> Bool
    private let generateDescriptionHandler: @MainActor (ShellProjectReference) -> Void

    private let createProjectFromIdeaHandler: @MainActor (NewProjectRequest, @escaping (CreateProjectResult) -> Void) -> Void

    init(
        projectDetailsEnabled: @escaping @MainActor () -> Bool,
        ideaCaptureEnabled: @escaping @MainActor () -> Bool,
        projectCreationEnabled: @escaping @MainActor () -> Bool,
        llmFeaturesEnabled: @escaping @MainActor () -> Bool,
        writeNavigationDestination: @escaping @MainActor (ShellNavigationDestination) -> Void,
        writeCaptureModalProject: @escaping @MainActor (ShellProjectReference?) -> Void,
        writeCaptureModalOrigin: @escaping @MainActor (CGRect?) -> Void,
        writeShowCaptureModal: @escaping @MainActor (Bool) -> Void,
        writeError: @escaping @MainActor (String?) -> Void,
        captureIdeaHandler: @escaping @MainActor (ShellProjectReference, String) -> Result<Void, Error>,
        checkIdeasFileChangesHandler: @escaping @MainActor ([ShellProjectReference]) -> Void,
        getIdeasHandler: @escaping @MainActor (ShellProjectReference) -> [Idea],
        isGeneratingTitleHandler: @escaping @MainActor (String) -> Bool,
        dismissIdeaHandler: @escaping @MainActor (Idea, ShellProjectReference) throws -> Void,
        reorderIdeasHandler: @escaping @MainActor ([Idea], ShellProjectReference) -> Void,
        getDescriptionHandler: @escaping @MainActor (ShellProjectReference) -> String?,
        isGeneratingDescriptionHandler: @escaping @MainActor (ShellProjectReference) -> Bool,
        generateDescriptionHandler: @escaping @MainActor (ShellProjectReference) -> Void,
        createProjectFromIdeaHandler: @escaping @MainActor (NewProjectRequest, @escaping (CreateProjectResult) -> Void) -> Void,
    ) {
        self.projectDetailsEnabled = projectDetailsEnabled
        self.ideaCaptureEnabled = ideaCaptureEnabled
        self.projectCreationEnabled = projectCreationEnabled
        self.llmFeaturesEnabled = llmFeaturesEnabled
        self.writeNavigationDestination = writeNavigationDestination
        self.writeCaptureModalProject = writeCaptureModalProject
        self.writeCaptureModalOrigin = writeCaptureModalOrigin
        self.writeShowCaptureModal = writeShowCaptureModal
        self.writeError = writeError
        self.captureIdeaHandler = captureIdeaHandler
        self.checkIdeasFileChangesHandler = checkIdeasFileChangesHandler
        self.getIdeasHandler = getIdeasHandler
        self.isGeneratingTitleHandler = isGeneratingTitleHandler
        self.dismissIdeaHandler = dismissIdeaHandler
        self.reorderIdeasHandler = reorderIdeasHandler
        self.getDescriptionHandler = getDescriptionHandler
        self.isGeneratingDescriptionHandler = isGeneratingDescriptionHandler
        self.generateDescriptionHandler = generateDescriptionHandler
        self.createProjectFromIdeaHandler = createProjectFromIdeaHandler
    }

    func showProjectDetail(_ project: some ProjectPathProviding) {
        guard projectDetailsEnabled() else { return }
        writeNavigationDestination(.projectDetail(projectID: project.path))
    }

    func showNewIdea() {
        guard projectCreationEnabled() else { return }
        writeNavigationDestination(.newIdea)
    }

    func showProjectList() {
        writeNavigationDestination(.projectList)
    }

    func showIdeaCaptureModal(for project: some ShellProjectReferenceProviding, from origin: CGRect? = nil) {
        guard ideaCaptureEnabled() else { return }
        writeCaptureModalProject(project.shellProjectReference)
        writeCaptureModalOrigin(origin)
        writeShowCaptureModal(true)
    }

    func captureIdea(for project: some ShellProjectReferenceProviding, text: String) -> Result<Void, Error> {
        guard ideaCaptureEnabled() else {
            return .failure(AppFeatureError.ideaCaptureDisabled)
        }
        return captureIdeaHandler(project.shellProjectReference, text)
    }

    func checkIdeasFileChanges(for projects: [some ShellProjectReferenceProviding]) {
        guard ideaCaptureEnabled() else { return }
        checkIdeasFileChangesHandler(projects.map(\.shellProjectReference))
    }

    func getIdeas(for project: some ShellProjectReferenceProviding) -> [Idea] {
        guard ideaCaptureEnabled() else { return [] }
        return getIdeasHandler(project.shellProjectReference)
    }

    func isGeneratingTitle(for ideaId: String) -> Bool {
        guard ideaCaptureEnabled() else { return false }
        return isGeneratingTitleHandler(ideaId)
    }

    func dismissIdea(_ idea: Idea, for project: some ShellProjectReferenceProviding) {
        guard ideaCaptureEnabled() else { return }
        do {
            try dismissIdeaHandler(idea, project.shellProjectReference)
        } catch {
            writeError("Failed to dismiss idea: \(error.localizedDescription)")
        }
    }

    func reorderIdeas(_ reorderedIdeas: [Idea], for project: some ShellProjectReferenceProviding) {
        guard ideaCaptureEnabled() else { return }
        reorderIdeasHandler(reorderedIdeas, project.shellProjectReference)
    }

    func getDescription(for project: some ShellProjectReferenceProviding) -> String? {
        guard llmFeaturesEnabled() else { return nil }
        return getDescriptionHandler(project.shellProjectReference)
    }

    func isGeneratingDescription(for project: some ShellProjectReferenceProviding) -> Bool {
        guard llmFeaturesEnabled() else { return false }
        return isGeneratingDescriptionHandler(project.shellProjectReference)
    }

    func generateDescription(for project: some ShellProjectReferenceProviding) {
        guard llmFeaturesEnabled() else { return }
        generateDescriptionHandler(project.shellProjectReference)
    }

    func createProjectFromIdea(_ request: NewProjectRequest, completion: @escaping (CreateProjectResult) -> Void) {
        guard projectCreationEnabled() else {
            completion(CreateProjectResult(
                success: false,
                projectPath: "",
                sessionId: nil,
                error: AppFeatureError.projectCreationDisabled.errorDescription ?? "Project creation is disabled.",
            ))
            return
        }
        createProjectFromIdeaHandler(request, completion)
    }
}
