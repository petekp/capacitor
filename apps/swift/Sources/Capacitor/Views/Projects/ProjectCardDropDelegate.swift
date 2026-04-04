import SwiftUI
import UniformTypeIdentifiers

struct ProjectCardDropDelegate: DropDelegate {
    let project: Project
    let groupProjects: [Project]
    let group: ActivityGroup
    @Binding var draggedProject: Project?
    let appState: AppState

    private var isExternalFileDrag: Bool {
        draggedProject == nil
    }

    func dropEntered(info: DropInfo) {
        // External file URL drag (from Finder) -> signal ContentView overlay.
        if isExternalFileDrag, info.hasItemsConforming(to: [.fileURL]) {
            appState.uiState.isFileDragOverCard = true
            return
        }

        // Internal card reorder - only within same group.
        guard let draggedProject,
              draggedProject.path != project.path,
              let fromIndex = groupProjects.firstIndex(where: { $0.path == draggedProject.path }),
              let toIndex = groupProjects.firstIndex(where: { $0.path == project.path })
        else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            appState.moveProject(
                from: IndexSet(integer: fromIndex),
                to: toIndex > fromIndex ? toIndex + 1 : toIndex,
                in: groupProjects,
                group: group,
            )
        }
    }

    func dropExited(info _: DropInfo) {
        if isExternalFileDrag {
            appState.uiState.isFileDragOverCard = false
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isExternalFileDrag, info.hasItemsConforming(to: [.fileURL]) {
            return DropProposal(operation: .copy)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if isExternalFileDrag, info.hasItemsConforming(to: [.fileURL]) {
            appState.uiState.isFileDragOverCard = false
            let providers = info.itemProviders(for: [.fileURL])
            appState.handleFileURLDrop(providers)
            return true
        }
        draggedProject = nil
        return true
    }
}
