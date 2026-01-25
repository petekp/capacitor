import Foundation

enum RuntimeDateParser {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let microFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return formatter
    }()

    static func parse(_ dateStr: String) -> Date? {
        if let date = isoWithFractional.date(from: dateStr) {
            return date
        }
        if let date = isoNoFractional.date(from: dateStr) {
            return date
        }
        if let normalized = normalizeFractional(dateStr),
           let date = microFormatter.date(from: normalized)
        {
            return date
        }
        return nil
    }

    private static func normalizeFractional(_ dateStr: String) -> String? {
        guard let dotIndex = dateStr.firstIndex(of: ".") else { return nil }
        var idx = dateStr.index(after: dotIndex)
        var fraction = ""
        while idx < dateStr.endIndex {
            let ch = dateStr[idx]
            if ch >= "0", ch <= "9" {
                fraction.append(ch)
                idx = dateStr.index(after: idx)
            } else {
                break
            }
        }
        guard !fraction.isEmpty else { return nil }
        let tz = String(dateStr[idx...])
        let prefix = String(dateStr[..<dotIndex])
        let padded = fraction.count >= 6
            ? String(fraction.prefix(6))
            : fraction.padding(toLength: 6, withPad: "0", startingAt: 0)
        return "\(prefix).\(padded)\(tz)"
    }
}
