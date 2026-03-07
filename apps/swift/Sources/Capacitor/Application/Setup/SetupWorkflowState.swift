import Foundation

@Observable
@MainActor
final class SetupWorkflowState {
    private(set) var manager: SetupRequirementsManager
    private(set) var checkID = UUID()
    private(set) var isUsingPreviewMode = false

    init() {
        manager = SetupRequirementsManager()
    }

    init(manager: SetupRequirementsManager) {
        self.manager = manager
    }

    var steps: [SetupStep] {
        manager.steps
    }

    var currentStepIndex: Int? {
        manager.currentStepIndex
    }

    var initializationErrorMessage: String? {
        manager.initializationErrorMessage
    }

    var hasBlockingError: Bool {
        manager.hasBlockingError
    }

    var allComplete: Bool {
        manager.allComplete
    }

    var showShellInstructions: Bool {
        get { manager.showShellInstructions }
        set { manager.showShellInstructions = newValue }
    }

    func runChecks() async {
        await manager.runChecks()
    }

    func executeStep(_ stepId: SetupStepID) async {
        await manager.executeStep(stepId)
    }

    func retryStep(_ stepId: SetupStepID) async {
        await manager.retryStep(stepId)
    }

    func dismissShellInstructions() {
        manager.dismissShellInstructions()
    }

    func restoreLive() {
        isUsingPreviewMode = false
        manager = SetupRequirementsManager()
        checkID = UUID()
    }

    #if DEBUG
        func activatePreview(_ scenario: SetupPreviewScenario) {
            isUsingPreviewMode = true
            manager = .preview(scenario)
        }
    #endif
}
