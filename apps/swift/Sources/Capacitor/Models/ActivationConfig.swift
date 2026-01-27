import Foundation

// MARK: - ParentApp Extensions (UniFFI enum from hud-core)

extension ParentApp: Identifiable, CaseIterable {
    public var id: String {
        switch self {
        case .ghostty: return "ghostty"
        case .iTerm: return "iterm2"
        case .terminal: return "terminal"
        case .alacritty: return "alacritty"
        case .kitty: return "kitty"
        case .warp: return "warp"
        case .cursor: return "cursor"
        case .vsCode: return "vscode"
        case .vsCodeInsiders: return "vscode-insiders"
        case .zed: return "zed"
        case .tmux: return "tmux"
        case .unknown: return "unknown"
        }
    }

    public static var allCases: [ParentApp] {
        [.ghostty, .iTerm, .terminal, .alacritty, .kitty, .warp,
         .cursor, .vsCode, .vsCodeInsiders, .zed, .tmux, .unknown]
    }

    var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .iTerm: return "iTerm2"
        case .terminal: return "Terminal.app"
        case .alacritty: return "Alacritty"
        case .kitty: return "kitty"
        case .warp: return "Warp"
        case .cursor: return "Cursor"
        case .vsCode: return "VS Code"
        case .vsCodeInsiders: return "VS Code Insiders"
        case .zed: return "Zed"
        case .tmux: return "tmux"
        case .unknown: return "Unknown"
        }
    }

    var category: ParentAppCategory {
        switch self {
        case .cursor, .vsCode, .vsCodeInsiders, .zed: return .ide
        case .ghostty, .iTerm, .terminal, .alacritty, .kitty, .warp: return .terminal
        case .tmux: return .multiplexer
        case .unknown: return .unknown
        }
    }

    init(fromString app: String?) {
        guard let app = app else {
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

    var id: String { rawValue }
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .activateByTTY: return "TTY Lookup"
        case .activateByApp: return "Activate App"
        case .activateKittyRemote: return "kitty Remote"
        case .activateIDEWindow: return "IDE Window"
        case .switchTmuxSession: return "Switch tmux"
        case .activateHostFirst: return "Host → tmux"
        case .launchNewTerminal: return "Launch New"
        case .priorityFallback: return "Priority Order"
        case .skip: return "Skip"
        }
    }

    var description: String {
        switch self {
        case .activateByTTY: return "Query iTerm/Terminal via AppleScript to find TTY owner"
        case .activateByApp: return "Simply activate the app by name"
        case .activateKittyRemote: return "Use kitty @ focus-window --match pid:"
        case .activateIDEWindow: return "Run cursor/code CLI to focus correct window"
        case .switchTmuxSession: return "Run tmux switch-client -t <session>"
        case .activateHostFirst: return "Find host terminal TTY, then switch tmux session"
        case .launchNewTerminal: return "Spawn new terminal with project"
        case .priorityFallback: return "Use TerminalApp priority order"
        case .skip: return "Do nothing"
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
            return ideDefault(scenario)
        case .terminal:
            return terminalDefault(scenario)
        case .multiplexer:
            return multiplexerDefault(scenario)
        case .unknown:
            return unknownDefault(scenario)
        }
    }

    private static func ideDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch (scenario.context, scenario.multiplicity) {
        case (.direct, .single), (.direct, .multipleTabs):
            return ScenarioBehavior(primaryStrategy: .activateIDEWindow, fallbackStrategy: nil)
        case (.direct, .multipleWindows):
            return ScenarioBehavior(primaryStrategy: .activateIDEWindow, fallbackStrategy: .priorityFallback)
        case (.tmux, .single), (.tmux, .multipleTabs):
            return ScenarioBehavior(primaryStrategy: .activateIDEWindow, fallbackStrategy: .switchTmuxSession)
        case (.tmux, .multipleWindows):
            return ScenarioBehavior(primaryStrategy: .activateIDEWindow, fallbackStrategy: .activateHostFirst)
        }
    }

    private static func terminalDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch scenario.parentApp {
        case .iTerm, .terminal:
            return ttyCapableTerminalDefault(scenario)
        case .kitty:
            return kittyDefault(scenario)
        case .ghostty, .alacritty, .warp:
            return basicTerminalDefault(scenario)
        default:
            return ScenarioBehavior(primaryStrategy: .priorityFallback, fallbackStrategy: nil)
        }
    }

    private static func ttyCapableTerminalDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch (scenario.context, scenario.multiplicity) {
        case (.direct, _):
            return ScenarioBehavior(primaryStrategy: .activateByTTY, fallbackStrategy: nil)
        case (.tmux, .single), (.tmux, .multipleTabs):
            return ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: nil)
        case (.tmux, .multipleWindows):
            return ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: .priorityFallback)
        }
    }

    private static func kittyDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch (scenario.context, scenario.multiplicity) {
        case (.direct, _):
            return ScenarioBehavior(primaryStrategy: .activateKittyRemote, fallbackStrategy: .activateByApp)
        case (.tmux, .single), (.tmux, .multipleTabs):
            return ScenarioBehavior(primaryStrategy: .activateKittyRemote, fallbackStrategy: .switchTmuxSession)
        case (.tmux, .multipleWindows):
            return ScenarioBehavior(primaryStrategy: .activateKittyRemote, fallbackStrategy: .activateHostFirst)
        }
    }

    private static func basicTerminalDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch (scenario.context, scenario.multiplicity) {
        case (.direct, .single):
            return ScenarioBehavior(primaryStrategy: .activateByApp, fallbackStrategy: nil)
        case (.direct, .multipleTabs), (.direct, .multipleWindows):
            return ScenarioBehavior(primaryStrategy: .activateByApp, fallbackStrategy: .priorityFallback)
        case (.tmux, _):
            return ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: nil)
        }
    }

    private static func multiplexerDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch scenario.multiplicity {
        case .single, .multipleTabs:
            return ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: nil)
        case .multipleWindows:
            return ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: .priorityFallback)
        }
    }

    private static func unknownDefault(_ scenario: ShellScenario) -> ScenarioBehavior {
        switch scenario.context {
        case .direct:
            return ScenarioBehavior(primaryStrategy: .activateByTTY, fallbackStrategy: .priorityFallback)
        case .tmux:
            return ScenarioBehavior(primaryStrategy: .activateHostFirst, fallbackStrategy: .priorityFallback)
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
