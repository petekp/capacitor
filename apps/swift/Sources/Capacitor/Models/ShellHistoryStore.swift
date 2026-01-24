import Foundation

struct ShellHistoryEntry: Codable, Equatable {
    let cwd: String
    let pid: Int
    let tty: String
    let parentApp: String?
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case cwd, pid, tty
        case parentApp = "parent_app"
        case timestamp
    }
}

@MainActor
@Observable
final class ShellHistoryStore {
    private enum Constants {
        static let defaultRetentionDays = 30
    }

    private let historyURL: URL
    private let decoder: JSONDecoder

    private(set) var entries: [ShellHistoryEntry] = []
    private(set) var recentProjectPaths: [String] = []

    init() {
        self.historyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/shell-history.jsonl")

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            if let date = formatter.date(from: dateStr) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date: \(dateStr)"
            )
        }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            entries = []
            recentProjectPaths = []
            return
        }

        do {
            let content = try String(contentsOf: historyURL, encoding: .utf8)
            entries = parseJSONL(content)
            recentProjectPaths = extractRecentProjects(from: entries)
        } catch {
            entries = []
            recentProjectPaths = []
        }
    }

    private func parseJSONL(_ content: String) -> [ShellHistoryEntry] {
        content.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(ShellHistoryEntry.self, from: data)
            }
    }

    private func extractRecentProjects(from entries: [ShellHistoryEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for entry in entries.reversed() {
            if !seen.contains(entry.cwd) {
                seen.insert(entry.cwd)
                result.append(entry.cwd)
            }
        }

        return result
    }

    func recentlyVisitedProjects(matching projectPaths: [String], limit: Int = 10) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for entry in entries.reversed() {
            let matchingProject = projectPaths.first { projectPath in
                entry.cwd == projectPath || entry.cwd.hasPrefix(projectPath + "/")
            }

            if let project = matchingProject, !seen.contains(project) {
                seen.insert(project)
                result.append(project)
                if result.count >= limit {
                    break
                }
            }
        }

        return result
    }

    func visits(for projectPath: String) -> Int {
        entries.filter { entry in
            entry.cwd == projectPath || entry.cwd.hasPrefix(projectPath + "/")
        }.count
    }

    func lastVisited(_ projectPath: String) -> Date? {
        entries.reversed().first { entry in
            entry.cwd == projectPath || entry.cwd.hasPrefix(projectPath + "/")
        }?.timestamp
    }
}
