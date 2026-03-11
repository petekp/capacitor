import CoreGraphics
import Foundation

@MainActor
final class ProjectFeatureCoordinator {
    private let projectDetailsEnabled: @MainActor () -> Bool
    private let ideaCaptureEnabled: @MainActor () -> Bool
    private let llmFeaturesEnabled: @MainActor () -> Bool

    private let writeProjectView: @MainActor (ProjectView) -> Void
    private let writeCaptureModalProject: @MainActor (Project?) -> Void
    private let writeCaptureModalOrigin: @MainActor (CGRect?) -> Void
    private let writeShowCaptureModal: @MainActor (Bool) -> Void
    private let writeError: @MainActor (String?) -> Void

    private let captureIdeaHandler: @MainActor (Project, String) -> Result<Void, Error>
    private let checkIdeasFileChangesHandler: @MainActor ([Project]) -> Void
    private let getIdeasHandler: @MainActor (Project) -> [Idea]
    private let isGeneratingTitleHandler: @MainActor (String) -> Bool
    private let dismissIdeaHandler: @MainActor (Idea, Project) throws -> Void
    private let reorderIdeasHandler: @MainActor ([Idea], Project) -> Void

    private let getDescriptionHandler: @MainActor (Project) -> String?
    private let isGeneratingDescriptionHandler: @MainActor (Project) -> Bool
    private let generateDescriptionHandler: @MainActor (Project) -> Void

    init(
        projectDetailsEnabled: @escaping @MainActor () -> Bool,
        ideaCaptureEnabled: @escaping @MainActor () -> Bool,
        llmFeaturesEnabled: @escaping @MainActor () -> Bool,
        writeProjectView: @escaping @MainActor (ProjectView) -> Void,
        writeCaptureModalProject: @escaping @MainActor (Project?) -> Void,
        writeCaptureModalOrigin: @escaping @MainActor (CGRect?) -> Void,
        writeShowCaptureModal: @escaping @MainActor (Bool) -> Void,
        writeError: @escaping @MainActor (String?) -> Void,
        captureIdeaHandler: @escaping @MainActor (Project, String) -> Result<Void, Error>,
        checkIdeasFileChangesHandler: @escaping @MainActor ([Project]) -> Void,
        getIdeasHandler: @escaping @MainActor (Project) -> [Idea],
        isGeneratingTitleHandler: @escaping @MainActor (String) -> Bool,
        dismissIdeaHandler: @escaping @MainActor (Idea, Project) throws -> Void,
        reorderIdeasHandler: @escaping @MainActor ([Idea], Project) -> Void,
        getDescriptionHandler: @escaping @MainActor (Project) -> String?,
        isGeneratingDescriptionHandler: @escaping @MainActor (Project) -> Bool,
        generateDescriptionHandler: @escaping @MainActor (Project) -> Void,
    ) {
        self.projectDetailsEnabled = projectDetailsEnabled
        self.ideaCaptureEnabled = ideaCaptureEnabled
        self.llmFeaturesEnabled = llmFeaturesEnabled
        self.writeProjectView = writeProjectView
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
    }

    func showProjectDetail(_ project: Project) {
        guard projectDetailsEnabled() else { return }
        writeProjectView(.detail(project))
    }

    func showProjectList() {
        writeProjectView(.list)
    }

    func showIdeaCaptureModal(for project: Project, from origin: CGRect? = nil) {
        guard ideaCaptureEnabled() else { return }
        writeCaptureModalProject(project)
        writeCaptureModalOrigin(origin)
        writeShowCaptureModal(true)
    }

    func captureIdea(for project: Project, text: String) -> Result<Void, Error> {
        guard ideaCaptureEnabled() else {
            return .failure(AppFeatureError.ideaCaptureDisabled)
        }
        return captureIdeaHandler(project, text)
    }

    func checkIdeasFileChanges(for projects: [Project]) {
        guard ideaCaptureEnabled() else { return }
        checkIdeasFileChangesHandler(projects)
    }

    func getIdeas(for project: Project) -> [Idea] {
        guard ideaCaptureEnabled() else { return [] }
        return getIdeasHandler(project)
    }

    func isGeneratingTitle(for ideaId: String) -> Bool {
        guard ideaCaptureEnabled() else { return false }
        return isGeneratingTitleHandler(ideaId)
    }

    func dismissIdea(_ idea: Idea, for project: Project) {
        guard ideaCaptureEnabled() else { return }
        do {
            try dismissIdeaHandler(idea, project)
        } catch {
            writeError("Failed to dismiss idea: \(error.localizedDescription)")
        }
    }

    func reorderIdeas(_ reorderedIdeas: [Idea], for project: Project) {
        guard ideaCaptureEnabled() else { return }
        reorderIdeasHandler(reorderedIdeas, project)
    }

    func getDescription(for project: Project) -> String? {
        guard llmFeaturesEnabled() else { return nil }
        return getDescriptionHandler(project)
    }

    func isGeneratingDescription(for project: Project) -> Bool {
        guard llmFeaturesEnabled() else { return false }
        return isGeneratingDescriptionHandler(project)
    }

    func generateDescription(for project: Project) {
        guard llmFeaturesEnabled() else { return }
        generateDescriptionHandler(project)
    }
}
