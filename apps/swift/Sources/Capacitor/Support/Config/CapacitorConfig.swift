import Foundation

actor CapacitorConfig {
    static let shared = CapacitorConfig()

    nonisolated static var defaultURL: URL {
        let capacitorDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor")
        return capacitorDir.appendingPathComponent("runtime-config.json")
    }

    private let configURL: URL
    private var cachedConfig: Config?

    struct Config: Codable {
        var claudePath: String?
        var tmuxPath: String?
    }

    private init(configURL: URL = CapacitorConfig.defaultURL) {
        self.configURL = configURL
    }

    // MARK: - Read

    func load() async -> Config {
        if let cached = cachedConfig {
            return cached
        }

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            let defaultConfig = Config()
            cachedConfig = defaultConfig
            return defaultConfig
        }
        let sourceURL = configURL

        do {
            let data = try Data(contentsOf: sourceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let config = try decoder.decode(Config.self, from: data)
            cachedConfig = config

            return config
        } catch {
            DebugLog.write("Warning: Could not load config: \(error)")
            let defaultConfig = Config()
            cachedConfig = defaultConfig
            return defaultConfig
        }
    }

    // MARK: - Write

    private func save(_ config: Config) async {
        cachedConfig = config

        do {
            let capacitorDir = configURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: capacitorDir.path) {
                try FileManager.default.createDirectory(
                    at: capacitorDir,
                    withIntermediateDirectories: true,
                )
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            DebugLog.write("Warning: Could not save config: \(error)")
        }
    }

    // MARK: - Accessors

    func getClaudePath() async -> String? {
        await load().claudePath
    }

    func setClaudePath(_ path: String) async {
        var config = await load()
        config.claudePath = path
        await save(config)
    }
}
