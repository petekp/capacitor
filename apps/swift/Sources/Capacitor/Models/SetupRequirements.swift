import Foundation
import SwiftUI

enum SetupStepStatus: Equatable {
    case pending
    case checking
    case completed(detail: String)
    case actionNeeded(message: String)
    case error(message: String)

    var isComplete: Bool {
        if case .completed = self { return true }
        return false
    }

    var isBlocking: Bool {
        if case .error = self { return true }
        return false
    }
}

enum SetupStepID: String, CaseIterable, Identifiable {
    case claude
    case hooks
    case shell

    var id: String {
        rawValue
    }

    static func runtime(named name: String) -> SetupStepID? {
        SetupStepID(rawValue: name)
    }

    static func dependency(named name: String) -> SetupStepID? {
        switch name {
        case SetupStepID.claude.rawValue:
            .claude
        default:
            nil
        }
    }
}

struct SetupStep: Identifiable {
    let id: SetupStepID
    let title: String
    let description: String
    var status: SetupStepStatus
    var isOptional: Bool = false

    var statusDetail: String {
        switch status {
        case .pending:
            description
        case .checking:
            "Checking..."
        case let .completed(detail):
            detail
        case let .actionNeeded(message):
            message
        case let .error(message):
            message
        }
    }
}

struct SetupLifecycleState {
    enum HookInstallResult: Equatable {
        case success(HookStatus)
        case failure(String)
    }

    enum Event {
        case initialize(initializationErrorMessage: String?)
        case checksStarted
        case checksFinished
        case dependencyResolved(DependencyStatus)
        case hookStatusResolved(HookStatus)
        case shellStatusResolved(SetupStepStatus)
        case hookInstallStarted
        case hookInstallFinished(result: HookInstallResult)
        case shellInstructionsPresented
        case shellInstructionsDismissed(status: SetupStepStatus)
    }

    var steps: [SetupStep]
    var claudePath: String?
    var initializationErrorMessage: String?
    var isRunningChecks = false
    var showShellInstructions = false

    static func initial() -> SetupLifecycleState {
        SetupLifecycleState(
            steps: SetupStepCatalog.defaultSteps(),
            claudePath: nil,
            initializationErrorMessage: nil,
            isRunningChecks: false,
            showShellInstructions: false,
        )
    }

    var hasBlockingError: Bool {
        steps.contains { $0.status.isBlocking }
    }

    mutating func apply(_ event: Event) {
        switch event {
        case let .initialize(initializationErrorMessage):
            self.initializationErrorMessage = initializationErrorMessage
            if let initializationErrorMessage {
                updateStep(.hooks, status: .error(message: initializationErrorMessage))
            }

        case .checksStarted:
            isRunningChecks = true

        case .checksFinished:
            isRunningChecks = false

        case let .dependencyResolved(dep):
            guard let stepId = SetupStepID.dependency(named: dep.name),
                  steps.contains(where: { $0.id == stepId })
            else {
                return
            }

            if dep.found {
                updateStep(stepId, status: .completed(detail: "Installed"))
                if stepId == .claude {
                    claudePath = dep.path
                }
            } else if dep.required {
                let hint = stepId == .claude
                    ? "Not found — download from claude.ai/download"
                    : dep.installHint ?? "Please install \(stepId.rawValue)"
                updateStep(stepId, status: .error(message: hint))
            } else {
                let hint = dep.installHint ?? "Optional: install \(stepId.rawValue)"
                updateStep(stepId, status: .completed(detail: hint))
            }

        case let .hookStatusResolved(hookStatus):
            updateStep(.hooks, status: HookPresentationPolicy.setupStepStatus(for: hookStatus))

        case let .shellStatusResolved(status):
            updateStep(.shell, status: status)

        case .hookInstallStarted:
            updateStep(.hooks, status: .checking)

        case let .hookInstallFinished(result):
            switch result {
            case let .success(hookStatus):
                updateStep(.hooks, status: HookPresentationPolicy.setupStepStatus(for: hookStatus))
            case let .failure(message):
                updateStep(.hooks, status: .error(message: message))
            }

        case .shellInstructionsPresented:
            showShellInstructions = true

        case let .shellInstructionsDismissed(status):
            showShellInstructions = false
            updateStep(.shell, status: status)
        }
    }

    private mutating func updateStep(_ id: SetupStepID, status: SetupStepStatus) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].status = status
        }
    }
}

