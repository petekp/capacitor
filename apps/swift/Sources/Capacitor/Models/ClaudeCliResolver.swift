import Foundation

actor ClaudeCliResolver {
    static let shared = ClaudeCliResolver()

    private let fileManager: FileManager
    private let processInfo: ProcessInfo
    private let config: CapacitorConfig
    private let environmentOverride: [String: String]?
    private let fallbackDirectoriesOverride: [String]?

    init(
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo,
        config: CapacitorConfig = .shared,
        environment: [String: String]? = nil,
        fallbackDirectories: [String]? = nil,
    ) {
        self.fileManager = fileManager
        self.processInfo = processInfo
        self.config = config
        environmentOverride = environment
        fallbackDirectoriesOverride = fallbackDirectories
    }

    func resolveClaudePath() async -> String? {
        let loaded = await config.load()
        if let configured = loaded.claudePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            isExecutable(configured)
        {
            return configured
        }

        for candidate in candidatePaths() {
            if isExecutable(candidate) {
                return candidate
            }
        }

        return nil
    }

    private func candidatePaths() -> [String] {
        let environment = environmentOverride ?? processInfo.environment
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let fallbackDirectories = fallbackDirectoriesOverride ?? defaultFallbackDirectories()
        var seen = Set<String>()
        return (pathDirectories + fallbackDirectories)
            .filter { !$0.isEmpty }
            .map {
                URL(fileURLWithPath: $0)
                    .appendingPathComponent("claude")
                    .path
            }
            .filter { seen.insert($0).inserted }
    }

    private func defaultFallbackDirectories() -> [String] {
        [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin")
                .path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
    }

    private func isExecutable(_ path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }
}
