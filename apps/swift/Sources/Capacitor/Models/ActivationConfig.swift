import Foundation

// MARK: - ParentApp Extensions (UniFFI enum from capacitor-core)

extension ParentApp: Identifiable, CaseIterable {
    public var id: String {
        switch self {
        case .ghostty: "ghostty"
        case .iTerm: "iterm2"
        case .terminal: "terminal"
        case .alacritty: "alacritty"
        case .kitty: "kitty"
        case .warp: "warp"
        case .cursor: "cursor"
        case .vsCode: "vscode"
        case .vsCodeInsiders: "vscode-insiders"
        case .zed: "zed"
        case .tmux: "tmux"
        case .unknown: "unknown"
        }
    }

    public static var allCases: [ParentApp] {
        [.ghostty, .iTerm, .terminal, .alacritty, .kitty, .warp,
         .cursor, .vsCode, .vsCodeInsiders, .zed, .tmux, .unknown]
    }

    var displayName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .iTerm: "iTerm2"
        case .terminal: "Terminal.app"
        case .alacritty: "Alacritty"
        case .kitty: "kitty"
        case .warp: "Warp"
        case .cursor: "Cursor"
        case .vsCode: "VS Code"
        case .vsCodeInsiders: "VS Code Insiders"
        case .zed: "Zed"
        case .tmux: "tmux"
        case .unknown: "Unknown"
        }
    }

    var category: ParentAppCategory {
        switch self {
        case .cursor, .vsCode, .vsCodeInsiders, .zed: .ide
        case .ghostty, .iTerm, .terminal, .alacritty, .kitty, .warp: .terminal
        case .tmux: .multiplexer
        case .unknown: .unknown
        }
    }

    init(fromString app: String?) {
        guard let app else {
            self = .unknown
            return
        }
        switch app.lowercased() {
        case "ghostty": self = .ghostty
        case "iterm2": self = .iTerm
        case "terminal": self = .terminal
        case "alacritty": self = .alacritty
        case "kitty": self = .kitty
        case "warp": self = .warp
        case "cursor": self = .cursor
        case "vscode": self = .vsCode
        case "vscode-insiders": self = .vsCodeInsiders
        case "zed": self = .zed
        case "tmux": self = .tmux
        default: self = .unknown
        }
    }
}

enum ParentAppCategory: String, CaseIterable, Identifiable {
    case ide = "IDE Terminals"
    case terminal = "Native Terminals"
    case multiplexer = "Multiplexed"
    case unknown = "Unknown Parent"

    var id: String {
        rawValue
    }
}

// MARK: - Shell Context

enum ShellContext: String, CaseIterable, Codable {
    case direct
    case tmux

    init(hasTmuxSession: Bool) {
        self = hasTmuxSession ? .tmux : .direct
    }
}

// MARK: - Terminal Multiplicity

enum TerminalMultiplicity: String, CaseIterable, Codable {
    case single
    case multipleTabs = "tabs"
    case multipleWindows = "windows"

    init(shellCount: Int) {
        if shellCount <= 1 {
            self = .single
        } else {
            self = .multipleTabs
        }
    }
}

// MARK: - Activation Strategy

enum ActivationStrategy: String, CaseIterable, Codable, Identifiable {
    case activateByTTY
    case activateByApp
    case activateKittyRemote
    case activateIDEWindow
    case switchTmuxSession
    case activateHostFirst
    case launchNewTerminal
    case priorityFallback
    case skip

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .activateByTTY: "TTY Lookup"
        case .activateByApp: "Activate App"
        case .activateKittyRemote: "kitty Remote"
        case .activateIDEWindow: "IDE Window"
        case .switchTmuxSession: "Switch tmux"
        case .activateHostFirst: "Host → tmux"
        case .launchNewTerminal: "Launch New"
        case .priorityFallback: "Priority Order"
        case .skip: "Skip"
        }
    }

    var description: String {
        switch self {
        case .activateByTTY: "Query iTerm/Terminal via AppleScript to find TTY owner"
        case .activateByApp: "Simply activate the app by name"
        case .activateKittyRemote: "Use kitty @ focus-window --match pid:"
        case .activateIDEWindow: "Run cursor/code CLI to focus correct window"
        case .switchTmuxSession: "Run tmux switch-client -t <session>"
        case .activateHostFirst: "Find host terminal TTY, then switch tmux session"
        case .launchNewTerminal: "Spawn new terminal with project"
        case .priorityFallback: "Use TerminalApp priority order"
        case .skip: "Do nothing"
        }
    }
}

// MARK: - Shell Scenario

struct ShellScenario: Identifiable, Hashable {
    let parentApp: ParentApp
    let context: ShellContext
    let multiplicity: TerminalMultiplicity

    var id: String {
        "\(parentApp.id):\(context.rawValue):\(multiplicity.rawValue)"
    }
}

// MARK: - Scenario Behavior

