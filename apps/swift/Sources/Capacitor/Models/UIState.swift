import CoreGraphics
import Foundation
import Observation

enum LayoutMode: String, CaseIterable {
    case vertical
    case dock
}

enum ProjectView: Equatable {
    case list
    case detail(Project)
    case delegationReview(Project)

    static func == (lhs: ProjectView, rhs: ProjectView) -> Bool {
        switch (lhs, rhs) {
        case (.list, .list):
            true
        case let (.detail(lhsProject), .detail(rhsProject)):
            lhsProject.path == rhsProject.path
        case let (.delegationReview(lhsProject), .delegationReview(rhsProject)):
            lhsProject.path == rhsProject.path
        default:
            false
        }
    }
}

struct ReviewWindowTarget: Equatable {
    let projectPath: String
    let workerID: String
}

struct RunCheckpointWindowTarget: Equatable {
    let projectPath: String
    let runID: String
    let checkpointID: String
}

@Observable
@MainActor
final class UIState {
    var layoutMode: LayoutMode = .vertical {
        didSet { saveLayoutMode() }
    }

    var projectView: ProjectView = .list
    var reviewWindowTarget: ReviewWindowTarget?
    var runCheckpointWindowTarget: RunCheckpointWindowTarget?

    var dashboard: DashboardData?
    var isLoading = true
    var error: String?
    var toast: ToastMessage?
    var pendingDragDropTip = false
    var isFileDragOverCard = false

    var hookDiagnostic: HookDiagnosticReport?
    var activationTrace: String?
    var runtimeStatus: RuntimeStatus?

    var showCaptureModal = false
    var captureModalProject: Project?
    var captureModalOrigin: CGRect?

    @ObservationIgnored
    private let layoutModeKey = "layoutMode"

    init() {
        loadLayoutMode()
    }

    func showError(_ message: String) {
        error = message
    }

    func showToast(_ message: String, isError: Bool = false) {
        toast = ToastMessage(message, isError: isError)
    }

    private func loadLayoutMode() {
        if let rawValue = UserDefaults.standard.string(forKey: layoutModeKey),
           let mode = LayoutMode(rawValue: rawValue)
        {
            layoutMode = mode
        }
    }

    private func saveLayoutMode() {
        UserDefaults.standard.set(layoutMode.rawValue, forKey: layoutModeKey)
    }
}
