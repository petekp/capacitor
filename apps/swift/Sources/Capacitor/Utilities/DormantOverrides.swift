import Foundation

enum DormantOverrideStore {
    private static let dormantOverridesKey = "manuallyDormantProjects"

    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        let paths = defaults.array(forKey: dormantOverridesKey) as? [String] ?? []
        return Set(paths)
    }

    static func save(_ paths: Set<String>, to defaults: UserDefaults = .standard) {
        defaults.set(Array(paths), forKey: dormantOverridesKey)
    }
}
