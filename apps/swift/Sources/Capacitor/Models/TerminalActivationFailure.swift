import Foundation

enum HostTerminalOperation: Equatable {
    case focusByTTY
    case openApplication
    case sendCommand
}

enum TerminalActivationFailureReason: Equatable, Error {
    case ghosttyUnsupportedVersion(String?)
    case ghosttyAutomationUnavailable(String?)
    case hostOperationFailed(
        app: SupportedTerminalApp,
        operation: HostTerminalOperation,
        detail: String?,
    )

    var userMessage: String {
        switch self {
        case let .ghosttyUnsupportedVersion(version):
            if let version, !version.isEmpty {
                return "Ghostty \(version) is unsupported. Capacitor requires Ghostty 1.3 or newer."
            }
            return "Ghostty 1.3 or newer is required for terminal switching."
        case let .ghosttyAutomationUnavailable(detail):
            let base = "Ghostty AppleScript automation is unavailable. Make sure Ghostty 1.3+ is installed, `macos-applescript` is enabled, and macOS Automation access is granted."
            return appendDetail(base, detail: detail)
        case let .hostOperationFailed(app, operation, detail):
            let base = switch operation {
            case .focusByTTY:
                "Couldn't focus the existing \(app.displayName) terminal. Make sure macOS Automation access is granted."
            case .openApplication:
                "Couldn't open \(app.displayName)."
            case .sendCommand:
                "Couldn't send the launch command to \(app.displayName). Make sure macOS Automation access is granted."
            }
            return appendDetail(base, detail: detail)
        }
    }

    private func appendDetail(_ base: String, detail: String?) -> String {
        guard let detail = cleanFailureDetail(detail) else {
            return base
        }
        return "\(base) (\(detail))"
    }
}

func cleanFailureDetail(_ detail: String?) -> String? {
    detail?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
