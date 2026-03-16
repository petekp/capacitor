import Foundation

actor ClaudeCliResolver {
    static let shared = ClaudeCliResolver()

    private let fileManager: FileManager
    private let processInfo: ProcessInfo
    private let config: CapacitorConfig

    init(
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo,
        config: CapacitorConfig = .shared,
    ) {
        self.fileManager = fileManager
        self.processInfo = processInfo
        self.config = config
    }

    func resolveClaudePath() async -> String? {
        let loaded = await config.load()
        if let configured = loaded.claudePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            isExecutable(configured)
        {
            return configured
        }

        let pathEntries = (processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for entry in pathEntries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry)
                .appendingPathComponent("claude")
                .path
            if isExecutable(candidate) {
                return candidate
            }
        }

        return nil
    }

    private func isExecutable(_ path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }
}
