enum SetupStepCatalog {
    static func defaultSteps() -> [SetupStep] {
        [
            claude(),
            hooks(),
            shell(),
        ]
    }

    static func step(for id: String, status: SetupStepStatus) -> SetupStep {
        switch id {
        case "claude":
            claude(status: status)
        case "hooks":
            hooks(status: status)
        case "shell":
            shell(status: status)
        default:
            fatalError("Unknown setup step id: \(id)")
        }
    }

    static func claude(status: SetupStepStatus = .pending) -> SetupStep {
        SetupStep(
            id: "claude",
            title: "Claude Code",
            description: "Capacitor reads your Claude sessions to show live project status",
            status: status,
        )
    }

    static func hooks(status: SetupStepStatus = .pending) -> SetupStep {
        SetupStep(
            id: "hooks",
            title: "Session tracking",
            description: "See which projects are active and what Claude is working on",
            status: status,
        )
    }

    static func shell(status: SetupStepStatus = .pending) -> SetupStep {
        SetupStep(
            id: "shell",
            title: "Terminal tracking",
            description: "Add hook to ~/.zshrc to auto-detect which project each terminal is in",
            status: status,
            isOptional: true,
        )
    }
}
