import Foundation

struct ShellEntry: Codable, Equatable {
    let cwd: String
    let tty: String
    let parentApp: String?
    let tmuxSession: String?
    let tmuxClientTty: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case cwd, tty
        case parentApp = "parent_app"
        case tmuxSession = "tmux_session"
        case tmuxClientTty = "tmux_client_tty"
        case updatedAt = "updated_at"
    }
}

struct ShellCwdState: Codable {
    let version: Int
    let shells: [String: ShellEntry]
}

@MainActor
@Observable
final class ShellStateStore {
    private enum Constants {
        static let pollingIntervalNanoseconds: UInt64 = 500_000_000
    }

    private let stateURL: URL
    private var pollTask: _Concurrency.Task<Void, Never>?

    private(set) var state: ShellCwdState?

    init() {
        self.stateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/shell-cwd.json")
    }

    func startPolling() {
        pollTask = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                self?.loadState()
                try? await _Concurrency.Task.sleep(nanoseconds: Constants.pollingIntervalNanoseconds)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL) else {
            return
        }

        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = formatter.date(from: dateStr) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateStr)")
        }

        guard let decoded = try? decoder.decode(ShellCwdState.self, from: data) else {
            return
        }

        state = decoded
    }

    var mostRecentShell: (pid: String, entry: ShellEntry)? {
        state?.shells
            .max(by: { $0.value.updatedAt < $1.value.updatedAt })
            .map { ($0.key, $0.value) }
    }

    var hasActiveShells: Bool {
        guard let shells = state?.shells else { return false }
        return !shells.isEmpty
    }
}
