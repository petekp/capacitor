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

struct SetupStep: Identifiable {
    let id: String
    let title: String
    let description: String
    var status: SetupStepStatus
    var isOptional: Bool = false

    var statusDetail: String {
        switch status {
        case .pending:
            return description
        case .checking:
            return "Checking..."
        case .completed(let detail):
            return detail
        case .actionNeeded(let message):
            return message
        case .error(let message):
            return message
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
    private let engine: HudEngine
    private weak var shellStateStore: ShellStateStore?

    var allComplete: Bool {
        steps.filter { !$0.isOptional }.allSatisfy { $0.status.isComplete }
    }

    var hasBlockingError: Bool {
        steps.contains { $0.status.isBlocking }
    }

    var currentStepIndex: Int? {
        steps.firstIndex { !$0.status.isComplete }
    }

    init(engine: HudEngine? = nil, shellStateStore: ShellStateStore? = nil) {
        self.engine = engine ?? (try? HudEngine()) ?? {
            fatalError("Failed to create HudEngine")
        }()
        self.shellStateStore = shellStateStore
        setupSteps()
    }

    private func setupSteps() {
        steps = [
            SetupStep(
                id: "claude",
                title: "Claude CLI",
                description: "Required for session tracking",
                status: .pending
            ),
            SetupStep(
                id: "hooks",
                title: "Session hooks",
                description: "Required for live state tracking",
                status: .pending
            ),
            SetupStep(
                id: "shell",
                title: "Shell integration",
                description: "Track active project across terminals",
                status: .pending,
                isOptional: true
            )
        ]
    }

    func runChecks() async {
        guard !isRunningChecks else { return }
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
        updateStep("shell", status: .checking)

        let shellType = ShellType.current

        if let store = shellStateStore, ShellIntegrationChecker.isConfigured(shellStateStore: store) {
            updateStep("shell", status: .completed(detail: "Receiving shell events"))
        } else if ShellIntegrationChecker.stateFileExists() {
            updateStep("shell", status: .completed(detail: "Receiving shell events"))
        } else if shellType.isSnippetInstalled {
            updateStep("shell", status: .completed(detail: "\(shellType.configFile) configured"))
        } else if shellType == .unsupported {
            updateStep("shell", status: .completed(detail: "Skipped: unsupported shell"))
        } else {
            updateStep("shell", status: .actionNeeded(message: "Optional: add to \(shellType.configFile)"))
        }
    }

    private func updateDependencyStatus(_ dep: DependencyStatus) async {
        let stepId = dep.name

        guard steps.contains(where: { $0.id == stepId }) else { return }

        updateStep(stepId, status: .checking)

        if dep.found {
            let path = dep.path ?? "Found"
            updateStep(stepId, status: .completed(detail: path))

            if dep.name == "claude" {
                claudePath = dep.path
                if let path = dep.path {
                    await CapacitorConfig.shared.setClaudePath(path)
                }
            } else if dep.name == "tmux" {
                tmuxPath = dep.path
            }
        } else if dep.required {
            let hint = dep.installHint ?? "Please install \(dep.name)"
            updateStep(stepId, status: .error(message: hint))
        } else {
            let hint = dep.installHint ?? "Optional: install \(dep.name)"
            updateStep(stepId, status: .completed(detail: hint))
        }
    }

    private func updateHookStatus(_ hookStatus: HookStatus) async {
        updateStep("hooks", status: .checking)

        switch hookStatus {
        case .installed(let version):
            updateStep("hooks", status: .completed(detail: "v\(version) installed"))

        case .notInstalled:
            updateStep("hooks", status: .actionNeeded(message: "Not installed yet"))

        case .outdated(let current, let latest):
            updateStep("hooks", status: .actionNeeded(message: "Update available: v\(current) → v\(latest)"))

        case .policyBlocked(let reason):
            updateStep("hooks", status: .error(message: reason))

        case .binaryBroken(let reason):
            updateStep("hooks", status: .error(message: "Binary broken: \(reason)"))

        case .symlinkBroken(let target, let reason):
            updateStep("hooks", status: .error(message: "Symlink broken: \(reason) (target: \(target))"))
        }
    }

    func executeStep(_ stepId: String) async {
        switch stepId {
        case "hooks":
            await installHooks()
        case "shell":
            showShellInstructions = true
        default:
            break
        }
    }

    func retryStep(_ stepId: String) async {
        switch stepId {
        case "claude":
            let dep = engine.checkDependency(name: stepId)
            await updateDependencyStatus(dep)
        case "hooks":
            let status = engine.getHookStatus()
            await updateHookStatus(status)
        case "shell":
            updateShellStatus()
        default:
            break
        }
    }

    func dismissShellInstructions() {
        showShellInstructions = false
        updateShellStatus()
    }

    private func updateStep(_ id: String, status: SetupStepStatus) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].status = status
        }
    }

    private func installHooks() async {
        updateStep("hooks", status: .checking)

        // First, install the bundled hook binary using the shared helper
        if let installError = HookInstaller.installBundledBinary(using: engine) {
            updateStep("hooks", status: .error(message: installError))
            return
        }

        do {
            let result = try engine.installHooks()

            if result.success {
                let status = engine.getHookStatus()
                await updateHookStatus(status)
            } else {
                updateStep("hooks", status: .error(message: result.message))
            }
        } catch {
            updateStep("hooks", status: .error(message: "Installation failed: \(error.localizedDescription)"))
        }
    }
}
