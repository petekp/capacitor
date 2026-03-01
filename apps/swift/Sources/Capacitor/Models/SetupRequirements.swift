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

@Observable
@MainActor
final class SetupRequirementsManager {
    private(set) var steps: [SetupStep] = []
    private(set) var claudePath: String?
    private(set) var tmuxPath: String?
    private(set) var isRunningChecks = false
    var showShellInstructions = false
    private let engine: CoreRuntime?
    private weak var shellStateStore: ShellStateStore?
    private let isPreview: Bool

    var allComplete: Bool {
        steps.filter { !$0.isOptional }.allSatisfy(\.status.isComplete)
    }

    var hasBlockingError: Bool {
        steps.contains { $0.status.isBlocking }
    }

    var currentStepIndex: Int? {
        steps.firstIndex { !$0.status.isComplete }
    }

    init(engine: CoreRuntime? = nil, shellStateStore: ShellStateStore? = nil) {
        self.engine = engine ?? (try? CoreRuntime()) ?? {
            fatalError("Failed to create CoreRuntime")
        }()
        self.shellStateStore = shellStateStore
        isPreview = false
        setupSteps()
    }

    /// Preview-only initializer: pre-bakes step states so previews are instant and deterministic.
    private init(previewSteps: [SetupStep]) {
        engine = nil
        shellStateStore = nil
        isPreview = true
        steps = previewSteps
    }

    private func setupSteps() {
        steps = SetupStepCatalog.defaultSteps()
    }

    func runChecks() async {
        guard !isPreview, !isRunningChecks, let engine else { return }
        isRunningChecks = true
        defer { isRunningChecks = false }

        let setupStatus = engine.checkSetupStatus()

        for dep in setupStatus.dependencies {
            await updateDependencyStatus(dep)
        }

        await updateHookStatus(setupStatus.hooks)
        updateShellStatus()
    }

    private func updateShellStatus() {
        updateStep(.shell, status: .checking)

        let shellType = ShellType.current

        if let store = shellStateStore, ShellIntegrationChecker.isConfigured(shellStateStore: store) {
            updateStep(.shell, status: .completed(detail: "Active"))
        } else if shellType.isSnippetInstalled {
            updateStep(.shell, status: .completed(detail: "Installed"))
        } else if shellType == .unsupported {
            updateStep(.shell, status: .completed(detail: "Skipped — unsupported shell"))
        } else {
            updateStep(.shell, status: .actionNeeded(message: "Add hook to \(shellType.configFile)"))
        }
    }

    private func updateDependencyStatus(_ dep: DependencyStatus) async {
        guard let stepId = SetupStepID.dependency(named: dep.name) else { return }
        guard steps.contains(where: { $0.id == stepId }) else { return }

        updateStep(stepId, status: .checking)

        if dep.found {
            updateStep(stepId, status: .completed(detail: "Installed"))

            if stepId == .claude {
                claudePath = dep.path
                if let path = dep.path {
                    await CapacitorConfig.shared.setClaudePath(path)
                }
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
    }

    private func updateHookStatus(_ hookStatus: HookStatus) async {
        updateStep(.hooks, status: .checking)
        updateStep(.hooks, status: HookPresentationPolicy.setupStepStatus(for: hookStatus))
    }

    func executeStep(_ stepId: SetupStepID) async {
        switch stepId {
        case .hooks:
            await installHooks()
        case .shell:
            showShellInstructions = true
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
            let status = engine.getHookStatus()
            await updateHookStatus(status)
        case .shell:
            updateShellStatus()
        }
    }

    func dismissShellInstructions() {
        showShellInstructions = false
        updateShellStatus()
    }

    private func updateStep(_ id: SetupStepID, status: SetupStepStatus) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].status = status
        }
    }

    private func installHooks() async {
        guard let engine else { return }
        updateStep(.hooks, status: .checking)

        if let hookInstallError = HookInstaller.ensureHooksInstalled(using: engine) {
            updateStep(.hooks, status: .error(message: hookInstallError))
            return
        }

        let status = engine.getHookStatus()
        await updateHookStatus(status)
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

        var steps: [SetupStep] {
            switch self {
            case .allPending:
                [Self.step(.claude, status: .pending), Self.step(.hooks, status: .pending), Self.step(.shell, status: .pending)]

            case .checking:
                [Self.step(.claude, status: .checking), Self.step(.hooks, status: .pending), Self.step(.shell, status: .pending)]

            case .cliMissing:
                [Self.step(.claude, status: .error(message: "Not found — download from claude.ai/download")), Self.step(.hooks, status: .pending), Self.step(.shell, status: .pending)]

            case .hooksNeeded:
                [Self.step(.claude, status: .completed(detail: "Installed")), Self.step(.hooks, status: HookPresentationPolicy.setupStepStatus(for: .notInstalled)), Self.step(.shell, status: .pending)]

            case .hooksError:
                [Self.step(.claude, status: .completed(detail: "Installed")), Self.step(.hooks, status: HookPresentationPolicy.setupStepStatus(for: .binaryBroken(reason: "preview"))), Self.step(.shell, status: .pending)]

            case .hooksPolicyBlocked:
                [Self.step(.claude, status: .completed(detail: "Installed")), Self.step(.hooks, status: HookPresentationPolicy.setupStepStatus(for: .policyBlocked(reason: "preview"))), Self.step(.shell, status: .pending)]

            case .shellOptional:
                [Self.step(.claude, status: .completed(detail: "Installed")), Self.step(.hooks, status: HookPresentationPolicy.setupStepStatus(for: .installed(version: "preview"))), Self.step(.shell, status: .actionNeeded(message: "Add to ~/.zshrc"))]

            case .allComplete:
                [Self.step(.claude, status: .completed(detail: "Installed")), Self.step(.hooks, status: HookPresentationPolicy.setupStepStatus(for: .installed(version: "preview"))), Self.step(.shell, status: .completed(detail: "Active"))]
            }
        }
    }
#endif