struct ScenarioBehavior: Codable, Equatable {
    var primaryStrategy: ActivationStrategy
    var fallbackStrategy: ActivationStrategy?

    static func defaultBehavior(for scenario: ShellScenario) -> ScenarioBehavior {
        switch scenario.parentApp.category {
        case .ide:
            ideDefault(scenario)
        case .terminal:
            terminalDefault(scenario)
        case .multiplexer:
            multiplexerDefault(scenario)
        case .unknown:
            unknownDefault(scenario)
        }
    }

    private static func ideDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch (scenario.context, scenario.multiplicity) {
        case (.direct, .single), (.direct, .multipleTabs):
            ScenarioBehavior(primaryStrategy: .activateIDEWindow, fallbackStrategy: nil)
        case (.direct, .multipleWindows):
            ScenarioBehavior(primaryStrategy: .activateIDEWindow, fallbackStrategy: .priorityFallback)
        case (.tmux, .single), (.tmux, .multipleTabs):
            ScenarioBehavior(primaryStrategy: .activateIDEWindow, fallbackStrategy: .switchTmuxSession)
        case (.tmux, .multipleWindows):
            ScenarioBehavior(primaryStrategy: .activateIDEWindow, fallbackStrategy: .activateHostFirst)
        }
    }

    private static func terminalDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch scenario.parentApp {
        case .iTerm, .terminal:
            ttyCapableTerminalDefault(scenario)
        case .kitty:
            kittyDefault(scenario)
        case .ghostty, .alacritty, .warp:
            basicTerminalDefault(scenario)
        default:
            ScenarioBehavior(primaryStrategy: .priorityFallback, fallbackStrategy: nil)
        }
    }

    private static func ttyCapableTerminalDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch (scenario.context, scenario.multiplicity) {
        case (.direct, _):
            ScenarioBehavior(primaryStrategy: .activateByTTY, fallbackStrategy: nil)
        case (.tmux, .single), (.tmux, .multipleTabs):
            ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: nil)
        case (.tmux, .multipleWindows):
            ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: .priorityFallback)
        }
    }

    private static func kittyDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch (scenario.context, scenario.multiplicity) {
        case (.direct, _):
            ScenarioBehavior(primaryStrategy: .activateKittyRemote, fallbackStrategy: .activateByApp)
        case (.tmux, .single), (.tmux, .multipleTabs):
            ScenarioBehavior(primaryStrategy: .activateKittyRemote, fallbackStrategy: .switchTmuxSession)
        case (.tmux, .multipleWindows):
            ScenarioBehavior(primaryStrategy: .activateKittyRemote, fallbackStrategy: .activateHostFirst)
        }
    }

    private static func basicTerminalDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch (scenario.context, scenario.multiplicity) {
        case (.direct, .single):
            ScenarioBehavior(primaryStrategy: .activateByApp, fallbackStrategy: nil)
        case (.direct, .multipleTabs), (.direct, .multipleWindows):
            ScenarioBehavior(primaryStrategy: .activateByApp, fallbackStrategy: .priorityFallback)
        case (.tmux, _):
            ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: nil)
        }
    }

    private static func multiplexerDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch scenario.multiplicity {
        case .single, .multipleTabs:
            ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: nil)
        case .multipleWindows:
            ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: .priorityFallback)
        }
    }

    private static func unknownDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch scenario.context {
        case .direct:
            ScenarioBehavior(primaryStrategy: .activateByTTY, fallbackStrategy: .priorityFallback)
        case .tmux:
            ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: .priorityFallback)
        }
    }
}

// MARK: - Activation Config Store

@MainActor
@Observable
final class ActivationConfigStore {
    static let shared = ActivationConfigStore()

    private var overrides: [String: ScenarioBehavior] = [:]
    private let persistenceKey = "activation_behavior_overrides"

    private init() {
        loadFromDisk()
    }

    func behavior(for scenario: ShellScenario) -> ScenarioBehavior {
        overrides[scenario.id] ?? ScenarioBehavior.defaultBehavior(for: scenario)
    }

    func setBehavior(_ behavior: ScenarioBehavior, for scenario: ShellScenario) {
        let defaultBehavior = ScenarioBehavior.defaultBehavior(for: scenario)
        if behavior == defaultBehavior {
            overrides.removeValue(forKey: scenario.id)
        } else {
            overrides[scenario.id] = behavior
        }
        saveToDisk()
    }

    func resetBehavior(for scenario: ShellScenario) {
        overrides.removeValue(forKey: scenario.id)
        saveToDisk()
    }

    func resetAll() {
        overrides.removeAll()
        saveToDisk()
    }

    func isModified(_ scenario: ShellScenario) -> Bool {
        overrides[scenario.id] != nil
    }

    var modifiedCount: Int {
        overrides.count
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: ScenarioBehavior].self, from: data)
        else { return }
        overrides = decoded
    }
}
