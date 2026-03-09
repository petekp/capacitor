import Darwin
import Foundation

enum ShellType: String, CaseIterable {
    case zsh
    case bash
    case fish
    case unsupported

    var displayName: String {
        switch self {
        case .zsh: "Zsh"
        case .bash: "Bash"
        case .fish: "Fish"
        case .unsupported: "Unknown"
        }
    }

    var configFile: String {
        switch self {
        case .zsh: "~/.zshrc"
        case .bash: "~/.bashrc"
        case .fish: "~/.config/fish/config.fish"
        case .unsupported: ""
        }
    }

    var snippet: String {
        switch self {
        case .zsh:
            """
            # Capacitor shell integration
            if [[ -x "$HOME/.local/bin/hud-hook" ]]; then
              _capacitor_precmd() {
                CAPACITOR_RUNTIME_ENABLED=1 "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$(tty)" 2>/dev/null &!
              }
              precmd_functions+=(_capacitor_precmd)
            fi
            """
        case .bash:
            """
            # Capacitor shell integration
            if [[ -x "$HOME/.local/bin/hud-hook" ]]; then
              _capacitor_prompt() {
                CAPACITOR_RUNTIME_ENABLED=1 "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$(tty)" 2>/dev/null &
              }
              PROMPT_COMMAND="_capacitor_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
            fi
            """
        case .fish:
            """
            # Capacitor shell integration
            if test -x "$HOME/.local/bin/hud-hook"
              function _capacitor_postexec --on-event fish_postexec
                CAPACITOR_RUNTIME_ENABLED=1 "$HOME/.local/bin/hud-hook" cwd "$PWD" "$fish_pid" (tty) 2>/dev/null &
              end
            end
            """
        case .unsupported:
            "# Shell integration not available for this shell"
        }
    }

    static var current: ShellType {
        let shell = ProcessInfo.processInfo.environment["SHELL"]
            ?? loginShellPath()
            ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent

        switch shellName {
        case "zsh": return .zsh
        case "bash": return .bash
        case "fish": return .fish
        default: return .unsupported
        }
    }

    private static func loginShellPath() -> String? {
        let uid = getuid()
        guard let pwd = getpwuid(uid) else { return nil }
        return String(cString: pwd.pointee.pw_shell)
    }

    var configFileURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .zsh:
            return home.appendingPathComponent(".zshrc")
        case .bash:
            return home.appendingPathComponent(".bashrc")
        case .fish:
            return home.appendingPathComponent(".config/fish/config.fish")
        case .unsupported:
            return nil
        }
    }

    var isSnippetInstalled: Bool {
        guard let url = configFileURL,
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return false
        }
        return contents.contains("Capacitor shell integration")
    }

    func installSnippet() -> Result<Void, ShellInstallError> {
        guard self != .unsupported else {
            return .failure(.unsupportedShell)
        }

        guard let url = configFileURL else {
            return .failure(.noConfigFile)
        }

        if isSnippetInstalled {
            return .failure(.alreadyInstalled)
        }

        do {
            let fileManager = FileManager.default
            let parentDir = url.deletingLastPathComponent()

            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            var contents = ""
            if fileManager.fileExists(atPath: url.path) {
                contents = try String(contentsOf: url, encoding: .utf8)
            }

            let newContents = contents.isEmpty
                ? snippet
                : contents + "\n\n" + snippet + "\n"

            try newContents.write(to: url, atomically: true, encoding: .utf8)
            return .success(())
        } catch {
            return .failure(.writeError(error.localizedDescription))
        }
    }
}

enum ShellInstallError: LocalizedError {
    case unsupportedShell
    case noConfigFile
    case alreadyInstalled
    case writeError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShell:
            "Shell type not supported"
        case .noConfigFile:
            "Could not determine config file location"
        case .alreadyInstalled:
            "Shell integration is already installed"
        case let .writeError(message):
            "Failed to write config: \(message)"
        }
    }
}
