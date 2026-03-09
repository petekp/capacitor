import CoreGraphics
import Foundation

@MainActor
protocol ProjectPresentationDetails: AnyObject {
    func captureIdea(for project: ShellProjectReference, text: String) -> Result<Void, Error>
    func checkIdeasFileChanges(for projects: [ShellProjectReference])
    func ideas(for projectPath: String) -> [Idea]
    func isGeneratingTitle(for ideaID: String) -> Bool
    func dismissIdea(_ idea: Idea, for project: ShellProjectReference) throws
    func reorderIdeas(_ ideas: [Idea], for project: ShellProjectReference)
    func description(for projectPath: String) -> String?
    func isGeneratingDescription(for projectPath: String) -> Bool
    func generateDescription(for project: ShellProjectReference)
}

@MainActor
protocol ProjectIdeaCreationHandling: AnyObject {
    func createProjectFromIdea(
        _ request: NewProjectRequest,
        completion: @escaping (CreateProjectResult) -> Void,
    )
}

@MainActor
final class ProjectPresentationState {
    private let ideaCaptureEnabled: @MainActor () -> Bool
    private let projectCreationEnabled: @MainActor () -> Bool
    private let llmFeaturesEnabled: @MainActor () -> Bool
    private let projectDetails: any ProjectPresentationDetails
    private let projectCreation: any ProjectIdeaCreationHandling

    private let writeCaptureModalProject: @MainActor (ShellProjectReference?) -> Void
    private let writeCaptureModalOrigin: @MainActor (CGRect?) -> Void
    private let writeShowCaptureModal: @MainActor (Bool) -> Void
    private let writeError: @MainActor (String?) -> Void

    init(
        ideaCaptureEnabled: @escaping @MainActor () -> Bool,
        projectCreationEnabled: @escaping @MainActor () -> Bool,
        llmFeaturesEnabled: @escaping @MainActor () -> Bool,
        projectDetails: any ProjectPresentationDetails,
        projectCreation: any ProjectIdeaCreationHandling,
        writeCaptureModalProject: @escaping @MainActor (ShellProjectReference?) -> Void,
        writeCaptureModalOrigin: @escaping @MainActor (CGRect?) -> Void,
        writeShowCaptureModal: @escaping @MainActor (Bool) -> Void,
        writeError: @escaping @MainActor (String?) -> Void,
    ) {
        self.ideaCaptureEnabled = ideaCaptureEnabled
        self.projectCreationEnabled = projectCreationEnabled
        self.llmFeaturesEnabled = llmFeaturesEnabled
        self.projectDetails = projectDetails
        self.projectCreation = projectCreation
        self.writeCaptureModalProject = writeCaptureModalProject
        self.writeCaptureModalOrigin = writeCaptureModalOrigin
        self.writeShowCaptureModal = writeShowCaptureModal
        self.writeError = writeError
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
        return projectDetails.captureIdea(for: project.shellProjectReference, text: text)
    }

    func checkIdeasFileChanges(for projects: [some ShellProjectReferenceProviding]) {
        guard ideaCaptureEnabled() else { return }
        projectDetails.checkIdeasFileChanges(for: projects.map(\.shellProjectReference))
    }

    func ideas(for project: some ProjectPathProviding) -> [Idea] {
        guard ideaCaptureEnabled() else { return [] }
        return projectDetails.ideas(for: project.path)
    }

    func isGeneratingTitle(for ideaID: String) -> Bool {
        guard ideaCaptureEnabled() else { return false }
        return projectDetails.isGeneratingTitle(for: ideaID)
    }

    func dismissIdea(_ idea: Idea, for project: some ShellProjectReferenceProviding) {
        guard ideaCaptureEnabled() else { return }
        do {
            try projectDetails.dismissIdea(idea, for: project.shellProjectReference)
        } catch {
            writeError("Failed to dismiss idea: \(error.localizedDescription)")
        }
    }

    func reorderIdeas(_ reorderedIdeas: [Idea], for project: some ShellProjectReferenceProviding) {
        guard ideaCaptureEnabled() else { return }
        projectDetails.reorderIdeas(reorderedIdeas, for: project.shellProjectReference)
    }

    func description(for project: some ProjectPathProviding) -> String? {
        guard llmFeaturesEnabled() else { return nil }
        return projectDetails.description(for: project.path)
    }

    func isGeneratingDescription(for project: some ProjectPathProviding) -> Bool {
        guard llmFeaturesEnabled() else { return false }
        return projectDetails.isGeneratingDescription(for: project.path)
    }

    func generateDescription(for project: some ShellProjectReferenceProviding) {
        guard llmFeaturesEnabled() else { return }
        projectDetails.generateDescription(for: project.shellProjectReference)
    }

    func createProjectFromIdea(
        _ request: NewProjectRequest,
        completion: @escaping (CreateProjectResult) -> Void,
    ) {
        guard projectCreationEnabled() else {
            completion(CreateProjectResult(
                success: false,
                projectPath: "",
                sessionId: nil,
                error: AppFeatureError.projectCreationDisabled.errorDescription ?? "Project creation is disabled.",
            ))
            return
        }

        projectCreation.createProjectFromIdea(request, completion: completion)
    }
}

private struct PathOnlyProjectReference: ProjectPathProviding {
    let path: String
}

extension ProjectDetailsManager: ProjectPresentationDetails {
    func ideas(for projectPath: String) -> [Idea] {
        getIdeas(for: PathOnlyProjectReference(path: projectPath))
    }

    func dismissIdea(_ idea: Idea, for project: ShellProjectReference) throws {
        try updateIdeaStatus(for: project, idea: idea, newStatus: "done")
    }

    func description(for projectPath: String) -> String? {
        getDescription(for: PathOnlyProjectReference(path: projectPath))
    }

    func isGeneratingDescription(for projectPath: String) -> Bool {
        isGeneratingDescription(for: PathOnlyProjectReference(path: projectPath))
    }
}

extension ProjectCreationCoordinator: ProjectIdeaCreationHandling {}
