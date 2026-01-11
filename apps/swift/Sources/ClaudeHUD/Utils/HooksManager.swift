import Foundation
import Combine

enum HooksSetupStatus: String {
    case none = "None"
    case basic = "Basic"
    case complete = "Complete"
    case custom = "Custom"

    var description: String {
        switch self {
        case .none: return "No HUD hooks configured"
        case .basic: return "Basic state tracking only"
        case .complete: return "Full HUD integration"
        case .custom: return "Custom hooks detected"
        }
    }

    var color: String {
        switch self {
        case .none: return "red"
        case .basic: return "yellow"
        case .complete: return "green"
        case .custom: return "blue"
        }
    }
}

struct DiffLine: Identifiable {
    let id = UUID()
    let text: String
    let type: DiffType

    enum DiffType {
        case added
        case removed
        case context
    }
}

struct HooksConfig: Codable {
    let hooks: HooksSection?

    struct HooksSection: Codable {
        let UserPromptSubmit: [HookEntry]?
        let PostToolUse: [HookEntry]?
        let Stop: [HookEntry]?
        let Notification: [HookEntry]?
    }

    struct HookEntry: Codable {
        let matcher: String?
        let hooks: [String]?
    }
}

class HooksManager: ObservableObject {
    @Published var setupStatus: HooksSetupStatus = .none
    @Published var hasUserPromptSubmit = false
    @Published var hasPostToolUse = false
    @Published var hasStop = false
    @Published var hasNotification = false
    @Published var errorMessage: String?

    private let settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    private let hudScriptPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/scripts/hud-state-tracker.sh")

    func checkSetup() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: self.settingsPath))
                let config = try JSONDecoder().decode(HooksConfig.self, from: data)

                var hudHooksCount = 0

                if let hooks = config.hooks {
                    let hudScript = "hud-state-tracker"

                    if let userPromptSubmit = hooks.UserPromptSubmit,
                       userPromptSubmit.contains(where: { ($0.hooks ?? []).contains(where: { $0.contains(hudScript) }) }) {
                        hudHooksCount += 1
                        DispatchQueue.main.async { self.hasUserPromptSubmit = true }
                    }

                    if let postToolUse = hooks.PostToolUse,
                       postToolUse.contains(where: { ($0.hooks ?? []).contains(where: { $0.contains(hudScript) }) }) {
                        hudHooksCount += 1
                        DispatchQueue.main.async { self.hasPostToolUse = true }
                    }

                    if let stop = hooks.Stop,
                       stop.contains(where: { ($0.hooks ?? []).contains(where: { $0.contains(hudScript) }) }) {
                        hudHooksCount += 1
                        DispatchQueue.main.async { self.hasStop = true }
                    }

                    if let notification = hooks.Notification,
                       notification.contains(where: { ($0.hooks ?? []).contains(where: { $0.contains(hudScript) }) }) {
                        hudHooksCount += 1
                        DispatchQueue.main.async { self.hasNotification = true }
                    }
                }

                DispatchQueue.main.async {
                    if hudHooksCount == 0 {
                        self.setupStatus = .none
                    } else if hudHooksCount >= 3 {
                        self.setupStatus = .complete
                    } else {
                        self.setupStatus = .basic
                    }
                }

            } catch {
                DispatchQueue.main.async {
                    self.setupStatus = .none
                    self.errorMessage = "Could not read settings.json"
                }
            }
        }
    }

    func hasHudScript() -> Bool {
        FileManager.default.fileExists(atPath: hudScriptPath)
    }

    func getCurrentSettings() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        return content
    }

    static func generateDiff(current: String?, recommended: String) -> [DiffLine] {
        var diffLines: [DiffLine] = []

        let currentLines = (current ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let recommendedLines = recommended.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if current == nil {
            for line in recommendedLines {
                diffLines.append(DiffLine(text: line, type: .added))
            }
            return diffLines
        }

        let currentHooksLines = extractHooksSection(from: currentLines)
        let recommendedHooksLines = extractHooksSection(from: recommendedLines)

        if currentHooksLines.isEmpty {
            diffLines.append(DiffLine(text: "// Current settings.json has no hooks section", type: .context))
            diffLines.append(DiffLine(text: "// The following will be added:", type: .context))
            diffLines.append(DiffLine(text: "", type: .context))
            for line in recommendedHooksLines {
                diffLines.append(DiffLine(text: line, type: .added))
            }
        } else {
            diffLines.append(DiffLine(text: "// Existing hooks section:", type: .context))
            for line in currentHooksLines {
                diffLines.append(DiffLine(text: line, type: .removed))
            }
            diffLines.append(DiffLine(text: "", type: .context))
            diffLines.append(DiffLine(text: "// Recommended hooks section:", type: .context))
            for line in recommendedHooksLines {
                diffLines.append(DiffLine(text: line, type: .added))
            }
        }

        return diffLines
    }

    private static func extractHooksSection(from lines: [String]) -> [String] {
        var result: [String] = []
        var inHooks = false
        var braceCount = 0

        for line in lines {
            if line.contains("\"hooks\"") && line.contains("{") {
                inHooks = true
                braceCount = 1
                result.append(line)
                continue
            }

            if inHooks {
                result.append(line)
                braceCount += line.filter { $0 == "{" }.count
                braceCount -= line.filter { $0 == "}" }.count

                if braceCount <= 0 {
                    break
                }
            }
        }

        return result
    }

    static let recommendedHooksConfig = """
    {
      "hooks": {
        "UserPromptSubmit": [
          {
            "matcher": "",
            "hooks": ["$HOME/.claude/scripts/hud-state-tracker.sh thinking working"]
          }
        ],
        "PostToolUse": [
          {
            "matcher": "",
            "hooks": ["$HOME/.claude/scripts/hud-state-tracker.sh heartbeat"]
          }
        ],
        "Stop": [
          {
            "matcher": "",
            "hooks": ["$HOME/.claude/scripts/hud-state-tracker.sh done ready"]
          }
        ],
        "Notification": [
          {
            "matcher": "idle_prompt",
            "hooks": ["$HOME/.claude/scripts/hud-state-tracker.sh done ready"]
          }
        ]
      }
    }
    """
}
