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
            guard let stepID = SetupStepID.dependency(named: dep.name),
                  steps.contains(where: { $0.id == stepID })
            else {
                return
            }

            if dep.found {
                updateStep(stepID, status: .completed(detail: "Installed"))
                if stepID == .claude {
                    claudePath = dep.path
                }
            } else if dep.required {
                let hint = stepID == .claude
                    ? "Not found — download from claude.ai/download"
                    : dep.installHint ?? "Please install \(stepID.rawValue)"
                updateStep(stepID, status: .error(message: hint))
            } else {
                let hint = dep.installHint ?? "Optional: install \(stepID.rawValue)"
                updateStep(stepID, status: .completed(detail: hint))
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
final class SetupWorkflowState {
    private(set) var steps: [SetupStep] = []
    private(set) var claudePath: String?
    private(set) var initializationErrorMessage: String?
    private(set) var isRunningChecks = false
    var showShellInstructions = false
    private(set) var checkID = UUID()
    private(set) var isUsingPreviewMode = false

    @ObservationIgnored
    private let injectedSetupGateway: (any SetupGateway)?
    @ObservationIgnored
    private let runtimeFactory: () throws -> CoreRuntime
    @ObservationIgnored
    private var isShellIntegrationActive: @MainActor () -> Bool

    @ObservationIgnored
    private var setupGateway: (any SetupGateway)?
    @ObservationIgnored
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
        setupGateway: (any SetupGateway)? = nil,
        isShellIntegrationActive: @escaping @MainActor () -> Bool = { false },
        runtimeFactory: @escaping () throws -> CoreRuntime = { try CoreRuntime() },
    ) {
        injectedSetupGateway = setupGateway
        self.isShellIntegrationActive = isShellIntegrationActive
        self.runtimeFactory = runtimeFactory
        restoreLive()
    }

    func runChecks() async {
        guard !isUsingPreviewMode, !isRunningChecks, let setupGateway else { return }
        applyLifecycle(.checksStarted)
        defer { applyLifecycle(.checksFinished) }

        guard let setupStatus = try? setupGateway.fetchSetupStatus() else { return }

        for dep in setupStatus.dependencies {
            await updateDependencyStatus(dep)
        }

        await updateHookStatus(setupStatus.hooks)
        updateShellStatus()
    }

    func executeStep(_ stepID: SetupStepID) async {
        switch stepID {
        case .hooks:
            await installHooks()
        case .shell:
            applyLifecycle(.shellInstructionsPresented)
        default:
            break
        }
    }

    func retryStep(_ stepID: SetupStepID) async {
        guard let setupGateway else { return }

        switch stepID {
        case .claude:
            guard let dep = try? setupGateway.checkDependency(name: stepID.rawValue) else { return }
            await updateDependencyStatus(dep)
        case .hooks:
            guard let status = try? setupGateway.fetchHookStatus() else { return }
            await updateHookStatus(status)
        case .shell:
            updateShellStatus()
        }
    }

    func dismissShellInstructions() {
        let shellType = ShellType.current
        let status: SetupStepStatus = if isShellIntegrationActive() {
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

    func restoreLive() {
        isUsingPreviewMode = false
        lifecycle = .initial()
        let liveSetup = makeLiveSetupGateway()
        setupGateway = liveSetup.gateway
        applyLifecycle(.initialize(initializationErrorMessage: liveSetup.initializationErrorMessage))
        checkID = UUID()
    }

    func setShellIntegrationActivityProvider(_ isShellIntegrationActive: @escaping @MainActor () -> Bool) {
        self.isShellIntegrationActive = isShellIntegrationActive
    }

    #if DEBUG
        static func preview(_ scenario: SetupPreviewScenario) -> SetupWorkflowState {
            let workflowState = SetupWorkflowState(
                setupGateway: nil,
                isShellIntegrationActive: { false },
                runtimeFactory: { try CoreRuntime() },
            )
            workflowState.activatePreview(scenario)
            return workflowState
        }

        func activatePreview(_ scenario: SetupPreviewScenario) {
            isUsingPreviewMode = true
            setupGateway = nil
            lifecycle = SetupLifecycleState(
                steps: scenario.steps,
                claudePath: nil,
                initializationErrorMessage: nil,
                isRunningChecks: false,
                showShellInstructions: false,
            )
            syncFromLifecycle()
        }
    #endif

    private func makeLiveSetupGateway() -> (gateway: (any SetupGateway)?, initializationErrorMessage: String?) {
        if let injectedSetupGateway {
            return (injectedSetupGateway, nil)
        }

        do {
            let runtime = try runtimeFactory()
            return (LiveSetupGateway(runtimeProvider: { runtime }), nil)
        } catch {
            return (nil, "Runtime initialization failed. Restart Capacitor and try again.")
        }
    }

    private func updateShellStatus() {
        let shellType = ShellType.current

        if isShellIntegrationActive() {
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
        guard let stepID = SetupStepID.dependency(named: dep.name) else { return }
        guard steps.contains(where: { $0.id == stepID }) else { return }

        applyLifecycle(.dependencyResolved(dep))

        if stepID == .claude, let path = dep.path, dep.found {
            await CapacitorConfig.shared.setClaudePath(path)
        }
    }

    private func updateHookStatus(_ hookStatus: HookStatus) async {
        applyLifecycle(.hookStatusResolved(hookStatus))
    }

    private func installHooks() async {
        guard let setupGateway else { return }
        applyLifecycle(.hookInstallStarted)

        if let hookInstallError = setupGateway.installHooks() {
            applyLifecycle(.hookInstallFinished(result: .failure(hookInstallError)))
            return
        }

        guard let status = try? setupGateway.fetchHookStatus() else { return }
        applyLifecycle(.hookInstallFinished(result: .success(status)))
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

    extension SetupPreviewScenario {
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