@Observable
@MainActor
final class SetupRequirementsManager {
    private(set) var steps: [SetupStep] = []
    private(set) var claudePath: String?
    private(set) var tmuxPath: String?
    private(set) var initializationErrorMessage: String?
    private(set) var isRunningChecks = false
    var showShellInstructions = false
    private let engine: CoreRuntime?
    private weak var shellStateStore: ShellStateStore?
    private let isPreview: Bool
    private var lifecycle = SetupLifecycleState.initial()

    var allComplete: Bool {
        steps.filter { !$0.isOptional }.allSatisfy(\.status.isComplete)
    }

    var hasBlockingError: Bool {
        steps.contains { $0.status.isBlocking }
    }

    var currentStepIndex: Int? {
        steps.firstIndex { !$0.status.isComplete }
    }

    init(
        engine: CoreRuntime? = nil,
        shellStateStore: ShellStateStore? = nil,
        runtimeFactory: () throws -> CoreRuntime = { try CoreRuntime() },
    ) {
        if let engine {
            self.engine = engine
            initializationErrorMessage = nil
        } else {
            do {
                self.engine = try runtimeFactory()
                initializationErrorMessage = nil
            } catch {
                self.engine = nil
                initializationErrorMessage = "Runtime initialization failed. Restart Capacitor and try again."
            }
        }
        self.shellStateStore = shellStateStore
        isPreview = false
        lifecycle = .initial()
        applyLifecycle(.initialize(initializationErrorMessage: initializationErrorMessage))
    }

    /// Preview-only initializer: pre-bakes step states so previews are instant and deterministic.
    private init(previewSteps: [SetupStep]) {
        engine = nil
        shellStateStore = nil
        initializationErrorMessage = nil
        isPreview = true
        lifecycle = SetupLifecycleState(
            steps: previewSteps,
            claudePath: nil,
            initializationErrorMessage: nil,
            isRunningChecks: false,
            showShellInstructions: false,
        )
        syncFromLifecycle()
    }

    func runChecks() async {
        guard !isPreview, !isRunningChecks, let engine else { return }
        applyLifecycle(.checksStarted)
        defer { applyLifecycle(.checksFinished) }

        guard let setupStatus = try? engine.checkSetupStatus() else { return }

        for dep in setupStatus.dependencies {
            await updateDependencyStatus(dep)
        }

        await updateHookStatus(setupStatus.hooks)
        updateShellStatus()
    }

    private func updateShellStatus() {
        let shellType = ShellType.current

        if let store = shellStateStore, ShellIntegrationChecker.isConfigured(shellStateStore: store) {
            applyLifecycle(.shellStatusResolved(.completed(detail: "Active")))
        } else if shellType.isSnippetInstalled {
            applyLifecycle(.shellStatusResolved(.completed(detail: "Installed")))
        } else if shellType == .unsupported {
            applyLifecycle(.shellStatusResolved(.completed(detail: "Skipped — unsupported shell")))
        } else {
            applyLifecycle(.shellStatusResolved(.actionNeeded(message: "Add hook to \(shellType.configFile)")))
        }
    }

    private func updateDependencyStatus(_ dep: DependencyStatus) async {
        guard let stepId = SetupStepID.dependency(named: dep.name) else { return }
        guard steps.contains(where: { $0.id == stepId }) else { return }

        applyLifecycle(.dependencyResolved(dep))

        if stepId == .claude, let path = dep.path, dep.found {
            await CapacitorConfig.shared.setClaudePath(path)
        }
    }

    private func updateHookStatus(_ hookStatus: HookStatus) async {
        applyLifecycle(.hookStatusResolved(hookStatus))
    }

    func executeStep(_ stepId: SetupStepID) async {
        switch stepId {
        case .hooks:
            await installHooks()
        case .shell:
            applyLifecycle(.shellInstructionsPresented)
        default:
            break
        }
    }

    func retryStep(_ stepId: SetupStepID) async {
        guard let engine else { return }
        switch stepId {
        case .claude:
            let dep = engine.checkDependency(name: stepId.rawValue)
            await updateDependencyStatus(dep)
        case .hooks:
            if let status = try? engine.getHookStatus() {
                await updateHookStatus(status)
            }
        case .shell:
            updateShellStatus()
        }
    }

