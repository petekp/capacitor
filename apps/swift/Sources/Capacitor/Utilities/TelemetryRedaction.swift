import CryptoKit
import Foundation

enum TelemetryRedaction {
    private static let localHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "::1",
    ]

    private static let embeddedPathPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(~\/[^\s,;"']+)"#),
        try! NSRegularExpression(pattern: #"(/(?:Users|Volumes|private|var|tmp|opt|home|workspaces|mnt)/[^\s,;"']+)"#),
        try! NSRegularExpression(pattern: #"(file:\/\/\/[^\s,;"']+)"#),
    ]

    static func shouldRedactPaths(environment: [String: String], endpoint: URL) -> Bool {
        guard isRemoteEndpoint(endpoint) else {
            return false
        }
        return environment["CAPACITOR_TELEMETRY_INCLUDE_PATHS"] != "1"
    }

    static func redactMessage(_ message: String) -> String {
        redactEmbeddedPaths(in: message)
    }

    static func redactPayload(_ payload: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in payload {
            result[key] = redactValue(value, keyHint: key)
        }
        return result
    }

    private static func redactValue(_ value: Any, keyHint: String?) -> Any {
        if let dict = value as? [String: Any] {
            var updated: [String: Any] = [:]
            for (key, nestedValue) in dict {
                updated[key] = redactValue(nestedValue, keyHint: key)
            }
            return updated
        }

        if let array = value as? [Any] {
            return array.map { redactValue($0, keyHint: keyHint) }
        }

        if let text = value as? String {
            if shouldRedactField(named: keyHint) {
                return pathToken(for: text)
            }
            return redactEmbeddedPaths(in: text)
        }

        return value
    }

    private static func shouldRedactField(named key: String?) -> Bool {
        guard let key else { return false }
        let normalized = key.lowercased()
        return normalized.contains("path")
            || normalized.contains("cwd")
            || normalized.contains("workspace")
            || normalized.contains("directory")
    }

    private static func redactEmbeddedPaths(in input: String) -> String {
        var output = input
        for regex in embeddedPathPatterns {
            let matches = regex.matches(
                in: output,
                options: [],
                range: NSRange(output.startIndex ..< output.endIndex, in: output),
            )
            guard !matches.isEmpty else { continue }

            for match in matches.reversed() {
                guard let range = Range(match.range, in: output) else { continue }
                let candidate = String(output[range])
                output.replaceSubrange(range, with: pathToken(for: candidate))
            }
        }
        return output
    }

    private static func pathToken(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return value
        }
        return "path#\(digestHex(trimmed).prefix(12))"
    }

    private static func digestHex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isRemoteEndpoint(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host?.lowercased() else {
            return false
        }
        if localHosts.contains(host) || host.hasSuffix(".local") {
            return false
        }
        return true
    }
}
