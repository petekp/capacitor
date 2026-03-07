import Foundation

struct LiveIdeaGateway: IdeaGateway {
    private let runtimeProvider: () throws -> CoreRuntime

    init(runtimeProvider: @escaping () throws -> CoreRuntime = { try CoreRuntime() }) {
        self.runtimeProvider = runtimeProvider
    }

    func capture(_ draft: ShellIdeaDraft) async throws -> ShellIdeaDraft {
        let ideaText = draft.details.isEmpty ? draft.title : "\(draft.title)\n\n\(draft.details)"
        let capturedID = try runtimeProvider().captureIdea(
            projectPath: draft.project?.path ?? "",
            ideaText: ideaText,
        )

        return ShellIdeaDraft(
            id: capturedID,
            project: draft.project,
            title: draft.title,
            details: draft.details,
        )
    }

    func loadIdeas(for project: ShellProjectReference) async throws -> [ShellIdeaDraft] {
        try runtimeProvider()
            .loadIdeas(projectPath: project.path)
            .map { idea in
                ShellIdeaDraft(
                    id: idea.id,
                    project: project,
                    title: idea.title,
                    details: idea.description,
                )
            }
    }
}
