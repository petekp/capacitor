import Foundation

struct PluginRecommendation {
    let pluginName: String
    let reason: String
    let priority: Int
}

struct ProjectTypeDetector {
    let projectPath: String

    private let fileManager = FileManager.default

    func detectProjectTypes() -> [String] {
        var types: [String] = []

        if fileExists("package.json") {
            types.append("node")

            if let content = readFile("package.json") {
                if content.contains("react") { types.append("react") }
                if content.contains("next") { types.append("nextjs") }
                if content.contains("vue") { types.append("vue") }
                if content.contains("angular") { types.append("angular") }
                if content.contains("typescript") { types.append("typescript") }
                if content.contains("tailwind") { types.append("tailwind") }
                if content.contains("prisma") { types.append("prisma") }
                if content.contains("jest") || content.contains("vitest") { types.append("testing") }
            }
        }

        if fileExists("Cargo.toml") {
            types.append("rust")
            if let content = readFile("Cargo.toml") {
                if content.contains("tauri") { types.append("tauri") }
                if content.contains("actix") || content.contains("axum") { types.append("rust-web") }
            }
        }

        if fileExists("Package.swift") {
            types.append("swift")
        }

        if fileExists("requirements.txt") || fileExists("pyproject.toml") || fileExists("setup.py") {
            types.append("python")
            if let content = readFile("requirements.txt") ?? readFile("pyproject.toml") {
                if content.contains("django") { types.append("django") }
                if content.contains("flask") { types.append("flask") }
                if content.contains("fastapi") { types.append("fastapi") }
            }
        }

        if fileExists("go.mod") {
            types.append("go")
        }

        if fileExists("Gemfile") {
            types.append("ruby")
            if let content = readFile("Gemfile") {
                if content.contains("rails") { types.append("rails") }
            }
        }

        if fileExists("Dockerfile") || fileExists("docker-compose.yml") {
            types.append("docker")
        }

        if fileExists(".github/workflows") {
            types.append("github-actions")
        }

        return types
    }

    private func fileExists(_ name: String) -> Bool {
        let path = (projectPath as NSString).appendingPathComponent(name)
        return fileManager.fileExists(atPath: path)
    }

    private func readFile(_ name: String) -> String? {
        let path = (projectPath as NSString).appendingPathComponent(name)
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}

class PluginRecommender: ObservableObject {
    @Published var recommendations: [PluginRecommendation] = []

    private static let pluginDatabase: [String: [(name: String, reason: String)]] = [
        "react": [
            ("react-component-dev", "React component patterns and best practices"),
            ("typescript", "Type-safe React development")
        ],
        "nextjs": [
            ("nextjs-boilerplate", "Next.js project scaffolding"),
            ("react-component-dev", "React component patterns")
        ],
        "typescript": [
            ("typescript", "TypeScript best practices and patterns")
        ],
        "tailwind": [
            ("tailwind", "Tailwind CSS utilities and patterns")
        ],
        "rust": [
            ("rust-patterns", "Idiomatic Rust code patterns")
        ],
        "python": [
            ("python", "Python best practices")
        ],
        "docker": [
            ("docker", "Container best practices")
        ],
        "testing": [
            ("testing", "Test patterns and coverage")
        ]
    ]

    func generateRecommendations(for projectPath: String, installedPlugins: [String]) -> [PluginRecommendation] {
        let detector = ProjectTypeDetector(projectPath: projectPath)
        let types = detector.detectProjectTypes()

        var recommendations: [PluginRecommendation] = []
        var seenPlugins = Set<String>()

        for (priority, projectType) in types.enumerated() {
            if let plugins = Self.pluginDatabase[projectType] {
                for plugin in plugins {
                    if !installedPlugins.contains(plugin.name) && !seenPlugins.contains(plugin.name) {
                        recommendations.append(PluginRecommendation(
                            pluginName: plugin.name,
                            reason: plugin.reason,
                            priority: priority
                        ))
                        seenPlugins.insert(plugin.name)
                    }
                }
            }
        }

        return recommendations.sorted { $0.priority < $1.priority }
    }
}
