import SwiftUI

struct DockProjectCardPresentation: Equatable {
    let currentState: SessionState
    let contextLine: String?

    static func resolve(
        sessionState: ProjectSessionState?,
        trackedRunVisualState: RunVisualState,
    ) -> Self {
        let currentState = trackedRunVisualState.sessionState ?? sessionState?.state ?? .idle

        return Self(
            currentState: currentState,
            contextLine: trackedRunVisualState.statusMessage,
        )
    }
}

struct DockProjectCard: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let delegationState: RuntimeDelegationState?
    let activeRunState: RuntimeRunState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let isActive: Bool
    let onTap: () -> Void
    let onInfoTap: (() -> Void)?
    let onMoveToDormant: () -> Void
    var onCaptureIdea: ((CGRect) -> Void)?
    let onRemove: () -> Void
    var onDragStarted: (() -> NSItemProvider)?
    var isDragging: Bool = false

    var body: some View {
        ProjectCard(
            layoutMode: .dock,
            project: project,
            sessionState: sessionState,
            delegationState: delegationState,
            activeRunState: activeRunState,
            projectStatus: projectStatus,
            flashState: flashState,
            isActive: isActive,
            onTap: onTap,
            onInfoTap: onInfoTap,
            onMoveToDormant: onMoveToDormant,
            onCaptureIdea: onCaptureIdea,
            onRemove: onRemove,
            onDragStarted: onDragStarted,
            isDragging: isDragging,
        )
    }
}
