import Foundation

actor CapacitorConfig {
    static let shared = CapacitorConfig()

    private let configURL: URL
    private var cachedConfig: Config?

    struct Config: Codable {
        var claudePath: String?
        var tmuxPath: String?
        var setupCompletedAt: Date?
        var hooksVersion: String?
    }

    private init() {
        let capacitorDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor")
        configURL = capacitorDir.appendingPathComponent("config.json")
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

        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let config = try decoder.decode(Config.self, from: data)
            cachedConfig = config
            return config
        } catch {
            print("Warning: Could not load config: \(error)")
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
                    withIntermediateDirectories: true
                )
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            print("Warning: Could not save config: \(error)")
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

    func getTmuxPath() async -> String? {
        await load().tmuxPath
    }

    func setTmuxPath(_ path: String) async {
        var config = await load()
        config.tmuxPath = path
        await save(config)
    }

    func isSetupComplete() async -> Bool {
        await load().setupCompletedAt != nil
    }

    func markSetupComplete() async {
        var config = await load()
        config.setupCompletedAt = Date()
        await save(config)
    }

    func getHooksVersion() async -> String? {
        await load().hooksVersion
    }

    func setHooksVersion(_ version: String) async {
        var config = await load()
        config.hooksVersion = version
        await save(config)
    }
}
