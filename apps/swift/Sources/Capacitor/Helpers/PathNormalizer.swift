import Foundation

enum PathNormalizer {
    static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let withoutTrailing = stripTrailingSlashes(trimmed)
        let standardized = URL(fileURLWithPath: withoutTrailing).standardizedFileURL.path
        let resolved: String = if FileManager.default.fileExists(atPath: standardized) {
            URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        } else {
            standardized
        }

        #if os(macOS)
            return resolved.lowercased()
        #else
            return resolved
        #endif
    }

    private static func stripTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        if result.isEmpty {
            return "/"
        }
        return result
    }
}
