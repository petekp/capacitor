import Foundation
import Observation

@Observable
@MainActor
final class ProjectActionState {
    var pendingDragDropTip = false

    @ObservationIgnored
    private let projectMutationService: ProjectMutationService
    @ObservationIgnored
    private let isRuntimeAvailable: () -> Bool
    @ObservationIgnored
    private let writeToast: (ToastMessage?) -> Void
    @ObservationIgnored
    private let writeError: (String?) -> Void
    @ObservationIgnored
    private let moveTrackedProjectToRecent: (String) -> Void
    @ObservationIgnored
    private let recoverTrackedProjects: ([String]) -> ProjectMutationService.RecoveredTrackedProjectsOutcome

    init(
        projectMutationService: ProjectMutationService,
        isRuntimeAvailable: @escaping () -> Bool,
        writeToast: @escaping (ToastMessage?) -> Void = { _ in },
        writeError: @escaping (String?) -> Void = { _ in },
        moveTrackedProjectToRecent: ((String) -> Void)? = nil,
        recoverTrackedProjects: (([String]) -> ProjectMutationService.RecoveredTrackedProjectsOutcome)? = nil,
    ) {
        self.projectMutationService = projectMutationService
        self.isRuntimeAvailable = isRuntimeAvailable
        self.writeToast = writeToast
        self.writeError = writeError
        self.moveTrackedProjectToRecent = moveTrackedProjectToRecent ?? { [projectMutationService] path in
            projectMutationService.moveTrackedProjectToRecent(path: path)
        }
        self.recoverTrackedProjects = recoverTrackedProjects ?? { [projectMutationService] paths in
            projectMutationService.recoverTrackedProjects(paths: paths)
        }
    }

    func connectSelectedSuggestions() {
        guard isRuntimeAvailable() else { return }
        let outcome = projectMutationService.connectSelectedSuggestedProjects()
        if outcome.connectedCount > 0 {
            writeToast(ToastMessage("Connected \(outcome.connectedCount) project\(outcome.connectedCount == 1 ? "" : "s")"))
        }
    }

    func connectProjectSelection(path: String) {
        guard isRuntimeAvailable() else { return }

        do {
            let resolution = try projectMutationService.resolveProjectSelection(path: path)

            switch resolution {
            case let .connect(connectPath):
                try projectMutationService.connectProject(path: connectPath)
                pendingDragDropTip = true

            case let .alreadyTracked(trackedPath, isDormant):
                if isDormant {
                    moveTrackedProjectToRecent(trackedPath)
                    writeToast(ToastMessage("Moved to In Progress"))
                } else {
                    writeToast(ToastMessage("Already linked!"))
                }

            case let .failed(message):
                writeToast(.error(message))
            }
        } catch {
            writeError(error.localizedDescription)
        }
    }

    func importProjects(
        from urls: [URL],
        ensureProjectListVisible: () -> Void = {},
    ) async {
        guard isRuntimeAvailable() else { return }

        ensureProjectListVisible()

        let outcome = await projectMutationService.importProjectsFromDrop(paths: urls.map(\.path))
        let recovery = recoverTrackedProjects(outcome.alreadyTrackedPaths)

        if outcome.addedCount > 0 {
            pendingDragDropTip = true
        }

        if !outcome.failedNames.isEmpty {
            writeToast(.error(Self.formatMixedResultsToast(
                failedNames: outcome.failedNames,
                connectedCount: outcome.addedCount,
            )))
            return
        }

        guard outcome.addedCount == 0 else { return }

        if !recovery.movedPaths.isEmpty {
            writeToast(ToastMessage(
                recovery.movedPaths.count == 1
                    ? "Moved to In Progress"
                    : "Moved \(recovery.movedPaths.count) projects to In Progress",
            ))
        } else if recovery.alreadyInProgressCount > 0 {
            writeToast(ToastMessage("Already linked!"))
        }
    }

    func removeProject(path: String) {
        guard isRuntimeAvailable() else { return }
        do {
            try projectMutationService.removeProject(path: path)
        } catch {
            writeError(error.localizedDescription)
        }
    }

    @discardableResult
    func createClaudeMd(for path: String) -> Bool {
        guard isRuntimeAvailable() else { return false }
        do {
            try projectMutationService.createClaudeMd(for: path)
            return true
        } catch {
            writeError(error.localizedDescription)
            return false
        }
    }

    private static func formatMixedResultsToast(failedNames: [String], connectedCount: Int) -> String {
        let failedCount = failedNames.count

        let failedPortion = if failedCount == 1 {
            "\(failedNames[0]) failed"
        } else if failedCount == 2 {
            "\(failedNames[0]), \(failedNames[1]) failed"
        } else {
            "\(failedNames[0]), \(failedNames[1]) and \(failedCount - 2) more failed"
        }

        if connectedCount > 0 {
            return "\(failedPortion) (\(connectedCount) connected)"
        }

        return failedPortion
    }
}