    func dismissShellInstructions() {
        let shellType = ShellType.current
        let status: SetupStepStatus = if let store = shellStateStore, ShellIntegrationChecker.isConfigured(shellStateStore: store) {
            .completed(detail: "Active")
        } else if shellType.isSnippetInstalled {
            .completed(detail: "Installed")
        } else if shellType == .unsupported {
            .completed(detail: "Skipped — unsupported shell")
        } else {
            .actionNeeded(message: "Add hook to \(shellType.configFile)")
        }
        applyLifecycle(.shellInstructionsDismissed(status: status))
    }

    private func installHooks() async {
        guard let engine else { return }
        applyLifecycle(.hookInstallStarted)

        if let hookInstallError = HookInstaller.ensureHooksInstalled(using: engine) {
            applyLifecycle(.hookInstallFinished(result: .failure(hookInstallError)))
            return
        }

        if let status = try? engine.getHookStatus() {
            applyLifecycle(.hookInstallFinished(result: .success(status)))
        } else {
            applyLifecycle(.hookInstallFinished(result: .failure("Failed to verify hook status after installation")))
        }
    }

    private func applyLifecycle(_ event: SetupLifecycleState.Event) {
        lifecycle.apply(event)
        syncFromLifecycle()
    }

    private func syncFromLifecycle() {
        steps = lifecycle.steps
        claudePath = lifecycle.claudePath
        initializationErrorMessage = lifecycle.initializationErrorMessage
        isRunningChecks = lifecycle.isRunningChecks
        showShellInstructions = lifecycle.showShellInstructions
    }
}

// MARK: - Preview Scenarios

#if DEBUG
    enum SetupPreviewScenario: String, CaseIterable, Identifiable {
        case allPending = "All Pending"
        case checking = "Checking"
        case cliMissing = "CLI Missing"
        case hooksNeeded = "Hooks Needed"
        case hooksError = "Hooks Error"
        case hooksPolicyBlocked = "Policy Blocked"
        case shellOptional = "Shell Optional"
        case allComplete = "All Complete"

        var id: String {
            rawValue
        }
    }

    extension SetupRequirementsManager {
        static func preview(_ scenario: SetupPreviewScenario) -> SetupRequirementsManager {
            SetupRequirementsManager(previewSteps: scenario.steps)
        }
    }

    extension SetupPreviewScenario {
        /// Shared step builder to keep preview copy in sync with production copy
        private static func step(_ id: SetupStepID, status: SetupStepStatus) -> SetupStep {
            SetupStepCatalog.step(for: id, status: status)
        }

        private struct ScenarioState {
            let claude: SetupStepStatus
            let hooks: SetupStepStatus
            let shell: SetupStepStatus
        }

        private static func steps(for state: ScenarioState) -> [SetupStep] {
            [
                step(.claude, status: state.claude),
                step(.hooks, status: state.hooks),
                step(.shell, status: state.shell),
            ]
        }

        private var scenarioState: ScenarioState {
            switch self {
            case .allPending:
                ScenarioState(
                    claude: .pending,
                    hooks: .pending,
                    shell: .pending,
                )

            case .checking:
                ScenarioState(
                    claude: .checking,
                    hooks: .pending,
                    shell: .pending,
                )

            case .cliMissing:
                ScenarioState(
                    claude: .error(message: "Not found — download from claude.ai/download"),
                    hooks: .pending,
                    shell: .pending,
                )

            case .hooksNeeded:
                ScenarioState(
                    claude: .completed(detail: "Installed"),
                    hooks: HookPresentationPolicy.setupStepStatus(for: .notInstalled),
                    shell: .pending,
                )

            case .hooksError:
                ScenarioState(
                    claude: .completed(detail: "Installed"),
                    hooks: HookPresentationPolicy.setupStepStatus(for: .binaryBroken(reason: "preview")),
                    shell: .pending,
                )

            case .hooksPolicyBlocked:
                ScenarioState(
                    claude: .completed(detail: "Installed"),
                    hooks: HookPresentationPolicy.setupStepStatus(for: .policyBlocked(reason: "preview")),
                    shell: .pending,
                )

            case .shellOptional:
                ScenarioState(
                    claude: .completed(detail: "Installed"),
                    hooks: HookPresentationPolicy.setupStepStatus(for: .installed(version: "preview")),
                    shell: .actionNeeded(message: "Add to ~/.zshrc"),
                )

            case .allComplete:
                ScenarioState(
                    claude: .completed(detail: "Installed"),
                    hooks: HookPresentationPolicy.setupStepStatus(for: .installed(version: "preview")),
                    shell: .completed(detail: "Active"),
                )
            }
        }

        var steps: [SetupStep] {
            Self.steps(for: scenarioState)
        }
    }
#endif
